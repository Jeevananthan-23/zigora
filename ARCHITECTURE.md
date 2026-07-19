# ARCHITECTURE.md

Zigora is a Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) HTTP reverse proxy framework. This doc maps Pingora's crate layout to Zigora's `lib/` sub-packages, defines the v0.1 surface, and governs build wiring. It is authoritative for module boundaries; `README.md` is the marketing-facing overview.

---

## 1. Pingora-to-Zigora map

| Pingora crate | Zigora package | v0.2 status |
|---|---|---|
| `pingora` (umbrella lib) | `src/root.zig` + `lib/root.zig` | Active |
| `pingora-core` | `lib/zigora_core/` | **[v0.1]** Server, Service, Listeners — **[v0.1.1]** async via `io.async`/`Group.concurrent` |
| `pingora-proxy` | `lib/zigora_proxy/` | **[v0.1]** ProxyHttp trait, Session, dispatch |
| `pingora-http` | `lib/zigora_http/` | **[v0.1]** Request parser — **[v0.1.1]** `ResponseHeader`, `headersToH1Wire`, `HttpTask` |
| `pingora-error` | `lib/zigora_error/` | **[v0.1]** Error struct + ErrorType |
| `pingora-limits` | `lib/zigora_limits/` | **[v0.1.1]** `Estimator`, `Inflight`, `Rate` |
| `pingora-lru` | `lib/zigora_lru/` | **[v0.1.1]** `Lru(T, N)` sharded weighted LRU |
| `pingora-ketama` | `lib/zigora_ketama/` | **[v0.1.1]** `Continuum` consistent hash ring |
| `pingora-pool` | `lib/zigora_pool/` | **[v0.1.1]** `ConnectionPool(S)` + `PoolNode(S)` |
| `tinyufo` | `lib/zigora_tinyufo/` | **[v0.1.1]** `TinyUfo(T)` S3-FIFO + TinyLFU |
| `pingora-load-balancing` | `lib/zigora_lb/` | v0.2 phase 2 |
| `pingora-memory-cache` | (reserved) | v0.2 phase 2 — `lib/zigora_memory_cache/` |
| `pingora-cache` | `lib/zigora_cache/` | v0.2 phase 2 |
| `pingora-tls` (open/boringssl/rustls/s2n) | `lib/zigora_tls/` | v0.2 phase 3 |
| `pingora-prometheus` | `lib/zigora_metrics/` | v0.2 phase 4 |
| `pingora-timeout` | (none) | `std.Io.Timeout` covers it |
| `pingora-runtime` | (none) | `std.Io` is the runtime |
| `pingora-header-serde` | (none) | Deferred indefinitely |
| (no bin in Pingora) | `src/main.zig` | Zigora ships as a binary |

**Key Zig-Pingora design shifts:**

1. **No async runtime.** Pingora depends on tokio; Zigora uses `std.Io` (`io.async` / `Group.concurrent` on the Threaded/Uring/Evented worker pool). No `pingora-runtime` equivalent.
2. **No `pingora-timeout`.** `std.Io.Timeout` covers fast-timeout needs natively.
3. **Binary ships.** `src/main.zig` is Zigora's equivalent of Pingora users' own `fn main()`.
4. **Phase 1 (v0.1.1) packages are pure unblockers.** limits/lru/ketama/tinyufo/pool have zero internal deps. They form the foundation for the composite packages in phase 2.
5. **No `CaseMap`** — Zigora's `Header.name` slice keeps original case, so the dual-HMap trick Pingora uses is unnecessary; `headersToH1Wire` preserves case in one pass.

---

## 2. v0.1 dependency graph

```
src/main.zig (binary — Pingora's "user's main.rs")
    ├─ zigora-proxy  (ProxyHttp trait, Session, upstream_peer)
    ├─ zigora-core   (Server, Service, Listeners)
    ├─ zigora-http   (RequestHeader, ResponseHeader parsing)
    └─ zigora-error  (Error struct — shared by all)
```

Sub-package import direction (no cycles):

```
zigora_proxy → zigora-core, zigora-http, zigora-error
zigora_core  → zigora-http, zigora-error
zigora_http  → (nothing)
zigora_error → (nothing — stdlib only)
```

