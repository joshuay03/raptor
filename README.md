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
[Raptor 39704|Main|Main] ├─ Version: 0.29.0
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

Raptor 0.29.0 vs Puma 8.0.2 vs Falcon 0.57.0. Each case has 3 fresh-process samples, interleaved in seeded shuffled
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
| Raptor | Fixed (3)      | -               | 3.35k ±1.4%  | -               | 47.84  | -             | 2.452      | 334.1   |
| Raptor | Scaling (3–16) | -               | 8.23k ±0.7%  | -               | 22.03  | -             | 0.467      | 320.5   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.41k ±1.4%  | 57.9% lower     | 133.47 | 179.0% higher | 0.765      | 272.0   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 8.15k ±0.6%  | 0.9% lower      | 22.20  | 0.7% higher   | 0.462      | 317.6   |
| Falcon | Fibers         | Fixed (3)       | 10.90k ±0.8% | 225.1% higher   | 15.68  | 67.2% lower   | 0.445      | 467.5   |
| Falcon | Fibers         | Scaling (3–16)  | 10.90k ±0.8% | 32.5% higher    | 15.68  | 28.8% lower   | 0.445      | 467.5   |

### IO over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.20k ±9.2% | -               | 50.70  | -             | 2.390      | 345.1   |
| Raptor | Scaling (3–16) | -               | 7.38k ±0.6% | -               | 24.60  | -             | 0.463      | 342.4   |
| Raptor | Fixed (16)     | -               | 7.52k ±0.0% | -               | 24.18  | -             | 0.457      | 338.3   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.39k ±1.4% | 56.7% lower     | 111.46 | 119.8% higher | 0.734      | 282.1   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 7.49k ±0.4% | 1.6% higher     | 24.20  | 1.6% lower    | 0.439      | 312.4   |
| Puma   | Fixed (16)     | Fixed (16)      | 7.57k ±0.9% | 0.6% higher     | 24.10  | 0.3% lower    | 0.429      | 318.1   |
| Falcon | Fibers         | Fixed (3)       | 7.44k ±1.4% | 132.3% higher   | 24.53  | 51.6% lower   | 0.384      | 334.2   |
| Falcon | Fibers         | Scaling (3–16)  | 7.44k ±1.4% | 0.8% higher     | 24.53  | 0.3% lower    | 0.384      | 334.2   |
| Falcon | Fibers         | Fixed (16)      | 7.44k ±1.4% | 1.1% lower      | 24.53  | 1.5% higher   | 0.384      | 334.2   |

### IO over HTTP/2

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 1.55k ±0.8% | -               | 120.06 | -             | 0.842      | 418.9   |
| Raptor | Scaling (3–16) | -               | 8.46k ±3.7% | -               | 21.77  | -             | 0.553      | 928.8   |
| Falcon | Fibers         | Fixed (3)       | 7.18k ±4.2% | 363.9% higher   | 26.01  | 78.3% lower   | 0.435      | 529.6   |
| Falcon | Fibers         | Scaling (3–16)  | 7.18k ±4.2% | 15.1% lower     | 26.01  | 19.5% higher  | 0.435      | 529.6   |

### CPU over HTTP/1.1

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.33k ±0.3% | -               | 68.91  | -             | 2.570      | 507.8   |
| Raptor | Scaling (3–16) | -               | 3.39k ±3.0% | -               | 62.76  | -             | 2.430      | 489.6   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.27k ±2.3% | 2.0% lower      | 56.55  | 17.9% lower   | 2.496      | 443.3   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 3.27k ±4.6% | 3.7% lower      | 48.35  | 23.0% lower   | 2.200      | 439.0   |
| Falcon | Fibers         | Fixed (3)       | 3.47k ±0.7% | 4.1% higher     | 47.50  | 31.1% lower   | 2.473      | 421.1   |
| Falcon | Fibers         | Scaling (3–16)  | 3.47k ±0.7% | 2.2% higher     | 47.50  | 24.3% lower   | 2.473      | 421.1   |

### CPU over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.12k ±0.4% | -               | 48.97  | -             | 2.570      | 476.6   |
| Raptor | Scaling (3–16) | -               | 3.02k ±2.0% | -               | 50.35  | -             | 2.593      | 504.5   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.51k ±0.9% | 12.5% higher    | 51.41  | 5.0% higher   | 2.346      | 381.8   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 2.94k ±4.4% | 2.8% lower      | 64.76  | 28.6% higher  | 2.243      | 469.3   |
| Falcon | Fibers         | Fixed (3)       | 3.13k ±0.6% | 0.1% higher     | 68.29  | 39.4% higher  | 2.806      | 536.3   |
| Falcon | Fibers         | Scaling (3–16)  | 3.13k ±0.6% | 3.4% higher     | 68.29  | 35.6% higher  | 2.806      | 536.3   |

### CPU over HTTP/2

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.45k ±3.9%  | -               | 67.62  | -             | 2.425      | 581.6   |
| Raptor | Scaling (3–16) | -               | 3.35k ±1.6%  | -               | 64.00  | -             | 2.409      | 584.6   |
| Falcon | Fibers         | Fixed (3)       | 2.71k ±28.6% | 21.6% lower     | 151.92 | 124.7% higher | 2.494      | 575.5   |
| Falcon | Fibers         | Scaling (3–16)  | 2.71k ±28.6% | 19.3% lower     | 151.92 | 137.4% higher | 2.494      | 575.5   |

### 64 KiB body over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Scaling (3–16) | -               | 93.53k ±1.0% | -               | 3.71   | -             | 0.052      | 501.2   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 84.26k ±0.5% | 9.9% lower      | 3.94   | 6.1% higher   | 0.056      | 1210.8  |
| Falcon | Fibers         | Scaling (3–16)  | 97.44k ±1.1% | 4.2% higher     | 3.96   | 6.7% higher   | 0.053      | 341.9   |

### IO + SSE (native) over HTTP/1.1 keep-alive

| Server        | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------------- | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor        | Fixed (3)      | -               | 3.16k ±12.5% | -               | 50.55  | -             | 2.374      | 347.8   |
| Raptor        | Scaling (3–16) | -               | 7.42k ±1.5%  | -               | 24.45  | -             | 0.470      | 341.1   |
| Puma          | Fixed (3)      | Fixed (3)       | 0.34k ±5.3%  | 89.3% lower     | 328.18 | 549.2% higher | 1.712      | 243.8   |
| Puma          | Scaling (3–16) | Scaling (3–16)  | 7.44k ±3.6%  | 0.2% higher     | 24.32  | 0.5% lower    | 0.435      | 311.0   |
| Falcon        | Fibers         | Fixed (3)       | 7.58k ±4.2%  | 140.0% higher   | 24.24  | 52.0% lower   | 0.385      | 335.5   |
| Falcon        | Fibers         | Scaling (3–16)  | 7.58k ±4.2%  | 2.2% higher     | 24.24  | 0.9% lower    | 0.385      | 335.5   |
| Raptor (enum) | Fixed (3)      | -               | 0.88k ±4.2%  | -               | 63.87  | -             | 8.136      | 330.3   |

Puma, Fixed (3) had 57 timeouts, 1 stalled stream across all samples.

Raptor (enum), Fixed (3) had 8 timeouts, 1 stalled stream across all samples.

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
