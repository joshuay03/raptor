# frozen_string_literal: true

run proc { |env|
  sleep 30 if env[Rack::PATH_INFO] == "/slow"
  [200, { "content-type" => "text/plain" }, ["ok"]]
}
