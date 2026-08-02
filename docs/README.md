# Zigora

A native **Zig** port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) — an HTTP reverse proxy and load-balancer framework written from scratch, without any external dependencies and without a generic async runtime.

Zigora is both a **framework** (a library — `lib/zigora_core`, `lib/zigora_proxy`, …) and a **working binary** (`zig-out/bin/zigora`) that demonstrates the full feature set. All scheduling runs on Zig 0.16's `std.Io` worker pool (`io.async`, `Group.concurrent`) — there is **no `std.Thread.spawn` anywhere** in the framework.

**Why it exists:** Pingora is Rust + tokio. Zigora re-implements the same server model (`Server` → `Service` → proxy app), connection pooling, load balancing, caching, and metrics in Zig with a single-file runtime you can actually read.

---

## Features

- **Reverse proxy / gateway** — HTTP/1.1 on both sides, forwards requests to one or more upstream backends.
- **Keep-alive everywhere** — downstream (client ↔ proxy) and upstream (proxy ↔ backend) connections are reused. Idle connections close gracefully (no RST storms).
- **Pingora-style `NoStealRuntime` scheduler** — one `Io.Threaded` engine per CPU; engine 0 owns accept loops, each connection is dispatched to a random engine. No run queue is shared between connections, so latency stays flat under concurrent keep-alive load.
- **Load balancing** — `RoundRobin`, `Random`, `FNVHash`, and `Consistent` (ketama hash ring) selectors.
- **Response caching** — in-memory TinyUFO-backed cache (`zigora_memory_cache` wrapping `zigora_cache` + `zigora_tinyufo`) with TTL (60s default in the demo binary), cache-first hit path.
- **Connection pooling** — reusable upstream connection pool (`ConnectionPool(S)`) with size cap.
- **Graceful shutdown** — `Server.shutdown()` + `ShutdownWatch`; signal handlers (SIGTERM/SIGINT) drain in-flight requests under a timeout.
- **Observability** — atomic counters and a Prometheus text endpoint (`GET /metrics`) plus an admin HTML page (`GET /admin`).
- **Framework callbacks** — a ~14-slot vtable (`proxy_upstream_filter`, `listen hooks`, cache put/lookup, metrics hooks, …) mirroring the Pingora `ProxyHttp` trait.
- **Zero dependencies, offline builds** — std-only; no network/`zig fetch` step.

---

## Requirements

- **Zig ≥ 0.16.0** (`zig version` must report `0.16.0` or newer; see `build.zig.zon` → `minimum_zig_version`).
- A Linux-ish OS for the runtime's default `Io.Threaded` backend (WSL2 works).
- No external crates, no C libraries.

---

## Build

```bash
zig build                    # Debug build → zig-out/bin/zigora
zig build --release=fast      # Optimization (fast | safe | small)
zig build test                # unit tests (library + exe modules, in parallel)
```

The binary is the framework assembled end-to-end; besides it, the library modules can be imported as `zigora-<name>` build modules in your own `build.zig`.

---

## Run

```bash
# defaults: listen on 127.0.0.1:8080, forward to 127.0.0.1:9000
zig build run

# or with an explicit backend and a release build
zig build run --release=fast -- --backend 127.0.0.1:9000
zig build run -- --backend 10.0.0.5:8080 --backend 10.0.0.6:8080  # multi-backend
```

### Test endpoints (no upstream needed to verify)

```sh
curl http://127.0.0.1:8080/          # proxied request → backend (200)
curl http://127.0.0.1:8080/metrics   # Prometheus text metrics
curl http://127.0.0.1:8080/admin     # admin HTML page
```

Two identical requests to the same path hit the response cache on the second call — see `zigora_bytes_downstream` / `zigora_requests_total` climb in `/metrics`.

### CLI

```
--backend host:port     # register a backend (repeatable). Default: 127.0.0.1:9000
```

---

## Configuration knobs (demo binary)

These are hard-coded in `src/main.zig` for the demo; use the library to override:

| Setting | Value |
|---------|-------|
| Listener | `127.0.0.1:8080` |
| Default backend | `127.0.0.1:9000` |
| Response cache | 256 entries, 60 s TTL |
| Engines | `n_cpu` (one per core) |
| Upstream keep-alive | 50 ms idle poll / graceful drain |

