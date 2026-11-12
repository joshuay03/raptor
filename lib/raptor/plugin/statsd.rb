# rbs_inline: enabled
# frozen_string_literal: true

require "socket"

require "atomic-ruby/atomic_boolean"

require_relative "../plugin"
require_relative "../log"

Raptor::Plugin.create(:statsd) do
  def start(cluster)
    @cluster = cluster
    @owner_pid = Process.pid
    settings = cluster.options.fetch(:statsd, {})
    @interval = Float(settings.fetch(:interval, 2))
    raise ArgumentError, "StatsD interval must be positive and finite" unless @interval.finite? && @interval.positive?

    namespace = settings.fetch(:namespace, "raptor")
    unless namespace.is_a?(String) && namespace.match?(/\A[a-zA-Z0-9_.-]*\z/)
      raise ArgumentError, "Invalid StatsD namespace"
    end
    @prefix = namespace.empty? ? "" : "#{namespace.delete_suffix(".")}."

    tags = settings.fetch(:tags, [])
    unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && !tag.empty? && !tag.match?(/[,|\r\n]/) }
      raise ArgumentError, "StatsD tags must be an array of strings without commas, pipes or newlines"
    end
    @tags = tags.empty? ? "" : "|##{tags.join(",")}"

    @address = if settings[:socket_path]
      Addrinfo.unix(settings[:socket_path], :DGRAM)
    else
      Addrinfo.udp(settings.fetch(:host, "127.0.0.1"), settings.fetch(:port, 8125))
    end
    @previous_requests = {}
    @running = AtomicBoolean.new(false)
    @stopped = false

    # Finish the sample and close its socket before forking. The owner check
    # prevents inherited callbacks from restarting the exporter in children.
    cluster.options[:before_fork] << proc { stop_exporter }
    cluster.options[:after_fork] << proc { start_exporter }
    cluster.options[:before_worker_boot].unshift(proc { @stopped = true })
    start_exporter
  end

  def stop
    @stopped = true
    stop_exporter
  end

  private

  def start_exporter
    return unless Process.pid == @owner_pid && !@stopped && !@thread

    @wake_r, @wake_w = IO.pipe
    @running.make_true
    @thread = in_background do
      while @running.true?
        begin
          export
        rescue SystemCallError, IOError => error
          Raptor::Log.warn "StatsD export failed with #{error.class} #{error.message}"
        end
        @wake_r.wait_readable(@interval) if @running.true?
      end
    end
  end

  def stop_exporter
    return unless Process.pid == @owner_pid && @thread

    @running.make_false
    @wake_w.write_nonblock(".", exception: false)
    @thread.join
  ensure
    if Process.pid == @owner_pid && @thread
      @threads.delete(@thread)
      @thread = nil
      @wake_r.close
      @wake_w.close
    end
  end

  def export
    values = metrics(@cluster.stats_hash)
    socket = Socket.new(@address.afamily, :DGRAM)
    socket.connect(@address)
    lines = values.map do |name, value|
      type = name == :requests ? "c" : "g"
      "#{@prefix}#{name}:#{value}|#{type}#{@tags}"
    end
    socket.sendmsg_nonblock(lines.join("\n"))
  ensure
    socket&.close
  end

  def metrics(stats)
    values = {
      workers: stats.fetch(:workers),
      booted_workers: stats.fetch(:booted_workers),
      old_workers: stats.fetch(:old_workers),
      running: 0,
      backlog: 0,
      pool_capacity: 0,
      busy_threads: 0,
      max_threads: 0,
      requests_count: 0
    }
    requests = 0
    previous = {}
    stats.fetch(:worker_status).each do |worker|
      status = worker.fetch(:last_status)
      [:running, :backlog, :pool_capacity, :busy_threads, :max_threads, :requests_count].each do |name|
        values[name] += status.fetch(name, 0)
      end

      identity = [worker.fetch(:index), worker.fetch(:pid), worker.fetch(:started_at)]
      count = status.fetch(:requests_count, 0)
      last_count = @previous_requests.fetch(identity, 0)
      requests += [count - last_count, 0].max
      previous[identity] = [count, last_count].max
    end
    @previous_requests = previous

    capacity = values[:max_threads]
    values[:percent_busy] = capacity.zero? ? 0.0 : values[:busy_threads] * 100.0 / capacity
    values[:requests] = requests
    values
  end
end
