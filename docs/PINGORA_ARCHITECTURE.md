# Pingora Architecture Reference

Authoritative source for Pingora crate boundaries, type shapes, and inter-crate dependencies. Used as the reference spec for the Zigora port. See `ARCHITECTURE.md` for the Zigora-side mapping.

---

## 1. Top-level directory structure

```
/home/jeeva/projects/rust/pingora/
├── .cargo/
├── .github/
├── Cargo.toml                  # Workspace root (21 member crates + tinyufo)
├── Cargo.lock
├── README.md
├── CHANGELOG.md
├── clippy.toml
├── cliff.toml
├── Dockerfile
├── LICENSE
├── docs/                       # User guide, quick start
│   ├── assets/
│   ├── user_guide/             # 19 markdown docs
│   └── quick_start.md
├── pingora/                    # Umbrella crate (library, no bin)
│   └── src/lib.rs
├── pingora-core/               # Core protocols, server, services, connectors
├── pingora-proxy/              # HTTP proxy framework (ProxyHttp trait)
├── pingora-cache/              # HTTP caching layer
├── pingora-http/               # Case-preserving HTTP header types
├── pingora-error/              # Unified Error type
├── pingora-load-balancing/     # Service discovery, health check, selection
├── pingora-limits/             # Rate limiting, inflight control, event estimation
├── pingora-pool/               # Connection pool (L4 connection reuse)
├── pingora-runtime/            # Tokio runtime (work-steal / no-steal)
├── pingora-timeout/            # High-perf async timer / timeout
├── pingora-lru/                # Sharded LRU with weight tracking
├── pingora-memory-cache/       # Async in-memory cache (TinyUFO) + read-through
├── pingora-ketama/             # nginx-compatible consistent hash ring
├── pingora-header-serde/       # HTTP header dict compression (zstd)
├── pingora-openssl/            # TLS: OpenSSL bindings
├── pingora-boringssl/          # TLS: BoringSSL bindings
├── pingora-rustls/             # TLS: rustls bindings (experimental)
├── pingora-s2n/                # TLS: s2n-tls bindings
├── pingora-prometheus/         # Prometheus metrics HTTP endpoint
├── tinyufo/                    # Standalone TinyLFU + S3-FIFO cache algorithm
└── target/
```

---

## 2. Workspace crates and responsibilities

