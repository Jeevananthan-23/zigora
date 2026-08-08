const std = @import("std");
const zigora = @import("zigora");
const limits = zigora.limits;

const ITERATIONS: u64 = 2_000_000;
const ITEMS: usize = 100_000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var est = try limits.Estimator.init(allocator, 3, 1024);
    defer est.deinit();

    var prng = std.Random.Xoshiro256.init(99);
    const rnd = prng.random();

    const t0 = std.Io.Timestamp.now(io, .real);
    for (0..ITERATIONS) |_| {
        _ = est.incr(rnd.int(usize) % ITEMS, 1);
    }
    const t1 = std.Io.Timestamp.now(io, .real);
    const elapsed_est: u64 = @intCast(@abs(t1.nanoseconds - t0.nanoseconds));
    std.debug.print(
        "estimator incr ({d} iters): {d}ns total, {d}ns avg, {d} ops/sec\n",
        .{ ITERATIONS, elapsed_est, elapsed_est / ITERATIONS,
           ITERATIONS * 1_000_000_000 / @max(1, elapsed_est) },
    );

    var naive = std.AutoHashMap(usize, usize).init(allocator);
    defer naive.deinit();

    const t2 = std.Io.Timestamp.now(io, .real);
    for (0..ITERATIONS) |_| {
        const key = rnd.int(usize) % ITEMS;
        const entry = naive.getPtr(key);
        if (entry) |p| {
            p.* += 1;
        } else {
            naive.put(key, 1) catch break;
        }
    }
    const t3 = std.Io.Timestamp.now(io, .real);
    const elapsed_nav: u64 = @intCast(@abs(t3.nanoseconds - t2.nanoseconds));
    std.debug.print(
        "naive hashmap incr ({d} iters): {d}ns total, {d}ns avg, {d} ops/sec\n",
        .{ ITERATIONS, elapsed_nav, elapsed_nav / ITERATIONS,
           ITERATIONS * 1_000_000_000 / @max(1, elapsed_nav) },
    );
}