# rbs_inline: enabled
# frozen_string_literal: true

require "socket"
require "uri"

module Raptor
  # Binds `tcp://`, `unix://`, and `ssl://` URIs to listening sockets and
  # holds them for the server. Reconstructs listeners from inherited file
  # descriptors when provided (systemd socket activation, hot restart).
  #
  class Binder
    SOCKET_BACKLOG = 1024

    class UnknownBindSchemeError < TypeError
      # @rbs (String scheme) -> void
      def initialize(scheme) = super("unknown scheme: #{scheme.inspect}")
    end

    # Pairs a TCPServer with the SSL context to use for accepted
    # connections.
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

    # Returns the array of bind URIs.
    #
    # @return [Array<String>]
    attr_reader :bind_uris

    # Returns the kernel `listen()` queue depth for TCP/SSL listeners.
    #
    # @return [Integer]
    attr_reader :socket_backlog

    # Returns the array of listening sockets.
    #
    # @return [Array<TCPServer, UNIXServer, SslListener>]
    attr_reader :listeners

    # Creates a new Binder and binds each URI. `localhost` expands to both
    # IPv4 and IPv6 loopback; when `inherited_fds` supplies file descriptors
    # for a URI the listener is rebuilt from those instead of binding fresh.
    #
    # @param bind_uris [Array<String>] array of URI strings to bind to
    # @param socket_backlog [Integer] kernel listen() queue depth for TCP/SSL listeners
    # @param inherited_fds [Hash{String => Array<Integer>}] inherited listener FDs keyed by bind URI
    # @return [void]
    # @raise [UnknownBindSchemeError] if a URI has an unsupported scheme
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

    # Returns the bound addresses as strings: TCP as `host:port`, Unix as
    # the socket path, SSL as `ssl://host:port`.
    #
    # @return [Array<String>]
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

    # Returns the port of the first TCP or SSL listener, or 0 when none
    # is configured.
    #
    # @return [Integer]
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

    # Returns the file descriptors of every listener, grouped by bind URI.
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
        uri = URI.parse(bind_uri)
        filenos = @inherited_fds[bind_uri]
        [bind_uri, filenos ? restore_listeners(uri, filenos) : create_listeners(uri)]
      end
      @listeners = @uri_listeners.values.flatten
    end

    # Creates fresh listeners for the given URI.
    #
    # @param uri [URI] the parsed bind URI
    # @return [Array<TCPServer, UNIXServer, SslListener>]
    # @raise [UnknownBindSchemeError] if the URI scheme is not supported
    #
    # @rbs (URI::Generic uri) -> Array[TCPServer | UNIXServer | SslListener]
    def create_listeners(uri)
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

    # Reconstructs listeners for the given URI from inherited file
    # descriptors.
    #
    # @param uri [URI] the parsed bind URI the FDs were bound to
    # @param filenos [Array<Integer>] file descriptors to wrap
    # @return [Array<TCPServer, UNIXServer, SslListener>]
    # @raise [UnknownBindSchemeError] if the URI scheme is not supported
    #
    # @rbs (URI::Generic uri, Array[Integer] filenos) -> Array[TCPServer | UNIXServer | SslListener]
    def restore_listeners(uri, filenos)
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
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      socket.bind(addrinfo)
      socket.listen(@socket_backlog)

      tcp_server = TCPServer.for_fd(socket.fileno)
      socket.autoclose = false
      [tcp_server]
    end

    # Creates a Unix domain server socket at the given path. Removes stale
    # socket files left by crashed processes, and cleans the file up on
    # the master's clean exit.
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

    # Creates SSL server sockets for the given host and port.
    #
    # @param host [String, nil] hostname or IP address to bind to
    # @param port [Integer, nil] port number to bind to
    # @param ssl_params [Hash<String, String>] SSL options (`cert` and `key` file paths)
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
