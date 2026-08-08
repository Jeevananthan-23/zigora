# Upstream Connection Pool Upgrade (V0.4 3.2)

Scope of the pool makeover: make `ConnectionPool` return *live* connections so
`upstream_pool` can be re-enabled in `zigora`, match Pingora's pool shape
without hand-rolling lock-free primitives, and add timeout-based idle
eviction. See `V0.4_ROADMAP.md` §3.2 for the originating requirements.

## Current state

- `src/main.zig` wires `proxy_app.upstream_pool = &state.upstream_pool`
  (re-enabled 2026-08-08; was disabled pending liveness).
- `lib/zigora_proxy/root.zig:426`:
  `p.get(pool_key) orelse net.IpAddress.connect(...)` — if the pool hands back
  a dead `Stream` (peer closed it), the first write fails the dispatch
  (mitigated by the `max_retries = 1` retry loop); the connected state is
  caught at `get` time by the TTL / `is_live` checks.

## Decisions (2026-08-02, researched against pingora-pool source)

| Question | Decision |
|----------|----------|
| Pool topology | **Global** single pool (NoSteal engines share it). Per-engine shards deferred until a contention bench demands them. |
| Pool node shape | **Pingora-shape, no lock-free**: 16-slot fixed ring (hot) + `ArrayList` overflow (cold), per-node mutex. std 0.16 has no MPMC ring to build on; a CAS ring is for a saturated pool. |
| Idle detection | **Lazy checks on `get`**: `MSG_PEEK` on pop + TTL stamp. No watcher thread, no socket options. |

Liveness mechanics (`posix.recv(fd, MSG.PEEK | MSG.DONTWAIT)`), passive, zero
bytes on the wire:

| recv result | meaning | action |
|-------------|---------|--------|
| `0` | peer FIN / closed | drop |
| `EAGAIN` / `WouldBlock` | alive | reuse |
| `> 0` bytes | leftover data (protocol desync) | drop |
| `ConnectionResetByPeer` / other error | dead | drop |

Half-open death (no FIN, e.g. network partition) is invisible to PEEK; the
TTL stamp bounds staleness to `idle_ms`.

## Caller-ownership seam

The pool is generic over `S` and cannot close a `Stream`. So the pool is
configured with two closures instead of doing socket work itself:

- `is_live: ?fn (?*anyopaque, *S) bool`
- `destroy: ?fn (?*anyopaque, *S) void`

`get` pops entries and drops dead/stale ones via these closures (bounded to
≤ 8 pops to avoid mass-death cascades), returning the first live, fresh
entry (or null). Caller-facing contract (`?S`, then `orelse connect`)
is unchanged, so `root.zig` dispatch needs no edits.

## File by file

1. **`lib/zigora_pool/root.zig`**
   - `PoolNode(S)`: hot ring is `stdx.queue.ArrayQueue(Entry, 16)` (FIFO, no
     manual head/tail) + `ArrayList` spillover (LIFO tail-pop); `remove(id)`
     drains/repushes the ring and scans the spill.
   - Entry gains `put_idle_at: i64` (linux monotonic clock via
     `std.os.linux.clock_gettime(.MONOTONIC)`).
   - `ConnectionPool(S)` gains opts: `idle_ms: u64 = 0`, `is_live`,
     `destroy`; `get` performs lazy liveness+TTL dropping (bounded to 8 pops
     so a mass-death burst drains across subsequent gets).
   - Tests: 7 cases (ring FIFO, spill LIFO, remove-by-id, TTL drop via
     `destroy`, `is_live` reject/reuse, size-cap reject) — wired as a real
     `zigora-pool` test step in `build.zig` (pool tests never ran before;
     `src/root.zig` does not import the pool module).
2. **`src/main.zig`**
   - `AppState` gains `upstream_pool: pool.ConnectionPool(Stream)`
     (`size_limit = 16`, `idle_ms = 5 * std.time.ns_per_s`).
   - `is_live`/`destroy` closures: peek on `.socket.handle`; close via
     `runtime.acceptIo()` (any engine's io works for close).
   - Metrics: `pool_reuse` (live PEEK on reuse), `pool_stale` (TTL/`is_live`
     drops) rendered in `/metrics` + admin table.
3. **`lib/zigora_proxy/root.zig`**: put path unchanged (contract unchanged).
4. **Docs**: `V0.4_ROADMAP.md` §3.2 + `CHANGELOG.md`.

## Deferred (roadmap bullets we are not building now)

- Hook the hot ring to `std.Io.Queue` — evaluated (2026-08-08):
  `std.Io.Queue` on 0.16 is an MPMC FIFO that needs an `io` per op, blocks
  (non-blocking via `min = 0` forms) and, unlike `stdx.queue.ArrayQueue`,
  exposes **no `len()` and no `remove(id)`** — both the per-key capacity
  accounting and the connection-id removal rely on those. Kept the
  `ArrayQueue` ring. Upgrade path if a contention bench ever demands a real
  MPMC: adopt `stdx.Io.Queue` behind the idle-limiter gate (drop
  `total_size` accounting by trusting the limiter's in-flight count).
- Lock-free CAS hot queue (crossbeam ArrayQueue equivalent) — std 0.16 has no
  MPMC ring; not justified until a contention benchmark shows the mutex.
- Pingora's LRU eviction — keep existing size-limit reject-new.
- Background idle watcher task — lazy `get` checks cover correctness.
- Per-engine (thread-local) pools — deferred topology option.

## Verification

- `zig build && zig build test` — pool tests (7) cover FIFO ring order, spill
  LIFO, remove-by-id, TTL drop via `destroy`, `is_live` rejection, size-cap.
- Miss-path bench (node upstream on :9000, **unique** paths — `/bench/N/<r>`
  — so the cache never serves them but the backend key stays stable; wrk lua
  must use `--` Lua comments, `//` silently falls back to `GET /` and the
  cache path masks everything): 10s `wrk -t4 -c100` measured
  `pool_reuse ≈ 6k` on ~6.2k miss-path requests, `pool_stale ≈ 2`, read
  errors ≈ 0, Debug shutdown clean.