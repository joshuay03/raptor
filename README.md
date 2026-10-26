# Raptor

Raptor is a high-performance, preloading, pre-forking, multi-threaded Ruby 4+ web server implementing Rack 3.2+, using
NIO for non-blocking I/O and Ractors for parallel HTTP/1.1 and HTTP/2 parsing via native C extensions, which also
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
[Raptor 39704|Main|Main] ├─ Version: 0.23.0
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
  before_worker_boot: [],
  before_worker_shutdown: [],
  before_refork: [],
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
active, Raptor serves the listening sockets systemd passes in place of `binds`.

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

## (Micro) Benchmarks

Raptor 0.23.0 vs Puma 8.0.2 vs Falcon 0.57.0. Each case has 3 fresh-process samples, interleaved in seeded shuffled
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
| Raptor | Fixed (3)      | -               | 3.41k ±0.3%  | -               | 45.86  | -             | 2.418      | 352.5   |
| Raptor | Scaling (3–16) | -               | 8.15k ±0.3%  | -               | 22.23  | -             | 0.472      | 339.9   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.55k ±0.9%  | 54.6% lower     | 116.06 | 153.1% higher | 0.953      | 296.2   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 8.14k ±0.5%  | 0.1% lower      | 22.27  | 0.2% higher   | 0.467      | 343.4   |
| Falcon | Fibers         | Fixed (3)       | 11.24k ±0.5% | 229.9% higher   | 15.16  | 66.9% lower   | 0.427      | 462.2   |
| Falcon | Fibers         | Scaling (3–16)  | 11.24k ±0.5% | 37.9% higher    | 15.16  | 31.8% lower   | 0.427      | 462.2   |

### IO over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.40k ±2.4% | -               | 36.30  | -             | 2.425      | 365.9   |
| Raptor | Scaling (3–16) | -               | 7.42k ±2.0% | -               | 24.27  | -             | 0.461      | 362.8   |
| Raptor | Fixed (16)     | -               | 7.49k ±0.9% | -               | 24.07  | -             | 0.446      | 367.4   |
| Puma   | Fixed (3)      | Fixed (3)       | 1.49k ±0.8% | 56.1% lower     | 108.05 | 197.7% higher | 1.013      | 302.0   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 7.34k ±0.1% | 1.1% lower      | 24.67  | 1.6% higher   | 0.423      | 346.4   |
| Puma   | Fixed (16)     | Fixed (16)      | 7.62k ±0.2% | 1.8% higher     | 23.70  | 1.5% lower    | 0.423      | 352.8   |
| Falcon | Fibers         | Fixed (3)       | 7.35k ±2.4% | 116.6% higher   | 24.51  | 32.5% lower   | 0.375      | 317.6   |
| Falcon | Fibers         | Scaling (3–16)  | 7.35k ±2.4% | 0.9% lower      | 24.51  | 1.0% higher   | 0.375      | 317.6   |
| Falcon | Fibers         | Fixed (16)      | 7.35k ±2.4% | 1.8% lower      | 24.51  | 1.9% higher   | 0.375      | 317.6   |

### IO over HTTP/2

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 1.59k ±0.5%  | -               | 137.45 | -             | 0.928      | 414.4   |
| Raptor | Scaling (3–16) | -               | 7.17k ±11.3% | -               | 29.93  | -             | 0.544      | 916.8   |
| Falcon | Fibers         | Fixed (3)       | 7.13k ±3.5%  | 347.2% higher   | 27.05  | 80.3% lower   | 0.425      | 496.1   |
| Falcon | Fibers         | Scaling (3–16)  | 7.13k ±3.5%  | 0.5% lower      | 27.05  | 9.6% lower    | 0.425      | 496.1   |

### CPU over HTTP/1.1

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.61k ±2.0% | -               | 62.23  | -             | 2.384      | 484.7   |
| Raptor | Scaling (3–16) | -               | 3.54k ±2.1% | -               | 58.68  | -             | 2.347      | 505.5   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.29k ±0.5% | 8.9% lower      | 54.53  | 12.4% lower   | 2.414      | 482.6   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 2.89k ±1.0% | 18.4% lower     | 53.12  | 9.5% lower    | 2.311      | 550.0   |
| Falcon | Fibers         | Fixed (3)       | 3.86k ±0.3% | 6.9% higher     | 42.79  | 31.2% lower   | 2.227      | 381.3   |
| Falcon | Fibers         | Scaling (3–16)  | 3.86k ±0.3% | 8.9% higher     | 42.79  | 27.1% lower   | 2.227      | 381.3   |

