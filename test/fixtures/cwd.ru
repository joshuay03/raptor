# frozen_string_literal: true

run proc { |_env| [200, { "content-type" => "text/plain" }, [Dir.pwd]] }
