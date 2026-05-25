# rbs_inline: enabled
# frozen_string_literal: true

require "stringio"

require "atomic-ruby/atom"
require "rack"

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
            socket.write(frame) rescue nil
          end
        end
      end
    end

    FLAG_END_STREAM = 0x1
    FLAG_END_HEADERS = 0x4
    FLAG_ACK = 0x1
    FLAG_PRIORITY = 0x20

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
        initial_window_size: 65_535
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
      connection_window = data[:http2_window] || 65_535
      preface_received = data[:http2_preface_received] || false

      unless preface_received
        if buffer.bytesize >= 24 && buffer.byteslice(0, 24) == Http2Parser.connection_preface
          buffer = buffer.byteslice(24..-1) || ""
          preface_received = true
        else
          return build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, connection_window, preface_received)
        end
      end

      loop do
        parsed = parser.parse_frame(buffer)
        break unless parsed

        frame, consumed = parsed
        buffer = buffer.byteslice(consumed..-1) || ""

        case frame[:type]
        when :settings
          if (frame[:flags] & FLAG_ACK).zero?
            outgoing_frames << parser.build_frame(:settings, FLAG_ACK, 0, nil)
          end

        when :headers
          stream_id = frame[:stream_id]
          header_payload = frame[:payload]

          if (frame[:flags] & FLAG_PRIORITY) != 0
            header_payload = header_payload.byteslice(5..-1) || ""
          end

          decoded_headers, hpack_table = parser.parse_headers(header_payload, hpack_table)
          stream = streams[stream_id] || {}
          stream = stream.merge(headers: decoded_headers)

          if (frame[:flags] & FLAG_END_STREAM) != 0
            stream = stream.merge(end_stream: true)
            completed_requests << {
              stream_id: stream_id,
              headers: decoded_headers,
              body: stream[:body] || ""
            }

            streams.delete(stream_id)
          else
            streams[stream_id] = stream
          end

        when :data
          stream_id = frame[:stream_id]
          stream = streams[stream_id] || {}
          existing_body = stream[:body] || ""
          stream = stream.merge(body: existing_body + frame[:payload])

          if frame[:payload].bytesize.positive?
            connection_window -= frame[:payload].bytesize
            if connection_window < 32_768
              increment = 65_535 - connection_window
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
          parser.parse_window_update(frame[:payload])

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

      build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, connection_window, preface_received)
    end

    # Builds a frozen result hash from the current processing state.
    #
    # @param data [Hash] original connection state
    # @param buffer [String] remaining unparsed data
    # @param hpack_table [Array] updated HPACK dynamic table
    # @param streams [Hash] updated stream states
    # @param outgoing_frames [Array<String>] frames to write to the socket
    # @param completed_requests [Array<Hash>] fully received stream requests
    # @param connection_window [Integer] current connection flow control window
    # @param preface_received [Boolean] whether the connection preface has been received
    # @return [Hash] frozen result hash
    #
    # @rbs (Hash[Symbol, untyped] data, String buffer, Array[untyped] hpack_table, Hash[Integer, Hash[Symbol, untyped]] streams, Array[String] outgoing_frames, Array[Hash[Symbol, untyped]] completed_requests, Integer connection_window, bool preface_received) -> Hash[Symbol, untyped]
    def self.build_result(data, buffer, hpack_table, streams, outgoing_frames, completed_requests, connection_window, preface_received)
      Ractor.make_shareable({
        id: data[:id],
        protocol: :http2,
        buffer: buffer || "",
        hpack_table: hpack_table,
        http2_streams: streams,
        http2_window: connection_window,
        http2_preface_received: preface_received,
        outgoing_frames: outgoing_frames,
        completed_requests: completed_requests,
        remote_addr: data[:remote_addr],
        url_scheme: data[:url_scheme]
      })
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

      writer.write_frames(socket, result[:outgoing_frames])

      reactor.update_http2_state(result)

      result[:completed_requests]&.each do |request|
        stream_id = request[:stream_id]
        remote_addr = result[:remote_addr] || "127.0.0.1"

        thread_pool << proc do
          dispatch_stream_request(
            socket, writer, stream_id,
            request[:headers], request[:body],
            remote_addr: remote_addr
          )
        end
      end
    end

    private

    # Dispatches a completed stream request to the Rack app and writes
    # the response back as HTTP/2 frames.
    #
    # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] lock-free frame writer for the connection
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param headers [Array<Array(String, String)>] request headers
    # @param body [String] request body
    # @param remote_addr [String] the client IP address
    # @return [void]
    #
    # @rbs (OpenSSL::SSL::SSLSocket socket, Writer writer, Integer stream_id, Array[[String, String]] headers, String body, remote_addr: String) -> void
    def dispatch_stream_request(socket, writer, stream_id, headers, body, remote_addr:)
      env = build_rack_env(headers, body, remote_addr: remote_addr)
      status, response_headers, response_body = @app.call(env)

      write_http2_response(socket, writer, stream_id, status, response_headers, response_body)
    rescue => error
      write_http2_error_response(socket, writer, stream_id)

      if @on_error
        @on_error.call(env, error) rescue nil
      else
        raise
      end
    ensure
      response_body.close if response_body.respond_to?(:close)
    end

    # Writes a Rack response as HTTP/2 frames to the socket.
    #
    # @param socket [OpenSSL::SSL::SSLSocket] the connection socket
    # @param writer [Writer] lock-free frame writer for the connection
    # @param stream_id [Integer] the HTTP/2 stream identifier
    # @param status [Integer] HTTP status code
    # @param headers [Hash] response headers from the Rack application
    # @param body [Object] response body responding to each
    # @return [void]
    #
    # @rbs (OpenSSL::SSL::SSLSocket socket, Writer writer, Integer stream_id, Integer status, Hash[String, String | Array[String]] headers, untyped body) -> void
    def write_http2_response(socket, writer, stream_id, status, headers, body)
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

      frames = []
      if body_chunks.empty?
        frames << parser.build_frame(:headers, FLAG_END_STREAM | FLAG_END_HEADERS, stream_id, encoded_headers)
      else
        frames << parser.build_frame(:headers, FLAG_END_HEADERS, stream_id, encoded_headers)

        last_index = body_chunks.size - 1
        body_chunks.each_with_index do |chunk, index|
          flags = index == last_index ? FLAG_END_STREAM : 0
          frames << parser.build_frame(:data, flags, stream_id, chunk)
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
        env[Rack::SERVER_NAME] ||= "localhost"
        env[Rack::SERVER_PORT] ||= @server_port.to_s
      end
    end
  end
end
