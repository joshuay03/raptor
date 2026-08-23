# frozen_string_literal: true

require "test_helper"

require "raptor/http1"

module Raptor
  class TestHttp1Parser < TestCase
    parallelize_me!

    def test_decode_chunked_single_chunk_complete
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\n\r\n")

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_multi_chunk_complete
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

      assert_equal "hello world", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_hex_size_upper_and_lower_case
      decoded, state = HttpParser.decode_chunked("Ff\r\n#{"x" * 255}\r\n0\r\n\r\n")

      assert_equal "x" * 255, decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_ignores_chunk_extension
      decoded, state = HttpParser.decode_chunked("5;name=value\r\nhello\r\n0\r\n\r\n")

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_consumes_trailer_section
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n")

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_incomplete_missing_terminator
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n")

      assert_equal "hello", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_incomplete_size_line
      decoded, state = HttpParser.decode_chunked("5")

      assert_equal "", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_incomplete_trailer_section
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\nX-Trailer: value\r\n")

      assert_equal "hello", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_malformed_non_hex_size
      _decoded, state = HttpParser.decode_chunked("z\r\nhello\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_malformed_empty_size_line
      _decoded, state = HttpParser.decode_chunked("\r\nhello\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_too_large_when_max_exceeded
      _decoded, state = HttpParser.decode_chunked("a\r\n0123456789\r\n0\r\n\r\n", 5)

      assert_equal :too_large, state
    end

    def test_decode_chunked_within_max_size
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\n\r\n", 5)

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_malformed_when_overhead_exceeds_limit
      bloated_extension = "A" * (HttpParser::MAX_CHUNK_OVERHEAD + 1)
      _decoded, state = HttpParser.decode_chunked("1;#{bloated_extension}\r\nX\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_empty_buffer_incomplete
      decoded, state = HttpParser.decode_chunked("")

      assert_equal "", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_nil_max_size_treated_as_unlimited
      body = "x" * 10_000
      decoded, state = HttpParser.decode_chunked("#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n", nil)

      assert_equal body, decoded
      assert_equal :complete, state
    end
  end
end
