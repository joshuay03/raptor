# frozen_string_literal: true

require "test_helper"

require "open3"

require "atomic-ruby/atomic_count_down_latch"

require "raptor/embedded"

module Raptor
  class TestIntegrationEmbedded < IntegrationTestCase
    def teardown
      @server&.shutdown
      super
    end

    def test_serves_the_existing_app_in_the_same_process
      message = +"initial"
      app = ->(_env) { [200, {}, ["#{Process.pid}: #{message}"]] }
      output, errors = capture_io { @server = Embedded.new(app).start }
      message.replace("updated")

      response = Net::HTTP.get(URI("http://127.0.0.1:#{@server.port}/"))

      assert_empty output
      assert_empty errors
      assert_equal "#{Process.pid}: updated", response
      assert_match(/#{Process.pid}: updated/, raw_split_request(@server.port))
    end

    def test_reports_startup_when_logging_is_enabled
      app = ->(_env) { [200, {}, ["ok"]] }
      output, errors = capture_io do
        @server = Embedded.new(app, threads: 3, max_threads: 3, log: true).start
      end

      assert_includes output, "Server initializing:"
      assert_includes output, "PID: #{Process.pid}"
      assert_includes output, "3 worker threads\n"
      assert_includes output, "Listening on 127.0.0.1:#{@server.port}"
      assert_empty errors
      assert_equal "ok", Net::HTTP.get(URI("http://127.0.0.1:#{@server.port}/"))
    end

    def test_pause_drains_requests_and_preserves_the_listener_across_resumes
      entered = AtomicCountDownLatch.new(1)
      release = AtomicCountDownLatch.new(1)
      app = ->(env) do
        if env["PATH_INFO"] == "/hold"
          entered.count_down
          release.wait
        end

        [200, {}, ["#{Process.pid}: ok"]]
      end
      @server = Embedded.new(app, http1: { ractors: 1 }).start
      port = @server.port
      addresses = @server.addresses
      client = nil
      joiner = Thread.new { @server.join }
      request = Thread.new { Net::HTTP.get(URI("http://127.0.0.1:#{port}/hold")) }
      Timeout.timeout(5) { entered.wait }
      pausing = Thread.new { @server.pause }
      wait_until { pausing.stop? }

      assert_predicate pausing, :alive?
      release.count_down
      assert_equal "#{Process.pid}: ok", Timeout.timeout(5) { request.value }
      assert_same @server, Timeout.timeout(5) { pausing.value }

      2.times do
        assert_same @server, @server.pause
        assert_equal port, @server.port
        assert_equal addresses, @server.addresses
        assert_predicate joiner, :alive?
        assert_raises(Errno::EADDRINUSE) { TCPServer.new("127.0.0.1", port) }

        client = TCPSocket.new("127.0.0.1", port)
        client.write("GET / HTTP/1.0\r\n\r\n")
        refute client.wait_readable(0.1)
        assert_same @server, @server.resume
        assert_same @server, @server.resume
        assert_includes Timeout.timeout(5) { client.read }, "#{Process.pid}: ok"
        client.close
        @server.pause
      end

      @server.shutdown
      Timeout.timeout(5) { joiner.value }
      assert_raises(ThreadError) { @server.resume }
      assert_raises(ThreadError) { @server.pause }
      TCPServer.open("127.0.0.1", port) { |listener| assert_equal port, listener.addr[1] }
    ensure
      release.count_down if release && release.count.positive?
      client&.close
      @server&.shutdown
      [request, pausing, joiner].each { |thread| thread&.join(5) }
    end

    def test_cli_serves_in_process_and_shuts_down_on_signals
      Tempfile.create(["raptor_embedded", ".ru"]) do |app|
        app.write('run ->(_env) { [200, {}, [Process.pid.to_s]] }')
        app.flush

        ["TERM", "INT"].each do |signal|
          port = TCPServer.open("127.0.0.1", 0) { |listener| listener.addr[1] }
          Open3.popen3(
            RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
            File.expand_path("../../exe/raptor", __dir__),
            "-t", "3", "-w", "0", "-b", "tcp://127.0.0.1:#{port}",
            "--chdir", File.dirname(app.path), File.basename(app.path)
          ) do |input, output, errors, process|
            input.close
            startup = +""
            Timeout.timeout(5) do
              startup << output.readline until startup.include?("Listening on")
            end

            assert_includes startup, "PID: #{process.pid}"
            assert_includes startup, "3 worker threads (scaling, no limit)"
            assert_includes startup, "Listening on 127.0.0.1:#{port}"

            wait_for_server(port)

            assert_equal process.pid.to_s, Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))

            Process.kill(signal, process.pid)
            status = Timeout.timeout(5) { process.value }
            error_output = errors.read

            assert_predicate status, :success?
            assert_empty error_output
            TCPServer.open("127.0.0.1", port) { |listener| assert_equal port, listener.addr[1] }
          ensure
            Process.kill("KILL", process.pid) rescue nil if process.alive?
          end
        end
      end
    end

    def test_capybara_server_shuts_down_cleanly_at_process_exit
      output, errors, status = Open3.capture3(
        RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", <<~RUBY
          require "capybara"
          require "rackup"
          require "rackup/handler/raptor"

          Capybara.register_server :raptor do |app, port, host|
            Rackup::Handler::Raptor.run(app, Host: host, Port: port, Workers: 0) do |server|
              at_exit { server.shutdown }
            end
          end
          Capybara.server = :raptor

          app = ->(_) { [200, { "content-type" => "text/plain" }, ["ok"]] }
          server = Capybara::Server.new(app, host: "127.0.0.1").boot
          puts Net::HTTP.get(URI(server.base_url))
        RUBY
      )

      assert_predicate status, :success?
      assert_equal "ok\n", output
      assert_empty errors
    end

    def test_shutdown_releases_threads_ractors_and_the_port
      Timeout.timeout(5) do
        threads = Thread.list
        ractor_count = Ractor.count
        port = 0

        2.times do
          @server = Embedded.new(->(_env) { [200, {}, ["ok"]] }, port: port).start
          port = @server.port
          serving_threads = Thread.list - threads

          assert_equal "ok", Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))

          @server.shutdown
          @server.shutdown
          @server.join

          assert_empty serving_threads.select(&:alive?)
          assert_equal ractor_count, Ractor.count
          TCPServer.open("127.0.0.1", port) { |listener| assert_equal port, listener.addr[1] }
        end
      end
    end

    def test_shutdown_waits_for_an_in_flight_request
      entered = AtomicCountDownLatch.new(1)
      release = AtomicCountDownLatch.new(1)
      @server = Embedded.new(->(_env) {
        entered.count_down
        release.wait
        [200, {}, ["finished"]]
      }).start
      request = Thread.new { Net::HTTP.get(URI("http://127.0.0.1:#{@server.port}/")) }
      Timeout.timeout(5) { entered.wait }

      shutdowns = 2.times.map { Thread.new { @server.shutdown } }
      wait_until { shutdowns.all?(&:stop?) }

      shutdowns.each { |shutdown| assert_predicate shutdown, :alive? }
      release.count_down
      assert_equal "finished", Timeout.timeout(5) { request.value }
      Timeout.timeout(5) { shutdowns.each(&:value) }
      @server.join
    ensure
      release.count_down if release && release.count > 0
      request&.join
      shutdowns&.each(&:join)
    end

    def test_startup_failure_releases_partially_started_resources
      threads = Thread.list
      ractor_count = Ractor.count
      @server = Embedded.new(
        ->(_env) { [200, {}, []] },
        binds: ["h2c://127.0.0.1:0"],
        http2: { ractors: 0 }
      )

      assert_raises(ArgumentError) { @server.start }

      assert_empty (Thread.list - threads).select(&:alive?)
      assert_equal ractor_count, Ractor.count
      TCPServer.open("127.0.0.1", @server.port) { |listener| assert_equal @server.port, listener.addr[1] }
    end

    def test_bind_failure_releases_previously_bound_listeners
      port = TCPServer.open("127.0.0.1", 0) { |listener| listener.addr[1] }
      @server = Embedded.new(
        ->(_env) { [200, {}, []] },
        binds: ["tcp://127.0.0.1:#{port}", "invalid://127.0.0.1:0"]
      )

      assert_raises(Binder::UnknownBindSchemeError) { @server.start }

      TCPServer.open("127.0.0.1", port) { |listener| assert_equal port, listener.addr[1] }
    end

    def test_reactor_startup_failure_is_returned_to_the_caller
      [:start, :resume].each do |operation|
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          result = Timeout.timeout(5) do
            threads = Thread.list
            ractor_count = Ractor.count
            server = Embedded.new(->(_env) { [200, {}, []] })
            server.start.pause if operation == :resume
            ENV["IO_EVENT_SELECTOR"] = "MissingSelector"
            begin
              server.public_send(operation)
              nil
            rescue NameError => error
              TCPServer.open("127.0.0.1", server.port) do
                [error.name, (Thread.list - threads).count(&:alive?), Ractor.count - ractor_count]
              end
            end
          end
          Marshal.dump(result, writer)
          writer.close
          exit!(0)
        end
        writer.close

        assert_equal [:MissingSelector, 0, 0], Timeout.timeout(10) { Marshal.load(reader) }
        Process.wait(pid)
        assert_predicate $?, :success?
      ensure
        reader&.close
        writer&.close
        stop_cluster(pid)
      end
    end

    def test_serving_failure_releases_resources_and_is_returned_to_the_caller
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        Server.prepend(Module.new do
          def accept_connection(listener)
            Thread.current.report_on_exception = false
            raise IOError, "accept failed"
          end
        end)
        result = Timeout.timeout(5) do
          threads = Thread.list
          ractor_count = Ractor.count
          server = Embedded.new(->(_env) { [200, {}, []] }).start
          begin
            TCPSocket.open("127.0.0.1", server.port) { server.join }
            nil
          rescue IOError => error
            TCPServer.open("127.0.0.1", server.port) do
              [error.message, (Thread.list - threads).count(&:alive?), Ractor.count - ractor_count]
            end
          end
        end
        Marshal.dump(result, writer)
        writer.close
        exit!(0)
      end
      writer.close

      assert_equal ["accept failed", 0, 0], Timeout.timeout(10) { Marshal.load(reader) }
      Process.wait(pid)
      assert_predicate $?, :success?
    ensure
      reader&.close
      writer&.close
      stop_cluster(pid)
    end

    def test_leaves_process_configuration_and_signal_handlers_unchanged
      handler = proc {}
      previous = Signal.trap("TERM", handler)
      directory = Dir.pwd
      environment = ENV.to_h
      stdout_sync = $stdout.sync
      stderr_sync = $stderr.sync
      @server = Embedded.new(->(_env) { [200, {}, []] }).start

      @server.shutdown

      assert_same handler, Signal.trap("TERM", previous)
      assert_equal directory, Dir.pwd
      assert_equal environment, ENV.to_h
      assert_equal stdout_sync, $stdout.sync
      assert_equal stderr_sync, $stderr.sync
    ensure
      Signal.trap("TERM", previous) if previous
    end
  end
end
