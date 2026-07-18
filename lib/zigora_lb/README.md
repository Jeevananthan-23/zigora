# zigora-lb

Reserved for v0.2. Port of [pingora-load-balancing](https://github.com/cloudflare/pingora/tree/main/pingora-load-balancing). Planned types:

- `Backend` — address + weight + extensions
- `Backends` — collection + service discovery + health check
- `LoadBalancer<S>` — selectors: RoundRobin, Random, FNVHash, Consistent (Ketama)
- `BackendSelection` trait for custom selection algorithms

Depends on `zigora-ketama` (consistent hash ring).