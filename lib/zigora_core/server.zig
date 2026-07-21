//! Port of pingora-core's `Server`. v0.2: per-service `io.async` futures
//! running on the `std.Io` worker pool (no `std.Thread`), joined via
//! `Future.await`. Graceful shutdown via atomic flag + ShutdownWatch.
//!
//! v0.2: signal handlers, FD transfer, keepalive — see V0.2_ROADMAP.md phase 4.

const std = @import("std");
const Io = std.Io;
const service_mod = @import("service.zig");

pub const zgcore_server = @This();

pub const ServerConf = struct {
    threads: usize = 1,
    graceful_shutdown_timeout_ms: u64 = 5000,
};

pub const ExecutionPhase = enum(u32) {
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

/// `ShutdownWatch` — a receiver that accept loops poll per iteration.
/// Created by `Server.shutdownWatch()`. Calling `Server.shutdown()` wakes all.
pub const ShutdownWatch = struct {
    flag: *std.atomic.Value(bool),

    pub fn check(self: ShutdownWatch) bool {
        return self.flag.load(.acquire);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    conf: ServerConf,
    services: std.ArrayList(ServiceSlot),
    shutdown_flag: std.atomic.Value(bool) = .{ .raw = false },
    phase_: std.atomic.Value(ExecutionPhase) = .{ .raw = ExecutionPhase.Setup },

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

    /// Get a `ShutdownWatch` for the accept loop to poll.
    pub fn shutdownWatch(self: *Server) ShutdownWatch {
        return .{ .flag = &self.shutdown_flag };
    }

    /// Trigger graceful shutdown. Sets the flag, transitions phase.
    pub fn shutdown(self: *Server) void {
        self.shutdown_flag.store(true, .release);
        _ = self.phase_.swap(ExecutionPhase.ShutdownStarted, .acq_rel);
    }

    /// Spawn one `io.async` future per service on the `Io` worker pool,
    /// then block on each future. Accept loops poll `shutdownWatch()`.
    pub fn runForever(self: *Server, io: Io) !void {
        if (self.services.items.len == 0) return error.NoServices;
        std.log.info("core: server starting {d} service(s)", .{self.services.items.len});

        _ = self.phase_.swap(ExecutionPhase.Running, .acq_rel);

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

        _ = self.phase_.swap(ExecutionPhase.Terminated, .acq_rel);
        std.log.info("core: all services stopped", .{});
    }

    pub fn phase(self: *Server) ExecutionPhase {
        return self.phase_.load(.acquire);
    }
};

// Local alias for `Io.Future(void)`.
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

test "ShutdownWatch reports false then true" {
    const alc = std.testing.allocator;
    var s = Server.new(alc, .{});
    const watch = s.shutdownWatch();
    try std.testing.expect(!watch.check());
    s.shutdown();
    try std.testing.expect(watch.check());
}
