# Changelog

## v0.4.0-alpha8 — 2026-08-08 (unreleased)

Layout restructure: every package is now a single file under `src/`
(`src/zigora_http.zig`, etc.) imported by relative path; `lib/` is gone.
`build.zig` collapses to two modules (`zigora` + `exe`); examples/benches
import via the `zigora` module. Relative imports propagate test blocks, so
`zig build test` now collects all ~87 tests (previously 19).

### Changes

- **restructure**: `lib/zigora_*/root.zig` → `src/zigora_*.zig` via `git mv`;
  `zigora_core` sub-files → `src/zigora_core/`; `lib/root.zig` surface merged
  into `src/root.zig` as package namespaces (`zigora.core`, `zigora.pool`, …)
  plus flat aliases (`zigora.Server`). `lib/` deleted.
- **build** (`build.zig`): single `zigora` module (root `src/root.zig`,
  `.imports` empty — all imports relative) + `exe` (root `src/main.zig`,
  imports `zigora`). Both test steps run in parallel under `zig build test`.
- **build** (`build.zig.zon`): version `0.4.0-alpha8`, `.paths` = `build.zig,
  build.zig.zon, src, stdx`.
- **http** (`src/zigora_http.zig`): `Request`/`ResponseHeader` now own their
  header storage (`header_buf: [32]Header` + `header_count`, `headers()`
  accessor). Both `parse` functions previously returned a slice into a
  stack-local array (dangling pointer — the proxy read dead stack in
  `findHeader` at `src/zigora_proxy.zig:544`). Tests use the 0.16
  `std.Io.Writer.fixed` API.
- **proxy** (`src/zigora_proxy.zig`): test impl aligned with the v0.2 vtable
  (`CTX = Ctx`, `upstream_peer` takes ctx).
- **memory_cache** (`src/zigora_memory_cache.zig`): replaced removed
  `std.time.sleep` with deadline spins on the module's `nanoTimestamp()`;
  union-tag vs union-value test fixes.
- **lb / ketama**: `std.hash.Fnv1a_64.init()` (0.16 API), `@intCast` fixes.

### Notes

- Test collection is the point of the restructure: the old named-module
  wiring ran only root-file tests, silently skipping ~68 test blocks across
  the packages — several held real bugs (see http above) that only surfaced
  now. `zig build && zig build test` is green.

## v0.4.0-alpha7 — 2026-08-08

Upstream connection pool liveness: `ConnectionPool` now hands back *live*
connections (TTL + PEEK liveness, lazy on `get`) and `upstream_pool` is
re-enabled in `zigora`. Verified by a unique-path miss bench: `pool_reuse
≈ 6k` in a 10s `wrk -t4 -c100` run, `pool_stale ≈ 2`, zero read errors.

### Additions

- **pool** (`lib/zigora_pool/root.zig`): `PoolNode` hot ring switched to
  `stdx.queue.ArrayQueue(Entry, 16)` (vendored TigerBeetle `stdx` — the
  only stdx module wired, `stdx-queue`) + `ArrayList` spill (LIFO tail-pop);
  `remove(id)` drains/repushes the ring (kills the old O(n) `orderedRemove(0)`).
  Entries carry `put_idle_at` from the linux monotonic clock.
- **pool**: `ConnectionPool.Options` — `idle_ms` (TTL, 0 = off), `ctx`,
  `is_live`, `destroy` closures; `get` lazily drops stale/dead entries
  (≤ 8 pops) via `destroy` and returns only live conns. Caller contract
  unchanged (`?S` + `orelse connect`).
- **build**: new `zigora-pool` test step — pool tests (7) actually run now
  (they were never collected; `src/root.zig` doesn't import the pool).
- **main** (`src/main.zig`): `AppState.upstream_pool` (`size_limit 16`,
  `idle_ms 5s`), `poolIsLive`/`poolDestroy` closures (PEEK + close via
  `runtime.acceptIo()`), re-enables `proxy_app.upstream_pool`.
- **metrics**: `zigora_pool_reuse` / `zigora_pool_stale` counters in
  `/metrics` and the admin table.

### Notes

- stdx module analysis (TigerBeetle vendored stdlib, 0.16 API): full-root
  use won't compile on 0.16 (`@typeInfo(T).Struct` in `json.zig` + root
  `refAllDecls`), so it is imported file-by-file; only `queue.zig` is wired.
