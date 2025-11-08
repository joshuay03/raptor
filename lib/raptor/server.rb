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
  # applied only to TCP sockets, and SSL handshakes are performed synchronously
  # before handing the connection to the reactor.
  #
  # For SSL connections, ALPN negotiation determines the protocol. HTTP/2
  # connections are added to the reactor with initial SETTINGS and processed
  # through the same ractor pool pipeline as HTTP/1.1 connections.
  #
  # @example
  #   binder = Binder.new(["tcp://0.0.0.0:3000"])
  #   reactor = Reactor.new(thread_pool, ractor_pool, client_options: {})
  #   server = Server.new(binder, reactor, thread_pool)
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
    # @rbs @running: AtomicBoolean

    # Creates a new Server instance.
    #
    # @param binder [Binder] the binder managing listening sockets
    # @param reactor [Reactor] the reactor for handling client connections
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @return [void]
    #
    # @rbs (Binder binder, Reactor reactor, AtomicThreadPool thread_pool) -> void
    def initialize(binder, reactor, thread_pool)
      @binder = binder
      @reactor = reactor
      @thread_pool = thread_pool
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
    # For SSL connections with h2 negotiated via ALPN, the server sends
    # initial SETTINGS and adds the connection to the reactor as an HTTP/2
    # connection. All other connections follow the HTTP/1.1 path.
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

      url_scheme = HTTP_SCHEME
      client = tcp_client

      if listener.is_a?(Binder::SslListener)
        url_scheme = HTTPS_SCHEME
        begin
          ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_client, listener.ssl_context)
          ssl_socket.sync_close = true
          ssl_socket.accept
          client = ssl_socket
        rescue OpenSSL::SSL::SSLError => error
          warn "SSL handshake failed: #{error.message}"
          tcp_client.close rescue nil
          return
        end

        if ssl_socket.alpn_protocol == H2_PROTOCOL
          ssl_socket.write(Http2.build_server_settings_frame) rescue nil

          reactor.add(
            id: ssl_socket.object_id,
            socket: ssl_socket,
            remote_addr: remote_addr,
            url_scheme: HTTPS_SCHEME,
            protocol: :http2
          )

          return
        end
      end

      reactor.add(
        id: client.object_id,
        socket: client,
        remote_addr: remote_addr,
        url_scheme: url_scheme
      )
    end
  end
end
