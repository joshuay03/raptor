# frozen_string_literal: true

require "test_helper"

require "etc"

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
          ["Host=HOST", "Port=PORT", "Threads=NUM", "Ractors=NUM", "Workers=NUM"],
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
        assert_nil opts[:stats_file]
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

      private

      def build(options)
        Rackup::Handler::Raptor.send(:build_cluster_options, ->(_) { [200, {}, []] }, options)
      end
    end
  end
end
