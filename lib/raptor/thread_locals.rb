# rbs_inline: enabled
# frozen_string_literal: true

module Raptor
  # Owns Raptor's reusable per-thread values and clears application thread
  # locals after each request.
  #
  module ThreadLocals
    PRESERVED_KEYS = [
      :raptor_http_parser,
      :raptor_read_buffer,
      :raptor_response_buffer,
    ].freeze

    # Returns a reusable value stored on the current thread.
    #
    # @return [Object]
    #
    # @rbs (Symbol key) { () -> untyped } -> untyped
    def self.fetch(key)
      thread = Thread.current
      thread.thread_variable_get(key) || thread.thread_variable_set(key, yield)
    end

    # Clears application-owned true thread locals while retaining Raptor's
    # reusable per-thread values.
    #
    # @return [void]
    #
    # @rbs () -> void
    def self.clear
      thread = Thread.current
      thread.thread_variables.each do |key|
        thread.thread_variable_set(key, nil) unless PRESERVED_KEYS.include?(key)
      end
    end
  end
end