`src/main.zig` imports all four via `build.zig` named modules. `src/root.zig` re-exports the public surface for library consumers.

---

## 3. Package surface — v0.1 minimum (Pingora types to port)

### `lib/zigora_core/`

Pingora counterparts: `pingora-core::Server`, `Service<A>`, `ServerConf`, `Listeners`, `apps::ServerApp`.

v0.1 surface:

```
Server {
    services: []ServiceHandle,
    shutdown_signal: flag,
    configuration: ServerConf,
}

Server.new(conf: ServerConf, opt: Opt) → Server
Server.add_service(&mut, svc: Service) → ServiceHandle
Server.run_forever(self) → !void          // blocks until SIGTERM/SIGINT

Service {
    name: []const u8,
    listeners: []TcpListener,           // one listener per endpoint
    app: *ServerApp,                    // trait object
    threads: ?usize,
}

Service.add_tcp(name, addr, port) → void
Service.add_service_to(server) → void   // convenience

ServerApp trait {
    process_new(stream: Stream, shutdown: bool) → ?Stream
      // accept → handshake → process → optionally return for keepalive
}
```

The current `server.zig` (`Server.start` / `Server.accept` / `Config`) maps to Pingora's `Service<A>` accept loop, not `Server` — it should be renamed and restructured before more code lands.

### `lib/zigora_proxy/`

Pingora counterparts: `ProxyHttp` trait (30+ callbacks), `HttpProxy<SV,C>`, `Session`.

v0.1 surface:

```
ProxyHttp(T) trait {                    // T is the user's context type
    new_ctx() → T;
    upstream_peer(session, ctx) → Result(HttpPeer);
    // All other ~30 callbacks default to pass-through in v0.1
}

HttpProxy {
    inner: *ProxyHttp,
    upstream_connector: Connector,
    downstream_modules: HttpModules,
    max_retries: usize,
}

Session {
    downstream_session: Box<HttpSession>,  // the H1/H2 client connection
    request: RequestHeader,                // parsed client request
    response: ?ResponseHeader,             // from upstream, if received
    cache: ?HttpCache,                     // absent in v0.1 (cache not wired)
    shutdown_flag: bool,
}

// Pingora convenience constructors:
http_proxy_service(conf, impl: *ProxyHttp) → Service<HttpProxy>
http_proxy(conf, impl) → HttpProxy
```

The current `proxy.zig` (`dispatch(io, upstream, buf, writer)`) is a direct-splice function, not `ProxyHttp` — should be restructured into `ProxyHttp.upstream_peer` + `HttpProxy.process_new_http` before v0.2.

### `lib/zigora_http/`

Pingora counterparts: `RequestHeader`, `ResponseHeader`, `CaseMap` (case-preserving header name map), `HttpTask`.

v0.1 surface:

```
RequestHeader {
    method: Method,
    path: []const u8,
    version: Version,
    headers: HeaderMap,
    raw_path_fallback: []u8,           // for non-UTF8 paths
}

RequestHeader.parse_from(buf: []u8) → RequestHeader
RequestHeader.header_to_wire(buf) → void

ResponseHeader {
    status_code: u16,
    version: Version,
    headers: HeaderMap,
    reason_phrase: ?[]const u8,
}

ResponseHeader.parse_from(buf: []u8) → ResponseHeader
ResponseHeader.header_to_wire(buf) → void

HeaderMap {
    entries: []{name: []const u8, value: []const u8},  // zero-copy into buffer
    case_map: ?CaseMap,                // v0.2 — Pingora uses case-preserving HMap
}

Method enum: GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH
Version enum: HTTP10, HTTP11
```

The current `root.zig` (`Request.parse`, `Header`, `Method` enum) is a good start — needs `ResponseHeader` to be added, and `CaseMap` deferred.

### `lib/zigora_error/`

Pingora counterparts: `ErrorType` (40+ variants), `ErrorSource`, `RetryType`, `Context<T>`/`OrErr<T>`/`OkOrErr<T>` chaining traits.

v0.1 surface:

```
Error {
    etype: ErrorType,
    esource: ErrorSource,
    retry: bool,
    cause: ?Error,                     // chain
    context: ?[]const u8,
}

Error.new(etype, source) → Error
Error.new_up(etype) → Error            // source = Upstream
Error.new_down(etype) → Error          // source = Downstream
Error.new_in(etype) → Error            // source = Internal

ErrorType enum {
    ConnectTimedout, ConnectRefused, ConnectNoRoute,
    TLSHandshakeFailure, TLSHandshakeTimedout, InvalidCert,
    InvalidHTTPHeader, H1Error,
    ReadError, WriteError, ReadTimedout, WriteTimedout, ConnectionClosed,
    HTTPStatus(u16),
    FileOpenError, FileReadError, FileWriteError,
    InternalError, UnknownError,
    Custom(&str),
}

ErrorSource enum { Upstream, Downstream, Internal, Unset }

// Zig idiom: each package defines its own error set that ErrorType wraps.
// No need for Rust's Box<dyn Error> chain — Zig error sets are flat.
```

The current `root.zig` is empty — needs a full `Error` + `ErrorType` implementation as the first v0.1 port of this crate, since `core` and `proxy` both depend on it.

---

## 4. Request lifecycle (Pingora model, v0.1 subset)

From Pingora `proxy_trait.rs` + `HttpProxy::process_new_request()`:

```
1.  Server.accept() → handshake (H1 for v0.1)
2.  early_request_filter()   → default passthrough
3.  Read/parse client request → RequestHeader
4.  Run downstream HttpModules on request headers
5.  request_filter()          → user override (v0.1: passthrough)
6.  request_cache_filter()    → v0.1: cache disabled (no-op)
7.  proxy_upstream_filter()   → v0.1: always true (proceed)
8.  upstream_peer()           → THE user entrypoint: select backend
9.  Retry loop:
    a. Connect to upstream (Connector.get_http_session)
    b. connected_to_upstream() → notify user
    c. upstream_request_filter() → modify request for upstream
    d. Proxy request (H1) → upstream
    e. upstream_response_filter() → inspect upstream response
    f. response_filter() → modify response for client
    g. Write response → client
    h. response_body_filter() → streaming pass-through
    i. On error: fail_to_connect / fail_to_proxy / error_while_proxy
10. response_cache_filter()   → v0.1: no-op (uncacheable)
11. logging()                 → structured log line
12. finish()                  → decide connection reuse, cleanup
```

v0.1 implements steps 1, 3-5 (passthrough), 7 (passthrough), 8 (single fixed backend), 9a-9d (connect+proxyH1+response filter passthrough+write), 10 (no-op), 11 (log line). v0.2 adds retry loop, connection reuse, cache integration, HTTP/2, multiple backends with selection algorithms.

---

## 5. Module label convention

On-disk directories use underscores (`zigora_core`). User-facing module labels in `build.zig` use hyphens (`zigora-core`). `@import("zigora-core")` refers to the module label, not the filesystem. `build.zig` `b.path()` calls must use the underscore form.

---

## 6. v0.1 acceptance test

Same as before, unchanged:

```bash
# upstream
python3 -m http.server 9000 --bind 127.0.0.1 &

# zigora proxy
zig build run -- --backend 127.0.0.1:9000

# client
curl -v http://127.0.0.1:8080/    # returns the directory listing from :9000
```

Plus `zig build && zig build test` exits 0.

---

## 7. Deferred packages (v0.2+)

Full directory map for when they land:

```
lib/
├── zigora_core/          v0.1 — Server, Service, Listeners, HttpServerApp
├── zigora_proxy/         v0.1 — ProxyHttp trait, HttpProxy, Session
├── zigora_http/          v0.1 — RequestHeader, ResponseHeader, HeaderMap
├── zigora_error/         v0.1 — Error, ErrorType, ErrorSource
├── zigora_lb/            v0.2 — Backend, Backends, LoadBalancer, BackendSelection
│   └── uses: zigora_ketama/ (consistent hash ring)
├── zigora_cache/         v0.2 — HttpCache, CachePhase, Storage, HitHandler, MissHandler, EvictionManager
│   ├── uses: zigora_lru/
│   └── uses: zigora_memory_cache/ (→ uses: zigora_tinyufo/)
├── zigora_limits/        v0.2 — Rate, Inflight, Estimator
├── zigora_tls/           v0.2 — TLS accept/connect adapter
├── zigora_pool/          v0.2 — ConnectionPool, PoolNode
├── zigora_ketama/        v0.2 — Continuum (nginx-compatible consistent hashing)
├── zigora_lru/           v0.2 — sharded weighted LRU
├── zigora_memory_cache/  v0.2 — MemoryCache (TinyUFO-backed)
├── zigora_tinyufo/       v0.2 — TinyUfo (S3-FIFO + TinyLFU cache algorithm)
├── zigora_metrics/       v0.2 — Prometheus /metrics endpoint + Admin status page
├── zigora_utils/         shared helpers (may stay minimal forever)
└── root.zig              umbrella re-exports
```

