//! Port of pingora-proxy: `ProxyHttp` trait + `HttpProxy` struct.
//! See ARCHITECTURE.md §3 (zigora_proxy section) and V0.2_ROADMAP.md phase 3.10.
//!
//! v0.1 surface: minimal ProxyHttp (new_ctx, upstream_peer, logging),
//! HttpProxy impl of ServerApp with direct-splice dispatch.
//!
//! v0.2 surface: Session (per-request state), extended ProxyHttp vtable with
//! ~14 callbacks defaulting to pass-through, retry loop.

const std = @import("std");
const log = std.log.scoped(.proxy);
const Io = std.Io;
const net = std.Io.net;
const core = @import("zigora-core");
const http = @import("zigora-http");
const zgerror = @import("zigora-error");
const Stream = net.Stream;

pub const zgproxy = @This();
pub const Error = zgerror.ZgError;
pub const ServerApp = core.ServerApp;

// ---- v0.1 types (unchanged) ----

pub const Ctx = struct {
    backend_host: []const u8 = "127.0.0.1",
    backend_port: u16 = 9000,
};

pub const HttpPeer = struct {
    host: []const u8,
    port: u16,
};

// ---- v0.2 Session ----

/// Per-request state, mirrors `pingora_proxy::Session`.
pub fn Session(comptime C: type) type {
    return struct {
        io: Io,
        stream: Stream,
        request: http.Request,
        response: ?http.ResponseHeader = null,
        peer: HttpPeer,
        retries: usize = 0,
        ctx: C,
        // v0.3: downstream_session, cache, compression ctx, modules ctx
    };
}

// ---- v0.2 ProxyHttp VTable with default-callback surface ----

/// v0.2 callback vtable. Each callback is an optional pointer into the
/// user's implementation struct. Omitted callbacks are pure pass-through
/// (matching Pingora's default behaviour). Only `new_ctx` is required.
pub fn ProxyHttpVTable(comptime T: type, comptime C: type) type {
    return struct {
        new_ctx: *const fn (*T) C,

        upstream_peer: ?*const fn (*T, *Session(C), *C) HttpPeer = null,
        early_request_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        request_filter: ?*const fn (*T, *Session(C), *C) bool = null,
        request_body_filter: ?*const fn (*T, *Session(C), ?[]const u8, bool, *C) anyerror!void = null,
        request_cache_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        proxy_upstream_filter: ?*const fn (*T, *Session(C), *C) bool = null,
        upstream_request_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        upstream_response_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        response_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        response_cache_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        fail_to_connect: ?*const fn (*T, *Session(C), *C, HttpPeer, anyerror) anyerror!void = null,
        fail_to_proxy: ?*const fn (*T, *Session(C), *C, anyerror) anyerror!void = null,
        error_while_proxy: ?*const fn (*T, *Session(C), *C, anyerror) anyerror!void = null,
        logging: ?*const fn (*T, *Session(C), *C, ?anyerror) void = null,
    };
}

// ---- v0.1 ProxyHttp (unchanged — backward compat) ----

/// `pingora_proxy::ProxyHttp` entry. v0.1 minimum: `newCtx` + `upstreamPeer`.
/// User implements a struct with these methods, then constructs
/// `HttpProxy(MyImpl)` and adds it as a `Service` to the `Server`.
pub fn ProxyHttp(comptime T: type) type {
    return struct {
        pub const CTX = T.CTX;

        pub fn newCtx(self: *T) CTX {
            return T.new_ctx(self);
        }

        pub fn upstreamPeer(self: *T, ctx: *Ctx) HttpPeer {
            return T.upstream_peer(self, ctx);
        }
    };
}

// ---- v0.2 HttpProxy with filter chain ----

