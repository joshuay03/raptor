# rbs_inline: enabled
# frozen_string_literal: true

require "socket"
require "uri"

module Raptor
  # Manages binding to network addresses and creating listening sockets.
  #
  # Binder handles parsing URI bind specifications, creating TCP, Unix, and SSL
  # server sockets, and managing socket options for optimal performance. It
  # supports binding to multiple addresses simultaneously.
  #
  # @example TCP binding
  #   binder = Binder.new(["tcp://0.0.0.0:3000", "tcp://[::1]:3000"])
  #   puts binder.addresses #=> ["0.0.0.0:3000", "[::1]:3000"]
  #   binder.close
  #
  # @example Unix socket binding
  #   binder = Binder.new(["unix:///tmp/raptor.sock"])
  #   puts binder.addresses #=> ["/tmp/raptor.sock"]
  #   binder.close
  #
  # @example SSL binding
  #   binder = Binder.new(["ssl://0.0.0.0:443?cert=/path/to.crt&key=/path/to.key"])
  #   puts binder.addresses #=> ["ssl://0.0.0.0:443"]
  #   binder.close
  #
  # @example Localhost binding
  #   binder = Binder.new(["tcp://localhost:8080"])
  #   # Binds to both IPv4 and IPv6 loopback addresses
  #
  class Binder
    SOCKET_BACKLOG = 1024

    class UnknownBindSchemeError < TypeError
      # @rbs (String scheme) -> void
      def initialize(scheme) = super("unknown scheme: #{scheme.inspect}")
    end

    # Wraps a TCPServer with an SSL context for accepting SSL connections.
    #
    # Holds both the underlying TCP server and the SSL context together so
    # the server thread can accept a TCP connection and then perform the SSL
    # handshake in a single coordinated step.
    #
    SslListener = Data.define(:tcp_server, :ssl_context) do
      # @rbs () -> TCPServer
      def to_io = tcp_server

      # @rbs () -> Addrinfo
      def local_address = tcp_server.local_address

      # @rbs () -> void
      def close = tcp_server.close
    end

    # @rbs @bind_uris: Array[String]
    # @rbs @socket_backlog: Integer
    # @rbs @inherited_fds: Hash[String, Array[Integer]]
    # @rbs @listeners: Array[TCPServer | UNIXServer | SslListener]
    # @rbs @uri_listeners: Hash[String, Array[TCPServer | UNIXServer | SslListener]]

    # Array of bind URIs.
    #
    # @return [Array<String>] the bind URIs
    attr_reader :bind_uris

    # Kernel listen() queue depth for TCP/SSL listeners.
    #
    # @return [Integer] the socket backlog
    attr_reader :socket_backlog

    # Array of listening sockets.
    #
    # @return [Array<TCPServer, UNIXServer, SslListener>] the server sockets
    attr_reader :listeners

    # Creates a new Binder with the specified bind URIs.
    #
    # Parses the provided bind URIs and creates listening sockets for each one.
    # Supports tcp://, unix://, and ssl:// schemes. Localhost is expanded to
    # all available loopback addresses (both IPv4 and IPv6). When `inherited_fds`
    # supplies file descriptors for a URI, the listener is reconstructed from
    # those FDs instead of binding fresh.
    #
    # @param bind_uris [Array<String>] array of URI strings to bind to
    # @param socket_backlog [Integer] kernel listen() queue depth for TCP/SSL listeners
    # @param inherited_fds [Hash{String => Array<Integer>}] inherited listener FDs keyed by bind URI
    # @return [void]
    # @raise [UnknownBindSchemeError] if a URI has an unsupported scheme
    #
    # @example
    #   binder = Binder.new(["tcp://0.0.0.0:3000", "unix:///tmp/raptor.sock"])
    #
    # @rbs (Array[String] bind_uris, ?socket_backlog: Integer, ?inherited_fds: Hash[String, Array[Integer]]) -> void
    def initialize(bind_uris, socket_backlog: SOCKET_BACKLOG, inherited_fds: {})
      @bind_uris = bind_uris
      @socket_backlog = socket_backlog
      @inherited_fds = inherited_fds
      @listeners = nil
      @uri_listeners = nil
      parse
    end

    # Returns the bound addresses as strings.
    #
    # TCP listeners are returned as "host:port", Unix listeners as the socket
    # path, and SSL listeners as "ssl://host:port".
    #
    # @return [Array<String>] address strings for each bound listener
    #
    # @example
    #   binder.addresses #=> ["127.0.0.1:3000", "/tmp/raptor.sock", "ssl://0.0.0.0:443"]
    #
    # @rbs () -> Array[String]
    def addresses
      @listeners.map do |listener|
        case listener
        when UNIXServer
          listener.path
        when SslListener
          address = listener.local_address
          "ssl://#{address.ip_address}:#{address.ip_port}"
        else
          address = listener.local_address
          "#{address.ip_address}:#{address.ip_port}"
        end
      end
    end

    # Returns the port number of the first TCP or SSL listener.
    #
    # Used to populate SERVER_PORT in the Rack environment. Returns 0
    # if no TCP or SSL listener is configured (e.g., Unix socket only).
    #
    # @return [Integer] the port number, or 0 if no TCP listener exists
    #
    # @rbs () -> Integer
    def server_port
      tcp_listener = @listeners.find { |listener| listener.is_a?(TCPServer) || listener.is_a?(SslListener) }
      return 0 unless tcp_listener

      tcp_listener.local_address.ip_port
    end

    # Closes all listening sockets.
    #
    # @return [void]
    #
    # @rbs () -> void
    def close
      @listeners.each(&:close)
    end

    # Returns the file descriptors of every listener, grouped by the bind URI
    # they were created from. The result is the payload to hand to a successor
    # process via the `inherited_fds:` constructor argument.
    #
    # @return [Hash{String => Array<Integer>}]
    #
    # @rbs () -> Hash[String, Array[Integer]]
    def inheritable_fds
      @uri_listeners.transform_values { |listeners| listeners.map { |listener| listener.to_io.fileno } }
    end

    # Clears the close-on-exec flag on every listener so the file descriptors
    # survive `Kernel.exec`.
    #
    # @return [void]
    #
    # @rbs () -> void
    def clear_close_on_exec
      @listeners.each { |listener| listener.to_io.close_on_exec = false }
    end

    private

    # Parses bind URIs and creates listening sockets, reusing inherited file
    # descriptors for URIs supplied in `@inherited_fds`.
    #
    # @return [void]
    # @raise [UnknownBindSchemeError] if a URI scheme is not supported
    #
    # @rbs () -> void
    def parse
      @uri_listeners = @bind_uris.to_h do |bind_uri|
        if filenos = @inherited_fds[bind_uri]
          [bind_uri, restore_listeners(bind_uri, filenos)]
        else
          [bind_uri, create_listeners(bind_uri)]
        end
      end
      @listeners = @uri_listeners.values.flatten
    end

    # Creates fresh listeners for the given bind URI.
    #
    # @param bind_uri [String] the URI to bind
    # @return [Array<TCPServer, UNIXServer, SslListener>]
    # @raise [UnknownBindSchemeError] if the URI scheme is not supported
    #
    # @rbs (String bind_uri) -> Array[TCPServer | UNIXServer | SslListener]
    def create_listeners(bind_uri)
      uri = URI.parse(bind_uri)
      case uri.scheme
      when "tcp"
        create_tcp_listeners(uri.host, uri.port)
      when "unix"
        create_unix_listeners(uri.path)
      when "ssl"
        create_ssl_listeners(uri.host, uri.port, URI.decode_www_form(uri.query || "").to_h)
      else
        raise UnknownBindSchemeError.new(uri.scheme)
      end
    end

    # Reconstructs listeners for the given bind URI from inherited file
    # descriptors.
    #
    # @param bind_uri [String] the URI the FDs were bound to
    # @param filenos [Array<Integer>] file descriptors to wrap
    # @return [Array<TCPServer, UNIXServer, SslListener>]
    # @raise [UnknownBindSchemeError] if the URI scheme is not supported
    #
    # @rbs (String bind_uri, Array[Integer] filenos) -> Array[TCPServer | UNIXServer | SslListener]
    def restore_listeners(bind_uri, filenos)
      uri = URI.parse(bind_uri)
      case uri.scheme
      when "tcp"
        filenos.map { |fileno| TCPServer.for_fd(fileno) }
      when "unix"
        register_unix_socket_cleanup(uri.path)
        filenos.map { |fileno| UNIXServer.for_fd(fileno) }
      when "ssl"
        ssl_context = build_ssl_context(URI.decode_www_form(uri.query || "").to_h)
        filenos.map { |fileno| SslListener.new(tcp_server: TCPServer.for_fd(fileno), ssl_context: ssl_context) }
      else
        raise UnknownBindSchemeError.new(uri.scheme)
      end
    end

    # Creates TCP server sockets for the given host and port.
    #
    # @param host [String, nil] hostname or IP address to bind to
    # @param port [Integer, nil] port number to bind to
    # @return [Array<TCPServer>] array containing the created TCP server socket(s)
    #
    # @rbs (String? host, Integer? port) -> Array[TCPServer]
    def create_tcp_listeners(host, port)
      if host == "localhost"
        return loopback_addresses.map { |address| create_tcp_listeners(address, port) }.flatten
      end

      host = host[1..-2] if host&.start_with?("[")

      addrinfo = Addrinfo.tcp(host, port)
      socket = Socket.new(addrinfo.afamily, Socket::SOCK_STREAM, 0)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true) if Socket.const_defined?(:SO_REUSEPORT)
      socket.bind(addrinfo)
      socket.listen(@socket_backlog)

      tcp_server = TCPServer.for_fd(socket.fileno)
      socket.autoclose = false
      [tcp_server]
    end

    # Creates a Unix domain server socket at the given path.
    #
    # Removes stale socket files left by crashed processes (when the socket
    # is not currently in use). Registers an at_exit hook to clean up the
    # socket file on normal process exit.
    #
    # @param path [String] filesystem path for the Unix socket
    # @return [Array<UNIXServer>] array containing the created Unix server socket
    # @raise [RuntimeError] if the socket path is already in active use
    #
    # @rbs (String path) -> Array[UNIXServer]
    def create_unix_listeners(path)
      if File.exist?(path)
        begin
          UNIXSocket.new(path).close
          raise "Socket #{path.inspect} is already in use"
        rescue Errno::ECONNREFUSED
          File.delete(path)
        end
      end

      register_unix_socket_cleanup(path)

      [UNIXServer.new(path)]
    end

    # Registers an `at_exit` hook that removes the Unix socket file on the
    # owning master's clean exit. Each call records the current process so
    # forked workers won't delete a socket their master still owns.
    #
    # @param path [String] filesystem path of the Unix socket
    # @return [void]
    #
    # @rbs (String path) -> void
    def register_unix_socket_cleanup(path)
      master_pid = Process.pid
      at_exit { File.delete(path) rescue nil if Process.pid == master_pid }
    end

    # Creates SSL server sockets for the given host, port, and SSL parameters.
    #
    # Wraps each TCP listener with an SSL context to produce SslListener objects.
    # The ssl_params hash must include "cert" and "key" entries pointing to the
    # certificate and private key files respectively.
    #
    # @param host [String, nil] hostname or IP address to bind to
    # @param port [Integer, nil] port number to bind to
    # @param ssl_params [Hash<String, String>] SSL options ("cert" and "key" paths)
    # @return [Array<SslListener>] array containing the created SSL listener(s)
    #
    # @rbs (String? host, Integer? port, Hash[String, String] ssl_params) -> Array[SslListener]
    def create_ssl_listeners(host, port, ssl_params)
      tcp_servers = create_tcp_listeners(host, port)
      ssl_context = build_ssl_context(ssl_params)
      tcp_servers.map { |tcp_server| SslListener.new(tcp_server: tcp_server, ssl_context: ssl_context) }
    end

    # Builds a frozen `OpenSSL::SSL::SSLContext` configured for HTTP/2 and
    # HTTP/1.1 ALPN negotiation.
    #
    # @param ssl_params [Hash<String, String>] SSL options ("cert" and "key" paths)
    # @return [OpenSSL::SSL::SSLContext]
    #
    # @rbs (Hash[String, String] ssl_params) -> OpenSSL::SSL::SSLContext
    def build_ssl_context(ssl_params)
      require "openssl"

      OpenSSL::SSL::SSLContext.new.tap do |ssl_context|
        ssl_context.cert = OpenSSL::X509::Certificate.new(File.read(ssl_params["cert"]))
        ssl_context.key = OpenSSL::PKey.read(File.read(ssl_params["key"]))
        ssl_context.alpn_protocols = ["h2", "http/1.1"]
        ssl_context.alpn_select_cb = ->(protocols) { protocols.include?("h2") ? "h2" : "http/1.1" }
        ssl_context.freeze
      end
    end

    # Returns all available loopback IP addresses.
    #
    # @return [Array<String>] unique loopback addresses (IPv4 and IPv6)
    #
    # @rbs () -> Array[String]
    def loopback_addresses
      Socket.ip_address_list.filter_map do |addrinfo|
        next unless addrinfo.ipv4_loopback? || addrinfo.ipv6_loopback?

        addrinfo.ip_address
      end.tap(&:uniq!)
    end
  end
end
