# zigora-limits

Reserved for v0.2. Port of [pingora-limits](https://github.com/cloudflare/pingora/tree/main/pingora-limits). Planned types:

- `rate` — sliding-window rate estimator (Count-Min Sketch)
- `estimator` — event frequency estimation (hash + atomic counters)
- `inflight` — in-flight request counter with automatic cleanup on drop

Imports: `std` only (ahash equivalent: std.hash).