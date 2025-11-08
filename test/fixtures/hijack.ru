# frozen_string_literal: true

run proc { |_env|
  hijack = proc { |socket|
    socket.write("hijacked body")
    socket.close
  }
  [200, { "content-length" => "13", Rack::RACK_HIJACK => hijack }, []]
}
