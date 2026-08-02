# MEMORY_MANAGEMENT.md

How memory is managed in zigora, and the conventions new code must follow.
Companion to `ARCHITECTURE.md`.

## The Zig model

- Every allocation goes through a caller-passed `std.mem.Allocator` — there is
  no global allocator, no hidden allocations inside stdlib containers.
- An allocator is a two-word struct: a `*anyopaque` pointer plus a vtable of
  `alloc` / `resize` / `remap` / `free`. Every allocation is owned by exactly
  one allocator and must be freed by that same allocator.
- The compiler never allocates implicitly (no GC, no hidden temporaries on the
  heap). What you don't pass an allocator for doesn't allocate.

## Allocator zoo (Zig 0.16)

| Allocator | Use |
|---|---|
| `std.heap.page_allocator` | OS pages directly, slow, always available. |
| `std.heap.DebugAllocator(.{})` | Leak-checking; tracks every allocation, reports leaks with stack traces at `deinit()`. Debug/ReleaseSafe default. |
| `std.heap.smp_allocator` | Global, lock-free per-CPU pools; the 0.16 replacement for `GeneralPurposeAllocator` in release builds. |
| `std.heap.ArenaAllocator` | Bump allocation, free-all-at-once; lock-free and thread-safe since 0.16. Process-lifetime scratch (e.g. args). |
| `std.heap.FixedBufferAllocator` | Bump allocation over a fixed buffer; stack-allocated scratch. |
| `std.testing.allocator` | Leak-checking; every `zig build test` run aborts on any leak or double-free. |
| `std.heap.MemoryPool` | Object pools for many same-sized items. |
| `std.heap.c_allocator` | libc malloc; only when linking libc. |

Note: `ThreadSafeAllocator` was removed in 0.15; `GeneralPurposeAllocator`
was renamed `DebugAllocator`; `std.meta.trait` was removed (use `@typeInfo`).

## Idioms

- Every `alloc`/`create` gets a paired `free`/`destroy`, usually via
  `defer`/`errdefer` so error returns clean up too.
- Name the parameter `allocator` (or `gpa` when it's specifically a
  general-purpose one, `arena` when a scratch/arena one). The name signals
  lifetime to the caller.
- Hot paths go stack-first: fixed-size stack buffers beat heap for request
  lifetime data.
- Leak detection at process exit: the allocator that owns everything asserts
  `deinit() == .ok` in `main` — a nonzero exit (or panic) on shutdown means a
  leak. Never `deinit() catch {}` the check away.
- A `deinit()` that frees everything is the leak test; if a module's deinit
  can't free a field, that field's ownership is documented at the field.

## Zigora's strategy

- **Proxy hot path is zero-heap**: per-connection `Session` uses stack buffers
  (4K read, 4K write, 8K header, 16K cache capture). No per-request
  allocations in `proxyToH1`/`process_new`.
- **Every package pairs alloc/deinit** (cache, balancer, ketama, tinyufo,
  lru, pool, metrics); ownership flows caller-down and is returned on eviction
  or deinit.
- **Main policy** (`src/main.zig`): `DebugAllocator` in Debug/ReleaseSafe
  (leak report at SIGTERM), `smp_allocator` in ReleaseFast/Small (no checking,
  max throughput). The process arena is used only for `std.process.Init`
  args, which outlive everything.
- **Shutdown order**: `runForever` returns only after the service drains
  in-flight connections (`Group.await`), so deinit never races a handler.
- **Tests** run under `std.testing.allocator` — a leaking library test fails
  the build.
- **Cache value ownership**: `MemoryCache.put` takes ownership of the value;
  evicted and overwritten values are returned by TinyUfo and freed by the
  cache layer; resident values are freed at deinit.

## Conventions for new modules

- Allocator as the first parameter of every `init`; store it for `deinit`.
- Container fields are `Unmanaged` variants (`.empty` init) so the struct
  stays copyable and the allocator is explicit.
- If the module owns its elements' memory, `deinit` frees them — test with
  `std.testing.allocator` and assert leak-free at process exit.
- Never hold a copy of a struct that is mutated after the copy (arraylist
  pointers go stale) — deinit the instance that was actually used.
- No global allocator, no `std.heap.page_allocator` shortcuts in hot paths.

Deferred (not needed yet): per-request arenas for large-response bodies,
`MemoryPool` for connection objects — revisit when benchmarks show them.
