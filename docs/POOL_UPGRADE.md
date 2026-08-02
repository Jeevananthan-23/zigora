# Upstream Connection Pool Upgrade (V0.4 3.2)

Scope of the pool makeover: make `ConnectionPool` return *live* connections so
`upstream_pool` can be re-enabled in `zigora`, match Pingora's pool shape
without hand-rolling lock-free primitives, and add timeout-based idle
eviction. See `V0.4_ROADMAP.md` §3.2 for the originating requirements.

## Current state (why it's disabled)

- `src/main.zig:160` comments out `proxy_app.upstream_pool = &state.upstream_pool`.
- `lib/zigora_proxy/root.zig:426`:
  `p.get(pool_key) orelse net.IpAddress.connect(...)` — the pool can hand back
  a `Stream` whose peer already closed it; the first write then fails the
  dispatch (mitigated only by the `max_retries = 1` retry loop).
- `lib/zigora_pool/root.zig` today: one global `Mutex` + per-key `PoolNode`
  (`ArrayList` + O(n) `orderedRemove(0)`), cap-hit ⇒ reject-new. No liveness,
  no TTL.

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
   - `PoolNode(S)`: 16-slot fixed ring (`[16]?Entry` + head/tail/count) +
     `ArrayList` spillover; `getAny`/`insert` O(1) on the hot path.
   - Entry gains `put_idle_at: i64` (monotonic clock).
   - `ConnectionPool(S)` gains opts: `idle_ms: u64 = 0`, `is_live`,
     `destroy`; `get` performs lazy liveness+TTL dropping.
2. **`src/main.zig`**
   - `AppState` gains `upstream_pool: pool.ConnectionPool(Stream)`
     (`size_limit = 16`, `idle_ms = 5000`).
   - `is_live`/`destroy` closures: peek on `.socket.handle`; close via
     `runtime.acceptIo()` (any engine's io works for close).
   - Re-enable `proxy_app.upstream_pool`; drop the ponytail comment.
   - Metrics: `pool_reuse`, `pool_stale` counters rendered in `/metrics`.
3. **`lib/zigora_proxy/root.zig`**: no changes (contract unchanged).
4. **Docs**: `V0.4_ROADMAP.md` §3.2 + `CHANGELOG.md`.

## Deferred (roadmap bullets we are not building now)

- Lock-free CAS hot queue (crossbeam ArrayQueue equivalent) — std 0.16 has no
  MPMC ring; not justified until a contention benchmark shows the mutex.
- Pingora's LRU eviction — keep existing size-limit reject-new.
- Background idle watcher task — lazy `get` checks cover correctness.
- Per-engine (thread-local) pools — deferred topology option.

## Verification

- `zig build && zig build test` — pool tests cover FIFO ring order, stale
  drop via `destroy`, `is_live` rejection, ring spill/underflow.
- Miss-path bench (node upstream, **unique** paths so cache always misses but
  the backend key stays stable): toggle pool on/off, 2-3 runs; assert
  `pool_reuse > 0` in `/metrics`, read errors ≈ 0, Debug shutdown clean.