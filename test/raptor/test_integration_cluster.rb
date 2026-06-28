# frozen_string_literal: true

require "test_helper"

require "json"
require "net/http"
require "tempfile"
require "timeout"
require "uri"

require "nio"
require "raptor/cli"
require "raptor/cluster"

module Raptor
  class TestIntegrationCluster < TestCase
    def setup
      @options = CLI::DEFAULT_OPTIONS.merge(
        binds: ["tcp://127.0.0.1:0"],
        workers: 1,
        rackup: File.expand_path("../fixtures/hello_world.ru", __dir__)
      )
    end

    def test_basic_http_request_response_cycle
      with_server do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "Hello, World!", response.body
        assert_equal "text/plain", response["content-type"]
      end
    end

    def test_head_request_returns_no_body
      with_server("head_request.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          http.head(uri.path)
        end

        assert_equal 200, response.code.to_i
        assert_equal "text/plain", response["content-type"]
        assert response.body.nil? || response.body.empty?
      end
    end

    def test_request_method
      with_server("request_method.ru") do |uri|
        response = Net::HTTP.post(uri, "data")

        assert_equal 200, response.code.to_i
        assert_equal "POST", response.body
      end
    end

    def test_path_info
      with_server("path_info.ru") do |uri|
        uri.path = "/foo/bar"
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "/foo/bar", response.body
      end
    end

    def test_query_string_with_parameters
      with_server("query_string.ru") do |uri|
        uri.query = "foo=bar&baz=qux"
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "foo=bar&baz=qux", response.body
      end
    end

    def test_query_string_empty_when_none_provided
      with_server("query_string.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "", response.body
      end
    end

    def test_rack_input_with_post_body
      with_server("rack_input.ru") do |uri|
        response = Net::HTTP.post(uri, "request body data")

        assert_equal 200, response.code.to_i
        assert_equal "request body data", response.body.strip
      end
    end

    def test_rack_input_uses_stringio_below_spool_threshold
      with_server("rack_input_class.ru") do |uri|
        response = Net::HTTP.post(uri, "small body")

        assert_equal "StringIO", response.body
      end
    end

    def test_rack_input_uses_tempfile_above_spool_threshold
      @options[:connection] = @options[:connection].merge(body_spool_threshold: 4)

      with_server("rack_input_class.ru") do |uri|
        response = Net::HTTP.post(uri, "body larger than four bytes")

        assert_equal "Tempfile", response.body
      end
    end

    def test_chunked_request_body_decoded
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri, "POST / HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")

        assert_match(/200 OK/, response)
        assert_match(/hello world/, response)
      end
    end

    def test_expect_100_continue_sent_before_body
      with_server("rack_input.ru") do |uri|
        socket = TCPSocket.new(uri.host, uri.port)
        socket.write(
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Content-Length: 5\r\n" \
          "Expect: 100-continue\r\n" \
          "Connection: close\r\n\r\n"
        )

        expected = Raptor::Http1::CONTINUE_RESPONSE
        assert_equal expected, Timeout.timeout(5) { socket.read(expected.bytesize) }

        socket.write("hello")
        response = Timeout.timeout(5) { socket.read }

        assert_match(/\AHTTP\/1\.1 200/, response)
        assert_includes response, "hello"
      ensure
        socket&.close
      end
    end

    def test_expect_100_continue_ignored_for_http10
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.0\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Content-Length: 5\r\n" \
          "Expect: 100-continue\r\n" \
          "Connection: close\r\n\r\nhello"
        )

        refute_match(/100 Continue/, response)
        assert_match(/\AHTTP\/1\.[01] 200/, response)
        assert_includes response, "hello"
      end
    end

    def test_array_body_with_multiple_chunks
      with_server("array_body.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "Hello, World!", response.body
        assert_equal 13, response["content-length"].to_i
      end
    end

    def test_enumerable_body
      with_server("enumerable_body.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "Chunk by chunk", response.body
      end
    end

    def test_file_body_via_to_path
      file = Tempfile.new(["test", ".txt"])
      file.write("File content here")
      file.close

      with_server("file_body.ru", file_path: file.path) do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "File content here", response.body
        assert_equal 17, response["content-length"].to_i
      end
    ensure
      file&.unlink
    end

    def test_status_204_has_no_content_type
      with_server("status_204.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 204, response.code.to_i
        assert_nil response["content-type"]
        assert response.body.nil? || response.body.empty?
      end
    end

    def test_status_204_has_no_content_length
      with_server("status_204.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 204, response.code.to_i
        assert_nil response["content-length"]
      end
    end

    def test_status_304_has_no_content_type
      with_server("status_304.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 304, response.code.to_i
        assert_nil response["content-type"]
        assert response.body.nil? || response.body.empty?
      end
    end

    def test_status_304_has_no_content_length
      with_server("status_304.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 304, response.code.to_i
        assert_nil response["content-length"]
      end
    end

    def test_rack_version_present
      with_server("rack_version.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        refute_empty response.body
        assert_match(/\d/, response.body)
      end
    end

    def test_server_software_present
      with_server("server_software.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "Raptor/#{Raptor::VERSION}", response.body
      end
    end

    def test_http_version_present
      with_server("http_version.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "HTTP/1.1", response.body
      end
    end

    def test_environment_option_sets_internal_environment
      @options[:environment] = "production"

      cluster = without_output { Cluster.new(@options) }

      assert_equal "production", cluster.instance_variable_get(:@environment)
    ensure
      cluster&.instance_variable_get(:@binder)&.close
    end

    def test_environment_falls_back_to_rails_env_then_rack_env_then_development
      original_rack_env = ENV["RACK_ENV"]
      original_rails_env = ENV["RAILS_ENV"]
      ENV.delete("RACK_ENV")
      ENV.delete("RAILS_ENV")

      cluster = without_output { Cluster.new(@options) }
      assert_equal "development", cluster.instance_variable_get(:@environment)
      cluster.instance_variable_get(:@binder).close

      ENV["RACK_ENV"] = "rack_only"
      cluster = without_output { Cluster.new(@options) }
      assert_equal "rack_only", cluster.instance_variable_get(:@environment)
      cluster.instance_variable_get(:@binder).close

      ENV["RAILS_ENV"] = "rails_wins"
      cluster = without_output { Cluster.new(@options) }
      assert_equal "rails_wins", cluster.instance_variable_get(:@environment)
    ensure
      ENV["RACK_ENV"] = original_rack_env
      ENV["RAILS_ENV"] = original_rails_env
      cluster&.instance_variable_get(:@binder)&.close
    end

    def test_chdir_option_changes_working_directory
      original_pwd = Dir.pwd
      target = File.realpath("/tmp")

      @options[:chdir] = target

      with_server("cwd.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal target, response.body
      end
    ensure
      Dir.chdir(original_pwd) if original_pwd
    end

    def test_server_name_and_port
      with_server("server_name_port.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_match(/\S+:\d+/, response.body)
      end
    end

    def test_x_forwarded_proto_promotes_to_https
      with_server("forwarded_proto.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["X-Forwarded-Proto"] = "https"
          request["Host"] = "example.com"
          http.request(request)
        end

        assert_equal "https|443", response.body
      end
    end

    def test_x_forwarded_scheme_promotes_to_https
      with_server("forwarded_proto.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["X-Forwarded-Scheme"] = "https"
          request["Host"] = "example.com"
          http.request(request)
        end

        assert_equal "https|443", response.body
      end
    end

    def test_x_forwarded_ssl_promotes_to_https
      with_server("forwarded_proto.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["X-Forwarded-Ssl"] = "on"
          request["Host"] = "example.com"
          http.request(request)
        end

        assert_equal "https|443", response.body
      end
    end

    def test_x_forwarded_proto_takes_first_value_from_proxy_chain
      with_server("forwarded_proto.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["X-Forwarded-Proto"] = "https, http"
          request["Host"] = "example.com"
          http.request(request)
        end

        assert_equal "https|443", response.body
      end
    end

    def test_http_headers_prefixed
      with_server("http_headers.ru") do |uri|
        response = Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = "TestAgent/1.0"
          http.request(request)
        end

        assert_equal 200, response.code.to_i
        assert_equal "TestAgent/1.0", response.body
      end
    end

    def test_multiple_header_values
      with_server("multiple_headers.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        cookies = response.get_fields("set-cookie")
        assert_equal 2, cookies.length
        assert_includes cookies, "cookie1=value1"
        assert_includes cookies, "cookie2=value2"
      end
    end

    def test_newline_joined_header_values
      with_server("newline_joined_headers.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        cookies = response.get_fields("set-cookie")
        assert_equal 2, cookies.length
        assert_includes cookies, "cookie1=value1"
        assert_includes cookies, "cookie2=value2"
      end
    end

    def test_rack_headers_not_sent_to_client
      with_server("rack_header_filtering.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_nil response["rack.custom"]
        assert_nil response["status"]
      end
    end

    def test_remote_addr_in_rack_env
      with_server("remote_addr.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "127.0.0.1", response.body
      end
    end

    def test_rack_is_hijack_present_in_env
      with_server("rack_is_hijack.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
      end
    end

    def test_connection_keepalive_header_on_http11
      with_server do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal "keep-alive", response["connection"]
      end
    end

    def test_connection_close_when_client_requests_close
      with_server do |uri|
        Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Connection"] = "close"
          response = http.request(request)

          assert_equal "close", response["connection"]
        end
      end
    end

    def test_keepalive_multiple_requests_on_same_connection
      with_server do |uri|
        Net::HTTP.start(uri.host, uri.port) do |http|
          3.times do
            response = http.get(uri.path)

            assert_equal 200, response.code.to_i
            assert_equal "Hello, World!", response.body
          end
        end
      end
    end

    def test_http10_connection_defaults_to_close
      with_server do |uri|
        response = raw_request(uri, "GET / HTTP/1.0\r\nHost: #{uri.host}:#{uri.port}\r\n\r\n")

        assert_match(/HTTP\/1\.0 200 OK/, response)
        assert_match(/connection: close/i, response)
      end
    end

    def test_http10_connection_keepalive_when_requested
      @options[:http1] = @options[:http1].merge(persistent_data_timeout: 1)

      with_server do |uri|
        response = raw_request(uri, "GET / HTTP/1.0\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: keep-alive\r\n\r\n")

        assert_match(/connection: keep-alive/i, response)
      end
    end

    def test_first_data_timeout_returns_408
      @options[:connection] = @options[:connection].merge(first_data_timeout: 1)

      with_server do |uri|
        socket = TCPSocket.new(uri.host, uri.port)
        response = Timeout.timeout(5) { socket.read }

        assert_match(/408 Request Timeout/, response)
      ensure
        socket&.close
      end
    end

    def test_app_error_returns_500
      with_server("error_500.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 500, response.code.to_i
      end
    end

    def test_on_error_callback_invoked_on_app_error
      log_path = "/tmp/raptor_test_on_error_#{Process.pid}.log"
      File.delete(log_path) rescue nil
      @options[:on_error] = ->(env, error) { File.write(log_path, "#{env[Rack::PATH_INFO]}:#{error.class}") }

      with_server("error_500.ru") do |uri|
        Net::HTTP.get_response(uri)

        Timeout.timeout(5) do
          loop do
            break if File.exist?(log_path) && File.size(log_path) > 0
            sleep 0.1
          end
        end

        assert_equal "/:RuntimeError", File.read(log_path)
      end
    ensure
      File.delete(log_path) rescue nil
    end

    def test_max_body_size_returns_413
      @options[:connection] = @options[:connection].merge(max_body_size: 5)

      with_server("rack_input.ru") do |uri|
        response = Net::HTTP.post(uri, "this body is well over five bytes")

        assert_equal 413, response.code.to_i
      end
    end

    def test_transfer_encoding_with_content_length_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Transfer-Encoding: chunked\r\n" \
          "Content-Length: 5\r\n" \
          "Connection: close\r\n\r\n" \
          "5\r\nhello\r\n0\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_transfer_encoding_without_chunked_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Transfer-Encoding: gzip\r\n" \
          "Connection: close\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_chunked_not_last_in_transfer_encoding_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Transfer-Encoding: chunked, gzip\r\n" \
          "Connection: close\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_negative_content_length_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Content-Length: -5\r\n" \
          "Connection: close\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_non_digit_content_length_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Content-Length: 10abc\r\n" \
          "Connection: close\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_duplicate_content_length_returns_400
      with_server("rack_input.ru") do |uri|
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Content-Length: 100\r\n" \
          "Content-Length: 200\r\n" \
          "Connection: close\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_excessive_chunk_overhead_returns_400
      with_server("rack_input.ru") do |uri|
        bloated_extension = "A" * (Raptor::Http1::MAX_CHUNK_OVERHEAD + 1)
        response = raw_request(uri,
          "POST / HTTP/1.1\r\n" \
          "Host: #{uri.host}:#{uri.port}\r\n" \
          "Transfer-Encoding: chunked\r\n" \
          "Connection: close\r\n\r\n" \
          "1; #{bloated_extension}\r\nX\r\n0\r\n\r\n"
        )

        assert_match(/400 Bad Request/, response)
      end
    end

    def test_too_long_uri_returns_400
      with_server do |uri|
        long_path = "/" + "a" * (13 * 1024)
        response = raw_request(uri, "GET #{long_path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n")

        assert_match(/400 Bad Request/, response)

        assert_equal 200, Net::HTTP.get_response(uri).code.to_i
      end
    end

    def test_too_long_uri_on_keepalive_returns_400
      with_server do |uri|
        socket = TCPSocket.new(uri.host, uri.port)
        long_path = "/" + "a" * (13 * 1024)
        socket.write("GET / HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\n\r\n")
        first_response = String.new
        Timeout.timeout(5) do
          first_response << socket.readpartial(1024) until first_response.include?("Hello, World!")
        end

        socket.write("GET #{long_path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n")
        response = Timeout.timeout(5) { socket.read }

        assert_match(/200 OK/, first_response)
        assert_match(/400 Bad Request/, response)

        assert_equal 200, Net::HTTP.get_response(uri).code.to_i
      ensure
        socket&.close
      end
    end

    def test_too_long_uri_via_slow_path_returns_400
      with_server do |uri|
        socket = TCPSocket.new(uri.host, uri.port)
        socket.write("GET /aa")
        sleep 0.1
        socket.write("#{"a" * (13 * 1024)} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n")
        response = Timeout.timeout(5) { socket.read }

        assert_match(/400 Bad Request/, response)

        assert_equal 200, Net::HTTP.get_response(uri).code.to_i
      ensure
        socket&.close
      end
    end

    def test_unix_socket_binding
      socket_path = "/tmp/raptor_test_#{Process.pid}.sock"
      File.delete(socket_path) rescue nil

      with_unix_server(socket_path) do
        response = raw_unix_request(socket_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

        assert_match(/200 OK/, response)
        assert_match(/Hello, World!/, response)
      end
    end

    def test_partial_hijack_response
      with_server("hijack.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "hijacked body", response.body
      end
    end

    def test_full_hijack_response
      with_server("full_hijack.ru") do |uri|
        response = Net::HTTP.get_response(uri)

        assert_equal 200, response.code.to_i
        assert_equal "hijacked full!", response.body
      end
    end

    def test_stats_file_written_after_startup
      stats_path = "/tmp/raptor_test_stats_#{Process.pid}.json"
      File.delete(stats_path) rescue nil
      @options[:stats_file] = stats_path

      with_server do |uri|
        data = nil
        Timeout.timeout(5) do
          loop do
            if File.exist?(stats_path)
              data = JSON.parse(File.read(stats_path), symbolize_names: true)
              break if data[:workers].first[:booted]
            end
            sleep 0.1
          end
        end

        assert_operator data[:master_pid], :>, 0
        assert_equal 1, data[:workers].length
        assert data[:workers].first[:booted]
      end
    ensure
      File.delete(stats_path) rescue nil
    end

    def test_pid_file_written_and_removed
      pid_file_path = "/tmp/raptor_test_#{Process.pid}.pid"
      File.delete(pid_file_path) rescue nil
      @options[:pid_file] = pid_file_path

      with_server do
        Timeout.timeout(5) do
          loop do
            break if File.exist?(pid_file_path)
            sleep 0.1
          end
        end

        assert_match(/\A\d+\z/, File.read(pid_file_path))
      end

      assert !File.exist?(pid_file_path)
    ensure
      File.delete(pid_file_path) rescue nil
    end

    def test_stats_populated_after_requests
      cluster = without_output { Cluster.new(@options) }
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      server_port = cluster.instance_variable_get(:@server_port)

      wait_for_server(server_port)

      uri = URI("http://127.0.0.1:#{server_port}/")
      3.times { Net::HTTP.get_response(uri) }

      stats = nil
      Timeout.timeout(5) do
        loop do
          stats = cluster.stats
          break if stats.first&.dig(:requests).to_i >= 3

          sleep 0.1
        end
      end

      assert_equal 1, stats.length
      assert stats.first[:booted]
      assert_operator stats.first[:requests], :>=, 3
      assert_operator stats.first[:pid], :>, 0
      assert_in_delta Time.now.to_f, stats.first[:last_checkin], 5
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def test_worker_restart_on_crash
      @options[:workers] = 2
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      uri = URI("http://127.0.0.1:#{server_port}/")
      assert_equal 200, Net::HTTP.get_response(uri).code.to_i

      worker_pids = `pgrep -P #{cluster_pid}`.strip.split.map(&:to_i).reject(&:zero?)
      skip "could not find worker PIDs" if worker_pids.empty?

      Process.kill("KILL", worker_pids.first) rescue nil

      wait_for_server(server_port)
      assert_equal 200, Net::HTTP.get_response(uri).code.to_i
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def test_phased_restart_on_usr1_replaces_workers
      @options[:workers] = 2
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      original_pids = `pgrep -P #{cluster_pid}`.strip.split.map(&:to_i).reject(&:zero?).sort
      skip "could not find worker PIDs" if original_pids.empty?

      Process.kill("USR1", cluster_pid)

      current_pids = []
      Timeout.timeout(30) do
        loop do
          current_pids = `pgrep -P #{cluster_pid}`.strip.split.map(&:to_i).reject(&:zero?).sort
          break if current_pids.length == original_pids.length && (current_pids & original_pids).empty?

          sleep 0.1
        end
      end

      assert_equal original_pids.length, current_pids.length
      assert_empty(current_pids & original_pids)
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def test_hot_restart_on_usr2_re_execs_master_and_inherits_listener
      sock_path = "/tmp/raptor_hot_test_#{Process.pid}.sock"
      stats_path = "/tmp/raptor_hot_stats_#{Process.pid}.json"
      File.delete(sock_path) rescue nil
      File.delete(stats_path) rescue nil

      raptor_exe = File.expand_path("../../exe/raptor", __dir__)
      lib_path = File.expand_path("../../lib", __dir__)
      fixture_path = File.expand_path("../fixtures/hello_world.ru", __dir__)

      cluster_pid = Process.spawn(
        RbConfig.ruby, "-I", lib_path, raptor_exe,
        "-b", "unix://#{sock_path}",
        "-w", "1",
        "--stats-file", stats_path,
        fixture_path,
        out: "/dev/null", err: "/dev/null"
      )

      initial_worker_pid = wait_for_booted_worker_pid(stats_path)

      response = raw_unix_request(sock_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match %r{\AHTTP/1\.1 200 OK}, response

      Process.kill("USR2", cluster_pid)

      restarted_worker_pid = wait_for_booted_worker_pid(stats_path, except: initial_worker_pid)

      refute_equal initial_worker_pid, restarted_worker_pid
      assert_equal cluster_pid, JSON.parse(File.read(stats_path), symbolize_names: true)[:master_pid]

      response = raw_unix_request(sock_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match %r{\AHTTP/1\.1 200 OK}, response
    ensure
      Process.kill("TERM", cluster_pid) rescue nil
      Process.wait(cluster_pid) rescue nil
      File.delete(sock_path) rescue nil
      File.delete(stats_path) rescue nil
    end

    def test_cluster_shuts_down_promptly_with_active_keepalive_pipeline
      fixture_content = <<~RUBY
        run proc { |_env| sleep 0.2; [200, { "content-type" => "text/plain" }, ["ok"]] }
      RUBY
      rackup_file = Tempfile.new(["config", ".ru"])
      rackup_file.write(fixture_content)
      rackup_file.close
      @options[:rackup] = rackup_file.path

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      client_socket = TCPSocket.new("127.0.0.1", server_port)
      client_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      client_thread = Thread.new do
        loop do
          client_socket.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
          response = String.new
          response << client_socket.readpartial(1024) until response.include?("ok")
        rescue
          break
        end
      end

      sleep 0.3

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", cluster_pid)
      Process.wait(cluster_pid)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      client_thread.join

      assert_operator elapsed, :<, 2
    ensure
      client_socket&.close
      rackup_file&.unlink
    end

    def test_access_log_file_receives_clf_entries
      log_path = "/tmp/raptor_test_access_#{Process.pid}.log"
      File.delete(log_path) rescue nil

      @options[:access_log_file] = log_path

      with_server do |uri|
        Net::HTTP.get_response(uri)

        Timeout.timeout(5) { sleep 0.05 until File.exist?(log_path) && !File.read(log_path).empty? }
      end

      assert_match(%r(^127\.0\.0\.1 - - \[[^\]]+\] "GET / HTTP/1\.1" 200 \d+$), File.read(log_path))
    ensure
      File.delete(log_path) rescue nil
    end

    def test_sighup_reopens_stdout_file
      log_path = "/tmp/raptor_test_stdout_#{Process.pid}.log"
      rotated_path = "#{log_path}.1"
      File.delete(log_path) rescue nil
      File.delete(rotated_path) rescue nil

      @options[:stdout_file] = log_path

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { cluster.run }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      Timeout.timeout(5) { sleep 0.05 until File.exist?(log_path) && !File.read(log_path).empty? }

      File.rename(log_path, rotated_path)
      refute File.exist?(log_path)

      Process.kill("HUP", cluster_pid)
      Timeout.timeout(5) { sleep 0.05 until File.exist?(log_path) }
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(log_path) rescue nil
      File.delete(rotated_path) rescue nil
    end

    def test_worker_drain_timeout_force_kills_hanging_app_threads
      fixture_content = <<~RUBY
        run proc { |env|
          sleep 30 if env["PATH_INFO"] == "/slow"
          [200, { "content-type" => "text/plain" }, ["ok"]]
        }
      RUBY
      rackup_file = Tempfile.new(["config", ".ru"])
      rackup_file.write(fixture_content)
      rackup_file.close
      @options[:rackup] = rackup_file.path
      @options[:worker_drain_timeout] = 1
      @options[:worker_shutdown_timeout] = 5

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      client_socket = TCPSocket.new("127.0.0.1", server_port)
      client_socket.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      sleep 0.3

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", cluster_pid)
      Process.wait(cluster_pid)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      assert_operator elapsed, :<, 4
    ensure
      client_socket&.close
      rackup_file&.unlink
    end

    def test_reactor_thread_survives_unexpected_error
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)

      cluster_pid = fork do
        NIO::Selector.prepend(Module.new do
          define_method(:select) do |*args, &block|
            Thread.current[:_test_select_count] = (Thread.current[:_test_select_count] || 0) + 1
            raise "injected reactor failure" if Thread.current[:_test_select_count] == 1

            super(*args, &block)
          end
        end)
        without_output { cluster.run }
      end
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      response = raw_split_request(server_port)

      assert_match(/200 OK/, response)
      assert_match(/Hello, World!/, response)
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def test_pipeline_collector_survives_handler_error
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)

      cluster_pid = fork do
        Raptor::Http1.prepend(Module.new do
          define_method(:handle_parsed_request) do |*args|
            Thread.current[:_test_handle_count] = (Thread.current[:_test_handle_count] || 0) + 1
            raise "injected collector failure" if Thread.current[:_test_handle_count] == 1

            super(*args)
          end
        end)
        without_output { cluster.run }
      end
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      raw_split_request(server_port) rescue nil
      response = raw_split_request(server_port)

      assert_match(/200 OK/, response)
      assert_match(/Hello, World!/, response)
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    private

    def with_server(fixture = nil, **template_vars)
      rackup_file = nil

      if fixture
        fixture_path = File.expand_path("../fixtures/#{fixture}", __dir__)
        if template_vars.any?
          content = File.read(fixture_path)
          template_vars.each { |key, value| content.gsub!("{{#{key}}}", value) }
          rackup_file = Tempfile.new(["config", ".ru"])
          rackup_file.write(content)
          rackup_file.close
          @options[:rackup] = rackup_file.path
        else
          @options[:rackup] = fixture_path
        end
      end

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)

      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      uri = URI("http://127.0.0.1:#{server_port}/")
      yield uri
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      rackup_file&.unlink
    end

    def with_unix_server(socket_path, fixture: "hello_world.ru")
      @options.merge!(
        binds: ["unix://#{socket_path}"],
        rackup: File.expand_path("../fixtures/#{fixture}", __dir__)
      )

      cluster = without_output { Cluster.new(@options) }
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      Timeout.timeout(10) do
        loop do
          UNIXSocket.new(socket_path).close
          break
        rescue Errno::ENOENT, Errno::ECONNREFUSED
          sleep 0.1
        end
      end

      yield
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(socket_path) rescue nil
    end

    def wait_for_server(port)
      Timeout.timeout(10) do
        loop do
          http = Net::HTTP.new("127.0.0.1", port)
          http.open_timeout = 1
          http.read_timeout = 1
          http.get("/")
          break
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout
          sleep 0.1
        end
      end
    end

    def raw_request(uri, request)
      socket = TCPSocket.new(uri.host, uri.port)
      socket.write(request)
      socket.read
    ensure
      socket&.close
    end

    def wait_for_booted_worker_pid(stats_path, except: nil, timeout: 20)
      Timeout.timeout(timeout) do
        loop do
          if File.exist?(stats_path)
            data = JSON.parse(File.read(stats_path), symbolize_names: true) rescue nil
            worker = data&.dig(:workers)&.find { |entry| entry[:booted] && entry[:pid] != except }
            return worker[:pid] if worker
          end

          sleep 0.1
        end
      end
    end

    def raw_unix_request(socket_path, request)
      socket = UNIXSocket.new(socket_path)
      socket.write(request)
      socket.read
    ensure
      socket&.close
    end

    def raw_split_request(port)
      socket = TCPSocket.new("127.0.0.1", port)
      socket.write("GET / HT")
      sleep 0.1
      socket.write("TP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      Timeout.timeout(5) { socket.read }
    ensure
      socket&.close
    end
  end
end
