# rbs_inline: enabled
# frozen_string_literal: true

require "json"

require "atomic-ruby/atomic_thread_pool"
require "rack/builder"
require "ractor-pool"

require_relative "log"
require_relative "binder"
require_relative "reactor"
require_relative "server"
require_relative "reuseport_bpf"
require_relative "http1"
require_relative "http2"
require_relative "stats"
require_relative "systemd"

module Raptor
  # Forks and supervises worker processes. Handles graceful shutdown on
  # `INT` and `TERM`, phased restart on `USR1`, hot restart on `USR2`,
  # and (on Linux) refork on `URG`. Restarts workers that exit
  # unexpectedly or stop checking in.
  #
  class Cluster
    INHERITED_FDS_ENV = "RAPTOR_INHERITED_FDS"

    # Creates and runs a cluster with the given options.
    #
    # @param options [Hash] cluster configuration options
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] options) -> void
    def self.run(options)
      new(options).run
    end

    # @rbs @drain_accept_queue: bool
    # @rbs @worker_count: Integer
    # @rbs @ractor_count: Integer
    # @rbs @thread_count: Integer
    # @rbs @environment: String
    # @rbs @connection_options: Hash[Symbol, untyped]
    # @rbs @http1_options: Hash[Symbol, untyped]
    # @rbs @http2_options: Hash[Symbol, untyped]
    # @rbs @worker_boot_timeout: Integer
    # @rbs @worker_timeout: Integer
    # @rbs @worker_drain_timeout: Integer
    # @rbs @worker_shutdown_timeout: Integer
    # @rbs @before_fork: Array[Proc]
    # @rbs @before_worker_boot: Array[Proc]
    # @rbs @before_worker_shutdown: Array[Proc]
    # @rbs @before_refork: Array[Proc]
    # @rbs @stats_file: String?
    # @rbs @pid_file: String?
    # @rbs @stdout_file: String?
    # @rbs @stderr_file: String?
    # @rbs @access_log_file: String?
    # @rbs @access_log_io: IO?
    # @rbs @launch_command: String?
    # @rbs @launch_argv: Array[String]?
    # @rbs @on_error: ^(Hash[String, untyped]?, Exception) -> void | nil
    # @rbs @binder: Binder
    # @rbs @server_port: Integer
    # @rbs @app: untyped
    # @rbs @shutdown: bool
    # @rbs @workers: Hash[Integer, Integer]
    # @rbs @timed_out: Set[Integer]
    # @rbs @stats: Stats
    # @rbs @phase: Integer
    # @rbs @phased_restart_requested: bool
    # @rbs @phased_restarting: bool
    # @rbs @hot_restart_requested: bool
    # @rbs @refork_thresholds: Array[Integer]
    # @rbs @refork_requested: bool
    # @rbs @refork_threshold_idx: Integer
    # @rbs @seed_pid: Integer?
    # @rbs @seed_ready: bool
    # @rbs @seed_vacated_index: Integer?
    # @rbs @fork_r: IO?
    # @rbs @fork_w: IO?
    # @rbs @resp_r: IO?
    # @rbs @resp_w: IO?
    # @rbs @bpf_active: bool

    # Creates a new Cluster with the given options.
    #
    # @param options [Hash] cluster configuration options
    # @option options [Array<String>] :binds array of bind URIs
    # @option options [Integer] :socket_backlog kernel listen() queue depth for TCP/SSL listeners
    # @option options [Boolean] :drain_accept_queue whether to drain the kernel accept queue on shutdown
    # @option options [Integer] :workers number of worker processes
    # @option options [Integer] :ractors number of ractors per worker process
    # @option options [Integer] :threads number of threads per worker process
    # @option options [#call] :app pre-built Rack application
    # @option options [String] :rackup path to Rack configuration file
    # @option options [String, nil] :chdir directory to change to before loading the Rack application, or nil to leave the working directory unchanged
    # @option options [String, nil] :environment Raptor's application environment label; falls back to `$RAILS_ENV`, then `$RACK_ENV`, then `"development"`
    # @option options [Hash] :connection per-connection settings shared across protocols
    # @option options [Hash] :http1 HTTP/1.1-specific settings
    # @option options [Hash] :http2 HTTP/2-specific settings
    # @option options [Integer] :worker_boot_timeout seconds to wait for a worker to finish booting before killing it
    # @option options [Integer] :worker_timeout seconds to wait for a booted worker to check in before killing it
    # @option options [Integer] :worker_drain_timeout seconds a worker waits for in-flight requests during shutdown before force-killing app threads
    # @option options [Integer] :worker_shutdown_timeout seconds to wait for graceful worker exit before force-killing
    # @option options [Integer, Array<Integer>, nil] :refork_after request-count threshold(s) at which a warm worker is promoted to a fork source for phased refork; nil or 0 disables. Requires `PR_SET_CHILD_SUBREAPER` (Linux)
    # @option options [Array<Proc>] :before_fork procs called in the master before every worker fork
    # @option options [Array<Proc>] :before_worker_boot procs called in each worker before it begins serving
    # @option options [Array<Proc>] :before_worker_shutdown procs called in each worker before its graceful shutdown
    # @option options [Array<Proc>] :before_refork procs called in a worker before it transitions to a seed
    # @option options [String, nil] :stats_file path to write per-worker stats JSON, or nil to disable
    # @option options [String, nil] :pid_file path to write the master PID to, or nil to disable
    # @option options [String, nil] :stdout_file path to redirect stdout to, reopened on SIGHUP, or nil to disable
    # @option options [String, nil] :stderr_file path to redirect stderr to, reopened on SIGHUP, or nil to disable
    # @option options [String, nil] :access_log_file path to write Common Log Format access logs to, reopened on SIGHUP, or nil to disable
    # @option options [String, nil] :launch_command path of the program to re-exec on hot restart, or nil to disable
    # @option options [Array<String>, nil] :launch_argv command-line arguments for the hot-restart exec, or nil to disable
    # @option options [#call, nil] :on_error callback invoked with (env, exception) when the Rack app raises
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] options) -> void
    def initialize(options)
      @drain_accept_queue = options[:drain_accept_queue]
      @worker_count = options[:workers]
      @ractor_count = options[:ractors]
      @thread_count = options[:threads]
      @environment = options[:environment] || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      @connection_options = options[:connection]
      @http1_options = options[:http1]
      @http2_options = options[:http2]
      @worker_boot_timeout = options[:worker_boot_timeout]
      @worker_timeout = options[:worker_timeout]
      @worker_drain_timeout = options[:worker_drain_timeout]
      @worker_shutdown_timeout = options[:worker_shutdown_timeout]
      @before_fork = Array(options[:before_fork])
      @before_worker_boot = Array(options[:before_worker_boot])
      @before_worker_shutdown = Array(options[:before_worker_shutdown])
      @before_refork = Array(options[:before_refork])
      @stats_file = options[:stats_file]
      @pid_file = options[:pid_file]
      @stdout_file = options[:stdout_file]
      @stderr_file = options[:stderr_file]
      @access_log_file = options[:access_log_file]
      @access_log_io = nil
      @launch_command = options[:launch_command]
      @launch_argv = options[:launch_argv]
      @on_error = options[:on_error]

      Dir.chdir(options[:chdir]) if options[:chdir]

      inherited_fds = if raw = ENV.delete(INHERITED_FDS_ENV)
        JSON.parse(raw)
      elsif (systemd_fds = Systemd.listen_fds).any?
        Systemd.clear_listen_env
        pair_systemd_fds(options[:binds], systemd_fds)
      else
        {}
      end
      @binder = Binder.new(options[:binds], socket_backlog: options[:socket_backlog], inherited_fds: inherited_fds)
      @server_port = @binder.server_port
      @app = options[:app] || Rack::Builder.parse_file(options[:rackup])
      log_initialization

      @shutdown = false
      @workers = {}
      @timed_out = Set.new
      @stats = Stats.new(@worker_count)
      @phase = 0
      @phased_restart_requested = false
      @phased_restarting = false
      @hot_restart_requested = false

      @refork_thresholds = normalize_refork_thresholds(options[:refork_after])
      @refork_requested = false
      @refork_threshold_idx = 0
      @seed_pid = nil
      @seed_ready = false
      @seed_vacated_index = nil
    end

    # Runs the cluster until a graceful shutdown is signalled.
    #
    # @return [void]
    #
    # @rbs () -> void
    def run
      $stdout.sync = true
      $stderr.sync = true

      reopen_logs

      trap("INT") { shutdown }
      trap("TERM") { shutdown }
      trap("HUP") { reopen_logs_and_signal_workers }
      trap("USR1") { @phased_restart_requested = true }
      trap("USR2") { @hot_restart_requested = true }

      if @refork_thresholds.any?
        if Subreaper.enable
          @fork_r, @fork_w = IO.pipe
          @resp_r, @resp_w = IO.pipe
          trap("URG") { @refork_requested = true }
        else
          Log.warn "Ignoring refork_after: PR_SET_CHILD_SUBREAPER not supported on this platform"
          @refork_thresholds = [].freeze
        end
      end

      File.open(@pid_file, File::CREAT | File::EXCL | File::WRONLY) { |file| file.write(Process.pid.to_s) } if @pid_file

      @bpf_active = ReuseportBPF.setup(@worker_count)

      @worker_count.times { |index| spawn_worker(index) }

      stats_file_thread = if @stats_file
        Thread.new do
          Thread.current.name = "Stats File Writer"

          write_stats_file_loop
        end
      end

      Systemd.notify("READY=1\nMAINPID=#{Process.pid}")

      until @shutdown
        break if reap_workers == :no_children

        perform_hot_restart if @hot_restart_requested
        poll_seed_ready if @seed_pid && !@seed_ready
        perform_phased_restart if @phased_restart_requested && !@phased_restarting
        check_refork_trigger if @refork_thresholds.any? && !@phased_restarting
        timeout_hung_workers

        sleep 0.1
      end

      Systemd.notify("STOPPING=1")
      stop_workers
      stats_file_thread&.join
      File.delete(@stats_file) rescue nil if @stats_file
      File.delete(@pid_file) rescue nil if @pid_file
      @stats.unmap
      @binder.close
    end

    # Returns stats for all worker processes.
    #
    # @return [Array<Hash>] array of per-worker stat hashes, each containing
    #   :pid, :index, :phase, :requests, :backlog, :busy_threads,
    #   :thread_capacity, :started_at, :last_checkin, and :booted
    #
    # @rbs () -> Array[Hash[Symbol, untyped]]
    def stats
      @stats.all
    end

    private

    # Returns the inherited-FDs hash for a systemd socket-activation handoff,
    # pairing each bind URI with the FD systemd passed at the same index.
    # Returns an empty hash when the FD count doesn't match the bind count.
    #
    # @param bind_uris [Array<String>] the configured bind URIs
    # @param filenos [Array<Integer>] file descriptors passed by systemd
    # @return [Hash{String => Array<Integer>}]
    #
    # @rbs (Array[String] bind_uris, Array[Integer] filenos) -> Hash[String, Array[Integer]]
    def pair_systemd_fds(bind_uris, filenos)
      if bind_uris.length != filenos.length
        Log.warn "Ignoring socket activation: #{filenos.length} fd(s) from systemd, #{bind_uris.length} bind(s) configured"
        return {}
      end

      bind_uris.zip(filenos).to_h { |bind_uri, fileno| [bind_uri, [fileno]] }
    end

    # Normalises the `refork_after` option into a sorted array of positive
    # thresholds. Accepts nil, 0, an Integer, or an Array<Integer>; anything
    # else falls back to an empty array (feature disabled).
    #
    # @param value [Integer, Array<Integer>, nil] the raw option value
    # @return [Array<Integer>]
    #
    # @rbs (untyped value) -> Array[Integer]
    def normalize_refork_thresholds(value)
      case value
      when Integer
        value.positive? ? [value].freeze : [].freeze
      when Array
        value.select { |threshold| threshold.is_a?(Integer) && threshold.positive? }.sort.freeze
      else
        [].freeze
      end
    end

    # Forks a new worker process and registers it at the given index,
    # forking from the seed when one is active and off the master otherwise.
    #
    # @param index [Integer] slot index for this worker in the stats region
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def spawn_worker(index)
      if @seed_pid && pid_alive?(@seed_pid)
        pid = spawn_worker_via_seed(index)
        if pid
          @workers[index] = pid
          return
        end
        Log.warn "Seed (#{@seed_pid}) failed to fork worker #{index}, falling back to direct fork"
        @seed_pid = nil
      end

      @before_fork.each(&:call)
      pid = fork { run_worker(index, @phase) }
      @workers[index] = pid
    end

    # Asks the seed to fork a new worker at the given index, returning the
    # child pid, or nil when the seed doesn't respond in time.
    #
    # @param index [Integer] slot index for the new worker
    # @return [Integer, nil] the forked worker's pid, or nil on failure
    #
    # @rbs (Integer index) -> Integer?
    def spawn_worker_via_seed(index)
      @fork_w.write([index, @phase].pack("LL"))
      return nil unless @resp_r.wait_readable(5)

      bytes = @resp_r.read_nonblock(4, exception: false)
      return nil unless bytes.is_a?(String) && bytes.bytesize == 4

      bytes.unpack1("L")
    rescue Errno::EPIPE, IOError
      nil
    end

    # Checks whether a process with the given pid is currently alive.
    #
    # @param pid [Integer] the pid to probe
    # @return [Boolean] true if the process exists
    #
    # @rbs (Integer pid) -> bool
    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::ECHILD
      false
    rescue Errno::EPERM
      true
    end

    # Reaps any worker processes that have exited, respawning each one
    # unless the cluster is shutting down.
    #
    # @return [Symbol] :no_children when nothing is left to supervise, otherwise :reaped
    #
    # @rbs () -> Symbol
    def reap_workers
      loop do
        pid, status = Process.wait2(-1, Process::WNOHANG)
        break unless pid

        reap_pid(pid, status)
      end

      @workers.empty? && !@seed_pid ? :no_children : :reaped
    rescue Errno::ECHILD
      @workers.empty? && !@seed_pid ? :no_children : :reaped
    end

    # Records a reaped pid, respawning its worker slot unless the cluster
    # is shutting down. Clears the seed reference when the seed exits.
    #
    # @param pid [Integer] the reaped pid
    # @param status [Process::Status] the exit status
    # @return [void]
    #
    # @rbs (Integer pid, Process::Status status) -> void
    def reap_pid(pid, status)
      if pid == @seed_pid
        Log.info "Seed (#{pid}) exited, #{exit_description(status)}"
        @seed_pid = nil
        return
      end

      index = @workers.key(pid)
      return unless index

      @workers.delete(index)
      @timed_out.delete(pid)

      unless @shutdown
        Log.warn "Restarting worker #{index} (#{pid}), #{exit_description(status)}"
        spawn_worker(index)
      end
    end

    # Promotes the most-experienced worker to a seed and starts a phased
    # refork when the next `refork_after` threshold is crossed or a manual
    # refork was requested via `SIGURG`.
    #
    # @return [void]
    #
    # @rbs () -> void
    def check_refork_trigger
      candidate = pick_refork_candidate
      return unless candidate

      candidate_index, candidate_requests = candidate
      threshold = @refork_thresholds[@refork_threshold_idx]

      if @refork_requested
        @refork_requested = false
      elsif !threshold || candidate_requests < threshold
        return
      else
        @refork_threshold_idx += 1
      end

      promote_worker_to_seed(candidate_index)
    end

    # Picks the most-experienced booted worker in the current phase,
    # returning its slot index and its request count. Returns nil when
    # no worker qualifies.
    #
    # @return [Array<Integer>, nil]
    #
    # @rbs () -> Array[Integer]?
    def pick_refork_candidate
      best_index = nil
      best_requests = -1
      @stats.all.each_with_index do |stat, index|
        next unless @workers[index] == stat[:pid]
        next unless stat[:booted]
        next unless stat[:phase] == @phase
        next unless stat[:requests] > best_requests

        best_index = index
        best_requests = stat[:requests]
      end
      [best_index, best_requests] if best_index
    end

    # Retires the current seed and promotes the given worker into its place,
    # queueing a phased refork for the remaining workers.
    #
    # @param index [Integer] slot index of the worker to promote
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def promote_worker_to_seed(index)
      pid = @workers[index]
      return unless pid

      retire_current_seed
      Log.info "Promoting worker #{index} to seed for phased refork"
      ReuseportBPF.mark_unavailable(index) if @bpf_active
      Process.kill("URG", pid) rescue nil
      @workers.delete(index)
      @seed_pid = pid
      @seed_ready = false
      @seed_vacated_index = index
      @phased_restart_requested = true
    end

    # Terminates the currently-active seed process, if any, and waits for
    # it to exit. Its seed-forked workers stay attached to the master and
    # keep serving.
    #
    # @return [void]
    #
    # @rbs () -> void
    def retire_current_seed
      return unless @seed_pid && pid_alive?(@seed_pid)

      Log.info "Retiring seed (#{@seed_pid})"
      Process.kill("TERM", @seed_pid) rescue nil

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @worker_shutdown_timeout
      while @seed_pid && pid_alive?(@seed_pid)
        reap_workers
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    # Records the seed's readiness when its ready marker has arrived.
    # Non-blocking.
    #
    # @return [void]
    #
    # @rbs () -> void
    def poll_seed_ready
      return unless @resp_r && @seed_pid && !@seed_ready
      return unless @resp_r.wait_readable(0)

      bytes = @resp_r.read_nonblock(4, exception: false)
      return unless bytes.is_a?(String) && bytes.bytesize == 4

      @seed_ready = true if bytes.unpack1("L") == 0
    end

    # Stops every worker (and the seed if one is active), escalating
    # from TERM to KILL if any fail to exit within `worker_shutdown_timeout`.
    #
    # @return [void]
    #
    # @rbs () -> void
    def stop_workers
      @workers.values.each { |pid| Process.kill("TERM", pid) rescue nil }
      Process.kill("TERM", @seed_pid) rescue nil if @seed_pid

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @worker_shutdown_timeout
      until (@workers.empty? && !@seed_pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        reap_workers
        sleep 0.05
      end
      return if @workers.empty? && !@seed_pid

      pids = @workers.values + [@seed_pid].compact
      Log.warn "Force-killing #{pids.size} process(es) after #{@worker_shutdown_timeout}s"
      pids.each { |pid| Process.kill("KILL", pid) rescue nil }
      pids.each { |pid| Process.wait(pid) rescue nil }
    end

    # Kills workers that have stopped checking in. A booted worker that
    # fails to update its stats slot within `worker_timeout` seconds is
    # assumed to be hung (deadlocked app, runaway loop, blocked syscall);
    # a worker still in startup is held to `worker_boot_timeout`. Killed
    # workers are then restarted by `reap_workers`.
    #
    # @return [void]
    #
    # @rbs () -> void
    def timeout_hung_workers
      now = Process.clock_gettime(Process::CLOCK_REALTIME)
      stats = @stats.all

      @workers.each do |index, pid|
        next if @timed_out.include?(pid)

        stat = stats[index]
        next unless stat[:pid] == pid

        timeout = stat[:booted] ? @worker_timeout : @worker_boot_timeout
        elapsed = now - stat[:last_checkin]
        next if elapsed <= timeout

        action = stat[:booted] ? "check in" : "boot"
        Log.warn "Killing worker #{index} (#{pid}), failed to #{action} within #{timeout}s"
        Process.kill("KILL", pid) rescue nil
        @timed_out << pid
      end
    end

    # Replaces each worker process one at a time, waiting for the new
    # worker to boot before moving on to the next.
    #
    # @return [void]
    #
    # @rbs () -> void
    def perform_phased_restart
      @phased_restart_requested = false
      @phased_restarting = true
      @phase += 1
      Log.info "Phased restart starting"

      begin
        wait_for_seed_ready
        filled_index = fill_vacated_seed_slot

        @workers.keys.sort.each do |index|
          return if @shutdown
          next if index == filled_index

          target_pid = @workers[index]
          next unless target_pid

          Process.kill("TERM", target_pid) rescue nil

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
          until @shutdown
            reap_workers
            current = @workers[index]
            stat = @stats.all[index]
            break if current && current != target_pid && stat[:pid] == current && stat[:booted]
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.1
          end
        end

        Log.info "Phased restart complete"
      ensure
        @phased_restarting = false
      end
    end

    # Blocks until the freshly-promoted seed has signalled readiness,
    # or times out and clears the seed reference. No-op when no seed is
    # being promoted.
    #
    # @return [void]
    #
    # @rbs () -> void
    def wait_for_seed_ready
      return unless @seed_pid && !@seed_ready

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @worker_drain_timeout + 5
      until @seed_ready || @shutdown
        break unless pid_alive?(@seed_pid)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        poll_seed_ready
        sleep 0.1
      end

      return if @seed_ready

      Log.warn "Seed (#{@seed_pid}) didn't signal ready in time, falling back to direct forks"
      @seed_pid = nil
    end

    # Spawns a replacement worker for the slot the seed vacated when
    # it was promoted, returning the slot index it filled.
    #
    # @return [Integer, nil] the filled slot index, or nil if none was vacated
    #
    # @rbs () -> Integer?
    def fill_vacated_seed_slot
      index = @seed_vacated_index
      return unless index

      @seed_vacated_index = nil
      return if @shutdown

      spawn_worker(index)
      index
    end

    # Re-execs the master process with a fresh boot of the same Raptor
    # invocation, handing the new master its listening sockets so accepted
    # connections continue to be served across the swap.
    #
    # @return [void]
    #
    # @rbs () -> void
    def perform_hot_restart
      @hot_restart_requested = false

      unless @launch_command && @launch_argv
        Log.warn "Hot restart unavailable: launch command not captured"
        return
      end

      Log.info "Hot restart starting"
      monotonic_usec = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000).to_i
      Systemd.notify("RELOADING=1\nMONOTONIC_USEC=#{monotonic_usec}")
      @shutdown = true
      stop_workers
      @binder.clear_close_on_exec
      ENV[INHERITED_FDS_ENV] = JSON.generate(@binder.inheritable_fds)
      File.delete(@stats_file) rescue nil if @stats_file
      File.delete(@pid_file) rescue nil if @pid_file
      @stats.unmap
      $stdout.flush
      $stderr.flush
      exec(@launch_command, *@launch_argv)
    end

    # Runs a worker process's full server stack until a shutdown signal is
    # received or a critical component fails. On `SIGURG` the worker drains
    # and transitions into a seed loop that forks replacement workers on
    # master's request.
    #
    # @param index [Integer] slot index for this worker in the stats region
    # @param phase [Integer] the cluster phase this worker was forked at
    # @return [void]
    #
    # @rbs (Integer index, Integer phase) -> void
    def run_worker(index, phase)
      @fork_w.close if @fork_w && !@fork_w.closed?
      @resp_r.close if @resp_r && !@resp_r.closed?

      shutdown_requested = false
      promote_to_seed = false
      trap("INT") { shutdown_requested = true }
      trap("TERM") { shutdown_requested = true }
      trap("HUP") { reopen_logs }
      trap("USR1", "IGNORE")
      trap("USR2", "IGNORE")
      trap("URG") { promote_to_seed = true } if @fork_r

      Raptor::CPU.pin(index) if Raptor::CPU.count >= @worker_count

      started_at = Process.clock_gettime(Process::CLOCK_REALTIME)
      request_count = 0

      @stats.write(
        index,
        pid: Process.pid,
        phase: phase,
        requests: 0,
        backlog: 0,
        busy_threads: 0,
        thread_capacity: @thread_count,
        started_at:,
        last_checkin: started_at,
        booted: false
      )

      reactor = nil

      counting_app = ->(env) {
        request_count += 1
        @app.call(env)
      }
      thread_pool = AtomicThreadPool.new(size: @thread_count)
      http1 = Http1.new(
        counting_app,
        @server_port,
        connection_options: @connection_options,
        http1_options: @http1_options,
        access_log_io: @access_log_io,
        on_error: @on_error
      )
      http2 = Http2.new(
        counting_app,
        @server_port,
        connection_options: @connection_options,
        http2_options: @http2_options,
        access_log_io: @access_log_io,
        on_error: @on_error
      )
      ractor_pool = RactorPool.new(
        size: @ractor_count,
        worker: http1.parser_worker
      ) do |parsed_result|
        begin
          if parsed_result[:protocol] == :http2
            http2.handle_parsed_request(parsed_result, reactor, thread_pool)
          else
            http1.handle_parsed_request(parsed_result, reactor, thread_pool)
          end
        rescue => error
          Log.rescued_error(error)
        end
      end

      reactor = Reactor.new(
        ractor_pool,
        thread_pool,
        connection_options: @connection_options,
        http1_options: @http1_options
      )
      reactor_thread = reactor.run

      worker_listeners = if @bpf_active
        bpf_listeners = ReuseportBPF.create_worker_listeners(@binder.bind_uris, index, @binder.socket_backlog)
        ReuseportBPF.enable_load_reporting(index)
        non_tcp_listeners = @binder.listeners.reject { |listener| listener.is_a?(TCPServer) }
        bpf_listeners + non_tcp_listeners
      else
        @binder.listeners
      end

      server = Server.new(
        @binder,
        reactor,
        thread_pool,
        http1,
        http2,
        connection_options: @connection_options,
        drain_accept_queue: @drain_accept_queue,
        listeners: worker_listeners,
        worker_index: (index if @bpf_active)
      )
      server_thread = server.run

      @before_worker_boot.each(&:call)

      Log.info "Worker #{index} booted"

      stats_thread = Thread.new do
        Thread.current.name = "Stats Writer"

        loop do
          @stats.write(
            index,
            pid: Process.pid,
            phase: phase,
            requests: request_count,
            backlog: reactor.backlog,
            busy_threads: thread_pool.active_count,
            thread_capacity: @thread_count,
            started_at:,
            last_checkin: Process.clock_gettime(Process::CLOCK_REALTIME),
            booted: true
          )
          break if shutdown_requested || promote_to_seed

          sleep 1
        end
      end

      until shutdown_requested || promote_to_seed
        break unless server_thread.alive? && reactor_thread.alive?

        sleep 0.5
      end

      if promote_to_seed
        @before_refork.each(&:call)
        server.stop_accepting
      else
        @before_worker_shutdown.each(&:call)
        server.shutdown
      end

      server_thread.join
      reactor.shutdown
      reactor_thread.join
      ractor_pool.shutdown
      http1.shutdown
      drain_thread_pool(thread_pool)
      stats_thread.join

      run_seed_loop(index) if promote_to_seed
    end

    # Runs the seed's fork loop, forking a replacement worker for each
    # slot index the master asks for.
    #
    # @param index [Integer] the seed's original slot index
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def run_seed_loop(index)
      Log.info "Worker #{index} promoted to seed"

      seed_shutdown = false
      trap("INT") { seed_shutdown = true }
      trap("TERM") { seed_shutdown = true }
      trap("URG", "IGNORE")

      child_pids = []
      trap("CHLD") do
        child_pids.reject! { Process.wait(_1, Process::WNOHANG) rescue true }
      end

      @resp_w.write([0].pack("L"))

      until seed_shutdown
        next unless @fork_r.wait_readable(1)

        bytes = @fork_r.read_nonblock(8, exception: false)
        break unless bytes.is_a?(String) && bytes.bytesize == 8

        slot_index, child_phase = bytes.unpack("LL")
        pid = fork { run_worker(slot_index, child_phase) }
        child_pids << pid
        @resp_w.write([pid].pack("L")) rescue nil
      end
    rescue Errno::EPIPE, IOError
    end

    # Shuts down the worker's application thread pool, force-killing the
    # underlying threads if in-flight requests have not finished within
    # `worker_drain_timeout` seconds.
    #
    # @param thread_pool [AtomicThreadPool] the worker's thread pool
    # @return [void]
    #
    # @rbs (AtomicThreadPool thread_pool) -> void
    def drain_thread_pool(thread_pool)
      drain = Thread.new { thread_pool.shutdown }
      return if drain.join(@worker_drain_timeout)

      Log.warn "Force-killing in-flight app threads after #{@worker_drain_timeout}s drain timeout"
      thread_pool.instance_variable_get(:@threads).each(&:kill)
      drain.join
    end

    # Returns a human-readable description of how a process exited.
    #
    # @param status [Process::Status] the exit status of the process
    # @return [String] a description of the exit reason
    #
    # @rbs (Process::Status status) -> String
    def exit_description(status)
      if status.exited?
        "exited with code #{status.exitstatus}"
      elsif status.signaled?
        "killed by SIG#{Signal.signame(status.termsig)}"
      else
        "exited"
      end
    end

    # Initiates graceful shutdown of the cluster.
    #
    # @return [void]
    #
    # @rbs () -> void
    def shutdown
      return if @shutdown

      @shutdown = true
    end

    # Prints the cluster's startup banner showing process structure
    # and bind addresses.
    #
    # @return [void]
    #
    # @rbs () -> void
    def log_initialization
      Log.info "Cluster initializing:"
      Log.info "├─ Version: #{VERSION}"
      Log.info "├─ Ruby Version: #{RUBY_DESCRIPTION}"
      Log.info "├─ Environment: #{@environment}"
      Log.info "├─ Master PID: #{Process.pid}"
      Log.info "│  └─ #{@worker_count} worker process#{"es" if @worker_count > 1}"
      Log.info "│     ├─ 1 server thread"
      Log.info "│     ├─ 1 reactor thread"
      Log.info "│     ├─ #{@ractor_count} pipeline ractor#{"s" if @ractor_count > 1}"
      Log.info "│     ├─ 1 pipeline collector thread"
      Log.info "│     ├─ #{@thread_count} worker thread#{"s" if @thread_count > 1}"
      Log.info "│     └─ 1 stats thread"
      Log.info "└─ Listening on #{@binder.addresses.join(", ")}"
    end

    # Redirects `$stdout`, `$stderr`, and the access log to their configured
    # paths. No-op for any stream whose target path is nil.
    #
    # @return [void]
    #
    # @rbs () -> void
    def reopen_logs
      $stdout.reopen(@stdout_file, "a").sync = true if @stdout_file
      $stderr.reopen(@stderr_file, "a").sync = true if @stderr_file
      return unless @access_log_file

      @access_log_io ||= File.open(@access_log_file, "a")
      @access_log_io.reopen(@access_log_file, "a")
      @access_log_io.sync = true
    end

    # Reopens the master's log files and forwards SIGHUP to each worker so
    # they reopen their own inherited file descriptors.
    #
    # @return [void]
    #
    # @rbs () -> void
    def reopen_logs_and_signal_workers
      reopen_logs
      @workers.values.each { |pid| Process.kill("HUP", pid) rescue nil }
    end

    # Writes the stats file on a 1-second interval until shutdown.
    #
    # @return [void]
    #
    # @rbs () -> void
    def write_stats_file_loop
      loop do
        File.write(@stats_file, JSON.generate({ master_pid: Process.pid, workers: @stats.all }))
        break if @shutdown

        sleep 1
      end
    rescue SystemCallError
    end
  end
end
