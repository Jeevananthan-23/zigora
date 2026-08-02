//! Load-balancing reverse proxy example.
//! Distributes requests across two upstreams using Consistent hashing.
//! Serves Prometheus /metrics on port 8081.

const std = @import("std");
const log = std.log.scoped(.load_balancer);
const Io = std.Io;
const core = @import("zigora-core");
const proxy = @import("zigora-proxy");
const lb = @import("zigora-lb");
const metrics = @import("zigora-metrics");

const AppState = struct {
    balancer: lb.LoadBalancer(lb.Consistent),
    metrics: metrics.Metrics,
    counter: std.atomic.Value(u64) = .{ .raw = 0 },
};

const MyProxy = struct {
    pub const CTX = proxy.Ctx;

    state: *AppState,

    pub fn new_ctx(self: *MyProxy) proxy.Ctx {
        self.state.metrics.incRequests();
        return .{};
    }

    pub fn upstream_peer(self: *MyProxy, ctx: *proxy.Ctx) proxy.HttpPeer {
        const c = self.state.counter.fetchAdd(1, .monotonic);
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, c, .little);
        if (self.state.balancer.select(&key)) |b| {
            ctx.backend_host = "127.0.0.1";
            ctx.backend_port = std.Io.net.IpAddress.getPort(b.addr);
        }
        return .{ .host = ctx.backend_host, .port = ctx.backend_port };
    }

    pub fn renderMetrics(self: *MyProxy, w: *Io.Writer) void {
        self.state.metrics.renderPrometheus(w) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena = init.arena.allocator();

    var backends = [_]lb.Backend{
        try lb.Backend.newWithWeight("127.0.0.1:9000", 5),
        try lb.Backend.newWithWeight("127.0.0.1:9001", 5),
    };
    const balancer = try lb.LoadBalancer(lb.Consistent).init(arena, backends[0..]);
    const m = metrics.Metrics.init(arena);

    var state = AppState{ .balancer = balancer, .metrics = m };
    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var proxy_app = proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 9000,
    });
    proxy_app.renderMetrics = MyProxy.renderMetrics;
    proxy_app.onUpstreamConnect = struct {
        fn cb(p: *MyProxy) void { p.state.metrics.incUpstreamActive(); }
    }.cb;
    proxy_app.onUpstreamDisconnect = struct {
        fn cb(p: *MyProxy) void { p.state.metrics.decUpstreamActive(); }
    }.cb;
    proxy_app.onUpstreamError = struct {
        fn cb(p: *MyProxy) void { p.state.metrics.incUpstreamErrors(); }
    }.cb;
    proxy_app.upstreamBytes = &state.metrics.bytes_upstream;
    proxy_app.downstreamBytes = &state.metrics.bytes_downstream;

    var svc = Svc.init("lb_example", proxy_app);
    svc.onAccept = struct {
        fn cb(o: *proxy.HttpProxy(MyProxy)) void {
            o.inner.state.metrics.incAccepted();
            o.inner.state.metrics.incActive();
        }
    }.cb;
    svc.onFinish = struct {
        fn cb(o: *proxy.HttpProxy(MyProxy)) void {
            o.inner.state.metrics.decActive();
        }
    }.cb;
    try svc.addTcp(arena, "127.0.0.1:8081");
    var server = core.Server.new(arena, .{});
    _ = try server.addService(&svc);
    try server.runForever(process_io);
}