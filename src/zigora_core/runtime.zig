//! Pingora-style NoSteal runtime: N independent `Io.Threaded` engines, each
//! with its own worker pool and run queue. Engine 0 owns accept loops;
//! connections are dispatched to a random engine (pingora's
//! `current_handle()`), so no queue is ever shared between connections.
//!
//! See docs/ARCHITECTURE.md §3 and docs/V0.4_ROADMAP.md 3.1 (scheduler residual).

const std = @import("std");
const Io = std.Io;

pub const NoStealRuntime = struct {
    allocator: std.mem.Allocator,
    engines: []Io.Threaded,
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, num_engines: usize) !NoStealRuntime {
        std.debug.assert(num_engines > 0);
        const engines = try allocator.alloc(Io.Threaded, num_engines);
        errdefer allocator.free(engines);
        // .unlimited: every task runs on its own worker thread — nothing
        // ever queues behind another connection on the same engine.
        for (engines) |*e| e.* = Io.Threaded.init(allocator, .{ .async_limit = .unlimited });
        var seed: u64 = undefined;
        _ = std.os.linux.getrandom(std.mem.asBytes(&seed), 0, 0);
        return .{
            .allocator = allocator,
            .engines = engines,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// The engine that owns accept loops (engine 0).
    pub fn acceptIo(self: *NoStealRuntime) Io {
        return self.engines[0].io();
    }

    /// Pingora's `current_handle()`: a random engine for a new connection.
    /// Skips engine 0 so accept can never be starved by connection work.
    pub fn getRandomIo(self: *NoStealRuntime) Io {
        const start: usize = if (self.engines.len > 1) 1 else 0;
        const idx = start + self.rng.random().intRangeLessThan(usize, 0, self.engines.len - start);
        return self.engines[idx].io();
    }

    pub fn deinit(self: *NoStealRuntime) void {
        for (self.engines) |*e| e.deinit();
        self.allocator.free(self.engines);
    }
};

test "NoStealRuntime init/deinit" {
    var rt = try NoStealRuntime.init(std.testing.allocator, 2);
    defer rt.deinit();
    try std.testing.expectEqual(@as(usize, 2), rt.engines.len);
}

test "getRandomIo returns a valid engine io" {
    var rt = try NoStealRuntime.init(std.testing.allocator, 3);
    defer rt.deinit();
    for (0..16) |_| {
        const io = rt.getRandomIo();
        const t: *Io.Threaded = @ptrCast(@alignCast(io.userdata));
        var found = false;
        for (rt.engines[1..]) |*e| {
            if (t == e) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "single engine: getRandomIo falls back to engine 0" {
    var rt = try NoStealRuntime.init(std.testing.allocator, 1);
    defer rt.deinit();
    const io = rt.getRandomIo();
    const t: *Io.Threaded = @ptrCast(@alignCast(io.userdata));
    try std.testing.expectEqual(&rt.engines[0], t);
}
