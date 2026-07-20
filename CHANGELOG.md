# Changelog

## v0.1.1 — 2026-07-19

Phase 1 milestone: all v0.2 unblocker packages + async core refactor.

### Changes

- **core**: replaced `std.Thread.spawn`/`join` with `io.async`/`Future.await`
  for per-service tasks and `Group.concurrent` for per-connection dispatch.
  The `std.Io` worker pool now schedules everything — no manual threads.
- **http** (v0.2 surface): added `ResponseHeader.parse`/`toH1Wire`,
  `headersToH1Wire` (case-preserving one-pass), `HttpTask` union (6 variants),
  `reasonPhrase` canonical table, `Version.toSlice`.
- **limits**: `Estimator` (Count-Min Sketch, `isize` atomic cells),
  `Inflight` + `Guard` (auto-decrement on `deinit()`), `Rate`
  (sliding-window red/blue toggle, `observe`/`rate`).
- **lru**: `Lru(T, N)` — N-shard weighted LRU, per-shard mutex,
  `admit`/`promote`/`remove`/`evictShard`/`evictToLimit`.
- **ketama**: `Continuum` — nginx-compatible consistent hash ring (CRC32,
  160 points/weight), `node(key)` binary-search lookup, `getAddr` iterator.
- **tinyufo**: `TinyUfo(T)` — S3-FIFO + TinyLFU admission cache,
  `get`/`put`/`forcePut`/`remove`. Single mutex port of lock-free crate.
- **pool**: `ConnectionPool(S)` — `GroupKey → PoolNode` map + size cap,
  `get(GroupKey)` / `put(meta)` with eviction on overflow.
- **build**: All phase 1 packages wired as named modules in `build.zig`
  and re-exported from `lib/root.zig`.

### Tag

`v0.1.1`

## v0.1.0 — 2026-07-18

Initial release. Zig port of Cloudflare [Pingora](https://github.com/cloudflare/pingora) HTTP reverse proxy framework.

### Packages shipped (v0.1 surface)

- **zigora-core** — `Server`, `Service<A>`, `Listeners` (TCP only), `ServerApp` vtable, `ServerConf`. Port of `pingora-core`.
- **zigora-proxy** — `ProxyHttp(T)` trait, `HttpProxy(T)`, `http_proxy_service()`. `process_new()` dispatches to the configured upstream. Port of `pingora-proxy`.
- **zigora-http** — Zero-copy HTTP/1.1 `Request` parser (`Method`, `Version`, `Header`). Port of `pingora-http`.
- **zigora-error** — `ZgError` (struct), `ErrorType` (23 variants), `ErrorSource` (`Upstream`/`Downstream`/`Internal`). Port of `pingora-error`.

### Executable

`zigora` binary accepts `--backend host:port` (default `127.0.0.1:9000`), listens on `127.0.0.1:8080`, and proxies HTTP/1.1 requests to the upstream.

### Packages reserved for v0.2

`zigora-lb`, `zigora-cache`, `zigora-tls`, `zigora-limits`, `zigora-metrics`, `zigora-utils` — on-disk stubs exist for forward-compatibility.

### Design notes

- No async runtime port — Zigora uses `std.Io` (`io_uring`/`epoll`) directly.
- No `HTTP/2`, no `TLS`, no `LoadBalancer` selectors.
- Architecture map against Pingora crates: see `ARCHITECTURE.md`.