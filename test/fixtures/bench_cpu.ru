# frozen_string_literal: true

require "json"

RESPONSE = JSON.generate(status: "ok")
CPU_SEQUENCES = Random.new(0).then { |rng|
  1024.times.map { rng.rand(3..5).times.map { { count: rng.rand(700..1400), wait: rng.rand(1..2) / 40000.0 } } }
}.freeze

run proc { |env|
  env[Rack::RACK_INPUT].read
  CPU_SEQUENCES.sample.each do |chunk|
    sleep chunk[:wait]
    items = chunk[:count].times.map { |index| { id: index, name: "item-#{index}", value: index * 3.14, rendered: "ITEM-#{index}" } }
    JSON.generate(items: items)
  end
  [200, { "content-type" => "application/json" }, [RESPONSE]]
}
