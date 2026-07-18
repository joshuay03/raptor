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
> bundle exec raptor -w 4 -t 3 hello_world.ru
[Raptor 76577|Main|Main] Cluster initializing:
[Raptor 76577|Main|Main] ├─ Version: 0.11.0
[Raptor 76577|Main|Main] ├─ Ruby Version: ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +YJIT +PRISM [arm64-darwin23]
[Raptor 76577|Main|Main] ├─ Environment: development
[Raptor 76577|Main|Main] ├─ Master PID: 76577
[Raptor 76577|Main|Main] │  └─ 4 worker processes
[Raptor 76577|Main|Main] │     ├─ 1 server thread
[Raptor 76577|Main|Main] │     ├─ 1 reactor thread
[Raptor 76577|Main|Main] │     ├─ 1 pipeline ractor
[Raptor 76577|Main|Main] │     ├─ 1 pipeline collector thread
[Raptor 76577|Main|Main] │     ├─ 3 worker threads
[Raptor 76577|Main|Main] │     └─ 1 stats thread
[Raptor 76577|Main|Main] └─ Listening on 0.0.0.0:9292
[Raptor 76579|Main|Main] Worker 0 booted
[Raptor 76580|Main|Main] Worker 1 booted
[Raptor 76581|Main|Main] Worker 2 booted
[Raptor 76582|Main|Main] Worker 3 booted
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

## Configuration

Raptor accepts configuration via command-line flags, a Ruby config file, or both (CLI flags override config file
values). Run `bundle exec raptor --help` for the full flag list.

The config file is a Ruby file that evaluates to a hash of options. By default Raptor loads `raptor.rb` then
`config/raptor.rb` from the working directory; pass `-c PATH` to point at a specific file. Settings are nested under
`connection:` (shared across protocols), `http1:` (HTTP/1.1-specific), and `http2:` (HTTP/2-specific).

```ruby
# raptor.rb

# Every key below is set to its default value; only include the ones you want to override.
{
  binds: ["tcp://0.0.0.0:9292"],
  socket_backlog: 1024,
  drain_accept_queue: false,
  workers: 4, # `Etc.nprocessors`
  ractors: 1,
  threads: 3,
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
    persistent_data_timeout: 65,
    max_keepalive_requests: 100,
  },
  http2: {
    max_concurrent_streams: 100,
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
  pid_file: nil,
  stdout_file: nil,
  stderr_file: nil,
  access_log_file: nil,
}
```

## Bindings

Raptor accepts multiple `binds:` URIs across three schemes.

- `tcp://host:port` for TCP. Host can be a specific IP, `0.0.0.0` / `[::]`, or `localhost` (expanded to both IPv4 and
  IPv6 loopback addresses).
- `unix:///path/to/socket` for a Unix domain socket. Stale sockets left by crashed processes are cleaned up
  automatically.
- `ssl://host:port?cert=/path/to.crt&key=/path/to.key` for TLS. HTTP/1.1 and HTTP/2 are negotiated via ALPN.

Multiple binds can be combined freely.

## Signals

Send to the master process.

| Signal | Effect                                                      |
| ------ | ----------------------------------------------------------- |
| `INT`  | Graceful shutdown                                           |
| `TERM` | Graceful shutdown                                           |
| `HUP`  | Reopen `stdout_file`, `stderr_file`, and `access_log_file`  |
| `USR1` | Phased restart (rolling worker replacement)                 |
| `USR2` | Hot restart (re-exec master, inheriting listening sockets)  |

## Restarts

- **Phased restart** (`USR1`) replaces workers one at a time, waiting for each new worker to boot before retiring the
  previous one. The master process keeps running, so existing workers continue serving until they are individually
  replaced. Use to pick up code changes that don't affect the master's boot path.
- **Hot restart** (`USR2`) re-execs the master process with its original command line, inheriting the listening sockets
  so accepted connections continue to be served across the swap. The successor master re-runs initialization from
  scratch. Use to pick up changes that affect master-level state (config layout, dependency upgrades, Raptor itself).