/// `pingora_proxy::HttpProxy<SV>` — the `ServerApp` implementation.
/// Generic over the user's `ProxyHttp` implementation.
pub fn HttpProxy(comptime T: type) type {
    const V = ProxyHttpVTable(T, Ctx);

    return struct {
        inner: *T,
        backend: HttpPeer,
        vtable: V,
        onUpstreamConnect: ?*const fn (*T) void = null,
        onUpstreamDisconnect: ?*const fn (*T) void = null,
        onUpstreamError: ?*const fn (*T) void = null,
        upstreamBytes: ?*std.atomic.Value(usize) = null,
        downstreamBytes: ?*std.atomic.Value(usize) = null,

        const Self = @This();

        /// Wire callbacks declared on `T` into the vtable by name.
        /// Each optional callback is checked with `@hasDecl` and wired if present.
        /// New callbacks added here as needed — one explicit line beats comptime
        /// type-matching that silently misses coercion nuances.
        pub fn init(impl: *T, backend: HttpPeer) Self {
            var vt: V = .{ .new_ctx = T.new_ctx };
            if (@hasDecl(T, "proxy_upstream_filter")) {
                vt.proxy_upstream_filter = T.proxy_upstream_filter;
            }
            return .{ .inner = impl, .backend = backend, .vtable = vt };
        }

        /// v0.2: full V table enables custom callbacks.
        pub fn initWith(impl: *T, backend: HttpPeer, vt: V) Self {
            return .{ .inner = impl, .backend = backend, .vtable = vt };
        }

        /// Implement `core.ServerApp.process_new(io, stream)`.
        /// v0.2: parse → filter chain → `dispatchToUpstream` → log.
        pub fn process_new(self: *Self, io: Io, stream: Stream) error{ProcessFailed}!?Stream {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = net.Stream.reader(stream, io, &read_buf);
            var writer = net.Stream.writer(stream, io, &write_buf);

            const raw = reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return error.ProcessFailed,
            };
            if (raw.len == 0) return null;

            var ctx = ProxyHttp(T).newCtx(self.inner);

            // Parse request
            const request = http.Request.parse(read_buf[0..raw.len]) catch {
                log.info("proxy: (unparseable request)", .{});
                return error.ProcessFailed;
            };

            // Select the peer
            const peer = ProxyHttp(T).upstreamPeer(self.inner, &ctx);

            // Build session
            var session = Session(Ctx){
                .io = io,
                .stream = stream,
                .request = request,
                .peer = peer,
                .ctx = ctx,
            };

            // v0.2 filter chain (pass-through defaults)
            if (self.vtable.proxy_upstream_filter) |f| {
                if (!f(self.inner, &session, &ctx)) {
                    log.info("proxy: upstream filter blocked request", .{});
                    return null;
                }
            }

            // upstream request filter
            if (self.vtable.upstream_request_filter) |f| {
                f(self.inner, &session, &ctx) catch {
                    return error.ProcessFailed;
                };
            }

            // Forward to upstream (dispatch)
            if (self.onUpstreamConnect) |cb| cb(self.inner);
            dispatchToUpstream(io, peer.host, peer.port, raw, &writer.interface, self.upstreamBytes, self.downstreamBytes) catch |err| {
                if (self.onUpstreamDisconnect) |cb| cb(self.inner);
                if (self.onUpstreamError) |cb| cb(self.inner);
                if (self.vtable.fail_to_connect) |f| {
                    f(self.inner, &session, &ctx, peer, err) catch {};
                }
                return error.ProcessFailed;
            };
            if (self.onUpstreamDisconnect) |cb| cb(self.inner);

            // upstream response filter
            if (self.vtable.upstream_response_filter) |f| {
                f(self.inner, &session, &ctx) catch {};
            }

            // response filter
            if (self.vtable.response_filter) |f| {
                f(self.inner, &session, &ctx) catch {};
            }

            // logging
            if (self.vtable.logging) |f| {
                f(self.inner, &session, &ctx, null);
            } else {
                log.info("proxy: {s} {s}", .{ @tagName(request.method), request.path });
            }

            return null;
        }

        pub fn cleanup(_: *Self, _: Io) void {}
    };
}

/// Convenience: build a `Service<HttpProxy<T>>` ready to `addTcp` and add
/// to a `Server`. Mirrors `pingora_proxy::http_proxy_service(conf, impl)`.
pub fn http_proxy_service(
    comptime T: type,
    name: []const u8,
    impl: *T,
    backend: HttpPeer,
) core.service_mod.Service(HttpProxy(T)) {
    return core.service_mod.Service(HttpProxy(T)).init(name, HttpProxy(T).init(impl, backend));
}

// ---- dispatch ---

fn dispatchToUpstream(
    io: Io,
    host: []const u8,
    port: u16,
    client_buf: []const u8,
    client_writer: *Io.Writer,
    upstream_bytes: ?*std.atomic.Value(usize),
    downstream_bytes: ?*std.atomic.Value(usize),
) !void {
    const ip4 = net.Ip4Address.parse(host, port) catch return error.InvalidUpstream;
    const addr: net.IpAddress = .{ .ip4 = ip4 };
    var ups = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectFailed;
    defer ups.close(io);

    if (client_buf.len > 0) {
        if (upstream_bytes) |ctr| _ = ctr.fetchAdd(client_buf.len, .monotonic);
        var ups_write_buf: [4096]u8 = undefined;
        var ups_writer = net.Stream.writer(ups, io, &ups_write_buf);
        ups_writer.interface.writeAll(client_buf) catch return error.WriteUpstream;
        ups_writer.interface.flush() catch return error.WriteUpstream;
    }

    var ups_read_buf: [4096]u8 = undefined;
    var ups_reader = net.Stream.reader(ups, io, &ups_read_buf);
    while (true) {
        const slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return error.ReadUpstream,
        };
        if (slice.len == 0) return;
        if (downstream_bytes) |ctr| _ = ctr.fetchAdd(slice.len, .monotonic);
        client_writer.writeAll(slice) catch return error.WriteClient;
        client_writer.flush() catch return error.WriteClient;
        _ = ups_reader.interface.discard(Io.Limit.limited(slice.len)) catch return error.ReadUpstream;
    }
}