- The original "pool never reused under load" bench turned out to be a
  broken bench: wrk's lua used `//` comments (invalid Lua) so wrk silently
  fell back to `GET /`, the cache served everything, and the pool was never
  exercised. Fixed fixture: unique `/bench/N/<r>` paths (see
  `docs/POOL_UPGRADE.md` Verification).
- Evented/io_uring research recorded in `docs/V0.4_ROADMAP.md` §3.1.
- Re-ran the Pingora head-to-head (`docs/BENCHMARK.md`, 2026-08-08): the
  2026-08-02 "0 req/s vs fast upstream" failure is fixed — miss path now
  7.9-8.5K req/s (~0 errors, pool 98% reused) vs pingora 12.9-13.4K; cached
  `/` 68K vs pingora's keep-alive-only 14.3K; 41 MB vs 11.9 MB RSS under
  load.

## v0.4.0-alpha6 — 2026-08-02

Pingora-style NoSteal runtime: the shared `Io.Threaded` pool is replaced
with one engine per CPU, so no run queue is shared between connections.
Cached-path c100 throughput 53-57K → 62.5-64.6K req/s, median 3-7ms →
~1.5ms, max tail ~200ms → ~103ms (see BENCHMARK.md Run 5).

### Additions

- **core** (`lib/zigora_core/runtime.zig`): `NoStealRuntime` — N independent
  `Io.Threaded` engines, each `.unlimited`; engine 0 owns accept loops;
  `getRandomIo()` dispatches each connection to a random other engine
  (pingora's `current_handle()`).
- **core**: `Service.setRuntime()` — connections are dispatched per-engine;
  without a runtime, services keep the old single-io behavior.
- **proxy**: `downstream_bytes` counter now counts cache-hit responses (3.6).
- **main**: wires the NoSteal runtime (n_cpu engines); drops the ad-hoc
  `async_limit` tweak.

### Notes

- `std.Io.Evented` (io_uring) was probed as the scheduler engine and
  rejected: it does not compile in Zig 0.16.0 (std bug in `Uring.zig` dir
  open error sets — `Dir.OpenError` missing `error.ReadOnlyFileSystem`,
  fixed upstream post-0.16.0; no 0.16.1 exists). Revisit on a Zig upgrade.
- Determinism gate (roadmap 3.5) passed: 3x runs spread 1.03x (c100) and
  1.2x (c8), under the 2x gate. Remaining in 3.5: the in-repo bench fixture.

## v0.4.0-alpha5 — 2026-08-02

Downstream keep-alive: the RST storm is gone; cached-path throughput is now
53-57K req/s at wrk -c100 vs ~0 before (see BENCHMARK.md Run 4).

### Additions

- **proxy** (`lib/zigora_proxy/root.zig`): keep-alive request loop in
  `process_new` — pipelined bytes from the stream reader, else a bounded
  (50ms) `receiveTimeout` wait into a scratch buffer served via
  `Io.Reader.fixed`; idle connections close gracefully through the existing
  drain path (no RST). `src/main.zig` raises the runtime io `async_limit`
  from n_cpu-1 to `.unlimited` so >7 keep-alive connections don't queue.

### Fixes

- **proxy**: upstream header accumulation over-consumed the peeked buffer —
  a fast HTTP/1.1 upstream sending headers+body in one read had its body
  swallowed into `header_buf` and discarded, producing header-only
  responses (the "0 req/s vs node" benchmark regression). Header
  consumption now stops at the `\r\n\r\n` terminator; body bytes stay in
  the reader.
- **proxy**: unparsable request heads (partial reads on the keep-alive
  path) now close gracefully instead of `ProcessFailed` (RST churn).

## v0.4.0-alpha4 — 2026-08-02

Memory management: production leak detection + the real leaks it found.

### Additions

- **docs**: new `MEMORY_MANAGEMENT.md` — Zig 0.16 allocator model and zoo, idioms (`defer`/`errdefer`, `deinit() == .ok`), zigora's strategy, and conventions for new modules.
- **main** (`src/main.zig`): mode-switched allocator — `DebugAllocator` (leak-checking) in Debug/ReleaseSafe, `smp_allocator` in ReleaseFast/Small; `deinit() == .ok` asserted at shutdown, so a SIGTERM that reports leaks exits non-zero. All zigora allocations moved off the process arena (kept only for args); shutdown deinit wired for balancer, cache, metrics, listeners, server, config.
- **tinyufo**: new `forEachData` so owning layers can free resident values; same-key overwrites now return the previous value with the eviction batch instead of orphaning it.

### Fixes

- **memory_cache**: values are freed on eviction, overwrite, and at deinit (previously only the node slice was freed — every eviction leaked a response's bytes); deinit now frees the instance the proxy actually mutated (AppState's copy), not the stale local copy whose arraylist pointers went stale after the first put.
- **core** (`lib/zigora_core/service.zig`): `startService` drains in-flight connections (`Group.await`) before returning, so `runForever` never unwinds state while a handler is still running.

### Verified

- `zig build` + `zig build test` clean; leak-checked SIGTERM exits clean under a 60-request load during shutdown (3/3 runs, exit 0); E2E 8/8 PASS; ReleaseFast (`smp_allocator`) smoke: 200s + clean exit.

## v0.4.0-alpha3 — 2026-08-02

Deep-module refactor of the proxy seam + connection-handling fixes.

### Additions

- **proxy** (`lib/zigora_proxy/root.zig`): `proxyToH1` collapsed from 12 params to 3 — request-scoped knobs (cache buffer/cursor, upstream pool, byte counters, body hint) now ride on `Session`; capture logic is a `Session.writeAndCapture` method. Cache put fires only when the response fit the capture buffer entirely.
- **proxy**: `renderMetrics`/`renderAdmin`/`cacheLookup`/`cachePut` callbacks take the app pointer (`*T`), matching the `onUpstream*` callbacks — global singletons (`global_state`, `global_metrics`) deleted from `main.zig` and both examples; callbacks are now `MyProxy` methods.
- **core** (`lib/zigora_core/server.zig`): `Server.addService(&svc)` takes the `Service` directly and generates the start-wrapper internally — the `SlotWrap`/`ServiceSlot` boilerplate is gone from all consumers.
- **core**: deleted dead `buffer_pool` module (unused since the v0.4 stack-buffer rework; its cursor-based borrow had no acquire/release protocol).

### Fixes

- E2E script: step 7's bare `wait` blocked forever on the daemon jobs; step 8's `pidof` with a path matched nothing so SIGTERM was never sent.

### Verified

- `zig build` + `zig build test` clean; E2E 8/8 PASS (GET, streaming, /metrics, /admin, 5x sequential, POST, 3 parallel, SIGTERM).

## v0.4.0-alpha — 2026-07-31

v0.4 line opens: graceful shutdown, upstream keepalive plumbing, multi-listener accept, request body streaming.

### Additions

- **core** (`lib/zigora_core/server.zig`): SIGTERM/SIGINT signal handlers + `ShutdownWatch`-polled accept loops — clean service shutdown instead of process kill.
- **core** (`lib/zigora_core/service.zig`): multi-listener parallel accept — N listeners spawn N `io.async` accept futures joined at shutdown (previously one sequential loop).
- **core/lb**: Consistent-hash LB fix in `load_balancer` example (two-backend distribution).
- **proxy** (`lib/zigora_proxy/root.zig`): request body streaming for Content-Length POSTs — body forwarded upstream chunk-by-chunk after headers; `BodyHint` mode on the dispatch path.
- **proxy**: `ConnectionPool` keepalive hook — pooled upstream connections returned when the response allows reuse.
- **proxy/core**: downstream keepalive disabled for stability (per-request stack buffers, `stream.close` after each response).
- **docs**: `V0.4_ROADMAP.md` — phased v0.4 plan (perf, TLS, HTTP/2, cache/compress, pools).

### Verified

- SIGTERM shuts all services down cleanly; POST with Content-Length reaches upstream.

## v0.4.0-alpha2 — 2026-07-30

Per-request buffer pool + buffer ownership rework.

### Additions

- **core** (`lib/zigora_core/buffer_pool.zig`): pre-allocated ring of `PerRequestBuffers` (16 slots × 16KB) with atomic round-robin borrow — replaces stack allocation of ~24KB per request.
- **core/proxy**: `Service.handleConn` borrows pool buffers per connection; `process_new` uses pooled read/write/header buffers instead of stack locals.

## v0.4.0-alpha1 — 2026-07-30

Upstream response streaming: parse-then-stream.

### Additions

- **proxy** (`lib/zigora_proxy/root.zig`): `proxyToH1` rewritten from full-buffer copy to parse-then-stream — response headers parsed into `ResponseHeader`, then body streamed chunk-by-chunk (Content-Length, chunked transfer-encoding, and read-until-EOF modes) with no full-buffer copy. ~200 lines of streaming logic.

## v0.3.0-beta1 — 2026-07-30

First beta: performance tooling + log hygiene.

### Additions

- **bench** (`benches/`): ported Pingora benchmarks — TinyUFO admission (`tinyufo_perf.zig`), LRU (`lru_bench.zig`), Ketama continuum (`ketama_bench.zig`), rate limiter (`limits_bench.zig`); `zig build bench-*` steps in `build.zig`.
- **perf**: per-request info logs demoted to debug (`main.zig` routing, `zigora_proxy` request completion, `zigora_core` service listening) — keeps error/warn intact, silences hot-path log noise.
- **docs**: `V0.3_PERFORMANCE.md` — v0.3 performance work plan.

## v0.2.4 — 2026-07-29

End-to-end memory cache round-trip + cachePut callback.

### Additions

- **proxy** (`lib/zigora_proxy/root.zig`): optional `cachePut(path, raw_response_bytes)` callback on `HttpProxy`. Fired after successful upstream dispatch so users can populate `MemoryCache`.
- **proxy**: `proxyToH1` gains `resp_buf: []u8` + `resp_out: *[]const u8` out-params so the upstream response buffer lives through the `cachePut` callback (no dangling pointer).
- **main.zig**: `MyProxy.cachePut` implementation — allocator.dupe response + 60s TTL `MemCache.put()`; `metrics.incCachePut()` counter increment.
- **metrics** (`lib/zigora_metrics/root.zig`): `cache_hits`, `cache_misses`, `cache_puts` atomic counters; rendered in Prometheus `/metrics` and admin page.
- **tinyufo** (`lib/zigora_tinyufo/root.zig`): Zig 0.16 compat fix — `@as(comptime_float, ...)` on runtime value → `@as(usize, @intFromFloat(...))`.

### Verified

- 2nd+3rd requests served from cache (335B each)
- `cache_hits=2`, `cache_misses=1`, `cache_puts=1`

## v0.2.3 — 2026-07-22

Proxy production-readiness: upstream response parsing (status line + headers
+ body), retry loop with configurable max_retries in HttpProxy,
/ /admin served at the proxy layer (no user boilerplate), per-service approach
via ShutdownWatch, ConnectionPool keepalive hook, and removed unused
package imports from AppState.

### Additions

- **proxy** (`lib/zigora_proxy/root.zig`): `proxyToH1` replaces the old byte-forwarder
  with parsed upstream response handling — parses `ResponseHeader` from upstream,
  stores it on `Session.response`, logs `{method} {path} → {status_code}`.
- **Retry** loop: `max_retries` field on `HttpProxy`. On connection failure,
  re-selects `upstream_peer` and retries up to the limit; fires `fail_to_connect`
  once on the final error.
- **Framework** /metrics and /admin: `renderMetrics` and `renderAdmin` optional
  callbacks on `HttpProxy` — the proxy intercepts `GET /metrics` and `GET /admin`
  before upstream dispatch, no user callback needed.
- **core** (`lib/zigora_core/service.zig`): `Service.shutdown_watch` field —
  set via `setShutdown(sh).` Accept loop polls `ShutdownWatch.check()` per
  aggregation. No poll → loop runs forever (backward-compatible default).
- **core** (`lib/zigora_core/root.zig`): `ShutdownWatch` re-export for library
  consumers.

### Changes

- **src/main.zig**: 13 packages → 4; AppState is now `{balancer, metrics,
  counter}`. /metrics and /admin handled by `renderMetrics/renderAdmin`
  callbacks via package-level `global_metrics` pointer. `MyProxy.proxy_upstream_filter`
  removed — no longer needed.
- **examples/load_balancer/main.zig**: same framework /metrics render, no boilerplate filter.
- **examples/simple_proxy/main.zig**: only `/metrics` render; no admin page.

## v0.2.2 — 2026-07-22

Connection lifecycle callbacks on `Service` and `HttpProxy`, per-request
counter-based hash key for consistent load balancing, upstream active
connection tracking in metrics, and scoped loggers on all modules.

### Additions

- **core** (`lib/zigora_core/service.zig`): `onAccept` / `onFinish` callbacks
  on `Service`. `handleConn` now captures `*Self` (not `*App`) so it can fire
  `onFinish` on connection close.
- **proxy** (`lib/zigora_proxy/root.zig`): `onUpstreamConnect`,
  `onUpstreamDisconnect`, `onUpstreamError` callbacks on `HttpProxy`.
  `upstreamBytes` / `downstreamBytes` optional atomic pointer fields —
  incremented inside `dispatchToUpstream`.
- **metrics** (`lib/zigora_metrics/root.zig`): `upstream_active` counter
  with `incUpstreamActive` / `decUpstreamActive` methods. Rendered in both
  Prometheus and admin page.
- **all modules**: scoped loggers (`const log = std.log.scoped(.X)`) in every
  package root file, server.zig, listeners.zig, main entrypoints, and examples.

### Fixes

- **main.zig + load_balancer example**: hash key changed from static
  `"key"` (always routes to same backend) to per-request atomic counter
  for round-robin distribution.
- **BackendCfg**: changed from single `{host,port}` to `ArrayList([]const u8)`,
  supporting multiple `--backend` CLI flags. Defaults to `[127.0.0.1:9000,
  127.0.0.1:9001]`.

### Docs

- `BENCHMARK.md` — benchmark results (~310 req/s, 82ms median).
- `V0.3_ROADMAP.md` — priority-ordered plan for v0.3.

## v0.2.1 — 2026-07-21

Bugfix release: v0.2.0 packages compiled individually but the binary and
examples did not build or run. All packages now compile clean, the proxy
serves /metrics + /admin, and a regression test suite guards against
breakage.

### Fixes

- **all packages**: Zig 0.16 API migrations — `std.net.Address` → `Io.net.IpAddress`,
  `std.io.fixedBufferStream` → `Io.Writer.fixed()`, `std.Thread.Mutex` → spinlock,
  `std.AutoArrayHashMap` → `Unmanaged`, `@typeInfo(...).Struct` → `@"struct"`.
  All 13 modules compile without errors or warnings.
- **proxy** (`lib/zigora_proxy/root.zig`): `HttpProxy.init` now wires the
  `proxy_upstream_filter` callback from `T` if declared (with type coercion).
  `process_new` no longer uses undefined stream after `Session` takes ownership.
  `dispatchToUpstream` error path logs `ProcessFailed` instead of crashing.
- **core** (`lib/zigora_core/service.zig`): `handleConn` no longer double-closes
  the stream when `process_new` returns `null` (filter consumed the stream).
- **metrics** (`lib/zigora_metrics/root.zig`): `renderAdmin` format string — escaped
  `{`/`}` CSS braces for `Io.Writer.print`. Replaced dead `std.io.fixedBufferStream`
  tests with `Io.Writer.fixed()`. Tests now actually compile and run via dedicated
  `zigora-metrics` test step in `build.zig`.
- **main.zig**: Full v0.2 integration restored — all 13 packages wired into
  `AppState`, `MyProxy.proxy_upstream_filter` intercepts `/metrics` and `/admin`
  before upstream connection, writes response via `Io.Writer` + flush + stream close.

### Additions

- **E2E test** (`test/e2e.sh`): builds binary, curls `/metrics` and `/admin`,
  asserts Prometheus text and admin HTML content, cleans up. Run with `bash test/e2e.sh`.
- **Examples**: `examples/simple_proxy/` and `examples/load_balancer/` — minimal
  standalone proxy applications. Build with `zig build` (installed to `zig-out/bin/`).

### Tag

`v0.2.1`

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