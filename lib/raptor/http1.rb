# rbs_inline: enabled
# frozen_string_literal: true

require "socket"
require "stringio"
require "tempfile"

require "atomic-ruby/atomic_boolean"
require "rack"

require_relative "http"
require_relative "raptor_http"

module Raptor
  # Parses HTTP/1.x requests and dispatches them to the Rack
  # application. Coordinates with the Ractor pool for parsing and
  # with the reactor for requests that need more data before they
  # can be handled.
  #
  class Http1
    BODY_BUFFER_THRESHOLD = 256 * 1024
    CHUNKED_WRITE_THRESHOLD = 512 * 1024
    FILE_CHUNK_SIZE = 64 * 1024
    MAX_CHUNK_OVERHEAD = 16 * 1024
    READ_BUFFER_SIZE = 64 * 1024
    RESPONSE_BUFFER_CAPACITY = 4 * 1024
    KEEPALIVE_READ_TIMEOUT = 0.001
    MAX_KEEPALIVE_REQUESTS = 100

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

    STATUS_WITH_NO_ENTITY_BODY = [204, 304, *100..199].freeze
    CONTINUE_RESPONSE = "HTTP/1.1 100 Continue\r\n\r\n"
    BAD_REQUEST_RESPONSE = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    CONTENT_TOO_LARGE_RESPONSE = "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    INTERNAL_SERVER_ERROR_RESPONSE = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    CONNECTION_CLOSE = "close"
    CONNECTION_KEEPALIVE = "keep-alive"
    EXPECT_100_CONTINUE = "100-continue"
    TRANSFER_ENCODING_CHUNKED = "chunked"

    HTTP_CONNECTION = "HTTP_CONNECTION"
    HTTP_EXPECT = "HTTP_EXPECT"
    HTTP_TRANSFER_ENCODING = "HTTP_TRANSFER_ENCODING"
    RACK_HEADER_PREFIX = "rack."
    RACK_HIJACKED = "rack.hijacked"
    RACK_HIJACK_IO = "rack.hijack_io"

    ILLEGAL_HEADER_KEY_REGEX = /[\x00-\x20\(\)<>@,;:\\"\/\[\]\?=\{\}\x7F]/
    ILLEGAL_HEADER_VALUE_REGEX = /[\x00-\x08\x0A-\x1F]/
    CHUNK_SIZE_REGEX = /\A[0-9A-Fa-f]+\z/

    # Returns true when an HTTP/1.1 request lacks a valid `Host` header per
    # RFC 9112 section 3.2, where a valid value is a non-empty single-value
    # line.
    #
    # @param env [Hash] the Rack environment after header parsing
    # @return [Boolean]
    #
    # @rbs (Hash[String, untyped] env) -> bool
    def self.invalid_host?(env)
      return false unless env[Rack::SERVER_PROTOCOL] == HTTP_11

      http_host = env[Rack::HTTP_HOST]
      !http_host || http_host.empty? || http_host.include?(",")
    end

    # Returns true when the message framing shows a request-smuggling vector
    # per RFC 9112 section 6.3: a `Transfer-Encoding` where `chunked` is
    # missing, not the final encoding, or duplicated; a `Transfer-Encoding`
    # paired with a `Content-Length`; or a `Content-Length` containing any
    # non-digit character.
    #
    # @param env [Hash] the Rack environment after header parsing
    # @return [Boolean]
    #
    # @rbs (Hash[String, untyped] env) -> bool
    def self.request_smuggling?(env)
      transfer_encoding = env[HTTP_TRANSFER_ENCODING]
      content_length = env[Http::CONTENT_LENGTH]

      if transfer_encoding
        return true if content_length

        encodings = transfer_encoding.downcase.split(",").map(&:strip)
        return true if encodings.last != TRANSFER_ENCODING_CHUNKED
        return true if encodings.count(TRANSFER_ENCODING_CHUNKED) > 1
      elsif content_length
        return true if content_length.match?(/[^\d]/)
      end

      false
    end

    # Decodes a chunked transfer-encoded body buffer.
    #
    # Returns the decoded bytes and a state symbol: `:complete` when the
    # terminating zero-length chunk and trailer section were fully consumed,
    # `:too_large` when the decoded size would exceed `max_size`, `:malformed`
    # when a chunk-size line is not valid hex or chunk framing overhead exceeds
    # `MAX_CHUNK_OVERHEAD`, or `:incomplete` otherwise.
    #
    # @param buffer [String] the raw body buffer to decode
    # @param max_size [Integer, nil] maximum decoded body size, or nil for unlimited
    # @return [Array(String, Symbol)] decoded body and completion state
    #
    # @rbs (String buffer, ?Integer? max_size) -> [String, Symbol]
    def self.decode_chunked(buffer, max_size = nil)
      decoded = String.new
      offset = 0
      overhead = 0

      while offset < buffer.bytesize
        crlf = buffer.index("\r\n", offset)
        return [decoded, :incomplete] unless crlf

        size_line = buffer.byteslice(offset, crlf - offset)
        semicolon = size_line.index(";")
        size_part = semicolon ? size_line.byteslice(0, semicolon) : size_line
        return [decoded, :malformed] unless size_part.match?(CHUNK_SIZE_REGEX)

        chunk_size = size_part.to_i(16)

        if chunk_size == 0
          trailer_offset = crlf + 2
          loop do
            trailer_crlf = buffer.index("\r\n", trailer_offset)
            return [decoded, :incomplete] unless trailer_crlf
            return [decoded, :complete] if trailer_crlf == trailer_offset

            trailer_offset = trailer_crlf + 2
          end
        end

        return [decoded, :too_large] if max_size && (decoded.bytesize + chunk_size) > max_size

        overhead += (crlf - offset) + 4
        return [decoded, :malformed] if overhead > (decoded.bytesize + chunk_size + MAX_CHUNK_OVERHEAD)

        offset = crlf + 2
        decoded << buffer.byteslice(offset, chunk_size)
        offset += chunk_size + 2
      end

      [decoded, :incomplete]
    end

    # Advances an HTTP/1.x request parse from the state hash's buffered
    # bytes. A complete well-formed request returns with `:complete` set
    # plus populated `:env` and `:body`; malformed or oversized input flips
    # `:malformed` or `:too_large`; incomplete input returns the state
    # so the reactor can wait for more.
    #
    # @param data [Hash] the current parse state
    # @param env_template [Hash] the Rack env template to seed the request with
    # @param max_body_size [Integer, nil] byte limit for the request body, or nil for no limit
    # @return [Hash] the updated parse state, made shareable for cross-Ractor return
    #
    # @rbs (Hash[Symbol, untyped] data, Hash[String, untyped] env_template, Integer? max_body_size) -> Hash[Symbol, untyped]
    def self.parse(data, env_template, max_body_size)
      parser = Raptor::HttpParser.new
      env = env_template.dup
      nread = begin
        parser.execute(env, data[:buffer], 0)
      rescue Raptor::HttpParserError
        return Ractor.make_shareable(data.merge(complete: true, malformed: true))
      end
      parse_data = if data[:parse_data]
        data[:parse_data].dup
      else
        { parse_count: 0, content_length: parser.content_length }
      end
      parse_data[:parse_count] += 1

      message = if parser.finished?
        if invalid_host?(env) || request_smuggling?(env)
          data.merge(env: env, body: nil, parse_data: parse_data, complete: true, malformed: true)
        elsif parser.has_body?
          body_buffer = data[:buffer].byteslice(nread..-1) || ""

          if max_body_size && parser.content_length > max_body_size
            data.merge(env: env, body: nil, parse_data: parse_data, complete: true, too_large: true)
          elsif parser.chunked?
            decoded_body, chunked_state = decode_chunked(body_buffer, max_body_size)

            case chunked_state
            when :complete
              env.delete(HTTP_TRANSFER_ENCODING)
              data.merge(env: env, body: decoded_body, parse_data: parse_data, complete: true)
            when :too_large
              data.merge(env: env, body: nil, parse_data: parse_data, complete: true, too_large: true)
            when :malformed
              data.merge(env: env, body: nil, parse_data: parse_data, complete: true, malformed: true)
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

    # @rbs @app: ^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped]
    # @rbs @server_port: Integer
    # @rbs @server_port_string: String
    # @rbs @write_timeout: Integer
    # @rbs @max_body_size: Integer?
    # @rbs @body_spool_threshold: Integer?
    # @rbs @max_keepalive_requests: Integer
    # @rbs @access_log_io: IO?
    # @rbs @on_error: ^(Hash[String, untyped]?, Exception) -> void | nil
    # @rbs @running: AtomicBoolean
    # @rbs @env_template: Hash[String, untyped]

    # Creates a new Http1 handler.
    #
    # @param app [#call] the Rack application to dispatch complete requests to
    # @param server_port [Integer] port number used to populate SERVER_PORT in the Rack env
    # @param connection_options [Hash] per-connection settings shared across protocols
    # @option connection_options [Integer] :write_timeout per-write socket timeout in seconds
    # @option connection_options [Integer, nil] :max_body_size maximum request body size in bytes
    # @option connection_options [Integer, nil] :body_spool_threshold spool bodies larger than this to a tempfile
    # @param http1_options [Hash] HTTP/1.1-specific settings
    # @option http1_options [Integer] :max_keepalive_requests maximum requests per HTTP/1.1 keep-alive connection
    # @param access_log_io [IO, nil] IO to write Common Log Format access entries to, or nil to disable
    # @param on_error [#call, nil] callback invoked with (env, exception) when the Rack app raises
    # @return [void]
    #
    # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, Integer server_port, ?connection_options: Hash[Symbol, untyped], ?http1_options: Hash[Symbol, untyped], ?access_log_io: IO?, ?on_error: ^(Hash[String, untyped]?, Exception) -> void | nil) -> void
    def initialize(app, server_port, connection_options: {}, http1_options: {}, access_log_io: nil, on_error: nil)
      @app = app
      @server_port = server_port
      @server_port_string = server_port.to_s.freeze
      @write_timeout = connection_options[:write_timeout] || Http::WRITE_TIMEOUT
      @max_body_size = connection_options[:max_body_size]
      @body_spool_threshold = connection_options[:body_spool_threshold]
      @max_keepalive_requests = http1_options[:max_keepalive_requests] || MAX_KEEPALIVE_REQUESTS
      @access_log_io = access_log_io
      @on_error = on_error
      @running = AtomicBoolean.new(true)
      @env_template = {
        Rack::RACK_VERSION => Rack::VERSION,
        Rack::RACK_IS_HIJACK => true,
        Rack::SCRIPT_NAME => "",
        Rack::QUERY_STRING => "",
        Http::SERVER_SOFTWARE => Http::SERVER_SOFTWARE_VALUE
      }.freeze
    end

    # Instance-level wrapper around {Http.parser_worker} that binds this
    # handler's env template and body-size limit into the worker proc.
    #
    # @return [Proc]
    #
    # @rbs () -> ^(Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
    def parser_worker
      Http.parser_worker(@env_template, @max_body_size)
    end

    # Instance-level wrapper around {Http.socket_write} that applies the
    # configured `write_timeout`.
    #
    # @param socket [TCPSocket] the socket to write to
    # @param string [String] the data to write
    # @return [void]
    # @raise [Http::WriteError] if the socket is not writable within the timeout or raises IOError
    #
    # @rbs (TCPSocket socket, String string) -> void
    def socket_write(socket, string)
      Http.socket_write(socket, string, timeout: @write_timeout)
    end

    # Instance-level wrapper around {Http.socket_writev} that applies the
    # configured `write_timeout`.
    #
    # @param socket [TCPSocket] the socket to write to
    # @param strings [Array<String>] the buffers to write in order
    # @return [void]
    # @raise [Http::WriteError] if the socket is not writable within the timeout or raises IOError
    #
    # @rbs (TCPSocket socket, Array[String] strings) -> void
    def socket_writev(socket, strings)
      Http.socket_writev(socket, strings, timeout: @write_timeout)
    end

    # Signals eager keep-alive loops to stop processing further requests on
    # their connections. In-flight requests complete normally.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      @running.make_false
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
      begin
        buffer = read_into_thread_buffer(socket)
      rescue IO::WaitReadable
        reactor.add(id: id, socket: socket, remote_addr: remote_addr, url_scheme: url_scheme)
        return
      rescue EOFError, IOError
        socket.close rescue nil
        return
      end

      env, parse_data, nread, parser = begin
        parse_next_request(buffer)
      rescue HttpParserError
        reject_malformed(socket)
        return
      end

      if !parser.finished?
        fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, 0, remote_addr, url_scheme, persisted: false)
        return
      elsif Http1.invalid_host?(env) || Http1.request_smuggling?(env)
        reject_malformed(socket)
        return
      elsif parser.has_body? && @max_body_size && parser.content_length > @max_body_size
        reject_oversized(socket)
        return
      end

      body = extract_body(buffer, env, parser, nread, decode_chunked: true)
      case body
      when :incomplete
        fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, 0, remote_addr, url_scheme, persisted: false)
        return
      when :too_large
        reject_oversized(socket)
        return
      when :malformed
        reject_malformed(socket)
        return
      end

      thread_pool << proc do
        process_client(socket, id, env, parse_data, body, reactor, thread_pool, 1, remote_addr, url_scheme)
      end
    end

    # Dispatches a parsed HTTP request to the thread pool when complete,
    # or hands it back to the reactor for more I/O when incomplete.
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

      if parsed_request[:malformed]
        socket = reactor.remove(parsed_request[:id])
        reject_malformed(socket) if socket
        return
      end

      unless parsed_request[:complete]
        parsed_request = send_continue_if_expected(parsed_request, reactor)
        reactor.update_state(parsed_request)
      else
        socket = reactor.remove(parsed_request[:id])
        request_count = (parsed_request[:request_count] || 0) + 1
        remote_addr = parsed_request[:remote_addr] || Server::DEFAULT_REMOTE_ADDR
        url_scheme = parsed_request[:url_scheme] || Server::HTTP_SCHEME

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

    # Reads pending bytes off `socket` into the thread-local read buffer,
    # draining any additional SSL-buffered bytes so `pending` is empty on
    # return. Raises `IO::WaitReadable`, `EOFError`, or `IOError` like the
    # underlying `read_nonblock` does.
    #
    # @param socket [TCPSocket] the socket to read from
    # @return [String] the thread-local buffer, freshly populated
    #
    # @rbs (TCPSocket socket) -> String
    def read_into_thread_buffer(socket)
      buffer = (Thread.current[:raptor_read_buffer] ||= String.new(capacity: READ_BUFFER_SIZE))
      socket.read_nonblock(READ_BUFFER_SIZE, buffer)

      while socket.respond_to?(:pending) && socket.pending > 0
        buffer << socket.read_nonblock(socket.pending)
      end

      buffer
    end

    # Runs a fresh HTTP/1.x parse against `buffer`, returning
    # `[env, parse_data, nread, parser]`. Raises `HttpParserError` on
    # malformed input.
    #
    # @param buffer [String] the raw request bytes
    # @return [Array(Hash, Hash, Integer, HttpParser)]
    #
    # @rbs (String buffer) -> [Hash[String, untyped], Hash[Symbol, untyped], Integer, HttpParser]
    def parse_next_request(buffer)
      parser = (Thread.current[:raptor_http_parser] ||= HttpParser.new)
      parser.reset
      env = @env_template.dup
      nread = parser.execute(env, buffer, 0)
      parse_data = { parse_count: 1, content_length: parser.content_length }
      [env, parse_data, nread, parser]
    end

    # Resolves the request body for a finished parse. Returns the body
    # `String` (or `nil` when the request has no body), or one of
    # `:incomplete`, `:too_large`, `:malformed` when the caller must
    # fall back or reject.
    #
    # @param buffer [String] the raw request bytes
    # @param env [Hash] the Rack environment being built
    # @param parser [HttpParser] the parser holding the finished parse state
    # @param nread [Integer] the byte offset where the body begins in `buffer`
    # @param decode_chunked [Boolean] whether to decode chunked bodies inline; when false chunked bodies signal `:incomplete`
    # @return [String, nil, Symbol]
    #
    # @rbs (String buffer, Hash[String, untyped] env, HttpParser parser, Integer nread, decode_chunked: bool) -> (String | Symbol)?
    def extract_body(buffer, env, parser, nread, decode_chunked:)
      return nil unless parser.has_body?

      body = buffer.byteslice(nread..-1) || ""

      if parser.chunked?
        return :incomplete unless decode_chunked

        body, chunked_state = Http1.decode_chunked(body, @max_body_size)
        case chunked_state
        when :complete
          env.delete(HTTP_TRANSFER_ENCODING)
          body
        else
          chunked_state
        end
      elsif parser.content_length > body.bytesize
        :incomplete
      else
        body
      end
    end

    # Returns true if the request expects a 100 Continue response per
    # RFC 7231 section 5.1.1.
    #
    # @param env [Hash] the parsed Rack environment (possibly incomplete)
    # @return [Boolean]
    #
    # @rbs (Hash[String, untyped] env) -> bool
    def expects_100_continue?(env)
      (env[Rack::SERVER_PROTOCOL] == HTTP_11) && env[HTTP_EXPECT]&.casecmp?(EXPECT_100_CONTINUE)
    end

    # Sends an HTTP 100 Continue response when the client requested
    # `Expect: 100-continue`, returning the state hash with `:continued`
    # set once written. A write failure is silently ignored.
    #
    # @param state [Hash] the partially-parsed connection state
    # @param reactor [Reactor] the reactor holding the connection's socket
    # @return [Hash] the state, with `:continued` set if 100 was written
    #
    # @rbs (Hash[Symbol, untyped] state, Reactor reactor) -> Hash[Symbol, untyped]
    def send_continue_if_expected(state, reactor)
      return state if state[:continued]

      env = state[:env]
      return state unless env && expects_100_continue?(env)

      socket = reactor.socket_for(state[:id])
      return state unless socket

      socket_write(socket, CONTINUE_RESPONSE) rescue nil
      state.merge(continued: true)
    end

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

    # Processes a single request. Builds the Rack env, calls the app,
    # writes the response, and returns whether the connection stays open
    # for another request.
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
          response_size = response_size(headers, body) unless hijacked
          response_started = true
          write_response(socket, rack_env, status, headers, body, keep_alive: keep_alive)
        end

        write_access_log(rack_env, status, response_size, remote_addr) if @access_log_io && !hijacked
        call_response_finished(rack_env, status, headers, nil)
        keep_alive && !hijacked
      rescue => error
        keep_alive = false
        handle_app_error(socket, rack_env, status, headers, error, response_started: response_started, hijacked: hijacked)
      ensure
        rack_input = rack_env && rack_env[Rack::RACK_INPUT]
        rack_input.close! rescue nil if rack_input.respond_to?(:close!)

        unless hijacked || keep_alive
          socket.close rescue nil
        end
      end
    end

    # Handles an exception raised while processing a request. Fires the
    # `rack.response_finished` callbacks with the error, writes a 500
    # response when no bytes have gone to the socket yet, and routes the
    # exception through the configured `on_error` handler (or re-raises).
    #
    # @param socket [TCPSocket] the client socket
    # @param rack_env [Hash, nil] the Rack environment, if it was built
    # @param status [Integer, nil] the status returned by the app, if any
    # @param headers [Hash, nil] the headers returned by the app, if any
    # @param error [Exception] the exception raised
    # @param response_started [Boolean] whether any response bytes have been written
    # @param hijacked [Boolean] whether the app took over the socket
    # @return [void]
    #
    # @rbs (TCPSocket socket, Hash[String, untyped]? rack_env, Integer? status, Hash[String, String | Array[String]]? headers, Exception error, response_started: bool, hijacked: bool) -> void
    def handle_app_error(socket, rack_env, status, headers, error, response_started:, hijacked:)
      call_response_finished(rack_env, status, headers, error) if rack_env
      socket.write(INTERNAL_SERVER_ERROR_RESPONSE) rescue nil unless response_started || hijacked

      if @on_error
        @on_error.call(rack_env, error) rescue nil
      else
        raise error
      end
    end

    # Reads and processes subsequent requests inline on a kept-alive
    # connection. Falls back to the reactor when no data arrives within the
    # timeout, the thread pool is saturated, or the request is incomplete.
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
        unless @running.true?
          socket.close rescue nil
          return
        end

        unless socket.wait_readable(KEEPALIVE_READ_TIMEOUT)
          reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
          return
        end

        begin
          buffer = read_into_thread_buffer(socket)
        rescue IO::WaitReadable
          reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
          return
        rescue EOFError
          socket.close rescue nil
          return
        end

        env, parse_data, nread, parser = begin
          parse_next_request(buffer)
        rescue HttpParserError
          reject_malformed(socket)
          return
        end

        if !parser.finished?
          fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, request_count, remote_addr, url_scheme)
          return
        end

        body = extract_body(buffer, env, parser, nread, decode_chunked: false)
        if body == :incomplete
          fallback_to_reactor(socket, id, buffer, env, parse_data, reactor, request_count, remote_addr, url_scheme)
          return
        end

        request_count += 1

        if thread_pool.queue_size >= thread_pool.size
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
    # an incomplete request is received on the fast path.
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
      continued = expects_100_continue?(env)
      socket_write(socket, CONTINUE_RESPONSE) rescue nil if continued

      reactor.persist(socket, id, request_count, remote_addr: remote_addr, url_scheme: url_scheme)
      state = {
        id: id,
        buffer: buffer.dup,
        env: env,
        request_count: request_count,
        parse_data: parse_data,
        remote_addr: remote_addr,
        url_scheme: url_scheme
      }
      state[:persisted] = true if persisted
      state[:continued] = true if continued
      reactor.update_state(Ractor.make_shareable(state))
    end

    # Writes a 413 response and closes the socket.
    #
    # @param socket [TCPSocket] the client socket
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def reject_oversized(socket)
      socket.write(CONTENT_TOO_LARGE_RESPONSE) rescue nil
      socket.close rescue nil
    end

    # Writes a 400 response and closes the socket.
    #
    # @param socket [TCPSocket] the client socket
    # @return [void]
    #
    # @rbs (TCPSocket socket) -> void
    def reject_malformed(socket)
      socket.write(BAD_REQUEST_RESPONSE) rescue nil
      socket.close rescue nil
    end

    # Builds a Rack environment hash from parsed HTTP request data.
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
    def build_rack_env(env, parse_data, body, socket, remote_addr: Server::DEFAULT_REMOTE_ADDR, url_scheme: Server::HTTP_SCHEME)
      env[Rack::RACK_INPUT] = build_rack_input(body)
      env[Rack::RACK_ERRORS] = $stderr
      env[Rack::RACK_RESPONSE_FINISHED] = []
      env[Rack::RACK_HIJACK] = proc do
        env[RACK_HIJACKED] = true
        env[RACK_HIJACK_IO] = socket
        socket
      end
      env[Rack::RACK_EARLY_HINTS] = proc do |hints|
        send_early_hints(socket, hints) rescue nil
      end

      unless env.key?(Rack::PATH_INFO)
        request_uri = env[Http::REQUEST_URI]
        scheme_end = request_uri&.index("://")
        if scheme_end
          authority_end = request_uri.index("/", scheme_end + 3) || request_uri.bytesize
          path_and_query = request_uri.byteslice(authority_end..-1) || ""
          if query_delim = path_and_query.index("?")
            env[Rack::PATH_INFO] = query_delim.zero? ? "/" : path_and_query.byteslice(0, query_delim)
            env[Rack::QUERY_STRING] = path_and_query.byteslice(query_delim + 1..-1)
          else
            env[Rack::PATH_INFO] = path_and_query.empty? ? "/" : path_and_query
          end
        else
          env[Rack::PATH_INFO] = ""
        end
      end

      if (content_length = parse_data[:content_length]).positive?
        env[Http::CONTENT_LENGTH] = content_length.to_s
      end

      env[Http::REMOTE_ADDR] = remote_addr
      env[Http::HTTP_VERSION] = env[Rack::SERVER_PROTOCOL]

      behind_tls_proxy = (url_scheme == Server::HTTP_SCHEME) && forwarded_https?(env)
      env[Rack::RACK_URL_SCHEME] = behind_tls_proxy ? Server::HTTPS_SCHEME : url_scheme
      default_port = behind_tls_proxy ? "443" : @server_port_string

      http_host = env[Rack::HTTP_HOST]
      host = nil
      port = nil
      if http_host && !http_host.empty?
        if http_host.start_with?("[")
          bracket_end = http_host.index("]")
          if bracket_end
            host = http_host.byteslice(1, bracket_end - 1)
            port_colon = http_host.index(":", bracket_end + 1)
            port = port_colon && http_host.byteslice(port_colon + 1, http_host.bytesize - port_colon - 1)
          end
        else
          colon = http_host.index(":")
          if colon
            host = http_host.byteslice(0, colon)
            port = http_host.byteslice(colon + 1, http_host.bytesize - colon - 1)
          else
            host = http_host
          end
        end
      end
      env[Rack::SERVER_NAME] ||= host || Server::DEFAULT_SERVER_NAME
      env[Rack::SERVER_PORT] ||= port || default_port

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

    # Returns true when an upstream proxy signals that it terminated TLS for
    # this request via `X-Forwarded-Proto`, `X-Forwarded-Scheme`, or
    # `X-Forwarded-Ssl`. Only the first comma-separated value is consulted.
    #
    # @param env [Hash] the Rack environment
    # @return [Boolean]
    #
    # @rbs (Hash[String, untyped] env) -> bool
    def forwarded_https?(env)
      proto = env["HTTP_X_FORWARDED_PROTO"] || env["HTTP_X_FORWARDED_SCHEME"]
      return true if proto && proto.split(",").first&.strip&.casecmp?(Server::HTTPS_SCHEME)

      env["HTTP_X_FORWARDED_SSL"]&.casecmp?("on") || false
    end

    # Returns true when the connection should be kept alive after the
    # current response.
    #
    # @param env [Hash] the Rack environment
    # @param request_count [Integer] number of requests handled on this connection
    # @return [Boolean] true if the connection should be kept alive
    #
    # @rbs (Hash[String, untyped] env, Integer request_count) -> bool
    def keep_alive?(env, request_count)
      return false if request_count >= @max_keepalive_requests

      connection_header = env[HTTP_CONNECTION]

      if env[Rack::SERVER_PROTOCOL] == HTTP_11
        !connection_header&.casecmp?(CONNECTION_CLOSE)
      else
        connection_header&.casecmp?(CONNECTION_KEEPALIVE) || false
      end
    end

    # Sends an HTTP 103 Early Hints response, skipping any entries with
    # illegal header keys or values. No-ops when `hints` is empty.
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

    # Returns a normalised copy of the response headers with lowercased
    # keys and illegal/`rack.*`/`status` entries dropped.
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

    # Raises when the headers include entries forbidden for the response
    # status (`content-type` or `content-length` on a 204, 304, or 1xx).
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

    # Returns the HTTP status line for `status`.
    #
    # @param http_version [String] "HTTP/1.1" or "HTTP/1.0"
    # @param status [Integer] HTTP status code
    # @return [String] the status line including trailing CRLF
    #
    # @rbs (String http_version, Integer status) -> String
    def build_status_line(http_version, status)
      cache = http_version == HTTP_11 ? STATUS_LINE_CACHE_11 : STATUS_LINE_CACHE_10
      response = (Thread.current[:raptor_response_buffer] ||= String.new(capacity: RESPONSE_BUFFER_CAPACITY))
      response.clear
      response << cache[status]
      response
    end

    # Writes the response headers, uncorks the socket, and hands the raw
    # socket to the hijack callback.
    #
    # @param socket [TCPSocket] the client socket
    # @param response [String] the status line accumulated so far
    # @param headers [Hash] normalized response headers
    # @param response_hijack [Proc] callable that receives the socket and writes the body
    # @return [void]
    #
    # @rbs (TCPSocket socket, String response, Hash[String, String | Array[String]] headers, ^(TCPSocket) -> void response_hijack) -> void
    def write_hijacked_response(socket, response, headers, response_hijack)
      format_headers(response, headers)
      response << "\r\n"
      socket_write(socket, response)
      uncork_socket(socket)
      response_hijack.call(socket)
    end

    # Writes a response with no entity body, adding a zero
    # `Content-Length` when the status may carry a body but none was
    # supplied.
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

      format_headers(response, headers)
      response << "\r\n"
      socket_write(socket, response)
    end

    # Writes a complete response with a body. Emits a `Content-Length`
    # when the total size is known upfront, otherwise chunked encoding on
    # HTTP/1.1.
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
        format_headers(response, headers)
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

      format_headers(response, headers)
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
    end

    # Returns the byte length of the body when it can be determined
    # upfront (array or file), otherwise nil.
    #
    # @param body [Object] the response body
    # @return [Integer, nil] the byte length, or nil if it cannot be determined
    #
    # @rbs (untyped body) -> Integer?
    def calculate_content_length(body)
      if body.respond_to?(:to_ary)
        array = body.to_ary
        return unless array.is_a?(Array)

        array.sum { |chunk| chunk.is_a?(String) ? chunk.bytesize : 0 }
      elsif body.respond_to?(:to_path) && (path = body.to_path) && File.readable?(path)
        File.size(path)
      else
        nil
      end
    end

    # Writes a file body to the socket.
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
          buffer = response
          while (chunk = file.read(FILE_CHUNK_SIZE))
            buffer << chunk.bytesize.to_s(16) << "\r\n" << chunk << "\r\n"
            if buffer.bytesize >= CHUNKED_WRITE_THRESHOLD
              socket_write(socket, buffer)
              buffer = +""
            end
          end
          buffer << "0\r\n\r\n"
          socket_write(socket, buffer)
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

    # Writes a single-element array body to the socket.
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
        response << chunk.bytesize.to_s(16) << "\r\n" << chunk << "\r\n0\r\n\r\n"
        socket_write(socket, response)
      else
        socket_writev(socket, [response, chunk])
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
        buffer = response
        body_array.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)

          next if chunk.empty?

          buffer << chunk.bytesize.to_s(16) << "\r\n" << chunk << "\r\n"
          if buffer.bytesize >= CHUNKED_WRITE_THRESHOLD
            socket_write(socket, buffer)
            buffer = +""
          end
        end
        buffer << "0\r\n\r\n"
        socket_write(socket, buffer)
      else
        body_array.each do |chunk|
          raise TypeError, "body must yield String values" unless chunk.is_a?(String)
        end
        socket_writev(socket, [response, *body_array])
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
        socket_write(socket, "0\r\n\r\n")
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

    # Appends normalised header lines to `result`. Skips entries with
    # illegal keys or values. Array values are written as separate lines.
    #
    # @param headers [Hash] normalized response headers
    # @return [String] formatted header lines, each ending with CRLF
    #
    # @rbs (String result, Hash[String, String | Array[String]] headers) -> void
    def format_headers(result, headers)
      headers.each do |name, value|
        next if illegal_header_key?(name)

        if value.is_a?(Array)
          value.each { |entry| append_header_value(result, name, entry) }
        else
          append_header_value(result, name, value)
        end
      end
    end

    # Appends one or more `name: value` header lines to `result`, splitting
    # newline-joined values across separate lines and skipping empty or
    # illegal values.
    #
    # @param result [String] the buffer to append to
    # @param name [String] the header name
    # @param value [Object] the header value (any object responding to `to_s`)
    # @return [void]
    #
    # @rbs (String result, String name, untyped value) -> void
    def append_header_value(result, name, value)
      string_value = value.is_a?(String) ? value : value.to_s
      return if string_value.empty?

      if string_value.include?("\n")
        string_value.split("\n").each do |line|
          next if line.empty? || illegal_header_value?(line)

          result << name << ": " << line << "\r\n"
        end
      else
        return if illegal_header_value?(string_value)

        result << name << ": " << string_value << "\r\n"
      end
    end

    # Calls every `rack.response_finished` callback in reverse
    # registration order, rescuing any that raise.
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

    # Instance-level wrapper around {Http.write_access_log} that routes to
    # the configured `@access_log_io`.
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

    # Returns the response body size as a String for the access log, taken
    # from the `content-length` header when set, computed from the body
    # otherwise, or `-` when the size cannot be determined upfront.
    #
    # @param headers [Hash] the response headers
    # @param body [Object] the response body
    # @return [String]
    #
    # @rbs (Hash[String, String | Array[String]] headers, untyped body) -> String
    def response_size(headers, body)
      headers[Rack::CONTENT_LENGTH] || calculate_content_length(body)&.to_s || "-"
    end

    if Socket.const_defined?(:TCP_CORK)
      # Enables `TCP_CORK` on the socket to batch outgoing packets into
      # fewer segments. Linux-only; a no-op elsewhere.
      #
      # @param socket [TCPSocket] the socket to cork
      # @return [void]
      #
      # @rbs (TCPSocket socket) -> void
      def cork_socket(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 1) if socket.is_a?(TCPSocket)
      end

      # Disables `TCP_CORK` on the socket, flushing any buffered packets.
      # Linux-only; a no-op elsewhere.
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
