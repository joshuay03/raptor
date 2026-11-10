# frozen_string_literal: true

require "test_helper"

require "json"
require "tmpdir"

module Raptor
  class TestIntegrationPlugins < IntegrationTestCase
    parallelize_me!

    def setup
      super
      @directory = Dir.mktmpdir("raptor-plugin-", "/tmp")
      @socket_path = File.join(@directory, "plugin.sock")
      @events_path = File.join(@directory, "events.jsonl")
      @release_path = File.join(@directory, "release")
      @app_path = File.join(@directory, "app.sock")
      @log_path = File.join(@directory, "raptor.log")
    end

    def teardown
      File.write(@release_path, "")
      stop_cluster(@cluster_pid)
      FileUtils.remove_entry(@directory)
      super
    end

    def test_plugin_serves_stats_before_workers_boot_and_preserves_configured_hooks
      start_cluster(before_worker_boot: <<~RUBY)
        [proc do
          File.write(#{File.join(@directory, "booting").inspect}, "")
          sleep 0.01 until File.exist?(#{@release_path.inspect})
        end]
      RUBY
      wait_until { File.exist?(File.join(@directory, "booting")) }

      assert_equal @cluster_pid, plugin_stats[:pid]
      assert_equal 0, plugin_stats.dig(:stats, :booted_workers)

      File.write(@release_path, "")
      wait_for_ready

      assert_app_response
      worker = events.find { |event| event[:event] == "worker_boot" }
      refute_equal @cluster_pid, worker[:pid]
      assert_equal 0, worker[:index]
    end

    def test_master_stats_remain_available_under_load_and_across_worker_replacement
      start_cluster
      wait_for_ready

      blocked = Thread.new do
        raw_unix_request(@app_path, "GET /hold HTTP/1.0\r\n\r\n")
      end
      busy = wait_until do
        stats = plugin_stats
        stats if stats.dig(:stats, :worker_status, 0, :last_status, :busy_threads) == 1
      end

      assert_equal @cluster_pid, busy[:pid]
      assert_equal 1, busy.dig(:stats, :booted_workers)
      File.write(@release_path, "")
      assert_match(/200 OK/, Timeout.timeout(5) { blocked.value })

      original_pid = plugin_stats.dig(:stats, :worker_status, 0, :pid)
      Process.kill("KILL", original_pid)
      replacement = wait_for_ready(except: original_pid)
      refute_equal original_pid, replacement.dig(:stats, :worker_status, 0, :pid)

      Process.kill("USR1", @cluster_pid)
      wait_for_ready(except: replacement.dig(:stats, :worker_status, 0, :pid))
      assert_app_response
      assert_equal 1, events.count { |event| event[:event] == "start" }

      stop_cluster(@cluster_pid)
      @cluster_pid = nil
      assert_equal 1, events.count { |event| event[:event] == "stop" }
      assert_equal 1, events.count { |event| event[:event] == "background_stopped" }
      refute_path_exists @socket_path
    ensure
      File.write(@release_path, "")
      blocked&.join(5)
    end

    def test_hot_restart_stops_the_old_plugin_and_rebinds_in_the_same_master
      start_cluster
      initial = wait_for_ready
      assert_app_response

      Process.kill("USR2", @cluster_pid)
      restarted = wait_for_ready(except: initial.dig(:stats, :worker_status, 0, :pid))
      lifecycle = events.filter_map do |event|
        event[:event] if %w[start stop].include?(event[:event])
      end

      assert_equal @cluster_pid, restarted[:pid]
      assert_app_response
      assert_equal %w[start stop start], lifecycle

      stop_cluster(@cluster_pid)
      @cluster_pid = nil
      assert_equal 2, events.count { |event| event[:event] == "stop" }
      refute_path_exists @socket_path
    end

    def test_failed_startup_cleans_up_even_when_plugin_stop_raises
      control_path = File.join(@directory, "control.sock")
      listener = UNIXServer.new(control_path)
      start_cluster(settings: { fail_start: true, fail_stop: true }, control_url: "unix://#{control_path}")
      status = Timeout.timeout(10) { Process.waitpid2(@cluster_pid).last }
      @cluster_pid = nil

      refute status.success?
      assert_includes File.read(@log_path), "plugin startup failed"
      assert_includes File.read(@log_path), "plugin shutdown failed"
      assert_equal 1, events.count { |event| event[:event] == "stop" }
      refute_path_exists @socket_path
      refute_path_exists File.join(@directory, "raptor.pid")
      socket = UNIXSocket.new(control_path)

      assert_kind_of UNIXSocket, socket
    ensure
      socket&.close
      listener&.close
    end

    def test_embedded_listener_serves_the_master_across_forks_and_saturated_workers
      start_cluster(plugin: :fixture_rack_listener, workers: 2, before_worker_boot: <<~RUBY)
        [proc do
          File.write(#{File.join(@directory, "booting").inspect}, "")
          sleep 0.01 until File.exist?(#{@release_path.inspect})
        end]
      RUBY
      wait_until { File.exist?(File.join(@directory, "booting")) }
      initial = wait_until { plugin_stats rescue nil }
      assert_equal @cluster_pid, initial[:pid]
      assert_equal 0, initial.dig(:stats, :booted_workers)
      File.write(@release_path, "")
      ready = wait_for_ready
      original_pids = ready.dig(:stats, :worker_status).map { |worker| worker[:pid] }

      assert_equal 2, events.count { |event| event[:event] == "paused" }
      assert_equal 2, events.count { |event| event[:event] == "resumed" }
      assert_app_response

      File.unlink(@release_path)
      requests = Array.new(8) do
        Thread.new { raw_unix_request(@app_path, "GET /hold HTTP/1.0\r\n\r\n") }
      end
      busy = wait_until do
        data = plugin_stats
        data if data.dig(:stats, :worker_status).all? { |worker| worker.dig(:last_status, :busy_threads) == 1 }
      end
      assert_equal @cluster_pid, busy[:pid]
      File.write(@release_path, "")
      requests.each { |request| assert_match(/200 OK/, Timeout.timeout(5) { request.value }) }

      Process.kill("KILL", original_pids.first)
      replacement = wait_for_ready(except: original_pids.first)
      assert_equal @cluster_pid, replacement[:pid]
      Process.kill("USR1", @cluster_pid)
      wait_until do
        data = plugin_stats
        pids = data.dig(:stats, :worker_status).map { |worker| worker[:pid] }
        data if data.dig(:stats, :booted_workers) == 2 && (pids & original_pids).empty?
      rescue Errno::ECONNRESET, EOFError
        false
      end
      assert_app_response

      stop_cluster(@cluster_pid)
      @cluster_pid = nil
      lifecycle = events.select { |event| ["paused", "resumed"].include?(event[:event]) }
      assert_equal ["paused", "resumed"] * 5, lifecycle.map { |event| event[:event] }
      assert_equal 1, lifecycle.map { |event| event[:pid] }.uniq.length
      assert_equal 1, events.count { |event| event[:event] == "start" }
      assert_equal 1, events.count { |event| event[:event] == "stop" }
      refute_path_exists @socket_path
      UNIXServer.open(@socket_path) { |listener| assert_kind_of UNIXServer, listener }
    ensure
      File.write(@release_path, "")
      requests&.each { |request| request.join(5) }
    end

    def test_embedded_listener_remains_available_during_seed_reforks
      skip "PR_SET_CHILD_SUBREAPER not available on this platform" unless Subreaper.enable

      start_cluster(plugin: :fixture_rack_listener, refork_after: 10_000)
      initial = wait_for_ready
      original_pid = initial.dig(:stats, :worker_status, 0, :pid)
      Process.kill("URG", @cluster_pid)
      replacement = wait_for_ready(except: original_pid)

      assert_equal @cluster_pid, replacement[:pid]
      Process.kill("KILL", replacement.dig(:stats, :worker_status, 0, :pid))
      wait_for_ready(except: replacement.dig(:stats, :worker_status, 0, :pid))
      assert_app_response
      assert_equal 1, events.count { |event| event[:event] == "paused" }
      assert_equal 1, events.count { |event| event[:event] == "resumed" }

      stop_cluster(@cluster_pid)
      @cluster_pid = nil
      refute_path_exists @socket_path
    end

    private

    def start_cluster(before_worker_boot: "[]", settings: {}, control_url: nil,
      plugin: :fixture_listener, workers: 1, refork_after: nil)
      @plugin = plugin
      @worker_count = workers
      config_path = File.join(@directory, "raptor.rb")
      plugin_settings = { socket: @socket_path, events: @events_path }.merge(settings)
      File.write(config_path, <<~RUBY)
        $LOAD_PATH.unshift(#{fixture_path("plugins").inspect})
        {
          binds: [#{"unix://#{@app_path}".inspect}],
          workers: #{workers},
          threads: 1,
          max_threads: 1,
          http1: { ractors: 1 },
          refork_after: #{refork_after.inspect},
          stats_file: nil,
          control_url: #{control_url.inspect},
          pid_file: #{File.join(@directory, "raptor.pid").inspect},
          plugins: [#{plugin.inspect}],
          plugin_test: #{plugin_settings.inspect},
          before_worker_boot: #{before_worker_boot.chomp},
          app: ->(env) do
            sleep 0.01 until File.exist?(#{@release_path.inspect}) if env["PATH_INFO"] == "/hold"
            [200, { "content-type" => "text/plain" }, ["OK"]]
          end
        }
      RUBY
      @cluster_pid = Process.spawn(
        RbConfig.ruby,
        "-I", File.expand_path("../../lib", __dir__),
        File.expand_path("../../exe/raptor", __dir__), "-c", config_path,
        out: @log_path, err: [:child, :out]
      )
    end

    def plugin_stats
      Timeout.timeout(3) do
        if @plugin == :fixture_rack_listener
          response = raw_unix_request(@socket_path, "GET / HTTP/1.0\r\n\r\n")
          raise EOFError if response.empty?

          JSON.parse(response.split("\r\n\r\n", 2).last, symbolize_names: true)
        else
          UNIXSocket.open(@socket_path) { |socket| JSON.parse(socket.readline, symbolize_names: true) }
        end
      end
    end

    def wait_for_ready(except: nil)
      wait_until(timeout: 15) do
        data = plugin_stats
        worker = data.dig(:stats, :worker_status, 0)
        data if worker && worker[:booted] && worker[:pid] != except && data.dig(:stats, :booted_workers) == @worker_count
      rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
        false
      end
    end

    def events
      File.readlines(@events_path).map { |line| JSON.parse(line, symbolize_names: true) }
    end

    def assert_app_response
      response = raw_unix_request(@app_path, "GET / HTTP/1.0\r\n\r\n")

      assert_match(/200 OK/, response)
      assert_equal "OK", response.split("\r\n\r\n", 2).last
    end
  end
end
