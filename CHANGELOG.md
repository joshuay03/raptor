## [Unreleased]

- Raise the backpressure threshold floor so low thread counts don't throttle prematurely

## [0.5.1] - 2026-05-31

- Fix `LoadError` when requiring the native extensions from an installed gem

## [0.5.0] - 2026-05-31

- Apply the default `stats_file` in the Rack handler
- Add `phase` to per-worker stats
- Force-kill workers that fail to exit within `--worker-shutdown-timeout` after shutdown is signalled
- Kill workers that fail to check in within `--worker-timeout` or `--worker-boot-timeout`
- Add `index`, `busy_threads`, and `thread_capacity` to per-worker stats

## [0.4.0] - 2026-05-29

- Load `raptor.rb` or `config/raptor.rb` by default when no config path is supplied
- Honour the peer's HTTP/2 flow-control windows when sending `DATA` frames
- Assemble HEADERS across `CONTINUATION` frames
- Validate HTTP/2 stream IDs and emit `GOAWAY` on protocol errors
- Offload TLS handshakes to the thread pool to keep the server thread responsive
- Exit eager keep-alive loops on cluster shutdown
- Apply the write timeout to HTTP/2 frame writes
- Reject HPACK dynamic table size updates larger than 4096 bytes
- Reject malformed HTTP/1.1 requests with a 400 response
- Rescue unexpected errors in the reactor and pipeline collector

## [0.3.0] - 2026-05-25

- Load cluster options from a Ruby config file via `--config`
- Replace workers one at a time on `SIGUSR2` (phased restart)
- Invoke `:on_error` callback with `(env, exception)` when the Rack app raises
- Spool request bodies larger than `--body-spool-threshold` to a tempfile
- Reject HTTP/1.1 requests larger than `--max-body-size` with a 413 response
- Write pidfile via `--pidfile`
- Set `SO_REUSEPORT` on TCP listeners where supported

## [0.2.0] - 2026-05-25

- Add Rack handler for booting via `rackup` or `rails server`
- Replace the HTTP/2 per-connection write mutex with a lock-free writer
- Parse the first HTTP/1.1 request inline on the server thread

## [0.1.0] - 2026-05-22

- Initial release
