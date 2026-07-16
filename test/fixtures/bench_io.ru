# frozen_string_literal: true

require "json"

RESPONSE = JSON.generate(status: "ok")
IO_SEQUENCES = Random.new(0).then { |rng|
  1024.times.map { rng.rand(5..10).times.map { rng.rand(5..15) / 10000.0 } }
}.freeze

run proc { |_env|
  IO_SEQUENCES.sample.each do |wait|
    sleep wait
    100.times.sum { |index| index * 2 }
  end
  [200, { "content-type" => "application/json" }, [RESPONSE]]
}
