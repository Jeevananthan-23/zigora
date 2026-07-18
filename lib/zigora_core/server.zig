//! Port of pingora-core's `Server`. v0.1: per-service `std.Thread`,
//! no FD transfer, no daemon, no dependency DAG, no signal handlers
//! (process exit is the only shutdown path). v0.2 brings graceful
//! upgrade + SIGQUIT/SIGTERM.

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

    /// Spawn one thread per service; block until all threads exit (v0.1:
    /// they never exit — this blocks forever until Ctrl-C kills process).
    pub fn runForever(self: *Server, io: Io) !void {
        if (self.services.items.len == 0) return error.NoServices;
        std.log.info("core: server starting {d} service(s)", .{self.services.items.len});

        var threads = try self.allocator.alloc(std.Thread, self.services.items.len);
        defer self.allocator.free(threads);

        for (self.services.items, 0..) |*slot, i| {
            threads[i] = try std.Thread.spawn(.{}, threadEntry, .{ slot, io, self.allocator });
        }
        for (threads) |t| t.join();

        std.log.info("core: all services stopped", .{});
    }

    fn threadEntry(slot: *ServiceSlot, io: Io, allocator: std.mem.Allocator) void {
        slot.start(slot.userdata, io, allocator) catch |err| {
            std.log.err("core: service '{s}' crashed: {s}", .{ slot.name, @errorName(err) });
        };
    }
};

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