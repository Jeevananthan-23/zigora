//! Port of pingora-core's `Service<A>` + `ServerApp` trait. v0.2: the accept
//! loop spawns one `io.async` per inbound connection on the `std.Io` worker
//! pool — non-blocking, concurrent. Inflight connections are tracked via a
//! `Group` so a future graceful shutdown can `group.cancel` them.
//!
//! See ARCHITECTURE.md §3 (zigora_core section).

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const listeners_mod = @import("listeners.zig");
const Stream = net.Stream;

pub const zgcore_service = @This();

/// `pingora_core::apps::ServerApp::process_new()` — the trait every proxy
/// app implements. Zig has no traits; this is a vtable struct. Users create
/// one via `ServerApp.implement(impl_struct)`.
pub const ServerApp = struct {
    vtable: *const VTable,
    /// User-provided state pointer. Cast back to `*MyImpl` in callbacks.
    userdata: *anyopaque,

    pub const VTable = struct {
        /// Called when a new connection arrives. Returns `?Stream` — non-null
        /// when the connection is to be reused for another HTTP request
        /// (keep-alive), null when done. v0.1 always returns null (no keepalive).
        process_new: *const fn (app: *ServerApp, io: Io, stream: Stream) error{ProcessFailed}!?Stream,
        /// Called once at shutdown to clean up any resources held by the app.
        cleanup: *const fn (app: *ServerApp, io: Io) void = defaultCleanup,
    };

    fn defaultCleanup(app: *ServerApp, io: Io) void {
        _ = app;
        _ = io;
    }

    /// Construct a ServerApp from a concrete impl struct. The struct must
    /// have public methods with the vtable signatures.
    pub fn implement(comptime T: type, instance: *T) ServerApp {
        const Wrap = struct {
            fn process_new(app: *ServerApp, io: Io, stream: Stream) error{ProcessFailed}!?Stream {
                const self: *T = @ptrCast(@alignCast(app.userdata));
                return self.process_new(io, stream);
            }
            fn cleanup(app: *ServerApp, io: Io) void {
                const self: *T = @ptrCast(@alignCast(app.userdata));
                if (@hasDecl(T, "cleanup")) self.cleanup(io);
            }
        };
        return .{
            .vtable = &.{
                .process_new = Wrap.process_new,
                .cleanup = Wrap.cleanup,
            },
            .userdata = instance,
        };
    }

    pub fn processNew(app: *ServerApp, io: Io, stream: Stream) error{ProcessFailed}!?Stream {
        return app.vtable.process_new(app, io, stream);
    }

    pub fn cleanup(app: *ServerApp, io: Io) void {
        app.vtable.cleanup(app, io);
    }
};

/// `ServiceHandle` — returned by `Server.add_service`. v0.1: opaque; the
/// dependency-graph and readiness watcher from Pingora are v0.2 (no
/// user-facing API today).
pub const ServiceHandle = struct {
    name: []const u8,
    index: usize,
};

/// `Service<App>` — generic over the user's app type. `startService(io)`
/// accepts connections and hands each off to `io.async` — the caller's
/// `Io` (Threaded/Uring/Evented) schedules them on its worker pool. Per-
/// connection futures are tracked in a `Group` so they can be awaited
/// (or canceled) at shutdown.
pub fn Service(comptime App: type) type {
    return struct {
        name: []const u8,
        app: App,
        listeners: listeners_mod.Listeners,
        threads: ?usize = null,
        inflight: Io.Group = .init,

        const Self = @This();

        pub fn init(name: []const u8, app: App) Self {
            return .{ .name = name, .app = app, .listeners = listeners_mod.Listeners.init() };
        }

        pub fn addTcp(self: *Self, allocator: std.mem.Allocator, addr: []const u8) !void {
            try self.listeners.addTcp(allocator, addr);
        }

        /// Accept loop. Each accepted connection is dispatched to a worker
        /// via `Group.concurrent` and runs concurrently with all other
        /// connections. Blocks here until the listener errors fatally.
        pub fn startService(self: *Self, io: Io, allocator: std.mem.Allocator) !void {
            const built = try self.listeners.build(io, allocator);
            defer allocator.free(built);
            if (built.len == 0) return error.NoEndpoints;

            var listener = built[0];
            std.log.info("core: service '{s}' listening", .{self.name});

            while (true) {
                var stream = listener.accept(io) catch |err| {
                    std.log.warn("core: accept failed: {s}", .{@errorName(err)});
                    continue;
                };
                // ponytail: handing each conn to the Group means shutdown can
                // `self.inflight.cancel(io)` to break all in-flight proxied
                // requests at once. Today we just leak the group (process
                // exit reaps it); wire `cancel` into the v0.2 signal handler.
                self.inflight.concurrent(io, handleConn, .{ &self.app, io, stream }) catch |err| {
                    std.log.warn("core: dispatch failed: {s}", .{@errorName(err)});
                    stream.close(io);
                };
            }
        }

        fn handleConn(app: *App, io: Io, stream: Stream) void {
            const reused = app.process_new(io, stream) catch |err| {
                std.log.warn("core: process_new failed: {s}", .{@errorName(err)});
                stream.close(io);
                return;
            };
            if (reused) |r| r.close(io);
            stream.close(io);
        }
    };
}

// ===== Tests =====
test "ServiceHandle struct shape" {
    const h: ServiceHandle = .{ .name = "name", .index = 0 };
    try std.testing.expectEqualStrings("name", h.name);
    try std.testing.expectEqual(@as(usize, 0), h.index);
}
