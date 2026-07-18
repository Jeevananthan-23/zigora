# AGENTS.md

Compact guidance for OpenCode sessions working in this repo. Read `ARCHITECTURE.md` for the full Pingora-to-Zigora design map; this file covers toolchain, commands, and wiring conventions.

## Toolchain

- Zig **0.16.0** required ( see `build.zig.zon` `minimum_zig_version`). `zig version` must report `0.16.0` or newer.
- No dependencies, no fetch step needed. Offline builds work.

## Commands

- `zig build` — build the `zigora` executable into `zig-out/`
- `zig build run` — build and run the exe (pass args after `--`, e.g. `zig build run -- foo`)
- `zig build test` — run tests in both the `zigora` module and the exe's root module (they run in parallel)
- `--release=fast|safe|small` is selectable; no default release mode is forced

## Architecture reference

A Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) HTTP reverse proxy framework. The authoritative module map and dependency graph live in `ARCHITECTURE.md`. Key structural facts:

- `src/main.zig` is the binary entrypoint (`pub fn main(init: std.process.Init) !void` — note the 0.16 signature). Unlike Pingora (lib-only), Zigora ships as a binary.
- `src/root.zig` is the public library root for consumers; re-exports v0.1 sub-packages via named build-module imports.
- `lib/root.zig` is the umbrella re-exporter for all sub-packages. Ten packages exist on disk; v0.1 implements four (`zigora_core`, `zigora_proxy`, `zigora_http`, `zigora_error`), the rest are reserved for v0.2.

## Sub-package naming

- On-disk directories use **underscores** (`zigora_core`).
- User-facing module labels in `build.zig` use **hyphens** (`zigora-core`).
- `@import("zigora-core")` refers to the module label. `b.path("lib/zigora_core/root.zig")` refers to the filesystem.
- Mismatching these is the only common build error in this repo.

## Wiring rules

- Every package reachable from `src/main.zig` or `src/root.zig` must be registered as a named module in `build.zig` via `b.addModule()`.
- Every named module that imports another module must list that module in its `.imports` table.
- Tests: `b.addTest(.{ .root_module = mod })` tests the `zigoma` library module; `b.addTest(.{ .root_module = exe.root_module })` tests the exe's root module. Both run in parallel via the `test` top-level step.

## Verification

Before considering work done, run:

```
zig build && zig build test
```

A clean build is the only signal the module wiring is correct. Zig's build cache validates hashes and import paths that the compiler does not check file-by-file.