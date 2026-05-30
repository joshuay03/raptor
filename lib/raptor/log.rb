# rbs_inline: enabled
# frozen_string_literal: true

module Raptor
  # Shared logging helpers.
  #
  module Log
    # Logs a rescued exception to stderr with the current thread's
    # name as a prefix. Used by background threads that catch their
    # own errors to keep running.
    #
    # @param error [Exception] the rescued exception
    # @return [void]
    #
    # @rbs (Exception error) -> void
    def self.rescued_error(error)
      warn "#{Thread.current.name} rescued:"
      warn error.full_message
    end
  end
end
