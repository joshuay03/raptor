# frozen_string_literal: true

run proc { |_env|
  [200, {
    "content-type" => "text/plain",
    "rack.custom" => "should-not-appear",
    "status" => "should-not-appear"
  }, ["ok"]]
}
