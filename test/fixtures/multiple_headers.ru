# frozen_string_literal: true

run proc { |_env| [200, { "set-cookie" => ["cookie1=value1", "cookie2=value2"] }, ["OK"]] }