## systemd

Raptor implements socket activation (`LISTEN_FDS`) and `sd_notify`, so it integrates cleanly with `Type=notify` units.
When the socket unit is active, systemd hands the pre-bound listening file descriptors to Raptor, which serves them in
place of `binds:`. `READY=1`, `STOPPING=1`, and `RELOADING=1` lifecycle messages are emitted automatically.

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

Each worker writes per-worker stats (request count, busy threads, backlog, last check-in) to shared memory and to a
JSON file (default `tmp/raptor.json`; set via `stats_file`).

```
> bundle exec raptor stats
Master PID: 91348
Worker 0 (phase 0): pid=91350, requests=1234, busy=2/3, backlog=0, booted, last_checkin=10:42:01
Worker 1 (phase 0): pid=91351, requests=1199, busy=1/3, backlog=0, booted, last_checkin=10:42:01
...
```

## (Micro) Benchmarks

Raptor 0.11.0 vs Puma 8.0.2 vs Falcon 0.55.5 across two workload profiles. **IO-bound** is a GET endpoint that
interleaves 5-10 short sleeps (total 2.5-15ms) with small CPU work, simulating a read path that makes several DB or
cache calls. **CPU-bound** is a POST endpoint that accepts a small JSON body, interleaves 3-5 chunks of JSON item
building (total 450-1500 items) with sub-100µs sleeps, and returns the built array, simulating a write path that does
most of its work in Ruby with a few near-zero-cost cache hits.

Each cell reports the median throughput and median p95 latency independently across 5 runs, so the two numbers in a row
may come from different runs. Every run starts a fresh server process so the samples are independent of each other;
state accumulated in a previous run cannot bias the next. Across the whole table, the widest spread
((max - min) / 2 / median) between runs of a single cell was ±46.2% for throughput
and ±38.2% for p95.

| Protocol              | Workload | Raptor req/s | Raptor p95 | Puma req/s  | Puma p95 | vs Puma req/s | vs Puma p95 | Falcon req/s | Falcon p95 | vs Falcon req/s | vs Falcon p95 |
| --------------------- | -------- | ------------ | ---------- | ----------- | -------- | ------------- | ----------- | ------------ | ---------- | --------------- | ------------- |
| HTTP/1.1              | IO       | 1.36k req/s  | 52.50 ms   | 0.98k req/s | 64.00 ms | +39.1%        | -18.0%      | 4.54k req/s  | 15.10 ms   | -70.0%          | +247.7%       |
| HTTP/1.1              | CPU      | 3.54k req/s  | 27.70 ms   | 3.66k req/s | 16.50 ms | -3.2%         | +67.9%      | 3.76k req/s  | 15.50 ms   | -5.7%           | +78.7%        |
| HTTP/1.1 (keep-alive) | IO       | 1.34k req/s  | 35.10 ms   | 0.96k req/s | 63.70 ms | +38.7%        | -44.9%      | 4.12k req/s  | 16.50 ms   | -67.5%          | +112.7%       |
| HTTP/1.1 (keep-alive) | CPU      | 4.24k req/s  | 11.40 ms   | 3.80k req/s | 17.40 ms | +11.6%        | -34.5%      | 3.83k req/s  | 17.10 ms   | +10.8%          | -33.3%        |
| HTTP/2                | IO       | 0.99k req/s  | 78.02 ms   | N/A         | N/A      | -             | -           | 3.88k req/s  | 17.57 ms   | -74.4%          | +344.1%       |
| HTTP/2                | CPU      | 4.18k req/s  | 18.89 ms   | N/A         | N/A      | -             | -           | 2.96k req/s  | 29.16 ms   | +41.1%          | -35.2%        |

> ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +YJIT +PRISM [aarch64-linux]
> 4 worker processes; Raptor and Puma run 3 threads per worker, Falcon runs unbounded fibers per worker;
> 48 concurrent HTTP/1.1 client connections; 16 concurrent HTTP/2 client connections × 3 streams each

See [bin/benchmark](bin/benchmark) for more details.

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
