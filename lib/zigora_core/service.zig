//! Port of pingora-core's `Service<A>` + `ServerApp` trait. v0.2: the accept
//! loop spawns one `io.async` per inbound connection on the `std.Io` worker
//! pool — non-blocking, concurrent. Inflight connections tracked via `Group`
//! for graceful shutdown via `group.cancel(io)`.
//!
//! See ARCHITECTURE.md §3 (zigora_core section).

const std = @import("std");
const log = std.log.scoped(.core);
const Io = std.Io;
const net = std.Io.net;
const listeners_mod = @import("listeners.zig");
const server_mod = @import("server.zig");
const runtime_mod = @import("runtime.zig");
const ShutdownWatch = server_mod.ShutdownWatch;
const NoStealRuntime = runtime_mod.NoStealRuntime;
const Stream = net.Stream;

pub const zgcore_service = @This();

/// `pingora_core::apps::ServerApp::process_new()` — the trait every proxy
/// app implements. Zig has no traits; this is a vtable struct. Users create
/// one via `ServerApp.implement(impl_struct)`.
pub const ServerApp = struct {
    vtable: *const VTable,
    userdata: *anyopaque,

    pub const VTable = struct {
        process_new: *const fn (app: *ServerApp, io: Io, stream: Stream) error{ProcessFailed}!?Stream,
        cleanup: *const fn (app: *ServerApp, io: Io) void = defaultCleanup,
    };

    fn defaultCleanup(app: *ServerApp, io: Io) void {
        _ = app;
        _ = io;
    }

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
        shutdown_watch: ?ShutdownWatch = null,
        server_ref: ?*server_mod.Server = null,
        onAccept: ?*const fn (*App) void = null,
        onFinish: ?*const fn (*App) void = null,
        runtime: ?*NoStealRuntime = null,

        const Self = @This();

        pub fn init(name: []const u8, app: App) Self {
            return .{ .name = name, .app = app, .listeners = listeners_mod.Listeners.init() };
        }

        pub fn setShutdown(self: *Self, sh: ShutdownWatch, svr: *server_mod.Server) void {
            self.shutdown_watch = sh;
            self.server_ref = svr;
        }

        /// Assign the NoSteal runtime: accepts stay on engine 0, each
        /// connection is dispatched to a random engine (never engine 0).
        pub fn setRuntime(self: *Self, rt: *NoStealRuntime) void {
            self.runtime = rt;
        }

        /// The engine a newly accepted connection runs on. With a NoSteal
        /// runtime each connection is dispatched to a random engine; without
        /// one, connections run on the accept engine like before.
        fn connIo(self: *Self, accept_io: Io) Io {
            if (self.runtime) |rt| return rt.getRandomIo();
            return accept_io;
        }

        pub fn addTcp(self: *Self, allocator: std.mem.Allocator, addr: []const u8) !void {
            try self.listeners.addTcp(allocator, addr);
        }

        pub fn startService(self: *Self, io: Io, allocator: std.mem.Allocator) !void {
            const built = try self.listeners.build(io, allocator);
            defer allocator.free(built);
            if (built.len == 0) return error.NoEndpoints;

            log.debug("core: service '{s}' starting on {d} listener(s)", .{ self.name, built.len });

            // Register listener fds with Server so shutdown() can close them.
            if (self.server_ref) |s| {
                for (built) |l| s.addListenerFd(l.socket.handle) catch {};
            }

            const sh = self.shutdown_watch;

            if (built.len <= 1) {
                // single listener — accept loop inline
                var listener = built[0];
                self.acceptLoop(io, &listener, sh);
            } else {
                // multi-listener: spawn N accept futures, join them
                const AcceptFuture = std.Io.Future(void);
                const futures = try allocator.alloc(AcceptFuture, built.len);
                defer allocator.free(futures);

                const LoopAdapter = struct {
                    fn run(svc: *Self, ioval: Io, l: *net.Server, shutdown: ?server_mod.ShutdownWatch) void {
                        svc.acceptLoop(ioval, l, shutdown);
                    }
                };

                for (built, 0..) |*l, i| {
                    futures[i] = io.async(LoopAdapter.run, .{ self, io, l, sh });
                }
                for (futures) |*f| {
                    _ = f.await(io);
                }
            }
            // Drain: wait for in-flight connections before returning, so
            // callers can deinit state while no handler is running.
            self.inflight.await(io) catch {};
            log.info("core: service '{s}' shutting down", .{self.name});
        }

        fn acceptLoop(self: *Self, io: Io, listener: *net.Server, sh: ?server_mod.ShutdownWatch) void {
            const no_shutdown = (sh == null);
            if (no_shutdown) {
                while (true) {
                    var stream = listener.accept(io) catch |err| {
                        log.warn("core: accept failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    if (self.onAccept) |cb| cb(&self.app);
                    const conn_io = self.connIo(io);
                    self.inflight.concurrent(conn_io, handleConn, .{ self, conn_io, stream }) catch |err| {
                        log.warn("core: dispatch failed: {s}", .{@errorName(err)});
                        stream.close(io);
                    };
                }
            } else {
                while (!sh.?.check()) {
                    var stream = listener.accept(io) catch |err| {
                        if (sh.?.check()) return;
                        log.warn("core: accept failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    if (self.onAccept) |cb| cb(&self.app);
                    const conn_io = self.connIo(io);
                    self.inflight.concurrent(conn_io, handleConn, .{ self, conn_io, stream }) catch |err| {
                        log.warn("core: dispatch failed: {s}", .{@errorName(err)});
                        stream.close(io);
                    };
                }
            }
        }

        fn handleConn(self: *Self, io: Io, stream: Stream) void {
            defer if (self.onFinish) |cb| cb(&self.app);
            const reused = self.app.process_new(io, stream) catch |err| {
                log.warn("core: process_new failed: {s}", .{@errorName(err)});
                stream.close(io);
                return;
            };
            if (reused) |r| {
                r.close(io);
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
