# rbs_inline: enabled
# frozen_string_literal: true

require "socket"

module Raptor
  # Integration with systemd's service notification protocol and
  # socket-activation file descriptors.
  #
  module Systemd
    LISTEN_FDS_START = 3

    LISTEN_FDNAMES_ENV = "LISTEN_FDNAMES"
    LISTEN_FDS_ENV = "LISTEN_FDS"
    LISTEN_PID_ENV = "LISTEN_PID"
    NOTIFY_SOCKET_ENV = "NOTIFY_SOCKET"

    # Sends `message` to the systemd notification socket, returning true on
    # success and false when the socket is unset or the send fails.
    #
    # @param message [String] notify protocol payload, e.g. "READY=1"
    # @return [Boolean]
    #
    # @rbs (String message) -> bool
    def self.notify(message)
      socket_path = ENV[NOTIFY_SOCKET_ENV]
      return false if socket_path.nil? || socket_path.empty?

      address = if socket_path.start_with?("@")
        Socket.pack_sockaddr_un("\0#{socket_path[1..]}")
      else
        Socket.pack_sockaddr_un(socket_path)
      end

      socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_DGRAM, 0)
      socket.send(message, 0, address)
      true
    rescue SystemCallError, IOError
      false
    ensure
      socket&.close
    end

    # Returns the file descriptors passed in via socket activation, or an
    # empty array when systemd has not exported any.
    #
    # @return [Array<Integer>]
    #
    # @rbs () -> Array[Integer]
    def self.listen_fds
      return [] unless ENV[LISTEN_PID_ENV]&.to_i == Process.pid

      count = ENV[LISTEN_FDS_ENV]&.to_i || 0
      Array.new(count) { |index| LISTEN_FDS_START + index }
    end

    # Clears the socket-activation environment variables so children don't
    # act on stale values.
    #
    # @return [void]
    #
    # @rbs () -> void
    def self.clear_listen_env
      ENV.delete(LISTEN_FDNAMES_ENV)
      ENV.delete(LISTEN_FDS_ENV)
      ENV.delete(LISTEN_PID_ENV)
    end
  end
end
