# frozen_string_literal: true

require "json"
require "socket"

require "raptor/plugin"

Raptor::Plugin.create(:fixture_listener) do
  def start(cluster)
    @cluster = cluster
    @settings = cluster.options.fetch(:plugin_test)
    @listener = UNIXServer.new(@settings.fetch(:socket))
    record("start")

    cluster.options[:before_worker_boot] << proc do |index|
      @listener.close
      record("worker_boot", index)
    end
    cluster.options[:before_worker_shutdown] << proc { |index| record("worker_stop", index) }

    in_background do
      record("background_started")
      loop do
        client = @listener.accept
        begin
          client.puts(JSON.generate(pid: Process.pid, stats: cluster.stats_hash))
        ensure
          client.close
        end
      end
    rescue IOError, Errno::EBADF
    ensure
      record("background_stopped")
    end

    raise "plugin startup failed" if @settings[:fail_start]
  end

  def stop
    record("stop", @cluster.stats.length)
    @listener&.close
    File.unlink(@settings.fetch(:socket))
    raise "plugin shutdown failed" if @settings[:fail_stop]
  end

  private

  def record(event, index = nil)
    File.open(@settings.fetch(:events), "a") do |file|
      file.puts(JSON.generate(event: event, pid: Process.pid, index: index))
    end
  end
end
