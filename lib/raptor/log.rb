# rbs_inline: enabled
# frozen_string_literal: true

module Raptor
  # Shared logging helpers used by background threads to surface
  # diagnostics on stderr without each call site reimplementing the
  # same formatting.
  #
  module Log
    # Writes a `"<thread> rescued:"` line followed by the exception's
    # full message (class, message, backtrace) to stderr. Used by
    # background threads that catch their own exceptions to keep
    # running.
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
