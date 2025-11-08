# frozen_string_literal: true

run proc { |env|
  socket = env[Rack::RACK_HIJACK].call
  socket.write("HTTP/1.1 200 OK\r\nContent-Length: 14\r\nConnection: close\r\n\r\nhijacked full!")
  socket.close
  [200, {}, []]
}
