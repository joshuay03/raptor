# rbs_inline: enabled
# frozen_string_literal: true

require "nio"
require "openssl"
require "red-black-tree"
require "timeout"

require "atomic-ruby/atom"
require "atomic-ruby/atomic_boolean"
require "atomic-ruby/atomic_condition_variable"
require "atomic-ruby/atomic_queue"

require_relative "detached_body"
require_relative "http1"
require_relative "http2"
require_relative "log"

module Raptor
  # Multiplexes client connections, manages connection deadlines, feeds
  # ready bytes to the parser pipeline, and hands completed requests back
  # to the caller-provided handlers.
  #
  class Reactor
    # A client connection node ordered by absolute expiry time so the
    # soonest-to-expire is always at the tree's minimum.
    #
    class TimeoutClient < RedBlackTree::Node
      # @rbs attr_accessor timeout_at: Float
      attr_accessor :timeout_at

      # Returns the client connection state.
      #
      # @return [Hash] the client connection state
      #
      # @rbs () -> Hash[Symbol, untyped]
      def client_data
        data
      end

      # Returns seconds until expiry, clamped to 0 so an already-expired
      # client doesn't push the next selector wait into the future.
      #
      # @param now [Float] current monotonic timestamp
      # @return [Float] seconds until expiry, never negative
      #
      # @rbs (Float now) -> Float
      def timeout(now)
        [timeout_at - now, 0].max
      end

      # Orders nodes by `timeout_at` so the tree minimum is the next
      # client to expire.
      #
      # @param other [TimeoutClient] another timeout client to compare
      # @return [Integer] -1, 0, or 1
      #
      # @rbs (TimeoutClient other) -> Integer
      def <=>(other)
        timeout_at <=> other.timeout_at
      end
    end

    # Tracks reactor-owned output state for a connection.
    #
    class ConnectionIO
      # @rbs attr_accessor offset: Integer
      attr_accessor :offset

      # @rbs attr_accessor wait: Symbol?
      attr_accessor :wait

      # @rbs attr_accessor reading: bool
      attr_accessor :reading

      # @rbs attr_accessor closing: bool
      attr_accessor :closing

      # @rbs attr_accessor monitor: NIO::Monitor?
      attr_accessor :monitor

      # @rbs attr_accessor timeout: TimeoutClient?
      attr_accessor :timeout

      # @rbs attr_reader output: Array[String]
      attr_reader :output

      # Creates empty connection I/O state for reactor-owned writes.
      #
      # @return [void]
      #
      # @rbs () -> void
      def initialize
        @output = []
        @offset = 0
        @wait = nil
        @reading = false
        @closing = false
        @monitor = nil
        @timeout = nil
      end

      # Returns whether the connection has no output waiting to be written.
      #
      # @return [Boolean]
      #
      # @rbs () -> bool
      def empty?
        output.empty?
      end
    end

    # Tracks reactor-owned I/O state for an HTTP/1.x detached response.
    #
    class Http1IO < ConnectionIO
      # @rbs attr_accessor body: DetachedBody?
      attr_accessor :body

      # @rbs attr_accessor finishing: bool
      attr_accessor :finishing

      # @rbs attr_reader budget: DetachedBody::Budget
      attr_reader :budget

      # @rbs attr_reader input: String
      attr_reader :input

      # @rbs attr_reader state: Hash[Symbol, untyped]
      attr_reader :state

      # Creates I/O state for an HTTP/1.x detached response.
      #
      # @param body [DetachedBody] the response body
      # @param state [Hash] connection state restored after the response finishes
      # @return [void]
      #
      # @rbs (DetachedBody body, Hash[Symbol, untyped] state) -> void
      def initialize(body, state)
        super()
        @body = body
        @state = state
        @budget = DetachedBody::Budget.new(DETACHED_CONNECTION_BUFFER_SIZE)
        @input = String.new(encoding: Encoding::ASCII_8BIT)
        @reading = true
        @finishing = false
      end

      # Returns whether the connection has no output or detached body remaining.
      #
      # @return [Boolean]
      #
      # @rbs () -> bool
      def empty?
        super && !body
      end
    end

    # Tracks reactor-owned I/O state for an HTTP/2 connection.
    #
    class Http2IO < ConnectionIO
      # @rbs attr_reader detached: Hash[Integer, DetachedBody]
      attr_reader :detached

      # @rbs attr_reader ready: Array[Integer]
      attr_reader :ready

      # @rbs attr_reader ready_streams: Hash[Integer, bool]
      attr_reader :ready_streams

      # @rbs attr_reader budget: DetachedBody::Budget
      attr_reader :budget

      # Creates empty I/O state for an HTTP/2 connection and its detached streams.
      #
      # @return [void]
      #
      # @rbs () -> void
      def initialize
        super
        @detached = {}
        @ready = []
        @ready_streams = {}
        @budget = DetachedBody::Budget.new(DETACHED_CONNECTION_BUFFER_SIZE)
      end

      # Returns whether the connection has no output or detached streams remaining.
      #
      # @return [Boolean]
      #
      # @rbs () -> bool
      def empty?
        super && detached.empty?
      end
    end

    CHUNK_SIZE = 64 * 1024
    DETACHED_CONNECTION_BUFFER_SIZE = 1024 * 1024
    DETACHED_WRITE_BATCH = 8
    DETACHED_WORKER_BUFFER_SIZE = 16 * 1024 * 1024
    TIMEOUT_RESPONSE = "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    # @rbs @thread_pool: untyped
    # @rbs @http1_ractor_pool: untyped
    # @rbs @http2_ractor_pool: untyped
    # @rbs @first_data_timeout: Integer
    # @rbs @chunk_data_timeout: Integer
    # @rbs @persistent_data_timeout: Integer
    # @rbs @write_timeout: Integer
    # @rbs @http2_keepalive_interval: Integer
    # @rbs @http2_keepalive_timeout: Integer
    # @rbs @selector: NIO::Selector
    # @rbs @queue: Queue[TCPSocket]
    # @rbs @io_queue: AtomicQueue
    # @rbs @io_applied: AtomicConditionVariable
    # @rbs @timeouts: RedBlackTree[TimeoutClient]
    # @rbs @id_to_socket: Hash[Integer, TCPSocket]
    # @rbs @socket_to_state: Hash[TCPSocket, Hash[Symbol, untyped]]
    # @rbs @id_to_timeout: Hash[Integer, TimeoutClient]
    # @rbs @id_to_writer: Hash[Integer, untyped]
    # @rbs @id_to_flow_control: Hash[Integer, untyped]
    # @rbs @id_to_http2_last_stream: Hash[Integer, Integer]
    # @rbs @id_to_http2_drain_stream: Hash[Integer, Integer]
    # @rbs @id_to_http2_keepalive: Hash[Integer, Hash[Symbol, untyped]]
    # @rbs @id_to_io: Hash[Integer, ConnectionIO]
    # @rbs @detached_budget: DetachedBody::Budget
    # @rbs @detached_count: Atom
    # @rbs @detached_drained: AtomicConditionVariable
    # @rbs @thread: Thread?

    # Creates a new Reactor instance.
    #
    # @param http1_ractor_pool [RactorPool] ractor pool for HTTP/1.x parsing
    # @param http2_ractor_pool [RactorPool, nil] ractor pool for HTTP/2 parsing, or nil when no listener supports HTTP/2
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param connection_options [Hash] per-connection timeout configuration
    # @option connection_options [Integer] :first_data_timeout timeout for initial data
    # @option connection_options [Integer] :chunk_data_timeout timeout for subsequent chunks
    # @option connection_options [Integer] :write_timeout timeout for non-blocking writes
    # @param http1_options [Hash] HTTP/1.1-specific configuration
    # @option http1_options [Integer] :persistent_data_timeout timeout for keep-alive idle connections
    # @param http2_options [Hash] HTTP/2-specific configuration
    # @option http2_options [Integer] :keepalive_interval idle time before sending a PING
    # @option http2_options [Integer] :keepalive_timeout time to await a PING acknowledgement
    # @return [void]
    #
    # @rbs (untyped http1_ractor_pool, untyped http2_ractor_pool, untyped thread_pool, connection_options: Hash[Symbol, untyped], http1_options: Hash[Symbol, untyped], http2_options: Hash[Symbol, untyped]) -> void
    def initialize(http1_ractor_pool, http2_ractor_pool, thread_pool, connection_options:, http1_options:, http2_options:)
      @http1_ractor_pool = http1_ractor_pool
      @http2_ractor_pool = http2_ractor_pool
      @thread_pool = thread_pool
      @first_data_timeout = connection_options[:first_data_timeout]
      @chunk_data_timeout = connection_options[:chunk_data_timeout]
      @write_timeout = connection_options[:write_timeout]
      @persistent_data_timeout = http1_options[:persistent_data_timeout]
      @http2_keepalive_interval = http2_options[:keepalive_interval]
      @http2_keepalive_timeout = http2_options[:keepalive_timeout]

      @selector = NIO::Selector.new
      @queue = Queue.new
      @io_queue = AtomicQueue.new
      @io_applied = AtomicConditionVariable.new
      @timeouts = RedBlackTree.new

      @id_to_socket = {}
      @socket_to_state = {}
      @id_to_timeout = {}
      @id_to_writer = {}
      @id_to_flow_control = {}
      @id_to_http2_last_stream = {}
      @id_to_http2_drain_stream = {}
      @id_to_http2_keepalive = {}
      @id_to_io = {}
      @detached_budget = DetachedBody::Budget.new(DETACHED_WORKER_BUFFER_SIZE)
      @detached_count = Atom.new(0)
      @detached_drained = AtomicConditionVariable.new
      @thread = nil
    end

    # Starts the reactor's main event loop in a new thread. Runs until
    # shutdown work and pending writes are drained.
    #
    # @return [Thread] the thread running the reactor event loop
    #
    # @rbs () -> Thread
    def run
      Thread.new do
        Thread.current.name = "Reactor"
        @thread = Thread.current

        until stopped?
          begin
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            timeout = @timeouts.min&.timeout(now)
            @selector.select(timeout) do |monitor|
              handle_monitor(monitor)
            end

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expire_timeouts(now)
            drain_io_queue

            until @queue.empty?
              register(@queue.pop)
            end
          rescue => error
            Log.rescued_error(error)
          end
        end

        @id_to_flow_control.each_value(&:close)
        @id_to_socket.each_value { |socket| socket.close rescue nil }
        @id_to_socket.clear
        @socket_to_state.clear
        @id_to_timeout.clear
        @id_to_writer.clear
        @id_to_flow_control.clear
        @id_to_http2_last_stream.clear
        @id_to_http2_drain_stream.clear
        @id_to_http2_keepalive.clear
        @id_to_io.clear
        @timeouts.clear!
        @thread = nil
        @selector.close
      end
    end

    # Adds a new client connection to the reactor.
    #
    # @param state [Hash] client connection state including socket and ID
    # @option state [TCPSocket] :socket the client socket
    # @option state [Integer] :id unique identifier for the client
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] state) -> void
    def add(state)
      socket = state[:socket]
      state.delete(:socket)
      writer = state.delete(:writer)
      flow_control = state.delete(:flow_control)
      @id_to_socket[state[:id]] = socket
      @socket_to_state[socket] = state
      @id_to_writer[state[:id]] = writer if writer
      @id_to_flow_control[state[:id]] = flow_control if flow_control

      read_and_queue_for_parse(socket, state)
    end

    # Updates the state of an existing client connection and re-registers
    # it for further I/O.
    #
    # @param state [Hash] updated client connection state
    # @option state [Integer] :id client identifier
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] state) -> void
    def update_state(state)
      socket = @id_to_socket[state[:id]]
      return unless socket

      @socket_to_state[socket] = state
      @queue << socket
      @selector.wakeup
    rescue ClosedQueueError
      socket.close
    end

    # Drops the reactor's references to a client whose parsed request
    # has been handed off to the thread pool. The socket itself is kept
    # open so the worker can write the response.
    #
    # @param id [Integer] unique client identifier
    # @return [TCPSocket, nil] the socket associated with `id`, if any
    #
    # @rbs (Integer id) -> TCPSocket?
    def remove(id)
      @id_to_socket.delete(id).tap do |socket|
        @socket_to_state.delete(socket)
      end
    end

    # Re-registers a kept-alive connection for the next request cycle
    # under the persistent-data timeout.
    #
    # @param socket [TCPSocket] the kept-alive client socket
    # @param id [Integer] the unique client identifier
    # @param request_count [Integer] number of requests handled on this connection
    # @param remote_addr [String] the client's remote IP address
    # @param url_scheme [String] "http" or "https"
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, Integer request_count, remote_addr: String, url_scheme: String) -> void
    def persist(socket, id, request_count, remote_addr:, url_scheme:)
      state = {
        id: id,
        request_count: request_count,
        remote_addr: remote_addr,
        url_scheme: url_scheme,
        persisted: true
      }

      @id_to_socket[id] = socket
      @socket_to_state[socket] = state
      @queue << socket
      @selector.wakeup
    rescue ClosedQueueError
      socket.close
    end

    # Returns the socket for a given client identifier without removing it.
    #
    # @param id [Integer] unique client identifier
    # @return [TCPSocket, nil] the socket, if found
    #
    # @rbs (Integer id) -> TCPSocket?
    def socket_for(id)
      @id_to_socket[id]
    end

    # Returns the writer object associated with a given connection, if one
    # was supplied when the connection was added.
    #
    # @param id [Integer] unique client identifier
    # @return [Object, nil] the writer, if found
    #
    # @rbs (Integer id) -> untyped?
    def writer_for(id)
      @id_to_writer[id]
    end

    # Returns the flow controller associated with a given connection, if
    # one was supplied when the connection was added.
    #
    # @param id [Integer] unique client identifier
    # @return [Object, nil] the flow controller, if found
    #
    # @rbs (Integer id) -> untyped?
    def flow_control_for(id)
      @id_to_flow_control[id]
    end

    # Attaches a detached response body to an HTTP/1.x connection.
    #
    # @param socket [TCPSocket] the client socket
    # @param id [Integer] unique client identifier
    # @param body [DetachedBody] the response body
    # @param state [Hash] connection state restored once the response finishes
    # @param finished [Proc] called with the close reason
    # @return [Boolean] whether the body was attached
    #
    # @rbs (TCPSocket socket, Integer id, DetachedBody body, Hash[Symbol, untyped] state, ^(Symbol) -> void finished) -> bool
    def attach_http1_body(socket, id, body, state, finished)
      attached = AtomicBoolean.new(false)
      @io_queue << [:attach_http1, id, socket, body, attached, finished, state]
      @selector.wakeup rescue nil
      @io_applied.wait { attached.true? }
      return false if body.closed?

      body.open
      true
    rescue
      remove_connection(id)
      raise
    end

    # Records an HTTP/2 stream before application dispatch, rejecting streams
    # that arrived after graceful draining began.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @return [Boolean] whether the stream may be dispatched
    #
    # @rbs (Integer id, Integer stream_id) -> bool
    def dispatch_http2_stream(id, stream_id)
      if (last_stream = @id_to_http2_drain_stream[id])
        return stream_id <= last_stream
      end

      current = @id_to_http2_last_stream[id] || 0
      @id_to_http2_last_stream[id] = stream_id if stream_id > current
      true
    end

    # Sends GOAWAY on every HTTP/2 connection and fixes the last stream each
    # connection may dispatch while existing application work drains.
    #
    # @yieldparam stream_id [Integer] last dispatched stream identifier
    # @yieldreturn [String] serialized GOAWAY frame
    # @return [void]
    #
    # @rbs () { (Integer stream_id) -> String } -> void
    def drain_http2
      @id_to_flow_control.each_key do |id|
        last_stream = @id_to_http2_last_stream[id] || 0
        @id_to_http2_drain_stream[id] = last_stream
        writer = @id_to_writer[id]
        socket = @id_to_socket[id]
        writer.write_frames(socket, [yield(last_stream)]) if writer && socket
      end
    end

    # Queues serialized HTTP/2 frames for a connection. Producers never
    # write to the socket or wait for it to become writable.
    #
    # @param id [Integer] unique connection identifier
    # @param frames [Array<String>] frame bytes to write in order
    # @return [void]
    #
    # @rbs (Integer id, Array[String] frames) -> void
    def write_http2_frames(id, frames)
      data = frames.join
      return if data.empty?

      if Thread.current.equal?(@thread)
        io = @id_to_io[id]
        queue_output(io, data)
        flush_output(id, io) if io && !io.wait
      else
        @io_queue << [:write, id, data]
        @selector.wakeup rescue nil
      end
    end

    # Attaches a detached response body to an HTTP/2 stream.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @param body [DetachedBody] the response body
    # @param finished [Proc] called with the close reason
    # @return [Boolean] whether the body was attached
    #
    # @rbs (Integer id, Integer stream_id, DetachedBody body, ^(Symbol) -> void finished) -> bool
    def attach_http2_body(id, stream_id, body, finished)
      attached = AtomicBoolean.new(false)
      @io_queue << [:attach_http2, id, stream_id, body, attached, finished]
      @selector.wakeup rescue nil
      @io_applied.wait { attached.true? }
      return false if body.closed?

      body.open
      true
    rescue
      cancel_http2_body(id, stream_id)
      raise
    end

    # Reconsiders detached streams after an outbound window update.
    #
    # @param id [Integer] unique connection identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def resume_http2_bodies(id)
      return if @detached_count.value.zero?

      @io_queue << [:resume_http2, id]
      @selector.wakeup rescue nil
    end

    # Cancels a detached response stream.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @return [void]
    #
    # @rbs (Integer id, Integer stream_id) -> void
    def cancel_http2_body(id, stream_id)
      return if @detached_count.value.zero?

      @io_queue << [:cancel_http2, id, stream_id]
      @selector.wakeup rescue nil
    end

    # Waits for detached responses to finish, then cancels any that outlive
    # the worker drain period.
    #
    # @param timeout [Numeric] seconds to wait before cancelling open bodies
    # @return [void]
    #
    # @rbs (Numeric timeout) -> void
    def drain_detached_bodies(timeout)
      barrier = AtomicBoolean.new(false)
      @io_queue << [:barrier, nil, barrier]
      @selector.wakeup rescue nil
      @io_applied.wait { barrier.true? }

      Timeout.timeout(timeout) do
        @detached_drained.wait { @detached_count.value.zero? }
      end
    rescue Timeout::Error
      @io_queue << [:cancel_all]
      @selector.wakeup rescue nil
      @detached_drained.wait { @detached_count.value.zero? }
    end

    # Stores an HTTP/2 connection's socket, state, writer, and flow
    # controller in the reactor's per-connection maps.
    #
    # @param id [Integer] unique client identifier
    # @param socket [TCPSocket] the connection socket
    # @param state [Hash] initial connection state
    # @param writer [Http2::Writer] per-connection frame writer
    # @param flow_control [Http2::FlowControl] per-connection outbound flow controller
    # @param ping_frame [String] serialized PING frame for keepalive probes
    # @param ping_payload [String] payload expected in the corresponding acknowledgement
    # @return [void]
    #
    # @rbs (id: Integer, socket: TCPSocket, state: Hash[Symbol, untyped], writer: untyped, flow_control: untyped, ping_frame: String, ping_payload: String) -> void
    def attach_http2(id:, socket:, state:, writer:, flow_control:, ping_frame:, ping_payload:)
      @id_to_socket[id] = socket
      @socket_to_state[socket] = state
      @id_to_writer[id] = writer
      @id_to_flow_control[id] = flow_control
      @id_to_http2_last_stream[id] = 0
      @id_to_io[id] = Http2IO.new
      writer.attach(self, id)
      if @http2_keepalive_interval.positive?
        @id_to_http2_keepalive[id] = { frame: ping_frame, payload: ping_payload }
      end
    end

    # Records acknowledgements for server keepalive probes.
    #
    # @param id [Integer] unique connection identifier
    # @param payloads [Array<String>, nil] acknowledged PING payloads
    # @return [void]
    #
    # @rbs (Integer id, Array[String]? payloads) -> void
    def acknowledge_http2_ping(id, payloads)
      keepalive = @id_to_http2_keepalive[id]
      return unless keepalive && payloads&.include?(keepalive[:payload])

      keepalive.delete(:deadline)
    end

    # Registers an attached socket for future reactor-driven reads.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def watch(id)
      socket = @id_to_socket[id]
      return unless socket

      @queue << socket
      @selector.wakeup
    rescue ClosedQueueError
      socket.close
    end

    # Updates connection state for an HTTP/2 connection and re-registers
    # the socket for further reads.
    #
    # @param state [Hash] updated connection state from the ractor pool
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] state) -> void
    def update_http2_state(state)
      socket = @id_to_socket[state[:id]]
      return unless socket

      @socket_to_state[socket] = state
      @queue << socket
      @selector.wakeup
    rescue ClosedQueueError
      socket.close
    end

    # Closes a connection after writing any frames already queued for it.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def close_connection(id)
      @io_queue << [:close, id]
      @selector.wakeup rescue nil
    end

    # Closes the registration queue and wakes the selector so the
    # event loop drains pending work and exits.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      @queue.close
      @selector.wakeup
    end

    # Returns the number of complete requests either being processed
    # or awaiting processing.
    #
    # @return [Integer] number of complete requests
    #
    # @rbs () -> Integer
    def backlog
      @thread_pool.queue_size + @thread_pool.active_count
    end

    private

    # Returns whether shutdown has no registrations or writes left to drain.
    #
    # @return [Boolean]
    #
    # @rbs () -> bool
    def stopped?
      @queue.closed? && @queue.empty? && @io_queue.empty? &&
        @id_to_io.each_value.all?(&:empty?)
    end

    # Handles every expired connection deadline in order.
    #
    # @param now [Float] current monotonic timestamp
    # @return [void]
    #
    # @rbs (Float now) -> void
    def expire_timeouts(now)
      while (client = @timeouts.min) && client.timeout(now).zero?
        @timeouts.delete!(client)
        id = client.client_data[:id]
        if client.client_data[:write]
          @id_to_io[id]&.timeout = nil
          remove_connection(id)
        else
          @id_to_timeout.delete(id)
          handle_timeout(client, now)
        end
      end
    end

    # Applies queued reactor-owned I/O operations.
    #
    # @return [void]
    #
    # @rbs () -> void
    def drain_io_queue
      connections = {}
      while (operation = @io_queue.pop)
        type, id, value, body, attached, finished, state = operation
        case type
        when :write
          data = value
          queue_output(@id_to_io[id], data)
          connections[id] = true
        when :close
          close_after_writes(id)
        when :attach_http2
          begin
            attach_http2_detached_body(id, value, body, finished)
          ensure
            attached.make_true
            @io_applied.broadcast
          end
          connections[id] = true
        when :attach_http1
          begin
            attach_http1_detached_body(value, id, body, state, finished)
          ensure
            attached.make_true
            @io_applied.broadcast
          end
        when :ready_http1
          flush_http1_detached_body(id)
        when :ready_http2
          mark_http2_detached_body_ready(id, value)
          connections[id] = true
        when :flush_http2
          connections[id] = true
        when :resume_http2
          resume_http2_detached_bodies(id)
          connections[id] = true
        when :cancel_http2
          remove_http2_detached_body(id, value, :cancelled)
        when :cancel_all
          cancel_detached_bodies
        when :barrier
          value.make_true
          @io_applied.broadcast
        end
      end

      connections.each_key do |id|
        io = @id_to_io[id]
        flush_output(id, io) if io && !io.wait
        flush_http2_detached_bodies(id) if io.is_a?(Http2IO) && !io.wait && !io.detached.empty?
      end
    end

    # Adds a detached body to an HTTP/1.x connection.
    #
    # @param socket [TCPSocket] the client socket
    # @param id [Integer] unique client identifier
    # @param body [DetachedBody] the response body
    # @param state [Hash] connection state restored once the response finishes
    # @param finished [Proc] called with the close reason
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, DetachedBody body, Hash[Symbol, untyped] state, ^(Symbol) -> void finished) -> void
    def attach_http1_detached_body(socket, id, body, state, finished)
      io = Http1IO.new(body, state)
      dispatch = proc { |callback| @thread_pool << callback }
      wake = proc do
        @io_queue << [:ready_http1, id]
        @selector.wakeup rescue nil
      end
      unless body.attach([io.budget, @detached_budget], wake, dispatch, finished)
        socket.close rescue nil
        return
      end

      @id_to_socket[id] = socket
      @socket_to_state[socket] = { id: id, protocol: :http1, detached: true }
      @id_to_io[id] = io
      @detached_count.swap { |count| count + 1 }
      update_monitor(id, io)
    end

    # Writes buffered HTTP/1.x body chunks without blocking.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def flush_http1_detached_body(id)
      io = @id_to_io[id]
      return unless io.is_a?(Http1IO) && !io.wait && io.output.empty?

      DETACHED_WRITE_BATCH.times do
        size = io.body&.next_size
        break unless size

        if size.zero?
          queue_output(io, Http1.encode_trailers(io.body.trailers)) if io.state[:chunked]
          io.finishing = true
          flush_output(id, io)
          break
        end

        chunk = io.body.shift(size)
        queue_output(io, io.state[:chunked] ? Http1.encode_chunk(chunk) : chunk)
        flush_output(id, io)
        break if io.wait
      end

      if !io.finishing && !io.wait && io.body&.next_size
        @io_queue << [:ready_http1, id]
        @selector.wakeup rescue nil
      end
    end

    # Finishes an HTTP/1.x detached response and either reuses or closes its connection.
    #
    # @param id [Integer] unique client identifier
    # @param io [Http1IO] connection I/O state
    # @return [void]
    #
    # @rbs (Integer id, Http1IO io) -> void
    def finish_http1_detached_body(id, io)
      socket = @id_to_socket[id]
      return unless socket

      body = io.body
      io.body = nil
      body.finish(:closed)
      detached_body_removed
      @id_to_io.delete(id)
      deregister(socket, io)
      clear_write_timeout(io)

      if io.state[:keep_alive]
        state = {
          id: id,
          request_count: io.state[:request_count],
          remote_addr: io.state[:remote_addr],
          url_scheme: io.state[:url_scheme],
          persisted: true
        }
        unless io.input.empty?
          state[:buffer] = io.input
          @socket_to_state[socket] = state
          @http1_ractor_pool << Ractor.make_shareable(state)
          return
        end

        persist(socket, id, io.state[:request_count], remote_addr: io.state[:remote_addr], url_scheme: io.state[:url_scheme])
      else
        @socket_to_state.delete(socket)
        @id_to_socket.delete(id)
        socket.close rescue nil
      end
    end

    # Cancels an HTTP/1.x detached response and closes its connection.
    #
    # @param id [Integer] unique client identifier
    # @param reason [Symbol] why the response closed
    # @return [void]
    #
    # @rbs (Integer id, Symbol reason) -> void
    def remove_http1_detached_body(id, reason)
      io = @id_to_io[id]
      return unless io.is_a?(Http1IO) && io.body

      body = io.body
      io.body = nil
      body.finish(reason)
      detached_body_removed
      remove_connection(id)
    end

    # Adds a detached body to an HTTP/2 stream.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @param body [DetachedBody] the response body
    # @param finished [Proc] called with the close reason
    # @return [void]
    #
    # @rbs (Integer id, Integer stream_id, DetachedBody body, ^(Symbol) -> void finished) -> void
    def attach_http2_detached_body(id, stream_id, body, finished)
      io = @id_to_io[id]
      dispatch = proc { |callback| @thread_pool << callback }
      unless io
        body.attach([], proc {}, dispatch, finished)
        body.finish(:connection_closed)
        return
      end

      wake = proc do
        @io_queue << [:ready_http2, id, stream_id]
        @selector.wakeup rescue nil
      end
      return unless body.attach([io.budget, @detached_budget], wake, dispatch, finished)

      io.detached[stream_id] = body
      @detached_count.swap { |count| count + 1 }
    end

    # Marks an HTTP/2 detached stream eligible for fair scheduling.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @return [void]
    #
    # @rbs (Integer id, Integer stream_id) -> void
    def mark_http2_detached_body_ready(id, stream_id)
      io = @id_to_io[id]
      return unless io&.detached&.key?(stream_id) && !io.ready_streams.key?(stream_id)

      io.ready << stream_id
      io.ready_streams[stream_id] = true
    end

    # Marks every HTTP/2 detached stream eligible after flow-control capacity changes.
    #
    # @param id [Integer] unique connection identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def resume_http2_detached_bodies(id)
      io = @id_to_io[id]
      return unless io

      io.detached.each_key { |stream_id| mark_http2_detached_body_ready(id, stream_id) }
    end

    # Writes HTTP/2 detached streams in round-robin order without waiting for flow control.
    #
    # @param id [Integer] unique connection identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def flush_http2_detached_bodies(id)
      io = @id_to_io[id]
      flow_control = @id_to_flow_control[id]
      socket = @id_to_socket[id]
      return unless io && flow_control && socket

      DETACHED_WRITE_BATCH.times do
        break if io.wait || !io.output.empty?

        stream_id = io.ready.shift
        break unless stream_id

        io.ready_streams.delete(stream_id)
        body = io.detached[stream_id]
        next unless body

        size = body.next_size
        next unless size

        if size.zero?
          finish_http2_detached_body(id, stream_id, body)
          next
        end

        granted = flow_control.try_acquire(stream_id, size)
        next if granted.zero?

        chunk = body.shift(granted)
        parser = Http2Parser.new
        queue_output(io, parser.build_frame(:data, 0, stream_id, chunk))
        flush_output(id, io)
        mark_http2_detached_body_ready(id, stream_id) if body.next_size
      rescue Http2::StreamClosedError
        remove_http2_detached_body(id, stream_id, :cancelled)
      end

      if !io.wait && io.output.empty? && !io.ready.empty?
        @io_queue << [:flush_http2, id]
        @selector.wakeup rescue nil
      end
    end

    # Finishes an HTTP/2 detached stream with DATA or trailing HEADERS.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @param body [DetachedBody] the response body
    # @return [void]
    #
    # @rbs (Integer id, Integer stream_id, DetachedBody body) -> void
    def finish_http2_detached_body(id, stream_id, body)
      parser = Http2Parser.new
      frame = if body.trailers.empty?
        parser.build_frame(:data, Http2::FLAG_END_STREAM, stream_id, nil)
      else
        encoded = parser.encode_response_trailers(body.trailers)
        parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, stream_id, encoded)
      end
      io = @id_to_io[id]
      queue_output(io, frame)
      flush_output(id, io)
      remove_http2_detached_body(id, stream_id, :closed)
    end

    # Removes an HTTP/2 detached stream and schedules its close callback.
    #
    # @param id [Integer] unique connection identifier
    # @param stream_id [Integer] HTTP/2 stream identifier
    # @param reason [Symbol] why the stream closed
    # @return [void]
    #
    # @rbs (Integer id, Integer stream_id, Symbol reason) -> void
    def remove_http2_detached_body(id, stream_id, reason)
      io = @id_to_io[id]
      body = io&.detached&.delete(stream_id)
      return unless body

      io.ready_streams.delete(stream_id)
      body.finish(reason)
      detached_body_removed
    end

    # Cancels every detached response during worker shutdown.
    #
    # @return [void]
    #
    # @rbs () -> void
    def cancel_detached_bodies
      @id_to_io.to_a.each do |id, io|
        if io.is_a?(Http1IO)
          remove_http1_detached_body(id, :shutdown)
        else
          io.detached.each_key.to_a.each do |stream_id|
            remove_http2_detached_body(id, stream_id, :shutdown)
          end
        end
      end
    end

    # Records one detached stream finishing.
    #
    # @return [void]
    #
    # @rbs () -> void
    def detached_body_removed
      remaining = nil
      @detached_count.swap do |count|
        remaining = count - 1
        remaining
      end
      @detached_drained.broadcast if remaining.zero?
    end

    # Closes a connection once its queued frames are written.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def close_after_writes(id)
      io = @id_to_io[id]
      return unless io

      if io.empty?
        remove_connection(id)
      else
        io.closing = true
      end
    end

    # Immediately closes a connection and drops its reactor state.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def remove_connection(id)
      socket = @id_to_socket[id]
      cleanup(socket) if socket
    end

    # Adds bytes to one connection and writes as much as the socket accepts.
    #
    # @param io [ConnectionIO] connection I/O state
    # @param data [String] serialized response bytes
    # @return [void]
    #
    # @rbs (ConnectionIO? io, String data) -> void
    def queue_output(io, data)
      return unless io && !io.closing

      if io.output.empty?
        io.output << data
      else
        io.output[-1] << data
      end
    end

    # Drains one connection's queued response bytes without blocking.
    #
    # @param id [Integer] unique connection identifier
    # @param io [ConnectionIO] connection I/O state
    # @return [void]
    #
    # @rbs (Integer id, ConnectionIO? io) -> void
    def flush_output(id, io)
      socket = @id_to_socket[id]
      return unless socket && io

      while (data = io.output.first)
        chunk = io.offset.zero? ? data : data.byteslice(io.offset..-1)

        begin
          written = socket.write_nonblock(chunk)
        rescue IO::WaitReadable
          wait_for_write(id, io, :read)
          return
        rescue IO::WaitWritable
          wait_for_write(id, io, :write)
          return
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          remove_connection(id)
          return
        end

        if written.zero?
          wait_for_write(id, io, :write)
          return
        end

        clear_write_timeout(io)
        io.offset += written
        if io.offset == data.bytesize
          io.output.shift
          io.offset = 0
        end
      end

      io.wait = nil
      if io.is_a?(Http1IO) && io.finishing
        finish_http1_detached_body(id, io)
      elsif io.closing
        remove_connection(id)
      else
        update_monitor(id, io)
      end
    end

    # Registers the readiness needed to continue a partial socket write.
    #
    # @param id [Integer] unique connection identifier
    # @param io [ConnectionIO] connection I/O state
    # @param readiness [Symbol] `:read` or `:write`
    # @return [void]
    #
    # @rbs (Integer id, ConnectionIO io, Symbol readiness) -> void
    def wait_for_write(id, io, readiness)
      io.wait = readiness
      track_write_timeout(id, io)
      update_monitor(id, io)
    end

    # Updates selector interest for one reactor-owned connection.
    #
    # @param id [Integer] unique connection identifier
    # @param io [ConnectionIO] connection I/O state
    # @return [void]
    #
    # @rbs (Integer id, ConnectionIO io) -> void
    def update_monitor(id, io)
      socket = @id_to_socket[id]
      return unless socket && io

      read = io.reading || io.wait == :read
      write = io.wait == :write
      interests = if read && write
        :rw
      elsif read
        :r
      elsif write
        :w
      end

      if io.monitor
        io.monitor.interests = interests
      elsif interests
        io.monitor = @selector.register(socket, interests)
        io.monitor.value = socket
      end
    end

    # Starts or refreshes one connection's non-blocking write deadline.
    #
    # @param id [Integer] unique connection identifier
    # @param io [ConnectionIO] connection I/O state
    # @return [void]
    #
    # @rbs (Integer id, ConnectionIO io) -> void
    def track_write_timeout(id, io)
      clear_write_timeout(io)
      client = TimeoutClient.new({ id: id, write: true })
      client.timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @write_timeout
      @timeouts << client
      io.timeout = client
    end

    # Removes one connection's non-blocking write deadline.
    #
    # @param io [ConnectionIO, nil] connection I/O state
    # @return [void]
    #
    # @rbs (ConnectionIO? io) -> void
    def clear_write_timeout(io)
      client = io&.timeout
      @timeouts.delete!(client) if client
      io.timeout = nil if io
    end

    # Removes a socket from selector tracking.
    #
    # @param socket [TCPSocket] socket to deregister
    # @param io [ConnectionIO, nil] connection I/O state
    # @return [void]
    #
    # @rbs (TCPSocket socket, ConnectionIO? io) -> void
    def deregister(socket, io)
      return unless io&.monitor || @selector.registered?(socket)

      @selector.deregister(socket)
      io.monitor = nil if io
    rescue IOError
    end

    # Registers a socket with the NIO selector and sets up timeout tracking.
    #
    # @param socket [TCPSocket] the socket to register
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def register(socket)
      state = @socket_to_state[socket]
      return unless state

      if state[:protocol] == :http2
        io = @id_to_io[state[:id]]
        io.reading = true
        update_monitor(state[:id], io)
      else
        @selector.register(socket, :r).value = socket
      end

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timeout_at = if state[:protocol] == :http2
        if state[:http2_preface_received]
          keepalive = @id_to_http2_keepalive[state[:id]]
          keepalive && (keepalive[:deadline] || now + @http2_keepalive_interval)
        else
          now + @first_data_timeout
        end
      elsif state[:persisted]
        now + @persistent_data_timeout
      elsif first_data_received?(state)
        now + @chunk_data_timeout
      else
        now + @first_data_timeout
      end
      track_timeout(state, timeout_at) if timeout_at
    end

    # Adds a connection deadline to the timeout tree.
    #
    # @param state [Hash] client connection state
    # @param timeout_at [Float] absolute monotonic expiry time
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] state, Float timeout_at) -> void
    def track_timeout(state, timeout_at)
      client = TimeoutClient.new(state)
      client.timeout_at = timeout_at
      @timeouts << client
      @id_to_timeout[state[:id]] = client
    end

    # Handles an expired connection deadline, sending an HTTP/2 keepalive
    # probe before closing the connection when its acknowledgement is late.
    #
    # @param client [TimeoutClient] expired client
    # @param now [Float] current monotonic timestamp
    # @return [void]
    #
    # @rbs (TimeoutClient client, Float now) -> void
    def handle_timeout(client, now)
      state = client.client_data
      id = state[:id]
      socket = @id_to_socket[id]
      return unless socket

      keepalive = @id_to_http2_keepalive[id] if state[:http2_preface_received]
      if keepalive && !keepalive[:deadline]
        keepalive[:deadline] = now + @http2_keepalive_timeout
        @id_to_writer[id].write_frames(socket, [keepalive[:frame]])
        track_timeout(state, keepalive[:deadline])
        return
      end

      socket.write(TIMEOUT_RESPONSE) rescue nil unless state[:protocol] == :http2
      cleanup(socket)
    end

    # Dispatches readable and writable events without allowing application
    # threads to take ownership of HTTP/2 sockets.
    #
    # @param monitor [NIO::Monitor] ready selector monitor
    # @return [void]
    #
    # @rbs (NIO::Monitor monitor) -> void
    def handle_monitor(monitor)
      socket = monitor.value
      state = @socket_to_state[socket]
      return unless state

      if state[:detached]
        handle_http1_detached_monitor(monitor, state[:id])
        return
      end

      unless state[:protocol] == :http2
        wakeup!(socket)
        return
      end

      id = state[:id]
      io = @id_to_io[id]
      return unless io

      wait = io.wait
      if (wait == :read && monitor.readable?) || (wait == :write && monitor.writable?)
        flush_output(id, io)
        return unless @id_to_socket.key?(id)
        return if io.wait == :read
        flush_http2_detached_bodies(id) unless io.detached.empty?
      end

      return unless io.reading && monitor.readable?

      io.reading = false
      update_monitor(id, io)
      to_client = @id_to_timeout.delete(id)
      @timeouts.delete!(to_client) if to_client
      read_and_queue_for_parse(socket, state)
    end

    # Handles readiness for an HTTP/1.x detached response.
    #
    # @param monitor [NIO::Monitor] ready selector monitor
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (NIO::Monitor monitor, Integer id) -> void
    def handle_http1_detached_monitor(monitor, id)
      socket = monitor.value
      io = @id_to_io[id]
      return unless io.is_a?(Http1IO)

      wait = io.wait
      if (wait == :read && monitor.readable?) || (wait == :write && monitor.writable?)
        flush_output(id, io)
        return unless @id_to_io.key?(id)

        flush_http1_detached_body(id) unless io.wait
      end

      return unless io.reading && monitor.readable?

      io.input << socket.read_nonblock(CHUNK_SIZE)
      io.reading = false
      update_monitor(id, io)
    rescue IO::WaitReadable
    rescue IO::WaitWritable
      wait_for_write(id, io, :write)
    rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      remove_connection(id)
    end

    # Handles socket wakeup by deregistering and queuing for processing.
    #
    # @param socket [TCPSocket] the socket that became ready
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def wakeup!(socket)
      @selector.deregister(socket)
      state = @socket_to_state[socket]
      to_client = @id_to_timeout.delete(state[:id])
      @timeouts.delete!(to_client) if to_client
      read_and_queue_for_parse(socket, state)
    end

    # Reads data from a socket and either queues it for parsing or
    # returns it to the selector.
    #
    # @param socket [TCPSocket] the socket to read from and queue
    # @param state [Hash] current connection state
    # @return [Hash, nil] updated state, if successful
    #
    # @rbs (TCPSocket socket, Hash[Symbol, untyped] state) -> Hash[Symbol, untyped]?
    def read_and_queue_for_parse(socket, state)
      data = begin
        socket.read_nonblock(CHUNK_SIZE)
      rescue IO::WaitReadable
        @queue << socket
        @selector.wakeup
        return
      rescue EOFError
        cleanup(socket)
        return
      end

      buffer = state[:buffer] ? state[:buffer].dup : String.new
      buffer << data

      while socket.respond_to?(:pending) && socket.pending.positive?
        buffer << socket.read_nonblock(socket.pending)
      end

      state = state.frozen? ? state.merge(buffer: buffer) : state.merge!(buffer: buffer)
      pool = state[:protocol] == :http2 ? @http2_ractor_pool : @http1_ractor_pool
      pool << Ractor.make_shareable(state)
    end

    # Cleans up a client connection by removing it from tracking and closing the socket.
    #
    # @param socket [TCPSocket] the socket to clean up
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def cleanup(socket)
      state = @socket_to_state.delete(socket)
      io = @id_to_io.delete(state[:id])
      deregister(socket, io)
      @id_to_socket.delete(state[:id])
      @id_to_writer.delete(state[:id])
      @id_to_flow_control.delete(state[:id])&.close
      @id_to_http2_last_stream.delete(state[:id])
      @id_to_http2_drain_stream.delete(state[:id])
      @id_to_http2_keepalive.delete(state[:id])
      if io.is_a?(Http1IO)
        if io.body
          io.body.finish(:connection_closed)
          io.body = nil
          detached_body_removed
        end
      elsif io
        io.detached.each_value do |body|
          body.finish(:connection_closed)
          detached_body_removed
        end
      end
      client = @id_to_timeout.delete(state[:id])
      @timeouts.delete!(client) if client
      clear_write_timeout(io)
      socket.close rescue nil
    end

    # Returns true when the request has been fully parsed.
    #
    # @param state [Hash] connection state
    # @return [Boolean] true if the request is complete
    #
    # @rbs (Hash[Symbol, untyped] state) -> bool
    def complete?(state)
      state[:complete]
    end

    # Checks if any data has been received for this connection.
    #
    # @param state [Hash] connection state
    # @return [Boolean] true if first data has been received
    #
    # @rbs (Hash[Symbol, untyped] state) -> bool
    def first_data_received?(state)
      complete?(state) || (state.dig(:parse_data, :parse_count) || 0) >= 1
    end
  end
end
