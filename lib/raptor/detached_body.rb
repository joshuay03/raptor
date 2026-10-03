# rbs_inline: enabled
# frozen_string_literal: true

require "atomic-ruby/atom"

module Raptor
  # A bounded response body that may be written after its application thread
  # has returned.
  #
  class DetachedBody
    DEFAULT_MAX_BUFFER_SIZE = 64 * 1024

    # Tracks buffered bytes shared by a group of detached bodies.
    #
    class Budget
      # @rbs @max_size: Integer
      # @rbs @size: Atom

      # Creates a shared budget with the given byte limit.
      #
      # @param max_size [Integer] maximum bytes that may be reserved
      # @return [void]
      #
      # @rbs (Integer max_size) -> void
      def initialize(max_size)
        @max_size = max_size
        @size = Atom.new(0)
      end

      # Reserves bytes when they fit within the shared limit.
      #
      # @param bytes [Integer] number of bytes to reserve
      # @return [Boolean] whether the bytes were reserved
      #
      # @rbs (Integer bytes) -> bool
      def reserve(bytes)
        reserved = false
        @size.swap do |size|
          reserved = size + bytes <= @max_size
          reserved ? size + bytes : size
        end
        reserved
      end

      # Releases bytes previously charged to the shared limit.
      #
      # @param bytes [Integer] number of bytes to release
      # @return [void]
      #
      # @rbs (Integer bytes) -> void
      def release(bytes)
        @size.swap { |size| size - bytes }
      end
    end

    # @rbs @max_buffer_size: Integer
    # @rbs @state: Atom
    # @rbs @budgets: Array[Budget]
    # @rbs @wake: ^() -> void
    # @rbs @dispatch: ^(Proc) -> void
    # @rbs @finished: ^(Symbol) -> void
    # @rbs @on_open: (^(DetachedBody) -> void)?
    # @rbs @on_close: (^(Symbol) -> void)?

    # Creates a detached body with a bounded byte buffer.
    #
    # @param max_buffer_size [Integer] maximum body bytes waiting to be written
    # @return [void]
    #
    # @rbs (?max_buffer_size: Integer) -> void
    def initialize(max_buffer_size: DEFAULT_MAX_BUFFER_SIZE)
      raise ArgumentError, "max_buffer_size must be positive" unless max_buffer_size.positive?

      @max_buffer_size = max_buffer_size
      @state = Atom.new({ chunks: [], size: 0, closing: false, closed: false, notified: false, trailers: {} })
      @budgets = []
      @wake = proc {}
      @dispatch = proc { |callback| callback.call }
      @finished = proc {}
      @on_open = nil
      @on_close = nil
    end

    # Registers a callback that runs on the request thread once the server
    # accepts the response stream.
    #
    # @yieldparam stream [DetachedBody] the opened response stream
    # @return [DetachedBody]
    #
    # @rbs () { (DetachedBody stream) -> void } -> DetachedBody
    def on_open(&block)
      @on_open = block
      self
    end

    # Registers a callback for when the response stream closes.
    #
    # @yieldparam reason [Symbol] why the stream closed
    # @return [DetachedBody]
    #
    # @rbs () { (Symbol reason) -> void } -> DetachedBody
    def on_close(&block)
      @on_close = block
      self
    end

    # Adds body bytes without waiting for socket or flow-control capacity.
    #
    # @param chunk [String] response body bytes
    # @return [Symbol] `:accepted`, `:full`, or `:closed`
    #
    # @rbs (String chunk) -> Symbol
    def try_write(chunk)
      raise TypeError, "body must yield String values" unless chunk.is_a?(String)

      chunk = chunk.dup.freeze
      if chunk.empty?
        state = @state.value
        return state[:closed] || state[:closing] ? :closed : :accepted
      end
      return :full unless reserve(chunk.bytesize)

      result = :closed
      wake = false
      @state.swap do |state|
        if state[:closed] || state[:closing]
          result = :closed
          wake = false
          state
        elsif state[:size] + chunk.bytesize > @max_buffer_size
          result = :full
          wake = false
          state
        else
          result = :accepted
          wake = !state[:notified]
          state.merge(
            chunks: state[:chunks] + [chunk],
            size: state[:size] + chunk.bytesize,
            notified: true
          )
        end
      end

      if result == :accepted
        @wake.call if wake
      else
        release(chunk.bytesize)
      end
      result
    end

    # Finishes the body after all accepted bytes have been written.
    #
    # @param trailers [Hash] trailing response headers
    # @return [void]
    #
    # @rbs (?trailers: Hash[String, String | Array[String]]) -> void
    def close(trailers: {})
      trailers = trailers.to_h do |name, value|
        value = value.is_a?(Array) ? value.map { _1.dup.freeze }.freeze : value.dup.freeze
        [name.dup.freeze, value]
      end.freeze
      wake = false
      @state.swap do |state|
        if state[:closed] || state[:closing]
          wake = false
          next state
        end

        wake = !state[:notified]
        state.merge(closing: true, notified: true, trailers: trailers)
      end
      @wake.call if wake
    end

    # Returns whether the stream has closed.
    #
    # @return [Boolean]
    #
    # @rbs () -> bool
    def closed?
      @state.value[:closed]
    end

    # Connects the body to its reactor-owned response stream.
    #
    # @param budgets [Array<Budget>] buffer budgets shared with other bodies
    # @param wake [Proc] called when buffered data or a close is ready to write
    # @param dispatch [Proc] schedules application callbacks off the reactor thread
    # @param finished [Proc] called with the close reason after `on_close`
    # @return [Boolean] false when the bytes already buffered exceed a budget
    #
    # @rbs (Array[Budget] budgets, ^() -> void wake, ^(Proc) -> void dispatch, ^(Symbol) -> void finished) -> bool
    def attach(budgets, wake, dispatch, finished)
      @wake = wake
      @dispatch = dispatch
      @finished = finished
      size = @state.value[:size]
      reserved = []
      budgets.each do |budget|
        unless budget.reserve(size)
          reserved.each { |held| held.release(size) }
          finish(:full)
          return false
        end
        reserved << budget
      end

      @budgets = budgets
      true
    end

    # Notifies the application that its response stream is ready.
    #
    # @return [void]
    #
    # @rbs () -> void
    def open
      @on_open&.call(self)
      @wake.call if @state.value[:notified]
    end

    # Returns the size of the next buffered chunk, 0 when closing, or nil
    # while waiting for more data.
    #
    # @return [Integer, nil]
    #
    # @rbs () -> Integer?
    def next_size
      state = @state.value
      state[:chunks].first&.bytesize || (0 if state[:closing])
    end

    # Removes up to `max_bytes` from the next buffered chunk.
    #
    # @param max_bytes [Integer] the largest chunk to return
    # @return [String, nil] the removed bytes, or nil when nothing is buffered
    #
    # @rbs (Integer max_bytes) -> String?
    def shift(max_bytes)
      chunk = nil
      @state.swap do |state|
        chunk = nil
        first = state[:chunks].first
        next state unless first

        size = max_bytes < first.bytesize ? max_bytes : first.bytesize
        chunk = first.byteslice(0, size)
        chunks = if size == first.bytesize
          state[:chunks].drop(1)
        else
          [first.byteslice(size..-1).freeze] + state[:chunks].drop(1)
        end
        state.merge(
          chunks: chunks,
          size: state[:size] - size,
          notified: !chunks.empty? || state[:closing]
        )
      end
      release(chunk.bytesize) if chunk
      chunk
    end

    # Returns the response trailers supplied when the body closed.
    #
    # @return [Hash] trailing response headers
    #
    # @rbs () -> Hash[String, String | Array[String]]
    def trailers
      @state.value[:trailers]
    end

    # Closes the stream and invokes its callback exactly once.
    #
    # @param reason [Symbol] why the stream closed
    # @return [void]
    #
    # @rbs (Symbol reason) -> void
    def finish(reason)
      callback = false
      remaining = 0
      @state.swap do |state|
        if state[:closed]
          callback = false
          remaining = 0
          state
        else
          callback = true
          remaining = state[:size]
          state.merge(chunks: [], size: 0, closed: true, notified: false)
        end
      end
      return unless callback

      release(remaining)
      @dispatch.call(proc do
        begin
          @on_close&.call(reason)
        ensure
          @finished.call(reason)
        end
      end)
    end

    private

    # Reserves bytes from every budget attached to this body.
    #
    # @param bytes [Integer] number of bytes to reserve
    # @return [Boolean] whether every budget accepted the reservation
    #
    # @rbs (Integer bytes) -> bool
    def reserve(bytes)
      reserved = []
      @budgets.each do |budget|
        unless budget.reserve(bytes)
          reserved.each { |held| held.release(bytes) }
          return false
        end
        reserved << budget
      end
      true
    end

    # Releases bytes from every budget attached to this body.
    #
    # @param bytes [Integer] number of bytes to release
    # @return [void]
    #
    # @rbs (Integer bytes) -> void
    def release(bytes)
      @budgets.each { |budget| budget.release(bytes) }
    end
  end
end
