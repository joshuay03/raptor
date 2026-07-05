# frozen_string_literal: true

require "json"

RESPONSE = JSON.generate(status: "ok")

run proc { |_env|
  sleep rand(5..50) / 1000.0
  [200, { "content-type" => "application/json" }, [RESPONSE]]
}
