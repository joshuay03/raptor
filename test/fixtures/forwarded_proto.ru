# frozen_string_literal: true

run proc { |env| [200, { "content-type" => "text/plain" }, ["#{env[Rack::RACK_URL_SCHEME]}|#{env[Rack::SERVER_PORT]}"]] }
