# rbs_inline: enabled
# frozen_string_literal: true

require "nio"
require "red-black-tree"

module Raptor
  # High-performance I/O reactor for managing client connections and timeouts.
  #
  # Reactor uses NIO selectors for efficient I/O multiplexing and implements
  # client timeouts using a red-black tree for O(log n) timeout management.
  # It coordinates between ractor pools for CPU-intensive HTTP parsing and
  # thread pools for blocking operations, and provides backlog metrics that
  # the server uses for backpressure control to prevent overload.
  #
  # @example
  #   reactor = Reactor.new(ractor_pool, thread_pool, client_options: {
  #     first_data_timeout: 30,
  #     chunk_data_timeout: 10
  #   })
  #   reactor.run
  #   reactor.add(id: client.object_id, socket: client)
  #   # ... later
  #   reactor.shutdown
  #
  class Reactor
    # A client connection node ordered by absolute expiry time so the
    # soonest-to-expire is always at the tree's minimum.
    #
    class TimeoutClient < RedBlackTree::Node
      # @rbs attr_accessor timeout_at: Float
      attr_accessor :timeout_at

      # Semantic alias for the inherited `data` slot.
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
    # @rbs @ractor_pool: untyped
    # @rbs @client_options: Hash[Symbol, Integer]
    # @rbs @selector: NIO::Selector
    # @rbs @queue: Queue[TCPSocket]
    # @rbs @timeouts: RedBlackTree[TimeoutClient]
    # @rbs @id_to_socket: Hash[Integer, TCPSocket]
    # @rbs @socket_to_state: Hash[TCPSocket, Hash[Symbol, untyped]]
    # @rbs @id_to_timeout: Hash[Integer, TimeoutClient]
    # @rbs @id_to_writer: Hash[Integer, untyped]
    # @rbs @id_to_flow_control: Hash[Integer, untyped]

    # Creates a new Reactor instance.
    #
    # @param ractor_pool [RactorPool] ractor pool for HTTP parsing
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param client_options [Hash] timeout configuration options
    # @option client_options [Integer] :first_data_timeout timeout for initial data
    # @option client_options [Integer] :chunk_data_timeout timeout for subsequent chunks
    # @option client_options [Integer] :persistent_data_timeout timeout for keep-alive connections
    # @return [void]
    #
    # @rbs (untyped ractor_pool, untyped thread_pool, client_options: Hash[Symbol, Integer]) -> void
    def initialize(ractor_pool, thread_pool, client_options:)
      @ractor_pool = ractor_pool
      @thread_pool = thread_pool
      @client_options = client_options

      @selector = NIO::Selector.new
      @queue = Queue.new
      @timeouts = RedBlackTree.new

      @id_to_socket = {}
      @socket_to_state = {}
      @id_to_timeout = {}
      @id_to_writer = {}
      @id_to_flow_control = {}
    end

    # Starts the reactor's main event loop in a new thread.
    #
    # The event loop handles I/O events, processes timeouts, manages
    # the registration queue, and controls server connection acceptance.
    # It continues until the queue is closed and emptied.
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
              break unless to_client.timeout(now) == 0

              expired << to_client
            end

            expired.each do |to_client|
              @timeouts.delete!(to_client)
              id = to_client.client_data[:id]
              @id_to_timeout.delete(id)
              socket = @id_to_socket[id]
              next unless socket

              @selector.deregister(socket)
              socket.write(TIMEOUT_RESPONSE) rescue nil
              cleanup(socket)
            end

            until @queue.empty?
              register(@queue.pop)
            end
          rescue => error
            Log.rescued_error(error)
          end
        end

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

    # Updates the state of an existing client connection.
    #
    # Called when an incomplete HTTP request needs to be
    # re-registered with the reactor for further processing.
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

    # Re-registers a kept-alive connection for the next request cycle.
    #
    # Called after successfully writing a response when keep-alive is active.
    # Resets the connection state and re-queues the socket in the selector
    # using the persistent data timeout.
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
    # Used by HTTP/2 connections where the socket remains registered across
    # multiple stream requests.
    #
    # @param id [Integer] unique client identifier
    # @return [TCPSocket, nil] the socket, if found
    #
    # @rbs (Integer id) -> TCPSocket?
    def socket_for(id)
      @id_to_socket[id]
    end

    # Returns the writer object associated with a given connection, if one
    # was supplied when the connection was added. Used by protocol handlers
    # that need to coordinate concurrent socket writes.
    #
    # @param id [Integer] unique client identifier
    # @return [Object, nil] the writer, if found
    #
    # @rbs (Integer id) -> untyped?
    def writer_for(id)
      @id_to_writer[id]
    end

    # Returns the flow controller associated with a given connection, if one
    # was supplied when the connection was added. Used by HTTP/2 stream
    # dispatchers to honour the peer's flow-control windows.
    #
    # @param id [Integer] unique client identifier
    # @return [Object, nil] the flow controller, if found
    #
    # @rbs (Integer id) -> untyped?
    def flow_control_for(id)
      @id_to_flow_control[id]
    end

    # Updates connection state for an HTTP/2 connection after frame processing.
    #
    # Re-registers the socket with the selector for further reads and stores
    # the updated HPACK table and stream states.
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

    # Closes the socket for the given connection and drops all reactor state
    # associated with it. Used to terminate HTTP/2 connections after sending
    # a GOAWAY frame.
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
      @id_to_flow_control.delete(id)
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
      client = TimeoutClient.new(state)
      timeout = if state[:persisted]
        @client_options[:persistent_data_timeout]
      elsif first_data_received?(state)
        @client_options[:chunk_data_timeout]
      else
        @client_options[:first_data_timeout]
      end
      client.timeout_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @timeouts << client
      @id_to_timeout[state[:id]] = client
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
      @timeouts.delete!(to_client)
      read_and_queue_for_parse(socket, state)
    end

    # Reads data from a socket and either queues it for parsing,
    # or for selector registration.
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

      while socket.respond_to?(:pending) && socket.pending > 0
        buffer << socket.read_nonblock(socket.pending)
      end

      state = state.frozen? ? state.merge(buffer: buffer) : state.merge!(buffer: buffer)
      @ractor_pool << Ractor.make_shareable(state)
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
      @id_to_flow_control.delete(state[:id])
      socket.close
    end

    # Checks if a request is complete i.e., processable.
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
