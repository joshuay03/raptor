# frozen_string_literal: true

require "test_helper"

require "etc"
require "tempfile"

require "rackup"
require "rackup/handler/raptor"
require "raptor/cli"

module Rackup
  module Handler
    class TestRaptor < ::Raptor::TestCase
      parallelize_me!

      def test_registered_with_rackup
        assert_same Rackup::Handler::Raptor, Rackup::Handler.get(:raptor)
      end

      def test_valid_options_keys
        assert_equal(
          ["Host=HOST", "Port=PORT", "Threads=NUM", "Ractors=NUM", "Workers=NUM", "Config=PATH"],
          Rackup::Handler::Raptor.valid_options.keys
        )
      end

      def test_default_options
        opts = build({})

        assert_equal ["tcp://0.0.0.0:9292"], opts[:binds]
        assert_equal ::Raptor::CLI::DEFAULT_OPTIONS[:threads], opts[:threads]
        assert_equal ::Raptor::CLI::DEFAULT_OPTIONS[:ractors], opts[:ractors]
        assert_equal Etc.nprocessors, opts[:workers]
        assert_equal ::Raptor::CLI::DEFAULT_OPTIONS[:client], opts[:client]
      end

      def test_passes_app_through
        app = ->(_env) { [200, {}, ["ok"]] }

        opts = Rackup::Handler::Raptor.send(:build_cluster_options, app, {})

        assert_same app, opts[:app]
      end

      def test_maps_host_and_port_to_binds
        opts = build(Host: "127.0.0.1", Port: 3000)

        assert_equal ["tcp://127.0.0.1:3000"], opts[:binds]
      end

      def test_maps_threads
        opts = build(Threads: 4)

        assert_equal 4, opts[:threads]
      end

      def test_maps_ractors
        opts = build(Ractors: 4)

        assert_equal 4, opts[:ractors]
      end

      def test_maps_workers
        opts = build(Workers: 2)

        assert_equal 2, opts[:workers]
      end

      def test_handles_user_supplied_options_metadata
        opts = build(Port: 3000, user_supplied_options: [:Port])

        assert_equal ["tcp://0.0.0.0:3000"], opts[:binds]
      end

      def test_config_file_layers_under_rack_options
        with_config_file({ threads: 8, ractors: 4, workers: 2, client: { first_data_timeout: 60 } }) do |path|
          opts = build(Config: path, Workers: 16)

          assert_equal 8, opts[:threads]
          assert_equal 4, opts[:ractors]
          assert_equal 16, opts[:workers]
          assert_equal 60, opts[:client][:first_data_timeout]
          assert_equal 10, opts[:client][:chunk_data_timeout]
        end
      end

      def test_config_file_provides_binds_when_no_host_or_port
        with_config_file({ binds: ["tcp://127.0.0.1:4242"] }) do |path|
          opts = build(Config: path)

          assert_equal ["tcp://127.0.0.1:4242"], opts[:binds]
        end
      end

      def test_rack_host_and_port_override_config_binds
        with_config_file({ binds: ["tcp://127.0.0.1:4242"] }) do |path|
          opts = build(Config: path, Host: "0.0.0.0", Port: 3000)

          assert_equal ["tcp://0.0.0.0:3000"], opts[:binds]
        end
      end

      def test_config_file_can_supply_on_error_and_paths
        with_config_source(<<~RUBY) do |path|
          { on_error: ->(_env, _error) {}, stats_file: "tmp/c.json", pid_file: "tmp/c.pid" }
        RUBY
          opts = build(Config: path)

          assert_kind_of Proc, opts[:on_error]
          assert_equal "tmp/c.json", opts[:stats_file]
          assert_equal "tmp/c.pid", opts[:pid_file]
        end
      end

      private

      def build(options)
        Rackup::Handler::Raptor.send(:build_cluster_options, ->(_) { [200, {}, []] }, options)
      end

      def with_config_file(value)
        with_config_source(value.inspect) { |path| yield path }
      end

      def with_config_source(source)
        file = Tempfile.new(["raptor_config", ".rb"])
        file.write(source)
        file.close
        yield file.path
      ensure
        file.unlink if file
      end
    end
  end
end
