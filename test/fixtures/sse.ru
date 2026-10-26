# frozen_string_literal: true

IO_APP = Rack::Builder.parse_file(File.expand_path("io_bound.ru", __dir__))
SSE_HEADERS = { "content-type" => "text/event-stream", "cache-control" => "no-cache" }.freeze
OPENED = ": open\n\n"
EVENT = "data: tick\n\n"

open_stream = if ENV["RAPTOR_SSE_BODY"] != "enumerator" && defined?(Raptor::DetachedBody)
  # Detached bodies release the application thread, so one thread per worker
  # writes an event to every open stream each second.
  new_streams = Queue.new
  ticker = nil

  lambda do
    unless ticker&.alive?
      ticker = Thread.new do
        streams = []
        loop do
          sleep 1
          streams << new_streams.pop until new_streams.empty?
          streams.reject! { |stream| stream.try_write(EVENT) == :closed }
        end
      end
    end

    Raptor::DetachedBody.new.on_open do |stream|
      stream.try_write(OPENED)
      new_streams << stream
    end
  end
else
  lambda do
    Enumerator.new do |events|
      events << OPENED
      loop do
        sleep 1
        events << EVENT
      end
    end
  end
end

run proc { |env|
  env["PATH_INFO"] == "/stream" ? [200, SSE_HEADERS.dup, open_stream.call] : IO_APP.call(env)
}
