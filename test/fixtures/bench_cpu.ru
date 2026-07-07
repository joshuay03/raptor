# frozen_string_literal: true

require "json"

COUNTS = Random.new(0).then { |rng| 1024.times.map { rng.rand(20..200) } }.freeze
MUTEX = Mutex.new

counter = 0

run proc { |_env|
  slot = MUTEX.synchronize { counter += 1 }
  count = COUNTS[(slot - 1) % COUNTS.length]
  items = count.times.map do |index|
    { id: index, name: "item-#{index}", value: index * 3.14, rendered: "ITEM-#{index}" }
  end
  [200, { "content-type" => "application/json" }, [JSON.generate(items: items)]]
}
