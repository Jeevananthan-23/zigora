# Zigora libxev I/O backend — Plan (v1)

Status: proposed. All work happens in a dedicated worktree (`zigora-xev`) so
`ai/dev` stays green on `std.Io`.

## 0. Context / why

Zigora's proxy currently runs on `std.Io.Threaded`. Benchmarks
(`BENCHMARK.md`, `V0.4_ROADMAP.md` §3.1) show its ceiling: one blocking
`poll()` per in-flight op -> one worker thread per op (305 threads @ c100),
LIFO run-queue starvation of long keep-alive chains -> c100 median 3-7ms with
a ~200ms tail, clean only at <=8 conns. The roadmap names the fix:
*"swap `Io.Threaded` for an evented backend."* We build that swap on **libxev**
(TigerBeetle-style driver; io_uring/epoll/kqueue) in a separate worktree so
`ai/dev` stays green.

Concurrency model = **Pingora's `NoStealRuntime`** (faithful to the library we
are porting), scaled across cores via the **TigerBeetle "each thread its own
loop"** structure. Details in §4.

## 1. Baseline

- Branch: `ai/dev` @ `8da2879` (HEAD) + uncommitted NoSteal WIP
  (`lib/zigora_core/runtime.zig` + edits in core/service/proxy/main).
- Deps: Zig `0.16.0`, no network (offline builds).
- Local libxev checkout: `/home/jeeva/projects/zig/libxev` @ `9ce8e8e`
  (Zig 0.16 compatible), exposes module `xev`.

## 2. Issues at baseline

| # | Issue | Where | Note |
|---|---|---|---|
| 1 | Thread-per-op runtime; 305 threads @ c100; LIFO starvation | `V0.4_ROADMAP.md` §3.1 | root reason for the xev port |
| 2 | NoSteal WIP uncommitted (4 files + `runtime.zig`) | `ai/dev` | must be committed/stashed before branching |
| 3 | Upstream pool returns dead conns; disabled (ponytail) | `proxy/root.zig:426`, `main.zig:160` | needs liveness probe before reuse (pool §3.2) |
| 4 | Chunked POST body forwarding not implemented | `proxy/root.zig` body loop | headers-only today |
| 5 | No backend health check | `V0.4_ROADMAP.md` §3.3 | dead backends keep receiving ring traffic |
| 6 | No structured request logging | `V0.4_ROADMAP.md` §3.4 | `logging` callback unused |
| 7 | No determinism gate for benchmarks | `V0.4_ROADMAP.md` §3.5 | spread 1K-19K req/s; worse in debug |
| 8 | Graceful-drain + e2e hygiene unverified | `BUGS.md` | mostly fixed at HEAD; verify after xev port |

Items 1-2 are the focus of this backend work; 3-8 carry over, mostly
independent of the backend choice.

## 3. Research summary (what the port must match)

### Pingora `NoStealRuntime` (`pingora-runtime/src/lib.rs`, local checkout)

- N threads, each hosting a **tokio current-thread runtime**; the thread waits
  on a oneshot channel `block_on(rx)`, idle until work, shuts down on signal;
  `shutdown_timeout` sends duration to each channel then joins.
- `current_handle()` returns a random engine `Handle` for **each spawned task**
  (per-connection dispatch). `Runtime::get_handle()` is the random-handle path.
- `run_endpoint` (`services/listening.rs`): accept loop on one runtime; each
  accepted stream -> `current_handle().spawn(handle_event)`; `handle_event`
  loops `process_new -> process_new` on the **same** task/engine, so a
  keep-alive connection stays pinned to its engine.
- The uncommitted Zigora `runtime.zig` (`getRandomIo`, engine 0 = accept) is a
  correct model of this shape; we swap the backend, keep the structure.

### TigerBeetle IO driver (`src/io/linux.zig`) — libxev's genome

- **Single-threaded by design** (determinism); the N=1 case of NoSteal, not
  the multi-engine version.
