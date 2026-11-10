# rbs_inline: enabled
# frozen_string_literal: true

require "atomic-ruby/atom"
require "atomic-ruby/atomic_condition_variable"

require_relative "cli"
require_relative "worker"

module Raptor
  # Serves an existing Rack application in the caller's process without
  # installing signal handlers or changing process-wide configuration.
  #
  class Embedded
    # @rbs @app: untyped
    # @rbs @options: Hash[Symbol, untyped]
    # @rbs @binds: Array[String]
    # @rbs @log: bool
    # @rbs @lifecycle_owner: Atom
    # @rbs @lifecycle_available: AtomicConditionVariable
    # @rbs @started: bool
    # @rbs @stopped: bool
    # @rbs @binder: Binder?
    # @rbs @worker: Worker?

    attr_reader :port #: Integer
    attr_reader :addresses #: Array[String]

    # Creates an in-process server. A port of zero selects an available port.
    # Thread and protocol options follow the regular server configuration.
    # Set log to report startup information.
    #
    # @rbs (untyped app, ?host: String, ?port: Integer, ?log: bool, **untyped options) -> void
    def initialize(app, host: "127.0.0.1", port: 0, log: false, **options)
      @app = app
      @port = port
      @log = log
      @addresses = []
      @options = CLI::DEFAULT_OPTIONS.merge(options)
      CLI::NESTED_OPTION_KEYS.each do |key|
        @options[key] = CLI::DEFAULT_OPTIONS[key].merge(options[key] || {})
      end
      @options[:max_threads] = CLI.parse_max_threads(@options[:max_threads], threads: @options[:threads])
      @binds = options[:binds] || ["tcp://#{host}:#{port}"]
      @lifecycle_owner = Atom.new(nil)
      @lifecycle_available = AtomicConditionVariable.new
      @started = false
      @stopped = false
    end

    # Starts serving and returns once the request-handling stack is ready.
    # Startup errors are raised in the calling thread.
    #
    # @rbs () -> Embedded
    def start
      with_lifecycle do
        raise ThreadError, "server has already been started or stopped" if @started || @stopped

        @started = true
        begin
          @binder = Binder.new(@binds, socket_backlog: @options[:socket_backlog])
          @port = @binder.server_port
          @addresses = @binder.addresses
          start_worker
        rescue
          @stopped = true
          @binder&.close
          raise
        end
        log_initialization if @log
      end

      self
    end

    # Starts serving and waits until shutdown.
    #
    # @rbs () -> void
    def run
      start
      join
    end

    # Drains serving work while retaining the bound listeners for resume.
    # Connections may queue, but requests are not served while paused.
    # Existing keep-alive connections close. Repeated pauses have no effect.
    #
    # Pause before master forks and resume in the parent. Close the inherited
    # instance before other worker boot hooks, and shut down when the plugin stops.
    #
    # @example From a plugin's start callback
    #   @server = Raptor::Embedded.new(app, port: 9293).start
    #   cluster.options[:before_fork] << proc { @server.pause }
    #   cluster.options[:after_fork] << proc { @server.resume }
    #   cluster.options[:before_worker_boot].unshift(proc { @server.shutdown })
    #
    # @rbs () -> Embedded
    def pause
      with_lifecycle do
        raise ThreadError, "server is not running" unless @started && !@stopped

        begin
          @worker&.shutdown(close_listeners: false)
          @worker = nil
        rescue
          @stopped = true
          @binder&.close
          raise
        end
      end

      self
    end

    # Resumes serving on the retained listeners. Has no effect while running.
    # Shutdown remains terminal. Startup failures release the listeners and propagate.
    #
    # @rbs () -> Embedded
    def resume
      with_lifecycle do
        raise ThreadError, "server has not been started or has been stopped" unless @started && !@stopped

        begin
          start_worker unless @worker
        rescue
          @stopped = true
          @binder&.close
          raise
        end
      end

      self
    end

    # Drains requests and closes the server's sockets, threads, and Ractors.
    # Calling shutdown more than once has no effect.
    #
    # @rbs () -> void
    def shutdown
      with_lifecycle do
        return if @stopped

        @stopped = true
        begin
          @worker&.shutdown
        ensure
          @binder&.close
        end
      end
    end

    # Waits across pauses until termination and propagates serving failures.
    #
    # @rbs () -> void
    def join
      started = with_lifecycle { @started }
      raise ThreadError, "server has not been started" unless started

      loop do
        worker, stopped = with_lifecycle { [@worker, @stopped] }
        break if stopped

        if worker
          worker.join
          break if with_lifecycle { @worker.equal?(worker) }
        else
          @lifecycle_available.wait { @worker || @stopped }
        end
      end
    ensure
      shutdown if started
    end

    private

    # @rbs () -> void
    def start_worker
      @worker = Worker.new(
        @app,
        listeners: @binder.listeners,
        port: @port,
        options: @options,
        http1_ractors: @options[:http1][:ractors] || Cluster.default_http1_ractor_count(1),
        http2_ractors: @options[:http2][:ractors] || Cluster.default_http2_ractor_count(1)
      )
      @worker.start
    end

    # @rbs () -> void
    def log_initialization
      environment = @options[:environment] || ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
      thread_count = @options[:threads]
      max_threads = @options[:max_threads]
      thread_limit = if max_threads == Float::INFINITY
        " (scaling, no limit)"
      elsif max_threads > thread_count
        " (scaling up to #{max_threads})"
      else
        ""
      end

      Log.info "Server initializing:"
      Log.info "├─ Version: #{VERSION}"
      Log.info "├─ Ruby Version: #{RUBY_DESCRIPTION}"
      Log.info "├─ Environment: #{environment}"
      Log.info "├─ PID: #{Process.pid}"
      Log.info "├─ #{thread_count} worker thread#{"s" if thread_count > 1}#{thread_limit}"
      Log.info "└─ Listening on #{@addresses.join(", ")}"
    end

    # @rbs () { () -> untyped } -> untyped
    def with_lifecycle
      thread = Thread.current
      @lifecycle_available.wait do
        @lifecycle_owner.swap { |owner| owner || thread }.equal?(thread)
      end
      yield
    ensure
      if @lifecycle_owner.value.equal?(thread)
        @lifecycle_owner.swap { nil }
        @lifecycle_available.broadcast
      end
    end
  end
end
