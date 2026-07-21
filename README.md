# Zigora

A native Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) — an HTTP reverse proxy and load balancer framework built without a generic async runtime. Uses `std.Io` (`io.async` / `Group.concurrent` on the Threaded/Uring/Evented worker pool) for all scheduling — no `std.Thread.spawn` anywhere.

## Current release: v0.2.1 (phase 2 milestone)

### v0.1 surface (initial framework)

- `Server.new(conf)` → `addService(proxy_svc)` → `runForever()` lifecycle (Pingora `Server` model).
- `ProxyHttp` trait + `HttpProxy` server app dispatching to a configured upstream.
- Zero-copy HTTP/1.1 request parsing (method, path, version, headers).
- Structured `ZgError` type with source tracking (`Upstream` / `Downstream` / `Internal`).
- Working binary: `curl http://127.0.0.1:8080/` through the proxy to a Python upstream returns `200 OK`.

### v0.1.1 additions (phase 1 unblocker packages)

- **`zigora_http`** — `ResponseHeader.parse`/`toH1Wire`, `headersToH1Wire` (case-preserving, one pass), `HttpTask` union (6 variants), `reasonPhrase` canonical table.
- **`zigora_limits`** — `Estimator` (Count-Min Sketch), `Inflight` + `Guard` (auto-decrement on `deinit`), `Rate` (sliding-window red/blue slot toggle).
- **`zigora_lru`** — `Lru(T, N)` N-shard weighted LRU with per-shard mutex.
- **`zigora_ketama`** — `Continuum` nginx-compatible consistent hash ring (CRC32, 160 points/weight).
- **`zigora_tinyufo`** — `TinyUfo(T)` S3-FIFO + TinyLFU admission cache.
- **`zigora_pool`** — `ConnectionPool(S)` + `PoolNode(S)` with size cap.
- **`zigora_core`** (refactor) — `Server.runForever` uses `io.async` + `Future.await`; `Service.startService` uses `Group.concurrent` per connection.

### v0.2.0 / v0.2.1 additions (phase 2 – all packages integrated)

- **`zigora_proxy`** — `ProxyHttpVTable` with ~14 optional callbacks (filter chain), `Session(C)` per-request state, `HttpProxy.init` auto-wires declared callbacks. Built-in `/metrics` and `/admin` intercept.
- **`zigora_core`** — `Server.shutdown()` + `ShutdownWatch` for graceful shutdown; atomic phase transitions.
- **`zigora_memory_cache`** — `MemoryCache(T)` wrapping `TinyUfo` with TTL and `getStale`.
- **`zigora_pool`** — `ConnectionPool(S)` with `GroupKey → PoolNode` map and size-cap eviction.
- **`zigora_lb`** — `LoadBalancer(S)` with 4 selectors: `RoundRobin`, `Random`, `FNVHash`, `Consistent` (ketama).
- **`zigora_cache`** — `HttpCache` state machine with 12-phase `CachePhase`, vtable interfaces for storage/hit/miss/eviction.
- **`zigora_tls`** — TLS accept/connect adapter (stubs, interface ready for v0.3).
- **`zigora_metrics`** — Atomic counters (accepted/active/requests/errors/bytes), Prometheus `/metrics` and admin HTML page.
- **E2E test** (`test/e2e.sh`) — curls `/metrics` and `/admin`, asserts output, cleans up.
- **Examples** (`examples/`) — `simple_proxy` and `load_balancer` standalone applications.

## Modules

| Package | Status | Purpose |
|---|---|---|
| `zigora_core` | v0.2.1 | `Server`, `Service`, `Listeners`, `ServerApp` vtable (async via `std.Io`) |
| `zigora_proxy` | v0.2.1 | `ProxyHttp` trait, `HttpProxy` app, filter chain, `/metrics` + `/admin` intercept |
| `zigora_http` | v0.1.1 | HTTP/1.1 `Request` + `ResponseHeader`, `HttpTask` |
| `zigora_error` | v0.1 | `ZgError`, `ErrorType`, `ErrorSource` |
| `zigora_limits` | v0.2.1 | `Estimator`, `Inflight`, `Rate` |
| `zigora_lru` | v0.2.1 | `Lru(T, N)` sharded weighted LRU |
| `zigora_ketama` | v0.2.1 | `Continuum` consistent hash ring |
| `zigora_tinyufo` | v0.2.1 | `TinyUfo(T)` S3-FIFO + TinyLFU cache |
| `zigora_pool` | v0.2.1 | `ConnectionPool(S)` L4 connection reuse |
| `zigora_lb` | v0.2.1 | `LoadBalancer(S)` — RoundRobin, Random, FNVHash, Consistent |
| `zigora_cache` | v0.2.1 | `HttpCache` state machine, `CachePhase` (12 variants), storage/hit/miss vtable |
| `zigora_memory_cache` | v0.2.1 | `MemoryCache(T)` wrapping `TinyUfo` with TTL |
| `zigora_tls` | v0.2.1 | TLS accept/connect adapter (stubs, interface ready) |
| `zigora_metrics` | v0.2.1 | Atomic counters, Prometheus `/metrics` + admin HTML page |

See `ARCHITECTURE.md` for the authoritative module map and `V0.2_ROADMAP.md` for the phased plan.

## Build + Run

```bash
git clone https://github.com/Jeevananthan-23/zigora.git
cd zigora

# Build
zig build

# Run (listens on 127.0.0.1:8080, forwards to 127.0.0.1:9000 by default)
zig build run -- --backend 127.0.0.1:9000

# Test endpoints (no upstream needed)
curl http://127.0.0.1:8080/metrics   # Prometheus metrics
curl http://127.0.0.1:8080/admin     # Admin HTML page

# Run tests + E2E
zig build test
bash test/e2e.sh
```

Requires Zig ≥ 0.16.0. No dependencies. Offline builds work out of the box.

## Async / I/O model

Unlike Pingora (which depends on tokio), Zigora uses Zig 0.16's new `std.Io` directly:

- `Server.runForever` spawns one `io.async` future per service on the `Io` worker pool, joined via `Future.await`.
- `Service.startService` accepts connections and dispatches each to `Group.concurrent` — concurrent, non-blocking, no manual threads.

Backend selection (Threaded / Uring / Evented) happens via the process-supplied `init.io`. See `lib/zigora_core/server.zig` and `lib/zigora_core/service.zig`.

## Architecture

- `ARCHITECTURE.md` — authoritative Zigora module map, dependency graph, per-package surface, request lifecycle.
- `PINGORA_ARCHITECTURE.md` — reference Pingora crate layout and type shapes (the spec being ported from).
- `V0.2_ROADMAP.md` — phased implementation plan (phase 1 complete, phase 2 in progress).
- `AGENTS.md` — toolchain, commands, wiring conventions for OpenCode sessions.

## License

MIT — see `LICENSE`.