# frozen_string_literal: true

require "test_helper"
require "raptor/cli"

module Raptor
  class TestCLI < TestCase
    parallelize_me!

    def test_default_options
      cli = CLI.new([])

      assert_equal ["tcp://0.0.0.0:9292"], options(cli)[:binds]
      assert_equal 3, options(cli)[:threads]
      assert_equal 1, options(cli)[:ractors]
      assert_equal CLI::DEFAULT_WORKER_COUNT, options(cli)[:workers]
      assert_equal "config.ru", options(cli)[:rackup]
      assert_equal 30, options(cli)[:client][:first_data_timeout]
      assert_equal 10, options(cli)[:client][:chunk_data_timeout]
      assert_equal 65, options(cli)[:client][:persistent_data_timeout]
      assert_equal "tmp/raptor.json", options(cli)[:stats_file]
      assert_nil options(cli)[:pidfile]
    end

    def test_rackup_file_positional_argument
      cli = CLI.new(["my_app.ru"])

      assert_equal "my_app.ru", options(cli)[:rackup]
    end

    def test_bind_replaces_default_on_first_use
      cli = CLI.new(["-b", "tcp://0.0.0.0:3000"])

      assert_equal ["tcp://0.0.0.0:3000"], options(cli)[:binds]
    end

    def test_bind_accumulates_on_subsequent_uses
      cli = CLI.new(["-b", "tcp://0.0.0.0:3000", "-b", "tcp://0.0.0.0:3001"])

      assert_equal ["tcp://0.0.0.0:3000", "tcp://0.0.0.0:3001"], options(cli)[:binds]
    end

    def test_threads_short_flag
      cli = CLI.new(["-t", "8"])

      assert_equal 8, options(cli)[:threads]
    end

    def test_threads_long_flag
      cli = CLI.new(["--threads", "8"])

      assert_equal 8, options(cli)[:threads]
    end

    def test_ractors_short_flag
      cli = CLI.new(["-r", "4"])

      assert_equal 4, options(cli)[:ractors]
    end

    def test_ractors_long_flag
      cli = CLI.new(["--ractors", "4"])

      assert_equal 4, options(cli)[:ractors]
    end

    def test_workers_short_flag
      cli = CLI.new(["-w", "2"])

      assert_equal 2, options(cli)[:workers]
    end

    def test_workers_long_flag
      cli = CLI.new(["--workers", "2"])

      assert_equal 2, options(cli)[:workers]
    end

    def test_first_data_timeout
      cli = CLI.new(["--first-data-timeout", "60"])

      assert_equal 60, options(cli)[:client][:first_data_timeout]
    end

    def test_chunk_data_timeout
      cli = CLI.new(["--chunk-data-timeout", "20"])

      assert_equal 20, options(cli)[:client][:chunk_data_timeout]
    end

    def test_persistent_data_timeout
      cli = CLI.new(["--persistent-data-timeout", "120"])

      assert_equal 120, options(cli)[:client][:persistent_data_timeout]
    end

    def test_stats_file
      cli = CLI.new(["--stats-file", "/tmp/custom.json"])

      assert_equal "/tmp/custom.json", options(cli)[:stats_file]
    end

    def test_pidfile
      cli = CLI.new(["--pidfile", "/tmp/raptor.pid"])

      assert_equal "/tmp/raptor.pid", options(cli)[:pidfile]
    end

    def test_multiple_options_together
      cli = CLI.new(["-t", "8", "-r", "2", "-w", "4", "app.ru"])

      assert_equal 8, options(cli)[:threads]
      assert_equal 2, options(cli)[:ractors]
      assert_equal 4, options(cli)[:workers]
      assert_equal "app.ru", options(cli)[:rackup]
    end

    def test_does_not_mutate_default_options
      CLI.new(["-t", "99", "-w", "99"])

      assert_equal 3, CLI::DEFAULT_OPTIONS[:threads]
      assert_equal CLI::DEFAULT_WORKER_COUNT, CLI::DEFAULT_OPTIONS[:workers]
    end

    def test_client_options_are_independent_between_instances
      cli1 = CLI.new(["--first-data-timeout", "5"])
      cli2 = CLI.new([])

      assert_equal 5, options(cli1)[:client][:first_data_timeout]
      assert_equal 30, options(cli2)[:client][:first_data_timeout]
    end

    def test_stats_subcommand_sets_command
      cli = CLI.new(["stats"])

      assert_equal :stats, cli.instance_variable_get(:@command)
    end

    def test_stats_subcommand_does_not_set_rackup
      cli = CLI.new(["stats"])

      assert_equal "config.ru", options(cli)[:rackup]
    end

    def test_invalid_option_raises
      assert_raises(OptionParser::InvalidOption) { CLI.new(["--nonexistent"]) }
    end

    private

    def options(cli)
      cli.instance_variable_get(:@options)
    end
  end
end
