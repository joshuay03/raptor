# rbs_inline: enabled
# frozen_string_literal: true

require "socket"
require "uri"

begin
  require "libbpf-ruby"
rescue LoadError
end

module Raptor
  # Routes incoming connections across worker processes to the worker with
  # the lowest reactor backlog.
  #
  # Auto-enabled on Linux when the `libbpf-ruby` gem is installed and the
  # BPF object file has been compiled. Falls back silently to standard
  # `SO_REUSEPORT` when either is missing. Raises when the kernel refuses
  # the BPF program. Wraps `tcp://` bindings only; non-tcp bindings are
  # left to the binder's shared listeners.
  #
  module ReuseportBPF
    LIBBPF_LOADED = !!defined?(LibBPFRuby)
    BPF_OBJECT_PATH = File.expand_path("../../ext/raptor_bpf/reuseport_select.bpf.o", __dir__)

    # Whether the preconditions for BPF-directed reuseport are met on this
    # platform. Does not imply that the kernel will accept the program.
    #
    # @return [Boolean]
    #
    # @rbs () -> bool
    def self.supported?
      LIBBPF_LOADED && File.exist?(BPF_OBJECT_PATH)
    end

    # Prepares BPF-directed routing for `worker_count` workers.
    #
    # Returns true when BPF-directed dispatch is active. Returns false
    # when the platform is unsupported. Raises when the kernel refuses
    # the program.
    #
    # @param worker_count [Integer] number of worker processes that will bind sockets
    # @return [Boolean]
    #
    # @rbs (Integer worker_count) -> bool
    def self.setup(worker_count)
      return false unless supported?

      @object = LibBPFRuby::Object.new(BPF_OBJECT_PATH)
      @program_fd = @object.program_fd("select_least_loaded")
      @socks_fd = @object.map_fd("socks")
      @loads_fd = @object.map_fd("loads")

      LibBPFRuby.map_update(@loads_fd, [0].pack("L"), [worker_count].pack("L"))
      true
    end

    # Returns tcp listening sockets bound and registered for `worker_index`.
    # Skips non-tcp bind URIs.
    #
    # @param bind_uris [Array<String>] the configured bind URIs
    # @param worker_index [Integer] slot index for this worker in the socks map
    # @param socket_backlog [Integer] kernel listen() queue depth
    # @return [Array<TCPServer>] the tcp listening sockets created for this worker
    #
    # @rbs (Array[String] bind_uris, Integer worker_index, Integer socket_backlog) -> Array[TCPServer]
    def self.create_worker_listeners(bind_uris, worker_index, socket_backlog)
      @load_key = [worker_index + 1].pack("L")
      @load_value = String.new("\x00\x00\x00\x00", encoding: Encoding::ASCII_8BIT)

      bind_uris.filter_map do |bind_uri|
        uri = URI(bind_uri)
        next unless uri.scheme == "tcp"

        host = uri.host
        host = host[1..-2] if host&.start_with?("[")

        addrinfo = Addrinfo.tcp(host, uri.port)
        socket = Socket.new(addrinfo.afamily, Socket::SOCK_STREAM, 0)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        socket.bind(addrinfo)
        socket.listen(socket_backlog)

        LibBPFRuby.sockmap_update(@socks_fd, [worker_index].pack("L"), socket)
        LibBPFRuby.attach_reuseport(socket, @program_fd)

        tcp_server = TCPServer.for_fd(socket.fileno)
        socket.autoclose = false
        tcp_server
      end
    end

    # Publishes this worker's current backlog to the BPF map.
    #
    # @param backlog [Integer] the worker's current reactor backlog
    # @return [void]
    #
    # @rbs (Integer backlog) -> void
    def self.update_load(backlog)
      @load_value.setbyte(0, backlog & 0xff)
      @load_value.setbyte(1, (backlog >> 8) & 0xff)
      @load_value.setbyte(2, (backlog >> 16) & 0xff)
      @load_value.setbyte(3, (backlog >> 24) & 0xff)
      LibBPFRuby.map_update(@loads_fd, @load_key, @load_value)
    end

    # Marks a worker's slot as unavailable by parking its load at the
    # sentinel maximum so the BPF program's least-loaded pick skips it.
    #
    # @param worker_index [Integer] slot index for the worker to mark
    # @return [void]
    #
    # @rbs (Integer worker_index) -> void
    def self.mark_unavailable(worker_index)
      return unless @loads_fd

      LibBPFRuby.map_update(@loads_fd, [worker_index + 1].pack("L"), [0xffffffff].pack("L"))
    end
  end
end
