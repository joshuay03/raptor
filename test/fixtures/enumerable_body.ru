# frozen_string_literal: true

body = Class.new do
  def each
    yield "Chunk "
    yield "by "
    yield "chunk"
  end
end
run proc { |_env| [200, { "content-type" => "text/plain" }, body.new] }
