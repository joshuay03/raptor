# rbs_inline: enabled
# frozen_string_literal: true

require "stringio"

require "atomic-ruby/atom"
require "atomic-ruby/atomic_boolean"
require "atomic-ruby/atomic_condition_variable"
require "rack"

require_relative "detached_body"
require_relative "http"
require_relative "log"
require_relative "raptor_http2"
require_relative "server"
require_relative "thread_locals"

module Raptor
  # Handles HTTP/2 request processing and Rack application integration.
  #
  class Http2
    EAGER_READ_BUFFER_SIZE = 64 * 1024
    EAGER_MAX_ROUNDS = 8

    FLAG_END_STREAM = 0x1
    FLAG_ACK = 0x1
    FLAG_END_HEADERS = 0x4
    FLAG_PADDED = 0x8
    FLAG_PRIORITY = 0x20

    ERROR_NO_ERROR = 0x0
    ERROR_PROTOCOL_ERROR = 0x1
    ERROR_INTERNAL_ERROR = 0x2
    ERROR_FRAME_SIZE_ERROR = 0x6
    ERROR_REFUSED_STREAM = 0x7
    ERROR_COMPRESSION_ERROR = 0x9

    DEFAULT_WINDOW_SIZE = 65_535
    MAX_FRAME_SIZE = 16_384

    RESPONSE_TRAILERS = "raptor.response_trailers"
    SERVER_PROTOCOL = "HTTP/2"

    REQUEST_PSEUDO_HEADERS = [":method", ":scheme", ":path", ":authority"].freeze
    REQUIRED_REQUEST_PSEUDO_HEADERS = [":method", ":scheme", ":path"].freeze

    class StreamClosedError < StandardError
      # @rbs () -> String
      def message = "HTTP/2 stream closed"
    end

    # Queues concurrent frame writes while the reactor remains the sole
    # owner of the connection socket.
    #
    class Writer
      # @rbs @reactor: Reactor?
      # @rbs @connection_id: Integer?
      # @rbs @write_timeout: Integer

      # Creates a new Writer.
      #
      # @param write_timeout [Integer] per-write socket timeout passed through to {Http.socket_write}
      # @return [void]
      #
      # @rbs (write_timeout: Integer) -> void
      def initialize(write_timeout:)
        @reactor = nil
        @connection_id = nil
        @write_timeout = write_timeout
      end

      # Routes subsequent frame writes through the connection's reactor.
      #
      # @param reactor [Reactor] the reactor that owns the connection
      # @param connection_id [Integer] unique connection identifier
      # @return [void]
      #
      # @rbs (Reactor reactor, Integer connection_id) -> void
      def attach(reactor, connection_id)
        @reactor = reactor
        @connection_id = connection_id
      end

      # Queues frames for the reactor to write. Before attachment, writes
      # directly so the writer remains usable during connection setup.
      #
      # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
      # @param frames [Array<String>, nil] frame bytes to write in order
      # @return [void]
      #
      # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Array[String]? frames) -> void
      def write_frames(socket, frames)
        return if !frames || frames.empty?

        if @reactor
          @reactor.write_http2_frames(@connection_id, frames)
        else
          Http.socket_write(socket, frames.join, timeout: @write_timeout) rescue nil
        end
      end

      # Attaches a response body that outlives its application thread.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param body [DetachedBody] the response body
      # @param finished [Proc] called with the close reason
      # @return [Boolean] whether the reactor accepted the body
      #
      # @rbs (Integer stream_id, DetachedBody body, ^(Symbol) -> void finished) -> bool
      def attach_body(stream_id, body, finished)
        @reactor.attach_http2_body(@connection_id, stream_id, body, finished)
      end
    end

    # Coordinates outbound flow control and stream cancellation without
    # polling or mutexes.
    #
    class FlowControl
      # @rbs @connection_window: Atom
      # @rbs @stream_windows: Atom
      # @rbs @initial_stream_window: Atom
      # @rbs @cancelled_streams: Atom
      # @rbs @available: AtomicConditionVariable

      # Creates a new FlowControl with the spec-default windows.
      #
      # @return [void]
      #
      # @rbs () -> void
      def initialize
        @connection_window = Atom.new(DEFAULT_WINDOW_SIZE)
        @stream_windows = Atom.new({})
        @initial_stream_window = Atom.new(DEFAULT_WINDOW_SIZE)
        @cancelled_streams = Atom.new({})
        @available = AtomicConditionVariable.new
      end

      # Reserves outbound capacity on the given stream, waiting until at
      # least one byte is available on both the connection and stream
      # windows.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param max_bytes [Integer] the largest size the caller would like to send
      # @return [Integer] the number of bytes the caller may now send
      # @raise [StreamClosedError] if the stream or connection has closed
      #
      # @rbs (Integer stream_id, Integer max_bytes) -> Integer
      def acquire(stream_id, max_bytes)
        initial = @initial_stream_window.value
        capped = [max_bytes, MAX_FRAME_SIZE].min

        @available.wait do
          check(stream_id)
          stream_window = @stream_windows.value[stream_id] || initial
          capped_full = [capped, stream_window].min
          granted = capped_full.positive? ? reserve_connection(capped_full) : 0

          if granted.positive?
            @stream_windows.swap do |windows|
              current = windows[stream_id] || initial
              windows.merge(stream_id => current - granted)
            end
            granted
          end
        end
      end

      # Reserves outbound capacity without waiting for a window update.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param max_bytes [Integer] the largest size the caller would like to send
      # @return [Integer] available bytes, or 0 when flow control is exhausted
      # @raise [StreamClosedError] if the stream or connection has closed
      #
      # @rbs (Integer stream_id, Integer max_bytes) -> Integer
      def try_acquire(stream_id, max_bytes)
        check(stream_id)
        initial = @initial_stream_window.value
        stream_window = @stream_windows.value[stream_id] || initial
        capped = [max_bytes, MAX_FRAME_SIZE, stream_window].min
        return 0 unless capped.positive?

        granted = reserve_connection(capped)
        if granted.positive?
          @stream_windows.swap do |windows|
            current = windows[stream_id] || initial
            windows.merge(stream_id => current - granted)
          end
        end
        granted
      end

      # Increments the connection-level send window by `increment` bytes.
      #
      # @param increment [Integer] the byte count to add
      # @return [void]
      #
      # @rbs (Integer increment) -> void
      def add_connection_window(increment)
        @connection_window.swap { |window| window + increment }
        @available.broadcast
      end

      # Increments the send window for the given stream by `increment` bytes.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param increment [Integer] the byte count to add
      # @return [void]
      #
      # @rbs (Integer stream_id, Integer increment) -> void
      def add_stream_window(stream_id, increment)
        initial = @initial_stream_window.value
        @stream_windows.swap do |windows|
          current = windows[stream_id] || initial
          windows.merge(stream_id => current + increment)
        end
        @available.broadcast
      end

      # Updates the peer's `SETTINGS_INITIAL_WINDOW_SIZE`. Shifts every
      # existing stream window by the delta as required by RFC 9113 section 6.9.2.
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

        @stream_windows.swap do |windows|
          windows.transform_values { |size| size + delta }
        end
        @available.broadcast
      end

      # Raises when the given stream can no longer write a response.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @return [void]
      # @raise [StreamClosedError] if the stream or connection has closed
      #
      # @rbs (Integer stream_id) -> void
      def check(stream_id)
        cancelled = @cancelled_streams.value
        raise StreamClosedError if cancelled.key?(0) || cancelled.key?(stream_id)
      end

      # Cancels pending and future writes for the given stream.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @return [void]
      #
      # @rbs (Integer stream_id) -> void
      def cancel_stream(stream_id)
        @cancelled_streams.swap { |streams| streams.merge(stream_id => true) }
        @available.broadcast
      end

      # Cancels pending and future writes for the connection.
      #
      # @return [void]
      #
      # @rbs () -> void
      def close
        @cancelled_streams.swap { |streams| streams.merge(0 => true) }
        @available.broadcast
      end

      # Discards any per-stream tracking for the given stream.
      #
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @return [void]
      #
      # @rbs (Integer stream_id) -> void
      def discard_stream(stream_id)
        @stream_windows.swap do |windows|
          next windows unless windows.key?(stream_id)

          pruned = windows.dup
          pruned.delete(stream_id)
          pruned
        end
        @cancelled_streams.swap do |streams|
          next streams unless streams.key?(stream_id)

          pruned = streams.dup
          pruned.delete(stream_id)
          pruned
        end
      end

      private

      # Reserves up to `capped` bytes from the connection window.
      #
      # @param capped [Integer] the largest reservation the caller will accept
      # @return [Integer] bytes granted, or 0 when the window is exhausted
      #
      # @rbs (Integer capped) -> Integer
      def reserve_connection(capped)
        granted = 0
        @connection_window.swap do |window|
          granted = [window, capped].min
          granted.positive? ? window - granted : window
        end
        granted
      end
    end

    # Adapts one HTTP/2 response stream to Rack's streaming body interface.
    #
    class ResponseStream
      # @rbs @socket: TCPSocket | OpenSSL::SSL::SSLSocket
      # @rbs @writer: Writer
      # @rbs @flow_control: FlowControl
      # @rbs @stream_id: Integer
      # @rbs @trailers: Hash[String, String | Array[String]]
      # @rbs @parser: Http2Parser
      # @rbs @bytes_written: Integer
      # @rbs @closed: bool

      # Returns the number of response body bytes written to the stream.
      #
      # @return [Integer]
      attr_reader :bytes_written #: Integer

      # Creates a response stream for a Rack streaming body.
      #
      # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
      # @param writer [Writer] frame writer for the connection
      # @param flow_control [FlowControl] per-connection outbound flow controller
      # @param stream_id [Integer] the HTTP/2 stream identifier
      # @param trailers [Hash] trailing response headers populated by the Rack application
      # @return [void]
      #
      # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Hash[String, String | Array[String]] trailers) -> void
      def initialize(socket, writer, flow_control, stream_id, trailers)
        @socket = socket
        @writer = writer
        @flow_control = flow_control
        @stream_id = stream_id
        @trailers = trailers
        @parser = Http2Parser.new
        @bytes_written = 0
        @closed = false
      end

      # Rejects reads; streaming responses are write-only.
      #
      # @raise [IOError] always
      #
      # @rbs (*untyped) -> bot
      def read(*)
        raise IOError, "not opened for reading"
      end

      # Writes response body bytes to the stream.
      #
      # @param chunk [String] response body bytes
      # @return [Integer] number of bytes written
      # @raise [IOError] if the stream has already closed
      # @raise [TypeError] if the chunk is not a String
      # @raise [StreamClosedError] if the stream or connection has closed
      #
      # @rbs (String chunk) -> Integer
      def write(chunk)
        raise IOError, "closed stream" if @closed
        raise TypeError, "body must yield String values" unless chunk.is_a?(String)

        offset = 0
        while offset < chunk.bytesize
          granted = @flow_control.acquire(@stream_id, chunk.bytesize - offset)
          slice = offset.zero? && granted == chunk.bytesize ? chunk : chunk.byteslice(offset, granted)
          offset += granted
          @writer.write_frames(@socket, [@parser.build_frame(:data, 0, @stream_id, slice)])
        end

        @bytes_written += chunk.bytesize
        chunk.bytesize
      end

      # Writes response body bytes and returns the stream.
      #
      # @param chunk [String] response body bytes
      # @return [ResponseStream]
      #
      # @rbs (String chunk) -> ResponseStream
      def <<(chunk)
        write(chunk)
        self
      end

      # Flushes the stream. Frames are already handed to the writer as they
      # are produced.
      #
      # @return [ResponseStream]
      #
      # @rbs () -> ResponseStream
      def flush
        self
      end

      # Finishes the stream.
      #
      # @return [void]
      # @raise [StreamClosedError] if the stream or connection has closed
      #
      # @rbs () -> void
      def close
        return if @closed

        @flow_control.check(@stream_id)
        @closed = true
        if @trailers.empty?
          frame = @parser.build_frame(:data, FLAG_END_STREAM, @stream_id, nil)
        else
          encoded = @parser.encode_response_trailers(@trailers)
          frame = @parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, @stream_id, encoded)
        end
        @writer.write_frames(@socket, [frame])
      end

      # Closes the unsupported read side of the stream.
      #
      # @raise [IOError] always
      #
      # @rbs () -> bot
      def close_read
        raise IOError, "closing non-duplex IO for reading"
      end

      # Finishes the writable side of the stream.
      #
      # @return [void]
      #
      # @rbs () -> void
      def close_write
        close
      end

      # Returns whether the stream has finished.
      #
      # @return [Boolean]
      #
      # @rbs () -> bool
      def closed?
        @closed
      end
    end

    # Advances HTTP/2 frame parsing from the connection buffer, returning
    # updated connection state along with any outgoing protocol frames and
    # completed stream requests.
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
      cancelled_streams = []
      window_updates = []
      ping_acknowledgements = []
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
          return build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, cancelled_streams, window_updates, ping_acknowledgements, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, false)
        end
      end

      loop do
        # Reject oversized frames before waiting for their payload.
        if buffer.bytesize >= 3 && (buffer.getbyte(0) << 16 | buffer.getbyte(1) << 8 | buffer.getbyte(2)) > MAX_FRAME_SIZE
          goaway_error = ERROR_FRAME_SIZE_ERROR
          break
        end

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
          if frame[:flags].nobits?(FLAG_ACK)
            parsed_settings = parser.parse_settings(frame[:payload])
            peer_initial_window_size = parsed_settings[:initial_window_size] if parsed_settings.key?(:initial_window_size)
            outgoing_frames << parser.build_frame(:settings, FLAG_ACK, 0, nil)
          end

        when :headers
          stream_id = frame[:stream_id]
          header_payload = unpadded_payload(frame)
          trailers = streams.key?(stream_id)

          unless header_payload
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          unless trailers
            if stream_id.even? || stream_id <= last_client_stream_id
              goaway_error = ERROR_PROTOCOL_ERROR
              break
            end
            last_client_stream_id = stream_id
          end

          if frame[:flags].anybits?(FLAG_PRIORITY)
            header_payload = header_payload.byteslice(5..-1) || ""
          end

          end_stream = frame[:flags].anybits?(FLAG_END_STREAM)

          if frame[:flags].anybits?(FLAG_END_HEADERS)
            decoded_headers, hpack_table = parser.parse_headers(header_payload, hpack_table)
            streams, completed_requests = complete_header_block(
              streams, completed_requests, outgoing_frames, parser,
              stream_id, decoded_headers, end_stream, trailers
            )
          else
            pending_headers = { stream_id: stream_id, buffer: header_payload, end_stream: end_stream, trailers: trailers }
          end

        when :continuation
          if !pending_headers || frame[:stream_id] != pending_headers[:stream_id]
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          pending_headers = pending_headers.merge(buffer: pending_headers[:buffer] + frame[:payload])
          if pending_headers[:buffer].bytesize > Http2Parser::MAX_HEADER_LIST_SIZE
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          if frame[:flags].anybits?(FLAG_END_HEADERS)
            stream_id = pending_headers[:stream_id]
            decoded_headers, hpack_table = parser.parse_headers(pending_headers[:buffer], hpack_table)
            streams, completed_requests = complete_header_block(
              streams, completed_requests, outgoing_frames, parser,
              stream_id, decoded_headers, pending_headers[:end_stream], pending_headers[:trailers]
            )
            pending_headers = nil
          end

        when :data
          stream_id = frame[:stream_id]
          chunk = unpadded_payload(frame)

          if stream_id.zero? || stream_id > last_client_stream_id || !chunk
            goaway_error = ERROR_PROTOCOL_ERROR
            break
          end

          # DATA for closed streams still counts toward connection flow control.
          connection_window -= frame[:length]
          if connection_window < DEFAULT_WINDOW_SIZE / 2
            outgoing_frames << parser.build_frame(:window_update, 0, 0, [DEFAULT_WINDOW_SIZE - connection_window].pack("N"))
            connection_window = DEFAULT_WINDOW_SIZE
          end

          stream = streams[stream_id]
          next unless stream

          stream_window_used = (stream[:window_used] || 0) + frame[:length]
          if stream_window_used >= DEFAULT_WINDOW_SIZE / 2 && frame[:flags].nobits?(FLAG_END_STREAM)
            outgoing_frames << parser.build_frame(:window_update, 0, stream_id, [stream_window_used].pack("N"))
            stream_window_used = 0
          end
          stream = stream.merge(body: (stream[:body] || "") + chunk, window_used: stream_window_used)

          if frame[:flags].anybits?(FLAG_END_STREAM)
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
          if frame[:flags].anybits?(FLAG_ACK)
            ping_acknowledgements << frame[:payload]
          else
            outgoing_frames << parser.build_frame(:ping, FLAG_ACK, 0, frame[:payload])
          end

        when :goaway
          break

        when :rst_stream
          stream_id = frame[:stream_id]
          streams.delete(stream_id)
          completed_requests.reject! { |request| request[:stream_id] == stream_id }
          cancelled_streams << stream_id
        end
      rescue Http2ParserError
        # A failed header decode can desynchronize HPACK state for the whole connection.
        goaway_error = if frame[:type] == :headers || frame[:type] == :continuation
          ERROR_COMPRESSION_ERROR
        else
          ERROR_FRAME_SIZE_ERROR
        end
        break
      end

      if goaway_error
        goaway_payload = [last_client_stream_id, goaway_error].pack("NN")
        outgoing_frames << parser.build_frame(:goaway, 0, 0, goaway_payload)
      end

      build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, cancelled_streams, window_updates, ping_acknowledgements, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, !!goaway_error)
    end

    # Returns a DATA or HEADERS payload without padding, or nil if padding
    # is invalid.
    #
    # @param frame [Hash] the parsed frame
    # @return [String, nil]
    #
    # @rbs (Hash[Symbol, untyped] frame) -> String?
    def self.unpadded_payload(frame)
      payload = frame[:payload]
      return payload if frame[:flags].nobits?(FLAG_PADDED)

      pad_length = payload.getbyte(0)
      payload.byteslice(1, payload.bytesize - 1 - pad_length) if pad_length && pad_length < payload.bytesize
    end
    private_class_method :unpadded_payload

    # Returns whether request pseudo-headers violate RFC 9113 section 8.3.
    #
    # @param headers [Array<Array(String, String)>] decoded header pairs
    # @return [Boolean]
    #
    # @rbs (Array[[String, String]] headers) -> bool
    def self.invalid_pseudo_headers?(headers)
      seen_pseudo = {}
      seen_regular = false

      headers.each do |name, _value|
        if name.start_with?(":")
          return true if seen_regular
          return true unless REQUEST_PSEUDO_HEADERS.include?(name)
          return true if seen_pseudo[name]

          seen_pseudo[name] = true
        else
          seen_regular = true
        end
      end

      return false if seen_pseudo[":method"] && headers.assoc(":method")&.last == "CONNECT"

      REQUIRED_REQUEST_PSEUDO_HEADERS.any? { |name| !seen_pseudo[name] }
    end
    private_class_method :invalid_pseudo_headers?

    # Applies one complete request header block to its stream, resetting
    # malformed initial headers or trailers and completing valid trailers.
    #
    # @param streams [Hash] current open-stream map
    # @param completed_requests [Array<Hash>] accumulator of completed stream requests
    # @param outgoing_frames [Array<String>] accumulator of protocol response frames
    # @param parser [Http2Parser] frame parser and encoder
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param decoded_headers [Array<Array(String, String)>] decoded header pairs
    # @param end_stream [Boolean] whether the source frame had END_STREAM set
    # @param trailers [Boolean] whether this is a trailing header block
    # @return [Array(Hash, Array<Hash>)] updated streams and completed requests
    #
    # @rbs (Hash[Integer, Hash[Symbol, untyped]] streams, Array[Hash[Symbol, untyped]] completed_requests, Array[String] outgoing_frames, Http2Parser parser, Integer stream_id, Array[[String, String]] decoded_headers, bool end_stream, bool trailers) -> [Hash[Integer, Hash[Symbol, untyped]], Array[Hash[Symbol, untyped]]]
    def self.complete_header_block(streams, completed_requests, outgoing_frames, parser, stream_id, decoded_headers, end_stream, trailers)
      invalid = if trailers
        !end_stream || decoded_headers.any? { |name, _value| name.start_with?(":") }
      else
        invalid_pseudo_headers?(decoded_headers)
      end

      if invalid
        streams.delete(stream_id)
        outgoing_frames << parser.build_frame(:rst_stream, 0, stream_id, [ERROR_PROTOCOL_ERROR].pack("N"))
      elsif trailers
        stream = streams.delete(stream_id)
        completed_requests << {
          stream_id: stream_id,
          headers: stream[:headers],
          body: stream[:body] || ""
        }
      else
        streams, completed_requests = finalize_headers(streams, completed_requests, stream_id, decoded_headers, end_stream)
      end

      [streams, completed_requests]
    end
    private_class_method :complete_header_block

    # Merges a decoded header block into the stream's accumulated state,
    # promoting the stream to `completed_requests` when END_STREAM is set.
    #
    # @param streams [Hash] current open-stream map
    # @param completed_requests [Array<Hash>] accumulator of completed stream requests
    # @param stream_id [Integer] the HTTP/2 stream identifier
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
    # @param cancelled_streams [Array<Integer>] streams reset by the peer
    # @param window_updates [Array<Array(Integer, Integer)>] inbound WINDOW_UPDATE pairs as [stream_id, increment]
    # @param ping_acknowledgements [Array<String>] acknowledged PING payloads
    # @param peer_initial_window_size [Integer, nil] new SETTINGS_INITIAL_WINDOW_SIZE announced by the peer
    # @param connection_window [Integer] current connection flow control window
    # @param preface_received [Boolean] whether the connection preface has been received
    # @param last_client_stream_id [Integer] highest client-initiated stream ID seen
    # @param pending_headers [Hash, nil] in-progress HEADERS+CONTINUATION assembly
    # @param close_connection [Boolean] whether the connection should be closed after writing outgoing frames
    # @return [Hash] frozen result hash
    #
    # @rbs (Hash[Symbol, untyped] data, String buffer, Array[untyped] hpack_table, Hash[Integer, Hash[Symbol, untyped]] streams, Array[String] outgoing_frames, Array[Hash[Symbol, untyped]] completed_requests, Array[Integer] cancelled_streams, Array[[Integer, Integer]] window_updates, Array[String] ping_acknowledgements, Integer? peer_initial_window_size, Integer connection_window, bool preface_received, Integer last_client_stream_id, Hash[Symbol, untyped]? pending_headers, bool close_connection) -> Hash[Symbol, untyped]
    def self.build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, cancelled_streams, window_updates, ping_acknowledgements, peer_initial_window_size, connection_window, preface_received, last_client_stream_id, pending_headers, close_connection)
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
      result[:cancelled_streams] = cancelled_streams unless cancelled_streams.empty?
      result[:window_updates] = window_updates unless window_updates.empty?
      result[:ping_acknowledgements] = ping_acknowledgements unless ping_acknowledgements.empty?
      result[:peer_initial_window_size] = peer_initial_window_size if peer_initial_window_size
      Ractor.make_shareable(result)
    end
    private_class_method :build_result

    # @rbs @app: ^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped]
    # @rbs @server_port_string: String
    # @rbs @write_timeout: Integer
    # @rbs @access_log_io: IO?
    # @rbs @clean_thread_locals: bool
    # @rbs @clean_fiber_locals: bool
    # @rbs @on_error: (^(Hash[String, untyped]?, Exception) -> void)?
    # @rbs @running: AtomicBoolean
    # @rbs @initial_settings_frame: String

    # Creates a new Http2 handler.
    #
    # @param app [#call] the Rack application to dispatch requests to
    # @param server_port [Integer] port number used to populate SERVER_PORT in the Rack env
    # @param connection_options [Hash] per-connection settings shared across protocols
    # @option connection_options [Integer] :write_timeout per-write socket timeout in seconds
    # @param http2_options [Hash] HTTP/2-specific settings
    # @option http2_options [Integer] :max_concurrent_streams maximum HTTP/2 concurrent streams per connection
    # @param access_log_io [IO, nil] IO to write Common Log Format access entries to, or nil to disable
    # @param clean_thread_locals [Boolean] whether to clear application thread locals after each request
    # @param clean_fiber_locals [Boolean] whether to process each request in a fresh Fiber
    # @param on_error [#call, nil] callback invoked with (env, exception) when the Rack app raises
    # @return [void]
    #
    # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, Integer server_port, ?connection_options: Hash[Symbol, untyped], ?http2_options: Hash[Symbol, untyped], ?access_log_io: IO?, ?clean_thread_locals: bool, ?clean_fiber_locals: bool, ?on_error: (^(Hash[String, untyped]?, Exception) -> void)?) -> void
    def initialize(app, server_port, connection_options: {}, http2_options: {}, access_log_io: nil, clean_thread_locals: true, clean_fiber_locals: false, on_error: nil)
      @app = app
      @server_port_string = server_port.to_s.freeze
      @write_timeout = connection_options[:write_timeout] || Http::WRITE_TIMEOUT
      @access_log_io = access_log_io
      @clean_thread_locals = clean_thread_locals
      @clean_fiber_locals = clean_fiber_locals
      @on_error = on_error
      @running = AtomicBoolean.new(true)

      parser = Http2Parser.new
      settings_payload = parser.build_settings(
        max_concurrent_streams: http2_options[:max_concurrent_streams],
        initial_window_size: DEFAULT_WINDOW_SIZE,
        max_header_list_size: Http2Parser::MAX_HEADER_LIST_SIZE
      )
      @initial_settings_frame = parser.build_frame(:settings, 0, 0, settings_payload).freeze
    end

    # Returns a Ractor-safe proc that parses HTTP/2 frames from the
    # state hash's buffered bytes.
    #
    # @return [Proc]
    #
    # @rbs () -> ^(Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
    def parser_worker
      proc do |data|
        Http2.process_frames(data)
      end
    end

    # Stops new stream dispatch and asks clients to finish streams already
    # handed to the application.
    #
    # @param reactor [Reactor] the reactor managing HTTP/2 connections
    # @return [void]
    #
    # @rbs (Reactor reactor) -> void
    def shutdown(reactor)
      @running.make_false
      parser = Http2Parser.new
      reactor.drain_http2 do |stream_id|
        payload = [stream_id, ERROR_NO_ERROR].pack("NN")
        parser.build_frame(:goaway, 0, 0, payload)
      end
    end

    # Sends the server SETTINGS frame on a freshly negotiated HTTP/2
    # connection, then eagerly reads and parses the first client frame
    # batch, dispatching completed streams directly to the thread pool.
    # Falls back to the reactor when no initial data is ready.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param id [Integer] unique connection identifier
    # @param reactor [Reactor] the reactor managing the connection
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param remote_addr [String] the client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Integer id, Reactor reactor, AtomicThreadPool thread_pool, String remote_addr, String url_scheme) -> void
    def eager_accept(socket, id, reactor, thread_pool, remote_addr, url_scheme)
      unless @running.true?
        socket.close rescue nil
        return
      end

      writer = create_writer
      flow_control = FlowControl.new
      ping_payload = [id].pack("Q>")
      ping_frame = Http2Parser.new.build_frame(:ping, 0, 0, ping_payload).freeze
      initial_state = {
        id: id,
        protocol: :http2,
        remote_addr: remote_addr,
        url_scheme: url_scheme
      }

      reactor.attach_http2(
        id: id,
        socket: socket,
        state: initial_state,
        writer: writer,
        flow_control: flow_control,
        ping_frame: ping_frame,
        ping_payload: ping_payload
      )
      unless @running.true?
        reactor.close_connection(id)
        return
      end

      socket.write(@initial_settings_frame) rescue nil

      buffer = begin
        socket.read_nonblock(EAGER_READ_BUFFER_SIZE)
      rescue IO::WaitReadable
        reactor.watch(id)
        return
      rescue EOFError, IOError, SystemCallError
        reactor.close_connection(id)
        return
      end

      while socket.respond_to?(:pending) && socket.pending.positive?
        buffer << socket.read_nonblock(socket.pending)
      end

      result = Http2.process_frames(initial_state.merge(buffer: buffer))
      handle_parsed_request(result, reactor, thread_pool)
    rescue => error
      Log.rescued_error(error)
      reactor.close_connection(id)
    end

    # Handles a parsed HTTP/2 result. Writes outgoing frames, dispatches
    # completed stream requests to the thread pool, and eagerly consumes
    # further buffered frame batches before returning control to the
    # reactor.
    #
    # @param parsed_request [Hash] the parsed result produced by {.process_frames}
    # @param reactor [Reactor] the reactor managing the connection
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] parsed_request, Reactor reactor, AtomicThreadPool thread_pool) -> void
    def handle_parsed_request(parsed_request, reactor, thread_pool)
      socket = reactor.socket_for(parsed_request[:id])
      return unless socket

      writer = reactor.writer_for(parsed_request[:id])
      flow_control = reactor.flow_control_for(parsed_request[:id])

      rounds = 0
      loop do
        reactor.acknowledge_http2_ping(parsed_request[:id], parsed_request[:ping_acknowledgements])
        parsed_request[:cancelled_streams]&.each do |stream_id|
          flow_control.cancel_stream(stream_id)
          reactor.cancel_http2_body(parsed_request[:id], stream_id)
        end

        if flow_control && (parsed_request[:window_updates]&.any? || parsed_request[:peer_initial_window_size])
          apply_flow_control_updates(flow_control, parsed_request)
          reactor.resume_http2_bodies(parsed_request[:id])
        end

        writer.write_frames(socket, parsed_request[:outgoing_frames])

        if parsed_request[:close_connection]
          reactor.close_connection(parsed_request[:id])
          return
        end

        parsed_request[:completed_requests]&.each do |request|
          stream_id = request[:stream_id]
          remote_addr = parsed_request[:remote_addr] || Server::DEFAULT_REMOTE_ADDR

          unless reactor.dispatch_http2_stream(parsed_request[:id], stream_id)
            write_reset_stream(socket, writer, stream_id, ERROR_REFUSED_STREAM)
            next
          end

          thread_pool << proc do
            dispatch_stream_request(
              socket, writer, flow_control, stream_id,
              request[:headers], request[:body],
              remote_addr: remote_addr
            )
          end
        end

        rounds += 1
        break if rounds >= EAGER_MAX_ROUNDS
        break if thread_pool.queue_size >= thread_pool.size

        next_batch = eager_read_next_batch(socket)
        break unless next_batch

        parsed_request = Http2.process_frames(parsed_request.merge(buffer: parsed_request[:buffer] + next_batch))
      end

      reactor.update_state(parsed_request)
    end

    private

    # Creates a per-connection {Writer} configured with the handler's write timeout.
    #
    # @return [Writer] a new per-connection frame writer
    #
    # @rbs () -> Writer
    def create_writer
      Writer.new(write_timeout: @write_timeout)
    end

    # Applies inbound flow-control updates from a parsed result to the
    # connection's {FlowControl}.
    #
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param result [Hash] the parsed result from {.process_frames}
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

    # Reads the next frame batch from `socket` if it has already arrived,
    # without waiting on the shared collector thread.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @return [String, nil] the bytes read, or nil if nothing was available
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket) -> String?
    def eager_read_next_batch(socket)
      return unless socket.wait_readable(0)

      buffer = begin
        socket.read_nonblock(EAGER_READ_BUFFER_SIZE)
      rescue IO::WaitReadable, EOFError, IOError, SystemCallError
        return
      end

      while socket.respond_to?(:pending) && socket.pending.positive?
        buffer << socket.read_nonblock(socket.pending)
      end

      buffer
    end

    # Dispatches a completed stream request to the Rack app and writes
    # the response back as HTTP/2 frames.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param headers [Array<Array(String, String)>] request headers
    # @param body [String] request body
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Array[[String, String]] headers, String body, remote_addr: String) -> void
    def dispatch_stream_request(socket, writer, flow_control, stream_id, headers, body, remote_addr:)
      if @clean_fiber_locals
        Fiber.new { perform_stream_request(socket, writer, flow_control, stream_id, headers, body, remote_addr: remote_addr) }.resume
      else
        perform_stream_request(socket, writer, flow_control, stream_id, headers, body, remote_addr: remote_addr)
      end
    ensure
      ThreadLocals.clear if @clean_thread_locals
    end

    # Calls the Rack app and writes its response for one stream.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param headers [Array<Array(String, String)>] request headers
    # @param body [String] request body
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Array[[String, String]] headers, String body, remote_addr: String) -> void
    def perform_stream_request(socket, writer, flow_control, stream_id, headers, body, remote_addr:)
      env = nil
      status = nil
      response_headers = nil
      response_started = false
      detached = false

      flow_control.check(stream_id)
      env = build_rack_env(headers, body, socket, writer, flow_control, stream_id, remote_addr: remote_addr)
      status, response_headers, response_body = @app.call(env)

      no_body = env[Rack::REQUEST_METHOD] == "HEAD" || Http.no_entity_body_status?(status)
      if response_body.is_a?(DetachedBody) && !no_body
        finished = proc do |reason|
          error = StreamClosedError.new unless reason == :closed
          write_access_log(env, status, "-", remote_addr) if @access_log_io
          Http.call_response_finished(env, status, response_headers, error)
          flow_control.discard_stream(stream_id)
        end
        write_detached_response(socket, writer, flow_control, stream_id, status, response_headers, response_body, finished) do
          response_started = true
        end
        detached = true
        return
      end

      response_size = write_response(
        socket,
        writer,
        flow_control,
        stream_id,
        status,
        response_headers,
        response_body,
        trailers: env[RESPONSE_TRAILERS],
        request_method: env[Rack::REQUEST_METHOD]
      ) { response_started = true }
      if response_body.is_a?(DetachedBody)
        response_body.finish(:closed)
      elsif response_body.respond_to?(:close)
        response_body.close
      end
      write_access_log(env, status, response_size, remote_addr) if @access_log_io
      Http.call_response_finished(env, status, response_headers, nil)
    rescue StreamClosedError => error
      Http.call_response_finished(env, status, response_headers, error)
    rescue => error
      Http.call_response_finished(env, status, response_headers, error)
      if response_started
        write_reset_stream(socket, writer, stream_id, ERROR_INTERNAL_ERROR)
      else
        write_error_response(socket, writer, stream_id)
      end

      if @on_error
        @on_error.call(env, error) rescue nil
      else
        raise
      end
    ensure
      flow_control.discard_stream(stream_id) if flow_control && !detached
    end

    # Starts a detached HTTP/2 response after writing its response headers.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param status [Integer] HTTP status code
    # @param headers [Hash] response headers from the Rack application
    # @param body [DetachedBody] the response body
    # @param finished [Proc] called with the close reason
    # @yield once the response headers are queued
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Integer status, Hash[String, String | Array[String]] headers, DetachedBody body, ^(Symbol) -> void finished) { () -> void } -> void
    def write_detached_response(socket, writer, flow_control, stream_id, status, headers, body, finished)
      flow_control.check(stream_id)
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(status, headers)
      writer.write_frames(socket, [parser.build_frame(:headers, FLAG_END_HEADERS, stream_id, encoded)])
      yield
      attached = writer.attach_body(stream_id, body, finished)
      write_reset_stream(socket, writer, stream_id, ERROR_REFUSED_STREAM) unless attached
    end

    # Writes a Rack response as HTTP/2 frames to the socket, partitioning
    # DATA frames through `flow_control` to fit within the peer's windows.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param status [Integer] HTTP status code
    # @param headers [Hash] response headers from the Rack application
    # @param body [Object] response body responding to each
    # @param trailers [Hash] trailing response headers populated by the Rack application
    # @param request_method [String] request method used to suppress HEAD response bodies
    # @yield once the response headers are queued
    # @return [String] the response body size in bytes
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Integer status, Hash[String, String | Array[String]] headers, untyped body, trailers: Hash[String, String | Array[String]], request_method: String) ?{ () -> void } -> String
    def write_response(socket, writer, flow_control, stream_id, status, headers, body, trailers:, request_method:)
      parser = Http2Parser.new

      encoded_headers = parser.encode_response_headers(status, headers)
      flow_control.check(stream_id)
      no_body = request_method == "HEAD" || Http.no_entity_body_status?(status)
      if no_body
        writer.write_frames(socket, [parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, stream_id, encoded_headers)])
        yield if block_given?
        return "0"
      end

      writer.write_frames(socket, [parser.build_frame(:headers, FLAG_END_HEADERS, stream_id, encoded_headers)])
      yield if block_given?

      stream = ResponseStream.new(socket, writer, flow_control, stream_id, trailers)
      if body.respond_to?(:each)
        body.each { |chunk| stream.write(chunk) }
      else
        body.call(stream)
      end
      stream.close

      stream.bytes_written.to_s
    end

    # Sends an HTTP 103 Early Hints response.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param hints [Hash] response headers to send as early hints
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, Hash[String, String | Array[String]] hints) -> void
    def send_early_hints(socket, writer, flow_control, stream_id, hints)
      return if hints.empty?

      flow_control.check(stream_id)
      parser = Http2Parser.new
      encoded = parser.encode_response_headers(103, hints)
      writer.write_frames(socket, [parser.build_frame(:headers, FLAG_END_HEADERS, stream_id, encoded)])
    end

    # Resets one HTTP/2 stream with the given error code.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param error_code [Integer] the HTTP/2 error code
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, Integer stream_id, Integer error_code) -> void
    def write_reset_stream(socket, writer, stream_id, error_code)
      parser = Http2Parser.new
      frame = parser.build_frame(:rst_stream, 0, stream_id, [error_code].pack("N"))
      writer.write_frames(socket, [frame])
    end

    # Writes a 500 error response as HTTP/2 frames.
    #
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @return [void]
    #
    # @rbs (TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, Integer stream_id) -> void
    def write_error_response(socket, writer, stream_id)
      parser = Http2Parser.new
      encoded = parser.encode_headers([[":status", "500"]])

      writer.write_frames(
        socket,
        [parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, stream_id, encoded)]
      )
    end

    # Builds a Rack environment hash from HTTP/2 headers and body.
    #
    # @param headers [Array<Array(String, String)>] HTTP/2 header pairs
    # @param body [String] the request body
    # @param socket [TCPSocket, OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] frame writer for the connection
    # @param flow_control [FlowControl] per-connection outbound flow controller
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param remote_addr [String] the client IP address
    # @return [Hash] fully populated Rack environment hash
    #
    # @rbs (Array[[String, String]] headers, String body, TCPSocket | OpenSSL::SSL::SSLSocket socket, Writer writer, FlowControl flow_control, Integer stream_id, remote_addr: String) -> Hash[String, untyped]
    def build_rack_env(headers, body, socket, writer, flow_control, stream_id, remote_addr:)
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
          env[Http::CONTENT_TYPE] = value
        elsif name == "content-length"
          env[Http::CONTENT_LENGTH] = value
        else
          rack_key = "HTTP_#{name.upcase.tr("-", "_")}"
          if (existing = env[rack_key])
            separator = rack_key == Rack::HTTP_COOKIE ? "; " : ", "
            env[rack_key] = "#{existing}#{separator}#{value}"
          else
            env[rack_key] = value
          end
        end
      end

      env[Rack::SERVER_PROTOCOL] = SERVER_PROTOCOL
      env[Rack::RACK_VERSION] = Rack::VERSION
      env[Rack::RACK_INPUT] = StringIO.new(body).set_encoding(Encoding::ASCII_8BIT)
      env[Rack::RACK_ERRORS] = $stderr
      env[Rack::RACK_RESPONSE_FINISHED] = []
      env[Rack::RACK_EARLY_HINTS] = proc do |hints|
        send_early_hints(socket, writer, flow_control, stream_id, hints) rescue nil
      end
      env[Rack::RACK_IS_HIJACK] = false

      env[Rack::SCRIPT_NAME] = "" unless env.key?(Rack::SCRIPT_NAME)
      env[Rack::PATH_INFO] = "" unless env.key?(Rack::PATH_INFO)
      env[Rack::QUERY_STRING] = "" unless env.key?(Rack::QUERY_STRING)

      if body.bytesize.positive? && !env.key?(Http::CONTENT_LENGTH)
        env[Http::CONTENT_LENGTH] = body.bytesize.to_s
      end

      env[Http::REMOTE_ADDR] = remote_addr
      env[Http::SERVER_SOFTWARE] = Http::SERVER_SOFTWARE_VALUE
      env[Http::HTTP_VERSION] = SERVER_PROTOCOL
      env[RESPONSE_TRAILERS] = {}

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
        env[Rack::SERVER_PORT] ||= port || @server_port_string
      else
        env[Rack::SERVER_NAME] ||= Server::DEFAULT_SERVER_NAME
        env[Rack::SERVER_PORT] ||= @server_port_string
      end
    end

    # Writes a completed request to the access log.
    #
    # @param env [Hash] the Rack environment
    # @param status [Integer] the response status code
    # @param size [String] the response body size in bytes, or `-` if unknown
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (Hash[String, untyped] env, Integer status, String size, String remote_addr) -> void
    def write_access_log(env, status, size, remote_addr)
      Http.write_access_log(@access_log_io, env, status, size, remote_addr)
    end
  end
end
