# AGENTS.md

Compact guidance for OpenCode sessions working in this repo. Read `docs/ARCHITECTURE.md` for the full Pingora-to-Zigora design map and `docs/V0.2_ROADMAP.md` for the phased implementation plan; this file covers toolchain, commands, and wiring conventions.

## Toolchain

- Zig **0.16.0** required ( see `build.zig.zon` `minimum_zig_version`). `zig version` must report `0.16.0` or newer.
- No dependencies, no fetch step needed. Offline builds work.

## Commands

- `zig build` — build the `zigora` executable into `zig-out/`
- `zig build run` — build and run the exe (pass args after `--`, e.g. `zig build run -- foo`)
- `zig build test` — run tests in both the `zigora` module and the exe's root module (they run in parallel)
- `--release=fast|safe|small` is selectable; no default release mode is forced

## Architecture reference

A Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) HTTP reverse proxy framework. The authoritative module map and dependency graph live in `docs/ARCHITECTURE.md`; the Pingora reference doc is `docs/PINGORA_ARCHITECTURE.md`. Key structural facts:

- `src/main.zig` is the binary entrypoint (`pub fn main(init: std.process.Init) !void` — note the 0.16 signature). Unlike Pingora (lib-only), Zigora ships as a binary.
- `src/root.zig` is the public library root for consumers; re-exports every package as a namespace (`pub const core = @import("zigora_core.zig")`, etc.) plus flat aliases (`pub const Server = core.Server`).
- Every package is a **single file** under `src/` (e.g. `src/zigora_http.zig`), imported by relative path (`@import("zigora_http.zig")`). The only subdirectory is `src/zigora_core/` (listeners/runtime/server/service), re-exported via `src/zigora_core.zig`. `lib/` no longer exists.
- Eleven packages exist on disk; v0.1 implements four (`zigora_core`, `zigora_proxy`, `zigora_http`, `zigora_error`); v0.2 phase 1 implements five more (`zigora_limits`, `zigora_lru`, `zigora_ketama`, `zigora_tinyufo`, `zigora_pool`); the rest are reserved for v0.2 phases 2-4.

## Async / I/O

v0.1 used `std.Thread.spawn` per service; **v0.1.1 onward uses `io.async` + `Future.await` for services and `Group.concurrent` for per-connection dispatch**. No manual thread spawning anywhere in the framework — the `std.Io` worker pool (Threaded/Uring/Evented) schedules everything. See `src/zigora_core/server.zig` and `src/zigora_core/service.zig`.

## Sub-package naming

- On-disk files use **underscores** (`zigora_core.zig`).
- The library root `src/root.zig` re-exports each package as a namespace: `pub const core = @import("zigora_core.zig")`, so consumers write `zigora.core`, `zigora.pool`, etc.
- Packages import each other by relative path only — no named-module imports inside `src/`. All relative imports propagate test blocks, so `zig build test` collects tests from every package (unlike the old named-module wiring, which silently ran only root-file tests).
- Mismatching import paths is the only common build error in this repo.

## Wiring rules

- Only two modules exist in `build.zig`: the `zigora` library module (root `src/root.zig`, `.imports` empty — everything is relative) and the `exe` module (root `src/main.zig`, imports `zigora`).
- Examples and benches import the library via `.imports = &.{. { .name = "zigora", .module = mod } }` and use `const zigora = @import("zigora"); const core = zigora.core;`.
- Tests: `b.addTest(.{ .root_module = mod })` tests the `zigora` library module; `b.addTest(.{ .root_module = exe.root_module })` tests the exe's root module. Both run in parallel via the `test` top-level step.

## Release conventions

- Each phase completion ships a tag: `v0.1.x` increments for phase 1 milestones, `v0.2.x` for phase 2, etc.
- `CHANGELOG.md` must be updated for each tag with the phase's package additions and notable changes (`docs/CHANGELOG.md`).
- All phase 1 unblocker packages (limits, lru, ketama, tinyufo, http+pool) are done — tagged `v0.1.1`.

## Verification

Before considering work done, run:

```
zig build && zig build test
```

A clean build is the only signal the module wiring is correct. Zig's build cache validates hashes and import paths that the compiler does not check file-by-file.