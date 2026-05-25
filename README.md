# Raptor

Raptor is a high-performance, multi-threaded, multi-process Ruby Rack 3 web server that leverages Ractors for parallel
HTTP/1.1 and HTTP/2 request processing, native C extensions for HTTP parsing and HPACK compression, and NIO for
non-blocking I/O.

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
> bundle exec raptor -t 3 -w 4 hello_world.ru
Raptor Cluster initializing:
├─ Version: 0.2.0
├─ Ruby Version: ruby 4.0.4 (2026-05-12 revision b89eb1bcbf) +YJIT +PRISM [arm64-darwin23]
├─ Master PID: 31504
│  └─ 4 worker processes
│     ├─ 1 server thread
│     ├─ 1 reactor thread
│     ├─ 1 pipeline ractor
│     ├─ 1 pipeline collector thread
│     ├─ 3 worker threads
│     └─ 1 stats thread
└─ Listening on 0.0.0.0:9292
[31506] Worker 0 booted
[31507] Worker 1 booted
[31508] Worker 2 booted
[31509] Worker 3 booted
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

## (Micro) Benchmarks

Raptor 0.2.0 vs Puma 8.0.1:

| Protocol              | Raptor       | Puma         |
| --------------------- | ------------ | ------------ |
| HTTP/1.1              | 20.3k req/s  | 20.8k req/s  |
| HTTP/1.1 (keep-alive) | 60.9k req/s  | 45.4k req/s  |
| HTTP/2                | 22.9k req/s  | N/A          |

> Ruby 4.0.4 +YJIT, macOS Apple Silicon. 4 workers, 3 threads, 12 concurrent connections.

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
