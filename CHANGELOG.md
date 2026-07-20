# Changelog

## v0.2.0 — 2026-07-20

Phase 2 complete: composite packages + proxy/TLS + core signals + metrics.

### Phase 1 (v0.1.1 — unblockers)

All packages landed in `v0.1.1` tag.

### Phase 2 (composite packages)

- **memory_cache** (2.7): `MemoryCache(T)` — wraps `TinyUfo` with TTL, `get`/`getStale`/`put`/`forcePut`/`remove`, lazy expiry on `get`, `CacheStatus` union (hit/miss/expired/lock_hit/stale).
- **pool** (2.6): `ConnectionPool(S)` — `GroupKey → PoolNode` map + size cap, `get`/`put` with eviction, no idle watcher (caller manages keep/close).
- **lb** (2.8): `LoadBalancer(S)` with 4 selectors — `RoundRobin` (weighted atomic ctr), `Random` (Wyhash), `FNVHash` (Fnv1a-64), `Consistent` (zigora-ketama). `Backend(addr, weight)`. `select(key)`/`selectWith(key, accept)`.
- **cache** (2.9): `HttpCache` state machine + `CachePhase` (12 variants), `NoCacheReason`, `RespCacheable`, `HitStatus` (6), `CacheMeta`. Vtable interfaces: `Storage`/`HitHandler`/`MissHandler`/`EvictionManager`. No disk/storage/lock/predictor yet.

### Phase 3 (proxy + TLS)

- **proxy** (3.10): `ProxyHttpVTable(T, Ctx)` with ~14 optional callbacks (`upstream_peer`, `early_request_filter`, `request_filter`, `request_body_filter`, `request_cache_filter`, `proxy_upstream_filter`, `upstream_request_filter`, `upstream_response_filter`, `response_filter`, `response_cache_filter`, `fail_to_connect`, `fail_to_proxy`, `error_while_proxy`, `logging`). Defaults = pass-through. `Session(Ctx)` per-request state. `HttpProxy.initWith` accepts custom vtable. `process_new` runs the filter chain.
- **tls** (3.11): `accept(raw_stream, config)`, `connect(io, addr, config)` — stubs returning `error.Unimplemented`. Interface ready for v0.3 BoringSSL/pure-Zig impl.

### Phase 4 (core signals + metrics)

- **core** (4.12): `Server.shutdown_flag` + `phase_` atomics for signal integration. `ShutdownWatch` for accept loops. `Server.shutdown()` sets flag + transitions phase.
- **metrics** (4.13): `Metrics` registry with atomic counters (accepted/active/requests/errors/bytes upstream/downstream/upstream_errors). `renderPrometheus()` Prometheus text format. `adminHandler` serves `/metrics`, `/admin` (HTML), 404 else.

### Build

All 13 packages wired as named modules in `build.zig` and re-exported from `lib/root.zig`.

### Tag

`v0.2.0`

## v0.1.1 — 2026-07-19

Phase 1 milestone: all v0.2 unblocker packages + async core refactor.

...

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