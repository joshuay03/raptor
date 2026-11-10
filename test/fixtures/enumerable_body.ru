# frozen_string_literal: true

closed = Queue.new
body = Class.new do
  def each
    yield "Chunk "
    yield "by "
    yield "chunk"
  end

  def call(_stream)
    raise "enumerable bodies must not be called"
  end

  define_method(:close) { closed << true }
end

run proc { |env|
  response_body = case env["PATH_INFO"]
  when "/closed"
    [closed.size.to_s]
  when "/stream"
    proc { |stream| stream.write("Streamed body") }
  else
    body.new
  end

  [200, { "content-type" => "text/plain" }, response_body]
}
