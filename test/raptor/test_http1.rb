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

    def test_eager_keepalive_persists_idle_connections
      handler = Http1.allocate
      handler.instance_variable_set(:@running, AtomicBoolean.new(true))

      timeout = nil
      socket = Object.new
      socket.define_singleton_method(:wait_readable) do |value|
        timeout = value
        false
      end

      persisted = nil
      reactor = Object.new
      reactor.define_singleton_method(:persist) { |*args, **options| persisted = [args, options] }

      handler.send(:eager_keepalive, socket, 1, reactor, nil, 2, "127.0.0.1", "http")

      assert_equal 0, timeout
      assert_equal [[socket, 1, 2], { remote_addr: "127.0.0.1", url_scheme: "http" }], persisted
    end

    def test_response_corking
      handler = Http1.allocate
      handler.instance_variable_set(:@write_timeout, 1)

      corked = 0
      uncorked = 0
      handler.define_singleton_method(:cork_socket) { |_| corked += 1 }
      handler.define_singleton_method(:uncork_socket) { |_| uncorked += 1 }
      handler.define_singleton_method(:socket_write) { |*| }
      handler.define_singleton_method(:socket_writev) { |*| }

      env = { Rack::SERVER_PROTOCOL => "HTTP/1.1", Rack::REQUEST_METHOD => "GET" }
      handler.send(:write_response, Object.new, env, 200, {}, ["hello"])

      assert_equal 0, corked
      assert_equal 0, uncorked

      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("hello") }
      handler.send(:write_response, Object.new, env, 200, {}, body)

      assert_equal 1, corked
      assert_equal 1, uncorked
    end
  end
end
