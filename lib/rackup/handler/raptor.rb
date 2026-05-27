# rbs_inline: enabled
# frozen_string_literal: true

require "etc"

module Rackup
  module Handler
    # Rack handler for booting Raptor through Rackup, `rails server`, or any
    # other host that follows the Rack handler protocol.
    #
    module Raptor
      DEFAULT_OPTIONS = {
        Host: "0.0.0.0",
        Port: 9292
      }.freeze

      # Boots a Raptor cluster serving the given Rack application.
      #
      # @param app [#call] the Rack application to serve
      # @param options [Hash] handler options provided by Rackup or the host
      # @yield [cluster] the cluster instance, before it starts running
      # @return [void]
      #
      # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, **untyped options) { (::Raptor::Cluster) -> void } -> void
      def self.run(app, **options)
        require_relative "../../raptor/cli"
        require_relative "../../raptor/cluster"

        cluster = ::Raptor::Cluster.new(build_cluster_options(app, options))

        yield cluster if block_given?

        cluster.run
      end

      # Returns the handler-specific options surfaced by `rackup --help`.
      #
      # @return [Hash{String => String}] option spec to description mapping
      #
      # @rbs () -> Hash[String, String]
      def self.valid_options
        {
          "Host=HOST"   => "Hostname to listen on (default: #{DEFAULT_OPTIONS[:Host]})",
          "Port=PORT"   => "Port to listen on (default: #{DEFAULT_OPTIONS[:Port]})",
          "Threads=NUM" => "Number of threads per worker (default: 3)",
          "Ractors=NUM" => "Number of pipeline ractors per worker (default: 1)",
          "Workers=NUM" => "Number of worker processes (default: nprocessors)",
          "Config=PATH" => "Load additional configuration from PATH"
        }
      end

      # Builds a Raptor cluster options hash from Rack handler options.
      #
      # Options not explicitly supplied by the user (per the `:user_supplied_options`
      # key) are treated as host-provided defaults.
      #
      # @param app [#call] the Rack application to serve
      # @param options [Hash] handler options provided by Rackup or the host
      # @return [Hash{Symbol => untyped}] cluster configuration
      #
      # @rbs (^(Hash[String, untyped]) -> [Integer, Hash[String, String | Array[String]], untyped] app, Hash[Symbol, untyped] options) -> Hash[Symbol, untyped]
      def self.build_cluster_options(app, options)
        defaults = DEFAULT_OPTIONS.dup

        if user_supplied_options = options.delete(:user_supplied_options)
          (options.keys - user_supplied_options).each do |key|
            defaults[key] = options.delete(key)
          end
        end

        cli_defaults = ::Raptor::CLI::DEFAULT_OPTIONS
        config_path = options[:Config] || ::Raptor::CLI.default_config_path
        config = config_path ? ::Raptor::CLI.load_config_file(config_path) : {}

        binds = if options[:Host] || options[:Port]
          host = options[:Host] || defaults[:Host]
          port = options[:Port] || defaults[:Port]
          ["tcp://#{host}:#{port}"]
        else
          config[:binds] || ["tcp://#{defaults[:Host]}:#{defaults[:Port]}"]
        end

        result = {
          app: app,
          binds: binds,
          threads: (options[:Threads] || config[:threads] || cli_defaults[:threads]).to_i,
          ractors: (options[:Ractors] || config[:ractors] || cli_defaults[:ractors]).to_i,
          workers: (options[:Workers] || config[:workers] || Etc.nprocessors).to_i,
          client: cli_defaults[:client].merge(config[:client] || {})
        }

        [:rackup, :on_error, :stats_file, :pidfile].each do |key|
          result[key] = config[key] if config.key?(key)
        end

        result
      end
      private_class_method :build_cluster_options
    end

    register :raptor, Raptor
  end
end
