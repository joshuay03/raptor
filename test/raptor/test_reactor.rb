# frozen_string_literal: true

require "test_helper"

module Raptor
  class TestReactor < TestCase
    # Runs serially so forked integration servers never inherit live reactor sockets.

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

    def test_http2_response_writes
      reader, socket = Socket.pair(:UNIX, :STREAM)
      write_thread = nil
      socket.define_singleton_method(:write_nonblock) do |*arguments|
        write_thread = Thread.current
        super(*arguments)
      end
      reactor = build_reactor
      writer = Http2::Writer.new(write_timeout: 5)
      flow_control = Http2::FlowControl.new
      reactor.attach_http2(
        id: 1,
        socket: socket,
        state: {id: 1, protocol: :http2, http2_preface_received: true},
        writer: writer,
        flow_control: flow_control,
        ping_frame: "ping",
        ping_payload: "payload"
      )
      reactor_thread = reactor.run

      writer.write_frames(socket, ["hello"])
      writer.write_frames(socket, [" world"])
      reactor.close_connection(1)

      assert_equal "hello world", Timeout.timeout(1) { reader.readpartial(11) }
      assert_nil Timeout.timeout(1) { reader.read(1) }
      assert_same reactor_thread, write_thread
    ensure
      reactor&.shutdown
      reactor_thread&.join
      reader&.close
      socket&.close
    end

    def test_http2_partial_response_writes
      reactor, socket, = build_http2_reactor
      writer = Http2::Writer.new(write_timeout: 5)
      writer.attach(reactor, 1)
      reactor.instance_variable_get(:@id_to_writer)[1] = writer
      attempts = 0
      written = String.new
      socket.define_singleton_method(:write_nonblock) do |data|
        attempts += 1
        if attempts == 1
          written << data.byteslice(0, 3)
          3
        elsif attempts == 2
          raise IO::EAGAINWaitWritable
        else
          written << data
          data.bytesize
        end
      end
      reactor.instance_variable_set(:@thread, Thread.current)

      writer.write_frames(socket, ["response"])

      io = reactor.instance_variable_get(:@id_to_io)[1]
      assert_equal :write, io.wait
      monitor = io.monitor
      monitor.readiness = :w
      reactor.send(:handle_monitor, monitor)

      assert_equal 3, attempts
      assert_equal "response", written
      assert_empty io.output
      assert_nil io.timeout
    end

    def test_http2_detached_body_writes
      callbacks = Queue.new
      thread_pool = Object.new
      thread_pool.define_singleton_method(:<<) { |callback| callbacks << callback }
      reactor, reactor_thread, reader, socket = build_running_http2_reactor(thread_pool)
      body = DetachedBody.new
      9.times { body.try_write("x") }
      body.close

      assert reactor.attach_http2_body(1, 3, body, proc {})
      parser = Http2Parser.new
      expected = (parser.build_frame(:data, 0, 3, "x") * 9) +
        parser.build_frame(:data, Http2::FLAG_END_STREAM, 3, nil)

      assert_equal expected, Timeout.timeout(1) { reader.read(expected.bytesize) }
      assert_predicate body, :closed?
    ensure
      reactor&.shutdown
      Timeout.timeout(1) { reactor_thread&.join }
      reader&.close
      socket&.close
    end

    def test_http2_detached_body_cancellation
      callbacks = Queue.new
      thread_pool = Object.new
      thread_pool.define_singleton_method(:<<) { |callback| callbacks << callback }
      reactor, reactor_thread, reader, socket = build_running_http2_reactor(thread_pool)
      reason = nil
      body = DetachedBody.new
      body.on_close { |closed| reason = closed }

      assert reactor.attach_http2_body(1, 3, body, proc {})
      reactor.cancel_http2_body(1, 3)
      Timeout.timeout(1) { callbacks.pop.call }

      assert_equal :cancelled, reason
      assert_predicate body, :closed?
    ensure
      reactor&.shutdown
      Timeout.timeout(1) { reactor_thread&.join }
      reader&.close
      socket&.close
    end

    def test_http2_detached_body_shutdown
      callbacks = Queue.new
      thread_pool = Object.new
      thread_pool.define_singleton_method(:<<) { |callback| callbacks << callback }
      reactor, reactor_thread, reader, socket = build_running_http2_reactor(thread_pool)
      reason = nil
      body = DetachedBody.new
      body.on_close { |closed| reason = closed }

      assert reactor.attach_http2_body(1, 3, body, proc {})
      reactor.drain_detached_bodies(0.01)
      Timeout.timeout(1) { callbacks.pop.call }

      assert_equal :shutdown, reason
      assert_predicate body, :closed?
    ensure
      reactor&.shutdown
      Timeout.timeout(1) { reactor_thread&.join }
      reader&.close
      socket&.close
    end

    def test_http2_keepalive
      reactor, socket, writer, flow_control = build_http2_reactor
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reactor.send(:register, socket)
      client = reactor.instance_variable_get(:@id_to_timeout).delete(1)
      reactor.instance_variable_get(:@timeouts).delete!(client)

      assert_in_delta before + 10, client.timeout_at, 0.1
      reactor.send(:handle_timeout, client, client.timeout_at)

      assert_equal ["ping"], writer.frames
      client = reactor.instance_variable_get(:@id_to_timeout).delete(1)
      reactor.instance_variable_get(:@timeouts).delete!(client)
      assert_in_delta before + 15, client.timeout_at, 0.1

      reactor.send(:handle_timeout, client, client.timeout_at)

      assert socket.closed?
      assert flow_control.closed?
    end

    def test_http2_keepalive_acknowledgement
      reactor, = build_http2_reactor
      keepalive = reactor.instance_variable_get(:@id_to_http2_keepalive)[1]
      keepalive[:deadline] = 105.0

      reactor.acknowledge_http2_ping(1, ["different"])
      assert_equal 105.0, keepalive[:deadline]

      reactor.acknowledge_http2_ping(1, ["payload"])
      refute keepalive.key?(:deadline)
    end

    def test_http2_initial_timeout
      reactor, socket, writer, = build_http2_reactor
      reactor.instance_variable_get(:@socket_to_state)[socket][:http2_preface_received] = false
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      reactor.send(:register, socket)
      client = reactor.instance_variable_get(:@id_to_timeout)[1]

      assert_in_delta before + 30, client.timeout_at, 0.1
      reactor.send(:handle_timeout, client, client.timeout_at)

      assert_empty writer.frames
      assert socket.closed?
    end

    private

    def build_reactor(thread_pool = nil)
      Reactor.new(
        nil,
        nil,
        thread_pool,
        connection_options: {first_data_timeout: 30, chunk_data_timeout: 10, write_timeout: 5},
        http1_options: {persistent_data_timeout: 65},
        http2_options: {keepalive_interval: 10, keepalive_timeout: 5}
      )
    end

    def build_running_http2_reactor(thread_pool)
      reader, socket = Socket.pair(:UNIX, :STREAM)
      reactor = build_reactor(thread_pool)
      reactor.attach_http2(
        id: 1,
        socket: socket,
        state: {id: 1, protocol: :http2, http2_preface_received: true},
        writer: Http2::Writer.new(write_timeout: 5),
        flow_control: Http2::FlowControl.new,
        ping_frame: "ping",
        ping_payload: "payload"
      )
      [reactor, reactor.run, reader, socket]
    end

    def build_http2_reactor
      reactor = build_reactor

      reactor.instance_variable_get(:@selector).close
      selector = Object.new
      selector.define_singleton_method(:registered?) { |_socket| false }
      selector.define_singleton_method(:register) do |_socket, _interest|
        monitor = Object.new
        monitor.define_singleton_method(:value=) { |value| @value = value }
        monitor.define_singleton_method(:value) { @value }
        monitor.define_singleton_method(:interests=) { |interests| @interests = interests }
        monitor.define_singleton_method(:interests) { @interests }
        monitor.define_singleton_method(:readiness=) { |readiness| @readiness = readiness }
        monitor.define_singleton_method(:readable?) { @readiness == :r || @readiness == :rw }
        monitor.define_singleton_method(:writable?) { @readiness == :w || @readiness == :rw }
        monitor
      end
      selector.define_singleton_method(:deregister) { |_socket| }
      selector.define_singleton_method(:wakeup) {}
      reactor.instance_variable_set(:@selector, selector)

      socket = Object.new
      socket.define_singleton_method(:close) { @closed = true }
      socket.define_singleton_method(:closed?) { @closed || false }

      writer = Object.new
      writer.define_singleton_method(:frames) { @frames ||= [] }
      writer.define_singleton_method(:attach) { |_reactor, _id| }
      writer.define_singleton_method(:write_frames) { |_socket, frames| self.frames.concat(frames) }

      flow_control = Object.new
      flow_control.define_singleton_method(:close) { @closed = true }
      flow_control.define_singleton_method(:closed?) { @closed || false }

      reactor.attach_http2(
        id: 1,
        socket: socket,
        state: {id: 1, protocol: :http2, http2_preface_received: true},
        writer: writer,
        flow_control: flow_control,
        ping_frame: "ping",
        ping_payload: "payload"
      )

      [reactor, socket, writer, flow_control]
    end
  end
end
