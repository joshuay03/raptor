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
      },
      stats_file: "tmp/raptor.json",
      pidfile: nil,
    }.freeze

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
      data[:workers].each_with_index do |worker, index|
        status = worker[:booted] ? "booted" : "starting"
        last_checkin = Time.at(worker[:last_checkin]).strftime("%H:%M:%S")
        puts "Worker #{index}: pid=#{worker[:pid]}, requests=#{worker[:requests]}, " \
             "backlog=#{worker[:backlog]}, #{status}, last_checkin=#{last_checkin}"
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

        opts.on("--stats-file PATH", String, "Stats file path (default: tmp/raptor.json)") do |path|
          @options[:stats_file] = path
        end

        opts.on("--pidfile PATH", String, "Pidfile path (default: none)") do |path|
          @options[:pidfile] = path
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
