# rbs_inline: enabled
# frozen_string_literal: true

module Raptor
  # An extension, loaded from `raptor/plugin/<name>` or
  # registered explicitly by application code.
  #
  class Plugin
    class UnknownPlugin < LoadError; end

    # @rbs self.@registry: Hash[String, singleton(Plugin)]
    @registry = {}

    # Registers a plugin class under a name.
    #
    # @rbs (String | Symbol name, singleton(Plugin) plugin) -> void
    def self.register(name, plugin)
      @registry[name.to_s] = plugin
    end

    # Defines and registers a plugin without a named subclass.
    #
    # @rbs (String | Symbol name) { () -> void } -> singleton(Plugin)
    def self.create(name, &block)
      plugin = Class.new(self, &block)
      register(name, plugin)
      plugin
    end

    # Loads a registered plugin, requiring its conventional path if needed.
    #
    # @rbs (String | Symbol name) -> Plugin
    def self.load(name)
      name = name.to_s
      path = "raptor/plugin/#{name}"
      unless @registry.key?(name)
        begin
          require path
        rescue LoadError => error
          raise UnknownPlugin, "Unable to find plugin #{name.inspect}" if error.path == path

          raise
        end
      end

      plugin = @registry[name]
      raise UnknownPlugin, "#{path} did not register plugin #{name.inspect}" unless plugin

      plugin.new
    end

    # @rbs @threads: Array[Thread]?

    # Starts in the master before workers fork. Override to open resources
    # and append callbacks to the cluster's lifecycle hook arrays.
    #
    # @rbs (Cluster cluster) -> void
    def start(cluster)
    end

    # Stops in the master after workers exit, including before hot restart.
    # Also called if startup fails, so resources may be only partly opened.
    #
    # @rbs () -> void
    def stop
    end

    # Runs a block on a master-owned thread. Raptor stops and joins these
    # threads after calling `stop`; use `ensure` in the block for cleanup.
    #
    # @rbs () { () -> void } -> Thread
    def in_background(&block)
      @threads ||= []
      @threads << Thread.new do
        Thread.current.name = "Plugin #{self.class}"
        block.call
      end
      @threads.last
    end

    # Calls the plugin's stop callback and joins its background threads.
    #
    # @rbs () -> void
    def shutdown
      stop
    ensure
      threads = @threads || []
      threads.each(&:kill)
      error = nil
      threads.each do |thread|
        thread.join
      rescue StandardError => thread_error
        error ||= thread_error
      end
      raise error if error
    end
  end
end
