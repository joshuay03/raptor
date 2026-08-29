# frozen_string_literal: true

require "test_helper"

require "raptor/thread_locals"

module Raptor
  class TestThreadLocals < TestCase
    parallelize_me!

    def test_fetch_stores_value_on_current_thread
      value, stored = Thread.new do
        value = ThreadLocals.fetch(:raptor_read_buffer) { "buffer" }
        [value, Thread.current.thread_variable_get(:raptor_read_buffer)]
      end.value

      assert_equal "buffer", value
      assert_same value, stored
    end

    def test_fetch_reuses_stored_value
      first, second, calls = Thread.new do
        calls = 0
        first = ThreadLocals.fetch(:raptor_read_buffer) do
          calls += 1
          Object.new
        end
        second = ThreadLocals.fetch(:raptor_read_buffer) do
          calls += 1
          Object.new
        end
        [first, second, calls]
      end.value

      assert_same first, second
      assert_equal 1, calls
    end

    def test_clear_removes_application_thread_locals
      value = Thread.new do
        Thread.current.thread_variable_set(:application_value, "value")
        ThreadLocals.clear
        Thread.current.thread_variable_get(:application_value)
      end.value

      assert_nil value
    end

    def test_clear_preserves_raptor_thread_locals
      value = Thread.new do
        ThreadLocals.fetch(:raptor_read_buffer) { "buffer" }
        ThreadLocals.clear
        Thread.current.thread_variable_get(:raptor_read_buffer)
      end.value

      assert_equal "buffer", value
    end
  end
end
