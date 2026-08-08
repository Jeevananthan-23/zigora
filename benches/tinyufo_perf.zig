const std = @import("std");
const zigora = @import("zigora");
const tinyufo = zigora.tinyufo;

const ITEMS: u64 = 100;
const ITERATIONS: u64 = 5_000_000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var tiny = try tinyufo.TinyUfo(void).init(allocator, ITEMS + 10, 10);
    defer tiny.deinit();

    for (0..ITEMS) |i| {
        _ = try tiny.put(i, {}, 1);
    }

    var prng = std.Random.Xoshiro256.init(1337);
    const rnd = prng.random();

    const io = std.Io.Threaded.global_single_threaded.io();
    const t0 = std.Io.Timestamp.now(io, .real);

    for (0..ITERATIONS) |_| {
        _ = tiny.get(rnd.int(u64) % ITEMS);
    }

    const t1 = std.Io.Timestamp.now(io, .real);
    const elapsed_ns: u64 = @intCast(@abs(t1.nanoseconds - t0.nanoseconds));
    std.debug.print(
        "tinyufo read: {d}ns total, {d}ns avg, {d} ops/sec\n",
        .{ elapsed_ns, elapsed_ns / ITERATIONS, ITERATIONS * 1_000_000_000 / @max(1, elapsed_ns) },
    );
}