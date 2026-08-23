# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "raptor"
require "minitest/autorun"

require "net/http"
require "socket"
require "tempfile"
require "timeout"
require "uri"

require "raptor/cli"
require "raptor/cluster"

module Raptor
  class TestCase < Minitest::Test
    OUTPUT_MUTEX = Mutex.new

    private

    def without_output(&block)
      return block.call if ENV["WITH_OUTPUT"]

      OUTPUT_MUTEX.synchronize do
        original_stdout = $stdout
        original_stderr = $stderr
        null_stdout = File.open(File::NULL, "w")
        null_stderr = File.open(File::NULL, "w")
        $stdout = null_stdout
        $stderr = null_stderr
        begin
          block.call
        ensure
          $stdout = original_stdout
          $stderr = original_stderr
          null_stdout.close
          null_stderr.close
        end
      end
    end
  end

  class IntegrationTestCase < TestCase
    def setup
      @options = CLI::DEFAULT_OPTIONS.merge(
        binds: ["tcp://127.0.0.1:0"],
        workers: 1,
        rackup: fixture_path("hello_world.ru")
      )
    end

    private

    def fixture_path(fixture)
      File.expand_path("fixtures/#{fixture}", __dir__)
    end

    def with_server(fixture = nil, **template_vars)
      rackup_file = nil

      if fixture
        path = fixture_path(fixture)
        if template_vars.any?
          content = File.read(path)
          template_vars.each { |key, value| content.gsub!("{{#{key}}}", value) }
          rackup_file = Tempfile.new(["config", ".ru"])
          rackup_file.write(content)
          rackup_file.close
          @options[:rackup] = rackup_file.path
        else
          @options[:rackup] = path
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