---

## 8. Design decisions recorded

- **No tokio port.** Pingora's `pingora-runtime` and `pingora-timeout` crate equivalents are absorbed by `std.Io`. The per-core event loop model is Pingora's `NoStealRuntime` path, already implemented in `std.Io.net` + `std.Io.Dispatch`. Documented so no agent attempts to port tokio.
- **Pingora is a library; Zigora is a bin.** Unlike Pingora's pure-library model, Zigora ships `src/main.zig` as one concrete instantiation of `Server + ProxyHttp`. Library consumers `@import("zigora")` to compose their own. `src/main.zig` is the reference implementation.
- **ProxyHttp trait is v0.1 minimum.** The 30+ Pingora callbacks compress to 3 in v0.1 (new_ctx, upstream_peer, logging). Others default to passthrough. Add retry, cache, body filtering callbacks as features land.
- **Error type is first — shared by everything.** In Pingora, `pingora-error` has zero dependencies. In Zigora, `zigora_error` must land before any other package uses structured errors. Current v0.1 code uses raw Zig error sets — should be migrated to `zigora_error.Error` before v0.2.
- **Package re-exports must align with Pingora's `prelude` pattern.** Each Zig `root.zig` re-exports its public surface under a short prefix (`zigora-Error::new_up`, etc.) so library consumers can import one name and use dotted access.

---

## 9. Implementation status (v0.2 phase 1 + 2.6)

Phase 1 (v0.1.1 tag) — **complete**. See `V0.2_ROADMAP.md` for the plan.

| Package | Public API | Notes |
|---|---|---|
| `zigora_limits` | `Estimator` (Count-Min Sketch, atomic `isize`), `Inflight` + `Guard` (auto-decrement on `deinit`), `Rate` (red/blue slot toggle) | Lock-free `Estimator`; `Rate` is mutex-free via atomics. |
| `zigora_lru` | `Lru(T, N).init/admit/promote/remove/evictShard/evictToLimit/peek/peekWeight` | N shards, `std.Thread.Mutex` per shard. Order is a `std.ArrayList(u64)`. |
| `zigora_ketama` | `Continuum.init/node/nodeIdx/getAddr`, `Bucket` | V1 only (no v2 packed repr). `std.hash.Crc32`, 160 pts/weight. |
| `zigora_tinyufo` | `TinyUfo(T).get/put/forcePut/remove`, `KV(T)` | One mutex (Pingora's crate is lock-free). S3-FIFO + TinyLFU admission. |
| `zigora_http` (additions) | `ResponseHeader.parse/toH1Wire`, `headersToH1Wire`, `HttpTask` union | No `CaseMap` struct — `Header.name` keeps original case. |
| `zigora_core` (refactor) | `Server.runForever` uses `io.async` + `Future.await`; `Service.startService` uses `Group.concurrent` per conn | No `std.Thread.spawn` anywhere. |

Phase 2 (v0.2.x tags) — progress:

| Package | Status | Notes |
|---|---|---|
| `zigora_pool` (2.6) | **complete** | Single-mutex port of `pingora-pool`. `ConnectionPool(S)` with size cap; no idle watcher. |
| `zigora_memory_cache` (2.7) | pending | Wraps `TinyUfo`. |
| `zigora_lb` (2.8) | pending | Uses `zigora_ketama` for `Consistent`. |
| `zigora_cache` (2.9) | pending | Largest surface — `HttpCache` + `Storage`/`HitHandler`/`MissHandler` traits. |