- Driver: `run()` / `run_for_ns(ns)` = flush submissions + copy completions
  into an intrusive `Completion` list, then drain callbacks (no recursion,
  bounded stack), then re-flush submissions queued while running. Time-bounded
  tick so the loop observes shutdown/state between ticks.
- `next_tick()` = deferred callback with no kernel I/O; `event_trigger` /
  `event_listen` = eventfd pair for cross-thread wake. Result carries on the
  `Completion`, callback runs later. Proactor abstraction across
  io_uring/kqueue.
- Blog recommendation for embarrassingly parallel workloads (web servers):
  **multiple threads, each its own queue** — verbatim NoSteal.

### libxev (`9ce8e8e`) — what we actually consume

- Package module: `xev`. Backend = io_uring default on Linux, epoll fallback.
- `xev.Loop.init` / `run(.until_done|.once|.no_wait)` / `stop` / `stopped`;
  `xev.Timer`.
- `xev.TCP.init/initFd/bind/listen/accept/connect/shutdown/close`.
- `xev.Stream.read/write/queueWrite/close/poll`; Buffer types.
- `xev.Async` (eventfd) for cross-thread wake.
- Important: libxev does **not** implement `std.Io` — no `Reader`/`Writer`,
  no `peekGreedy`, no `Io.Limit`. The port needs an adapter (§4, M3).

## 4. Migration surface — every file touching `std.Io`

| File | Uses `std.Io` | Xev replacement |
|---|---|---|
| `server.zig` | `io.async`, `Io.Future`, `slot.start(io, alc)` | services run on engine loops; `runForever` drives engine threads |
| `service.zig` | `Io.Group`, `io.async`, accept loop, `net.Stream` | accept via `xev.TCP.accept` on accept engine; dispatch via `xev.Async.notify`; shutdown via flag + `loop.stop` |
| `listeners.zig` | `net.Server`, `net.IpAddress.listen` | -> `xev.TCP` bind/listen (keep `addTcp` parsing + tests) |
| `runtime.zig` | `Io.Threaded` engines | -> xev engine runtime (same NoSteal shape) |
| `proxy/root.zig` | `Io.Writer`, `Io.Reader`, `Lim`, `receiveTimeout`, `net.Stream` r/w, `net.IpAddress.connect` | facade (`peekGreedy`/`discard`/`writeAll`/`flush`/`connect`/`close`/idle-ping) over `xev.TCP`/`xev.Stream`; pool -> `ConnectionPool(xev.TCP)` |
| `metrics/root.zig` | `Io.Writer` | facade writer |
| `pool/root.zig` | `ConnectionPool(Stream)` | type-param change only |
| `lb/root.zig` | `std.Io.net.IpAddress` parse/eql/getPort | keep — compatible (`xev` uses `net.Address.fromIpAddress`) |
| `main.zig` | `Io.Writer` callbacks, `runForever` | facade writer; build xev runtime, run engine threads |

## 5. Runtime design — `XevRuntime` (mirrors Pingora NoSteal)

```
XevRuntime                       lib/zigora_core/runtime_xev.zig
|-- engines: []Engine                       N = n_cpu
|     Engine { loop: *xev.Loop,
|               thread: std.Thread,
|               async: xev.Async,         // eventfd (Tiger event_listen)
|               stop: shared flag }
|-- [0] accept engine (acceptorLoop: xev.TCP accept completion re-arm loop,
|                       bounded by periodic Timer -> shutdown-flag check per tick)
|-- dispatch(conn): engine = rand in [1,N)      (Pingora current_handle)
|                   accept thread -> xev.Async.notify(target)
|-- shutdown:      flag.store(true); close listener fd (wakes accept);
|                  loop.stop() per engine; join threads    (Pingora shutdown_timeout)
```

- A connection handler runs synchronously on its pinned engine thread: callback
  entry -> blocking body -> nested `loop.run()` drives the connection's own
  read/write completions. Keep-alive stays pinned (Pingora `handle_event`).
