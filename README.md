# Zigora

A native Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) — an HTTP reverse proxy and load balancer framework built without a generic async runtime. Uses `std.Io` (`io.async` / `Group.concurrent` on the Threaded/Uring/Evented worker pool) for all scheduling — no `std.Thread.spawn` anywhere.

Requires Zig ≥ 0.16.0. No dependencies, offline builds.

```bash
zig build               # build zig-out/bin/zigora
zig build run -- --backend 127.0.0.1:9000
zig build test          # unit tests (both modules in parallel)
```

## Documentation

All docs live in [`docs/`](docs/):

- [`docs/README.md`](docs/README.md) — full release notes, module table, build/run, architecture overview
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — authoritative module map, dependency graph, per-package surface
- [`docs/PINGORA_ARCHITECTURE.md`](docs/PINGORA_ARCHITECTURE.md) — reference Pingora crate layout (the spec being ported)
- [`docs/V0.4_ROADMAP.md`](docs/V0.4_ROADMAP.md) — current phase plan (also `V0.2_ROADMAP.md`, `V0.3_ROADMAP.md`, `V0.3_PERFORMANCE.md`)
- [`docs/BENCHMARK.md`](docs/BENCHMARK.md) — benchmark methodology and runs
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — per-tag release notes
- [`docs/MEMORY_MANAGEMENT.md`](docs/MEMORY_MANAGEMENT.md) — allocator strategy by build mode

[`AGENTS.md`](AGENTS.md) stays at the repo root so agent tooling auto-discovers it.

## License

MIT — see `LICENSE`.