# frozen_string_literal: true

require "test_helper"

require "json"

require "nio"

module Raptor
  class TestIntegrationCluster < IntegrationTestCase
    parallelize_me!

    def test_environment_option_sets_internal_environment
      @options[:environment] = "production"

      cluster = without_output { Cluster.new(@options) }

      assert_equal "production", cluster.instance_variable_get(:@environment)
    ensure
      cluster&.instance_variable_get(:@binder)&.close
    end

    def test_environment_falls_back_to_rails_env_then_rack_env_then_development
      assert_equal "development", environment_in_subprocess(rack_env: nil,        rails_env: nil)
      assert_equal "rack_only",   environment_in_subprocess(rack_env: "rack_only", rails_env: nil)
      assert_equal "rails_wins",  environment_in_subprocess(rack_env: "rack_only", rails_env: "rails_wins")
    end

    def test_plaintext_worker_does_not_start_http2_ractors
      reader, writer = IO.pipe
      @options[:http1] = @options[:http1].merge(ractors: 1)
      @options[:http2] = @options[:http2].merge(ractors: 1)
      @options[:before_worker_boot] = [proc { writer.write([Ractor.count].pack("L")) }]

      cluster = without_output { Cluster.new(@options) }
      cluster_pid = fork do
        reader.close
        without_output { cluster.run }
      end
      cluster.instance_variable_get(:@binder).close
      writer.close

      ractor_count = Timeout.timeout(5) { reader.read(4).unpack1("L") }

      assert_equal 2, ractor_count
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      reader&.close
      writer&.close
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

      refute File.exist?(pid_file_path)
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

      cluster_pid = Process.spawn(
        RbConfig.ruby, "-I", lib_path, raptor_exe,
        "-b", "unix://#{sock_path}",
        "-w", "1",
        "--stats-file", stats_path,
        fixture_path("hello_world.ru"),
        out: "/dev/null", err: "/dev/null"
      )

      initial_worker_pid = wait_for_booted_worker_pid(stats_path)

      response = raw_unix_request(sock_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match(%r{\AHTTP/1\.1 200 OK}, response)

      Process.kill("USR2", cluster_pid)

      restarted_worker_pid = wait_for_booted_worker_pid(stats_path, except: initial_worker_pid)

      refute_equal initial_worker_pid, restarted_worker_pid
      assert_equal cluster_pid, JSON.parse(File.read(stats_path), symbolize_names: true)[:master_pid]

      response = raw_unix_request(sock_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match(%r{\AHTTP/1\.1 200 OK}, response)
    ensure
      Process.kill("TERM", cluster_pid) rescue nil
      Process.wait(cluster_pid) rescue nil
      File.delete(sock_path) rescue nil
      File.delete(stats_path) rescue nil
    end

    def test_refork_after_serves_requests_before_during_and_after_promotion
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      @options[:workers] = 2
      @options[:refork_after] = 3
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      original_pids = descendant_pids(cluster_pid)
      skip "could not find worker PIDs" if original_pids.empty?

      before = 3.times.map { Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) }

      stop = false
      during = []
      during_thread = Thread.new do
        until stop
          response = Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) rescue nil
          during << response
          sleep 0.01
        end
      end

      Timeout.timeout(60) do
        loop do
          current = descendant_pids(cluster_pid)
          break if (current - original_pids).length >= original_pids.length

          sleep 0.1
        end
      end

      stop = true
      during_thread.join

      after = 3.times.map { Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) }

      assert before.all? { |response| response.code.to_i == 200 }
      assert during.any? { |response| response&.code&.to_i == 200 }
      assert after.all? { |response| response.code.to_i == 200 }
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
    end

    def test_before_fork_hooks_run_in_the_master_before_every_fork
      marker = "/tmp/raptor_test_before_fork_#{Process.pid}.marker"
      File.delete(marker) rescue nil

      @options[:workers] = 2
      @options[:before_fork] = [proc { File.open(marker, "a") { |file| file.puts Process.pid } }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      lines = Timeout.timeout(10) do
        loop do
          existing = File.exist?(marker) ? File.read(marker).lines.map(&:strip) : []
          break existing if existing.length == 2

          sleep 0.05
        end
      end

      assert_equal [cluster_pid.to_s, cluster_pid.to_s], lines
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(marker) rescue nil
    end

    def test_before_worker_boot_hooks_run_in_each_worker_before_serving
      marker = "/tmp/raptor_test_before_worker_boot_#{Process.pid}.marker"
      File.delete(marker) rescue nil

      @options[:workers] = 1
      @options[:before_worker_boot] = [proc { |index| File.write(marker, "#{index}:#{Process.pid}") }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      Timeout.timeout(10) { sleep 0.05 until File.exist?(marker) && !File.read(marker).empty? }
      worker_pid = `pgrep -P #{cluster_pid}`.strip.split.map(&:to_i).first

      assert_equal "0:#{worker_pid}", File.read(marker)
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(marker) rescue nil
    end

    def test_before_worker_shutdown_hooks_run_in_each_worker_before_graceful_exit
      marker = "/tmp/raptor_test_before_worker_shutdown_#{Process.pid}.marker"
      File.delete(marker) rescue nil

      @options[:workers] = 1
      @options[:before_worker_shutdown] = [proc { |index| File.write(marker, "#{index}:#{Process.pid}") }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      worker_pid = `pgrep -P #{cluster_pid}`.strip.split.map(&:to_i).first

      Process.kill("TERM", cluster_pid)
      Process.wait(cluster_pid)
      cluster_pid = nil

      assert_equal "0:#{worker_pid}", File.read(marker)
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(marker) rescue nil
    end

    def test_before_refork_hooks_run_in_the_worker_being_promoted_to_seed
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      marker = "/tmp/raptor_test_before_refork_#{Process.pid}.marker"
      File.delete(marker) rescue nil

      @options[:workers] = 2
      @options[:refork_after] = 3
      @options[:before_refork] = [proc { File.write(marker, Process.pid.to_s) }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      original_pids = descendant_pids(cluster_pid)
      skip "could not find worker PIDs" if original_pids.empty?

      10.times { Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) }

      Timeout.timeout(60) { sleep 0.05 until File.exist?(marker) && !File.read(marker).empty? }

      assert_includes original_pids, File.read(marker).to_i
    ensure
      if cluster_pid
        Process.kill("TERM", cluster_pid) rescue nil
        Process.wait(cluster_pid) rescue nil
      end
      File.delete(marker) rescue nil
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

      assert_match(%r{^127\.0\.0\.1 - - \[[^\]]+\] "GET / HTTP/1\.1" 200 \d+$}, File.read(log_path))
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
        Http1.prepend(Module.new do
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

    def descendant_pids(pid)
      direct = `pgrep -P #{pid}`.strip.split.map(&:to_i).reject(&:zero?)
      (direct + direct.flat_map { |child| descendant_pids(child) }).sort
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

    def environment_in_subprocess(rack_env:, rails_env:)
      read, write = IO.pipe
      pid = fork do
        read.close
        rack_env ? ENV["RACK_ENV"] = rack_env : ENV.delete("RACK_ENV")
        rails_env ? ENV["RAILS_ENV"] = rails_env : ENV.delete("RAILS_ENV")
        cluster = without_output { Cluster.new(@options) }
        write.write(cluster.instance_variable_get(:@environment))
        write.close
        exit!(0)
      end
      write.close
      value = read.read
      Process.wait(pid)
      value
    end
  end
end
