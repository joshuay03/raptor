# rbs_inline: enabled
# frozen_string_literal: true

module Raptor
  # Shared logging helpers. Every line is prefixed with
  # `[Raptor <pid>|<ractor>|<thread>]` so output is identifiable
  # and traceable to its source in a mixed log stream.
  #
  module Log
    # Writes an informational message to stdout.
    #
    # @param message [String] the message to log
    # @return [void]
    #
    # @rbs (String message) -> void
    def self.info(message)
      Kernel.puts "#{prefix} #{message}"
    end

    # Writes a warning to stderr.
    #
    # @param message [String] the message to log
    # @return [void]
    #
    # @rbs (String message) -> void
    def self.warn(message)
      Kernel.warn "#{prefix} #{message}"
    end

    # Logs a rescued exception to stderr. The full message (class,
    # message, backtrace) is written on subsequent unprefixed lines.
    #
    # @param error [Exception] the rescued exception
    # @return [void]
    #
    # @rbs (Exception error) -> void
    def self.rescued_error(error)
      Kernel.warn "#{prefix} rescued:"
      Kernel.warn error.full_message
    end

    # Builds the log line prefix from the current process, ractor,
    # and thread. Unnamed ractors and threads are reported as `Main`.
    #
    # @return [String] the prefix
    #
    # @rbs () -> String
    def self.prefix
      ractor = Ractor.current.name || "Main"
      thread = Thread.current.name || "Main"
      "[Raptor #{Process.pid}|#{ractor}|#{thread}]"
    end
    private_class_method :prefix
  end
end
