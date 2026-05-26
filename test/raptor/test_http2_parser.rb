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
  end
end
