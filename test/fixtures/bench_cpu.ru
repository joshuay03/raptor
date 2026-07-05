# frozen_string_literal: true

require "json"

run proc { |_env|
  count = rand(20..200)
  items = count.times.map do |index|
    { id: index, name: "item-#{index}", value: index * 3.14, rendered: "ITEM-#{index}" }
  end
  [200, { "content-type" => "application/json" }, [JSON.generate(items: items)]]
}
