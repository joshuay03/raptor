# frozen_string_literal: true

run proc { |env|
  status = env[Rack::RACK_IS_HIJACK] ? 200 : 500
  [status, { "content-type" => "text/plain" }, [""]]
}
