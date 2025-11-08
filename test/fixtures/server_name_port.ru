# frozen_string_literal: true

run proc { |env| [200, { "content-type" => "text/plain" }, ["#{env[Rack::SERVER_NAME]}:#{env[Rack::SERVER_PORT]}"]] }