- Each loop owns one private io_uring ring (SPSC, no cross-thread ring
  locking) — the validated thread-per-core shape.

## 6. Milestones

- **M0 — Baseline lock.** Commit or stash the WIP on `ai/dev`;
  `zig build && zig build test` green.
- **M1 — Worktree + deps.** Create `zigora-xev` worktree; add libxev as a
  **path** dependency (no network fetch) in `build.zig.zon`/`build.zig`;
  wire the `xev` module into core/proxy/main; smoke-link the exe with a
  `@import("xev")` reference.
- **M2 — Runtime core.** `runtime_xev.zig`: engine-thread bootstrap
  (`xev.Loop.init`, `xev.Async.init`), accept loop
  (`xev.TCP` bind/listen/accept re-arm + Timer tick + stop), shutdown path,
  dispatch helper. Single-loop stage first (accept+conns on one loop), then
  extend to N engines (M5).
- **M3 — IO facade.** `lib/zigora_io/`: `Io.Reader`-equivalent
  (`read`/`peekGreedy`/`discard`/`Limit`) and `Io.Writer`-equivalent
  (`writeAll`/`flush`) over `xev.TCP`/`xev.Stream`; `connect`; `close`;
  `shutdown(.send)`; idle-ping probe via `xev.Timer` (replaces the
  `receiveTimeout`-drain keep-alive probe); each op = one completion + nested
  `loop.run` until set.
- **M4 — Port proxy/main/metrics.** Swap imports; upstream `connect` ->
  `xev.TCP.connect`; pool -> `ConnectionPool(xev.TCP)`;
  `/metrics` + `/admin` render via facade writer; keep-alive loop and
  `session.upstream_body` through the facade; leak-check (DebugAllocator) per
  request.
- **M5 — Multi-engine + dispatch.** Engines N; accept on `[0]`; per-connection
  random dispatch `[1,N)`; keep-alive pinned; `wrk -t4 -c100` gate (goal:
  sub-ms median, no ~200ms tail) vs `std.Io` numbers.
- **M6 — Verification + docs.** keep-alive e2e, SIGTERM/SIGINT idempotent,
  memory-leak check, CHANGELOG entry, update `V0.4`/`ARCHITECTURE` notes, this
  doc.

## 7. Verification gates

```
zig build && zig build test
test/e2e_all.sh                       # proxy keep-alive + shutdown e2e
./zigora --backend 127.0.0.1:9000 &   wrk -t4 -c100 vs node/python upstream
# expect: no thread-per-op, sub-ms median, no 200ms tail (vs std.Io today)
env ZIGORA_BACKEND=xev ...            # optional build-time flag if dual-backend is wanted later
```

## 8. YAGNI / boundaries

- No bespoke completion-queue layer — libxev inherits TigerBeetle's driver.
- No callback/CPS rewrite of the proxy — a small synch-style adapter keeps the
  state machine.
- No build-flag dual-backend initially: git worktrees are the switch, per
  earlier decision.

## 9. Worktree setup (actual commands, run after approval)

```sh
cd /home/jeeva/projects/zig/zigora
git add -A && git commit -m "wip(core): std.Io NoStealRuntime baseline"
git worktree add /home/jeeva/projects/zig/zigora-xev -b feat/xev-io ai/dev
cd /home/jeeva/projects/zig/zigora-xev
# M1: add libxev path dep in build.zig.zon + build.zig, wire xev module
zig build && zig build test
```

## 10. Open items

1. Commit vs stash the WIP at M0. (Recommend: commit on `ai/dev`, then branch
   off it.)
2. Pin libxev to the local `9ce8e8e` via `.path`; document the pin.
3. Accept engine = `[0]` only (parity with Pingora's one-listener runtime);
   consider all-engine accept for fancier load balancing only if numbers demand.
4. DETERMINISM gate for the proxy bench (3x spread < 2x,  V0.4 §3.5) — decide in M6.