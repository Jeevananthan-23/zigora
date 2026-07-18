# zigora-cache

Reserved for v0.2. Port of [pingora-cache](https://github.com/cloudflare/pingora/tree/main/pingora-cache). Planned types:

- `HttpCache` — phase-driven state machine (CacheKey → Hit/Miss/Stale/Revalidated)
- `Storage` trait — key-value backend (disk, in-memory)
- `HitHandler` / `MissHandler` — streaming body read/write
- `CacheMeta` — freshness, variance, headers

Depends on `zigora-http`, `zigora-lru` (for eviction), `zigora-memory-cache` (TinyUFO-backed).