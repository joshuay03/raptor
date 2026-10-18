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
      stop_cluster(cluster_pid)
      reader&.close
      writer&.close
    end

    def test_pid_file_written_and_removed
      pid_path = "/tmp/raptor_test_pid_#{Process.pid}.pid"
      File.delete(pid_path) rescue nil
      @options[:pid_file] = pid_path

      with_server do
        wait_until { File.exist?(pid_path) }

        assert_match(/\A\d+\z/, File.read(pid_path))
      end

      refute_path_exists pid_path
    ensure
      File.delete(pid_path) rescue nil
    end

    def test_stats_file_written_after_startup
      stats_path = "/tmp/raptor_test_stats_#{Process.pid}.json"
      File.delete(stats_path) rescue nil
      @options[:stats_file] = stats_path

      with_server do
        data = wait_until do
          next unless File.exist?(stats_path)

          stats = JSON.parse(File.read(stats_path), symbolize_names: true)
          stats if stats[:workers].first[:booted]
        end

        assert_operator data[:master_pid], :>, 0
        assert_equal 1, data[:workers].length
        assert data[:workers].first[:booted]
      end
    ensure
      File.delete(stats_path) rescue nil
    end

    def test_stats_populated_after_requests
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      uri = URI("http://127.0.0.1:#{server_port}/")
      3.times { Net::HTTP.get_response(uri) }

      stats = wait_until do
        current = cluster.stats
        current if current.first&.dig(:requests).to_i >= 3
      end

      assert_equal 1, stats.length
      assert stats.first[:booted]
      assert_operator stats.first[:requests], :>=, 3
      assert_operator stats.first[:pid], :>, 0
      assert_in_delta Time.now.to_f, stats.first[:last_checkin], 5
    ensure
      stop_cluster(cluster_pid)
    end

    def test_control_server_exposes_cluster_stats
      socket_path = "/tmp/raptor_test_control_#{Process.pid}.sock"
      File.delete(socket_path) rescue nil
      @options[:control_url] = "unix://#{socket_path}"

      with_server do |uri|
        3.times { Net::HTTP.get_response(uri) }

        stats = wait_until do
          response = raw_unix_request(socket_path, "GET /stats HTTP/1.0\r\nHost: localhost\r\n\r\n") rescue nil
          next unless response

          data = JSON.parse(response.split("\r\n\r\n", 2).last, symbolize_names: true)
          data if data.dig(:worker_status, 0, :last_status, :requests_count).to_i >= 3
        end

        assert_equal 1, stats[:workers]
        assert_equal 1, stats[:booted_workers]
        assert_equal 0, stats[:old_workers]
        assert_equal 1, stats[:worker_status].length
        assert_equal @options[:threads], stats.dig(:worker_status, 0, :last_status, :max_threads)
        assert_equal @options[:threads], stats.dig(:worker_status, 0, :last_status, :pool_capacity)
      end

      refute_path_exists socket_path
    ensure
      File.delete(socket_path) rescue nil
    end

    def test_access_log_file_receives_clf_entries
      log_path = "/tmp/raptor_test_access_#{Process.pid}.log"
      File.delete(log_path) rescue nil

      @options[:access_log_file] = log_path

      with_server do |uri|
        Net::HTTP.get_response(uri)

        wait_until { File.exist?(log_path) && !File.read(log_path).empty? }
      end

      assert_match(%r{^127\.0\.0\.1 - - \[[^\]]+\] "GET / HTTP/1\.1" 200 \d+$}, File.read(log_path))
    ensure
      File.delete(log_path) rescue nil
    end

    def test_stdout_file_reopened_on_sighup
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

      wait_until { File.exist?(log_path) && !File.read(log_path).empty? }

      File.rename(log_path, rotated_path)
      refute_path_exists log_path

      Process.kill("HUP", cluster_pid)
      wait_until { File.exist?(log_path) }

      assert_path_exists log_path
    ensure
      stop_cluster(cluster_pid)
      File.delete(log_path) rescue nil
      File.delete(rotated_path) rescue nil
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

      worker_pids = child_pids(cluster_pid)
      skip "could not find worker PIDs" if worker_pids.empty?

      Process.kill("KILL", worker_pids.first) rescue nil

      wait_for_server(server_port)
      assert_equal 200, Net::HTTP.get_response(uri).code.to_i
    ensure
      stop_cluster(cluster_pid)
    end

    def test_phased_restart_on_usr1_replaces_workers
      @options[:workers] = 2
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      original_pids = child_pids(cluster_pid)
      skip "could not find worker PIDs" if original_pids.empty?

      Process.kill("USR1", cluster_pid)

      current_pids = wait_until(timeout: 30) do
        pids = child_pids(cluster_pid)
        pids if pids.length == original_pids.length && (pids & original_pids).empty?
      end

      assert_equal original_pids.length, current_pids.length
      assert_empty current_pids & original_pids
    ensure
      stop_cluster(cluster_pid)
    end

    def test_hot_restart_on_usr2_re_execs_master_and_inherits_listener
      socket_path = "/tmp/raptor_test_hot_restart_#{Process.pid}.sock"
      stats_path = "/tmp/raptor_test_hot_restart_#{Process.pid}.json"
      File.delete(socket_path) rescue nil
      File.delete(stats_path) rescue nil

      raptor_exe = File.expand_path("../../exe/raptor", __dir__)
      lib_path = File.expand_path("../../lib", __dir__)

      cluster_pid = Process.spawn(
        RbConfig.ruby, "-I", lib_path, raptor_exe,
        "-b", "unix://#{socket_path}",
        "-w", "1",
        "--stats-file", stats_path,
        fixture_path("hello_world.ru"),
        out: File::NULL, err: File::NULL
      )

      initial_worker_pid = wait_for_booted_worker_pid(stats_path)

      response = raw_unix_request(socket_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match(%r{\AHTTP/1\.1 200 OK}, response)

      Process.kill("USR2", cluster_pid)

      restarted_worker_pid = wait_for_booted_worker_pid(stats_path, except: initial_worker_pid)

      refute_equal initial_worker_pid, restarted_worker_pid
      assert_equal cluster_pid, JSON.parse(File.read(stats_path), symbolize_names: true)[:master_pid]

      response = raw_unix_request(socket_path, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      assert_match(%r{\AHTTP/1\.1 200 OK}, response)
    ensure
      stop_cluster(cluster_pid)
      File.delete(socket_path) rescue nil
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

      wait_until(timeout: 60) { (descendant_pids(cluster_pid) - original_pids).length >= original_pids.length }

      stop = true
      during_thread.join

      after = 3.times.map { Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) }

      assert before.all? { |response| response.code.to_i == 200 }
      assert during.any? { |response| response&.code&.to_i == 200 }
      assert after.all? { |response| response.code.to_i == 200 }
    ensure
      stop_cluster(cluster_pid)
    end

    def test_refork_closes_idle_keepalive_connections
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      socket_path = "/tmp/raptor_test_refork_#{Process.pid}.sock"
      stats_path = "/tmp/raptor_test_refork_#{Process.pid}.json"
      File.delete(socket_path) rescue nil
      File.delete(stats_path) rescue nil
      @options[:binds] = ["unix://#{socket_path}"]
      @options[:refork_after] = 1
      @options[:stats_file] = stats_path
      cluster = without_output { Cluster.new(@options) }
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      original_pid = wait_for_booted_worker_pid(stats_path)

      client_socket = UNIXSocket.new(socket_path)
      client_socket.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")

      response = +""
      Timeout.timeout(5) do
        response << client_socket.readpartial(1024) until response.include?("Hello, World!")
      end

      wait_for_booted_worker_pid(stats_path, except: original_pid)

      assert_nil Timeout.timeout(5) { client_socket.read(1) }
    ensure
      client_socket&.close
      stop_cluster(cluster_pid)
      File.delete(socket_path) rescue nil
      File.delete(stats_path) rescue nil
    end

    def test_master_replaces_crashed_seed_forked_worker
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      stats_path = "/tmp/raptor_test_refork_crash_#{Process.pid}.json"
      File.delete(stats_path) rescue nil
      @options[:refork_after] = 1
      @options[:stats_file] = stats_path
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      original_pid = wait_for_booted_worker_pid(stats_path)
      Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/"))
      seed_forked_pid = wait_for_booted_worker_pid(stats_path, except: original_pid)

      Process.kill("KILL", seed_forked_pid)

      wait_for_booted_worker_pid(stats_path, except: [original_pid, seed_forked_pid])
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/"))

      assert_equal 200, response.code.to_i
      assert_equal "Hello, World!", response.body
    ensure
      stop_cluster(cluster_pid)
      File.delete(stats_path) rescue nil
    end

    def test_worker_drain_timeout_force_kills_hanging_app_threads
      @options[:rackup] = fixture_path("slow_path.ru")
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
      cluster_pid = nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      assert_operator elapsed, :<, 4
    ensure
      client_socket&.close
      stop_cluster(cluster_pid)
    end

    def test_cluster_shuts_down_promptly_with_active_keepalive_pipeline
      @options[:rackup] = fixture_path("slow_response.ru")

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
          response = +""
          response << client_socket.readpartial(1024) until response.include?("ok")
        rescue
          break
        end
      end

      sleep 0.3

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.kill("TERM", cluster_pid)
      Process.wait(cluster_pid)
      cluster_pid = nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      client_thread.join

      assert_operator elapsed, :<, 2
    ensure
      client_socket&.close
      stop_cluster(cluster_pid)
    end

    def test_before_fork_hooks_run_in_the_master_before_every_fork
      marker_path = "/tmp/raptor_test_before_fork_#{Process.pid}.marker"
      File.delete(marker_path) rescue nil

      @options[:workers] = 2
      @options[:before_fork] = [proc { File.open(marker_path, "a") { |file| file.puts Process.pid } }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      lines = wait_until(timeout: 10) do
        existing = File.exist?(marker_path) ? File.read(marker_path).lines.map(&:strip) : []
        existing if existing.length == 2
      end

      assert_equal [cluster_pid.to_s, cluster_pid.to_s], lines
    ensure
      stop_cluster(cluster_pid)
      File.delete(marker_path) rescue nil
    end

    def test_before_worker_boot_hooks_run_in_each_worker_before_serving
      marker_path = "/tmp/raptor_test_before_worker_boot_#{Process.pid}.marker"
      File.delete(marker_path) rescue nil

      @options[:workers] = 1
      @options[:before_worker_boot] = [proc { |index| File.write(marker_path, "#{index}:#{Process.pid}") }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      wait_until(timeout: 10) { File.exist?(marker_path) && !File.read(marker_path).empty? }
      worker_pid = child_pids(cluster_pid).first

      assert_equal "0:#{worker_pid}", File.read(marker_path)
    ensure
      stop_cluster(cluster_pid)
      File.delete(marker_path) rescue nil
    end

    def test_before_worker_shutdown_hooks_run_in_each_worker_before_graceful_exit
      marker_path = "/tmp/raptor_test_before_worker_shutdown_#{Process.pid}.marker"
      File.delete(marker_path) rescue nil

      @options[:workers] = 1
      @options[:before_worker_shutdown] = [proc { |index| File.write(marker_path, "#{index}:#{Process.pid}") }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      worker_pid = child_pids(cluster_pid).first

      Process.kill("TERM", cluster_pid)
      Process.wait(cluster_pid)
      cluster_pid = nil

      assert_equal "0:#{worker_pid}", File.read(marker_path)
    ensure
      stop_cluster(cluster_pid)
      File.delete(marker_path) rescue nil
    end

    def test_before_refork_hooks_run_in_the_worker_being_promoted_to_seed
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      marker_path = "/tmp/raptor_test_before_refork_#{Process.pid}.marker"
      File.delete(marker_path) rescue nil

      @options[:workers] = 2
      @options[:refork_after] = 3
      @options[:before_refork] = [proc { File.write(marker_path, Process.pid.to_s) }]

      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)
      cluster_pid = fork { without_output { cluster.run } }
      cluster.instance_variable_get(:@binder).close

      wait_for_server(server_port)

      original_pids = descendant_pids(cluster_pid)
      skip "could not find worker PIDs" if original_pids.empty?

      10.times { Net::HTTP.get_response(URI("http://127.0.0.1:#{server_port}/")) }

      wait_until(timeout: 60) { File.exist?(marker_path) && !File.read(marker_path).empty? }

      assert_includes original_pids, File.read(marker_path).to_i
    ensure
      stop_cluster(cluster_pid)
      File.delete(marker_path) rescue nil
    end

    def test_server_thread_survives_reset_connections
      cluster = without_output { Cluster.new(@options) }
      server_port = cluster.instance_variable_get(:@server_port)

      cluster_pid = fork do
        TCPSocket.prepend(Module.new do
          define_method(:remote_address) do
            Thread.current[:_test_remote_address_count] = (Thread.current[:_test_remote_address_count] || 0) + 1
            raise Errno::EINVAL if Thread.current[:_test_remote_address_count] == 1

            super()
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
      stop_cluster(cluster_pid)
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
      stop_cluster(cluster_pid)
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
      stop_cluster(cluster_pid)
    end

    private

    def child_pids(pid)
      `pgrep -P #{pid}`.strip.split.map(&:to_i).reject(&:zero?).sort
    end

    def descendant_pids(pid)
      direct = child_pids(pid)
      (direct + direct.flat_map { |child| descendant_pids(child) }).sort
    end

    def wait_for_booted_worker_pid(stats_path, except: nil, timeout: 20)
      wait_until(timeout: timeout) do
        next unless File.exist?(stats_path)

        data = JSON.parse(File.read(stats_path), symbolize_names: true) rescue nil
        worker = data&.dig(:workers)&.find { |entry| entry[:booted] && !Array(except).include?(entry[:pid]) }
        worker&.fetch(:pid)
      end
    end

    def environment_in_subprocess(rack_env:, rails_env:)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        rack_env ? ENV["RACK_ENV"] = rack_env : ENV.delete("RACK_ENV")
        rails_env ? ENV["RAILS_ENV"] = rails_env : ENV.delete("RAILS_ENV")
        cluster = without_output { Cluster.new(@options) }
        writer.write(cluster.instance_variable_get(:@environment))
        writer.close
        exit!(0)
      end
      writer.close
      value = reader.read
      Process.wait(pid)
      value
    ensure
      reader&.close
      writer&.close
    end
  end
end
