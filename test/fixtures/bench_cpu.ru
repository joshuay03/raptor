# frozen_string_literal: true

require "json"

CPU_SEQUENCES = Random.new(0).then { |rng|
  1024.times.map { rng.rand(3..5).times.map { { count: rng.rand(150..300), wait: rng.rand(1..2) / 20000.0 } } }
}.freeze
MUTEX = Mutex.new

counter = 0

run proc { |_env|
  slot = MUTEX.synchronize { counter += 1 }
  items = []
  CPU_SEQUENCES[(slot - 1) % CPU_SEQUENCES.length].each do |chunk|
    chunk[:count].times do |index|
      items << { id: index, name: "item-#{index}", value: index * 3.14, rendered: "ITEM-#{index}" }
    end
    sleep chunk[:wait]
  end
  [200, { "content-type" => "application/json" }, [JSON.generate(items: items)]]
}
