# rbs_inline: enabled
# frozen_string_literal: true

require "json"

require "atomic-ruby/atomic_thread_pool"
require "rack/builder"
require "ractor-pool"

require_relative "log"
require_relative "binder"
require_relative "server"
require_relative "reactor"
require_relative "http1"
require_relative "http2"
require_relative "stats"

module Raptor
  # Multi-process web server cluster with advanced concurrency architecture.
  #
  # Cluster manages multiple worker processes, each running a complete server
  # stack including a ractor pool for HTTP parsing, a thread pool for
  # application processing, plus dedicated reactor and server threads. It
  # handles process forking, signal management, graceful shutdown, and
  # automatic worker restart when a worker process unexpectedly exits.
  #
  # The architecture provides horizontal scaling through processes while
  # maintaining efficient I/O and CPU utilization within each process
  # through the combination of ractor-based parsing and thread pools on
  # top of NIO reactors.
  #
  # Flow per worker process:
  # 1. Server continuously accepts connections but skips acceptance when backlog is high
  # 2. Reactor manages I/O multiplexing and provides backlog metrics for load control
  # 3. Ractor pool handles CPU-intensive HTTP parsing in parallel
  # 4. Thread pool processes Rack applications and handles response writing
  # 5. Natural load balancing occurs through backpressure-based acceptance control
  #
  # @example Basic usage
  #   options = {
  #     workers: 4, ractors: 2, threads: 8,
  #     binds: ["tcp://0.0.0.0:3000"],
  #     rackup: "config.ru",
  #     connection: { first_data_timeout: 30, chunk_data_timeout: 10 }
  #   }
  #   Cluster.run(options)
  #
  class Cluster
    # Convenience method to create and run a cluster with the given options.
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
    # @rbs @connection_options: Hash[Symbol, untyped]
    # @rbs @http1_options: Hash[Symbol, untyped]
    # @rbs @http2_options: Hash[Symbol, untyped]
    # @rbs @worker_boot_timeout: Integer
    # @rbs @worker_timeout: Integer
    # @rbs @worker_drain_timeout: Integer
    # @rbs @worker_shutdown_timeout: Integer
    # @rbs @stats_file: String?
    # @rbs @pid_file: String?
    # @rbs @stdout_file: String?
    # @rbs @stderr_file: String?
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

    # Creates a new Cluster with the specified configuration.
    #
    # Initializes the cluster with worker, ractor, and thread counts,
    # sets up network binding, loads the Rack application, and prepares
    # for multi-process operation.
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
    # @option options [Hash] :connection per-connection settings shared across protocols
    # @option options [Hash] :http1 HTTP/1.1-specific settings
    # @option options [Hash] :http2 HTTP/2-specific settings
    # @option options [Integer] :worker_boot_timeout seconds to wait for a worker to finish booting before killing it
    # @option options [Integer] :worker_timeout seconds to wait for a booted worker to check in before killing it
    # @option options [Integer] :worker_drain_timeout seconds a worker waits for in-flight requests during shutdown before force-killing app threads
    # @option options [Integer] :worker_shutdown_timeout seconds to wait for graceful worker exit before force-killing
    # @option options [String, nil] :stats_file path to write per-worker stats JSON, or nil to disable
    # @option options [String, nil] :pid_file path to write the master PID to, or nil to disable
    # @option options [String, nil] :stdout_file path to redirect stdout to, reopened on SIGHUP, or nil to disable
    # @option options [String, nil] :stderr_file path to redirect stderr to, reopened on SIGHUP, or nil to disable
    # @option options [#call] :on_error callback invoked with (env, exception) when the Rack app raises
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] options) -> void
    def initialize(options)
      @drain_accept_queue = options[:drain_accept_queue]
      @worker_count = options[:workers]
      @ractor_count = options[:ractors]
      @thread_count = options[:threads]
      @connection_options = options[:connection]
      @http1_options = options[:http1]
      @http2_options = options[:http2]
      @worker_boot_timeout = options[:worker_boot_timeout]
      @worker_timeout = options[:worker_timeout]
      @worker_drain_timeout = options[:worker_drain_timeout]
      @worker_shutdown_timeout = options[:worker_shutdown_timeout]
      @stats_file = options[:stats_file]
      @pid_file = options[:pid_file]
      @stdout_file = options[:stdout_file]
      @stderr_file = options[:stderr_file]
      @on_error = options[:on_error]

      @binder = Binder.new(options[:binds], socket_backlog: options[:socket_backlog])
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
    end

    # Starts the multi-process cluster and manages worker processes.
    #
    # Forks the configured number of worker processes and monitors them,
    # restarting any that exit unexpectedly or stop checking in. Handles
    # graceful shutdown via INT or TERM signals, stats logging via USR1,
    # and phased restart via USR2.
    #
    # Each worker process includes:
    # - 1 server thread (continuously accepts connections with backpressure control)
    # - 1 reactor thread (I/O multiplexing, timeout handling, backlog monitoring)
    # - N pipeline ractors (parallel HTTP parsing)
    # - 1 pipeline collector thread (coordinates parsing results)
    # - M worker threads (Rack application processing and response writing)
    # - 1 stats thread (writes per-worker metrics to shared memory every second)
    #
    # @return [void]
    #
    # @rbs () -> void
    def run
      reopen_logs

      trap("INT") { shutdown }
      trap("TERM") { shutdown }
      trap("HUP") { reopen_logs_and_signal_workers }
      trap("USR1") { log_stats }
      trap("USR2") { @phased_restart_requested = true }

      File.open(@pid_file, File::CREAT | File::EXCL | File::WRONLY) { |file| file.write(Process.pid.to_s) } if @pid_file

      @worker_count.times { |index| spawn_worker(index) }

      stats_file_thread = if @stats_file
        Thread.new do
          Thread.current.name = "Stats File Writer"

          write_stats_file_loop
        end
      end

      until @shutdown
        break if reap_workers == :no_children

        perform_phased_restart if @phased_restart_requested && !@phased_restarting
        timeout_hung_workers

        sleep 0.1
      end

      stop_workers
      stats_file_thread&.join
      File.delete(@stats_file) rescue nil if @stats_file
      File.delete(@pid_file) rescue nil if @pid_file
      @stats.unmap
    end

    # Returns stats for all worker processes.
    #
    # @return [Array<Hash>] array of per-worker stat hashes, each containing
    #   :pid, :requests, :backlog, :started_at, :last_checkin, and :booted
    #
    # @rbs () -> Array[Hash[Symbol, untyped]]
    def stats
      @stats.all
    end

    private

    # Forks a new worker process and registers it at the given index.
    # The worker inherits the cluster's current phase.
    #
    # @param index [Integer] slot index for this worker in the stats region
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def spawn_worker(index)
      pid = fork { run_worker(index, @phase) }
      @workers[index] = pid
    end

    # Reaps any worker processes that have exited, respawning each one
    # unless the cluster is shutting down.
    #
    # @return [Symbol] :no_children when there are no remaining children, otherwise :reaped
    #
    # @rbs () -> Symbol
    def reap_workers
      loop do
        pid, status = Process.wait2(-1, Process::WNOHANG)
        return :reaped unless pid

        index = @workers.key(pid)
        @workers.delete(index)
        @timed_out.delete(pid)

        unless @shutdown
          Log.warn "Restarting worker #{index} (#{pid}), #{exit_description(status)}"
          spawn_worker(index)
        end
      end
    rescue Errno::ECHILD
      :no_children
    end

    # Stops every worker, escalating from TERM to KILL if any fail to
    # exit within `worker_shutdown_timeout`.
    #
    # @return [void]
    #
    # @rbs () -> void
    def stop_workers
      @workers.values.each { |pid| Process.kill("TERM", pid) rescue nil }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @worker_shutdown_timeout
      until @workers.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        reap_workers
        sleep 0.05
      end
      return if @workers.empty?

      Log.warn "Force-killing #{@workers.size} worker(s) after #{@worker_shutdown_timeout}s"
      @workers.values.each { |pid| Process.kill("KILL", pid) rescue nil }
      @workers.values.each { |pid| Process.wait(pid) rescue nil }
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
    # worker to boot before moving on to the next. Triggered by SIGUSR2.
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
        @workers.keys.sort.each do |index|
          return if @shutdown

          target_pid = @workers[index]
          next unless target_pid

          Process.kill("TERM", target_pid) rescue nil

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
          until @shutdown
            reap_workers
            current = @workers[index]
            break if current && current != target_pid && @stats.all[index][:booted]
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.1
          end
        end

        Log.info "Phased restart complete"
      ensure
        @phased_restarting = false
      end
    end

    # Runs the full server stack inside a worker process.
    #
    # Sets up and coordinates the reactor, server, ractor pool, thread pool,
    # and stats thread, running until a shutdown signal is received or a
    # critical component fails.
    #
    # @param index [Integer] slot index for this worker in the stats region
    # @param phase [Integer] the cluster phase this worker was forked at
    # @return [void]
    #
    # @rbs (Integer index, Integer phase) -> void
    def run_worker(index, phase)
      shutdown_requested = false
      trap("INT") { shutdown_requested = true }
      trap("TERM") { shutdown_requested = true }
      trap("HUP") { reopen_logs }

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
        on_error: @on_error
      )
      http2 = Http2.new(
        counting_app,
        @server_port,
        connection_options: @connection_options,
        http2_options: @http2_options,
        on_error: @on_error
      )
      ractor_pool = RactorPool.new(
        size: @ractor_count,
        worker: http1.http_parser_worker
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

      server = Server.new(@binder, reactor, thread_pool, http1, http2, connection_options: @connection_options, drain_accept_queue: @drain_accept_queue)
      server_thread = server.run

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
          break if shutdown_requested

          sleep 1
        end
      end

      until shutdown_requested
        break unless server_thread.alive? && reactor_thread.alive?

        sleep 0.5
      end

      server.shutdown
      server_thread.join
      reactor.shutdown
      reactor_thread.join
      ractor_pool.shutdown
      http1.shutdown
      drain_thread_pool(thread_pool)
      stats_thread.join
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

    # Logs current stats for all workers to stdout.
    #
    # Triggered by SIGUSR1 in the master process.
    #
    # @return [void]
    #
    # @rbs () -> void
    def log_stats
      @stats.all.each do |stat|
        status = stat[:booted] ? "booted" : "starting"
        Log.info "Worker #{stat[:index]} (phase #{stat[:phase]}): pid=#{stat[:pid]}, requests=#{stat[:requests]}, " \
                 "busy=#{stat[:busy_threads]}/#{stat[:thread_capacity]}, backlog=#{stat[:backlog]}, " \
                 "#{status}, last_checkin=#{Time.at(stat[:last_checkin]).strftime("%H:%M:%S")}"
      end
    end

    # Redirects `$stdout` and `$stderr` to `stdout_file` and `stderr_file`
    # when configured. No-op for either stream when its target is nil.
    #
    # @return [void]
    #
    # @rbs () -> void
    def reopen_logs
      $stdout.reopen(@stdout_file, "a").sync = true if @stdout_file
      $stderr.reopen(@stderr_file, "a").sync = true if @stderr_file
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
