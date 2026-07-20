//! Port of pingora-proxy's `ProxyHttp` trait + `HttpProxy` struct.
//! v0.1: minimal `ProxyHttp` trait (3 callbacks: new_ctx, upstream_peer,
//! logging), `HttpProxy` vtable implementation of `ServerApp` that runs
//! the filter chain inline.
//!
//! See ARCHITECTURE.md §3 (zigora_proxy section).

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const core = @import("zigora-core");
const http = @import("zigora-http");
const zgerror = @import("zigora-error");
const Stream = net.Stream;

pub const zgproxy = @This();
pub const Error = zgerror.ZgError;
pub const ServerApp = core.ServerApp;

/// `pingora_proxy::ProxyHttp::CTX` equivalent. v0.1 carries just the
/// upstream buffer reference. v0.2 adds cache lock, retry count, etc.
pub const Ctx = struct {
    backend_host: []const u8 = "127.0.0.1",
    backend_port: u16 = 9000,
};

/// v0.1 upstream peer. v0.2 becomes a trait-equiv with weight/TLS/sni.
pub const HttpPeer = struct {
    host: []const u8,
    port: u16,
};

/// `pingora_proxy::ProxyHttp` trait. v0.1 minimum: 2 callbacks.
/// User implements a struct with these methods, then constructs
/// `HttpProxy(MyImpl)` and adds it as a Service to the Server.
pub fn ProxyHttp(comptime T: type) type {
    return struct {
        /// Per-request context type. Built fresh each request.
        pub const CTX = T.CTX;

        /// Create a per-request context. v0.1 stored inline on the stack
        /// of `process_new` — no allocation.
        pub fn newCtx(self: *T) CTX {
            return T.new_ctx(self);
        }

        /// Select the upstream peer for this request. v0.1 always returns
        /// the same peer; v0.2 brings LoadBalancer-based selection.
        pub fn upstreamPeer(self: *T, _: *Ctx) HttpPeer {
            return T.upstream_peer(self);
        }
    };
}

/// `pingora_proxy::HttpProxy<SV>` — the `ServerApp` impl. Generic over
/// the user's `ProxyHttp` implementation. Constructed via
/// `HttpProxy.init(impl)`. Add as a Service via `server.addService(svc)`.
pub fn HttpProxy(comptime T: type) type {
    return struct {
        inner: *T,
        backend: HttpPeer,

        const Self = @This();

        pub fn init(impl: *T, backend: HttpPeer) Self {
            return .{ .inner = impl, .backend = backend };
        }

        /// Implement `core.ServerApp.process_new(io, stream)`.
        /// v0.1: parse request → log → forward to backend → splice response
        /// back → close. No keepalive, no retry, no filter chain yet.
        pub fn process_new(self: *Self, io: Io, stream: Stream) error{ProcessFailed}!?Stream {
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = net.Stream.reader(stream, io, &read_buf);
            var writer = net.Stream.writer(stream, io, &write_buf);

            // Read available bytes (request headers + small bodies).
            const req_bytes = reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return error.ProcessFailed,
            };
            if (req_bytes.len == 0) return null;

            // Pingora's early_request_filter runs here in v0.2.
            var ctx = ProxyHttp(T).newCtx(self.inner);
            _ = &ctx;

            // Log the request line.
            if (http.Request.parse(read_buf[0..req_bytes.len])) |req| {
                std.log.info("proxy: {s} {s}", .{ @tagName(req.method), req.path });
            } else |_| {
                std.log.info("proxy: (unparseable request: {d} bytes)", .{req_bytes.len});
            }

            // Forward to upstream.
            dispatchToUpstream(io, self.backend.host, self.backend.port, req_bytes, &writer.interface) catch {
                return error.ProcessFailed;
            };
            return null; // v0.1: no keepalive
        }

        pub fn cleanup(self: *Self, _: Io) void {
            _ = self;
        }
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

/// Forward raw buffer to upstream, splice response back to client.
fn dispatchToUpstream(
    io: Io,
    host: []const u8,
    port: u16,
    client_buf: []const u8,
    client_writer: *Io.Writer,
) !void {
    const ip4 = net.Ip4Address.parse(host, port) catch return error.InvalidUpstream;
    const addr: net.IpAddress = .{ .ip4 = ip4 };
    var ups = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectFailed;
    defer ups.close(io);

    if (client_buf.len > 0) {
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