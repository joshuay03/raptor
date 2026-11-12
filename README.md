# Raptor

Raptor is a high-performance, preloading, pre-forking, multi-threaded Ruby 4+ web server implementing Rack 3.2+, using
io-event for non-blocking I/O and Ractors for parallel HTTP/1.1 and HTTP/2 parsing via native C extensions, which also
implement HPACK compression.

> [!NOTE]
> **Your application does not need to be Ractor-safe.** Ractors handle protocol-level work only; your Rack application
> is invoked on a thread pool, so any thread-safe Rack app (including Rails) works as-is.

Reference documentation is published at <https://joshuay03.github.io/raptor>.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add raptor
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install raptor
```

## Usage

```ruby
# hello_world.ru

# frozen_string_literal: true

run proc { |_env| [200, { "content-type" => "text/plain" }, ["Hello, World!"]] }
```

```
> bundle exec raptor -w 10 -t 3 hello_world.ru
[Raptor 39704|Main|Main] Cluster initializing:
[Raptor 39704|Main|Main] ├─ Version: 0.27.0
[Raptor 39704|Main|Main] ├─ Ruby Version: ruby 4.0.9 (2026-10-23 revision 3e93b23afc) +YJIT +PRISM [arm64-darwin25]
[Raptor 39704|Main|Main] ├─ Environment: development
[Raptor 39704|Main|Main] ├─ Master PID: 39704
[Raptor 39704|Main|Main] │  └─ 10 worker processes
[Raptor 39704|Main|Main] │     ├─ 1 server thread
[Raptor 39704|Main|Main] │     ├─ 1 reactor thread
[Raptor 39704|Main|Main] │     ├─ 1 HTTP/1.1 pipeline ractor
[Raptor 39704|Main|Main] │     ├─ 1 pipeline collector thread
[Raptor 39704|Main|Main] │     ├─ 3 worker threads (scaling, no limit)
[Raptor 39704|Main|Main] │     └─ 1 stats thread
[Raptor 39704|Main|Main] └─ Listening on 0.0.0.0:9292
[Raptor 39720|Main|Main] Worker 1 booted
[Raptor 39719|Main|Main] Worker 0 booted
[Raptor 39722|Main|Main] Worker 3 booted
[Raptor 39721|Main|Main] Worker 2 booted
[Raptor 39723|Main|Main] Worker 4 booted
[Raptor 39725|Main|Main] Worker 6 booted
[Raptor 39724|Main|Main] Worker 5 booted
[Raptor 39728|Main|Main] Worker 8 booted
[Raptor 39726|Main|Main] Worker 7 booted
[Raptor 39730|Main|Main] Worker 9 booted
```

```
> curl localhost:9292
Hello, World!%   
```

Also works with `rackup` and `rails server`:

```
> bundle exec rackup -s raptor hello_world.ru
> bundle exec rails server -u raptor
```

Rails apps using `SOLID_QUEUE_IN_PUMA` run jobs through `config/puma.rb`, which Raptor does not load. Run `bin/jobs` as
a separately supervised process or container instead.

### Rails system tests

Use Raptor as Capybara's server without forking, so Rails can share transactional test data with browser requests.
Add this to your system test setup, alongside your browser driver configuration:

```ruby
require "rackup"
require "rackup/handler/raptor"

Capybara.register_server :raptor do |app, port, host|
  Rackup::Handler::Raptor.run(app, Host: host, Port: port, Workers: 0) do |server|
    at_exit { server.shutdown }
  end
end
Capybara.server = :raptor
```

The exit hook shuts the server down before Ruby tears down its background threads.

For other in-process uses, `require "raptor/embedded"` and call `Raptor::Embedded.new(app, host: "127.0.0.1", port: 0)`.
`start` returns when serving is ready, `port` reports the bound port, `shutdown` drains requests and releases resources,
and `join` waits for termination. Call `shutdown` before process exit. The embedded server leaves signal handlers and
process-wide configuration to its caller. Cluster plugins and process lifecycle hooks do not run in this mode.

## Configuration

Raptor reads options from a Ruby config file, environment variables, and command line flags, in increasing order of
precedence. Run `bundle exec raptor --help` for the full flag list.

The config file evaluates to a hash of options. By default Raptor loads `raptor.rb` then `config/raptor.rb` from the
working directory. Pass `-c PATH` to point at a specific file.

```ruby
# raptor.rb

