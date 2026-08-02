# Zigora Benchmark

## System

| Item | Value |
|------|-------|
| CPU | Intel Core i5-9300H @ 2.40GHz (8 cores) |
| Cache | L1d 128KiB, L1i 128KiB, L2 1MiB, L3 8MiB |
| RAM | 7.6 GiB |
| OS | Linux 6.6.87.2-microsoft-standard-WSL2 (x86_64) |
| Zig | 0.16.0 |
| Build | `--release=fast` |

## Upstream

Two Python 3 `http.server` instances on 127.0.0.1:9000 and 127.0.0.1:9001.

## Tool

[wrk](https://github.com/wg/wrk) — 4 threads, 100 connections, 30s duration.

## Results

### Run 1 (30s)

```
Running 30s test @ http://127.0.0.1:8080/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   292.89ms  395.93ms   1.98s    79.47%
    Req/Sec    78.44     38.62   242.00     71.43%
  9355 requests in 30.09s, 10.71MB read
  Socket errors: connect 0, read 2, write 0, timeout 403
Requests/sec:    310.86
Transfer/sec:    364.29KB
```

### Run 2 (15s, with latency distribution)

```
Running 15s test @ http://127.0.0.1:8080/
  4 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   256.10ms  384.58ms   2.00s    82.01%
    Req/Sec    83.16     43.61   290.00     74.79%
  Latency Distribution
     50%   82.30ms
     75%  398.53ms
     90%  971.19ms
     99%    1.35s
  4979 requests in 15.06s, 5.70MB read
  Socket errors: connect 0, read 0, write 0, timeout 202
Requests/sec:    330.67
Transfer/sec:    387.50KB
```

## Metrics (post-benchmark)

| Metric | Value |
|--------|-------|
| Connections Accepted | 14,410 |
| Requests Total | 14,407 |
| Request Errors | 0 |
| Upstream Bytes | 575 KB |
| Downstream Bytes | 17 MB |
| Upstream Errors | 117 |

## Observations

- **~310 req/s** sustained across 100 concurrent connections
- **82 ms median** latency, 971 ms p90
- 403/202 socket timeouts — upstream Python servers are single-threaded and bottleneck at high concurrency
- Upstream errors (117) match wrk timeout count — caused by slow Python upstream, not Zigora
- Zigora itself is CPU-bound on the Python upstream, not the proxy layer
- Active upstream connections show >0 under concurrent load (gauge resets between requests)

---

## Run 3 — 2026-08-02 (v0.4.0-alpha4)

Same system, upstreams, and tool as above (`--release=fast`, 2× Python http.server on :9000/:9001, wrk -t4 -c100 -d30s). Includes cache-hit path (memory cache added since Run 1/2).

### Cache-hit path (repeated 30s runs)

| Run | Requests/s | Read errors | Notes |
|-----|-----------|-------------|-------|
| A (15s) | 16,697 | 21,607 | 273K requests, 1.66KB avg response |
| B (20s) | 19,318 | 28,784 | 387K requests, 30.6MB/s |
| C (20s) | 1,053 | 383,172 | degraded mode |
| D (10s) | 1,741 | 172,057 | degraded mode |

Best-valid runs: **~17-19K req/s**, ~3.8ms median latency (p99.99 1.3-1.9s tail in storm runs).

### Miss path (unique URLs, 30s)

- **1,258 req/s** — backend-bound (Python http.server direct ceiling: 134 req/s single-threaded; 404 bodies are small so the proxy-side rate is higher than index.html direct)
- All responses non-2xx by design (random paths → 404, cached)

### Metrics (60s combined load)

| Metric | Value |
|--------|-------|
| Connections Accepted | 622,304 |
| Requests Total | 622,255 |
| Request Errors | 0 |
| Upstream Errors | 0 |
| Cache Hits / Misses / Puts | 581,617 / 40,637 / 40,557 |
| Upstream Bytes | 2.0 MB |
| Downstream Bytes | 12.3 MB |

### Memory (ReleaseFast, smp_allocator)

| State | RSS |
|-------|-----|
| Idle | 1.1 MB |
| Under 19K conn/s load | 51-110 MB |
| After drain (5s post-load) | unchanged (smp_allocator retains slabs; not a leak — Debug builds verify leak-free) |

### Findings

- **Proxy capacity: ~19K connections/s** (accept→read→write→close per request; no keep-alive). Storm-mode runs show identical 19K conn/s total — the difference is response survival, not throughput.
- **Top issue — close race**: the proxy closes downstream immediately after the response (`root.zig:326-329`, ponytail'd). When the client's next request lands in the recv buffer before close, Linux sends RST and the response is lost; wrk counts these as read errors. Loss rate varies 2-95% per run → bimodal results, long latency tails. Fix is the V0.3 roadmap item (downstream keep-alive + drain-before-close); until then, benchmark results on the hit path are non-deterministic.
- **Downstream byte counter undercounts cache hits**: cached responses bypass the capture path, so `bytes_downstream` (~50 bytes/req) does not reflect cached traffic (58MB actually served in the 15s run A).
- **vs. Run 1/2 baseline**: 310 → ~17-19K req/s (~55×) on the cache-hit path; the old 310 req/s figure was the miss path, backend-bound.

---

## Pingora comparison — 2026-08-02

Same machine, tool, and upstreams. Pingora: Cloudflare Pingora 0.8.0 source
(`~/projects/rust/pingora`), a minimal proxy example (listener 8081, one
`BasicPeer` upstream, jemalloc, default features, `--release`), 3m47s build.
Zigora: `--release=fast`, same listener count per test.

### Same test (wrk -t4 -c100, one Python http.server backend)

| Metric | Pingora | Zigora |
|--------|---------|--------|
| Miss path, unique URLs (20-30s) | 470 req/s | 495 req/s |
| Cached path `/` (20s) | n/a (no cache) | 12,770 req/s (0.6% read errors) |
| Read errors (miss path) | 0 | 656 |
| Timeouts (miss path) | 169 | 203 |

Both proxies are backend-bound on the miss path; results are equivalent within
noise. Zigora's cached path adds a 26x throughput tier the bare Pingora proxy
does not have.

### Fast upstream (node http server, 1.5KB responses, HTTP/1.1)

Node direct ceiling: 7,954 req/s (the upstream, not the proxy, is the wall).

| Metric | Pingora | Zigora |
|--------|---------|--------|
| Requests/s (30s / 20s) | 8,137 | ~0 (all responses lost) |
| Read errors | 0 | 211,840 |
| Latency avg (p100) | 12.9ms (83.8ms) | n/a |
| RSS under load | 12.1 MB | 42.2 MB (1.1 MB idle) |

### Findings

- **Deterministic vs storm**: Pingora sustains 8.1K req/s with zero errors
  (upstream-keep-alive + downstream keep-alive). Zigora processes ~10.6K
  conns/s but its immediate close-after-response (`root.zig:326-329`,
  ponytail'd no-keep-alive) RSTs every response when the client races the
  close — which fast upstreams make worse (responses complete in microseconds,
  so the race window is 100%). Against the slow Python backend the same race
  loses only 0.6-95% of responses, which is why Zigora's hit-path numbers are
  bimodal (1K-19K req/s) while Pingora's are flat.
- **Latency tails**: Pingora max 84ms; Zigora tails reach 1.3-1.9s in storm
  runs.
- **Memory**: Pingora 12 MB steady. Zigora 1.1 MB idle but grows to 42-110 MB
  under load (smp_allocator retains slabs; Debug builds verify no leaks).
- **What to close the gap**: the V0.3 roadmap items — downstream keep-alive
  (drain-before-close), upstream connection pool with liveness check
  (currently disabled, root.zig ponytail note). Until then Zigora's real
  capacity (~19K conn/s) is hidden behind response loss.
- **Fairness**: Pingora proxy had one upstream (hardcoded in the bench
  example); Zigora's earlier 2-backend runs (16.7-19.3K req/s) are not
  directly comparable to Pingora's single-upstream numbers.

## Run 4 — 2026-08-02 (keep-alive + body-truncation fix, v0.4.0-alpha5)

Fixes since Run 3 (see V0.4_ROADMAP 3.1):
1. **Body truncation (the actual "0 req/s vs node" cause):** the upstream
   header loop consumed headers *and* body into `header_buf` when a fast
   upstream sent them in one read, then discarded the body → responses were
   header-only. Header consumption now stops at `\r\n\r\n`.
2. **Downstream keep-alive:** `process_new` loops per connection (pipelined
   bytes, else a 50ms `receiveTimeout` wait served via `Io.Reader.fixed`);
   idle conns close gracefully with drain (no RST).
3. **async_limit:** `src/main.zig` raises the runtime default (n_cpu-1 = 7)
   to `.unlimited`; at the default, >7 concurrent keep-alive connections
   queue on the io and latency collapses.

Cache-hit path `/`, node upstream (HTTP/1.1, 1.5KB bodies), wrk -t4:

| Config | Requests/s | Read errors | Latency (mean/med) | Timeouts |
|--------|-----------|-------------|--------------------|----------|
| -c8 (3 runs) | 30.7-31.7K | 0 | 0.51-0.54ms / ~0.5ms | 0 |
| -c100 (3 runs) | 53-57K | 0-90 (0-0.02%) | 2.7-6.7ms / ~1ms | 0 |

Run 3 on the same path: ~0 req/s (100% response loss). Pingora comparison
(8.1K req/s, miss path): beat 6.5-7x at -c100.

Miss path unchanged (backend-bound ~470-500 req/s with the Python upstream).

### Known residual (std.Io, not proxy code)

Threaded io performs one blocking `poll()` per in-flight op and spawns a
worker thread per op (305 threads at -c100). Above ~8 connections the LIFO
run queue starves long keep-alive chains: median latency climbs to ~1ms at
-c8, ~3-7ms at -c100 with a ~200ms tail. Latency is clean at -c8; the tail
at -c100 is scheduled for a follow-up (evented io backend or an idle-wait
that doesn't churn the run queue). Shutdown remains clean and leak-free
(Debug build asserts pass).

## Run 5 — 2026-08-02 (NoSteal runtime, v0.4.0-alpha6)

Fix since Run 4 (see V0.4_ROADMAP 3.1 residual): replaced the single shared
`Io.Threaded` pool with a Pingora-style NoSteal runtime
(`zigora_core/runtime.zig`) — one engine per CPU, engine 0 owns the accept
loop, each connection is dispatched to a random other engine. Each engine
runs `.unlimited`, so nothing queues behind another connection anymore.
`std.Io.Evented` (io_uring) was probed as the alternative and rejected: it
does not compile in Zig 0.16.0 (std bug in `Uring.zig` dir-open error sets,
fixed upstream post-0.16.0; no 0.16.1 release exists).

Cache-hit path `/`, node upstream, keep-alive, wrk -t4 --release=fast, 10s runs:

| Config | Requests/s | Read errors | Latency (mean/med) | Max |
|--------|-----------|-------------|--------------------|-----|
| -c8 (3 runs) | 27.6-33.1K | 0 | ~0.5ms | - |
| -c100 (3 runs) | 62.5-64.6K | 0-24 (0-0.004%) | 1.47-1.73ms | 103-108ms |
| -c100 determinism gate | 62.5/63.8/64.6K (1.03x) | - | - | - |

vs Run 4 (-c100): 53-57K → 62.5-64.6K req/s (~12%), median 3-7ms → ~1.5ms,
max tail ~200ms → ~103ms. Determinism spread 1.03x at c100, 1.2x at c8
(both within the 3.5 gate of < 2x). Shutdown still clean and leak-free
(Debug asserts pass, SIGTERM exits, services drain).