| Crate | Responsibility |
|---|---|
| `pingora` (lib only) | Umbrella crate re-exporting all sub-crates. Feature-gated: `proxy`, `lb`, `cache`, `time`. `@import("pingora")` is the public face. |
| `pingora-core` | Core protocols (L4, TLS, HTTP/1, HTTP/2), the `Server` orchestrator, the `Service` abstraction, `Listeners`, `Connector`s, `Peer` trait, upstream connection management, `ServiceConf`, CLI `Opt`. The heart of the framework. |
| `pingora-proxy` | HTTP proxy logic. Defines `ProxyHttp` trait (the filter chain), `HttpProxy` struct, `Session` (the request context object). Handles H1/H2/custom upstream proxying, retry/failover, subrequests, cache integration, upstream/downstream modules. |
| `pingora-http` | Case-preserving `RequestHeader` / `ResponseHeader` wrapped around `http::Parts`. Needed for transparent HTTP/1.x proxying. |
| `pingora-error` | `Error` struct with `ErrorType` (connect/protocol/io/application), `ErrorSource` (Upstream/Downstream/Internal), `RetryType`, chain support. Shared by everything. |
| `pingora-cache` | HTTP caching state machine: `HttpCache` (phase-driven: Disabled -> CacheKey -> Hit/Miss/Stale -> Expired/Revalidated), `Storage` trait, `HitHandler`, `MissHandler`, `CacheMeta`, eviction, cache lock, predictor, variance, max file size tracker. |
| `pingora-load-balancing` | `LoadBalancer<S>` where `S: BackendSelection`. Contains `Backends` (service discovery + health check), `BackendSelection` trait (RoundRobin, Random, FNVHash, Consistent/Ketama), `ServiceDiscovery` trait (static/dynamic), `HealthCheck` trait (`TcpHealthCheck`). Runs as a background service. |
| `pingora-limits` | `rate` (rate limiter), `estimator` (Count-Min event estimation), `inflight` (in-flight counter with auto-decrement `Guard`). Uses `ahash`. |
| `pingora-pool` | `ConnectionPool` for L4 connection reuse. Per-thread-local pools, LRU-based eviction, `Connector` takes a pool to reuse connections. |
| `pingora-runtime` | `Runtime` enum: `Steal` (tokio multi-thread) or `NoSteal` (pool of single-thread tokios). `NoStealRuntime` is more efficient for non-work-stealing workloads. |
| `pingora-timeout` | `fast_timeout` / `fast_sleep`: drop-in replacement for `tokio::time::timeout` with lazy timer init, 10ms tick rounding, no global lock. |
| `pingora-lru` | N-shard `Lru` with weight tracking, eviction, `LinkedList`-based ordered list + `HashMap`. Used by `pingora-cache`/`eviction`. |
| `pingora-memory-cache` | `MemoryCache<K,V>` backed by `TinyUfo` (S3-FIFO + TinyLFU). `RTCache` for read-through / cache-stampede-protection pattern. |
| `pingora-ketama` | `Continuum` ring — Rust port of nginx consistent hashing (CRC32-based). Used by `pingora-load-balancing` for `Consistent` selection. |
| `pingora-header-serde` | Zstd-dictionary-based header (de-)compression for bandwidth saving. |
| `pingora-openssl` / `boringssl` / `rustls` / `s2n` | TLS backends (mutually exclusive at build time). Each provides `tls::accept`, `tls::connect`, `SslDigest`. `pingora-core` imports the selected one as `pub use pingora_x as tls`. |
| `pingora-prometheus` | Serves a `GET /metrics` HTTP endpoint from the `prometheus` crate's registry. |
| `tinyufo` | Standalone S3-FIFO + TinyLFU cache. `TinyUfo<K,T>` with two FIFO queues (small 10% + main), frequency estimator for admission. Uses `SegQueue` (lock-free), atomic usage counters. |

---

## 3. Entrypoint

Pingora is purely a library framework. There is no built-in binary. Consumers build their own `main.rs`:

```rust
// user's main.rs
fn main() {
    let my_server = Server::new(Some(Opt::parse_args())).unwrap();
    let mut my_proxy = http_proxy_service(&my_server.configuration, MyProxy);
    my_proxy.add_tcp("0.0.0.0:8080");
    my_server.add_service(my_proxy);
    my_server.run_forever();
}
```

`Server::run_forever()` / `Server::run()` blocks until a shutdown signal. Example apps exist as integration tests and examples within each crate.

---

## 4. Key types and structs

### 4.1 Server orchestration (`pingora-core`)

| Type | Location | Purpose |
|---|---|---|
| `Server` | `pingora-core/src/server/mod.rs` | Top-level process: holds services, shutdown watch, execution phase, config `ServerConf`, optional `Opt`. Runs services on separate tokio runtimes. Handles SIGQUIT (graceful upgrade), SIGTERM (graceful shutdown), SIGINT (fast shutdown). |
| `ServerConf` | `pingora-core/src/server/configuration/mod.rs` | YAML config: threads, work_stealing, daemon, listen ports, TLS, grace periods, etc. |
| `Opt` | `pingora-core/src/server/configuration/mod.rs` | CLI via clap: `--conf`, daemon flag, `--upgrade`, `--test`. |
| `ExecutionPhase` | `pingora-core/src/server/mod.rs` | State machine: Setup -> Bootstrap -> BootstrapComplete -> Running -> GracefulUpgrade* / GracefulTerminate -> ShutdownStarted -> GracePeriod -> ShutdownRuntimes -> Terminated. |
| `ShutdownWatch` | `pingora-core/src/server/mod.rs` | `watch::Receiver<bool>` broadcast when shutdown begins. Every service and session checks this. |
| `Service<A>` | `pingora-core/src/services/listening.rs` | A listening service wrapping `Listeners` + app logic `A: ServerApp`. Accept loop -> handshake -> `handle_event` -> `reuse_event`. |
| `ServiceTrait` | `pingora-core/src/services/mod.rs` (likely) | `start_service()`, `name()`, `threads()` — the async trait implemented by `Service<A>`. |
| `ServerApp` (trait) | `pingora-core/src/apps/mod.rs` | `process_new(stream: Stream) -> Option<Stream>` — the app abstraction for any protocol. |
| `HttpServerApp` (trait) | `pingora-core/src/apps/http_app.rs` | HTTP-specific app: `process_new_http()`, `h2_options()`, `server_options()`, `process_custom_session()`, `http_cleanup()`. |
| `ServeHttp` (trait) | `pingora-core/src/apps/http_app.rs` | Simple `response(&mut ServerSession) -> Response<Vec<u8>>`. |
| `HttpServer<SV>` | `pingora-core/src/apps/http_app.rs` | Wraps `ServeHttp` + `HttpModules` for a basic HTTP server. |

