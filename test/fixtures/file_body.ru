# frozen_string_literal: true

body = Class.new do
  def initialize(path)
    @path = path
  end
  def each
    File.open(@path, "rb") { |f| yield f.read }
  end
  def to_path
    @path
  end
  def close
  end
end
run proc { |_env| [200, { "content-type" => "text/plain" }, body.new("{{file_path}}")] }
