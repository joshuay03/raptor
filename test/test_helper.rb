# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "raptor"
require "minitest/autorun"

module Raptor
  class TestCase < Minitest::Test
    private

    def without_output(&block)
      return block.call if ENV["WITH_OUTPUT"]

      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = File.open(File::NULL, "w")
      $stderr = File.open(File::NULL, "w")
      block.call
    ensure
      unless ENV["WITH_OUTPUT"]
        $stdout&.close unless $stdout == STDOUT
        $stdout = original_stdout
        $stderr&.close unless $stderr == STDERR
        $stderr = original_stderr
      end
    end
  end
end
