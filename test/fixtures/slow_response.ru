# frozen_string_literal: true

run proc { |_env|
  sleep 0.2
  [200, { "content-type" => "text/plain" }, ["ok"]]
}
