# rbs_inline: enabled
# frozen_string_literal: true

require "atomic-ruby/atomic_thread_pool"
require "ractor-pool"

require_relative "http1"
require_relative "http2"
require_relative "reactor"
require_relative "server"

module Raptor
  # Runs the request-handling stack shared by forked and embedded servers.
  #
  class Worker
    # @rbs @app: untyped
    # @rbs @listeners: Array[TCPServer | UNIXServer | Binder::SslListener | Binder::H2cListener]
    # @rbs @port: Integer
    # @rbs @options: Hash[Symbol, untyped]
    # @rbs @http1_ractors: Integer
    # @rbs @http2_ractors: Integer
    # @rbs @access_log_io: IO?
    # @rbs @worker_index: Integer?
    # @rbs @stopped: bool
    # @rbs @http1: Http1?
    # @rbs @http2: Http2?
    # @rbs @http1_ractor_pool: RactorPool?
    # @rbs @http2_ractor_pool: RactorPool?
    # @rbs @reactor_thread: Thread?
    # @rbs @server: Server?
    # @rbs @server_thread: Thread?

    attr_reader :requests #: Integer
    attr_reader :reactor #: Reactor?
    attr_reader :thread_pool #: AtomicThreadPool?

    # Creates a serving stack using the supplied listeners and configuration.
    #
    # @rbs (untyped app, listeners: Array[TCPServer | UNIXServer | Binder::SslListener | Binder::H2cListener], port: Integer, options: Hash[Symbol, untyped], http1_ractors: Integer, http2_ractors: Integer, ?access_log_io: IO?, ?worker_index: Integer?) -> void
    def initialize(app, listeners:, port:, options:, http1_ractors:, http2_ractors:, access_log_io: nil, worker_index: nil)
      @app = app
      @listeners = listeners
      @port = port
      @options = options
      @http1_ractors = http1_ractors
      @http2_ractors = http2_ractors
      @access_log_io = access_log_io
      @worker_index = worker_index
      @requests = 0
      @stopped = false
    end

    # Starts the application pool, protocol parsers, reactor, and acceptor.
    #
    # @rbs () -> void
    def start
      counting_app = ->(env) {
        @requests += 1
        @app.call(env)
      }
      @thread_pool = AtomicThreadPool.new(size: @options[:threads], max_size: @options[:max_threads])
      @http1 = Http1.new(
        counting_app,
        @port,
        connection_options: @options[:connection],
        http1_options: @options[:http1],
        access_log_io: @access_log_io,
        clean_thread_locals: @options[:clean_thread_locals],
        clean_fiber_locals: @options[:clean_fiber_locals],
        on_error: @options[:on_error],
        error_response: @options[:error_response]
      )
      @http2 = Http2.new(
        counting_app,
        @port,
        connection_options: @options[:connection],
        http2_options: @options[:http2],
        access_log_io: @access_log_io,
        clean_thread_locals: @options[:clean_thread_locals],
        clean_fiber_locals: @options[:clean_fiber_locals],
        on_error: @options[:on_error],
        error_response: @options[:error_response]
      )
      @http1_ractor_pool = RactorPool.new(
        size: @http1_ractors,
        worker: @http1.parser_worker,
        name: "HTTP/1.1"
      ) do |parsed_result|
        begin
          @http1.handle_parsed_request(parsed_result, @reactor, @thread_pool)
        rescue => error
          Log.rescued_error(error)
        end
      end

      if @listeners.any? { |listener| listener.is_a?(Binder::SslListener) || listener.is_a?(Binder::H2cListener) }
        @http2_ractor_pool = RactorPool.new(
          size: @http2_ractors,
          worker: @http2.parser_worker,
          name: "HTTP/2"
        ) do |parsed_result|
          begin
            @http2.handle_parsed_request(parsed_result, @reactor, @thread_pool)
          rescue => error
            Log.rescued_error(error)
          end
        end
      end

      @reactor = Reactor.new(
        @http1,
        @http1_ractor_pool,
        @http2_ractor_pool,
        @thread_pool,
        connection_options: @options[:connection],
        http1_options: @options[:http1],
        http2_options: @options[:http2]
      )
      @reactor_thread = @reactor.run
      @server = Server.new(
        @reactor,
        @thread_pool,
        @http1,
        @http2,
        connection_options: @options[:connection],
        drain_accept_queue: @options[:drain_accept_queue],
        listeners: @listeners,
        worker_index: @worker_index
      )
      @server_thread = @server.run
    rescue
      shutdown
      raise
    end

    # Returns whether both serving threads are still running.
    #
    # @rbs () -> bool
    def running?
      !!(@server_thread&.alive? && @reactor_thread&.alive?)
    end

    # Returns live pool statistics and the number of detached responses.
    # Counts are observations, not a barrier against new requests.
    #
    # @rbs () -> Hash[Symbol, Integer]
    def stats
      queued = @thread_pool.queue_size
      busy = @thread_pool.active_count
      capacity = @thread_pool.size

      {
        backlog: queued,
        busy_threads: busy,
        running: capacity,
        pool_capacity: [capacity - busy - queued, 0].max,
        max_threads: capacity,
        requests_count: @requests,
        detached_responses: @reactor.detached_responses
      }
    end

    # Returns whether no app work is queued or running and no detached response remains.
    # Idle keep-alive connections and sockets owned by hijacking apps do not count.
    #
    # @rbs () -> bool
    def idle?
      status = stats

      status[:backlog].zero? && status[:busy_threads].zero? && status[:detached_responses].zero?
    end

    # Waits until serving stops, propagating background thread failures.
    #
    # @rbs () -> void
    def join
      @server_thread.join(0.1) while running?
      @server_thread.value if @server_thread && !@server_thread.alive?
      @reactor_thread.value if @reactor_thread && !@reactor_thread.alive?
    end

    # Drains requests and releases the serving threads and parser Ractors.
    # A seed keeps its listeners open for the cluster to manage.
    #
    # @rbs (?close_listeners: bool) -> void
    def shutdown(close_listeners: true)
      return if @stopped

      @stopped = true
      begin
        if close_listeners
          @server&.shutdown
        else
          @server&.stop_accepting
        end
        @server_thread&.join
      ensure
        @http1&.shutdown
        if @reactor_thread&.alive?
          @http2&.shutdown(@reactor)
          @reactor.drain_detached_bodies(@options[:worker_drain_timeout])
        end
        drain_thread_pool if @thread_pool
        @reactor&.shutdown
        begin
          @reactor_thread&.join
        ensure
          @http1_ractor_pool&.shutdown
          @http2_ractor_pool&.shutdown
        end
      end
    end

    private

    # Waits for app work to finish within the configured drain timeout.
    #
    # @rbs () -> void
    def drain_thread_pool
      drain_thread = Thread.new do
        Thread.current.name = "Thread Pool Drain"

        @thread_pool.shutdown
      end
      return if drain_thread.join(@options[:worker_drain_timeout])

      Log.warn "Force-killing in-flight app threads after #{@options[:worker_drain_timeout]}s drain timeout"
      @thread_pool.instance_variable_get(:@threads).each(&:kill)
      drain_thread.join
    end
  end
end
