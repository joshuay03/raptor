# frozen_string_literal: true

require "test_helper"

require "raptor/http1"

module Raptor
  class TestHttp1 < TestCase
    parallelize_me!

    def test_parse_leaves_pipelined_request_out_of_body
      request = "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello"
      pipelined = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"

      parsed = Http1.parse({ buffer: request + pipelined }, {}, nil)

      assert_equal "hello", parsed[:body]
      assert_equal pipelined, parsed[:parse_data][:pipelined]
    end

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
      thread_pool.define_singleton_method(:<<) { |work| queued << work }

      socket = Object.new
      socket.define_singleton_method(:wait_readable) { |_| true }

      handler.eager_keepalive(socket, 1, nil, thread_pool, 1, "127.0.0.1", "http")

      assert_equal 1, queued.length
      refute processed
    end

    def test_eager_keepalive_processes_resumed_connections_inline
      handler = Http1.allocate
      handler.instance_variable_set(:@running, AtomicBoolean.new(true))

      parser = Object.new
      parser.define_singleton_method(:finished?) { true }
      handler.define_singleton_method(:read_into_thread_buffer) { |_| "" }
      handler.define_singleton_method(:parse_next_request) { |_| [{}, {}, 0, parser] }
      handler.define_singleton_method(:extract_body) { |*| nil }

      processed = 0
      handler.define_singleton_method(:process_request) do |*|
        processed += 1
        false
      end

      queued = []
      thread_pool = Object.new
      thread_pool.define_singleton_method(:queue_size) { 1 }
      thread_pool.define_singleton_method(:<<) { |work| queued << work }

      handler.eager_keepalive(Object.new, 1, nil, thread_pool, 1, "127.0.0.1", "http", resumed: true)

      assert_equal 1, processed
      assert_empty queued
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

      handler.eager_keepalive(socket, 1, reactor, nil, 2, "127.0.0.1", "http")

      assert_equal 0, timeout
      assert_equal [[socket, 1, 2], { remote_addr: "127.0.0.1", url_scheme: "http" }], persisted
    end

    def test_write_response_corks_socket_only_for_streamed_bodies
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
