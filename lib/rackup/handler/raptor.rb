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
          "Workers=NUM" => "Number of worker processes (default: nprocessors)",
          "Ractors=NUM" => "Number of pipeline ractors per worker (default: 1)",
          "Threads=NUM" => "Number of threads per worker (default: 3)",
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

        result = {
          binds: if options[:Host] || options[:Port]
            ["tcp://#{options[:Host] || defaults[:Host]}:#{options[:Port] || defaults[:Port]}"]
          else
            config[:binds] || ["tcp://#{defaults[:Host]}:#{defaults[:Port]}"]
          end,
          socket_backlog: (config[:socket_backlog] || cli_defaults[:socket_backlog]).to_i,
          drain_accept_queue: config.key?(:drain_accept_queue) ? config[:drain_accept_queue] : cli_defaults[:drain_accept_queue],
          workers: (options[:Workers] || config[:workers] || Etc.nprocessors).to_i,
          ractors: (options[:Ractors] || config[:ractors] || cli_defaults[:ractors]).to_i,
          threads: (options[:Threads] || config[:threads] || cli_defaults[:threads]).to_i,
          app: app
        }
        result[:rackup] = config[:rackup] if config.key?(:rackup)
        ::Raptor::CLI::NESTED_OPTION_KEYS.each do |key|
          result[key] = cli_defaults[key].merge(config[key] || {})
        end
        result[:worker_boot_timeout] = (config[:worker_boot_timeout] || cli_defaults[:worker_boot_timeout]).to_i
        result[:worker_timeout] = (config[:worker_timeout] || cli_defaults[:worker_timeout]).to_i
        result[:worker_drain_timeout] = (config[:worker_drain_timeout] || cli_defaults[:worker_drain_timeout]).to_i
        result[:worker_shutdown_timeout] = (config[:worker_shutdown_timeout] || cli_defaults[:worker_shutdown_timeout]).to_i
        result[:stats_file] = config.key?(:stats_file) ? config[:stats_file] : cli_defaults[:stats_file]
        result[:pid_file] = config[:pid_file] if config.key?(:pid_file)
        result[:on_error] = config[:on_error] if config.key?(:on_error)
        result
      end
      private_class_method :build_cluster_options
    end

    register :raptor, Raptor
  end
end
