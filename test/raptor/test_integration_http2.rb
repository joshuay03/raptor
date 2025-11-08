# frozen_string_literal: true

require "test_helper"

require "openssl"
require "socket"
require "tempfile"
require "timeout"

require "http/2"
require "raptor/cli"
require "raptor/cluster"

module Raptor
  class TestIntegrationHttp2 < TestCase
    def setup
      generate_test_certs

      @options = CLI::DEFAULT_OPTIONS.merge(
        binds: ["ssl://127.0.0.1:0?cert=#{@cert_path}&key=#{@key_path}"],
        workers: 1,
        rackup: File.expand_path("../fixtures/hello_world.ru", __dir__)
      )
    end

    def teardown
      @cert_file&.unlink
      @key_file&.unlink
    end

    def test_basic_http2_get_request
      with_http2_server do |port|
        responses = http2_get(port, "/")

        assert_equal 1, responses.size
        assert_equal "200", responses[0][:status]
        assert_equal "Hello, World!", responses[0][:body]
      end
    end

    def test_http2_request_method
      with_http2_server("request_method.ru") do |port|
        responses = http2_request(port, "POST", "/", body: "data")

        assert_equal 1, responses.size
        assert_equal "200", responses[0][:status]
        assert_equal "POST", responses[0][:body]
      end
    end

    def test_http2_path_info
      with_http2_server("path_info.ru") do |port|
        responses = http2_get(port, "/foo/bar")

        assert_equal 1, responses.size
        assert_equal "200", responses[0][:status]
        assert_equal "/foo/bar", responses[0][:body]
      end
    end

    def test_http2_query_string
      with_http2_server("query_string.ru") do |port|
        responses = http2_get(port, "/?foo=bar&baz=qux")

        assert_equal 1, responses.size
        assert_equal "200", responses[0][:status]
        assert_equal "foo=bar&baz=qux", responses[0][:body]
      end
    end

    def test_http2_response_headers
      with_http2_server do |port|
        responses = http2_get(port, "/")

        assert_equal "text/plain", responses[0][:headers]["content-type"]
      end
    end

    def test_http2_post_with_body
      with_http2_server("rack_input.ru") do |port|
        responses = http2_request(port, "POST", "/", body: "request body content")

        assert_equal "200", responses[0][:status]
        assert_equal "request body content", responses[0][:body]
      end
    end

    def test_http2_concurrent_streams
      with_http2_server do |port|
        responses = http2_concurrent_gets(port, ["/", "/", "/"])

        assert_equal 3, responses.size
        responses.each do |response|
          assert_equal "200", response[:status]
          assert_equal "Hello, World!", response[:body]
        end
      end
    end

    private

    def generate_test_certs
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = OpenSSL::X509::Name.parse("CN=localhost")
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest::SHA256.new)

      @cert_file = Tempfile.new(["cert", ".pem"])
      @cert_file.write(cert.to_pem)
      @cert_file.close
      @cert_path = @cert_file.path

      @key_file = Tempfile.new(["key", ".pem"])
      @key_file.write(key.to_pem)
      @key_file.close
      @key_path = @key_file.path
    end

    def with_http2_server(fixture = nil)
      if fixture
        @options[:rackup] = File.expand_path("../fixtures/#{fixture}", __dir__)
      end

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)

      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_ssl_server(server_port)

      yield server_port
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def wait_for_ssl_server(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10

      loop do
        raise Timeout::Error, "server did not become ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        tcp = TCPSocket.new("127.0.0.1", port)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.sync_close = true

        begin
          ssl.connect_nonblock
        rescue IO::WaitReadable, IO::WaitWritable
          if IO.select([ssl], [ssl], nil, 1)
            retry
          else
            ssl.close rescue nil
            sleep 0.1
            next
          end
        end

        ssl.close
        break
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError
        sleep 0.1
      end
    end

    def http2_get(port, path)
      http2_request(port, "GET", path)
    end

    def http2_request(port, method, path, body: nil)
      responses = []

      ssl_socket = connect_http2(port)
      conn = HTTP2::Client.new

      conn.on(:frame) { |bytes| ssl_socket.write(bytes) }

      stream = conn.new_stream
      response = { headers: {}, body: +"" }

      stream.on(:headers) do |response_headers|
        response_headers.each do |name, value|
          if name == ":status"
            response[:status] = value
          else
            response[:headers][name] = value
          end
        end
      end

      stream.on(:data) { |chunk| response[:body] << chunk }
      stream.on(:close) { responses << response }

      request_headers = {
        ":method" => method,
        ":path" => path,
        ":scheme" => "https",
        ":authority" => "localhost:#{port}"
      }

      if body
        stream.headers(request_headers, end_stream: false)
        stream.data(body)
      else
        stream.headers(request_headers, end_stream: true)
      end

      read_http2_responses(ssl_socket, conn)

      responses
    ensure
      ssl_socket&.close rescue nil
    end

    def http2_concurrent_gets(port, paths)
      responses = []

      ssl_socket = connect_http2(port)
      conn = HTTP2::Client.new

      conn.on(:frame) { |bytes| ssl_socket.write(bytes) }

      paths.each do |path|
        stream = conn.new_stream
        response = { headers: {}, body: +"" }

        stream.on(:headers) do |response_headers|
          response_headers.each do |name, value|
            if name == ":status"
              response[:status] = value
            else
              response[:headers][name] = value
            end
          end
        end

        stream.on(:data) { |chunk| response[:body] << chunk }
        stream.on(:close) { responses << response }

        stream.headers({
          ":method" => "GET",
          ":path" => path,
          ":scheme" => "https",
          ":authority" => "localhost:#{port}"
        }, end_stream: true)
      end

      read_http2_responses(ssl_socket, conn)

      responses
    ensure
      ssl_socket&.close rescue nil
    end

    def connect_http2(port)
      tcp_socket = TCPSocket.new("127.0.0.1", port)
      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl_context.alpn_protocols = ["h2"]

      ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
      ssl_socket.sync_close = true
      ssl_socket.connect
      ssl_socket
    end

    def read_http2_responses(ssl_socket, conn)
      Timeout.timeout(5) do
        loop do
          data = ssl_socket.readpartial(65_536)
          conn << data
        rescue EOFError
          break
        end
      end
    rescue Timeout::Error
      # Server keeps connection open; timeout indicates all responses received
    end
  end
end
