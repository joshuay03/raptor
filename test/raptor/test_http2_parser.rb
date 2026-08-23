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

    def test_encode_response_headers_prepends_status_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, {"content-type" => "text/plain"})

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_lowercases_names
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, {"Content-Type" => "text/plain"})

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_expands_array_values
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, {"set-cookie" => ["a=1", "b=2"]})

      assert_equal [[":status", "200"], ["set-cookie", "a=1"], ["set-cookie", "b=2"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_drops_rack_prefixed_keys
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, {"rack.hijack" => "x", "content-type" => "text/plain"})

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_drops_hop_by_hop_headers
      parser = Http2Parser.new
      hop_by_hop = {"connection" => "x", "transfer-encoding" => "x", "keep-alive" => "x", "upgrade" => "x", "proxy-connection" => "x"}
      encoded = parser.encode_response_headers(200, hop_by_hop.merge("content-type" => "text/plain"))

      assert_equal [[":status", "200"], ["content-type", "text/plain"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_coerces_non_string_values
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(200, {"content-length" => 42})

      assert_equal [[":status", "200"], ["content-length", "42"]], parser.parse_headers(encoded, []).first
    end

    def test_encode_response_headers_handles_empty_headers_hash
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(404, {})

      assert_equal [[":status", "404"]], parser.parse_headers(encoded, []).first
    end
  end
end
