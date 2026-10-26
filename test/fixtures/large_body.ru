# frozen_string_literal: true

RESPONSE = ("x" * 64 * 1024).freeze

run proc { |_env|
  [200, { "content-type" => "application/octet-stream" }, [RESPONSE]]
}
