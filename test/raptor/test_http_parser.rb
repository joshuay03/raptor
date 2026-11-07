# frozen_string_literal: true

require "test_helper"

require "raptor/http1"

module Raptor
  class TestHttpParser < TestCase
    parallelize_me!

    def test_header_normalization_preserves_raw_names_and_prefers_hyphens
      fields = ["X_Auth_Token: untrusted", "x-auth-token: trusted", "X-Auth-Token: second"]
      [fields, fields.reverse].each do |headers|
        request = "GET / HTTP/1.1\r\nHost: example.com\r\n#{headers.join("\r\n")}\r\n\r\n"
        original = request.dup
        env = {}
        HttpParser.new.execute(env, request, 0)

        expected = headers.first == fields.first ? "trusted, second" : "second, trusted"
        assert_equal expected, env["HTTP_X_AUTH_TOKEN"]
        assert_equal original, request
      end

      env = {}
      HttpParser.new.execute(env, "GET / HTTP/1.0\r\nX_Auth_Token: legacy\r\n\r\n", 0)
      assert_equal "legacy", env["HTTP_X_AUTH_TOKEN"]
    end

    def test_rejects_underscore_framing_aliases
      ["Content_Length: 1", "Transfer_Encoding: chunked"].each do |header|
        assert_raises(HttpParserError) do
          HttpParser.new.execute({}, "POST / HTTP/1.1\r\nHost: x\r\n#{header}\r\n\r\n", 0)
        end
      end
    end

    def test_decode_chunked_decodes_single_chunk
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\n\r\n")

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_decodes_multiple_chunks
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

      assert_equal "hello world", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_validates_payload_delimiters
      ["XX", "\n\n", "\rX", "X"].each do |delimiter|
        _decoded, state = HttpParser.decode_chunked("1\r\nA#{delimiter}0\r\n\r\n")

        assert_equal :malformed, state, delimiter.inspect
      end
    end

    def test_decode_chunked_waits_for_split_delimiters_and_preserves_pipeline
      body = "3\r\nA\r\n\r\n1\r\nB\r\n0\r\n\r\n"
      (0...body.bytesize).each do |split|
        _decoded, state = HttpParser.decode_chunked(body.byteslice(0, split))

        assert_equal :incomplete, state, "split at #{split}"
      end

      decoded, state, consumed = HttpParser.decode_chunked(body + "GET / HTTP/1.0\r\n\r\n")

      assert_equal "A\r\nB", decoded
      assert_equal :complete, state
      assert_equal body.bytesize, consumed
    end

    def test_decode_chunked_accepts_mixed_case_hex_size
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

    def test_decode_chunked_accepts_body_within_max_size
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\n\r\n", 5)

      assert_equal "hello", decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_treats_nil_max_size_as_unlimited
      body = "x" * 10_000
      decoded, state = HttpParser.decode_chunked("#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n", nil)

      assert_equal body, decoded
      assert_equal :complete, state
    end

    def test_decode_chunked_returns_incomplete_for_empty_buffer
      decoded, state = HttpParser.decode_chunked("")

      assert_equal "", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_returns_incomplete_for_partial_size_line
      decoded, state = HttpParser.decode_chunked("5")

      assert_equal "", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_returns_incomplete_without_terminating_chunk
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n")

      assert_equal "hello", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_returns_incomplete_for_unterminated_trailers
      decoded, state = HttpParser.decode_chunked("5\r\nhello\r\n0\r\nX-Trailer: value\r\n")

      assert_equal "hello", decoded
      assert_equal :incomplete, state
    end

    def test_decode_chunked_returns_malformed_for_non_hex_size
      _decoded, state = HttpParser.decode_chunked("z\r\nhello\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_returns_malformed_for_empty_size_line
      _decoded, state = HttpParser.decode_chunked("\r\nhello\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_returns_malformed_for_excessive_chunk_overhead
      bloated_extension = "A" * (HttpParser::MAX_CHUNK_OVERHEAD + 1)
      _decoded, state = HttpParser.decode_chunked("1;#{bloated_extension}\r\nX\r\n0\r\n\r\n")

      assert_equal :malformed, state
    end

    def test_decode_chunked_bounds_size_lines_before_their_terminator
      limit = HttpParser::MAX_CHUNK_OVERHEAD
      ["0;", "8;"].each do |prefix|
        line = prefix + "a" * (limit - 2)
        assert_equal :incomplete, HttpParser.decode_chunked(line)[1]
        assert_equal :malformed, HttpParser.decode_chunked(line + "a")[1]
        assert_equal :malformed, HttpParser.decode_chunked(line + "\r\n")[1]
      end

      line = "8;#{"a" * (limit - 4)}\r\n"
      decoded, state = HttpParser.decode_chunked("#{line}payload!\r\n0\r\n\r\n")
      assert_equal :complete, state
      assert_equal "payload!", decoded
      assert_equal :malformed, HttpParser.decode_chunked("#{line.chomp("\r\n")}a\r\npayload!\r\n0\r\n\r\n")[1]
    end

    def test_decode_chunked_bounds_terminal_metadata_independently_of_payload
      limit = HttpParser::MAX_CHUNK_OVERHEAD
      terminals = [
        "0;#{"a" * (limit - 6)}\r\n\r\n",
        "0\r\nX: #{"a" * (limit - 10)}\r\n\r\n",
        "0\r\n#{"X: a\r\n" * 8}Y: #{"a" * (limit - 58)}\r\n\r\n"
      ]
      payload = "8000\r\n#{"x" * 32_768}\r\n"
      terminals.each do |terminal|
        assert_equal limit, terminal.bytesize
        ["", payload].each do |prefix|
          decoded, state, consumed = HttpParser.decode_chunked(prefix + terminal + "GET / HTTP/1.0\r\n\r\n")
          assert_equal :complete, state
          assert_equal prefix.empty? ? "" : "x" * 32_768, decoded
          assert_equal prefix.bytesize + limit, consumed

          oversized = terminal.sub("\r\n\r\n", "a\r\n\r\n")
          assert_equal :malformed, HttpParser.decode_chunked(prefix + oversized)[1]
        end
      end

      partial = "0\r\nX: #{"a" * (limit - 6)}"
      assert_equal :incomplete, HttpParser.decode_chunked(partial)[1]
      assert_equal :malformed, HttpParser.decode_chunked(partial + "a")[1]
    end

    def test_decode_chunked_returns_too_large_above_max_size
      _decoded, state = HttpParser.decode_chunked("a\r\n0123456789\r\n0\r\n\r\n", 5)

      assert_equal :too_large, state
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
