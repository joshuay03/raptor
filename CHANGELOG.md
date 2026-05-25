## [Unreleased]

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
