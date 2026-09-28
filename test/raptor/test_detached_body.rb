# frozen_string_literal: true

require "test_helper"

require "raptor/detached_body"

module Raptor
  class TestDetachedBody < TestCase
    parallelize_me!

    def test_bounded_writes
      body = DetachedBody.new(max_buffer_size: 5)

      assert_equal :accepted, body.try_write("hello")
      assert_equal :full, body.try_write("!")
      assert_equal "hel", body.shift(3)
      assert_equal :accepted, body.try_write("!")
      assert_equal "lo", body.shift(3)
      assert_equal "!", body.shift(3)
    end

    def test_stream_lifecycle
      opened = nil
      closed = []
      wakes = 0
      callbacks = []
      body = DetachedBody.new
      body.on_open { |stream| opened = stream }
      body.on_close { |reason| closed << reason }

      assert body.attach([], proc { wakes += 1 }, proc { |callback| callbacks << callback }, proc {})
      body.open
      callbacks.shift.call
      assert_same body, opened
      assert_equal :accepted, body.try_write("message")
      trailers = {"grpc-status" => +"0"}
      body.close(trailers: trailers)
      trailers["grpc-status"] << "1"

      assert_equal 1, wakes
      assert_equal 7, body.next_size
      assert_equal "message", body.shift(7)
      assert_equal 0, body.next_size
      assert_equal({"grpc-status" => "0"}, body.trailers)

      body.finish(:closed)
      body.finish(:cancelled)
      callbacks.each(&:call)

      assert_predicate body, :closed?
      assert_equal [:closed], closed
      assert_equal :closed, body.try_write("later")
    end

    def test_shared_buffer_limits
      budget = DetachedBody::Budget.new(5)
      first = DetachedBody.new
      second = DetachedBody.new
      first.attach([budget], proc {}, proc(&:call), proc {})
      second.attach([budget], proc {}, proc(&:call), proc {})
      first.open
      second.open

      assert_equal :accepted, first.try_write("hello")
      assert_equal :full, second.try_write("!")
      assert_equal "hello", first.shift(5)
      assert_equal :accepted, second.try_write("!")
    end
  end
end
