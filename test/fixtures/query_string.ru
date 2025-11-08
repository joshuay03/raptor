# frozen_string_literal: true

run proc { |env| [200, { "content-type" => "text/plain" }, [env[Rack::QUERY_STRING]]] }