---

## Architecture

```
client ──► Server (accept loop, engine 0)
              └─► Service (per-conn task on a random engine)
                    └─► HttpProxy.process_new
                          ├─ new_ctx / filters (vtable)
                          ├─ cache hit?        ⇒ respond from MemoryCache
                          ├─ upstreamPeer     ⇒ LB: RoundRobin / Random / FNV / Consistent
                          ├─ Pool.get(key)?   ⇒ upstream keep-alive conn
                          ├─ forward request / stream response
                          └─ pool.put on keep-alive response
```

All I/O is driven by `std.Io`; the `NoStealRuntime` owns the `Io.Threaded` engines (see `docs/V0.4_ROADMAP.md` §3.1). `process_new(io, …)` never names a backend — Threaded/Uring/Evented are drop-able.

---

## Modules

| Package | Path | Purpose |
|---|---|---|
| `zigora_core` | `lib/zigora_core/` | `Server`, `Service`, `Listeners`, `ServerApp` vtable, `NoStealRuntime` |
| `zigora_proxy` | `lib/zigora_proxy/` | `ProxyHttp` trait, `HttpProxy` app, filter chain, `/metrics` `/admin`, cache hooks |
| `zigora_http` | `lib/zigora_http/` | HTTP/1.1 `Request`, `ResponseHeader`, wire serialization, `HttpTask` |
| `zigora_error` | `lib/zigora_error/` | `ZgError` with source tracking |
| `zigora_limits` | `lib/zigora_limits/` | `Estimator` (CMS), `Inflight`, `Rate` limiters |
| `zigora_lru` | `lib/zigora_lru/` | sharded weighted LRU |
| `zigora_ketama` | `lib/zigora_ketama/` | consistent-hash ring (CRC32, 160 pts/weight) |
| `zigora_tinyufo` | `lib/zigora_tinyufo/` | TinyUFO admission cache |
| `zigora_pool` | `lib/zigora_pool/` | reusable connection pool |
| `zigora_lb` | `lib/zigora_lb/` | `LoadBalancer(S)` — RR / Random / FNVHash / Consistent |
| `zigora_cache` | `lib/zigora_cache/` | HTTP cache state machine + vtable |
| `zigora_memory_cache` | `lib/zigora_memory_cache/` | in-memory `MemoryCache(T)` with TTL |
| `zigora_tls` | `lib/zigora_tls/` | TLS accept/connect adapter (interface stubs) |
| `zigora_metrics` | `lib/zigora_metrics/` | atomic counters, Prometheus + admin renderers |

See `ARCHITECTURE.md` for the dependency graph and per-module surface.

---

## Benchmarks

`wrk -t4` against the demo binary (cache-hit path, node upstream, see `BENCHMARK.md`):

| Config | Throughput | Median | Max |
|--------|-----------|--------|-----|
| `-c8` | 27.6-33.1K req/s | ~0.5 ms | — |
| `-c100` | 62.5-64.6K req/s | ~1.5 ms | ~103 ms |

---

## Testing

```sh
zig build test            # unit tests (library + exe modules)
bash test/e2e.sh          # end-to-end curl test of /metrics and /admin
```

---

## Documentation

- `ARCHITECTURE.md` — authoritative module map, dependency graph, request lifecycle.
- `V0.2_ROADMAP.md`, `V0.3_ROADMAP.md`, `V0.3_PERFORMANCE.md`, `V0.4_ROADMAP.md` — phased plans (current work in V0.4).
- `PINGORA_ARCHITECTURE.md` — the Pingora source being ported.
- `BENCHMARK.md` — methodology + runs (Runs 1-5).
- `CHANGELOG.md` — per-tag release notes.
- `MEMORY_MANAGEMENT.md` — allocator strategy by build mode.
- `POOL_UPGRADE.md` — design notes for the upstream connection pool (V0.4 §3.2).
- `AGENTS.md` — tooling guidance (kept in the repo root for auto-discovery).

---

## License

MIT — see [`LICENSE`](../LICENSE).