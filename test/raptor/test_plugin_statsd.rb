# frozen_string_literal: true

require "test_helper"

require "raptor/plugin"

module Raptor
  class TestPluginStatsd < TestCase
    parallelize_me!

    ClusterSnapshot = Struct.new(:options, :snapshot) do
      def stats_hash = snapshot
    end

    def setup
      @plugin = Plugin.load(:statsd)
    end

    def teardown
      @plugin.shutdown
      @receiver&.close
      super
    end

    def test_aggregates_capacity_active_threads_and_request_deltas_per_worker
      first = worker(0, 100, 20, capacity: 4, busy: 1, backlog: 3, available: 0)
      second = worker(1, 101, 30, capacity: 6, busy: 2, backlog: 0, available: 4)
      values = metrics(first, second)

      assert_equal 2, values[:workers]
      assert_equal 2, values[:booted_workers]
      assert_equal 10, values[:running]
      assert_equal 10, values[:max_threads]
      assert_equal 3, values[:busy_threads]
      assert_equal 3, values[:backlog]
      assert_equal 4, values[:pool_capacity]
      assert_equal 30.0, values[:percent_busy]
      assert_equal 50, values[:requests_count]
      assert_equal 50, values[:requests]
      assert_equal 0, metrics(first, second)[:requests]

      replacement = worker(0, 200, 3)
      advanced = worker(1, 101, 34)
      values = metrics(replacement, advanced)

      assert_equal 37, values[:requests_count]
      assert_equal 7, values[:requests]
      assert_equal 0, metrics(replacement, advanced)[:requests]
      assert_equal 2, metrics(worker(1, 101, 36))[:requests]
    end

    def test_ignores_regressing_snapshots_without_recounting_requests
      assert_equal 8, metrics(worker(0, 100, 8))[:requests]
      assert_equal 0, metrics(worker(0, 100, 0))[:requests]
      assert_equal 0, metrics(worker(0, 100, 7))[:requests]
      assert_equal 1, metrics(worker(0, 100, 9))[:requests]

      reused_pid = worker(0, 100, 2).merge(started_at: "later")
      assert_equal 2, metrics(reused_pid)[:requests]
      assert_equal 0, metrics(reused_pid)[:requests]
    end

    def test_empty_cluster_has_finite_zero_utilization
      values = metrics

      assert_equal 0.0, values[:percent_busy]
      assert_equal 0, values[:requests]
      assert_equal 0, values[:requests_count]
      assert_equal 0, values[:max_threads]
    end

    def test_pause_finishes_an_inflight_sample_and_resume_preserves_its_baseline
      cluster = cluster_snapshot(interval: 3600)
      cluster.snapshot = stats([worker(0, 100, 7)])
      entered = Queue.new
      release = Queue.new
      first = true
      cluster.define_singleton_method(:stats_hash) do
        if first
          first = false
          entered << true
          release.pop
        end
        snapshot
      end
      @plugin.start(cluster)
      Timeout.timeout(5) { entered.pop }
      pause = Thread.new { cluster.options[:before_fork].each(&:call) }
      wait_until { pause.stop? }

      assert_nil pause.join(0.05)
      release << true
      Timeout.timeout(5) { pause.join }
      assert_includes receive_sample, "raptor.requests:7|c"
      refute @receiver.wait_readable(0.05)

      cluster.snapshot = stats([worker(0, 100, 9)])
      cluster.options[:after_fork].each(&:call)
      assert_includes receive_sample, "raptor.requests:2|c"
      Timeout.timeout(1) { @plugin.stop }
      cluster.options[:after_fork].each(&:call)
      refute @receiver.wait_readable(0.05)
    ensure
      release << true if release
      pause&.join(5)
    end

    def test_fork_callbacks_never_start_an_exporter_in_children_or_seeds
      cluster = cluster_snapshot(interval: 0.01)
      cluster.define_singleton_method(:stats_hash) do
        { workers: Process.pid, booted_workers: 0, old_workers: 0, worker_status: [] }
      end
      @plugin.start(cluster)
      cluster.options[:before_fork].each(&:call)
      ready_r, ready_w = IO.pipe
      finish_r, finish_w = IO.pipe
      child = fork do
        ready_r.close
        finish_w.close
        @receiver.close
        cluster.options[:after_fork].each(&:call)
        cluster.options[:before_worker_boot].each(&:call)
        cluster.options[:before_fork].each(&:call)
        cluster.options[:after_fork].each(&:call)
        ready_w.write(".")
        ready_w.close
        finish_r.read(1)
        exit!
      end
      ready_w.close
      finish_r.close
      Timeout.timeout(5) { assert_equal ".", ready_r.read(1) }
      cluster.options[:after_fork].each(&:call)
      3.times { assert_includes receive_sample, "raptor.workers:#{Process.pid}|g" }
      @plugin.stop
      while @receiver.wait_readable(0)
        assert_includes @receiver.recv(65_535), "raptor.workers:#{Process.pid}|g"
      end
      refute @receiver.wait_readable(0.1)
    ensure
      [ready_r, ready_w, finish_r, finish_w].compact.each { |io| io.close unless io.closed? }
      Process.wait(child) if child
    end

    def test_rejects_invalid_intervals_and_datagram_injection
      [0, -1, Float::INFINITY, Float::NAN].each do |interval|
        assert_raises(ArgumentError) { @plugin.start(cluster_snapshot(interval: interval)) }
      end
      assert_raises(ArgumentError) { @plugin.start(cluster_snapshot(namespace: "raptor\nforged")) }
      assert_raises(ArgumentError) { @plugin.start(cluster_snapshot(tags: ["env:test|c"])) }
      assert_raises(ArgumentError) { @plugin.start(cluster_snapshot(tags: "env:test")) }
    end

    private

    def cluster_snapshot(**settings)
      unless @receiver
        @receiver = UDPSocket.new
        @receiver.bind("127.0.0.1", 0)
      end
      options = {
        statsd: { port: @receiver.addr[1] }.merge(settings),
        before_fork: [], after_fork: [], before_worker_boot: []
      }
      ClusterSnapshot.new(options, stats([]))
    end

    def receive_sample
      assert @receiver.wait_readable(5)
      @receiver.recv(65_535)
    end

    def worker(index, pid, count, capacity: 2, busy: 0, backlog: 0, available: 2)
      {
        index: index, pid: pid, started_at: "boot", booted: true,
        last_status: {
          running: capacity, max_threads: capacity, busy_threads: busy,
          backlog: backlog, pool_capacity: available, requests_count: count
        }
      }
    end

    def stats(workers)
      { workers: workers.length, booted_workers: workers.length, old_workers: 0, worker_status: workers }
    end

    def metrics(*workers)
      if @cluster
        @cluster.options[:before_fork].each(&:call)
        @cluster.snapshot = stats(workers)
        @cluster.options[:after_fork].each(&:call)
      else
        @cluster = cluster_snapshot(interval: 3600)
        @cluster.snapshot = stats(workers)
        @plugin.start(@cluster)
      end

      receive_sample.lines(chomp: true).to_h do |line|
        name, value = line.split(":", 2)
        number = value.split("|").first
        [name.delete_prefix("raptor.").to_sym, number.include?(".") ? Float(number) : Integer(number)]
      end
    end
  end
end