# Every key below is set to its default value; only include the ones you want to override.
{
  binds: ["tcp://0.0.0.0:9292"],
  socket_backlog: 1024,
  drain_accept_queue: false,
  workers: 4, # `Etc.nprocessors`
  threads: 3,
  max_threads: Float::INFINITY, # set to `threads` for a fixed pool
  cpu_affinity: false,
  clean_thread_locals: true,
  clean_fiber_locals: false,
  chdir: nil,
  environment: nil, # falls back to `RAILS_ENV`, then `RACK_ENV`, then `"development"`
  connection: {
    first_data_timeout: 30,
    chunk_data_timeout: 10,
    write_timeout: 5,
    max_body_size: nil,
    body_spool_threshold: 1024 * 1024,
  },
  http1: {
    ractors: nil,
    persistent_data_timeout: 65,
    max_keepalive_requests: 1000,
  },
  http2: {
    ractors: nil,
    max_concurrent_streams: 100,
    keepalive_interval: 10,
    keepalive_timeout: 5,
  },
  worker_boot_timeout: 60,
  worker_timeout: 60,
  worker_drain_timeout: 25,
  worker_shutdown_timeout: 30,
  refork_after: 1000, # `nil` on non-Linux
  before_fork: [],
  after_fork: [],
  before_worker_boot: [],
  after_worker_boot: [],
  before_worker_shutdown: [],
  after_worker_drain: [],
  after_worker_exit: [],
  before_refork: [],
  before_seed_fork: [],
  after_seed_fork: [],
  plugins: [],
  stats_file: "tmp/raptor.json",
  control_url: nil,
  pid_file: nil,
  stdout_file: nil,
  stderr_file: nil,
  access_log_file: nil,
}
```

`RAPTOR_WORKERS`, `RAPTOR_THREADS`, and `RAPTOR_MAX_THREADS` set the corresponding options without a config file.

By default each worker adds threads beyond `threads` only while queued requests are waiting on blocking work such as
database or network calls. It stops adding them once Ruby execution becomes the bottleneck, and the extra threads
retire when the queue is idle. Set `max_threads` to cap this growth, or set it to `threads` for a fixed pool.

## Plugins

Plugins start in the master process and can register lifecycle hooks that run in workers. Use them for metrics
exporters, probes, or other integrations. Enable them in your config with `plugins: [:stats_logger]`.

Raptor loads each name from `raptor/plugin/<name>` on Ruby's load path. A gem can provide that file, or you can require
an application-local plugin before returning the config hash.

```ruby
# lib/raptor/plugin/stats_logger.rb
require "raptor/plugin"

Raptor::Plugin.create(:stats_logger) do
  def start(cluster)
    in_background do
      loop do
        Raptor::Log.info(JSON.generate(cluster.stats_hash))
        sleep 10
      end
    end
  end
end
```

`cluster.options` exposes configuration and lifecycle hooks. `cluster.stats` and `cluster.stats_hash` provide worker
and aggregate statistics. Override `stop` to release plugin resources after workers exit, including during hot restart.
See the [API documentation](https://joshuay03.github.io/raptor/Raptor/Plugin.html) for lifecycle details.

## Bindings

`binds` accepts any combination of these URIs.

- `tcp://host:port` for TCP. `localhost` binds both IPv4 and IPv6 loopback addresses.
- `unix:///path/to/socket` for a Unix domain socket.
- `ssl://host:port?cert=/path/to.crt&key=/path/to.key` for TLS, negotiating HTTP/1.1 or HTTP/2 via ALPN.
- `h2c://host:port` for cleartext HTTP/2.

## Signals

Send to the master process.

