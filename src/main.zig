const std = @import("std");
const log = std.log.scoped(.zigora);
const Io = std.Io;
const core = @import("zigora-core");
const proxy = @import("zigora-proxy");
const lb = @import("zigora-lb");
const metrics = @import("zigora-metrics");
const memcache = @import("zigora-memory-cache");

var global_metrics: ?*metrics.Metrics = null;
var global_state: ?*AppState = null;

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
    response_cache: memcache.MemoryCache([]const u8),
    cache_allocator: std.mem.Allocator,
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
        log.debug("routing to {s}:{d}", .{ ctx.backend_host, ctx.backend_port });
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
    const resp_cache = try memcache.MemoryCache([]const u8).init(arena, 256);

    var state = AppState{
        .balancer = balancer,
        .metrics = m,
        .response_cache = resp_cache,
        .cache_allocator = arena,
    };
    global_metrics = &state.metrics;
    global_state = &state;

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
    proxy_app.cacheLookup = struct {
        fn cb(path: []const u8) ?[]const u8 {
            const s = global_state.?;
            const result = s.response_cache.get(path);
            if (result.status.isHit()) {
                s.metrics.incCacheHit();
                return result.value;
            }
            s.metrics.incCacheMiss();
            return null;
        }
    }.cb;
    proxy_app.cachePut = struct {
        fn cb(path: []const u8, resp: []const u8) void {
            const s = global_state.?;
            // dupe the response bytes into the process arena — the proxy's
            // stack buffer is freed on return.
            const owned = s.cache_allocator.dupe(u8, resp) catch return;
            s.response_cache.put(path, owned, 60 * std.time.ns_per_s) catch return;
            s.metrics.incCachePut();
        }
    }.cb;

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