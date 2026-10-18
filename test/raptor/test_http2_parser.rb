# frozen_string_literal: true

require "test_helper"

require "raptor/http2"

module Raptor
  class TestHttp2Parser < TestCase
    parallelize_me!

    def test_parse_headers_rejects_oversized_dynamic_table_size_update
      parser = Http2Parser.new
      size_update_to_8k = "\x3f\xe1\x3f".b

      assert_raises(Http2ParserError) do
        parser.parse_headers(size_update_to_8k, [])
      end
    end

    def test_parse_headers_accepts_dynamic_table_size_update_at_limit
      parser = Http2Parser.new
      size_update_to_4k = "\x3f\xe1\x1f".b

      headers, _table = parser.parse_headers(size_update_to_4k, [])

      assert_empty headers
    end

    def test_parse_headers_rejects_malformed_huffman_string
      parser = Http2Parser.new
      overlong_padding_name = "\x00\x81\xff\x01a".b

      assert_raises(Http2ParserError) do
        parser.parse_headers(overlong_padding_name, [])
      end
    end

    def test_parse_headers_accepts_header_list_within_size_limit
      parser = Http2Parser.new

      headers, _table = parser.parse_headers(repeated_indexed_field_block(27), [])

      assert_equal Array.new(28) { ["x", "a" * 4000] }, headers
    end

    def test_parse_headers_rejects_header_list_beyond_size_limit
      parser = Http2Parser.new

      assert_raises(Http2ParserError) do
        parser.parse_headers(repeated_indexed_field_block(28), [])
      end
    end

    def test_parse_headers_rejects_oversized_huffman_string
      parser = Http2Parser.new
      a_huffman_codes = "\x18\xc6\x31\x8c\x63".b * 500_000
      long_value_block = "\x00\x01x\xff\xa1\xca\x98\x01".b + a_huffman_codes

      assert_raises(Http2ParserError) do
        Thread.new do
          Thread.current.report_on_exception = false
          parser.parse_headers(long_value_block, [])
        end.value
      end
    end

    def test_encode_headers_encodes_long_huffman_string
      parser = Http2Parser.new

      encoded = Thread.new { parser.encode_headers([["x", "a" * 4_000_000]]) }.value

      assert_equal "\x00\x01x\xff\xa1\xca\x98\x01".b + ("\x18\xc6\x31\x8c\x63".b * 500_000), encoded
    end

    def test_encode_response_headers_prepends_status_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, { "content-type" => "text/plain" })

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_lowercases_names
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, { "Content-Type" => "text/plain" })

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_expands_array_values
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, { "set-cookie" => ["a=1", "b=2"] })

      assert_equal [[":status", "200"], ["set-cookie", "a=1"], ["set-cookie", "b=2"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_drops_rack_prefixed_keys
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, { "rack.hijack" => "x", "content-type" => "text/plain" })

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_drops_hop_by_hop_headers
      parser = Http2Parser.new
      hop_by_hop = { "connection" => "x", "transfer-encoding" => "x", "keep-alive" => "x", "upgrade" => "x", "proxy-connection" => "x" }
      encoded = parser.encode_response_headers(200, hop_by_hop.merge("content-type" => "text/plain"))

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_coerces_non_string_values
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, { "content-length" => 42 })

      assert_equal [[":status", "200"], ["content-length", "42"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_handles_empty_headers_hash
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(404, {})

      assert_equal [[":status", "404"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_trailers_lowercases_names_and_drops_pseudo_headers
      parser = Http2Parser.new
      encoded = parser.encode_response_trailers({ "Grpc-Status" => "0", ":status" => "500" })

      assert_equal [["grpc-status", "0"]], parser.parse_headers(encoded, []).first
    end

    private

    # Each decoded field costs 4,033 bytes, even when encoded as a one-byte index.
    def repeated_indexed_field_block(repeats)
      literal_with_indexing = "\x40\x01x\x7f\xa1\x1e".b + ("a" * 4000)
      literal_with_indexing + ("\xbe".b * repeats)
    end
  end
end
