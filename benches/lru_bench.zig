const std = @import("std");
const lru = @import("zigora-lru");

const ITERATIONS: u64 = 2_000_000;
const SHARDS: usize = 10;
const CAPACITY: usize = 100;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var cache = try lru.Lru(void, SHARDS).init(allocator, CAPACITY, CAPACITY);
    defer cache.deinit();

    for (0..CAPACITY) |i| {
        _ = cache.admit(i, {}, 1);
    }

    var prng = std.Random.Xoshiro256.init(42);
    const rnd = prng.random();

    const io = std.Io.Threaded.global_single_threaded.io();
    const t0 = std.Io.Timestamp.now(io, .real);

    for (0..ITERATIONS) |_| {
        _ = cache.promote(rnd.int(u64) % CAPACITY);
    }

    const t1 = std.Io.Timestamp.now(io, .real);
    const elapsed: u64 = @intCast(@abs(t1.nanoseconds - t0.nanoseconds));
    std.debug.print(
        "lru promote ({d} iters): {d}ns total, {d}ns avg, {d} ops/sec\n",
        .{ ITERATIONS, elapsed, elapsed / ITERATIONS, ITERATIONS * 1_000_000_000 / @max(1, elapsed) },
    );
}