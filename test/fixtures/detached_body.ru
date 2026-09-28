# frozen_string_literal: true

require "raptor"

run proc { |_env|
  body = Raptor::DetachedBody.new
  body.on_open do |stream|
    Thread.new do
      sleep 0.05
      stream.try_write("first")
      stream.try_write(" second")
      stream.close(trailers: {"x-stream-status" => "complete"})
    end
  end
  [200, {"content-type" => "text/plain"}, body]
}
