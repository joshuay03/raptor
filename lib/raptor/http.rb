# rbs_inline: enabled
# frozen_string_literal: true

require "rack"

require_relative "version"

module Raptor
  # Shared HTTP utilities used by both the HTTP/1.x and HTTP/2 handlers:
  # Rack env keys that aren't provided by Rack itself and low-level socket
  # writing.
  #
  module Http
    WRITE_TIMEOUT = 5

    CONTENT_LENGTH = "CONTENT_LENGTH"
    CONTENT_TYPE = "CONTENT_TYPE"
    HTTP_VERSION = "HTTP_VERSION"
    REMOTE_ADDR = "REMOTE_ADDR"
    SERVER_SOFTWARE = "SERVER_SOFTWARE"
    SERVER_SOFTWARE_VALUE = "Raptor/#{Raptor::VERSION}".freeze

    class WriteError < StandardError
      # @rbs () -> String
      def message = "could not write response"
    end

    # Writes `string` in full, retrying on partial writes. Bounded by
    # `timeout` so a slow client can't pin the writing thread.
    #
    # @param socket [TCPSocket] the socket to write to
    # @param string [String] the data to write
    # @param timeout [Integer] seconds to wait for the socket to become writable on each partial write
    # @return [void]
    # @raise [WriteError] if the socket is not writable within the timeout or raises IOError
    #
    # @rbs (TCPSocket socket, String string, ?timeout: Integer) -> void
    def self.socket_write(socket, string, timeout: WRITE_TIMEOUT)
      bytes = 0
      byte_size = string.bytesize

      while bytes < byte_size
        begin
          bytes += socket.write_nonblock(bytes.zero? ? string : string.byteslice(bytes..-1))
        rescue IO::WaitWritable
          raise WriteError unless socket.wait_writable(timeout)
          retry
        rescue IOError
          raise WriteError
        end
      end
    end
  end
end
