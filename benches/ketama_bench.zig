const std = @import("std");
const ketama = @import("zigora-ketama");
const net = std.Io.net;

const CREATE_ITERS: usize = 100;
const HASH_ITERS: u64 = 1_000_000;

fn makeBuckets(n: usize, allocator: std.mem.Allocator) !std.ArrayList(ketama.Bucket) {
    var list = try std.ArrayList(ketama.Bucket).initCapacity(allocator, n);
    for (1..n + 1) |i| {
        const ip = try net.Ip4Address.parse("127.0.0.1", @intCast(i));
        const addr: net.IpAddress = .{ .ip4 = ip };
        list.appendAssumeCapacity(ketama.Bucket.new(addr, 10));
    }
    return list;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var buckets = try makeBuckets(100, allocator);
    defer buckets.deinit(allocator);

    const t0 = std.Io.Timestamp.now(io, .real);
    for (0..CREATE_ITERS) |_| {
        var c = try ketama.Continuum.init(allocator, buckets.items);
        c.deinit();
    }
    const t1 = std.Io.Timestamp.now(io, .real);
    const elapsed_create: u64 = @intCast(@abs(t1.nanoseconds - t0.nanoseconds));
    std.debug.print(
        "ketama create ({d} iters, 100 backends): {d}ns total, {d}ns avg\n",
        .{ CREATE_ITERS, elapsed_create, elapsed_create / CREATE_ITERS },
    );

    var continuum = try ketama.Continuum.init(allocator, buckets.items);
    defer continuum.deinit();

    var prng = std.Random.Xoshiro256.init(42);
    const rnd = prng.random();
    var key: [30]u8 = undefined;

    const t2 = std.Io.Timestamp.now(io, .real);
    for (0..HASH_ITERS) |_| {
        for (&key) |*b| b.* = rnd.int(u8);
        _ = continuum.node(key[0..]);
    }
    const t3 = std.Io.Timestamp.now(io, .real);
    const elapsed_hash: u64 = @intCast(@abs(t3.nanoseconds - t2.nanoseconds));
    std.debug.print(
        "ketama node hash ({d} iters): {d}ns total, {d}ns avg, {d} ops/sec\n",
        .{ HASH_ITERS, elapsed_hash, elapsed_hash / HASH_ITERS,
           HASH_ITERS * 1_000_000_000 / @max(1, elapsed_hash) },
    );
}