# frozen_string_literal: true

require "test_helper"

require "socket"

require "raptor/systemd"

module Raptor
  class TestSystemd < TestCase
    def test_notify_sends_message_to_notify_socket_path
      socket_path = "/tmp/raptor_sd_notify_#{Process.pid}_#{object_id}.sock"
      File.delete(socket_path) rescue nil
      receiver = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM, 0)
      receiver.bind(Socket.pack_sockaddr_un(socket_path))

      original = ENV["NOTIFY_SOCKET"]
      ENV["NOTIFY_SOCKET"] = socket_path

      assert Systemd.notify("READY=1")
      message, _addr = receiver.recvfrom_nonblock(1024)
      assert_equal "READY=1", message
    ensure
      ENV["NOTIFY_SOCKET"] = original
      receiver&.close
      File.delete(socket_path) rescue nil
    end

    def test_notify_returns_false_when_socket_unset
      original = ENV["NOTIFY_SOCKET"]
      ENV.delete("NOTIFY_SOCKET")

      refute Systemd.notify("READY=1")
    ensure
      ENV["NOTIFY_SOCKET"] = original
    end

    def test_listen_fds_ignores_mismatched_listen_pid
      original_pid = ENV["LISTEN_PID"]
      original_fds = ENV["LISTEN_FDS"]
      ENV["LISTEN_PID"] = (Process.pid + 1).to_s
      ENV["LISTEN_FDS"] = "2"

      assert_equal [], Systemd.listen_fds
    ensure
      ENV["LISTEN_PID"] = original_pid
      ENV["LISTEN_FDS"] = original_fds
    end

    def test_listen_fds_returns_fd_range_for_current_pid
      original_pid = ENV["LISTEN_PID"]
      original_fds = ENV["LISTEN_FDS"]
      ENV["LISTEN_PID"] = Process.pid.to_s
      ENV["LISTEN_FDS"] = "3"

      assert_equal [3, 4, 5], Systemd.listen_fds
    ensure
      ENV["LISTEN_PID"] = original_pid
      ENV["LISTEN_FDS"] = original_fds
    end

    def test_clear_listen_env_deletes_socket_activation_vars
      original_pid = ENV["LISTEN_PID"]
      original_fds = ENV["LISTEN_FDS"]
      original_fdnames = ENV["LISTEN_FDNAMES"]
      ENV["LISTEN_PID"] = "1"
      ENV["LISTEN_FDS"] = "2"
      ENV["LISTEN_FDNAMES"] = "main:tls"

      Systemd.clear_listen_env

      assert_nil ENV["LISTEN_PID"]
      assert_nil ENV["LISTEN_FDS"]
      assert_nil ENV["LISTEN_FDNAMES"]
    ensure
      ENV["LISTEN_PID"] = original_pid
      ENV["LISTEN_FDS"] = original_fds
      ENV["LISTEN_FDNAMES"] = original_fdnames
    end
  end
end
