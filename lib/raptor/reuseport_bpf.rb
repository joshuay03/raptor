# rbs_inline: enabled
# frozen_string_literal: true

require "socket"

begin
  require "libbpf-ruby"
rescue LoadError
end

module Raptor
  # Routes incoming connections across worker processes using two-choice
  # load sampling, atomically reserving the selected slot before routing.
  #
  # Auto-enabled on Linux when the `libbpf-ruby` gem is installed and the
  # BPF object file has been compiled. Falls back silently to standard
  # `SO_REUSEPORT` when either is missing, or when there are more workers
  # or listeners than the BPF maps have slots for. Raises when the kernel
  # refuses the BPF program. Wraps `tcp://` bindings only; non-tcp bindings
  # are left to the binder's shared listeners.
  #
  module ReuseportBPF
    LIBBPF_LOADED = !!defined?(LibBPFRuby)
    BPF_OBJECT_PATH = File.expand_path("../../ext/raptor_bpf/reuseport_select.bpf.o", __dir__)
    TCP_INFO_UNACKED_OFFSET = 24
    UNAVAILABLE_LOAD = 0xffffffff
    MAX_WORKERS = 64
    MAX_LISTENERS = 16

    # @rbs self.@object: untyped
    # @rbs self.@program_fd: Integer
    # @rbs self.@socks_fd: Integer
    # @rbs self.@loads_fd: Integer?
    # @rbs self.@shared_listeners: Array[TCPServer]
    # @rbs self.@worker_listeners: Array[TCPServer]
    # @rbs self.@load_key: String
    # @rbs self.@load_value: String
    # @rbs self.@accepted_load_value: String

    # Returns true when the preconditions for BPF-directed reuseport are
    # met on this platform.
    #
    # @return [Boolean]
    #
    # @rbs () -> bool
    def self.supported?
      LIBBPF_LOADED && File.exist?(BPF_OBJECT_PATH)
    end

    # Prepares BPF-directed routing for `worker_count` workers across the
    # addresses `shared_listeners` are bound to.
    #
    # Returns true when BPF-directed dispatch is active. Returns false
    # when the platform is unsupported or the counts exceed the map slots.
    # Raises when the kernel refuses the program.
    #
    # @param worker_count [Integer] number of worker processes that will bind sockets
    # @param shared_listeners [Array<TCPServer>] the binder's tcp listeners
    # @return [Boolean]
    #
    # @rbs (Integer worker_count, Array[TCPServer] shared_listeners) -> bool
    def self.setup(worker_count, shared_listeners)
      return false unless supported? && worker_count <= MAX_WORKERS && shared_listeners.length <= MAX_LISTENERS

      @shared_listeners = shared_listeners

      @object = LibBPFRuby::Object.new(BPF_OBJECT_PATH)
      @program_fd = @object.program_fd("select_less_loaded")
      @socks_fd = @object.map_fd("socks")
      @loads_fd = @object.map_fd("loads")

      LibBPFRuby.map_update(@loads_fd, [0].pack("L"), [worker_count].pack("L"))
      true
    end

    # Creates this worker's BPF-routed listeners at the shared listeners'
    # bound addresses, including resolved `localhost` addresses and ports
    # assigned by the kernel for port 0.
    #
    # @param worker_index [Integer] slot index for this worker in the socks map
    # @param socket_backlog [Integer] kernel listen() queue depth
    # @return [Array<TCPServer>] the tcp listening sockets created for this worker
    #
    # @rbs (Integer worker_index, Integer socket_backlog) -> Array[TCPServer]
    def self.create_worker_listeners(worker_index, socket_backlog)
      @worker_listeners = @shared_listeners.each_with_index.map do |shared_listener, listener_index|
        addrinfo = shared_listener.local_address
        socket = Socket.new(addrinfo.afamily, Socket::SOCK_STREAM, 0)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_DEFER_ACCEPT, 1)
        socket.bind(addrinfo)
        socket.listen(socket_backlog)

        LibBPFRuby.sockmap_update(@socks_fd, [listener_index * MAX_WORKERS + worker_index].pack("L"), socket)
        LibBPFRuby.attach_reuseport(socket, @program_fd)

        tcp_server = TCPServer.for_fd(socket.fileno)
        socket.autoclose = false
        tcp_server
      end
    end

    # Prepares this worker's load-reporting slot so subsequent
    # {update_load} calls can publish its backlog.
    #
    # @param worker_index [Integer] slot index for this worker
    # @return [void]
    #
    # @rbs (Integer worker_index) -> void
    def self.enable_load_reporting(worker_index)
      @load_key = [worker_index + 1].pack("L")
      @load_value = String.new("\x00\x00\x00\x00", encoding: Encoding::ASCII_8BIT)
      @accepted_load_value = String.new("\x00\x00\x00\x00", encoding: Encoding::ASCII_8BIT)
    end

    # Publishes this worker's load to the BPF map.
    #
    # @param backlog [Integer] the worker's current reactor backlog
    # @return [void]
    #
    # @rbs (Integer backlog) -> void
    def self.update_load(backlog)
      load = backlog + accept_queue_length
      @load_value.setbyte(0, load & 0xff)
      @load_value.setbyte(1, (load >> 8) & 0xff)
      @load_value.setbyte(2, (load >> 16) & 0xff)
      @load_value.setbyte(3, (load >> 24) & 0xff)
      LibBPFRuby.map_update(@loads_fd, @load_key, @load_value)
    end

    # Publishes an accept-side load estimate. This uses a separate value
    # buffer because the server and load reporter call into the map from
    # different threads.
    #
    # @param backlog [Integer] the estimated backlog after accepting a socket
    # @return [void]
    #
    # @rbs (Integer backlog) -> void
    def self.update_accepted_load(backlog)
      load = backlog + accept_queue_length
      @accepted_load_value.setbyte(0, load & 0xff)
      @accepted_load_value.setbyte(1, (load >> 8) & 0xff)
      @accepted_load_value.setbyte(2, (load >> 16) & 0xff)
      @accepted_load_value.setbyte(3, (load >> 24) & 0xff)
      LibBPFRuby.map_update(@loads_fd, @load_key, @accepted_load_value)
    end

    # Parks a worker's load at the maximum so BPF favors other workers.
    # Stop publishing its load first to avoid overwriting the sentinel.
    #
    # @param worker_index [Integer] slot index for the worker to mark
    # @return [void]
    #
    # @rbs (Integer worker_index) -> void
    def self.mark_unavailable(worker_index)
      LibBPFRuby.map_update(@loads_fd, [worker_index + 1].pack("L"), [UNAVAILABLE_LOAD].pack("L"))
    end

    # Returns the number of connections waiting in this worker's accept
    # queues, which the reactor backlog cannot see.
    #
    # @return [Integer]
    #
    # @rbs () -> Integer
    def self.accept_queue_length
      @worker_listeners.sum { |listener| listener.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_INFO).data.unpack1("L", offset: TCP_INFO_UNACKED_OFFSET) }
    end
    private_class_method :accept_queue_length
  end
end