### 4.2 Proxy framework (`pingora-proxy`)

| Type | Location | Purpose |
|---|---|---|
| `ProxyHttp` (trait) | `pingora-proxy/src/proxy_trait.rs` | The filter chain trait with ~30 async callbacks: `new_ctx()`, `upstream_peer()`, `request_filter()`, `early_request_filter()`, `request_body_filter()`, `request_cache_filter()`, `cache_key_callback()`, `proxy_upstream_filter()`, `upstream_request_filter()`, `upstream_response_filter()`, `response_filter()`, `upstream_response_body_filter()`, `response_body_filter()`, `logging()`, `fail_to_connect()`, `fail_to_proxy()`, `error_while_proxy()`, etc. |
| `HttpProxy<SV, C>` | `pingora-proxy/src/lib.rs` | The concrete bridge between `ProxyHttp` and `HttpServerApp`. Owns the upstream `Connector`, shutdown notify, downstream/upstream modules, `max_retries`. Implements `HttpServerApp::process_new_http`, the full proxy lifecycle: early_filter -> read/parse request -> request_filter -> cache lookup -> proxy_upstream_filter -> usr_peer -> retry loop -> [proxy_to_h1/h2/custom_upstream] -> response_filter -> caching -> logging -> finish. |
| `Session` | `pingora-proxy/src/lib.rs` | The per-request object passed through every `ProxyHttp` callback. Contains: `downstream_session: Box<HttpSession>`, `cache: HttpCache`, `upstream_compression: ResponseCompressionCtx`, `downstream_modules_ctx`, `upstream_modules_ctx`, and methods to read/write header/body/trailers with module filters applied. |
| `http_proxy_service()` | `pingora-proxy/src/lib.rs` | Factory: creates a `Service<HttpProxy<SV>>` from a `ProxyHttp` impl + `ServerConf`. |
| `http_proxy()` | `pingora-proxy/src/lib.rs` | Factory: creates just the `HttpProxy` (for custom accept loops). |

### 4.3 HTTP types (`pingora-http`)

| Type | Purpose |
|---|---|
| `RequestHeader` | `http::request::Parts` + case-preserving header name map + non-UTF8 path support |
| `ResponseHeader` | `http::response::Parts` + case-preserving header name map + reason phrase |
| `HttpTask` | Enum: `Header`, `Body`, `UpgradedBody`, `Trailer`, `Done`, `Failed`. Stream of tasks through the proxy pipe. |
| `ServerSession` | Type alias for HTTP/1 or HTTP/2 server session |

### 4.4 Error framework (`pingora-error`)

| Type | Purpose |
|---|---|
| `Error` | `etype: Error`, `esource: (Upstream/Downstream/Internal/Unset)`, `retry: Decided(bool)/ReusedOnly`, `cause: chain`, `context` |
| `ErrorType` | 40+ variants: `ConnectTimedout`, `ConnectRefused`, `TLSHandshakeFailure`, `InvalidHTTPHeader`, `H1Error`, `H2Error`, `ReadError`, `WriteError`, `HTTPStatus(u16)`, `FileReadError`, `Status(u16)`, `Custom(&str)`, etc. |
| `OrErr<T>` / `Context<T>` | Helper traits on `Result` and `Option` for chaining errors |

### 4.5 Cache framework (`pingora-cache`)

