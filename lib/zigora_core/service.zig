//! Port of pingora-core's `Service<A>` + `ServerApp` trait. v0.1: type-erased
//! via vtable, single-threaded accept loop, no listeners-per-fn fanout.
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
/// runs the accept loop inline on the calling thread. No threads/DAG
/// support in v0.1 — each Service blocks until shutdown signal arrives.
pub fn Service(comptime App: type) type {
    return struct {
        name: []const u8,
        app: App,
        listeners: listeners_mod.Listeners,
        threads: ?usize = null,

        const Self = @This();

        pub fn init(name: []const u8, app: App) Self {
            return .{ .name = name, .app = app, .listeners = listeners_mod.Listeners.init() };
        }

        pub fn addTcp(self: *Self, allocator: std.mem.Allocator, addr: []const u8) !void {
            try self.listeners.addTcp(allocator, addr);
        }

        /// Run the accept loop. v0.1: single listener, single thread,
        /// runs until the process is killed.
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
                const reused = self.app.process_new(io, stream) catch |err| {
                    std.log.warn("core: process_new failed: {s}", .{@errorName(err)});
                    stream.close(io);
                    continue;
                };
                if (reused) |r| r.close(io);
                stream.close(io);
            }
        }
    };
}

// ===== Tests =====
test "ServiceHandle struct shape" {
    const h: ServiceHandle = .{ .name = "name", .index = 0 };
    try std.testing.expectEqualStrings("name", h.name);
    try std.testing.expectEqual(@as(usize, 0), h.index);
}
