# frozen_string_literal: true

require "json"

require "raptor/plugin"
require "raptor/embedded"

Raptor::Plugin.create(:fixture_rack_listener) do
  def start(cluster)
    @settings = cluster.options.fetch(:plugin_test)
    app = ->(_env) do
      data = JSON.generate(pid: Process.pid, stats: cluster.stats_hash)

      [200, { "content-type" => "application/json" }, [data]]
    end
    @server = Raptor::Embedded.new(
      app,
      binds: ["unix://#{@settings.fetch(:socket)}"],
      threads: 1,
      max_threads: 1,
      http1: { ractors: 1 }
    ).start
    record("start")

    cluster.options[:before_fork] << proc do
      @server.pause
      record("paused")
    end
    cluster.options[:after_fork] << proc do
      @server.resume
      record("resumed")
    end
    cluster.options[:before_worker_boot].unshift(proc do |index|
      @server.shutdown
      record("worker_boot", index)
    end)
    in_background { @server.join }
  end

  def stop
    @server&.shutdown
    record("stop")
  end

  private

  def record(event, index = nil)
    File.open(@settings.fetch(:events), "a") do |file|
      file.puts(JSON.generate(event: event, pid: Process.pid, index: index))
    end
  end
end
