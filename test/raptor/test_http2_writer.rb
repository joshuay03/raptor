# frozen_string_literal: true

require "test_helper"

require "socket"
require "timeout"

require "raptor/http2"

module Raptor
  class TestHttp2Writer < TestCase
    parallelize_me!

    def test_write_frames_does_not_block_indefinitely_on_full_send_buffer
      server = TCPServer.new("127.0.0.1", 0)
      client = TCPSocket.new("127.0.0.1", server.addr[1])
      accepted = server.accept

      client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)
      accepted.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1024)

      writer = Http2::Writer.new(write_timeout: Http::WRITE_TIMEOUT)
      big_frame = "x" * (1024 * 1024)

      Timeout.timeout(Http::WRITE_TIMEOUT + 5) do
        writer.write_frames(client, [big_frame])
      end

      pass
    ensure
      client&.close
      accepted&.close
      server&.close
    end
  end
end
