# frozen_string_literal: true

require "json"

RESPONSE = JSON.generate(status: "ok")
SLEEPS = Random.new(0).then { |rng| 1024.times.map { rng.rand(1..10) / 1000.0 } }.freeze
MUTEX = Mutex.new

counter = 0

run proc { |_env|
  slot = MUTEX.synchronize { counter += 1 }
  sleep SLEEPS[(slot - 1) % SLEEPS.length]
  [200, { "content-type" => "application/json" }, [RESPONSE]]
}
