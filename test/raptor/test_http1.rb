# frozen_string_literal: true

require "test_helper"

require "raptor/http1"

module Raptor
  class TestHttp1 < TestCase
    parallelize_me!

    def test_eager_keepalive_requeues_when_work_is_waiting
      handler = Http1.allocate
      handler.instance_variable_set(:@running, AtomicBoolean.new(true))

      parser = Object.new
      parser.define_singleton_method(:finished?) { true }
      handler.define_singleton_method(:read_into_thread_buffer) { |_| "" }
      handler.define_singleton_method(:parse_next_request) { |_| [{}, {}, 0, parser] }
      handler.define_singleton_method(:extract_body) { |*| nil }

      processed = false
      handler.define_singleton_method(:process_request) { |*| processed = true }

      queued = []
      thread_pool = Object.new
      thread_pool.define_singleton_method(:queue_size) { 1 }
      thread_pool.define_singleton_method(:size) { 3 }
      thread_pool.define_singleton_method(:<<) { |work| queued << work }

      socket = Object.new
      socket.define_singleton_method(:wait_readable) { |_| true }

      handler.send(:eager_keepalive, socket, 1, nil, thread_pool, 1, "127.0.0.1", "http")

      assert_equal 1, queued.length
      assert_equal false, processed
    end
  end
end
