# frozen_string_literal: true

require "json"

CPU_SEQUENCES = Random.new(0).then { |rng|
  1024.times.map { rng.rand(3..5).times.map { { count: rng.rand(150..300), wait: rng.rand(1..2) / 20000.0 } } }
}.freeze

run proc { |env|
  env["rack.input"].read
  items = []
  CPU_SEQUENCES.sample.each do |chunk|
    chunk[:count].times do |index|
      items << { id: index, name: "item-#{index}", value: index * 3.14, rendered: "ITEM-#{index}" }
    end
    sleep chunk[:wait]
  end
  [200, { "content-type" => "application/json" }, [JSON.generate(items: items)]]
}
