# frozen_string_literal: true

require "test_helper"

module Raptor
  class TestControlServer < TestCase
    parallelize_me!

    def test_requires_unix_url
      error = assert_raises(ArgumentError) do
        ControlServer.new("tcp://127.0.0.1:9293") { {} }
      end

      assert_equal "control_url must use unix://", error.message
    end

    def test_bind_removes_stale_socket
      UNIXServer.new(socket_path).close
      server = ControlServer.new("unix://#{socket_path}") { {} }
      server.bind

      socket = UNIXSocket.new(socket_path)

      assert_kind_of UNIXSocket, socket
    ensure
      socket&.close
      server&.shutdown
      File.delete(socket_path) rescue nil
    end

    def test_bind_rejects_active_socket
      listener = UNIXServer.new(socket_path)
      server = ControlServer.new("unix://#{socket_path}") { {} }

      error = assert_raises(RuntimeError) { server.bind }

      assert_equal "Socket #{socket_path.inspect} is already in use", error.message
    ensure
      listener&.close
      File.delete(socket_path) rescue nil
    end

    def test_shutdown_with_connected_client
      server = ControlServer.new("unix://#{socket_path}") { {} }
      server.bind
      server.start
      client = UNIXSocket.new(socket_path)

      Timeout.timeout(1) do
        Thread.pass until server.instance_variable_get(:@client)
        server.shutdown
      end

      assert_equal "", client.read
    ensure
      client&.close
      server&.shutdown
      File.delete(socket_path) rescue nil
    end

    private

    def socket_path
      "/tmp/raptor_test_control_server_#{Process.pid}_#{object_id}.sock"
    end
  end
end
