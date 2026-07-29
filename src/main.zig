const std = @import("std");
const log = std.log.scoped(.zigora);
const Io = std.Io;
const core = @import("zigora-core");
const proxy = @import("zigora-proxy");
const lb = @import("zigora-lb");
const metrics = @import("zigora-metrics");

var global_metrics: ?*metrics.Metrics = null;

fn renderMetrics(w: *Io.Writer) void {
    if (global_metrics) |m| m.renderPrometheus(w) catch {};
}

fn renderAdmin(w: *Io.Writer) void {
    if (global_metrics) |m| m.renderAdmin(w) catch {};
}

const BackendCfg = struct {
    addrs: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) BackendCfg {
        var addrs = std.ArrayList([]const u8).empty;
        addrs.append(allocator, "127.0.0.1:9000") catch unreachable;
        addrs.append(allocator, "127.0.0.1:9001") catch unreachable;
        return .{ .addrs = addrs };
    }
};

const AppState = struct {
    balancer: lb.LoadBalancer(lb.Consistent),
    metrics: metrics.Metrics,
    counter: std.atomic.Value(u64) = .{ .raw = 0 },
};

const MyProxy = struct {
    pub const CTX = proxy.Ctx;

    state: *AppState,

    pub fn new_ctx(self: *MyProxy) CTX {
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
        log.info("routing to {s}:{d}", .{ ctx.backend_host, ctx.backend_port });
        return .{ .host = ctx.backend_host, .port = ctx.backend_port };
    }
};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var cfg = BackendCfg.init(arena);
    parseArgs(args, &cfg, arena);

    var backends = try std.ArrayList(lb.Backend).initCapacity(arena, cfg.addrs.items.len);
    for (cfg.addrs.items) |addr| {
        backends.appendAssumeCapacity(try lb.Backend.newWithWeight(addr, 10));
    }
    log.info("zigora: listening on 127.0.0.1:8080, {d} backends", .{backends.items.len});

    const balancer = try lb.LoadBalancer(lb.Consistent).init(arena, backends.items);
    const m = metrics.Metrics.init(arena);

    var state = AppState{
        .balancer = balancer,
        .metrics = m,
    };
    global_metrics = &state.metrics;

    var server = core.Server.new(arena, .{});
    const shutdown = server.shutdownWatch();

    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var proxy_app = proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 8080,
    });
    proxy_app.renderMetrics = &renderMetrics;
    proxy_app.renderAdmin = &renderAdmin;
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

    var svc = Svc.init("zigora_proxy", proxy_app);
    svc.setShutdown(shutdown);
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
    try svc.addTcp(arena, "127.0.0.1:8080");

    const SlotWrap = struct {
        fn start(ud: *anyopaque, io: Io, alc: std.mem.Allocator) anyerror!void {
            const real: *Svc = @ptrCast(@alignCast(ud));
            try real.startService(io, alc);
        }
    };
    _ = try server.addService(.{
        .name = svc.name,
        .start = SlotWrap.start,
        .userdata = &svc,
    });

    log.info("zigora: listening on 127.0.0.1:8080 with {d} backends", .{backends.items.len});

    try server.runForever(process_io);
}

fn parseArgs(args: []const []const u8, cfg: *BackendCfg, allocator: std.mem.Allocator) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--backend") and i + 1 < args.len) {
            cfg.addrs.append(allocator, args[i + 1]) catch {};
            i += 1;
        }
    }
}

test "parseArgs: --backend host:port" {
    const alc = std.testing.allocator;
    var cfg = BackendCfg.init(alc);
    defer cfg.addrs.deinit(alc);
    const initial_len = cfg.addrs.items.len;
    parseArgs(&.{ "zigora", "--backend", "10.0.0.1:8080" }, &cfg, alc);
    try std.testing.expectEqualStrings("10.0.0.1:8080", cfg.addrs.items[initial_len]);
}

test "defaults preserved when no --backend" {
    const alc = std.testing.allocator;
    var cfg = BackendCfg.init(alc);
    defer cfg.addrs.deinit(alc);
    const initial_len = cfg.addrs.items.len;
    parseArgs(&.{"zigora"}, &cfg, alc);
    try std.testing.expect(initial_len >= 2);
}

test "AppState is a struct" {
    try std.testing.expect(@sizeOf(AppState) > 0);
}