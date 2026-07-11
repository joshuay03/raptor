## [Unreleased]

- Skip a per-response allocation when formatting response headers
- Reject HTTP/2 streams with malformed pseudo-headers with `RST_STREAM`
- Populate `PATH_INFO` from absolute-form request targets
- Consume the trailer section after the chunked-body terminator
- Reject request headers larger than 112KB with 400
- Reject chunk sizes containing non-hex characters with 400
- Advance the parser's `nread` past the request header terminator
- Detect chunked `Transfer-Encoding` case-insensitively
- Reject HTTP/1.1 requests without a valid `Host` header with 400

## [0.10.0] - 2026-07-07

- Memoize the server port string for the Rack env
- Parse the Host header without regex
- Apply `TCP_NODELAY` on the listener rather than each accepted socket
- Buffer chunked body writes up to 512KB before flushing
- Add `QUERY_STRING` to the Rack env template
- Skip intermediate array allocations when formatting response headers
- Intern common HTTP header keys in the parser
- Reuse a Rack env template across HTTP/1.1 requests

## [0.9.0] - 2026-07-07

- Reuse a per-thread response buffer for status lines and headers
- Pin each worker to a distinct CPU when workers fit 1:1
- Batch response header and body writes into a single `writev(2)` syscall
- Close the binder as the last step of graceful shutdown
- Lower the backpressure floor for tighter load balancing on small pools
- Add load-aware `SO_REUSEPORT` routing on Linux via an attached BPF program
- Reuse per-thread read buffers across HTTP/1.1 requests
- Preserve the first `--bind` when it equals the default

## [0.8.0] - 2026-07-02

- Add systemd `LISTEN_FDS` socket activation and `sd_notify` lifecycle messages
- Add hot restart on `SIGUSR2`, inheriting listening sockets across the re-exec
- Drop `SIGUSR1` stats logging and move phased restart from `SIGUSR2` to `SIGUSR1`
- Add `chdir` and `environment` for Rack app loading, with fallback to `RAILS_ENV` and `RACK_ENV`
- Add `access_log_file` for Common Log Format access logging, reopened on `SIGHUP`
- Add `stdout_file` and `stderr_file` for redirecting stdout/stderr, reopened on `SIGHUP`
- Add `drain_accept_queue` for dispatching every queued connection on shutdown
- Add `worker_drain_timeout` for force-killing hung app threads during worker shutdown
- Reject `Content-Length` values containing non-digit characters with 400
- Populate `SERVER_SOFTWARE` and `HTTP_VERSION` in the Rack env
- Honour `X-Forwarded-Proto`, `X-Forwarded-Scheme`, and `X-Forwarded-Ssl` from upstream proxies
- Split newline-joined response header values into separate header lines
- Reject excessive chunked framing overhead with 400 (slow-trickle attack guard)
- Reject ambiguous request framing (`Transfer-Encoding` + `Content-Length`, or `chunked` not the final encoding) with 400
- Send `100 Continue` when an HTTP/1.1 client sends `Expect: 100-continue`
- Add new configuration options and split `client:` into protocol-scoped namespaces

## [0.7.0] - 2026-06-12

- Eagerly consume back-to-back HTTP/2 frame batches in the pipeline collector

## [0.6.0] - 2026-06-02

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