### CPU over HTTP/1.1 keep-alive

| Server | Mode           | Raptor baseline | req/s       | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ----------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.12k ±4.6% | -               | 53.11  | -             | 2.541      | 522.7   |
| Raptor | Scaling (3–16) | -               | 3.09k ±1.2% | -               | 50.46  | -             | 2.480      | 529.8   |
| Puma   | Fixed (3)      | Fixed (3)       | 3.61k ±1.3% | 15.7% higher    | 48.24  | 9.2% lower    | 2.246      | 408.7   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 2.88k ±1.3% | 6.6% lower      | 63.29  | 25.4% higher  | 2.228      | 492.4   |
| Falcon | Fibers         | Fixed (3)       | 3.75k ±1.0% | 20.1% higher    | 60.37  | 13.7% higher  | 2.338      | 556.5   |
| Falcon | Fibers         | Scaling (3–16)  | 3.75k ±1.0% | 21.4% higher    | 60.37  | 19.6% higher  | 2.338      | 556.5   |

### CPU over HTTP/2

| Server | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Fixed (3)      | -               | 3.70k ±4.9%  | -               | 58.06  | -             | 2.267      | 594.4   |
| Raptor | Scaling (3–16) | -               | 3.37k ±1.4%  | -               | 64.86  | -             | 2.239      | 632.4   |
| Falcon | Fibers         | Fixed (3)       | 2.79k ±25.3% | 24.6% lower     | 131.81 | 127.0% higher | 2.121      | 546.9   |
| Falcon | Fibers         | Scaling (3–16)  | 2.79k ±25.3% | 17.2% lower     | 131.81 | 103.2% higher | 2.121      | 546.9   |

### 64 KiB body over HTTP/1.1 keep-alive

This case was rerun on Ruby 4.1-dev (`33ac6afea7`); the other cases use `cda3527671`.

| Server | Mode           | Raptor baseline | req/s         | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------ | -------------- | --------------- | ------------- | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor | Scaling (3–16) | -               | 102.11k ±0.4% | -               | 3.37   | -             | 0.047      | 513.5   |
| Puma   | Scaling (3–16) | Scaling (3–16)  | 88.55k ±0.6%  | 13.3% lower     | 3.63   | 7.9% higher   | 0.054      | 1371.1  |
| Falcon | Fibers         | Scaling (3–16)  | 104.10k ±0.5% | 2.0% higher     | 3.81   | 13.2% higher  | 0.051      | 520.9   |

### IO + SSE (native) over HTTP/1.1 keep-alive

| Server        | Mode           | Raptor baseline | req/s        | vs Raptor req/s | p95 ms | vs Raptor p95 | CPU ms/req | PSS MiB |
| ------------- | -------------- | --------------- | ------------ | --------------- | ------ | ------------- | ---------- | ------- |
| Raptor        | Fixed (3)      | -               | 3.46k ±6.8%  | -               | 35.01  | -             | 2.431      | 374.8   |
| Raptor        | Scaling (3–16) | -               | 7.48k ±0.4%  | -               | 24.11  | -             | 0.456      | 371.6   |
| Puma          | Fixed (3)      | Fixed (3)       | 0.35k ±5.0%  | 90.0% lower     | 317.72 | 807.6% higher | 1.711      | 264.7   |
| Puma          | Scaling (3–16) | Scaling (3–16)  | 7.14k ±4.3%  | 4.5% lower      | 25.45  | 5.6% higher   | 0.419      | 342.9   |
| Falcon        | Fibers         | Fixed (3)       | 7.28k ±0.7%  | 110.5% higher   | 25.00  | 28.6% lower   | 0.374      | 332.1   |
| Falcon        | Fibers         | Scaling (3–16)  | 7.28k ±0.7%  | 2.6% lower      | 25.00  | 3.7% higher   | 0.374      | 332.1   |
| Raptor (enum) | Fixed (3)      | -               | 0.89k ±15.9% | -               | 59.24  | -             | 8.100      | 363.8   |

Puma, Fixed (3) had 54 timeouts, 1 stalled stream across all samples.

Raptor (enum), Fixed (3) had 21 timeouts across all samples.

> ruby 4.1.0dev (2026-10-27T07:37:34Z HEAD cda3527671) +YJIT +PRISM [aarch64-linux]
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
