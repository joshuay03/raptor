# rbs_inline: enabled
# frozen_string_literal: true

require "socket"

require "atomic-ruby/atomic_boolean"

module Raptor
  # High-performance HTTP server that accepts connections and dispatches them.
  #
  # Server manages the main accept loop, handling incoming client connections from
  # bound sockets. It uses IO.select for efficient polling and implements automatic
  # load balancing by checking reactor backlog before accepting connections,
  # providing natural backpressure based on system capacity.
  #
  # Supports TCP, Unix domain, and SSL listeners transparently. TCP_NODELAY is
  # applied only to TCP sockets, and SSL handshakes are offloaded to the thread
  # pool so a slow client cannot block the server thread.
  #
  # For HTTP/1.1 connections the first request is parsed inline on the server
  # thread and dispatched directly to the thread pool, falling back to the
  # reactor only when more data is needed. For HTTP/2 connections (negotiated
  # via ALPN) the server sends initial SETTINGS and registers the connection
  # with the reactor for frame processing through the ractor pool.
  #
  # @example
  #   binder = Binder.new(["tcp://0.0.0.0:3000"])
  #   reactor = Reactor.new(thread_pool, ractor_pool, client_options: {})
  #   request = Request.new(app, 3000)
  #   server = Server.new(binder, reactor, thread_pool, request, client_options: { first_data_timeout: 30 })
  #   server.run
  #   # ... later
  #   server.shutdown
  #
  class Server
    HTTP_SCHEME = "http"
    HTTPS_SCHEME = "https"
    H2_PROTOCOL = "h2"

    # @rbs @binder: Binder
    # @rbs @reactor: Reactor
    # @rbs @thread_pool: AtomicThreadPool
    # @rbs @request: Request
    # @rbs @client_options: Hash[Symbol, untyped]
    # @rbs @running: AtomicBoolean

    # Creates a new Server instance.
    #
    # @param binder [Binder] the binder managing listening sockets
    # @param reactor [Reactor] the reactor for handling client connections
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param request [Request] the HTTP/1.1 request handler
    # @param client_options [Hash] client timeout configuration, used to bound TLS handshakes
    # @return [void]
    #
    # @rbs (Binder binder, Reactor reactor, AtomicThreadPool thread_pool, Request request, client_options: Hash[Symbol, untyped]) -> void
    def initialize(binder, reactor, thread_pool, request, client_options:)
      @binder = binder
      @reactor = reactor
      @thread_pool = thread_pool
      @request = request
      @client_options = client_options
      @running = AtomicBoolean.new(true)
    end

    # Starts the server's main accept loop in a new thread.
    #
    # The accept loop polls listening sockets for ready connections and accepts
    # them when system capacity allows. It checks reactor backlog before accepting
    # to prevent overload. This provides natural load balancing across multiple
    # worker processes through backpressure control.
    #
    # @return [Thread] the thread running the accept loop
    #
    # @rbs () -> Thread
    def run
      Thread.new(@binder.listeners, @reactor, @running) do |server_sockets, reactor, running|
        Thread.current.name = self.class.name

        while running.true?
          begin
            ready_servers, _, _ = IO.select(server_sockets, nil, nil, 1)
          rescue IOError, Errno::EBADF
            break
          end

          next unless ready_servers
          next if @reactor.backlog >= (@thread_pool.size * 1.2).ceil

          ready_servers.each do |listener|
            accept_connection(listener, reactor)
          end
        end
      end
    end

    # Gracefully shuts down the server.
    #
    # Stops accepting new connections and closes all listening sockets.
    # The server thread will exit after handling any in-flight accept operations.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      @running.make_false
      @binder.close
    end

    private

    # Accepts a connection from the given listener and dispatches it.
    #
    # For SSL listeners the TLS handshake is offloaded to the thread pool so
    # a slow client cannot block the server thread. For SSL connections with
    # h2 negotiated via ALPN, the server sends initial SETTINGS and adds the
    # connection to the reactor as an HTTP/2 connection. All other connections
    # follow the HTTP/1.1 path.
    #
    # @param listener [TCPServer, UNIXServer, Binder::SslListener] the ready listener
    # @param reactor [Reactor] the reactor to dispatch connections to
    # @return [void]
    #
    # @rbs (TCPServer | UNIXServer | Binder::SslListener listener, Reactor reactor) -> void
    def accept_connection(listener, reactor)
      tcp_client = begin
        listener.is_a?(Binder::SslListener) ? listener.tcp_server.accept_nonblock : listener.accept_nonblock
      rescue IO::WaitReadable
        return
      end

      if tcp_client.is_a?(TCPSocket)
        tcp_client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        remote_addr = tcp_client.remote_address.ip_address
      else
        remote_addr = "127.0.0.1"
      end

      if listener.is_a?(Binder::SslListener)
        @thread_pool << proc do
          dispatch_ssl_connection(listener, tcp_client, remote_addr, reactor)
        end
        return
      end

      @request.eager_accept(
        tcp_client,
        tcp_client.object_id,
        reactor,
        @thread_pool,
        remote_addr,
        HTTP_SCHEME
      )
    end

    # Performs the TLS handshake for an accepted SSL connection and dispatches
    # it through the HTTP/2 or HTTP/1.1 path. The handshake is bounded by
    # `:first_data_timeout` so a slow client cannot pin a worker thread.
    #
    # @param listener [Binder::SslListener] the SSL listener that accepted the connection
    # @param tcp_client [TCPSocket] the accepted TCP socket
    # @param remote_addr [String] the client's IP address
    # @param reactor [Reactor] the reactor to dispatch the connection to
    # @return [void]
    #
    # @rbs (Binder::SslListener listener, TCPSocket tcp_client, String remote_addr, Reactor reactor) -> void
    def dispatch_ssl_connection(listener, tcp_client, remote_addr, reactor)
      ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_client, listener.ssl_context)
      ssl_socket.sync_close = true
      return unless perform_ssl_handshake(ssl_socket)

      if ssl_socket.alpn_protocol == H2_PROTOCOL
        ssl_socket.write(Http2.build_server_settings_frame) rescue nil

        reactor.add(
          id: ssl_socket.object_id,
          socket: ssl_socket,
          remote_addr: remote_addr,
          url_scheme: HTTPS_SCHEME,
          protocol: :http2,
          writer: Http2::Writer.new,
          flow_control: Http2::FlowControl.new
        )

        return
      end

      @request.eager_accept(
        ssl_socket,
        ssl_socket.object_id,
        reactor,
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
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @client_options[:first_data_timeout]

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
        warn "SSL handshake failed: #{error.message}"
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

      warn "SSL handshake timed out"
      ssl_socket.close rescue nil
      false
    end
  end
end
