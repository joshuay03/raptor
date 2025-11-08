# rbs_inline: enabled
# frozen_string_literal: true

require "mmap-ruby"

module Raptor
  # Shared memory store for per-worker process statistics.
  #
  # Stats uses an anonymous mmap (MAP_ANON | MAP_SHARED) created before
  # forking so that worker processes can write their stats and the master
  # process can read them without any pipes or signals. Each worker is
  # assigned a fixed-size slot in the shared region.
  #
  # Binary layout per slot (native byte order):
  #   pid           uint32    4 bytes
  #   requests      uint64    8 bytes
  #   backlog       uint32    4 bytes
  #   started_at    float64   8 bytes
  #   last_checkin  float64   8 bytes
  #   booted        uint8     1 byte
  #                          33 bytes total
  #
  class Stats
    SLOT_FORMAT = "LQLddC"
    SLOT_SIZE = [0, 0, 0, 0.0, 0.0, 0].pack(SLOT_FORMAT).bytesize

    # @rbs @num_workers: Integer
    # @rbs @mmap: untyped

    # Creates a new Stats instance backed by anonymous shared memory.
    #
    # Allocates a MAP_ANON | MAP_SHARED mmap region large enough for
    # num_workers slots. Must be called before forking so that all
    # worker processes share the same backing memory.
    #
    # @param num_workers [Integer] number of worker slots to allocate
    # @return [void]
    #
    # @rbs (Integer num_workers) -> void
    def initialize(num_workers)
      @num_workers = num_workers
      @mmap = Mmap.new(nil, length: num_workers * SLOT_SIZE, initialize: "\0")
    end

    # Writes stats for a worker slot into shared memory.
    #
    # @param index [Integer] slot index to write into
    # @param pid [Integer] worker process ID
    # @param requests [Integer] total requests handled by this worker
    # @param backlog [Integer] current queue depth
    # @param started_at [Float] process start time as a Unix timestamp
    # @param last_checkin [Float] time of last stats write as a Unix timestamp
    # @param booted [Boolean] whether the worker has finished starting
    # @return [void]
    #
    # @rbs (Integer index, pid: Integer, requests: Integer, backlog: Integer, started_at: Float, last_checkin: Float, booted: bool) -> void
    def write(index, pid:, requests:, backlog:, started_at:, last_checkin:, booted:)
      data = [pid, requests, backlog, started_at, last_checkin, booted ? 1 : 0].pack(SLOT_FORMAT)
      @mmap.semlock { @mmap[index * SLOT_SIZE, SLOT_SIZE] = data }
    end

    # Returns stats for all worker slots.
    #
    # @return [Array<Hash>] per-worker stat hashes with :pid, :requests, :backlog, :started_at, :last_checkin, and :booted
    #
    # @rbs () -> Array[Hash[Symbol, untyped]]
    def all
      (0...@num_workers).map { |index| read(index) }
    end

    # Releases the shared memory mapping.
    #
    # @return [void]
    #
    # @rbs () -> void
    def unmap
      @mmap.unmap
    end

    private

    # Reads stats for a worker slot from shared memory.
    #
    # @param index [Integer] slot index to read from
    # @return [Hash] stat hash with :pid, :requests, :backlog, :started_at, :last_checkin, and :booted
    #
    # @rbs (Integer index) -> Hash[Symbol, untyped]
    def read(index)
      data = @mmap[index * SLOT_SIZE, SLOT_SIZE]
      pid, requests, backlog, started_at, last_checkin, booted = data.unpack(SLOT_FORMAT)
      { pid:, requests:, backlog:, started_at:, last_checkin:, booted: booted == 1 }
    end
  end
end
