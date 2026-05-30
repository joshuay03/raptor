# rbs_inline: enabled
# frozen_string_literal: true

require "etc"
require "json"
require "optparse"

require_relative "cluster"

module Raptor
  # Command-line interface for the Raptor web server.
  #
  # CLI parses command-line arguments and starts the server cluster with the
  # specified configuration options. It supports configuring the number of
  # workers, threads, ractors, bind addresses, and various client timeout
  # settings.
  #
  # @example Basic usage
  #   cli = Raptor::CLI.new(["config.ru", "-t", "8", "-w", "4"])
  #   cli.run
  #
  # @example With custom timeouts
  #   cli = Raptor::CLI.new(["--first-data-timeout", "60", "--threads", "8"])
  #   cli.run
  #
  class CLI
    DEFAULT_WORKER_COUNT = Etc.nprocessors

    DEFAULT_OPTIONS = {
      binds: ["tcp://0.0.0.0:9292"].freeze,
      threads: 3,
      ractors: 1,
      workers: DEFAULT_WORKER_COUNT,
      rackup: "config.ru",
      client: {
        first_data_timeout: 30,
        chunk_data_timeout: 10,
        persistent_data_timeout: 65,
        max_body_size: nil,
        body_spool_threshold: 1024 * 1024,
      },
      worker_timeout: 60,
      worker_boot_timeout: 60,
      worker_shutdown_timeout: 30,
      stats_file: "tmp/raptor.json",
      pid_file: nil,
    }.freeze

    DEFAULT_CONFIG_PATHS = ["raptor.rb", "config/raptor.rb"].freeze

    # Loads a configuration file and returns the hash it evaluates to.
    #
    # The file is evaluated at the top level so constants like `Raptor::*` resolve
    # the same as in a regular Ruby script. The final expression must be a Hash
    # of cluster options (the same keys accepted by {Raptor::Cluster#initialize}).
    #
    # @param path [String] path to a Ruby file that evaluates to a Hash
    # @return [Hash{Symbol => untyped}] cluster options
    # @raise [ArgumentError] if the file does not evaluate to a Hash
    #
    # @rbs (String path) -> Hash[Symbol, untyped]
    def self.load_config_file(path)
      config = eval(File.read(path), TOPLEVEL_BINDING, path, 1)
      raise ArgumentError, "Config file at #{path.inspect} must return a Hash, got #{config.class}" unless config.is_a?(Hash)

      config
    end

    # Returns the first existing path in {DEFAULT_CONFIG_PATHS} resolved
    # against `root`, or nil if none exist.
    #
    # Used to pick up a project-local config file when no `-c`/`--config`
    # flag was supplied.
    #
    # @param root [String] directory to resolve the default paths against
    # @return [String, nil] the config path, or nil if no default file exists
    #
    # @rbs (?String root) -> String?
    def self.default_config_path(root = Dir.pwd)
      DEFAULT_CONFIG_PATHS.find { |path| File.exist?(File.join(root, path)) }
    end

    # @rbs @command: Symbol
    # @rbs @options: Hash[Symbol, untyped]
    # @rbs @parser: OptionParser

    # Creates a new CLI instance and parses command-line arguments.
    #
    # Parses the provided command-line arguments and configures the server
    # options accordingly. A rackup file can be provided as the first
    # positional argument (defaults to config.ru).
    #
    # @param argv [Array<String>] command-line arguments to parse
    # @return [void]
    # @raise [OptionParser::ParseError] if invalid options are provided
    #
    # @example With rackup file
    #   cli = CLI.new(["my_app.ru", "-w", "4"])
    #
    # @example With options only
    #   cli = CLI.new(["-t", "8", "-r", "2"])
    #
    # @rbs (Array[String] argv) -> void
    def initialize(argv)
      if argv.first == "stats"
        argv.shift
        @command = :stats
      else
        @command = :server
      end
      @options = DEFAULT_OPTIONS.dup
      @options[:client] = @options[:client].dup

      apply_config_file(extract_config_path(argv) || self.class.default_config_path)

      @parser = create_parser
      @parser.parse!(argv)

      @options[:rackup] = argv.first if @command == :server && argv.first
    end

    # Runs the requested command.
    #
    # @return [void]
    #
    # @rbs () -> void
    def run
      @command == :stats ? run_stats : Cluster.run(@options)
    end

    private

    # Reads and prints the stats file.
    #
    # @return [void]
    #
    # @rbs () -> void
    def run_stats
      stats_file = @options[:stats_file]

      unless File.exist?(stats_file)
        warn "No stats file at #{stats_file.inspect}. Is Raptor running?"
        exit 1
      end

      data = JSON.parse(File.read(stats_file), symbolize_names: true)

      puts "Master PID: #{data[:master_pid]}"
      data[:workers].each do |worker|
        status = worker[:booted] ? "booted" : "starting"
        last_checkin = Time.at(worker[:last_checkin]).strftime("%H:%M:%S")
        puts "Worker #{worker[:index]} (phase #{worker[:phase]}): pid=#{worker[:pid]}, requests=#{worker[:requests]}, " \
             "busy=#{worker[:busy_threads]}/#{worker[:thread_capacity]}, backlog=#{worker[:backlog]}, " \
             "#{status}, last_checkin=#{last_checkin}"
      end
    end

    # Scans argv for a `-c`/`--config` flag and returns the configured path.
    #
    # The pre-scan runs before the main OptionParser pass so the config file
    # can be applied as a base layer that CLI args then override. All four
    # OptionParser-accepted forms (`-c PATH`, `-cPATH`, `--config PATH`,
    # `--config=PATH`) are recognized.
    #
    # @param argv [Array<String>] command-line arguments to scan
    # @return [String, nil] the config path, or nil if no flag was supplied
    #
    # @rbs (Array[String] argv) -> String?
    def extract_config_path(argv)
      argv.each_with_index do |arg, i|
        case arg
        when "-c", "--config" then return argv[i + 1]
        when /\A--config=(.*)\z/, /\A-c(.+)\z/ then return Regexp.last_match(1)
        end
      end
      nil
    end

    # Loads a config file and merges it into `@options` over the defaults.
    #
    # Top-level keys replace defaults; the nested `:client` hash is merged
    # key-by-key so a config file does not need to restate every client option.
    #
    # @param path [String, nil] path to the config file, or nil to no-op
    # @return [void]
    #
    # @rbs (String? path) -> void
    def apply_config_file(path)
      return unless path

      config = self.class.load_config_file(path)
      config.each do |key, value|
        if key == :client && value.is_a?(Hash)
          @options[:client] = @options[:client].merge(value)
        else
          @options[key] = value
        end
      end
    end

    # Creates the OptionParser instance with all supported command-line options.
    #
    # @return [OptionParser] configured option parser
    #
    # @rbs () -> OptionParser
    def create_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: raptor [options] [rackup file]"

        opts.on("-c", "--config PATH", String, "Load configuration from PATH") do
          # Loaded in #initialize before parsing so CLI args can override config values
        end

        opts.on("-b", "--bind URI", String, "Bind address (default: tcp://0.0.0.0:9292)") do |bind|
          if @options[:binds] == DEFAULT_OPTIONS[:binds]
            @options[:binds] = [bind]
          else
            @options[:binds] << bind
          end
        end

        opts.on("-t", "--threads NUM", Integer, "Number of threads (default: 3)") do |num|
          @options[:threads] = num
        end

        opts.on("-r", "--ractors NUM", Integer, "Number of ractors (default: 1)") do |num|
          @options[:ractors] = num
        end

        opts.on("-w", "--workers NUM", Integer, "Number of worker processes (default: #{DEFAULT_WORKER_COUNT})") do |num|
          @options[:workers] = num
        end

        opts.on("--first-data-timeout SECONDS", Integer, "First data timeout in seconds (default: 30)") do |timeout|
          @options[:client][:first_data_timeout] = timeout
        end

        opts.on("--chunk-data-timeout SECONDS", Integer, "Chunk data timeout in seconds (default: 10)") do |timeout|
          @options[:client][:chunk_data_timeout] = timeout
        end

        opts.on("--persistent-data-timeout SECONDS", Integer, "Persistent data timeout in seconds (default: 65)") do |timeout|
          @options[:client][:persistent_data_timeout] = timeout
        end

        opts.on("--max-body-size BYTES", Integer, "Maximum request body size in bytes (default: unlimited)") do |bytes|
          @options[:client][:max_body_size] = bytes
        end

        opts.on("--body-spool-threshold BYTES", Integer, "Spool request bodies larger than this to a tempfile (default: #{1024 * 1024})") do |bytes|
          @options[:client][:body_spool_threshold] = bytes
        end

        opts.on("--worker-timeout SECONDS", Integer, "Kill booted workers that fail to check in within this window (default: 60)") do |timeout|
          @options[:worker_timeout] = timeout
        end

        opts.on("--worker-boot-timeout SECONDS", Integer, "Kill workers that fail to boot within this window (default: 60)") do |timeout|
          @options[:worker_boot_timeout] = timeout
        end

        opts.on("--worker-shutdown-timeout SECONDS", Integer, "Force-kill workers that fail to exit within this window after shutdown is signalled (default: 30)") do |timeout|
          @options[:worker_shutdown_timeout] = timeout
        end

        opts.on("--stats-file PATH", String, "Stats file path (default: tmp/raptor.json)") do |path|
          @options[:stats_file] = path
        end

        opts.on("--pid-file PATH", String, "PID file path (default: none)") do |path|
          @options[:pid_file] = path
        end

        opts.on("--help", "Show this help") do
          puts opts
          exit
        end

        opts.on("-v", "--version", "Show version") do
          puts Raptor::VERSION
          exit
        end
      end
    end
  end
end
