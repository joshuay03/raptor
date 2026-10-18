# frozen_string_literal: true

require "test_helper"

require "raptor"

module Raptor
  class TestRaptor < TestCase
    parallelize_me!

    def test_version_is_defined
      refute_nil VERSION
    end
  end
end
