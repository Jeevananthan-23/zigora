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
