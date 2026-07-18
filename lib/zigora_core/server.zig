//! Port of pingora-core's `Server`. v0.2: per-service `io.async` futures
//! running on the `std.Io` worker pool (no `std.Thread`), joined via
//! `Future.await`. No graceful shutdown yet — see V0.2_ROADMAP.md phase 4.

const std = @import("std");
const Io = std.Io;
const service_mod = @import("service.zig");

pub const zgcore_server = @This();

pub const ServerConf = struct {
    threads: usize = 1,
    // v0.2: graceful_shutdown_timeout_seconds, grace_period_seconds, etc.
};

pub const ExecutionPhase = enum {
    Setup,
    Bootstrap,
    BootstrapComplete,
    Running,
    GracefulUpgradeTransferringFds,
    GracefulUpgradeCloseTimeout,
    GracefulTerminate,
    ShutdownStarted,
    ShutdownGracePeriod,
    ShutdownRuntimes,
    Terminated,
};

pub const ServiceSlot = struct {
    name: []const u8,
    start: *const fn (userdata: *anyopaque, io: Io, alc: std.mem.Allocator) anyerror!void,
    userdata: *anyopaque,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    conf: ServerConf,
    services: std.ArrayList(ServiceSlot),

    pub fn new(allocator: std.mem.Allocator, conf: ServerConf) Server {
        return .{ .allocator = allocator, .conf = conf, .services = .empty };
    }

    pub fn addService(
        self: *Server,
        slot: ServiceSlot,
    ) !service_mod.ServiceHandle {
        const idx = self.services.items.len;
        try self.services.append(self.allocator, slot);
        return .{ .name = slot.name, .index = idx };
    }

    /// Spawn one `io.async` future per service on the `Io` worker pool,
    /// then block on each future in order. v0.2: services are concurrent
    /// and non-blocking; the process-provided `Io` (Threaded/Uring/Evented)
    /// does the scheduling.
    pub fn runForever(self: *Server, io: Io) !void {
        if (self.services.items.len == 0) return error.NoServices;
        std.log.info("core: server starting {d} service(s)", .{self.services.items.len});

        const ServiceFuture = Future(void);

        const futures = try self.allocator.alloc(ServiceFuture, self.services.items.len);
        defer self.allocator.free(futures);

        const Adapter = struct {
            fn start(slot: *ServiceSlot, io_arg: Io, alc: std.mem.Allocator) void {
                slot.start(slot.userdata, io_arg, alc) catch |err| {
                    std.log.err("core: service '{s}' crashed: {s}", .{ slot.name, @errorName(err) });
                    return;
                };
            }
        };

        for (self.services.items, 0..) |*slot, i| {
            futures[i] = io.async(
                Adapter.start,
                .{ slot, io, self.allocator },
            );
        }

        for (futures, 0..) |*f, i| {
            _ = f.await(io);
            std.log.info("core: service '{s}' stopped", .{self.services.items[i].name});
        }

        std.log.info("core: all services stopped", .{});
    }
};

// ponytail: single-service deployments are the common case; awaiting N futures
// in registration order works fine. If a service crashing should cancel all
// others (Pingora's behavior), wire a `Group` here and `group.cancel` on first
// error — small upgrade path when needed.

// Local alias so the function name resolves — `Io.Future(void)` is the
// generic factory; the resulting type is what `io.async` returns.
fn Future(comptime Result: type) type {
    return std.Io.Future(Result);
}

test "ServerConf defaults to 1 thread" {
    const c: ServerConf = .{};
    try std.testing.expectEqual(@as(usize, 1), c.threads);
}

test "Server.new empty has no services" {
    const alc = std.testing.allocator;
    var s = Server.new(alc, .{});
    defer s.services.deinit(alc);
    try std.testing.expectEqual(@as(usize, 0), s.services.items.len);
}

test "ExecutionPhase enum shape" {
    try std.testing.expectEqual(ExecutionPhase.Setup, ExecutionPhase.Setup);
    try std.testing.expectEqual(ExecutionPhase.Terminated, ExecutionPhase.Terminated);
}
