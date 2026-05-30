# rbs_inline: enabled
# frozen_string_literal: true

require "stringio"

require "atomic-ruby/atom"
require "rack"

require_relative "request"
require_relative "raptor_http2"

module Raptor
  # Handles HTTP/2 request processing and Rack application integration.
  #
  # Http2 manages the HTTP/2 protocol lifecycle including frame processing,
  # HPACK header compression, stream management, and response writing.
  # It integrates with the same reactor, ractor pool, and thread pool
  # pipeline used by HTTP/1.1 connections.
  #
  class Http2
    # Lock-free per-connection frame writer.
    #
    # Serializes concurrent socket writes from multiple stream workers
    # without blocking any of them.
    #
    class Writer
      IDLE = :idle

      # @rbs @state: Atom

      # Creates a new Writer.
      #
      # @rbs () -> void
      def initialize
        @state = Atom.new(IDLE)
      end

      # Writes frames to the socket, coordinating with concurrent writers
      # so that exactly one thread is actively writing at any time.
      #
      # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
      # @param frames [Array<String>] frame bytes to write in order
      # @return [void]
      #
      # @rbs (OpenSSL::SSL::SSLSocket socket, Array[String] frames) -> void
      def write_frames(socket, frames)
        return if frames.nil? || frames.empty?

        claimed = false
        @state.swap do |current|
          if current.equal?(IDLE)
            claimed = true
            frames
          else
            claimed = false
            current + frames
          end
        end

        return unless claimed

        loop do
          pending = nil
          @state.swap do |current|
            pending = current
            current.empty? ? IDLE : []
          end

          break if pending.empty?

          pending.each do |frame|
            Request.socket_write(socket, frame) rescue nil
          end
        end
      end
    end

    # Per-connection outbound flow-control accounting.
    #
    # Tracks the peer's connection-level and per-stream receive windows so
    # outbound DATA frames respect RFC 7540 §5.2. Threads dispatching stream
    # responses call `acquire` to reserve send capacity; threads applying
    # inbound WINDOW_UPDATE or SETTINGS frames call the mutating methods to
    # replenish it. The connection window and per-stream windows live in
    # separate `Atom`s so the common fast path skips per-stream tracking.
    #
    class FlowControl
      ACQUIRE_POLL_INTERVAL = 0.001

      # @rbs @connection_window: Atom
      # @rbs @stream_windows: Atom
      # @rbs @initial_stream_window: Atom

      # Creates a new FlowControl with the spec-default windows.
      #
      # @rbs () -> void
      def initialize
        @connection_window = Atom.new(DEFAULT_WINDOW_SIZE)
        @stream_windows = Atom.new({})
        @initial_stream_window = Atom.new(DEFAULT_WINDOW_SIZE)
      end

      # Reserves outbound capacity on the given stream, polling until at
      # least one byte is available on both the connection and stream
      # windows. The returned size is capped at `MAX_FRAME_SIZE`.
      #
      # When `end_stream` is true, `max_bytes` fits within the peer's
      # initial stream window, and no per-stream override has been
      # recorded, only the connection window is consulted. The stream
      # closes on this frame, so its remaining send window will not be
      # consulted again and need not be tracked.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param max_bytes [Integer] the largest size the caller would like to send
      # @param end_stream [Boolean] true when this is the final frame on the stream
      # @return [Integer] the number of bytes the caller may now send
      #
      # @rbs (Integer stream_id, Integer max_bytes, ?end_stream: bool) -> Integer
      def acquire(stream_id, max_bytes, end_stream: false)
        initial = @initial_stream_window.value
        capped = max_bytes < MAX_FRAME_SIZE ? max_bytes : MAX_FRAME_SIZE

        if end_stream && capped <= initial && !@stream_windows.value.key?(stream_id)
          loop do
            granted = 0
            @connection_window.swap do |window|
              granted = window > capped ? capped : window
              granted > 0 ? window - granted : window
            end
            return granted if granted > 0

            sleep ACQUIRE_POLL_INTERVAL
          end
        end

        loop do
          stream_window = @stream_windows.value[stream_id] || initial
          capped_full = capped < stream_window ? capped : stream_window

          granted = 0
          if capped_full > 0
            @connection_window.swap do |window|
              granted = window > capped_full ? capped_full : window
              granted > 0 ? window - granted : window
            end
          end

          if granted > 0
            @stream_windows.swap do |s|
              current = s[stream_id] || initial
              s.merge(stream_id => current - granted)
            end
            return granted
          end

          sleep ACQUIRE_POLL_INTERVAL
        end
      end

      # Increments the connection-level send window. Called when the peer
      # sends a WINDOW_UPDATE on stream 0.
      #
      # @param increment [Integer] the byte count to add
      # @return [void]
      #
      # @rbs (Integer increment) -> void
      def add_connection_window(increment)
        @connection_window.swap { |window| window + increment }
      end

      # Increments the per-stream send window. Called when the peer sends
      # a WINDOW_UPDATE on a specific stream.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param increment [Integer] the byte count to add
      # @return [void]
      #
      # @rbs (Integer stream_id, Integer increment) -> void
      def add_stream_window(stream_id, increment)
        initial = @initial_stream_window.value
        @stream_windows.swap do |s|
          current = s[stream_id] || initial
          s.merge(stream_id => current + increment)
        end
      end

      # Updates the peer's `SETTINGS_INITIAL_WINDOW_SIZE`. Shifts every
      # existing stream window by the delta as required by RFC 7540 §6.9.2.
      #
      # @param new_size [Integer] the peer's new initial window size
      # @return [void]
      #
      # @rbs (Integer new_size) -> void
      def set_initial_stream_window(new_size)
        old = @initial_stream_window.value
        @initial_stream_window.swap { new_size }
        delta = new_size - old
        return if delta.zero?

        @stream_windows.swap do |s|
          s.transform_values { |size| size + delta }
        end
      end

      # Discards any per-stream tracking for the given stream. Called
      # after a stream closes so `@stream_windows` does not grow without
      # bound across the lifetime of a connection.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @return [void]
      #
      # @rbs (Integer stream_id) -> void
      def discard_stream(stream_id)
        return unless @stream_windows.value.key?(stream_id)

        @stream_windows.swap do |s|
          next s unless s.key?(stream_id)

          new = s.dup
          new.delete(stream_id)
          new
        end
      end
    end

    FLAG_END_STREAM = 0x1
    FLAG_END_HEADERS = 0x4
    FLAG_ACK = 0x1
    FLAG_PRIORITY = 0x20

    ERROR_NO_ERROR = 0x0
    ERROR_PROTOCOL_ERROR = 0x1

    DEFAULT_WINDOW_SIZE = 65_535
    MAX_FRAME_SIZE = 16_384

    SERVER_PROTOCOL = "HTTP/2"
    RACK_HEADER_PREFIX = "rack."
    HOP_BY_HOP_HEADERS = Set.new(%w[connection transfer-encoding keep-alive upgrade proxy-connection]).freeze

    # @rbs @app: ^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped]
    # @rbs @server_port: Integer
    # @rbs @on_error: ^(Hash[String, untyped]?, Exception) -> void | nil

    # Creates a new Http2 handler.
    #
    # @param app [#call] the Rack application to dispatch requests to
    # @param server_port [Integer] port number used to populate SERVER_PORT in the Rack env
    # @param on_error [#call, nil] callback invoked with (env, exception) when the Rack app raises
    # @return [void]
    #
    # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, Integer server_port, ?on_error: ^(Hash[String, untyped]?, Exception) -> void | nil) -> void
    def initialize(app, server_port, on_error: nil)
      @app = app
      @server_port = server_port
      @on_error = on_error
    end

    # Builds the initial server SETTINGS frame to send on connection establishment.
    #
    # @return [String] the encoded SETTINGS frame
    #
    # @rbs () -> String
    def self.build_server_settings_frame
      parser = Http2Parser.new
      settings_payload = parser.build_settings(
        max_concurrent_streams: 100,
        initial_window_size: DEFAULT_WINDOW_SIZE
      )
      parser.build_frame(:settings, 0, 0, settings_payload)
    end

    # Processes HTTP/2 frames from the connection buffer.
    #
    # Parses frames, handles HPACK decoding, tracks stream state, and returns
    # updated connection state along with any outgoing protocol frames and
    # completed stream requests. Ractor-safe.
    #
    # @param data [Hash] the connection state including buffer and HPACK table
    # @return [Hash] updated state with outgoing_frames and completed_requests
    #
    # @rbs (Hash[Symbol, untyped] data) -> Hash[Symbol, untyped]
    def self.process_frames(data)
      parser = Http2Parser.new
      buffer = data[:buffer]
      hpack_table = data[:hpack_table] || []
      streams = data[:http2_streams] ? data[:http2_streams].dup : {}
      outgoing_frames = []
      completed_requests = []
      window_updates = []
      peer_initial_window_size = nil
      connection_window = data[:http2_window] || DEFAULT_WINDOW_SIZE
      preface_received = data[:http2_preface_received] || false
      last_client_stream_id = data[:http2_last_client_stream_id] || 0
      pending_headers = data[:http2_pending_headers]
      goaway_error = nil

      unless preface_received
        if buffer.bytesize >= 24 && buffer.byteslice(0, 24) == Http2Parser.connection_preface
          buffer = buffer.byteslice(24..-1) || ""
          preface_received = true
        else
          return build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, window_updates, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, false)
        end
      end

      loop do
        parsed = parser.parse_frame(buffer)
        break unless parsed

        frame, consumed = parsed
        buffer = buffer.byteslice(consumed..-1) || ""

        if pending_headers && frame[:type] != :continuation
          goaway_error = ERROR_PROTOCOL_ERROR
          break
        end

        case frame[:type]
        when :settings
          if (frame[:flags] & FLAG_ACK).zero?
            parsed_settings = parser.parse_settings(frame[:payload])
            peer_initial_window_size = parsed_settings[:initial_window_size] if parsed_settings.key?(:initial_window_size)
            outgoing_frames << parser.build_frame(:settings, FLAG_ACK, 0, nil)
          end

        when :headers
          stream_id = frame[:stream_id]
          header_payload = frame[:payload]

          unless streams.key?(stream_id)
            if stream_id.even? || stream_id <= last_client_stream_id
              goaway_error = ERROR_PROTOCOL_ERROR
              break
            end
            last_client_stream_id = stream_id
          end

          if (frame[:flags] & FLAG_PRIORITY) != 0
            header_payload = header_payload.byteslice(5..-1) || ""
          end

          end_stream = (frame[:flags] & FLAG_END_STREAM) != 0

          if (frame[:flags] & FLAG_END_HEADERS) != 0
            decoded_headers, hpack_table = parser.parse_headers(header_payload, hpack_table)
            streams, completed_requests = finalize_headers(streams, completed_requests, stream_id, decoded_headers, end_stream)
          else
            pending_headers = { stream_id: stream_id, buffer: header_payload, end_stream: end_stream }
          end

        when :continuation
          if pending_headers.nil? || frame[:stream_id] != pending_headers[:stream_id]
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          pending_headers = pending_headers.merge(buffer: pending_headers[:buffer] + frame[:payload])

          if (frame[:flags] & FLAG_END_HEADERS) != 0
            stream_id = pending_headers[:stream_id]
            decoded_headers, hpack_table = parser.parse_headers(pending_headers[:buffer], hpack_table)
            streams, completed_requests = finalize_headers(streams, completed_requests, stream_id, decoded_headers, pending_headers[:end_stream])
            pending_headers = nil
          end

        when :data
          stream_id = frame[:stream_id]

          unless streams.key?(stream_id)
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          stream = streams[stream_id]
          existing_body = stream[:body] || ""
          stream = stream.merge(body: existing_body + frame[:payload])

          if frame[:payload].bytesize.positive?
            connection_window -= frame[:payload].bytesize
            if connection_window < DEFAULT_WINDOW_SIZE / 2
              increment = DEFAULT_WINDOW_SIZE - connection_window
              wu_payload = [increment].pack("N")
              outgoing_frames << parser.build_frame(:window_update, 0, 0, wu_payload)
              outgoing_frames << parser.build_frame(:window_update, 0, stream_id, wu_payload)
              connection_window += increment
            end
          end

          if (frame[:flags] & FLAG_END_STREAM) != 0
            stream_headers = stream[:headers] || []
            completed_requests << {
              stream_id: stream_id,
              headers: stream_headers,
              body: stream[:body]
            }

            streams.delete(stream_id)
          else
            streams[stream_id] = stream
          end

        when :window_update
          increment = parser.parse_window_update(frame[:payload])
          window_updates << [frame[:stream_id], increment]

        when :ping
          if (frame[:flags] & FLAG_ACK).zero?
            outgoing_frames << parser.build_frame(:ping, FLAG_ACK, 0, frame[:payload])
          end

        when :goaway
          break

        when :rst_stream
          streams.delete(frame[:stream_id])
        end
      end

      if goaway_error
        goaway_payload = [last_client_stream_id, goaway_error].pack("NN")
        outgoing_frames << parser.build_frame(:goaway, 0, 0, goaway_payload)
      end

      build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, window_updates, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, !goaway_error.nil?)
    end

    # Merges a decoded header block into the stream's accumulated state,
    # promoting the stream to `completed_requests` when END_STREAM is set.
    #
    # @param streams [Hash] current open-stream map
    # @param completed_requests [Array<Hash>] accumulator of completed stream requests
    # @param stream_id [Integer] the stream identifier
    # @param decoded_headers [Array<Array(String, String)>] decoded header pairs
    # @param end_stream [Boolean] whether the source frame had END_STREAM set
    # @return [Array(Hash, Array<Hash>)] updated streams and completed_requests
    #
    # @rbs (Hash[Integer, Hash[Symbol, untyped]] streams, Array[Hash[Symbol, untyped]] completed_requests, Integer stream_id, Array[[String, String]] decoded_headers, bool end_stream) -> [Hash[Integer, Hash[Symbol, untyped]], Array[Hash[Symbol, untyped]]]
    def self.finalize_headers(streams, completed_requests, stream_id, decoded_headers, end_stream)
      stream = streams[stream_id] || {}
      stream = stream.merge(headers: decoded_headers)

      if end_stream
        completed_requests << {
          stream_id: stream_id,
          headers: decoded_headers,
          body: stream[:body] || ""
        }

        streams.delete(stream_id)
      else
        streams[stream_id] = stream
      end

      [streams, completed_requests]
    end
    private_class_method :finalize_headers

    # Builds a frozen result hash from the current processing state.
    #
    # @param data [Hash] original connection state
    # @param buffer [String] remaining unparsed data
    # @param hpack_table [Array] updated HPACK dynamic table
    # @param streams [Hash] updated stream states
    # @param outgoing_frames [Array<String>] frames to write to the socket
    # @param completed_requests [Array<Hash>] fully received stream requests
    # @param window_updates [Array<Array(Integer, Integer)>] inbound WINDOW_UPDATE pairs as [stream_id, increment]
    # @param peer_initial_window_size [Integer, nil] new SETTINGS_INITIAL_WINDOW_SIZE announced by the peer
    # @param connection_window [Integer] current connection flow control window
    # @param preface_received [Boolean] whether the connection preface has been received
    # @param last_client_stream_id [Integer] highest client-initiated stream ID seen
    # @param pending_headers [Hash, nil] in-progress HEADERS+CONTINUATION assembly
    # @param close_connection [Boolean] whether the connection should be closed after writing outgoing frames
    # @return [Hash] frozen result hash
    #
    # @rbs (Hash[Symbol, untyped] data, String buffer, Array[untyped] hpack_table, Hash[Integer, Hash[Symbol, untyped]] streams, Array[String] outgoing_frames, Array[Hash[Symbol, untyped]] completed_requests, Array[[Integer, Integer]] window_updates, Integer? peer_initial_window_size, Integer connection_window, bool preface_received, Integer last_client_stream_id, Hash[Symbol, untyped]? pending_headers, bool close_connection) -> Hash[Symbol, untyped]
    def self.build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, window_updates, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, close_connection)
      result = {
        id: data[:id],
        protocol: :http2,
        buffer: buffer || "",
        hpack_table: hpack_table,
        http2_streams: streams,
        http2_window: connection_window,
        http2_preface_received: preface_received,
        http2_last_client_stream_id: last_client_stream_id,
        http2_pending_headers: pending_headers,
        outgoing_frames: outgoing_frames,
        completed_requests: completed_requests,
        close_connection: close_connection,
        remote_addr: data[:remote_addr],
        url_scheme: data[:url_scheme]
      }
      result[:window_updates] = window_updates unless window_updates.empty?
      result[:peer_initial_window_size] = peer_initial_window_size if peer_initial_window_size
      Ractor.make_shareable(result)
    end
    private_class_method :build_result

    # Handles a parsed HTTP/2 request from the ractor pool.
    #
    # Writes outgoing protocol frames to the socket, updates reactor state,
    # and dispatches completed stream requests to the thread pool.
    #
    # @param result [Hash] the parsed result from the ractor pool
    # @param reactor [Reactor] the reactor managing the connection
    # @param thread_pool [AtomicThreadPool] thread pool for Rack app dispatch
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] result, Reactor reactor, AtomicThreadPool thread_pool) -> void
    def handle_parsed_request(result, reactor, thread_pool)
      socket = reactor.socket_for(result[:id])
      return unless socket

      writer = reactor.writer_for(result[:id])
      flow_control = reactor.flow_control_for(result[:id])

      if flow_control && (result[:window_updates] || result[:peer_initial_window_size])
        apply_flow_control_updates(flow_control, result)
      end

      writer.write_frames(socket, result[:outgoing_frames])

      if result[:close_connection]
        reactor.close_connection(result[:id])
        return
      end

      reactor.update_http2_state(result)

      result[:completed_requests]&.each do |request|
        stream_id = request[:stream_id]
        remote_addr = result[:remote_addr] || Server::DEFAULT_REMOTE_ADDR

        thread_pool << proc do
          dispatch_stream_request(
            socket, writer, flow_control, stream_id,
            request[:headers], request[:body],
            remote_addr: remote_addr
          )
        end
      end
    end

    private

    # Applies inbound flow-control updates from a parsed result to the
    # connection's `FlowControl`.
    #
    # @param flow_control [FlowControl] the per-connection flow controller
    # @param result [Hash] the parsed result from `process_frames`
    # @return [void]
    #
    # @rbs (FlowControl flow_control, Hash[Symbol, untyped] result) -> void
    def apply_flow_control_updates(flow_control, result)
      result[:window_updates]&.each do |stream_id, increment|
        if stream_id.zero?
          flow_control.add_connection_window(increment)
        else
          flow_control.add_stream_window(stream_id, increment)
        end
      end

      if (new_size = result[:peer_initial_window_size])
        flow_control.set_initial_stream_window(new_size)
      end
    end

    # Dispatches a completed stream request to the Rack app and writes
    # the response back as HTTP/2 frames.
    #
    # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] lock-free frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param headers [Array<Array(String, String)>] request headers
    # @param body [String] request body
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Array[[String, String]] headers, String body, remote_addr: String) -> void
    def dispatch_stream_request(socket, writer, flow_control, stream_id, headers, body, remote_addr:)
      env = build_rack_env(headers, body, remote_addr: remote_addr)
      status, response_headers, response_body = @app.call(env)

      write_http2_response(socket, writer, flow_control, stream_id, status, response_headers, response_body)
    rescue => error
      write_http2_error_response(socket, writer, stream_id)

      if @on_error
        @on_error.call(env, error) rescue nil
      else
        raise
      end
    ensure
      response_body.close if response_body.respond_to?(:close)
      flow_control.discard_stream(stream_id) if flow_control
    end

    # Writes a Rack response as HTTP/2 frames to the socket.
    #
    # DATA frames are partitioned through `flow_control` so each write fits
    # within the peer's per-stream and connection windows.
    #
    # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] lock-free frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param status [Integer] HTTP status code
    # @param headers [Hash] response headers from the Rack application
    # @param body [Object] response body responding to each
    # @return [void]
    #
    # @rbs (OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Integer status, Hash[String, String | Array[String]] headers, untyped body) -> void
    def write_http2_response(socket, writer, flow_control, stream_id, status, headers, body)
      parser = Http2Parser.new

      header_pairs = [[":status", status.to_s]]
      headers.each do |name, value|
        lowered = name.downcase
        next if lowered.start_with?(RACK_HEADER_PREFIX)
        next if HOP_BY_HOP_HEADERS.include?(lowered)

        if value.is_a?(Array)
          value.each { |val| header_pairs << [lowered, val.to_s] }
        else
          header_pairs << [lowered, value.to_s]
        end
      end

      encoded_headers = parser.encode_headers(header_pairs)
      body_chunks = []
      body.each { |chunk| body_chunks << chunk unless chunk.empty? }

      if body_chunks.empty?
        writer.write_frames(socket, [parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, stream_id, encoded_headers)])
        return
      end

      frames = [parser.build_frame(:headers, FLAG_END_HEADERS, stream_id, encoded_headers)]

      last_chunk_index = body_chunks.size - 1
      body_chunks.each_with_index do |chunk, chunk_index|
        offset = 0
        while offset < chunk.bytesize
          remaining = chunk.bytesize - offset
          last_frame = chunk_index == last_chunk_index && remaining <= MAX_FRAME_SIZE
          granted = flow_control.acquire(stream_id, remaining, end_stream: last_frame)
          slice = offset == 0 && granted == chunk.bytesize ? chunk : chunk.byteslice(offset, granted)
          offset += granted
          end_stream = chunk_index == last_chunk_index && offset == chunk.bytesize
          frames << parser.build_frame(:data, end_stream ? FLAG_END_STREAM : 0, stream_id, slice)
        end
      end

      writer.write_frames(socket, frames)
    end

    # Writes a 500 error response as HTTP/2 frames.
    #
    # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] lock-free frame writer for the connection
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @return [void]
    #
    # @rbs (OpenSSL::SSL::SSLSocket socket, Writer writer, Integer stream_id) -> void
    def write_http2_error_response(socket, writer, stream_id)
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":status", "500"]])

      writer.write_frames(
        socket,
        [parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, stream_id, encoded)]
      )
    end

    # Builds a Rack environment hash from HTTP/2 headers and body.
    #
    # Translates HTTP/2 pseudo-headers into Rack-compatible environment keys
    # and populates all required Rack env entries.
    #
    # @param headers [Array<Array(String, String)>] HTTP/2 header pairs
    # @param body [String] the request body
    # @param remote_addr [String] the client IP address
    # @return [Hash] fully populated Rack environment hash
    #
    # @rbs (Array[[String, String]] headers, String body, remote_addr: String) -> Hash[String, untyped]
    def build_rack_env(headers, body, remote_addr:)
      env = {}

      headers.each do |name, value|
        if name.start_with?(":")
          case name
          when ":method"    then env[Rack::REQUEST_METHOD] = value
          when ":path"
            path, query = value.split("?", 2)
            env[Rack::PATH_INFO] = path
            env[Rack::QUERY_STRING] = query || ""
          when ":scheme"    then env[Rack::RACK_URL_SCHEME] = value
          when ":authority" then env[Rack::HTTP_HOST] = value
          end
        elsif name == "content-type"
          env["CONTENT_TYPE"] = value
        elsif name == "content-length"
          env["CONTENT_LENGTH"] = value
        else
          rack_key = "HTTP_#{name.upcase.tr("-", "_")}"
          env[rack_key] = value
        end
      end

      env[Rack::SERVER_PROTOCOL] = SERVER_PROTOCOL
      env[Rack::RACK_VERSION] = Rack::VERSION
      env[Rack::RACK_INPUT] = StringIO.new(body).set_encoding(Encoding::ASCII_8BIT)
      env[Rack::RACK_ERRORS] = $stderr
      env[Rack::RACK_RESPONSE_FINISHED] = []
      env[Rack::RACK_IS_HIJACK] = false

      env[Rack::SCRIPT_NAME] = "" unless env.key?(Rack::SCRIPT_NAME)
      env[Rack::PATH_INFO] = "" unless env.key?(Rack::PATH_INFO)
      env[Rack::QUERY_STRING] = "" unless env.key?(Rack::QUERY_STRING)

      if body.bytesize.positive? && !env.key?("CONTENT_LENGTH")
        env["CONTENT_LENGTH"] = body.bytesize.to_s
      end

      env["REMOTE_ADDR"] = remote_addr

      populate_server_name_and_port(env)

      env
    end

    # Populates SERVER_NAME and SERVER_PORT from the HTTP_HOST header.
    #
    # @param env [Hash] the Rack environment to populate
    # @return [void]
    #
    # @rbs (Hash[String, untyped] env) -> void
    def populate_server_name_and_port(env)
      http_host = env[Rack::HTTP_HOST]

      if http_host
        if http_host.start_with?("[")
          host = http_host[/\A\[([^\]]+)\]/, 1]
          port = http_host[/\]:(\d+)\z/, 1]
        else
          host, port = http_host.split(":", 2)
        end
        env[Rack::SERVER_NAME] ||= host
        env[Rack::SERVER_PORT] ||= port || @server_port.to_s
      else
        env[Rack::SERVER_NAME] ||= Server::DEFAULT_SERVER_NAME
        env[Rack::SERVER_PORT] ||= @server_port.to_s
      end
    end
  end
end
