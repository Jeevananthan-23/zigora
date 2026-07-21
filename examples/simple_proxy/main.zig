//! Simple reverse proxy example.
//! Forwards all requests to 127.0.0.1:9000.
//! Serves Prometheus /metrics and /admin on the same port.

const std = @import("std");
const Io = std.Io;
const core = @import("zigora-core");
const http = @import("zigora-http");
const proxy = @import("zigora-proxy");
const metrics = @import("zigora-metrics");

const AppState = struct {
    metrics: metrics.Metrics,
};

const MyProxy = struct {
    pub const CTX = proxy.Ctx;

    state: *AppState,

    pub fn new_ctx(_: *MyProxy) proxy.Ctx {
        return .{};
    }

    pub fn upstream_peer(_: *MyProxy, _: *proxy.Ctx) proxy.HttpPeer {
        return .{ .host = "127.0.0.1", .port = 9000 };
    }

    pub fn proxy_upstream_filter(self: *MyProxy, session: *proxy.Session(proxy.Ctx), _: *proxy.Ctx) bool {
        const path = session.request.path;
        if (std.mem.eql(u8, path, "/metrics")) {
            var wbuf: [4096]u8 = undefined;
            var w = session.stream.writer(session.io, &wbuf);
            const wptr = &w.interface;
            Io.Writer.writeAll(wptr, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nConnection: close\r\n\r\n") catch {};
            self.state.metrics.renderPrometheus(wptr) catch {};
            Io.Writer.flush(wptr) catch {};
            session.stream.close(session.io);
            return false;
        }
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena = init.arena.allocator();
    const m = metrics.Metrics.init(arena);
    var state = AppState{ .metrics = m };
    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var svc = Svc.init("simple_proxy", proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 9000,
    }));
    try svc.addTcp(arena, "127.0.0.1:8080");
    const SlotWrap = struct {
        fn start(ptr: *anyopaque, io: std.Io, alc: std.mem.Allocator) anyerror!void {
            const real: *Svc = @ptrCast(@alignCast(ptr));
            try real.startService(io, alc);
        }
    };
    var server = core.Server.new(arena, .{});
    _ = try server.addService(.{
        .name = svc.name,
        .start = SlotWrap.start,
        .userdata = &svc,
    });
    state.metrics.incAccepted();
    try server.runForever(process_io);
}
