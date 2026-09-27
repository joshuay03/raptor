# frozen_string_literal: true

require "test_helper"

require "socket"
require "timeout"

require "raptor/http2"

module Raptor
  class TestHttp2 < TestCase
    parallelize_me!

    DATA_FRAME_TYPE = 0x0
    HEADERS_FRAME_TYPE = 0x1
    RST_STREAM_FRAME_TYPE = 0x3
    GOAWAY_FRAME_TYPE = 0x7

    def test_dispatch_cleans_thread_and_fiber_locals
      handler = Http2.allocate
      handler.instance_variable_set(:@clean_thread_locals, true)
      handler.instance_variable_set(:@clean_fiber_locals, true)
      values = []
      handler.define_singleton_method(:perform_stream_request) do |*|
        values << [
          Thread.current[:raptor_test_fiber],
          Thread.current.thread_variable_get(:raptor_test_thread),
          Fiber[:raptor_test_storage],
        ]
        Thread.current[:raptor_test_fiber] = "fiber"
        Thread.current.thread_variable_set(:raptor_test_thread, "thread")
        Fiber[:raptor_test_storage] = "storage"
      end

      2.times do
        handler.send(:dispatch_stream_request, nil, nil, nil, 1, [], "", remote_addr: "127.0.0.1")
      end

      assert_equal [[nil, nil, nil], [nil, nil, nil]], values
    end

    def test_shutdown_sends_goaway
      frame = nil
      reactor = Object.new
      reactor.define_singleton_method(:drain_http2) { |&block| frame = block.call(5) }
      handler = Http2.new(proc {}, 9292, http2_options: {max_concurrent_streams: 100})

      handler.shutdown(reactor)

      parsed, = Http2Parser.new.parse_frame(frame)
      assert_equal :goaway, parsed[:type]
      assert_equal [5, Http2::ERROR_NO_ERROR], parsed[:payload].unpack("NN")
    end

    def test_flow_control_acquire_caps_grant_at_max_frame_size
      flow_control = Http2::FlowControl.new

      assert_equal Http2::MAX_FRAME_SIZE, flow_control.acquire(1, 100_000)
    end

    def test_flow_control_acquire_blocks_until_stream_window_replenished
      flow_control = Http2::FlowControl.new
      drain_windows(flow_control, stream_id: 1)

      blocked = Thread.new { flow_control.acquire(1, 100) }
      sleep 0.05
      assert blocked.alive?

      flow_control.add_connection_window(40)
      flow_control.add_stream_window(1, 40)

      assert_equal 40, blocked.value
    end

    def test_flow_control_acquire_raises_when_stream_closes
      flow_control = Http2::FlowControl.new
      drain_windows(flow_control, stream_id: 1)

      blocked = Thread.new { flow_control.acquire(1, 100) }
      blocked.report_on_exception = false
      sleep 0.05
      flow_control.cancel_stream(1)

      assert_raises(Http2::StreamClosedError) { Timeout.timeout(1) { blocked.value } }
    end

    def test_flow_control_acquire_raises_when_connection_closes
      flow_control = Http2::FlowControl.new
      drain_windows(flow_control, stream_id: 1)

      blocked = Thread.new { flow_control.acquire(1, 100) }
      blocked.report_on_exception = false
      sleep 0.05
      flow_control.close

      assert_raises(Http2::StreamClosedError) { Timeout.timeout(1) { blocked.value } }
    end

    def test_flow_control_set_initial_stream_window_shifts_existing_streams
      flow_control = Http2::FlowControl.new
      flow_control.acquire(1, 100)
      flow_control.set_initial_stream_window(Http2::DEFAULT_WINDOW_SIZE + 1000)

      flow_control.add_connection_window(Http2::DEFAULT_WINDOW_SIZE)

      assert_equal Http2::MAX_FRAME_SIZE, flow_control.acquire(1, Http2::DEFAULT_WINDOW_SIZE + 900)
    end

    def test_writer_write_frames_does_not_block_indefinitely_on_full_send_buffer
      server = TCPServer.new("127.0.0.1", 0)
      client = TCPSocket.new("127.0.0.1", server.addr[1])
      accepted = server.accept

      client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)
      accepted.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1024)

      writer = Http2::Writer.new(write_timeout: Http::WRITE_TIMEOUT)
      big_frame = "x" * (1024 * 1024)

      Timeout.timeout(Http::WRITE_TIMEOUT + 5) do
        writer.write_frames(client, [big_frame])
      end

      pass
    ensure
      client&.close
      accepted&.close
      server&.close
    end

    def test_write_http2_response_omits_body_for_head_request
      frames = write_http2_response(request_method: "HEAD", status: 200, body: ["body"])

      assert_equal [HEADERS_FRAME_TYPE], frames.map { |frame| frame.getbyte(3) }
      assert frames.first.getbyte(4).anybits?(Http2::FLAG_END_STREAM)
    end

    def test_write_http2_response_omits_body_for_no_entity_status
      frames = write_http2_response(request_method: "GET", status: 204, body: ["body"])

      assert_equal [HEADERS_FRAME_TYPE], frames.map { |frame| frame.getbyte(3) }
      assert frames.first.getbyte(4).anybits?(Http2::FLAG_END_STREAM)
    end

    def test_write_http2_response_streams_enumerable_body
      frames = []
      observed_frames = nil
      body = Object.new
      body.define_singleton_method(:each) do |&block|
        block.call("first")
        observed_frames = frames.dup
        block.call("second")
      end

      write_http2_response(body: body, frames: frames)

      assert_equal [HEADERS_FRAME_TYPE, DATA_FRAME_TYPE], observed_frames.map { |frame| frame.getbyte(3) }
      assert_equal ["first", "second", ""], frames.drop(1).map { |frame| frame.byteslice(9..-1) }
      assert frames.last.getbyte(4).anybits?(Http2::FLAG_END_STREAM)
    end

    def test_write_http2_response_calls_streaming_body
      frames = []
      observed_frames = nil
      body = proc do |stream|
        stream.write("first")
        observed_frames = frames.dup
        stream << "second"
        stream.flush
        assert_raises(IOError) { stream.read }
        assert_raises(IOError) { stream.close_read }
        stream.close_write
        assert_predicate stream, :closed?
      end

      write_http2_response(body: body, frames: frames)

      assert_equal [HEADERS_FRAME_TYPE, DATA_FRAME_TYPE], observed_frames.map { |frame| frame.getbyte(3) }
      assert_equal ["first", "second", ""], frames.drop(1).map { |frame| frame.byteslice(9..-1) }
      assert frames.last.getbyte(4).anybits?(Http2::FLAG_END_STREAM)
    end

    def test_perform_stream_request_supports_response_lifecycle
      callback_arguments = nil
      app = proc do |env|
        env[Rack::RACK_EARLY_HINTS].call("link" => "</style.css>; rel=preload")
        env[Rack::RACK_RESPONSE_FINISHED] << proc { |*arguments| callback_arguments = arguments }
        [200, {"content-type" => "text/plain"}, ["body"]]
      end

      frames = perform_stream_request(app)

      assert_equal [HEADERS_FRAME_TYPE, HEADERS_FRAME_TYPE, DATA_FRAME_TYPE, DATA_FRAME_TYPE], frames.map { |frame| frame.getbyte(3) }
      assert_equal ["103", "200"], decode_header_blocks(frames).map { |headers| headers.assoc(":status").last }
      assert_equal [200, {"content-type" => "text/plain"}, nil], callback_arguments.drop(1)
    end

    def test_perform_stream_request_writes_response_trailers
      app = proc do |env|
        env[Http2::RESPONSE_TRAILERS]["grpc-status"] = "0"
        [200, {"content-type" => "application/grpc"}, ["body"]]
      end

      frames = perform_stream_request(app)

      assert_equal [HEADERS_FRAME_TYPE, DATA_FRAME_TYPE, HEADERS_FRAME_TYPE], frames.map { |frame| frame.getbyte(3) }
      assert_equal [[":status", "200"], ["content-type", "application/grpc"]], decode_header_blocks(frames).first
      assert_equal [["grpc-status", "0"]], decode_header_blocks(frames).last
      assert frames.last.getbyte(4).anybits?(Http2::FLAG_END_STREAM)
    end

    def test_perform_stream_request_handles_body_errors
      callback_error = nil
      handled_error = nil
      error = RuntimeError.new("stream failed")
      body = Object.new
      body.define_singleton_method(:each) do |&block|
        block.call("body")
        raise error
      end
      app = proc do |env|
        env[Rack::RACK_RESPONSE_FINISHED] << proc { |_env, _status, _headers, response_error| callback_error = response_error }
        [200, {}, body]
      end

      frames = perform_stream_request(app, on_error: proc { |_env, response_error| handled_error = response_error })

      assert_equal [HEADERS_FRAME_TYPE, DATA_FRAME_TYPE, RST_STREAM_FRAME_TYPE], frames.map { |frame| frame.getbyte(3) }
      assert_same error, callback_error
      assert_same error, handled_error
    end

    def test_perform_stream_request_handles_stream_cancellation
      called = false
      flow_control = Http2::FlowControl.new
      flow_control.cancel_stream(1)
      app = proc do
        called = true
        [200, {}, ["body"]]
      end

      frames = perform_stream_request(app, flow_control: flow_control)

      refute called
      assert_empty frames
    end

    def test_process_frames_rejects_even_client_stream_id
      result = process_frames_with(headers_frame(stream_id: 2))

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_non_monotonic_stream_id
      result = process_frames_with(headers_frame(stream_id: 3) + headers_frame(stream_id: 1))

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_data_for_unopened_stream
      parser = Http2Parser.new
      data_frame = parser.build_frame(:data, Http2::FLAG_END_STREAM, 1, "body")

      result = process_frames_with(data_frame)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_accepts_monotonic_odd_stream_ids
      result = process_frames_with(headers_frame(stream_id: 1) + headers_frame(stream_id: 3))

      refute result[:close_connection]
      assert_equal 2, result[:completed_requests].size
    end

    def test_process_frames_assembles_continuation_frames
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      half = encoded.bytesize / 2
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM, 1, encoded.byteslice(0, half))
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 1, encoded.byteslice(half..-1))

      result = process_frames_with(headers + continuation)

      refute result[:close_connection]
      assert_equal 1, result[:completed_requests].size
      assert_equal [":method", ":path", ":scheme", ":authority"], result[:completed_requests].first[:headers].map(&:first)
    end

    def test_process_frames_accepts_request_trailers
      parser = Http2Parser.new
      headers = headers_frame(stream_id: 1, end_stream: false)
      data = parser.build_frame(:data, 0, 1, "body")
      encoded = parser.encode_headers([["checksum", "abc"]])
      half = encoded.bytesize / 2
      trailers = parser.build_frame(:headers, Http2::FLAG_END_STREAM, 1, encoded.byteslice(0, half))
      trailers << parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 1, encoded.byteslice(half..-1))

      result = process_frames_with(headers + data + trailers)

      assert_equal 1, result[:completed_requests].size
      assert_equal "body", result[:completed_requests].first[:body]
    end

    def test_process_frames_resets_request_trailers_without_end_stream
      headers = headers_frame(stream_id: 1, end_stream: false)
      trailers = trailers_frame(stream_id: 1, headers: [["checksum", "abc"]], end_stream: false)

      result = process_frames_with(headers + trailers)

      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_resets_request_trailers_with_pseudo_headers
      headers = headers_frame(stream_id: 1, end_stream: false)
      trailers = trailers_frame(stream_id: 1, headers: [[":path", "/other"]])

      result = process_frames_with(headers + trailers)

      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_rejects_continuation_without_pending_headers
      parser = Http2Parser.new
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 1, "")

      result = process_frames_with(continuation)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_continuation_on_wrong_stream
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, 0, 1, encoded)
      continuation = parser.build_frame(:continuation, Http2::FLAG_END_HEADERS, 3, "")

      result = process_frames_with(headers + continuation)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_rejects_data_while_expecting_continuation
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, 0, 1, encoded)
      data = parser.build_frame(:data, Http2::FLAG_END_STREAM, 1, "body")

      result = process_frames_with(headers + data)

      assert result[:close_connection]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, goaway_error_code(result)
    end

    def test_process_frames_resets_stream_with_missing_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":scheme", "https"], [":authority", "x"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_resets_stream_with_unknown_pseudo_header
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"], [":unknown", "y"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_resets_stream_with_pseudo_header_after_regular
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], ["x-custom", "y"], [":authority", "x"]])
      headers = parser.build_frame(:headers, Http2::FLAG_END_STREAM | Http2::FLAG_END_HEADERS, 1, encoded)

      result = process_frames_with(headers)

      refute result[:close_connection]
      assert_empty result[:completed_requests]
      assert_equal Http2::ERROR_PROTOCOL_ERROR, rst_stream_error_code(result, stream_id: 1)
    end

    def test_process_frames_extracts_window_updates
      parser = Http2Parser.new
      connection_update = parser.build_frame(:window_update, 0, 0, [1000].pack("N"))
      stream_update = parser.build_frame(:window_update, 0, 5, [500].pack("N"))

      result = process_frames_with(connection_update + stream_update)

      assert_equal [[0, 1000], [5, 500]], result[:window_updates]
    end

    def test_process_frames_extracts_stream_cancellations
      parser = Http2Parser.new
      reset = parser.build_frame(:rst_stream, 0, 1, [Http2::ERROR_NO_ERROR].pack("N"))

      result = process_frames_with(headers_frame(stream_id: 1) + reset)

      assert_empty result[:completed_requests]
      assert_equal [1], result[:cancelled_streams]
    end

    def test_process_frames_extracts_peer_initial_window_size_from_settings
      parser = Http2Parser.new
      settings_payload = parser.build_settings(initial_window_size: 32_768)
      settings = parser.build_frame(:settings, 0, 0, settings_payload)

      result = process_frames_with(settings)

      assert_equal 32_768, result[:peer_initial_window_size]
    end

    private

    def perform_stream_request(app, flow_control: Http2::FlowControl.new, on_error: nil)
      frames = []
      writer = Object.new
      writer.define_singleton_method(:write_frames) { |_socket, outgoing| frames.concat(outgoing) }
      handler = Http2.new(app, 9292, http2_options: {max_concurrent_streams: 100}, on_error: on_error)
      headers = [[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "example.com"]]

      handler.send(
        :perform_stream_request,
        nil,
        writer,
        flow_control,
        1,
        headers,
        "",
        remote_addr: "127.0.0.1"
      )

      frames
    end

    def decode_header_blocks(frames)
      parser = Http2Parser.new
      table = []

      frames.filter_map do |frame|
        next unless frame.getbyte(3) == HEADERS_FRAME_TYPE

        headers, table = parser.parse_headers(frame.byteslice(9..-1), table)
        headers
      end
    end

    def write_http2_response(request_method: "GET", status: 200, body: ["body"], frames: [])
      writer = Object.new
      writer.define_singleton_method(:write_frames) { |_socket, outgoing| frames.concat(outgoing) }

      Http2.allocate.send(
        :write_http2_response,
        nil,
        writer,
        Http2::FlowControl.new,
        1,
        status,
        {},
        body,
        trailers: {},
        request_method: request_method
      )

      frames
    end

    def process_frames_with(frame_bytes)
      Http2.process_frames(
        id: 1,
        buffer: Http2Parser.connection_preface + frame_bytes,
        remote_addr: "127.0.0.1",
        url_scheme: "https",
        protocol: :http2
      )
    end

    def headers_frame(stream_id:, end_stream: true)
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":method", "GET"], [":path", "/"], [":scheme", "https"], [":authority", "x"]])
      flags = Http2::FLAG_END_HEADERS
      flags |= Http2::FLAG_END_STREAM if end_stream
      parser.build_frame(:headers, flags, stream_id, encoded)
    end

    def trailers_frame(stream_id:, headers:, end_stream: true)
      parser = Http2Parser.new
      encoded = parser.encode_headers(headers)
      flags = Http2::FLAG_END_HEADERS
      flags |= Http2::FLAG_END_STREAM if end_stream
      parser.build_frame(:headers, flags, stream_id, encoded)
    end

    def goaway_error_code(result)
      goaway = result[:outgoing_frames].find { |frame| frame.getbyte(3) == GOAWAY_FRAME_TYPE }
      return unless goaway

      _last_stream_id, error_code = goaway.byteslice(9, 8).unpack("NN")
      error_code
    end

    def rst_stream_error_code(result, stream_id:)
      rst = result[:outgoing_frames].find do |frame|
        frame.getbyte(3) == RST_STREAM_FRAME_TYPE && frame.byteslice(5, 4).unpack1("N") == stream_id
      end
      return unless rst

      rst.byteslice(9, 4).unpack1("N")
    end

    def drain_windows(flow_control, stream_id:)
      remaining = Http2::DEFAULT_WINDOW_SIZE
      remaining -= flow_control.acquire(stream_id, remaining) while remaining > 0
    end
  end
end