| Signal | Effect                                                      |
| ------ | ----------------------------------------------------------- |
| `INT`  | Graceful shutdown                                           |
| `TERM` | Graceful shutdown                                           |
| `HUP`  | Reopen `stdout_file`, `stderr_file`, and `access_log_file`  |
| `USR1` | Phased restart (rolling worker replacement)                 |
| `USR2` | Hot restart (restart master, keeping listening sockets)     |

A phased restart replaces workers one at a time while the master keeps running, picking up application code changes.
A hot restart starts a new master with the original command line and the same listening sockets, picking up changes
to configuration, dependencies, or Raptor itself.

## systemd

Raptor supports socket activation and `sd_notify`, so it works with `Type=notify` units. When the socket unit is
active, Raptor serves the listening sockets systemd passes in place of `binds`. Raptor sends `READY=1` after all
workers have finished booting, including their `before_worker_boot` hooks.

```ini
# /etc/systemd/system/myapp.socket
[Socket]
ListenStream=0.0.0.0:9292

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/myapp.service
[Service]
Type=notify
WorkingDirectory=/srv/myapp
ExecStart=/usr/bin/bundle exec raptor
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
```

## Stats

Workers publish their stats to `stats_file`, which defaults to `tmp/raptor.json`.

```
> bundle exec raptor stats
Master PID: 91348
Worker 0 (phase 0): pid=91350, requests=1234, busy=2/3, backlog=0, booted, last_checkin=10:42:01
Worker 1 (phase 0): pid=91351, requests=1199, busy=1/3, backlog=0, booted, last_checkin=10:42:01
...
```

Set `control_url` to a Unix socket URL such as `unix:///tmp/raptor-control.sock` to serve the same stats over
`GET /stats`.

The bundled `statsd` plugin exports aggregate gauges and a `requests` counter without additional dependencies.
Enable it in your configuration file.

```ruby
{
  plugins: [:statsd],
  statsd: { host: "127.0.0.1", port: 8125, interval: 2, namespace: "raptor", tags: [] }
}
```

Use `socket_path` instead of `host` and `port` for Unix datagrams. Delivery is best effort, based on sampled worker
statistics. The exporter handles worker forks and restart cleanup automatically.

## (Micro) Benchmarks

Raptor 0.27.0 vs Puma 8.0.2 vs Falcon 0.57.0. Each case has 3 fresh-process samples, interleaved in seeded shuffled
rounds. Each sample warms up for 3s and measures for 15s. Metrics are independent medians. ± is (max − min) / 2 /
median, not a confidence interval. Failure counts below each table sum all samples, so a failed run cannot disappear in
a median. Throughput counts successful ordinary requests only.

Comparison columns show each server's change from Raptor's median for the baseline mode. Higher req/s is better. Lower
p95 is better. Falcon's measurements are repeated against each Raptor mode, not rerun.

**IO** interleaves 5–10 sleeps of 0.5–1.5ms with small JSON renders. **CPU** interleaves 3–5 larger JSON renders with
25–50µs sleeps. Both discard the rendered JSON and return a short response. **64 KiB body** sends a prebuilt response to
isolate response transfer. **SSE (native)** uses Raptor's detached body versus blocking Enumerators. **Raptor (enum)**
uses the same blocking body as Puma and Falcon, reusing their existing samples for comparison. The 20 streams are
cluster-wide connections, not guaranteed to be evenly placed. Streams without complete headers after 2s remain connected
and are counted as stalled.

Fixed (3), Scaling (3–16), and the IO-only Fixed (16) control separate tight concurrency, pool growth, and a prestarted
larger pool. Falcon uses unbounded fibers and runs once per workload/protocol. Raptor request-local cleanup, CPU
affinity, and reforking, and Puma's Fiber-per-request mode are disabled. Both threaded servers allow 999 requests per
keep-alive connection.

CPU includes the server master and descendants, including SSE event production, but excludes client CPU and warmup. CPU
ms/req divides that CPU time by successful ordinary requests. Peak aggregate PSS is sampled every 0.5s, proportionally
accounting for shared pages instead of counting them fully in every worker.

