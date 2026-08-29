# frozen_string_literal: true

require "test_helper"

require "socket"
require "timeout"

require "raptor/http2"

module Raptor
  class TestHttp2 < TestCase
    parallelize_me!

    GOAWAY_FRAME_TYPE = 0x7
    RST_STREAM_FRAME_TYPE = 0x3

    def test_dispatch_cleans_thread_and_fiber_locals
      handler = Http2.allocate
      handler.instance_variable_set(:@clean_thread_locals, true)
      handler.instance_variable_set(:@clean_fiber_locals, true)
      values = []
      handler.define_singleton_method(:perform_stream_request) do |*|
        values << [
          Thread.current[:raptor_test_fiber],
          Thread.current.thread_variable_get(:raptor_test_thread),
          Fiber[:raptor_test_storage],
        ]
        Thread.current[:raptor_test_fiber] = "fiber"
        Thread.current.thread_variable_set(:raptor_test_thread, "thread")
        Fiber[:raptor_test_storage] = "storage"
      end

      2.times do
        handler.send(:dispatch_stream_request, nil, nil, nil, 1, [], "", remote_addr: "127.0.0.1")
      end

      assert_equal [[nil, nil, nil], [nil, nil, nil]], values
    end

    def test_flow_control_acquire_caps_grant_at_max_frame_size
      flow_control = Http2::FlowControl.new

      assert_equal Http2::MAX_FRAME_SIZE, flow_control.acquire(1, 100_000)
    end

    def test_flow_control_acquire_blocks_until_stream_window_replenished
      flow_control = Http2::FlowControl.new
      drain_windows(flow_control, stream_id: 1)

      blocked = Thread.new { flow_control.acquire(1, 100) }
      sleep 0.05
      assert blocked.alive?

      flow_control.add_connection_window(40)
      flow_control.add_stream_window(1, 40)

      assert_equal 40, blocked.value
    end

    def test_flow_control_set_initial_stream_window_shifts_existing_streams
      flow_control = Http2::FlowControl.new
      flow_control.acquire(1, 100)
      flow_control.set_initial_stream_window(Http2::DEFAULT_WINDOW_SIZE + 1000)

      flow_control.add_connection_window(Http2::DEFAULT_WINDOW_SIZE)

      assert_equal Http2::MAX_FRAME_SIZE, flow_control.acquire(1, Http2::DEFAULT_WINDOW_SIZE + 900)
    end

    def test_writer_write_frames_does_not_block_indefinitely_on_full_send_buffer
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

    def test_process_frames_rejects_even_client_stream_id
      result = process_frames_with(headers_frame(stream_id: 2))

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_non_monotonic_stream_id
      result = process_frames_with(headers_frame(stream_id: 3) + headers_frame(stream_id: 1))

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_data_for_unopened_stream
      parser = Http2Parser.new
      data_frame = parser.build_frame(:data, Http2::FLAG_END_STREAM, 1, "body")

      result = process_frames_with(data_frame)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_accepts_monotonic_odd_stream_ids
      result = process_frames_with(headers_frame(stream_id: 1) + headers_frame(stream_id: 3))

      refute result[:close_connection]
      assert_equal 2, result[:completed_requests].size
    end

    def test_process_frames_assembles_continuation_frames
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      half = encoded.bytesize / 2
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM, 1, encoded.byteslice(0, half))
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 1, encoded.byteslice(half..-1))

      result = process_frames_with(headers + continuation)

      refute result[:close_connection]
      assert_equal 1, result[:completed_requests].size
      assert_equal [":method", ":path", ":scheme", ":authority"], result[:completed_requests].first[:headers].map(&:first)
    end

    def test_process_frames_rejects_continuation_without_pending_headers
      parser = Http2Parser.new
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 1, "")

      result = process_frames_with(continuation)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_continuation_on_wrong_stream
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, 0, 1, encoded)
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 3, "")

      result = process_frames_with(headers + continuation)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_data_while_expecting_continuation
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, 0, 1, encoded)
      data = parser.build_frame(:data, Http2::FLAG_END_STREAM, 1, "body")

      result = process_frames_with(headers + data)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_resets_stream_with_missing_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_resets_stream_with_unknown_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"], [":unknown", "y"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_resets_stream_with_pseudo_header_after_regular
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], ["x-custom", "y"], [":authority", "x"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_extracts_window_updates
      parser = Http2Parser.new
      connection_update = parser.build_frame(:window_update, 0, 0, [1000].pack("N"))
      stream_update = parser.build_frame(:window_update, 0, 5, [500].pack("N"))

      result = process_frames_with(connection_update + stream_update)

      assert_equal [[0, 1000], [5, 500]], result[:window_updates]
    end

    def test_process_frames_extracts_peer_initial_window_size_from_settings
      parser = Http2Parser.new
      settings_payload = parser.build_settings(initial_window_size: 32_768)
      settings = parser.build_frame(:settings, 0, 0, settings_payload)

      result = process_frames_with(settings)

      assert_equal 32_768, result[:peer_initial_window_size]
    end

    private

    def process_frames_with(frame_bytes)
      Http2.process_frames(
        id: 1,
        buffer: Http2Parser.connection_preface + frame_bytes,
        remote_addr: "127.0.0.1",
        url_scheme: "https",
        protocol: :http2
      )
    end

    def headers_frame(stream_id:)
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, stream_id, encoded)
    end

    def goaway_error_code(result)
      goaway = result[:outgoing_frames].find { |frame| frame.getbyte(3) == GOAWAY_FRAME_TYPE }
      return unless goaway

      _last_stream_id, error_code = goaway.byteslice(9, 8).unpack("NN")
      error_code
    end

    def rst_stream_error_code(result, stream_id:)
      rst = result[:outgoing_frames].find do |frame|
        frame.getbyte(3) == RST_STREAM_FRAME_TYPE && frame.byteslice(5, 4).unpack1("N") == stream_id
      end
      return unless rst

      rst.byteslice(9, 4).unpack1("N")
    end

    def drain_windows(flow_control, stream_id:)
      remaining = Http2::DEFAULT_WINDOW_SIZE
      remaining -= flow_control.acquire(stream_id, remaining) while remaining > 0
    end
  end
end
