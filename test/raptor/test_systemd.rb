# frozen_string_literal: true

require "test_helper"

require "raptor/systemd"

module Raptor
  class TestSystemd < TestCase
    def test_notify_sends_message_to_notify_socket_path
      socket_path = "/tmp/raptor_test_sd_notify_#{Process.pid}_#{object_id}.sock"
      File.delete(socket_path) rescue nil
      receiver = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM, 0)
      receiver.bind(Socket.pack_sockaddr_un(socket_path))

      with_env("NOTIFY_SOCKET" => socket_path) do
        assert Systemd.notify("READY=1")

        message, _addr = receiver.recvfrom_nonblock(1024)

        assert_equal "READY=1", message
      end
    ensure
      receiver&.close
      File.delete(socket_path) rescue nil
    end

    def test_notify_returns_false_when_socket_unset
      with_env("NOTIFY_SOCKET" => nil) do
        refute Systemd.notify("READY=1")
      end
    end

    def test_listen_fds_ignores_mismatched_listen_pid
      with_env("LISTEN_PID" => (Process.pid + 1).to_s, "LISTEN_FDS" => "2") do
        assert_empty Systemd.listen_fds
      end
    end

    def test_listen_fds_returns_fd_range_for_current_pid
      with_env("LISTEN_PID" => Process.pid.to_s, "LISTEN_FDS" => "3") do
        assert_equal [3, 4, 5], Systemd.listen_fds
      end
    end

    def test_clear_listen_env_deletes_socket_activation_vars
      with_env("LISTEN_PID" => "1", "LISTEN_FDS" => "2", "LISTEN_FDNAMES" => "main:tls") do
        Systemd.clear_listen_env

        assert_nil ENV["LISTEN_PID"]
        assert_nil ENV["LISTEN_FDS"]
        assert_nil ENV["LISTEN_FDNAMES"]
      end
    end

    private

    def with_env(values)
      original = values.to_h { |key, _value| [key, ENV[key]] }
      ENV.update(values)
      yield
    ensure
      ENV.update(original) if original
    end
  end
end
