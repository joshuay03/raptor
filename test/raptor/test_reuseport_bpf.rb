# frozen_string_literal: true

require "test_helper"

require "raptor/server"

module Raptor
  class TestReuseportBPF < TestCase
    def setup
      skip "BPF reuseport dispatch is not supported on this platform" unless ReuseportBPF.supported?

      @port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    end

    def teardown
      @listeners&.each(&:close)
    end

    def test_stopped_server_parks_its_worker_slot_at_unavailable
      ReuseportBPF.setup(1)
      @listeners = ReuseportBPF.create_worker_listeners(["tcp://127.0.0.1:#{@port}"], 0, 16)
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
      ReuseportBPF.setup(1)
      @listeners = ReuseportBPF.create_worker_listeners(["tcp://127.0.0.1:#{@port}"], 0, 16)
      ReuseportBPF.mark_unavailable(0)

      TCPSocket.open("127.0.0.1", @port) { |client| client.write("GET / HTTP/1.1\r\n\r\n") }
      Timeout.timeout(1) { @listeners.first.accept.close }

      assert_equal ReuseportBPF::UNAVAILABLE_LOAD, load(0)
    end

    private

    def load(worker_index)
      loads_fd = ReuseportBPF.instance_variable_get(:@loads_fd)
      LibBPFRuby.map_lookup(loads_fd, [worker_index + 1].pack("L"), 4).unpack1("L")
    end
  end
end