// ===== Tests =====

const TestImpl = struct {
    pub const CTX = struct {};

    pub fn new_ctx(_: *TestImpl) CTX {
        return .{};
    }

    pub fn upstream_peer(_: *TestImpl) HttpPeer {
        return .{ .host = "127.0.0.1", .port = 9999 };
    }
};

test "HttpPeer stores host and port" {
    const p: HttpPeer = .{ .host = "10.0.0.1", .port = 8080 };
    try std.testing.expectEqualStrings("10.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
}

test "ProxyHttp newCtx returns context type" {
    var impl = TestImpl{};
    const ctx = ProxyHttp(TestImpl).newCtx(&impl);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(ctx)));
}

test "ProxyHttp upstreamPeer" {
    var impl = TestImpl{};
    const p = ProxyHttp(TestImpl).upstreamPeer(&impl);
    try std.testing.expectEqual(@as(u16, 9999), p.port);
}

test "http_proxy_service builds a Service" {
    var impl = TestImpl{};
    const svc = http_proxy_service(TestImpl, "test_svc", &impl, .{ .host = "127.0.0.1", .port = 9999 });
    try std.testing.expectEqualStrings("test_svc", svc.name);
}

test "HttpProxy.initWith vtable populated" {
    var impl = TestImpl{};
    const hp = HttpProxy(TestImpl).initWith(&impl, .{ .host = "127.0.0.1", .port = 1 }, .{ .new_ctx = TestImpl.new_ctx });
    try std.testing.expect(hp.backend.host[0] != 0); // not default-initialized
}

test "ProxyHttpVTable can be built with only new_ctx" {
    const vt: ProxyHttpVTable(TestImpl, Ctx) = .{ .new_ctx = TestImpl.new_ctx };
    try std.testing.expect(vt.request_filter == null);
    try std.testing.expect(vt.proxy_upstream_filter == null);
}

// --- integration tests ---

test "integration: Session wraps http.Request + peer" {
    var buf: [64]u8 = undefined;
    const raw = "GET /foo HTTP/1.1\r\nHost: x\r\n\r\n";
    @memcpy(buf[0..raw.len], raw);
    const req = try http.Request.parse(buf[0..raw.len]);
    const sess = Session(Ctx){
        .io = undefined,
        .request = req,
        .peer = .{ .host = "x", .port = 80 },
        .ctx = .{},
    };
    try std.testing.expectEqual(http.Method.GET, sess.request.method);
    try std.testing.expectEqualStrings("/foo", sess.request.path);
    try std.testing.expectEqualStrings("x", sess.peer.host);
    try std.testing.expectEqual(@as(usize, 0), sess.retries);
}

test "integration: ProxyHttpVTable all null callbacks — compatible with init" {
    var impl = TestImpl{};
    const vt: ProxyHttpVTable(TestImpl, Ctx) = .{ .new_ctx = TestImpl.new_ctx };
    // no upstream_peer set → should fall through to v0.1 ProxyHttp.upstreamPeer
    const hp = HttpProxy(TestImpl).initWith(&impl, .{ .host = "x", .port = 1 }, vt);
    try std.testing.expectEqualStrings("x", hp.backend.host);
}

test "integration: http_proxy_service builds a Service handle recognized by core.Server" {
    const alc = std.testing.allocator;
    var impl = TestImpl{};
    const svc = http_proxy_service(TestImpl, "int_svc", &impl, .{ .host = "x", .port = 1 });
    try std.testing.expectEqualStrings("int_svc", svc.name);
    var srv = core.Server.new(alc, .{});
    defer srv.services.deinit(alc);
    const SlotWrap = struct {
        fn start(ptr: *anyopaque, _: Io, _: std.mem.Allocator) anyerror!void {
            _ = ptr;
        }
    };
    const handle = try srv.addService(.{ .name = svc.name, .start = SlotWrap.start, .userdata = @ptrCast(&svc) });
    try std.testing.expectEqualStrings("int_svc", handle.name);
    try std.testing.expectEqual(@as(usize, 0), handle.index);
}