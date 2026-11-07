# frozen_string_literal: true

require "test_helper"

require "tmpdir"

require "raptor/plugin"

module Raptor
  class TestPlugin < TestCase
    def test_registers_classes_and_creates_fresh_instances
      plugin = Class.new(Plugin)
      Plugin.register(:registered_test, plugin)

      first = Plugin.load("registered_test")
      assert_instance_of plugin, first
      refute_same first, Plugin.load(:registered_test)
    end

    def test_autoloads_a_named_plugin
      with_plugin_file("autoload_test", <<~RUBY) do
        Raptor::Plugin.create(:autoload_test) do
          def greeting = "loaded"
        end
      RUBY
        assert_equal "loaded", Plugin.load(:autoload_test).greeting
      end
    end

    def test_reports_missing_and_unregistered_plugins
      error = assert_raises(Plugin::UnknownPlugin) { Plugin.load(:missing_test_plugin) }
      assert_includes error.message, "missing_test_plugin"

      with_plugin_file("unregistered_test", "# No registration\n") do
        error = assert_raises(Plugin::UnknownPlugin) { Plugin.load(:unregistered_test) }
        assert_includes error.message, "did not register"
      end
    end

    def test_preserves_missing_dependency_errors
      with_plugin_file("dependency_test", 'require "missing_plugin_dependency"') do
        error = assert_raises(LoadError) { Plugin.load(:dependency_test) }
        refute_instance_of Plugin::UnknownPlugin, error
        assert_equal "missing_plugin_dependency", error.path
      end
    end

    def test_shutdown_stops_background_threads_even_when_stop_raises
      plugin = Class.new(Plugin) do
        def stop = raise "stop failed"
      end.new
      started = Queue.new
      stopped = Queue.new
      thread = plugin.in_background do
        started << true
        sleep
      ensure
        stopped << true
      end
      Timeout.timeout(5) { started.pop }

      error = assert_raises(RuntimeError) { plugin.shutdown }

      assert_equal "stop failed", error.message
      refute thread.alive?
      assert_equal true, stopped.pop(true)
    ensure
      thread&.kill&.join
    end

    def test_shutdown_joins_remaining_threads_after_a_background_thread_fails
      plugin = Plugin.new
      failed = plugin.in_background do
        Thread.current.report_on_exception = false
        raise "exporter failed"
      end
      assert_raises(RuntimeError) { failed.join }

      started = Queue.new
      cleaning = Queue.new
      release = Queue.new
      worker = plugin.in_background do
        started << true
        sleep
      ensure
        cleaning << true
        release.pop
      end
      Timeout.timeout(5) { started.pop }

      shutdown = Thread.new do
        plugin.shutdown
      rescue RuntimeError => error
        error
      end
      Timeout.timeout(5) { cleaning.pop }
      wait_until { shutdown.stop? }

      assert_predicate shutdown, :alive?, "Shutdown returned before background cleanup finished"
      release << true
      error = Timeout.timeout(5) { shutdown.value }

      assert_equal "exporter failed", error.message
      refute worker.alive?
    ensure
      release << true if release
      [failed, worker, shutdown].compact.each do |thread|
        thread.kill
        thread.join rescue nil
      end
    end

    private

    def with_plugin_file(name, source)
      Dir.mktmpdir do |directory|
        path = File.join(directory, "raptor", "plugin")
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "#{name}.rb"), source)
        $LOAD_PATH.unshift(directory)
        begin
          yield
        ensure
          $LOAD_PATH.delete(directory)
        end
      end
    end
  end
end
