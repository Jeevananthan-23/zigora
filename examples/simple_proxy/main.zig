//! Simple reverse proxy example.
//! Forwards all requests to 127.0.0.1:9000.
//! Serves Prometheus /metrics and /admin on the same port.

const std = @import("std");
const log = std.log.scoped(.simple_proxy);
const Io = std.Io;
const zigora = @import("zigora");
const core = zigora.core;
const proxy = zigora.proxy;
const metrics = zigora.metrics;

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

    pub fn renderMetrics(self: *MyProxy, w: *Io.Writer) void {
        self.state.metrics.renderPrometheus(w) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena = init.arena.allocator();
    const m = metrics.Metrics.init(arena);

    var state = AppState{ .metrics = m };
    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var proxy_app = proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 9000,
    });
    proxy_app.renderMetrics = MyProxy.renderMetrics;
    var svc = Svc.init("simple_proxy", proxy_app);
    try svc.addTcp(arena, "127.0.0.1:8080");
    var server = core.Server.new(arena, .{});
    _ = try server.addService(&svc);
    state.metrics.incAccepted();
    try server.runForever(process_io);
}