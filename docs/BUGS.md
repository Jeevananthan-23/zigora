# BUGS.md — Regression Test Results (2026-08-01)

Testing against Pingora's architecture reference (`PINGORA_ARCHITECTURE.md`) and `ARCHITECTURE.md`. Fixed point: `cf85dc5` (HEAD). Zig 0.16.0, `std.Io.Threaded` runtime.

---

## Bug 1 — SIGTERM causes segfault at address 0x1

**Severity:** FATAL — every SIGTERM/graceful shutdown crashes.

**Root cause:** The signal handler (`src/zigora_core/server.zig:53`) sets `shutdown_flag = true`. The service accept loop in `service.zig:150` polls `sh.?.check()` after every `listener.accept()`. But `accept()` is a blocking poll — it only returns on new connection or error. After SIGTERM is delivered with no incoming connections, the accept loop never wakes up to check the flag. 

When a connection *does* arrive after SIGTERM, the accept loop wakes, sees the shutdown flag, exits `acceptLoop`, then `catches` into `runForever`'s `futures[i].await()` which tries to dereference args that were already freed by the `defer allocator.free(futures)` at line 116 — the `slot` pointer inside the `scan` call was captured from `self.services.items` which is alive, but the future's stack frame had the service future's arg pointer freed.

**Pingora's approach:** Uses `tokio::sync::watch::Receiver::changed()` inside `tokio::select!` alongside `stack.accept()`. The `select!` concurrently polls the accept future AND the watch receiver. When the signal handler sends `shutdown_watch.send(true)`, the select! resolves immediately on the watch path — no blocked accept required. The accept optimization also uses `shutdown_watch.reset()` to clear the received flag, then break out of the loop.

**Zig 0.16 path:** `std.Io` has no evented select equivalent. Options:
1. Use a non-blocking accept with timeout (`std.Io.Timeout`) — polls every N ms, checks shutdown between polls.
2. Use `listener.acceptWritable()` + `listener.acceptReadable()` with a polling variant.
3. Short-circuit: close the listener socket on shutdown, causing `accept()` to return an error, the loop checks the flag and exits. `shutdownWatch.send(true) + listener.close()` would wake the accept immediately.

**Reproduce:**
```bash
./zig-out/bin/zigora --backend "127.0.0.1:9000" &
curl http://127.0.0.1:8080/metrics && kill -TERM %1 && sleep 1 && curl http://127.0.0.1:8080/metrics
# Result: segfault, core dump
```

---

## Bug 2 — Dead backend `127.0.0.1:9001` hardcoded in `BackendCfg.init()`

**Severity:** High — every N-th request fails (every 2nd/3rd depending on `--backend`).

**Root cause:** `src/main.zig:24-28` — `BackendCfg init` always appends `127.0.0.1:9000` AND `127.0.0.1:9001`. When the user runs with `--backend "127.0.0.1:9000"`, the `parseArgs` function (line 171) **appends** rather than **replaces** the default list. Result: 3 backends (`9000, 9001, 9000`) and the 3rd request on the ring-based Consistent hash gets the dead `9001`.

**Pingora compared:** Pingora's `ServerConf` has **no default port**. The address-list is always user-supplied. The example apps pass exactly the expected hosts. Zigora should match: `BackendCfg.init()` should either be empty (only user-provided backends) or have 1 safe default (`127.0.0.1:9000` only).

**Reproduction:**
```bash
./zig-out/bin/zigora --backend "127.0.0.1:9000" &
for i in 1 2 3 4 5; do curl -s -m 2 http://127.0.0.1:8080/ -o /dev/null -w "%{http_code}\n"; done
# Request #3 and #5 return: 000
```

---

## Bug 3 — E2E test script references undefined `$BASE` env var

**Severity:** Low — test script always fails with empty-URL errors, false positives on `/metrics` and `/admin` (matches Python's directory listing).

**Root cause:** `test/e2e_all.sh:8` defines `B="http://127.0.0.1:${PP}"` but lines 20-27 reference `$BASE`. Fix: `s/$BASE/$B/g`.

**Secondary issue:** The `/metrics` check (`grep -q zigora`) and `/admin` check (`grep -qi admin`) can false-positive against the upstream Python http.server's directory listing when the proxy returns `000` (connect refused). Need a stricter regex: `/metric` should match Prometheus comment style (`# HELP`), `/admin` should match `<title>Zigora`.

**Already fixed in this session (lines corrected).**

---

## Bug 4 — `process_new` VTable has stale `bufs` signature

**Severity:** Medium — currently fixed (this session), but was broken at HEAD (`cf85dc5`).

**Root cause:** The `ServerApp.VTable.process_new` signature at `service.zig:29` declares `fn(app, io, stream, bufs: *PerRequestBuffers) → ?Stream`, but `HttpProxy.process_new` at `proxy/root.zig:158` declares `fn(self, io, stream) → ?Stream` (no `bps` param). The `implement` wrappers (line 40) cast through `anyopaque` so mismatched signatures compile silently — Zig catches this only at runtime (stack corruption on the missing argument).

**Current state:** Fixed by removing `bufs` from VTable and `implement` wrapper (this session). `proxyToH1` now uses local stack `[8192]u8` for header_buf.


## Bug 5 — Buffer `handleConn` + `VTable` still references `PerRequestBuffers` type

**Severity:** Low (dead import, no runtime effect).

**Root cause:** `service/zig:14-16` imports `buffer_pool_mods` + `PerRequestBuffers` even after buffer pool was removed. `handleConn` uses `var bufs = PerRequestBuffers{};` (allocates 16K+ on stack every call) then passes it to `process_new` which no longer accepts it. The `PerRequestBuffers` struct still allocates `read: [4096]u8, write: [4096]u8, header: [8192]u8` = ~16K of **dead stack space** because `proxy/root.zig` now has its own stack arrays.

**Already cleaned in this session** — the import + usage removed.

---

## Summary

| # | Bug | Severity | File(s) | Reproduce |
|---|-----|----------|---------|-----------|
| 1 | SIGTERM segfault | FATAL | `src/zigora_core/server.zig:53-69, 112-165` | `kill -TERM`, then hit with request |
| 2 | Stale signature in `VTable.process_new` | HIGH | `src/zigora_core/service.zig:29-31` | Compile with v0.1.1 ref, dispatch any request |
| 3 | Dead backend `127.0.0.1:9001` hardcoded | HIGH | `src/main.zig:24-28` | 5 sequential requests → #3, #5 fail |
| 4 | E2E test `$BASE` undefined | MEDIUM | `test/e2e_all.sh:8,20-27` | Run E2E script on a clean clone |
| 5 | Stale `PerRequestBuffers` import (dead code) | LOW | `src/zigora_core/service.zig:14-16` | None (just wasted memory) |

Pingora-style fix reference: `PINGORA_ARCHITECTURE.md` + local source at `/home/jeeva/projects/rust/pingora/` — see `SAN/chat/rust/pingora/pingora-core/src/server/mod.rs` for signal handling (`UnixShutdownSignalMatch`), `pingora-core/src/services/listening.rs` for accept loop (`tokio::select!` with `multitain(start).merge()`) pattern.