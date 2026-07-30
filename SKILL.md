# zigora Skill — Zig Port of Cloudflare Pingora

## Project Overview
**zigora** is a Zig port of Cloudflare's **Pingora** HTTP reverse proxy framework. Unlike Pingora (library-only), zigora ships as a **binary** (`src/main.zig`) with a public library (`src/root.zig`) for consumers.

**Target**: Zig 0.16.0+ (see `build.zig.zon`). Offline builds work — no fetch step.

---

## Architecture & Package Map

```
src/
├── main.zig          # Binary entry: Server + ProxyHttp reference impl
└── root.zig          # Public library umbrella (re-exports all v0.1+ packages)

lib/
├── root.zig          # Internal umbrella re-exports all 17 packages
├── zigora_core/      # [v0.1] Server, Service, Listeners, ServerApp
├── zigora_proxy/     # [v0.1] ProxyHttp trait, HttpProxy, Session
├── zigora_http/      # [v0.1] RequestHeader, ResponseHeader, HeaderMap
├── zigora_error/     # [v0.1] Error, ErrorType, ErrorSource
├── zigora_limits/    # [v0.1.1] Estimator, Inflight, Rate
├── zigora_lru/       # [v0.1.1] Sharded weighted LRU
├── zigora_ketama/    # [v0.1.1] Consistent hash ring (Continuum)
├── zigora_tinyufo/   # [v0.1.1] S3-FIFO + TinyLFU cache
├── zigora_pool/      # [v0.2.6] ConnectionPool + PoolNode
├── zigora_memory_cache/ # [v0.2.7] TinyUFO-backed memory cache
├── zigora_lb/        # [v0.2.8] LoadBalancer + 4 selectors
├── zigora_cache/     # [v0.2.9] HTTP cache state machine
├── zigora_tls/       # [v0.2 phase 3] TLS accept/connect
├── zigora_metrics/   # [v0.2 phase 4] Prometheus /metrics
├── zigora_cache/     # (reserved)
└── zigora_utils/     # (reserved, minimal)
```

**Module label convention**:
- On-disk dir: `zigora_core` (underscore)
- `build.zig` label: `zigora-core` (hyphen)
- Import: `@import("zigora-core")`
- `b.path()` uses underscore: `b.path("lib/zigora_core/root.zig")`

---

## Dependency Graph (v0.1)
```
zigora_proxy → zigora_core, zigora_http, zigora_error
zigora_core  → zigora_http, zigora_error
zigora_http  → (none)
zigora_error → (stdlib only)
```

---

## Build & Test Commands
```bash
zig build                    # builds zigora exe → zig-out/
zig build run -- --backend 127.0.0.1:9000
zig build test               # runs both lib tests + exe tests in parallel
zig build --release=fast|safe|small
```

**Verification gate**: `zig build && zig build test` must pass cleanly.

---

## Async / I/O Model (v0.1.1+)
- **No manual `std.Thread.spawn`** anywhere in framework.
- Uses `std.Io` worker pool (Threaded/Uring/Evented) via `io.async` + `Future.await`.
- Services use `Group.concurrent` for per-connection dispatch.
- Key files: `lib/zigora_core/server.zig`, `lib/zigora_core/service.zig`

---

## Key Implementation Notes

### Zig-Pingora Design Shifts
1. **No async runtime** — `std.Io` replaces tokio
2. **No `pingora-timeout`** — `std.Io.Timeout` covers it
3. **Binary ships** — `src/main.zig` = reference `main()` equivalent
4. **Phase 1 packages are pure unblockers** — zero internal deps
5. **No `CaseMap`** — Zig `Header.name` preserves original case; `headersToH1Wire` preserves case in one pass

### v0.1 Acceptance Test
```bash
python3 -m http.server 9000 --bind 127.0.0.1 &
zig build run -- --backend 127.0.0.1:9000
curl -v http://127.0.0.1:8080/   # proxies to :9000
```

---

## Wiring Rules (Critical for Build)
1. Every package reachable from `src/main.zig` or `src/root.zig` **must** be a named module in `build.zig` via `b.addModule()`.
2. Every module importing another **must** list it in `.imports`.
3. `lib/root.zig` **must** `pub const zg<name> = @import("zigora_<name>/root.zig");` for every on-disk package (even stubs).
4. Tests: `b.addTest(.{.root_module = mod })` for lib; `b.addTest(.{.root_module = exe.root_module })` for exe. Both run in parallel via `test` step.

---

## Current Status (v0.2 phase 1 + 2.6 complete)
| Package | Status | Notes |
|---------|--------|-------|
| zigora_limits | ✅ | Estimator (Count-Min), Inflight+Guard, Rate (red/blue atomic toggle) |
| zigora_lru | ✅ | N-shard, Mutex per shard, weighted LRU |
| zigora_ketama | ✅ | Continuum, CRC32, 160 pts/weight, v1 only |
| zigora_tinyufo | ✅ | S3-FIFO + TinyLFU, single mutex |
| zigora_http (adds) | ✅ | ResponseHeader, headersToH1Wire, HttpTask |
| zigora_core (refactor) | ✅ | io.async + Group.concurrent, no Thread.spawn |
| zigora_pool | ✅ | Single-mutex, size cap, no idle watcher |
| zigora_memory_cache | ⏳ | Wraps TinyUFO |
| zigora_lb | ⏳ | Uses ketama for Consistent |
| zigora_cache | ⏳ | HttpCache + Storage/HitHandler/MissHandler traits |

---

## Common Tasks & Patterns

### Adding a New Package
1. Create `lib/zigora_newpkg/root.zig`
2. Add module in `build.zig` with `b.addModule("zigora-newpkg", ...)`
3. Add import in `lib/root.zig`: `pub const zgnewpkg = @import("zigora_newpkg/root.zig");`
4. Add to `src/root.zig` imports if public-facing
5. Run `zig build && zig build test` to verify wiring

### Importing Internal Package
```zig
// In build.zig module definition:
.imports = &.{ .{ .name = "zigora-core", .module = core_mod } }

// In source:
const zgcore = @import("zigora-core");
```

### Running Tests for Specific Package
```bash
zig build test --summary all  # shows per-module results
```

---

## Key Files to Reference
- `ARCHITECTURE.md` — Authoritative Pingora→Zigora map, dependency graph, design decisions
- `V0.2_ROADMAP.md` — Phased implementation plan with checkboxes
- `AGENTS.md` — Toolchain, commands, wiring conventions (this file's source)
- `build.zig` — Module registry & dependency wiring
- `lib/root.zig` — Umbrella re-exports all packages
- `src/root.zig` — Public library surface
- `src/main.zig` — Binary entry, reference implementation

---

## Ponytail Notes (Intentional Simplifications)
- `zigora_error` currently stub — v0.1 uses raw Zig error sets; migration to structured `Error` is a v0.2 task
- `zigora_lru` uses `std.Thread.Mutex` per shard (Pingora is lock-free) — `ponytail: upgrade to lock-free if contention measured`
- `zigora_tinyufo` uses single mutex (Pingora is lock-free) — `ponytail: same`
- `zigora_ketama` implements v1 only (no v2 packed repr) — `ponytail: v2 if wire-compat needed`
- `zigora_pool` has no idle watcher — `ponytail: add if connection churn observed`

---

## Versioning & Release
- Phase 1 milestones → `v0.1.x` tags
- Phase 2+ → `v0.2.x` tags
- Each tag updates `CHANGELOG.md` with package additions & notable changes
- Clean `zig build && zig build test` is the only "green" signal