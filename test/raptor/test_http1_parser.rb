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

    def test_illegal_header_key_rejects_delimiters_and_control_bytes
      assert HttpParser.illegal_header_key?("bad key")
      assert HttpParser.illegal_header_key?("x:y")
      assert HttpParser.illegal_header_key?("x(y)")
      assert HttpParser.illegal_header_key?("x\x7Fy")
      refute HttpParser.illegal_header_key?("content-type")
      refute HttpParser.illegal_header_key?("X-Custom_Header")
    end

    def test_illegal_header_value_rejects_control_bytes_except_tab
      assert HttpParser.illegal_header_value?("has\x00null")
      assert HttpParser.illegal_header_value?("has\x0Anewline")
      assert HttpParser.illegal_header_value?("has\x0Dreturn")
      refute HttpParser.illegal_header_value?("has\ttab")
      refute HttpParser.illegal_header_value?("text/plain; charset=utf-8")
      refute HttpParser.illegal_header_value?("has\x7Fdel")
    end

    def test_format_headers_appends_lowercased_name_and_value
      buffer = +""
      HttpParser.format_headers(buffer, "content-type" => "text/plain", "content-length" => "5")

      assert_equal "content-type: text/plain\r\ncontent-length: 5\r\n", buffer
    end

    def test_format_headers_expands_array_values_into_separate_lines
      buffer = +""
      HttpParser.format_headers(buffer, "set-cookie" => ["a=1", "b=2"])

      assert_equal "set-cookie: a=1\r\nset-cookie: b=2\r\n", buffer
    end

    def test_format_headers_splits_newline_joined_values
      buffer = +""
      HttpParser.format_headers(buffer, "set-cookie" => "a=1\nb=2")

      assert_equal "set-cookie: a=1\r\nset-cookie: b=2\r\n", buffer
    end

    def test_format_headers_skips_illegal_keys_and_values
      buffer = +""
      HttpParser.format_headers(buffer, "bad key" => "v", "content-type" => "bad\x00value", "content-length" => "5")

      assert_equal "content-length: 5\r\n", buffer
    end

    def test_format_headers_skips_empty_values
      buffer = +""
      HttpParser.format_headers(buffer, "x-empty" => "", "content-length" => "0")

      assert_equal "content-length: 0\r\n", buffer
    end

    def test_format_headers_coerces_non_string_values
      buffer = +""
      HttpParser.format_headers(buffer, "content-length" => 42)

      assert_equal "content-length: 42\r\n", buffer
    end

    def test_format_headers_appends_to_existing_buffer_content
      buffer = +"HTTP/1.1 200 OK\r\n"
      HttpParser.format_headers(buffer, "content-length" => "5")

      assert_equal "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n", buffer
    end

    def test_chunked_encode_appends_hex_size_crlf_chunk_crlf
      buffer = +""
      HttpParser.chunked_encode(buffer, "hello")

      assert_equal "5\r\nhello\r\n", buffer
    end

    def test_chunked_encode_uses_lowercase_hex
      buffer = +""
      HttpParser.chunked_encode(buffer, "x" * 255)

      assert_equal "ff\r\n#{"x" * 255}\r\n", buffer
    end

    def test_chunked_encode_skips_empty_chunk
      buffer = +"prefix"
      HttpParser.chunked_encode(buffer, "")

      assert_equal "prefix", buffer
    end

    def test_chunked_encode_appends_to_existing_buffer_content
      buffer = +"HTTP/1.1 200 OK\r\n\r\n"
      HttpParser.chunked_encode(buffer, "hi")

      assert_equal "HTTP/1.1 200 OK\r\n\r\n2\r\nhi\r\n", buffer
    end
  end
end