| Type | Purpose |
|---|---|
| `HttpCache` | State machine: Disabled -> Uninit -> CacheKey -> Hit/Miss/Stale/Expired/Revalidated |
| `CachePhase` | Enum tracking lifecycle: `Disabled(NoCacheReason)`, `Uninit`, `Bypass`, `CacheKey`, `Hit`, `Miss`, `Stale`, `StaleUpdating`, `Expired`, `Revalidated`, `RevalidatedNoCache` |
| `Storage` (trait) | `lookup() -> (CacheMeta, HitHandler)`, `get_miss_handler()`, `purge()`, `update_meta()`, `support_streaming_partial_write()` |
| `HitHandler` (trait) | `read_body()`, `finish()`, `can_seek()`, `seek(s, end)` |
| `MissHandler` (trait) | `write_body(data, eof)`, `finish() -> MissFinishType`, `streaming_write_tag()` |
| `CacheMeta` | Every cached asset's metadata: header, internal: `{created, fresh_until, updated}`, extensions |
| `CacheKey` | Multi-component key: `HashBinary` + `variance_hash` + `subrequest_path` |
| `eviction::EvictionManager` (trait) | `admit()`, `access()`, `decrement_weight() -> Vec<CompactCacheKey>` to evict |
| `CacheKeyLockImpl` | Cache lock for concurrent cache miss protection (stampede prevention) |

---

## 5. Load balancing (`pingora-load-balancing`)

| Type | Purpose |
|---|---|
| `Backend` | `addr: SocketAddr`, `weight: usize`, `ext: Extension` |
| `Backends` | Collection of `Backend` + optional `HealthCheck` + `ServiceDiscovery`. Uses atomically-synced `ArcSwap` |
| `ServiceDiscovery` (trait) | `discover() -> (BTreeSet<Backend>, HashMap<u32, bool>)`. Static impl provided |
| `HealthCheck` (trait) | `check(&Backend) -> Result`. `TcpHealthCheck` provided |
| `LoadBalancer<S>` | Holds `Backends` + `ArcSwap<S>` (selection). `select(&self, key, max_iter) -> Option<Backend>`. `update()`, `run_health_check()`. Runs as `BackgroundService` |
| `BackendSelection` (trait) | `build(&BTreeSet<Backend>) -> Self`, `iter(&Arc<Self>, key) -> Self::Iter`. Four impls: RoundRobin, Random, FNVHash, Consistent (Ketama) |
| `SelectionAlgorithm` (trait) | `new()`, `next(key) -> u64`. Implemented by `H: Default + Hash` directly |

---

## 6. Filter chain / modules (`pingora-core` & `pingora-proxy`)

| Type | Purpose |
|---|---|
| `HttpModule` (trait) | `descriptor_filter(header)`, `request_body_filter()`, `response_filter()`, `response_body_filter()`, `response_trailer_filter()`, `response_done_filter()`. Implemented per-type (`ResponseCompression`, `grpc_web`) |
| `ModuleBuilder` | `fn init() -> Module`. Also has `order()` for pipeline ordering |
| `HttpModules` | Collection of `ModuleBuffer`. `build_ctx() -> HttpModuleCtx` (per-request) |
| `HttpModuleCtx` | Runs the module pipeline for each handshake |
| `ResponseCompressionBuilder` | Standard module for Zlib/Gzip/BR/Zstd/Broli content-encoding |

---

## 7. Selection implementation hierarchy

Load balancer selection algorithms:

```
BackendSelection (trait)
├── RoundRobin = Weighted<RoundRobin>     // atomic counter, weighted
├── Random     = Weighted<Random>          // random, weighted
├── FNVHash    = Weighted<FnvHasher>       // deterministic hash, weighted
├── Consistent = KetamaHashing            // ketama consistent hash ring
└── (extensible by users)
```

---

## 8. Inter-crate dependency graph

```
                          pingora (umbrella)
                       /     |       |       \
                      /      |       |        \
        pingora-core  pingora-proxy  pingora-cache  pingora-lb  pingora-timeout
       /  |  |  |  \    |  |  |        |  |  |         \  |
      /   |  |  |   \   |  |  |        |  |  |          \ |
pingora-*  pingora-+ pingora+ pingora-+ pingora-+ pingora-+ pingora-+
runtime   error     pool  http  error   limits   error  lru  ketama
          timeout         http                   header-serde
                          memory-cache
                              |
                           tinyufo
```

