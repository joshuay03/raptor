# rbs_inline: enabled
# frozen_string_literal: true

require "json"

require "atomic-ruby/atomic_thread_pool"
require "rack/builder"
require "ractor-pool"

require_relative "binder"
require_relative "server"
require_relative "reactor"
require_relative "request"
require_relative "http2"
require_relative "stats"

module Raptor
  # Multi-process web server cluster with advanced concurrency architecture.
  #
  # Cluster manages multiple worker processes, each running a complete server
  # stack including a reactor thread, server thread, ractor pool for HTTP
  # parsing, and thread pool for application processing. It handles process
  # forking, signal management, graceful shutdown, and automatic worker
  # restart when a worker process unexpectedly exits.
  #
  # The architecture provides horizontal scaling through processes while
  # maintaining efficient I/O and CPU utilization within each process through
  # the combination of NIO reactors, ractor-based parsing, and thread pools.
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
  #     threads: 8, ractors: 2, workers: 4,
  #     binds: ["tcp://0.0.0.0:3000"],
  #     rackup: "config.ru",
  #     client: { first_data_timeout: 30, chunk_data_timeout: 10 }
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

    # @rbs @thread_count: Integer
    # @rbs @ractor_count: Integer
    # @rbs @worker_count: Integer
    # @rbs @client_options: Hash[Symbol, Integer]
    # @rbs @on_error: ^(Hash[String, untyped]?, Exception) -> void | nil
    # @rbs @stats_file: String?
    # @rbs @pidfile: String?
    # @rbs @binder: Binder
    # @rbs @server_port: Integer
    # @rbs @app: untyped
    # @rbs @shutdown: bool
    # @rbs @workers: Hash[Integer, Integer]
    # @rbs @stats: Stats
    # @rbs @phased_restart_requested: bool
    # @rbs @phased_restarting: bool

    # Creates a new Cluster with the specified configuration.
    #
    # Initializes the cluster with thread, ractor, and worker counts,
    # sets up network binding, loads the Rack application, and prepares
    # for multi-process operation.
    #
    # @param options [Hash] cluster configuration options
    # @option options [Integer] :threads number of threads per worker process
    # @option options [Integer] :ractors number of ractors per worker process
    # @option options [Integer] :workers number of worker processes
    # @option options [Array<String>] :binds array of bind URIs
    # @option options [#call] :app pre-built Rack application
    # @option options [String] :rackup path to Rack configuration file
    # @option options [Hash] :client client configuration
    # @option options [#call] :on_error callback invoked with (env, exception) when the Rack app raises
    # @option options [String, nil] :stats_file path to write per-worker stats JSON, or nil to disable
    # @option options [String, nil] :pidfile path to write the master PID to, or nil to disable
    # @return [void]
    #
    # @rbs (Hash[Symbol, untyped] options) -> void
    def initialize(options)
      @thread_count = options[:threads]
      @ractor_count = options[:ractors]
      @worker_count = options[:workers]
      @client_options = options[:client]
      @on_error = options[:on_error]
      @stats_file = options[:stats_file]
      @pidfile = options[:pidfile]

      @binder = Binder.new(options[:binds])
      @server_port = @binder.server_port
      @app = options[:app] || Rack::Builder.parse_file(options[:rackup])
      log_initialization

      @shutdown = false
      @workers = {}
      @stats = Stats.new(@worker_count)
      @phased_restart_requested = false
      @phased_restarting = false
    end

    # Starts the multi-process cluster and manages worker processes.
    #
    # Forks the configured number of worker processes and monitors them,
    # automatically restarting any that exit unexpectedly. Handles graceful
    # shutdown via INT or TERM signals, stats logging via USR1, and phased
    # restart via USR2.
    #
    # Each worker process includes:
    # - 1 server thread (continuously accepts connections with backpressure control)
    # - 1 reactor thread (I/O multiplexing, timeout handling, backlog monitoring)
    # - N ractor workers (parallel HTTP parsing)
    # - 1 ractor collector thread (coordinates parsing results)
    # - M worker threads (Rack application processing and response writing)
    # - 1 stats thread (writes per-worker metrics to shared memory every second)
    #
    # @return [void]
    #
    # @rbs () -> void
    def run
      trap("INT") { shutdown }
      trap("TERM") { shutdown }
      trap("USR1") { log_stats }
      trap("USR2") { @phased_restart_requested = true }

      File.open(@pidfile, File::CREAT | File::EXCL | File::WRONLY) { |file| file.write(Process.pid.to_s) } if @pidfile

      @worker_count.times { |index| spawn_worker(index) }

      stats_file_thread = if @stats_file
        Thread.new do
          Thread.current.name = "Raptor Stats File"

          write_stats_file_loop
        end
      end

      until @shutdown
        break if reap_workers == :no_children

        perform_phased_restart if @phased_restart_requested && !@phased_restarting

        sleep 0.1
      end

      @workers.values.each { |pid| Process.kill("TERM", pid) rescue nil }
      @workers.values.each { |pid| Process.wait(pid) rescue nil }
      stats_file_thread&.join
      File.delete(@stats_file) rescue nil if @stats_file
      File.delete(@pidfile) rescue nil if @pidfile
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
    #
    # @param index [Integer] slot index for this worker in the stats region
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def spawn_worker(index)
      pid = fork { run_worker(index) }
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

        unless @shutdown
          warn "[#{Process.pid}] Restarting worker #{index} (#{pid}), #{exit_description(status)}"
          spawn_worker(index)
        end
      end
    rescue Errno::ECHILD
      :no_children
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
      puts "[#{Process.pid}] Phased restart starting"

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

        puts "[#{Process.pid}] Phased restart complete"
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
    # @return [void]
    #
    # @rbs (Integer index) -> void
    def run_worker(index)
      shutdown_requested = false
      trap("INT") { shutdown_requested = true }
      trap("TERM") { shutdown_requested = true }

      started_at = Process.clock_gettime(Process::CLOCK_REALTIME)
      request_count = 0

      @stats.write(
        index,
        pid: Process.pid,
        requests: 0,
        backlog: 0,
        started_at:,
        last_checkin: started_at,
        booted: false
      )

      reactor = nil

      counting_app = ->(env) {
        request_count += 1
        @app.call(env)
      }
      thread_pool = AtomicThreadPool.new(name: "Raptor Workers", size: @thread_count)
      request = Request.new(counting_app, @server_port, client_options: @client_options, on_error: @on_error)
      http2 = Http2.new(counting_app, @server_port, on_error: @on_error)
      ractor_pool = RactorPool.new(
        name: "Raptor Pipeline Workers",
        size: @ractor_count,
        worker: request.http_parser_worker
      ) do |parsed_result|
        begin
          if parsed_result[:protocol] == :http2
            http2.handle_parsed_request(parsed_result, reactor, thread_pool)
          else
            request.handle_parsed_request(parsed_result, reactor, thread_pool)
          end
        rescue => error
          warn "#{Thread.current.name} rescued:"
          warn error.full_message
        end
      end

      reactor = Reactor.new(thread_pool, ractor_pool, client_options: @client_options)
      reactor_thread = reactor.run

      server = Server.new(@binder, reactor, thread_pool, request)
      server_thread = server.run

      puts "[#{Process.pid}] Worker #{index} booted"

      stats_thread = Thread.new do
        Thread.current.name = "Raptor Stats"

        loop do
          @stats.write(
            index,
            pid: Process.pid,
            requests: request_count,
            backlog: reactor.backlog,
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
      request.shutdown
      thread_pool.shutdown
      stats_thread.join
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

    # Logs cluster initialization details including architecture and bind addresses.
    #
    # Outputs a hierarchical view of the cluster configuration showing
    # the master process, worker processes, and per-process thread/ractor
    # allocation along with listening addresses.
    #
    # @return [void]
    #
    # @rbs () -> void
    def log_initialization
      puts "Raptor Cluster initializing:"
      puts "├─ Version: #{VERSION}"
      puts "├─ Ruby Version: #{RUBY_DESCRIPTION}"
      puts "├─ Master PID: #{Process.pid}"
      puts "│  └─ #{@worker_count} worker process#{"es" if @worker_count > 1}"
      puts "│     ├─ 1 server thread"
      puts "│     ├─ 1 reactor thread"
      puts "│     ├─ #{@ractor_count} pipeline ractor#{"s" if @ractor_count > 1}"
      puts "│     ├─ 1 pipeline collector thread"
      puts "│     ├─ #{@thread_count} worker thread#{"s" if @thread_count > 1}"
      puts "│     └─ 1 stats thread"
      puts "└─ Listening on #{@binder.addresses.join(", ")}"
    end

    # Logs current stats for all workers to stdout.
    #
    # Triggered by SIGUSR1 in the master process.
    #
    # @return [void]
    #
    # @rbs () -> void
    def log_stats
      @stats.all.each_with_index do |stat, index|
        status = stat[:booted] ? "booted" : "starting"
        puts "Worker #{index}: pid=#{stat[:pid]}, requests=#{stat[:requests]}, " \
             "backlog=#{stat[:backlog]}, #{status}, " \
             "last_checkin=#{Time.at(stat[:last_checkin]).strftime("%H:%M:%S")}"
      end
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
