# rbs_inline: enabled
# frozen_string_literal: true

require "rack"

require_relative "version"
require_relative "raptor_native"

module Raptor
  # Shared HTTP utilities used by both the HTTP/1.x and HTTP/2 handlers:
  # Rack env keys that aren't provided by Rack itself, low-level socket
  # writing, and Common Log Format access-log formatting.
  #
  module Http
    WRITE_TIMEOUT = 5

    CONTENT_LENGTH = "CONTENT_LENGTH"
    CONTENT_TYPE = "CONTENT_TYPE"
    HTTP_VERSION = "HTTP_VERSION"
    REMOTE_ADDR = "REMOTE_ADDR"
    REQUEST_URI = "REQUEST_URI"
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

    # Writes `strings` in full via a single `writev(2)` syscall when possible,
    # falling back to per-string writes on partial results. Bounded by
    # `timeout` so a slow client can't pin the writing thread.
    #
    # @param socket [TCPSocket] the socket to write to
    # @param strings [Array<String>] the buffers to write in order
    # @param timeout [Integer] seconds to wait for the socket to become writable on each retry
    # @return [void]
    # @raise [WriteError] if the socket is not writable within the timeout or raises IOError
    #
    # @rbs (TCPSocket socket, Array[String] strings, ?timeout: Integer) -> void
    def self.socket_writev(socket, strings, timeout: WRITE_TIMEOUT)
      total = strings.sum(&:bytesize)
      return if total.zero?

      begin
        written = Raptor::VectorIO.writev_nonblock(socket, strings)
      rescue IO::WaitWritable
        raise WriteError unless socket.wait_writable(timeout)
        retry
      rescue IOError
        raise WriteError
      end

      return if written == total

      offset = 0
      strings.each do |string|
        size = string.bytesize
        if written >= offset + size
          offset += size
        else
          start = written - offset
          socket_write(socket, start.zero? ? string : string.byteslice(start..-1), timeout: timeout)
          offset += size
          written = offset
        end
      end
    end

    # Writes a Common Log Format entry to `io`. Write failures are silently
    # ignored.
    #
    # @param io [IO] the destination IO
    # @param env [Hash] the Rack environment
    # @param status [Integer] the response status code
    # @param size [String] the response body size in bytes, or `-` if unknown
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (IO io, Hash[String, untyped] env, Integer status, String size, String remote_addr) -> void
    def self.write_access_log(io, env, status, size, remote_addr)
      timestamp = Time.now.strftime("%d/%b/%Y:%H:%M:%S %z")
      method = env[Rack::REQUEST_METHOD]
      query = env[Rack::QUERY_STRING]
      path = query.empty? ? env[Rack::PATH_INFO] : "#{env[Rack::PATH_INFO]}?#{query}"
      protocol = env[Rack::SERVER_PROTOCOL]

      io.puts(%(#{remote_addr} - - [#{timestamp}] "#{method} #{path} #{protocol}" #{status} #{size})) rescue nil
    end
  end
end