### IO over HTTP/1.1

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.35k ±1.2%  | -               | 49.00  | -             | 2.421      | 337.8   |
| Raptor | Scaling (3–16) | -               | 8.21k ±0.6%  | -               | 22.09  | -             | 0.468      | 323.6   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.53k ±0.7%  | 54.4% lower     | 120.94 | 146.8% higher | 0.969      | 272.0   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 8.15k ±0.5%  | 0.7% lower      | 22.23  | 0.6% higher   | 0.467      | 319.5   |
| Falcon | Fibers         | Fixed (3)       | 11.07k ±0.5% | 230.3% higher   | 15.44  | 68.5% lower   | 0.439      | 446.6   |
| Falcon | Fibers         | Scaling (3–16)  | 11.07k ±0.5% | 34.8% higher    | 15.44  | 30.1% lower   | 0.439      | 446.6   |

### IO over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.09k ±6.5% | -               | 51.42  | -             | 2.346      | 348.9   |
| Raptor | Scaling (3–16) | -               | 7.39k ±0.6% | -               | 24.67  | -             | 0.465      | 344.2   |
| Raptor | Fixed (16)     | -               | 7.48k ±0.5% | -               | 24.30  | -             | 0.453      | 344.1   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.49k ±0.4% | 51.7% lower     | 100.59 | 95.6% higher  | 1.009      | 282.5   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 7.39k ±0.4% | 0.0% higher     | 24.58  | 0.4% lower    | 0.434      | 310.0   |
| Puma   | Fixed (16)     | Fixed (16)      | 7.52k ±0.4% | 0.5% higher     | 24.16  | 0.6% lower    | 0.428      | 316.3   |
| Falcon | Fibers         | Fixed (3)       | 7.34k ±2.1% | 137.4% higher   | 24.78  | 51.8% lower   | 0.382      | 329.6   |
| Falcon | Fibers         | Scaling (3–16)  | 7.34k ±2.1% | 0.7% lower      | 24.78  | 0.4% higher   | 0.382      | 329.6   |
| Falcon | Fibers         | Fixed (16)      | 7.34k ±2.1% | 1.9% lower      | 24.78  | 2.0% higher   | 0.382      | 329.6   |

### IO over HTTP/2

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 1.61k ±0.3% | -               | 131.78 | -             | 0.901      | 410.2   |
| Raptor | Scaling (3–16) | -               | 7.24k ±8.6% | -               | 30.21  | -             | 0.563      | 940.4   |
| Falcon | Fibers         | Fixed (3)       | 7.82k ±1.7% | 386.4% higher   | 25.75  | 80.5% lower   | 0.426      | 526.6   |
| Falcon | Fibers         | Scaling (3–16)  | 7.82k ±1.7% | 8.0% higher     | 25.75  | 14.7% lower   | 0.426      | 526.6   |

### CPU over HTTP/1.1

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.40k ±1.5% | -               | 66.74  | -             | 2.519      | 511.8   |
| Raptor | Scaling (3–16) | -               | 3.45k ±3.9% | -               | 62.67  | -             | 2.389      | 504.6   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.24k ±0.9% | 4.7% lower      | 57.00  | 14.6% lower   | 2.457      | 444.5   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 3.09k ±2.7% | 10.4% lower     | 49.54  | 21.0% lower   | 2.182      | 437.4   |
| Falcon | Fibers         | Fixed (3)       | 3.53k ±0.8% | 3.8% higher     | 47.04  | 29.5% lower   | 2.430      | 432.3   |
| Falcon | Fibers         | Scaling (3–16)  | 3.53k ±0.8% | 2.2% higher     | 47.04  | 24.9% lower   | 2.430      | 432.3   |

### CPU over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.12k ±0.3% | -               | 50.35  | -             | 2.534      | 483.3   |
| Raptor | Scaling (3–16) | -               | 2.99k ±2.1% | -               | 50.79  | -             | 2.532      | 502.5   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.49k ±6.5% | 11.7% higher    | 51.75  | 2.8% higher   | 2.319      | 383.4   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 3.00k ±3.8% | 0.5% higher     | 64.39  | 26.8% higher  | 2.224      | 470.8   |
| Falcon | Fibers         | Fixed (3)       | 3.17k ±0.2% | 1.7% higher     | 67.10  | 33.3% higher  | 2.763      | 529.6   |
| Falcon | Fibers         | Scaling (3–16)  | 3.17k ±0.2% | 6.1% higher     | 67.10  | 32.1% higher  | 2.763      | 529.6   |

