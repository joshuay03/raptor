# rbs_inline: enabled
# frozen_string_literal: true

require "socket"

require "atomic-ruby/atomic_boolean"

require_relative "reuseport_bpf"

module Raptor
  # Accepts client connections and dispatches them into the request
  # pipeline. Skips acceptance when the reactor backlog is high so an
  # overloaded process leaves connections for peers that can absorb
  # them (via shared `SO_REUSEPORT` listeners).
  #
  # Supports TCP, Unix, and SSL listeners. SSL handshakes are offloaded
  # to the thread pool so a slow client can't pin the server thread.
  # For HTTP/1.1 the first request is parsed inline and dispatched
  # straight to the thread pool; HTTP/2 (negotiated via ALPN) is
  # registered with the reactor for frame processing.
  #
  # @example
  #   binder = Binder.new(["tcp://0.0.0.0:3000"])
  #   reactor = Reactor.new(ractor_pool, thread_pool, connection_options: {}, http1_options: {})
  #   http1 = Http1.new(app, 3000)
  #   http2 = Http2.new(app, 3000)
  #   server = Server.new(binder, reactor, thread_pool, http1, http2, connection_options: { first_data_timeout: 30 }, listeners: binder.listeners)
  #   server.run
  #   # ... later
  #   server.shutdown
  #
  class Server
    HTTP_SCHEME = "http"
    HTTPS_SCHEME = "https"

    H2_PROTOCOL = "h2"

    DEFAULT_REMOTE_ADDR = "127.0.0.1"
    DEFAULT_SERVER_NAME = "localhost"

    MIN_BACKPRESSURE_THRESHOLD = 64

    # @rbs @binder: Binder
    # @rbs @listeners: Array[TCPServer | UNIXServer | Binder::SslListener]
    # @rbs @reactor: Reactor
    # @rbs @thread_pool: AtomicThreadPool
    # @rbs @http1: Http1
    # @rbs @http2: Http2
    # @rbs @first_data_timeout: Integer
    # @rbs @drain_accept_queue: bool
    # @rbs @bpf_active: bool
    # @rbs @running: AtomicBoolean

    # Creates a new Server instance.
    #
    # @param binder [Binder] the binder managing listening sockets
    # @param reactor [Reactor] the reactor for handling client connections
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param http1 [Http1] the HTTP/1.1 handler
    # @param http2 [Http2] the HTTP/2 handler (provides the initial SETTINGS frame)
    # @param connection_options [Hash] per-connection timeout configuration, used to bound TLS handshakes
    # @param listeners [Array] the per-worker listeners this server accepts on
    # @param drain_accept_queue [Boolean] whether to drain the kernel accept queue on shutdown
    # @param worker_index [Integer, nil] the slot index for BPF load reporting
    # @return [void]
    #
    # @rbs (Binder binder, Reactor reactor, AtomicThreadPool thread_pool, Http1 http1, Http2 http2, connection_options: Hash[Symbol, untyped], listeners: Array[untyped], ?drain_accept_queue: bool, ?worker_index: Integer?) -> void
    def initialize(binder, reactor, thread_pool, http1, http2, connection_options:, listeners:, drain_accept_queue: false, worker_index: nil)
      @binder = binder
      @listeners = listeners
      @reactor = reactor
      @thread_pool = thread_pool
      @http1 = http1
      @http2 = http2
      @first_data_timeout = connection_options[:first_data_timeout]
      @drain_accept_queue = drain_accept_queue
      @bpf_active = !!worker_index
      @running = AtomicBoolean.new(true)
    end

    # Starts the server's main accept loop in a new thread.
    #
    # The accept loop polls listening sockets for ready connections and accepts
    # them when the reactor backlog is under the backpressure threshold. On
    # Linux with BPF-directed dispatch active, a companion thread publishes
    # this worker's backlog to the BPF map.
    #
    # @return [Thread] the thread running the accept loop
    #
    # @rbs () -> Thread
    def run
      spawn_load_reporter if @bpf_active

      Thread.new do
        Thread.current.name = "Server"

        backpressure_threshold = [(@thread_pool.size * 1.2).ceil, MIN_BACKPRESSURE_THRESHOLD].max

        while @running.true?
          begin
            ready_servers, _, _ = IO.select(@listeners, nil, nil, 1)
          rescue IOError, Errno::EBADF
            break
          end

          next unless ready_servers
          next if @reactor.backlog >= backpressure_threshold

          ready_servers.each { |listener| accept_connection(listener) }
        end
      end
    end

    # Gracefully shuts down the server.
    #
    # Stops accepting new connections and closes all listening sockets. When
    # `drain_accept_queue` is enabled, dispatches every connection already in
    # the kernel accept queue before closing the listeners.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      @running.make_false
      drain_accept_queue if @drain_accept_queue
      @listeners.each(&:close)
    end

    private

    # Starts a background thread that publishes this worker's reactor
    # backlog to the BPF map for load-aware dispatch.
    #
    # @return [void]
    #
    # @rbs () -> void
    def spawn_load_reporter
      Thread.new do
        Thread.current.name = "Load Reporter"

        while @running.true?
          ReuseportBPF.update_load(@reactor.backlog)
          sleep 0.01
        end
      end
    end

    # Dispatches every connection already in the kernel accept queue for each
    # listener until all are drained.
    #
    # @return [void]
    #
    # @rbs () -> void
    def drain_accept_queue
      loop do
        accepted = false
        @listeners.each { |listener| accepted = true if accept_connection(listener) }
        break unless accepted
      end
    end

    # Accepts a connection from the given listener and dispatches it.
    #
    # For SSL listeners the TLS handshake is offloaded to the thread pool so
    # a slow client cannot block the server thread. For SSL connections with
    # h2 negotiated via ALPN, the server sends initial SETTINGS and adds the
    # connection to the reactor as an HTTP/2 connection. All other connections
    # follow the HTTP/1.1 path.
    #
    # @param listener [TCPServer, UNIXServer, Binder::SslListener] the ready listener
    # @return [Boolean] true if a connection was accepted, false if the listener had nothing to dispatch
    #
    # @rbs (TCPServer | UNIXServer | Binder::SslListener listener) -> bool
    def accept_connection(listener)
      tcp_client = begin
        listener.is_a?(Binder::SslListener) ? listener.tcp_server.accept_nonblock : listener.accept_nonblock
      rescue IO::WaitReadable
        return false
      end

      if tcp_client.is_a?(TCPSocket)
        tcp_client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        remote_addr = tcp_client.remote_address.ip_address
      else
        remote_addr = DEFAULT_REMOTE_ADDR
      end

      if listener.is_a?(Binder::SslListener)
        @thread_pool << proc do
          dispatch_ssl_connection(listener, tcp_client, remote_addr)
        end
        return true
      end

      @http1.eager_accept(
        tcp_client,
        tcp_client.object_id,
        @reactor,
        @thread_pool,
        remote_addr,
        HTTP_SCHEME
      )
      true
    end

    # Performs the TLS handshake for an accepted SSL connection and dispatches
    # it through the HTTP/2 or HTTP/1.1 path. The handshake is bounded by
    # `:first_data_timeout` so a slow client cannot pin a worker thread.
    #
    # @param listener [Binder::SslListener] the SSL listener that accepted the connection
    # @param tcp_client [TCPSocket] the accepted TCP socket
    # @param remote_addr [String] the client's IP address
    # @return [void]
    #
    # @rbs (Binder::SslListener listener, TCPSocket tcp_client, String remote_addr) -> void
    def dispatch_ssl_connection(listener, tcp_client, remote_addr)
      ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_client, listener.ssl_context)
      ssl_socket.sync_close = true
      return unless perform_ssl_handshake(ssl_socket)

      if ssl_socket.alpn_protocol == H2_PROTOCOL
        ssl_socket.write(@http2.initial_settings_frame) rescue nil

        @reactor.add(
          id: ssl_socket.object_id,
          socket: ssl_socket,
          remote_addr: remote_addr,
          url_scheme: HTTPS_SCHEME,
          protocol: :http2,
          writer: @http2.create_writer,
          flow_control: Http2::FlowControl.new
        )

        return
      end

      @http1.eager_accept(
        ssl_socket,
        ssl_socket.object_id,
        @reactor,
        @thread_pool,
        remote_addr,
        HTTPS_SCHEME
      )
    end

    # Drives a non-blocking SSL handshake to completion, bounded by the
    # configured first-data timeout. Returns true on success, false on
    # timeout or SSL error.
    #
    # @param ssl_socket [OpenSSL::SSL::SSLSocket] the SSL socket to hand-shake
    # @return [Boolean] true if the handshake completed
    #
    # @rbs (OpenSSL::SSL::SSLSocket ssl_socket) -> bool
    def perform_ssl_handshake(ssl_socket)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @first_data_timeout

      begin
        ssl_socket.accept_nonblock
        true
      rescue IO::WaitReadable
        return false unless wait_for_handshake(ssl_socket, deadline, :read)

        retry
      rescue IO::WaitWritable
        return false unless wait_for_handshake(ssl_socket, deadline, :write)

        retry
      rescue OpenSSL::SSL::SSLError => error
        Log.rescued_error(error)
        ssl_socket.close rescue nil
        false
      end
    end

    # Waits up to `deadline` for the socket to become ready for the next step
    # of the SSL handshake. Closes the socket and returns false on timeout.
    #
    # @param ssl_socket [OpenSSL::SSL::SSLSocket] the SSL socket
    # @param deadline [Float] absolute monotonic deadline
    # @param direction [Symbol] either `:read` or `:write`
    # @return [Boolean] true if the socket became ready before the deadline
    #
    # @rbs (OpenSSL::SSL::SSLSocket ssl_socket, Float deadline, Symbol direction) -> bool
    def wait_for_handshake(ssl_socket, deadline, direction)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ready = if remaining <= 0
        false
      elsif direction == :read
        ssl_socket.wait_readable(remaining)
      else
        ssl_socket.wait_writable(remaining)
      end
      return true if ready

      Log.warn "SSL handshake timed out"
      ssl_socket.close rescue nil
      false
    end
  end
end
