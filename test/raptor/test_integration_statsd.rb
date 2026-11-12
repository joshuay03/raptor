# frozen_string_literal: true

require "test_helper"

require "json"
require "tmpdir"

module Raptor
  class TestIntegrationStatsd < IntegrationTestCase
    parallelize_me!

    def setup
      super
      @directory = Dir.mktmpdir("raptor-statsd-", "/tmp")
      @app_path = File.join(@directory, "app.sock")
      @control_path = File.join(@directory, "control.sock")
      @log_path = File.join(@directory, "raptor.log")
      @samples = Queue.new
      @received = []
    end

    def teardown
      stop_cluster(@cluster_pid)
      @collector&.kill&.join
      @receiver&.close
      FileUtils.remove_entry(@directory)
      super
    end

    def test_udp_counts_requests_once_across_replacement_and_phased_restart
      listen_udp
      start_cluster(port: @receiver.addr[1], interval: 0.05)
      original = ready_worker
      sample_until { |sample| sample.fetch("raptor.booted_workers") == "1|g" }

      4.times { assert_request_pid original[:pid] }
      sample_until { |sample| sample.fetch("raptor.requests_count") == "4|g" }
      assert_equal 4, request_total

      Process.kill("KILL", original[:pid])
      replacement = ready_worker(except: original[:pid])
      2.times { assert_request_pid replacement[:pid] }
      sample_until { |sample| sample.fetch("raptor.requests_count") == "2|g" }
      assert_equal 6, request_total

      Process.kill("USR1", @cluster_pid)
      restarted = ready_worker(except: replacement[:pid])
      3.times { assert_request_pid restarted[:pid] }
      sample_until { |sample| sample.fetch("raptor.requests_count") == "3|g" }
      assert_equal 9, request_total
      3.times { next_sample }
      assert_equal 9, request_total
      assert @received.all? { |sample| sample.fetch("raptor.requests").split("|").first.to_i >= 0 }

      stop_and_assert_quiet
      refute_match(/StatsD export failed|closed stream|Bad file descriptor/, File.read(@log_path))
    end

    def test_seed_forked_replacements_keep_a_single_master_exporter
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      listen_udp
      start_cluster({ port: @receiver.addr[1], interval: 0.05 }, refork_after: 10_000)
      original = ready_worker
      assert_request_pid original[:pid]
      sample_until { |sample| sample.fetch("raptor.requests_count") == "1|g" }
      assert_equal 1, request_total

      Process.kill("URG", @cluster_pid)
      replacement = ready_worker(except: original[:pid])
      2.times { assert_request_pid replacement[:pid] }
      sample_until { |sample| sample.fetch("raptor.requests_count") == "2|g" }
      assert_equal 3, request_total

      Process.kill("KILL", replacement[:pid])
      restarted = ready_worker(except: replacement[:pid])
      3.times { assert_request_pid restarted[:pid] }
      sample_until { |sample| sample.fetch("raptor.requests_count") == "3|g" }
      assert_equal 6, request_total
      3.times { next_sample }
      assert_equal 6, request_total

      stop_and_assert_quiet
      refute_match(/StatsD export failed|Inherited exporter|Inherited datagram/, File.read(@log_path))
    end

    def test_unix_datagrams_support_namespace_tags_and_hot_restart
      socket_path = File.join(@directory, "metrics.sock")
      @receiver = Socket.new(:UNIX, :DGRAM)
      @receiver.bind(Socket.sockaddr_un(socket_path))
      collect_samples
      start_cluster(socket_path: socket_path, interval: 0.05, namespace: "service.raptor.", tags: ["env:test", "native"])
      worker = ready_worker
      assert_request_pid worker[:pid]
      sample = sample_until { |data| data.fetch("service.raptor.requests_count") == "1|g|#env:test,native" }

      assert_equal "1|g|#env:test,native", sample.fetch("service.raptor.workers")
      assert_equal "2|g|#env:test,native", sample.fetch("service.raptor.max_threads")
      assert_equal "0.0|g|#env:test,native", sample.fetch("service.raptor.percent_busy")
      assert_equal 1, request_total("service.raptor")

      Process.kill("USR2", @cluster_pid)
      restarted = ready_worker(except: worker[:pid])
      2.times { assert_request_pid restarted[:pid] }
      sample_until { |data| data.fetch("service.raptor.requests_count") == "2|g|#env:test,native" }
      assert_equal 3, request_total("service.raptor")

      stop_and_assert_quiet
      assert_path_exists socket_path
      refute_match(/StatsD export failed|closed stream|Bad file descriptor/, File.read(@log_path))
    end

    def test_statsd_is_opt_in
      listen_udp
      start_cluster({ port: @receiver.addr[1], interval: 0.01 }, plugins: [])
      worker = ready_worker
      assert_request_pid worker[:pid]

      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { @samples.pop } }
    end

    def test_exporter_recovers_when_unix_receiver_appears_later
      socket_path = File.join(@directory, "late.sock")
      start_cluster(socket_path: socket_path, interval: 0.05)
      worker = ready_worker
      wait_until { File.read(@log_path).include?("StatsD export failed") }
      @receiver = Socket.new(:UNIX, :DGRAM)
      @receiver.bind(Socket.sockaddr_un(socket_path))
      collect_samples
      assert_request_pid worker[:pid]
      sample_until { |sample| sample.fetch("raptor.requests_count") == "1|g" }

      assert_equal 1, request_total
      stop_and_assert_quiet
    end

    private

    def listen_udp
      @receiver = UDPSocket.new
      @receiver.bind("127.0.0.1", 0)
      collect_samples
    end

    def collect_samples
      @collector = Thread.new do
        loop do
          packet = @receiver.recv(65_535)
          @samples << packet.lines(chomp: true).to_h { |line| line.split(":", 2) }
        end
      end
    end

    def next_sample
      sample = Timeout.timeout(15) { @samples.pop }
      assert_equal 11, sample.length
      @received << sample
      sample
    end

    def sample_until
      Timeout.timeout(15) do
        loop do
          sample = next_sample
          return sample if yield sample
        end
      end
    end

    def request_total(namespace = "raptor")
      @received.sum { |sample| Integer(sample.fetch("#{namespace}.requests").split("|").first) }
    end

    def start_cluster(settings = nil, plugins: [:statsd], refork_after: nil, **keywords)
      settings = (settings || {}).merge(keywords)
      config_path = File.join(@directory, "raptor.rb")
      File.write(config_path, <<~RUBY)
        {
          binds: [#{"unix://#{@app_path}".inspect}],
          workers: 1,
          threads: 2,
          max_threads: 2,
          http1: { ractors: 1 },
          refork_after: #{refork_after.inspect},
          stats_file: nil,
          control_url: #{"unix://#{@control_path}".inspect},
          plugins: #{plugins.inspect},
          statsd: #{settings.inspect},
          before_worker_boot: [proc do
            raise "Inherited exporter thread" if Thread.list.any? { |thread| thread.name&.start_with?("Plugin ") }
            sockets = ObjectSpace.each_object(Socket).reject(&:closed?)
            raise "Inherited datagram socket" if sockets.any? { |socket| socket.local_address.socktype == Socket::SOCK_DGRAM }
          end],
          app: ->(env) { [200, { "content-type" => "text/plain" }, [Process.pid.to_s]] }
        }
      RUBY
      @cluster_pid = Process.spawn(
        RbConfig.ruby,
        "-I", File.expand_path("../../lib", __dir__),
        File.expand_path("../../exe/raptor", __dir__), "-c", config_path,
        out: @log_path, err: [:child, :out]
      )
    end

    def ready_worker(except: nil)
      wait_until(timeout: 15) do
        response = raw_unix_request(@control_path, "GET /stats HTTP/1.0\r\n\r\n")
        stats = JSON.parse(response.split("\r\n\r\n", 2).last, symbolize_names: true)
        worker = stats.fetch(:worker_status).first
        worker if worker && worker[:booted] && worker[:pid] != except
      rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
        false
      end
    end

    def assert_request_pid(pid)
      response = raw_unix_request(@app_path, "GET / HTTP/1.0\r\n\r\n")
      assert_match(/200 OK/, response)
      assert_equal pid.to_s, response.split("\r\n\r\n", 2).last
    end

    def stop_and_assert_quiet
      Process.kill("TERM", @cluster_pid)
      _, status = Timeout.timeout(10) { Process.waitpid2(@cluster_pid) }
      @cluster_pid = nil
      assert_predicate status, :success?
      @collector.kill.join
      loop do
        break if @receiver.recv_nonblock(65_535, exception: false) == :wait_readable
      end

      refute @receiver.wait_readable(0.2)
    end
  end
end
