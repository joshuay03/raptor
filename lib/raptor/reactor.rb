# rbs_inline: enabled
# frozen_string_literal: true

require "nio"
require "red-black-tree"

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

    CHUNK_SIZE = 64 * 1024
    TIMEOUT_RESPONSE = "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    # @rbs @thread_pool: untyped
    # @rbs @http1_ractor_pool: untyped
    # @rbs @http2_ractor_pool: untyped
    # @rbs @first_data_timeout: Integer
    # @rbs @chunk_data_timeout: Integer
    # @rbs @persistent_data_timeout: Integer
    # @rbs @http2_keepalive_interval: Integer
    # @rbs @http2_keepalive_timeout: Integer
    # @rbs @selector: NIO::Selector
    # @rbs @queue: Queue[TCPSocket]
    # @rbs @timeouts: RedBlackTree[TimeoutClient]
    # @rbs @id_to_socket: Hash[Integer, TCPSocket]
    # @rbs @socket_to_state: Hash[TCPSocket, Hash[Symbol, untyped]]
    # @rbs @id_to_timeout: Hash[Integer, TimeoutClient]
    # @rbs @id_to_writer: Hash[Integer, untyped]
    # @rbs @id_to_flow_control: Hash[Integer, untyped]
    # @rbs @id_to_http2_last_stream: Hash[Integer, Integer]
    # @rbs @id_to_http2_drain_stream: Hash[Integer, Integer]
    # @rbs @id_to_http2_keepalive: Hash[Integer, Hash[Symbol, untyped]]

    # Creates a new Reactor instance.
    #
    # @param http1_ractor_pool [RactorPool] ractor pool for HTTP/1.x parsing
    # @param http2_ractor_pool [RactorPool, nil] ractor pool for HTTP/2 parsing, or nil when no listener supports HTTP/2
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param connection_options [Hash] per-connection timeout configuration
    # @option connection_options [Integer] :first_data_timeout timeout for initial data
    # @option connection_options [Integer] :chunk_data_timeout timeout for subsequent chunks
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
      @persistent_data_timeout = http1_options[:persistent_data_timeout]
      @http2_keepalive_interval = http2_options[:keepalive_interval]
      @http2_keepalive_timeout = http2_options[:keepalive_timeout]

      @selector = NIO::Selector.new
      @queue = Queue.new
      @timeouts = RedBlackTree.new

      @id_to_socket = {}
      @socket_to_state = {}
      @id_to_timeout = {}
      @id_to_writer = {}
      @id_to_flow_control = {}
      @id_to_http2_last_stream = {}
      @id_to_http2_drain_stream = {}
      @id_to_http2_keepalive = {}
    end

    # Starts the reactor's main event loop in a new thread. Runs until
    # the registration queue is closed and drained.
    #
    # @return [Thread] the thread running the reactor event loop
    #
    # @rbs () -> Thread
    def run
      Thread.new do
        Thread.current.name = "Reactor"

        until @queue.closed? && @queue.empty?
          begin
            timeout = @timeouts.min&.timeout(Process.clock_gettime(Process::CLOCK_MONOTONIC))
            @selector.select(timeout) do |monitor|
              wakeup!(monitor.value)
            end

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            expired = []
            @timeouts.traverse do |to_client|
              break unless to_client.timeout(now).zero?

              expired << to_client
            end

            expired.each do |to_client|
              @timeouts.delete!(to_client)
              id = to_client.client_data[:id]
              @id_to_timeout.delete(id)
              handle_timeout(to_client, now)
            end

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
        @timeouts.clear!
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
      if @http2_keepalive_interval.positive?
        @id_to_http2_keepalive[id] = {frame: ping_frame, payload: ping_payload}
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

    # Closes the socket for the given connection and drops all reactor
    # state associated with it.
    #
    # @param id [Integer] unique client identifier
    # @return [void]
    #
    # @rbs (Integer id) -> void
    def close_connection(id)
      socket = @id_to_socket.delete(id)
      return unless socket

      @socket_to_state.delete(socket)
      @id_to_writer.delete(id)
      @id_to_flow_control.delete(id)&.close
      @id_to_http2_last_stream.delete(id)
      @id_to_http2_drain_stream.delete(id)
      @id_to_http2_keepalive.delete(id)
      socket.close rescue nil
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

    # Registers a socket with the NIO selector and sets up timeout tracking.
    #
    # @param socket [TCPSocket] the socket to register
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def register(socket)
      @selector.register(socket, :r).value = socket

      state = @socket_to_state[socket]
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

      @selector.deregister(socket)
      socket.write(TIMEOUT_RESPONSE) rescue nil unless state[:protocol] == :http2
      cleanup(socket)
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
      @id_to_socket.delete(state[:id])
      @id_to_writer.delete(state[:id])
      @id_to_flow_control.delete(state[:id])&.close
      @id_to_http2_last_stream.delete(state[:id])
      @id_to_http2_drain_stream.delete(state[:id])
      @id_to_http2_keepalive.delete(state[:id])
      socket.close
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
