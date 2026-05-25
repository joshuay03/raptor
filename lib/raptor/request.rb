# rbs_inline: enabled
# frozen_string_literal: true

require "socket"
require "stringio"
require "tempfile"

require "rack"

require_relative "raptor_http"

module Raptor
  # Handles HTTP request processing and Rack application integration.
  #
  # Request manages the HTTP parsing pipeline using Ractors and coordinates
  # with the reactor for connection state management. It bridges between the
  # low-level HTTP parsing and high-level Rack application interface, handling
  # both incomplete requests (that need more data) and complete requests
  # (ready for application processing).
  #
  class Request
    BODY_BUFFER_THRESHOLD = 256 * 1024
    FILE_CHUNK_SIZE = 64 * 1024
    READ_BUFFER_SIZE = 64 * 1024
    WRITE_TIMEOUT = 5
    KEEPALIVE_READ_TIMEOUT = 0.001
    MAX_KEEPALIVE_REQUESTS = 100

    HTTP_SCHEME = "http"
    HTTP_10 = "HTTP/1.0"
    HTTP_11 = "HTTP/1.1"
    STATUS_LINE_CACHE_10 = Hash.new do |h, status|
      reason = Rack::Utils::HTTP_STATUS_CODES[status]
      h[status] = "HTTP/1.0 #{status}#{reason ? " #{reason}" : ""}\r\n".freeze
    end
    STATUS_LINE_CACHE_11 = Hash.new do |h, status|
      reason = Rack::Utils::HTTP_STATUS_CODES[status]
      h[status] = "HTTP/1.1 #{status}#{reason ? " #{reason}" : ""}\r\n".freeze
    end

    STATUS_WITH_NO_ENTITY_BODY = Set.new([204, 304, *100..199]).freeze
    INTERNAL_SERVER_ERROR_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    CONTENT_TOO_LARGE_RESPONSE = "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    CONNECTION_CLOSE = "close"
    CONNECTION_KEEPALIVE = "keep-alive"
    TRANSFER_ENCODING_CHUNKED = "chunked"

    HTTP_CONNECTION = "HTTP_CONNECTION"
    HTTP_TRANSFER_ENCODING = "HTTP_TRANSFER_ENCODING"
    RACK_HEADER_PREFIX = "rack."
    RACK_HIJACKED = "rack.hijacked"
    RACK_HIJACK_IO = "rack.hijack_io"

    ILLEGAL_HEADER_KEY_REGEX = /[\x00-\x20\(\)<>@,;:\\"\/\[\]\?=\{\}\x7F]/
    ILLEGAL_HEADER_VALUE_REGEX = /[\x00-\x08\x0A-\x1F]/

    class Error < StandardError; end
    class WriteError < Error
      # @rbs () -> String
      def message = "could not write response"
    end

    # Decodes a chunked transfer-encoded body buffer.
    #
    # Returns the decoded bytes and a state symbol: `:complete` when the
    # terminating zero-length chunk was found, `:too_large` when the decoded
    # size would exceed `max_size`, or `:incomplete` otherwise.
    #
    # @param buffer [String] the raw body buffer to decode
    # @param max_size [Integer, nil] maximum decoded body size, or nil for unlimited
    # @return [Array(String, Symbol)] decoded body and completion state
    #
    # @rbs (String buffer, ?Integer? max_size) -> [String, Symbol]
    def self.decode_chunked(buffer, max_size = nil)
      decoded = String.new
      offset = 0

      while offset < buffer.bytesize
        crlf = buffer.index("\r\n", offset)
        return [decoded, :incomplete] unless crlf

        chunk_size = buffer.byteslice(offset, crlf - offset).to_i(16)
        return [decoded, :complete] if chunk_size == 0
        return [decoded, :too_large] if max_size && decoded.bytesize + chunk_size > max_size

        offset = crlf + 2
        decoded << buffer.byteslice(offset, chunk_size)
        offset += chunk_size + 2
      end

      [decoded, :incomplete]
    end

    # @rbs @app: ^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped]
    # @rbs @server_port: Integer
    # @rbs @max_body_size: Integer?
    # @rbs @body_spool_threshold: Integer?

    # Creates a new Request handler.
    #
    # @param app [#call] the Rack application to dispatch complete requests to
    # @param server_port [Integer] port number used to populate SERVER_PORT in the Rack env
    # @param client_options [Hash] client limits configuration
    # @option client_options [Integer, nil] :max_body_size maximum request body size in bytes
    # @option client_options [Integer, nil] :body_spool_threshold spool bodies larger than this to a tempfile
    # @return [void]
    #
    # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, Integer server_port, ?client_options: Hash[Symbol, untyped]) -> void
    def initialize(app, server_port, client_options: {})
      @app = app
      @server_port = server_port
      @max_body_size = client_options[:max_body_size]
      @body_spool_threshold = client_options[:body_spool_threshold]
    end

    # Eagerly reads and parses the first request on a freshly accepted
    # connection on the server thread, dispatching directly to the thread pool
    # when complete. Falls back to the reactor when more data is needed.
    #
    # @param socket [TCPSocket] the freshly accepted client socket
    # @param id [Integer] unique client identifier
    # @param reactor [Reactor] the reactor for fallback registration
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, Reactor reactor, AtomicThreadPool thread_pool, String remote_addr, String url_scheme) -> void
    def eager_accept(socket, id, reactor, thread_pool, remote_addr, url_scheme)
      data = begin
        socket.read_nonblock(READ_BUFFER_SIZE)
      rescue IO::WaitReadable
        reactor.add(
          id: id,
          socket: socket,
          remote_addr: remote_addr,
          url_scheme: url_scheme
        )
        return
      rescue EOFError, IOError
        socket.close rescue nil
        return
      end

      buffer = String.new
      buffer << data

      while socket.respond_to?(:pending) && socket.pending > 0
        buffer << socket.read_nonblock(socket.pending)
      end

      parser = HttpParser.new
      env = {}
      nread = parser.execute(env, buffer, 0)
      parse_data = { parse_count: 1, content_length: parser.content_length }

      body = nil
      if !parser.finished?
        fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, 0, remote_addr, url_scheme, persisted: false)
        return
      elsif parser.has_body?
        if @max_body_size && parser.content_length > @max_body_size
          reject_oversized(socket)
          return
        end

        body = buffer.byteslice(nread..-1) || ""

        if env[HTTP_TRANSFER_ENCODING]&.include?(TRANSFER_ENCODING_CHUNKED)
          body, chunked_state = Request.decode_chunked(body, @max_body_size)
          case chunked_state
          when :complete
            env.delete(HTTP_TRANSFER_ENCODING)
          when :too_large
            reject_oversized(socket)
            return
          else
            fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, 0, remote_addr, url_scheme, persisted: false)
            return
          end
        elsif parser.content_length > body.bytesize
          fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, 0, remote_addr, url_scheme, persisted: false)
          return
        end
      end

      thread_pool << proc do
        process_client(socket, id, env, parse_data, body, reactor, thread_pool, 1, remote_addr, url_scheme)
      end
    end

    # Returns a Proc for HTTP parsing work in Ractor context.
    #
    # The returned Proc processes raw socket data through the appropriate
    # HTTP parser and returns either a complete request state (ready for
    # app processing) or incomplete request state (needs more data).
    #
    # @return [Proc] a Ractor-safe proc that accepts a state hash and returns an updated state hash
    #
    # @rbs () -> ^(Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
    def http_parser_worker
      max_body_size = @max_body_size

      proc do |data|
        next Raptor::Http2.process_frames(data) if data[:protocol] == :http2

        parser = Raptor::HttpParser.new
        env = {}
        nread = parser.execute(env, data[:buffer], 0)
        parse_data = if data[:parse_data]
          data[:parse_data].dup
        else
          { parse_count: 0, content_length: parser.content_length }
        end
        parse_data[:parse_count] += 1

        message = if parser.finished?
          if parser.has_body?
            body_buffer = data[:buffer].byteslice(nread..-1) || ""

            if max_body_size && parser.content_length > max_body_size
              data.merge(env: env, body: nil, parse_data: parse_data, complete: true, too_large: true)
            elsif env[HTTP_TRANSFER_ENCODING]&.include?(TRANSFER_ENCODING_CHUNKED)
              decoded_body, chunked_state = Raptor::Request.decode_chunked(body_buffer, max_body_size)

              case chunked_state
              when :complete
                env.delete(HTTP_TRANSFER_ENCODING)
                data.merge(env: env, body: decoded_body, parse_data: parse_data, complete: true)
              when :too_large
                data.merge(env: env, body: nil, parse_data: parse_data, complete: true, too_large: true)
              else
                data.merge(env: env, parse_data: parse_data)
              end
            elsif parser.content_length > body_buffer.bytesize
              data.merge(env: env, parse_data: parse_data)
            else
              data.merge(env: env, body: body_buffer, parse_data: parse_data, complete: true)
            end
          else
            data.merge(env: env, body: nil, parse_data: parse_data, complete: true)
          end
        else
          data.merge(env: env, parse_data: parse_data)
        end
        Ractor.make_shareable(message)
      end
    end

    # Handles a parsed HTTP request by either continuing parsing or dispatching to the Rack app.
    #
    # For incomplete requests, updates reactor state and re-registers for more I/O.
    # For complete requests, removes from reactor, builds Rack env, and dispatches to thread pool.
    #
    # @param parsed_request [Hash] the parsed request state from the ractor pool
    # @param reactor [Reactor] the reactor managing the client connection
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] parsed_request, Reactor reactor, AtomicThreadPool thread_pool) -> void
    def handle_parsed_request(parsed_request, reactor, thread_pool)
      if parsed_request[:too_large]
        socket = reactor.remove(parsed_request[:id])
        reject_oversized(socket) if socket
        return
      end

      unless parsed_request[:complete]
        reactor.update_state(parsed_request)
      else
        socket = reactor.remove(parsed_request[:id])
        request_count = (parsed_request[:request_count] || 0) + 1
        remote_addr = parsed_request[:remote_addr] || "127.0.0.1"
        url_scheme = parsed_request[:url_scheme] || HTTP_SCHEME

        thread_pool << proc do
          process_client(
            socket,
            parsed_request[:id],
            parsed_request[:env].dup,
            parsed_request[:parse_data],
            parsed_request[:body],
            reactor,
            thread_pool,
            request_count,
            remote_addr,
            url_scheme
          )
        end
      end
    end

    private

    # Processes a client connection by handling the current request and,
    # if keep-alive, eagerly reading subsequent requests inline.
    #
    # @param socket [TCPSocket] the client socket
    # @param id [Integer] unique client identifier
    # @param env [Hash] partial env hash from the HTTP parser
    # @param parse_data [Hash] metadata from the parsing pass
    # @param body [String, nil] decoded request body
    # @param reactor [Reactor] the reactor managing the client connection
    # @param thread_pool [AtomicThreadPool] thread pool for application processing
    # @param request_count [Integer] number of requests handled on this connection
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, Hash[String, untyped] env, Hash[Symbol, untyped] parse_data, String? body, Reactor reactor, AtomicThreadPool thread_pool, Integer request_count, String remote_addr, String url_scheme) -> void
    def process_client(socket, id, env, parse_data, body, reactor, thread_pool, request_count, remote_addr, url_scheme)
      keep_alive = process_request(socket, env, parse_data, body, request_count, remote_addr, url_scheme)
      eager_keepalive(socket, id, reactor, thread_pool, request_count, remote_addr, url_scheme) if keep_alive
    end

    # Builds the Rack env, calls the application, and writes the response.
    # Returns true if the connection should be kept alive for further
    # requests, false otherwise (including hijack and error cases).
    #
    # @param socket [TCPSocket] the client socket
    # @param env [Hash] partial env hash from the HTTP parser
    # @param parse_data [Hash] metadata from the parsing pass
    # @param body [String, nil] decoded request body
    # @param request_count [Integer] number of requests handled on this connection
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [Boolean] true if the connection should be kept alive
    #
    # @rbs (TCPSocket socket, Hash[String, untyped] env, Hash[Symbol, untyped] parse_data, String? body, Integer request_count, String remote_addr, String url_scheme) -> bool
    def process_request(socket, env, parse_data, body, request_count, remote_addr, url_scheme)
      rack_env = nil
      status = nil
      headers = nil
      hijacked = false
      keep_alive = false
      response_started = false

      begin
        rack_env = build_rack_env(env, parse_data, body, socket, remote_addr: remote_addr, url_scheme: url_scheme)
        status, headers, body = @app.call(rack_env)

        if rack_env[RACK_HIJACKED]
          hijacked = true
          body.close if body.respond_to?(:close)
        else
          hijacked = headers.is_a?(Hash) && !!headers[Rack::RACK_HIJACK]
          streaming = body.respond_to?(:call) && !body.respond_to?(:each)
          keep_alive = (hijacked || streaming) ? false : keep_alive?(rack_env, request_count)
          response_started = true
          write_response(socket, rack_env, status, headers, body, keep_alive: keep_alive)
        end

        call_response_finished(rack_env, status, headers, nil)
        keep_alive && !hijacked
      rescue => error
        call_response_finished(rack_env, status, headers, error) if rack_env
        socket.write(INTERNAL_SERVER_ERROR_RESPONSE) rescue nil unless response_started || hijacked
        keep_alive = false
        raise
      ensure
        rack_input = rack_env && rack_env[Rack::RACK_INPUT]
        rack_input.close! rescue nil if rack_input.respond_to?(:close!)

        unless hijacked || keep_alive
          socket.close rescue nil
        end
      end
    end

    # Attempts to read and process subsequent requests inline on a
    # kept-alive connection. Blocks briefly for the next request to avoid
    # a full reactor round-trip. Falls back to the reactor when no data
    # arrives within the timeout, when the thread pool has queued work
    # (deprioritization), or when the request is incomplete.
    #
    # @param socket [TCPSocket] the client socket
    # @param id [Integer] unique client identifier
    # @param reactor [Reactor] the reactor for fallback registration
    # @param thread_pool [AtomicThreadPool] thread pool for deprioritization
    # @param request_count [Integer] number of requests handled on this connection
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, Reactor reactor, AtomicThreadPool thread_pool, Integer request_count, String remote_addr, String url_scheme) -> void
    def eager_keepalive(socket, id, reactor, thread_pool, request_count, remote_addr, url_scheme)
      loop do
        unless socket.wait_readable(KEEPALIVE_READ_TIMEOUT)
          reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
          return
        end

        data = begin
          socket.read_nonblock(READ_BUFFER_SIZE)
        rescue IO::WaitReadable
          reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
          return
        rescue EOFError
          socket.close rescue nil
          return
        end

        buffer = String.new
        buffer << data

        while socket.respond_to?(:pending) && socket.pending > 0
          buffer << socket.read_nonblock(socket.pending)
        end

        parser = HttpParser.new
        env = {}
        nread = parser.execute(env, buffer, 0)
        parse_data = { parse_count: 1, content_length: parser.content_length }

        body = nil
        if !parser.finished?
          fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, request_count, remote_addr, url_scheme)
          return
        elsif parser.has_body?
          body = buffer.byteslice(nread..-1) || ""

          chunked = env[HTTP_TRANSFER_ENCODING]&.include?(TRANSFER_ENCODING_CHUNKED)
          if chunked || parser.content_length > body.bytesize
            fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, request_count, remote_addr, url_scheme)
            return
          end
        end

        request_count += 1

        if thread_pool.queue_size > 0
          thread_pool << proc do
            process_client(
              socket,
              id,
              env,
              parse_data,
              body,
              reactor,
              thread_pool,
              request_count,
              remote_addr,
              url_scheme
            )
          end
          return
        end

        keep_alive = process_request(
          socket,
          env,
          parse_data,
          body,
          request_count,
          remote_addr,
          url_scheme
        )
        return unless keep_alive
      end
    end

    # Re-registers a socket with the reactor for further processing when
    # an incomplete request is received during eager accept or eager keep-alive.
    #
    # The persisted flag selects between persistent_data_timeout (for
    # kept-alive connections awaiting the next request) and chunk_data_timeout
    # (for fresh connections awaiting the rest of the first request).
    #
    # @param socket [TCPSocket] the client socket
    # @param id [Integer] unique client identifier
    # @param buffer [String] the partial request data already read
    # @param env [Hash] partial env hash from the HTTP parser
    # @param parse_data [Hash] metadata from the parsing pass
    # @param reactor [Reactor] the reactor to re-register with
    # @param request_count [Integer] number of requests handled on this connection
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @param persisted [Boolean] whether the connection has already completed at least one request
    # @return [void]
    #
    # @rbs (TCPSocket socket, Integer id, String buffer, Hash[String, untyped] env, Hash[Symbol, untyped] parse_data, Reactor reactor, Integer request_count, String remote_addr, String url_scheme, persisted: bool) -> void
    def fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, request_count, remote_addr, url_scheme, persisted: true)
      reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
      state = {
        id: id,
        buffer: buffer,
        env: env,
        request_count: request_count,
        parse_data: parse_data,
        remote_addr: remote_addr,
        url_scheme: url_scheme
      }
      state[:persisted] = true if persisted
      reactor.update_state(Ractor.make_shareable(state))
    end

    # Writes a 413 response and closes the socket. Used when a request body
    # exceeds the configured maximum size.
    #
    # @param socket [TCPSocket] the client socket
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def reject_oversized(socket)
      socket.write(CONTENT_TOO_LARGE_RESPONSE) rescue nil
      socket.close rescue nil
    end

    # Builds a Rack environment hash from parsed HTTP request data.
    #
    # Populates all required Rack env keys including rack.* keys, REMOTE_ADDR,
    # SERVER_NAME, SERVER_PORT, and hijack support.
    #
    # @param env [Hash] partial env hash from the HTTP parser
    # @param parse_data [Hash] metadata from the parsing pass, including content_length
    # @param body [String, nil] decoded request body, or nil if no body
    # @param socket [TCPSocket] the client socket, used for hijack support
    # @param remote_addr [String] client IP address
    # @param url_scheme [String] "http" or "https"
    # @return [Hash] fully populated Rack environment hash
    #
    # @rbs (Hash[String, untyped] env, Hash[Symbol, untyped] parse_data, String? body, TCPSocket socket, ?remote_addr: String, ?url_scheme: String) -> Hash[String, untyped]
    def build_rack_env(env, parse_data, body, socket, remote_addr: "127.0.0.1", url_scheme: HTTP_SCHEME)
      env[Rack::RACK_VERSION] = Rack::VERSION
      env[Rack::RACK_URL_SCHEME] = url_scheme
      env[Rack::RACK_INPUT] = build_rack_input(body)
      env[Rack::RACK_ERRORS] = $stderr
      env[Rack::RACK_RESPONSE_FINISHED] = []

      env[Rack::RACK_IS_HIJACK] = true
      env[Rack::RACK_HIJACK] = proc do
        env[RACK_HIJACKED] = true
        env[RACK_HIJACK_IO] = socket
        socket
      end

      env[Rack::RACK_EARLY_HINTS] = proc do |hints|
        send_early_hints(socket, hints) rescue nil
      end

      env[Rack::SCRIPT_NAME] = "" unless env.key?(Rack::SCRIPT_NAME)
      env[Rack::PATH_INFO] = env.delete(Rack::REQUEST_PATH) if env.key?(Rack::REQUEST_PATH)
      env[Rack::PATH_INFO] = "" unless env.key?(Rack::PATH_INFO)
      env[Rack::QUERY_STRING] = "" unless env.key?(Rack::QUERY_STRING)

      if (content_length = parse_data[:content_length]).positive?
        env["CONTENT_LENGTH"] = content_length.to_s
      end

      env["REMOTE_ADDR"] = remote_addr

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

      env
    end

    # Builds the `rack.input` IO object for the request body. Returns an
    # in-memory StringIO for bodies up to the spool threshold, or a Tempfile
    # for larger bodies to bound per-worker memory.
    #
    # @param body [String, nil] decoded request body
    # @return [IO] an IO-like object positioned at the start of the body
    #
    # @rbs (String? body) -> IO
    def build_rack_input(body)
      if body && @body_spool_threshold && body.bytesize > @body_spool_threshold
        tempfile = Tempfile.new("raptor-body")
        tempfile.binmode
        tempfile.write(body)
        tempfile.rewind
        tempfile
      else
        (body ? StringIO.new(body) : StringIO.new).set_encoding(Encoding::ASCII_8BIT)
      end
    end

    # Determines whether the connection should be kept alive after the response.
    #
    # Returns false if the request limit has been reached. For HTTP/1.1, keep-alive
    # is the default unless the client sent Connection: close. For HTTP/1.0,
    # keep-alive must be explicitly requested.
    #
    # @param env [Hash] the Rack environment
    # @param request_count [Integer] number of requests handled on this connection
    # @return [Boolean] true if the connection should be kept alive
    #
    # @rbs (Hash[String, untyped] env, Integer request_count) -> bool
    def keep_alive?(env, request_count)
      return false if request_count >= MAX_KEEPALIVE_REQUESTS

      connection_header = env[HTTP_CONNECTION]

      if env[Rack::SERVER_PROTOCOL] == HTTP_11
        !connection_header&.casecmp?(CONNECTION_CLOSE)
      else
        connection_header&.casecmp?(CONNECTION_KEEPALIVE) || false
      end
    end

    # Sends an HTTP 103 Early Hints response to the client.
    #
    # Skips any hints with illegal header keys or values. No-ops if hints is empty.
    #
    # @param socket [TCPSocket] the client socket to write to
    # @param hints [Hash] header name to value (or array of values) pairs
    # @return [void]
    #
    # @rbs (TCPSocket socket, Hash[String, String | Array[String]] hints) -> void
    def send_early_hints(socket, hints)
      return if hints.empty?

      response = +"#{HTTP_11} 103 Early Hints\r\n"
      hints.each do |key, value|
        next if illegal_header_key?(key)

        values = value.is_a?(Array) ? value : [value]
        values.each do |hint_value|
          next if illegal_header_value?(hint_value.to_s)

          response << "#{key.downcase}: #{hint_value}\r\n"
        end
      end
      response << "\r\n"

      socket_write(socket, response)
    end

    # Writes a complete HTTP response to the socket.
    #
    # Handles header normalization, validation, connection management, TCP corking,
    # and dispatches to the appropriate body write strategy.
    #
    # @param socket [TCPSocket] the client socket to write to
    # @param env [Hash] the Rack environment
    # @param status [Integer] HTTP status code
    # @param headers [Hash] response headers from the Rack application
    # @param body [Object] response body (array, enumerable, file, or callable)
    # @param keep_alive [Boolean] whether to send a keep-alive connection header
    # @return [void]
    #
    # @rbs (TCPSocket socket, Hash[String, untyped] env, Integer status, Hash[String, String | Array[String]] headers, untyped body, ?keep_alive: bool) -> void
    def write_response(socket, env, status, headers, body, keep_alive: false)
      validate_status(status)
      response_hijack = headers.is_a?(Hash) ? headers.delete(Rack::RACK_HIJACK) : nil
      headers = normalize_headers(headers)
      validate_headers(headers, status)

      headers["connection"] = keep_alive ? CONNECTION_KEEPALIVE : CONNECTION_CLOSE

      http_version = env[Rack::SERVER_PROTOCOL] == HTTP_11 ? HTTP_11 : HTTP_10
      no_body = env[Rack::REQUEST_METHOD] == "HEAD" || STATUS_WITH_NO_ENTITY_BODY.include?(status)

      response = build_status_line(http_version, status)

      cork_socket(socket)

      if response_hijack
        write_hijacked_response(socket, response, headers, response_hijack)
      elsif no_body
        write_no_body_response(socket, response, headers, status)
      else
        write_full_response(socket, response, headers, body, http_version)
      end
    ensure
      body.close if body.respond_to?(:close)
      uncork_socket(socket)
      socket.flush rescue nil
    end

    # Validates that the status code is a valid integer.
    #
    # @param status [Object] the status value to validate
    # @return [void]
    # @raise [TypeError] if status is not an Integer
    # @raise [ArgumentError] if status is less than 100
    #
    # @rbs (Integer status) -> void
    def validate_status(status)
      raise TypeError, "status must be an Integer" unless status.is_a?(Integer)

      raise ArgumentError, "status must be >= 100" unless status >= 100
    end

    # Normalizes response headers by downcasing keys and filtering invalid entries.
    #
    # Removes headers with illegal keys, rack.* prefixed headers, and "status" headers.
    # Raises if headers is not a Hash or contains non-String keys.
    #
    # @param headers [Hash] raw headers from the Rack application
    # @return [Hash] normalized headers with lowercased string keys
    # @raise [TypeError] if headers is not a Hash or a key is not a String
    #
    # @rbs (Hash[String, String | Array[String]] headers) -> Hash[String, String | Array[String]]
    def normalize_headers(headers)
      raise TypeError, "headers must be a Hash" unless headers.is_a?(Hash)

      normalized = {}
      headers.each do |key, value|
        raise TypeError, "header keys must be Strings" unless key.is_a?(String)

        next if illegal_header_key?(key)

        normalized_key = key.match?(/[A-Z]/) ? key.downcase : key
        next if normalized_key.start_with?(RACK_HEADER_PREFIX)
        next if normalized_key == "status"

        normalized[normalized_key] = value
      end
      normalized
    end

    # Validates that headers are appropriate for the given status code.
    #
    # Raises if content-type or content-length are present for status codes
    # that must not have an entity body (204, 304, 1xx).
    #
    # @param headers [Hash] normalized response headers
    # @param status [Integer] HTTP status code
    # @return [void]
    # @raise [ArgumentError] if a forbidden header is present for the status
    #
    # @rbs (Hash[String, String | Array[String]] headers, Integer status) -> void
    def validate_headers(headers, status)
      if STATUS_WITH_NO_ENTITY_BODY.include?(status)
        raise ArgumentError, "content-type must not be present for status #{status}" if headers.key?(Rack::CONTENT_TYPE)

        raise ArgumentError, "content-length must not be present for status #{status}" if headers.key?(Rack::CONTENT_LENGTH)
      end
    end

    # Builds the HTTP status line string.
    #
    # @param http_version [String] "HTTP/1.1" or "HTTP/1.0"
    # @param status [Integer] HTTP status code
    # @return [String] the status line including trailing CRLF
    #
    # @rbs (String http_version, Integer status) -> String
    def build_status_line(http_version, status)
      cache = http_version == HTTP_11 ? STATUS_LINE_CACHE_11 : STATUS_LINE_CACHE_10
      cache[status].dup
    end

    # Writes response headers and delegates body writing to the hijack callback.
    #
    # Uncorks the socket before calling the hijack so the app has full control
    # of the raw connection.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] the status line accumulated so far
    # @param headers [Hash] normalized response headers
    # @param response_hijack [Proc] callable that receives the socket and writes the body
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, Hash[String, String | Array[String]] headers, ^(TCPSocket) -> void response_hijack) -> void
    def write_hijacked_response(socket, response, headers, response_hijack)
      response << format_headers(headers)
      response << "\r\n"
      socket_write(socket, response)
      uncork_socket(socket)
      response_hijack.call(socket)
    end

    # Writes a response with no entity body.
    #
    # Used for HEAD requests and status codes that must not carry a body
    # (204, 304, 1xx). Adds a zero content-length for non-no-body statuses
    # that did not supply one.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] the status line accumulated so far
    # @param headers [Hash] normalized response headers
    # @param status [Integer] HTTP status code
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, Hash[String, String | Array[String]] headers, Integer status) -> void
    def write_no_body_response(socket, response, headers, status)
      unless STATUS_WITH_NO_ENTITY_BODY.include?(status)
        headers[Rack::CONTENT_LENGTH] = "0" unless headers.key?(Rack::CONTENT_LENGTH) || headers.key?(Rack::TRANSFER_ENCODING)
      end

      response << format_headers(headers)
      response << "\r\n"
      socket_write(socket, response)
    end

    # Writes a complete response with a body.
    #
    # Selects the appropriate write strategy based on body type: callable (streaming),
    # file (zero-copy), array, or generic enumerable. Automatically determines
    # content-length where possible, falling back to chunked transfer encoding
    # for HTTP/1.1 when the length cannot be determined upfront.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] the status line accumulated so far
    # @param headers [Hash] normalized response headers
    # @param body [Object] the response body
    # @param http_version [String] "HTTP/1.1" or "HTTP/1.0"
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, Hash[String, String | Array[String]] headers, untyped body, String http_version) -> void
    def write_full_response(socket, response, headers, body, http_version)
      if body.respond_to?(:call)
        response << format_headers(headers)
        response << "\r\n"
        socket_write(socket, response)
        uncork_socket(socket)
        body.call(socket)
        return
      end

      content_length = headers[Rack::CONTENT_LENGTH]&.to_i
      use_chunked = false

      if !content_length || content_length == 0
        calculated_length = calculate_content_length(body)
        if calculated_length
          content_length = calculated_length
        elsif http_version == HTTP_11 && !headers.key?(Rack::TRANSFER_ENCODING)
          use_chunked = true
        end
      end

      if content_length && content_length >= 0
        headers[Rack::CONTENT_LENGTH] = content_length.to_s
      elsif use_chunked
        headers[Rack::TRANSFER_ENCODING] = TRANSFER_ENCODING_CHUNKED
      end

      response << format_headers(headers)
      response << "\r\n"

      if body.respond_to?(:to_path) && (path = body.to_path) && File.readable?(path)
        write_file_body(socket, response, path, content_length, use_chunked)
      elsif body.respond_to?(:to_ary)
        write_array_body(socket, response, body.to_ary, use_chunked)
      elsif body.respond_to?(:each)
        write_enumerable_body(socket, response, body, use_chunked)
      else
        raise TypeError, "body must respond to each, to_ary, or to_path"
      end

      socket_write(socket, "0\r\n\r\n") if use_chunked
    end

    # Calculates content length from an array or file body without consuming it.
    #
    # Returns nil for enumerable bodies whose length cannot be determined upfront.
    #
    # @param body [Object] the response body
    # @return [Integer, nil] the byte length, or nil if it cannot be determined
    #
    # @rbs (untyped body) -> Integer?
    def calculate_content_length(body)
      if body.respond_to?(:to_ary)
        array = body.to_ary
        return nil unless array.is_a?(Array)

        array.sum { |chunk| chunk.is_a?(String) ? chunk.bytesize : 0 }
      elsif body.respond_to?(:to_path) && (path = body.to_path) && File.readable?(path)
        File.size(path)
      else
        nil
      end
    end

    # Writes a file body to the socket.
    #
    # Uses zero-copy IO.copy_stream for large files, direct buffering for small ones,
    # and chunked encoding when required.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] headers already serialized, to be written before the body
    # @param path [String] filesystem path of the file to send
    # @param content_length [Integer, nil] pre-calculated file size
    # @param use_chunked [Boolean] whether to use chunked transfer encoding
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, String path, Integer? content_length, bool use_chunked) -> void
    def write_file_body(socket, response, path, content_length, use_chunked)
      File.open(path, "rb") do |file|
        if use_chunked
          socket_write(socket, response)
          while (chunk = file.read(FILE_CHUNK_SIZE))
            socket_write(socket, "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
          end
        elsif content_length && content_length < BODY_BUFFER_THRESHOLD
          response << file.read(content_length)
          socket_write(socket, response)
        else
          socket_write(socket, response)
          IO.copy_stream(file, socket)
        end
      end
    end

    # Writes an array body to the socket.
    #
    # Dispatches to the single-chunk or multi-chunk path based on array length.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] headers already serialized, to be written before the body
    # @param body_array [Array<String>] the response body chunks
    # @param use_chunked [Boolean] whether to use chunked transfer encoding
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, Array[String] body_array, bool use_chunked) -> void
    def write_array_body(socket, response, body_array, use_chunked)
      if body_array.length == 1
        write_single_chunk(socket, response, body_array.first, use_chunked)
      else
        write_multiple_chunks(socket, response, body_array, use_chunked)
      end
    end

    # Writes a single-element array body, optionally buffering it with the headers.
    #
    # Small bodies are concatenated with the headers into one write to reduce
    # system call overhead.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] headers already serialized, to be written before the body
    # @param chunk [String] the single body chunk
    # @param use_chunked [Boolean] whether to use chunked transfer encoding
    # @return [void]
    # @raise [TypeError] if the chunk is not a String
    #
    # @rbs (TCPSocket socket, String response, String chunk, bool use_chunked) -> void
    def write_single_chunk(socket, response, chunk, use_chunked)
      raise TypeError, "body must yield String values" unless chunk.is_a?(String)

      if use_chunked
        response << "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n"
        socket_write(socket, response)
      elsif chunk.bytesize < BODY_BUFFER_THRESHOLD
        socket_write(socket, response << chunk)
      else
        socket_write(socket, response)
        socket_write(socket, chunk)
      end
    end

    # Writes a multi-element array body to the socket.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] headers already serialized, to be written before the body
    # @param body_array [Array<String>] the response body chunks
    # @param use_chunked [Boolean] whether to use chunked transfer encoding
    # @return [void]
    # @raise [TypeError] if any chunk is not a String
    #
    # @rbs (TCPSocket socket, String response, Array[String] body_array, bool use_chunked) -> void
    def write_multiple_chunks(socket, response, body_array, use_chunked)
      if use_chunked
        socket_write(socket, response)
        body_array.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)

          next if chunk.empty?

          socket_write(socket, "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        end
      else
        body_array.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)

          response << chunk
        end
        socket_write(socket, response)
      end
    end

    # Writes a generic enumerable body to the socket.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] headers already serialized, to be written before the body
    # @param body [Object] any object responding to each
    # @param use_chunked [Boolean] whether to use chunked transfer encoding
    # @return [void]
    # @raise [TypeError] if any yielded chunk is not a String
    #
    # @rbs (TCPSocket socket, String response, untyped body, bool use_chunked) -> void
    def write_enumerable_body(socket, response, body, use_chunked)
      if use_chunked
        socket_write(socket, response)
        body.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)

          next if chunk.empty?

          socket_write(socket, "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        end
      else
        body.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)

          response << chunk
        end
        socket_write(socket, response)
      end
    end

    # Returns true if the header key contains characters illegal in HTTP headers.
    #
    # @param key [String] the header key to check
    # @return [Boolean] true if the key is illegal
    #
    # @rbs (String key) -> bool
    def illegal_header_key?(key)
      key.match?(ILLEGAL_HEADER_KEY_REGEX)
    end

    # Returns true if the header value contains characters illegal in HTTP headers.
    #
    # @param value [String] the header value to check
    # @return [Boolean] true if the value is illegal
    #
    # @rbs (String value) -> bool
    def illegal_header_value?(value)
      value.match?(ILLEGAL_HEADER_VALUE_REGEX)
    end

    # Formats a headers hash into an HTTP header string.
    #
    # Skips entries with illegal keys or values. Array values are written
    # as separate header lines.
    #
    # @param headers [Hash] normalized response headers
    # @return [String] formatted header lines, each ending with CRLF
    #
    # @rbs (Hash[String, String | Array[String]] headers) -> String
    def format_headers(headers)
      result = +""
      headers.each do |name, value|
        next if illegal_header_key?(name)

        if value.is_a?(Array)
          value.each do |header_value|
            next if illegal_header_value?(header_value.to_s)

            result << "#{name}: #{header_value}\r\n"
          end
        else
          next if illegal_header_value?(value.to_s)

          result << "#{name}: #{value}\r\n"
        end
      end
      result
    end

    # Calls all rack.response_finished callbacks registered in the environment.
    #
    # Callbacks are called in reverse registration order. Individual callback
    # failures are rescued so all callbacks are always attempted.
    #
    # @param env [Hash, nil] the Rack environment
    # @param status [Integer, nil] the response status code
    # @param headers [Hash, nil] the response headers
    # @param error [Exception, nil] any error raised during processing, or nil on success
    # @return [void]
    #
    # @rbs (Hash[String, untyped] env, Integer? status, Hash[String, String | Array[String]]? headers, Exception? error) -> void
    def call_response_finished(env, status, headers, error)
      return unless env && env[Rack::RACK_RESPONSE_FINISHED].is_a?(Array)

      env[Rack::RACK_RESPONSE_FINISHED].reverse_each do |callable|
        callable.call(env, status, headers, error) rescue nil
      end
    end

    # Writes a string to the socket, retrying on partial writes and flow control blocks.
    #
    # Uses write_nonblock with a 5-second writable timeout to avoid blocking the
    # thread indefinitely on slow clients.
    #
    # @param socket [TCPSocket] the socket to write to
    # @param string [String] the data to write
    # @return [void]
    # @raise [WriteError] if the socket is not writable within the timeout or raises IOError
    #
    # @rbs (TCPSocket socket, String string) -> void
    def socket_write(socket, string)
      bytes = 0
      byte_size = string.bytesize

      while bytes < byte_size
        begin
          bytes += socket.write_nonblock(bytes.zero? ? string : string.byteslice(bytes..-1))
        rescue IO::WaitWritable
          raise WriteError unless socket.wait_writable(WRITE_TIMEOUT)
          retry
        rescue IOError
          raise WriteError
        end
      end
    end

    if Socket.const_defined?(:TCP_CORK)
      # Enables TCP_CORK on the socket to batch outgoing packets into fewer segments.
      #
      # Only applies to TCP sockets. No-op on non-TCP sockets.
      # Available on Linux only; this method is not defined on other platforms.
      #
      # @param socket [TCPSocket] the socket to cork
      # @return [void]
      #
      # @rbs (TCPSocket socket) -> void
      def cork_socket(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 1) if socket.is_a?(TCPSocket)
      end

      # Disables TCP_CORK on the socket, flushing any buffered packets.
      #
      # Only applies to TCP sockets. No-op on non-TCP sockets.
      # Available on Linux only; this method is not defined on other platforms.
      #
      # @param socket [TCPSocket] the socket to uncork
      # @return [void]
      #
      # @rbs (TCPSocket socket) -> void
      def uncork_socket(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 0) if socket.is_a?(TCPSocket)
      end
    else
      def cork_socket(socket); end

      def uncork_socket(socket); end
    end
  end
end
