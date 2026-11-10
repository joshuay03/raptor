# frozen_string_literal: true

run proc { |env|
  protocol = env["SERVER_PROTOCOL"]
  version = env.fetch("HTTP_VERSION", "absent")

  [200, { "content-type" => "text/plain" }, ["#{protocol}|#{version}"]]
}
