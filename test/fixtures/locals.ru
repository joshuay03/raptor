# frozen_string_literal: true

run proc { |env|
  if env["PATH_INFO"] == "/set"
    Thread.current[:fiber_local] = "fiber"
    Thread.current.thread_variable_set(:thread_local, "thread")
    Fiber[:storage] = "storage"
    body = "set"
  else
    body = [
      Thread.current[:fiber_local],
      Thread.current.thread_variable_get(:thread_local),
      Fiber[:storage],
    ].inspect
  end

  [200, { "content-type" => "text/plain" }, [body]]
}
