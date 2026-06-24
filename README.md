# Raptor

Raptor is a high-performance, preloading, pre-forking, multi-threaded Ruby 4+ web server implementing Rack 3.2+, using
NIO for non-blocking I/O and Ractors for parallel HTTP/1.1 and HTTP/2 parsing via native C extensions, which also
implement HPACK compression.

> [!NOTE]
> **Your application does not need to be Ractor-safe.** Ractors handle protocol-level work only; your Rack application
> is invoked on a thread pool, so any thread-safe Rack app (including Rails) works as-is.

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
[Raptor 91348|main|main] Cluster initializing:
[Raptor 91348|main|main] ├─ Version: 0.7.0
[Raptor 91348|main|main] ├─ Ruby Version: ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +YJIT +PRISM [arm64-darwin23]
[Raptor 91348|main|main] ├─ Master PID: 91348
[Raptor 91348|main|main] │  └─ 4 worker processes
[Raptor 91348|main|main] │     ├─ 1 server thread
[Raptor 91348|main|main] │     ├─ 1 reactor thread
[Raptor 91348|main|main] │     ├─ 1 pipeline ractor
[Raptor 91348|main|main] │     ├─ 1 pipeline collector thread
[Raptor 91348|main|main] │     ├─ 3 worker threads
[Raptor 91348|main|main] │     └─ 1 stats thread
[Raptor 91348|main|main] └─ Listening on 0.0.0.0:9292
[Raptor 91350|main|main] Worker 0 booted
[Raptor 91351|main|main] Worker 1 booted
[Raptor 91352|main|main] Worker 2 booted
[Raptor 91353|main|main] Worker 3 booted
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

{
  binds: ["tcp://0.0.0.0:9292"],
  socket_backlog: 1024,
  workers: 4,
  ractors: 1,
  threads: 3,
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
  worker_timeout: 60,
  worker_boot_timeout: 60,
  worker_shutdown_timeout: 30,
  stats_file: "tmp/raptor.json",
  pid_file: nil,
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

| Signal | Effect                                      |
| ------ | ------------------------------------------- |
| `INT`  | Graceful shutdown                           |
| `TERM` | Graceful shutdown                           |
| `USR1` | Log per-worker stats to stdout              |
| `USR2` | Phased restart (rolling worker replacement) |

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

Sending `SIGUSR1` to the master logs the same summary to stdout.

## (Micro) Benchmarks

Raptor 0.7.0 vs Puma 8.0.2:

| Protocol              | Raptor      | Puma        |
| --------------------- | ----------- | ----------- |
| HTTP/1.1              | 17.9k req/s | 16.8k req/s |
| HTTP/1.1 (keep-alive) | 60k req/s   | 29.6k req/s |
| HTTP/2                | 57.2k req/s | N/A         |

> ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +YJIT +PRISM [arm64-darwin23]
> 4 workers, 3 threads, 12 concurrent connections

See [bin/benchmark](bin/benchmark) for more details.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bundle exec rake` to compile native
extensions and run the tests. You can also run `bin/console` for an interactive prompt that will allow you to
experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/joshuay03/raptor. This project is intended to
be a safe, welcoming space for collaboration, and contributors are expected to adhere to the
[code of conduct](https://github.com/joshuay03/raptor/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Raptor project's codebases, issue trackers, chat rooms and mailing lists is expected to
follow the [code of conduct](https://github.com/joshuay03/raptor/blob/main/CODE_OF_CONDUCT.md).
