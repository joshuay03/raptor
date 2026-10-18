# frozen_string_literal: true

require "test_helper"

require "raptor/binder"
require "raptor/server"

module Raptor
  class TestReuseportBPF < TestCase
    def setup
      skip "BPF reuseport dispatch is not supported on this platform" unless ReuseportBPF.supported?
    end

    def teardown
      @listeners&.each(&:close)
      @binder&.close
    end

    def test_stopped_server_parks_its_worker_slot_at_unavailable
      bind_worker("tcp://127.0.0.1:0")
      ReuseportBPF.enable_load_reporting(0)
      reactor = Struct.new(:backlog).new(0)
      server = Server.new(reactor, nil, nil, nil, connection_options: {}, listeners: @listeners, worker_index: 0)

      server_thread = server.run
      sleep 0.01
      server.stop_accepting
      Timeout.timeout(1) { server_thread.join }

      assert_equal ReuseportBPF::UNAVAILABLE_LOAD, load(0)
    end

    def test_routing_to_an_unavailable_worker_leaves_its_load_parked
      bind_worker("tcp://127.0.0.1:0")
      ReuseportBPF.mark_unavailable(0)

      TCPSocket.open("127.0.0.1", @binder.server_port) { |client| client.write("GET / HTTP/1.1\r\n\r\n") }
      Timeout.timeout(1) { @listeners.first.accept.close }

      assert_equal ReuseportBPF::UNAVAILABLE_LOAD, load(0)
    end

    def test_routes_connections_on_every_tcp_bind_to_the_worker
      bind_worker("tcp://127.0.0.1:0", "tcp://127.0.0.2:0")

      @binder.listeners.zip(@listeners) do |shared_listener, worker_listener|
        10.times do
          address = shared_listener.local_address
          TCPSocket.open(address.ip_address, address.ip_port) { |client| client.write("GET / HTTP/1.1\r\n\r\n") }
        end

        assert_equal [10, 0], [worker_listener, shared_listener].map { |listener| accept_all(listener) }
      end
    end

    private

    def bind_worker(*bind_uris)
      @binder = Binder.new(bind_uris, socket_backlog: 16)
      ReuseportBPF.setup(1, @binder.listeners)
      @listeners = ReuseportBPF.create_worker_listeners(0, 16)
    end

    def load(worker_index)
      loads_fd = ReuseportBPF.instance_variable_get(:@loads_fd)
      LibBPFRuby.map_lookup(loads_fd, [worker_index + 1].pack("L"), 4).unpack1("L")
    end

    def accept_all(listener)
      count = 0
      while (socket = listener.accept_nonblock(exception: false)) != :wait_readable
        socket.close
        count += 1
      end
      count
    end
  end
end
