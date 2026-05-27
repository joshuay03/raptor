# frozen_string_literal: true

require "test_helper"

require "raptor/http2"

module Raptor
  class TestHttp2 < TestCase
    parallelize_me!

    GOAWAY_FRAME_TYPE = 0x7

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
      return nil unless goaway

      _last_stream_id, error_code = goaway.byteslice(9, 8).unpack("NN")
      error_code
    end
  end
end