### CPU over HTTP/2

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.32k ±3.7%  | -               | 70.25  | -             | 2.374      | 583.2   |
| Raptor | Scaling (3–16) | -               | 3.31k ±0.9%  | -               | 60.05  | -             | 2.347      | 562.3   |
| Falcon | Fibers         | Fixed (3)       | 2.36k ±18.9% | 29.0% lower     | 127.17 | 81.0% higher  | 2.399      | 561.8   |
| Falcon | Fibers         | Scaling (3–16)  | 2.36k ±18.9% | 28.8% lower     | 127.17 | 111.8% higher | 2.399      | 561.8   |

### 64 KiB body over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s         | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Scaling (3–16) | -               | 94.57k ±1.5%  | -               | 3.70   | -             | 0.051      | 592.0   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 88.51k ±0.7%  | 6.4% lower      | 3.67   | 0.6% lower    | 0.054      | 1201.7  |
| Falcon | Fibers         | Scaling (3–16)  | 103.00k ±5.1% | 8.9% higher     | 3.84   | 3.9% higher   | 0.051      | 341.1   |

### IO + SSE (native) over HTTP/1.1 keep-alive

| Server        | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------------- | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor        | Fixed (3)      | -               | 2.74k ±6.2% | -               | 59.25  | -             | 2.298      | 341.5   |
| Raptor        | Scaling (3–16) | -               | 7.41k ±1.2% | -               | 24.53  | -             | 0.471      | 345.4   |
| Puma          | Fixed (3)      | Fixed (3)       | 0.34k ±5.4% | 87.5% lower     | 361.94 | 510.8% higher | 1.715      | 263.9   |
| Puma          | Scaling (3–16) | Scaling (3–16)  | 7.34k ±1.0% | 1.0% lower      | 24.70  | 0.7% higher   | 0.430      | 310.9   |
| Falcon        | Fibers         | Fixed (3)       | 7.30k ±1.0% | 165.9% higher   | 24.88  | 58.0% lower   | 0.379      | 356.6   |
| Falcon        | Fibers         | Scaling (3–16)  | 7.30k ±1.0% | 1.6% lower      | 24.88  | 1.5% higher   | 0.379      | 356.6   |
| Raptor (enum) | Fixed (3)      | -               | 0.88k ±0.3% | -               | 66.74  | -             | 8.142      | 382.6   |

Puma, Fixed (3) had 37 timeouts, 1 stalled stream across all samples.

Raptor (enum), Fixed (3) had 16 timeouts across all samples.

> ruby 4.1.0dev (2026-11-10T00:02:04Z HEAD 7a07e456e4) +YJIT +PRISM [aarch64-linux]
> 10 workers, 120 HTTP/1.1 client connections, 40 HTTP/2 connections × 3 streams.

Run [bin/benchmark](bin/benchmark) to reproduce.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bundle exec rake` to compile native
extensions and run the tests. You can also run `bin/console` for an interactive prompt that will allow you to
experiment.

On macOS (or any non-Linux host), `bin/dev` builds and drops you into a Docker image with Ruby and the required Linux
toolchain preinstalled, mounting the repo at `/workspace`. Run `bin/dev` for an interactive shell, or
`bin/dev <command>` for one-off commands like `bin/dev bundle exec rake` or `bin/dev bin/benchmark`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/joshuay03/raptor. This project is intended to
be a safe, welcoming space for collaboration, and contributors are expected to adhere to the
[code of conduct](https://github.com/joshuay03/raptor/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Raptor project's codebases, issue trackers, chat rooms and mailing lists is expected to
follow the [code of conduct](https://github.com/joshuay03/raptor/blob/main/CODE_OF_CONDUCT.md).
