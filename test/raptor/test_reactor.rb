# frozen_string_literal: true

require "test_helper"

module Raptor
  class TestReactor < TestCase
    parallelize_me!

    def test_http2_stream_dispatch_during_drain
      frames = []
      writer = Object.new
      writer.define_singleton_method(:write_frames) { |_socket, outgoing| frames.concat(outgoing) }
      reactor = Reactor.allocate
      reactor.instance_variable_set(:@id_to_socket, {1 => Object.new})
      reactor.instance_variable_set(:@id_to_writer, {1 => writer})
      reactor.instance_variable_set(:@id_to_flow_control, {1 => Object.new})
      reactor.instance_variable_set(:@id_to_http2_last_stream, {})
      reactor.instance_variable_set(:@id_to_http2_drain_stream, {})

      assert reactor.dispatch_http2_stream(1, 3)
      reactor.drain_http2 { |stream_id| "goaway-#{stream_id}" }

      assert_equal ["goaway-3"], frames
      assert reactor.dispatch_http2_stream(1, 3)
      refute reactor.dispatch_http2_stream(1, 5)
    end
  end
end
