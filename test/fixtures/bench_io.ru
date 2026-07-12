# frozen_string_literal: true

require "json"

RESPONSE = JSON.generate(status: "ok")
IO_SEQUENCES = Random.new(0).then { |rng|
  1024.times.map { rng.rand(5..10).times.map { rng.rand(5..15) / 10000.0 } }
}.freeze
MUTEX = Mutex.new

counter = 0

run proc { |_env|
  slot = MUTEX.synchronize { counter += 1 }
  IO_SEQUENCES[(slot - 1) % IO_SEQUENCES.length].each do |wait|
    sleep wait
    100.times.map { |index| index * 2 }.sum
  end
  [200, { "content-type" => "application/json" }, [RESPONSE]]
}