Key transitive flows:

- `pingora` depends on: `pingora-core`, `pingora-http`, `pingora-timeout`, and optionally `pingora-proxy`, `pingora-load-balancing`, `pingora-cache`
- `pingora-core` depends on: `pingora-runtime`, `pingora-pool`, `pingora-http`, `pingora-timeout`, and one TLS backend (openssl/boringssl/rustls/s2n)
- `pingora-proxy` depends on: `pingora-core`, `pingora-http`, `pingora-cache`
- `pingora-cache` depends on: `pingora-core`, `pingora-http`, `pingora-header-serde`, `pingora-lru`, `pingora-timeout`
- `pingora-load-balancing` depends on: `pingora-core`, `pingora-http`, `pingora-ketama`, `pingora-runtime`
- `pingora-memory-cache` depends on: `tinyufo`, `pingora-timeout`, `pingora-error`
- `tinyufo` — standalone (no pingora deps)
- `pingora-lru` — standalone (hashbrown, parking_lot)
- `pingora-limits` — standalone (ahash)
- `pingora-error` — zero-dependency (stdlib only)
- `pingora-pool` — depends only on `pingora-timeout`
- `pingora-header-serde` — depends on `pingora-http`, `pingora-error`

---

## 9. Zig port module boundaries (recommended — implemented)

Based on this architecture, the Zig port has these module boundaries:

| On-disk path | Responsibility |
|---|---|
| `lib/root.zig` | umbrella re-export |
| `lib/zigora_core/` | `Server`, `Service`, `Listeners`, `Connectors`, protocols (HTTP/1, 2+, L4, TLS), modules, apps, upstream/`Peer` |
| `lib/zigora_http/` | `RequestHeader`, `ResponseHeader`, `HttpTask` (no deps outside this repo) |
| `lib/zigora_error/` | `Error`, `ErrorType`, `Source`, `Retry` (no deps except std) |
| `lib/zigora_pool/` | `ConnectionPool` (depends on timeout — which for Zig is just `std.Io`) |
| `lib/zigora_limits/` | `Rate` limiter, `Estimator`, `Inflight` (no deps) |
| `lib/zigora_lru/` | Weighted sharded LRU (no deps) |
| `lib/zigora_ketama/` | Consistent hash ring (no deps) |
| `lib/zigora_tinyufo/` | S3-FIFO + TinyLFU cache algorithm (no deps) |
| `lib/zigora_memory_cache/` (reserved) | `MemoryCache` (TinyUFO) + `ReadThroughCache` (depends on `tinyufo`, `timeout`) |
| `lib/zigora_cache/` (reserved) | HTTP caching: `HttpCache`, `Storage`, Hit/Miss handlers, eviction, lock (depends on `core`, `http`, `lru`, `timeout`) |
| `lib/zigora_proxy/` | `ProxyHttp` trait, `Session`, proxy H1/H2 bridge, subrequest (depends on `core`, `http`, `cache`) |
| `lib/zigora_lb/` (reserved) | `Backend`, `Backends`, `LoadBalancer`, selection algorithms, health check (depends on `core`, `ketama`) |
| `lib/zigora_tls/` (reserved) | TLS adapter (boringssl/openssl/rustls interface) (depends on `core`) |
| `lib/zigora_metrics/` (reserved) | Prometheus endpoint (depends on `core`) |

Absorbed by stdlib (no Zig port): `pingora-runtime` → `std.Io`, `pingora-timeout` → `std.Io.Timeout`.

Deferred indefinitely: `pingora-header-serde` (zstd header compression — low priority).

---

## 10. Documentation references

- `/home/jeeva/projects/rust/pingora/README.md` — feature highlights, crate overview, system requirements
- `/home/jeeva/projects/rust/pingora/docs/user_guide/index.md` — 19-page developer user guide covering server operations, proxy phases, setups, extract, etc.
- `/home/jeeva/projects/rust/pingora/docs/user_guide/phase.md` — proxy filter phases chart
- `/home/jeeva/projects/rust/pingora/docs/user_guide/internals.md` — Pingora internals
- Each crate has its own `src/lib.rs` with a doc comment at the top describing its purpose
