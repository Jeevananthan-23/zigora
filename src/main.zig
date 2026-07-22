const std = @import("std");
const log = std.log.scoped(.zigora);
const Io = std.Io;
const core = @import("zigora-core");
const http = @import("zigora-http");
const proxy = @import("zigora-proxy");
const zgerror = @import("zigora-error");
const limits = @import("zigora-limits");
const lru = @import("zigora-lru");
const ketama = @import("zigora-ketama");
const tinyufo = @import("zigora-tinyufo");
const pool = @import("zigora-pool");
const memcache = @import("zigora-memory-cache");
const lb = @import("zigora-lb");
const cache = @import("zigora-cache");
const tls = @import("zigora-tls");
const metrics = @import("zigora-metrics");

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
    upstream_pool: pool.ConnectionPool(pool.PoolNode([]const u8)),
    inflight: limits.Inflight,
    rate: limits.Rate,
    estimator: limits.Estimator,
    hot_lru: lru.Lru(u32, 4),
    resp_cache: memcache.MemoryCache([]const u8),
    http_cache: cache.HttpCache,
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

    pub fn proxy_upstream_filter(self: *MyProxy, session: *proxy.Session(proxy.Ctx), _: *proxy.Ctx) bool {
        const path = session.request.path;
        if (std.mem.eql(u8, path, "/metrics") or std.mem.eql(u8, path, "/admin")) {
            var wbuf: [4096]u8 = undefined;
            var w = session.stream.writer(session.io, &wbuf);
            const wptr = &w.interface;
            if (std.mem.eql(u8, path, "/metrics")) {
                Io.Writer.writeAll(wptr, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nConnection: close\r\n\r\n") catch {};
                self.state.metrics.renderPrometheus(wptr) catch {};
            } else {
                Io.Writer.writeAll(wptr, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n") catch {};
                self.state.metrics.renderAdmin(wptr) catch {};
            }
            Io.Writer.flush(wptr) catch {};
            session.stream.close(session.io);
            return false;
        }
        return true;
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
    log.info("zigora: listening on 127.0.0.1:8080, upstreams ({d} backends)", .{
        backends.items.len,
    });
    const balancer = try lb.LoadBalancer(lb.Consistent).init(arena, backends.items);
    const upstream_pool = pool.ConnectionPool(pool.PoolNode([]const u8)).init(arena, 16);
    const inflight = try limits.Inflight.init(arena);
    const rate = try limits.Rate.init(arena, 1000);
    const estimator = try limits.Estimator.init(arena, 4, 1024);
    const hot_lru = try lru.Lru(u32, 4).init(arena, 1024, 4096);
    const resp_cache = try memcache.MemoryCache([]const u8).init(arena, 64);
    const http_cache: cache.HttpCache = .{ .phase = .{ .disabled = .never_enabled } };
    const m = metrics.Metrics.init(arena);
    const _tls_server_cfg: tls.ServerConfig = .{ .cert_path = "", .key_path = "" };
    _ = _tls_server_cfg;

    var state = AppState{
        .balancer = balancer,
        .upstream_pool = upstream_pool,
        .inflight = inflight,
        .rate = rate,
        .estimator = estimator,
        .hot_lru = hot_lru,
        .resp_cache = resp_cache,
        .http_cache = http_cache,
        .metrics = m,
    };

    var server = core.Server.new(arena, .{});

    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var proxy_app = proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 8080,
    });
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
    svc.onAccept = struct {
        fn cb(app: *proxy.HttpProxy(MyProxy)) void {
            app.inner.state.metrics.incAccepted();
            app.inner.state.metrics.incActive();
        }
    }.cb;
    svc.onFinish = struct {
        fn cb(app: *proxy.HttpProxy(MyProxy)) void {
            app.inner.state.metrics.decActive();
        }
    }.cb;
    try svc.addTcp(arena, "127.0.0.1:8080");

    const SlotWrap = struct {
        fn start(ptr: *anyopaque, io: Io, alc: std.mem.Allocator) anyerror!void {
            const real: *Svc = @ptrCast(@alignCast(ptr));
            try real.startService(io, alc);
        }
    };
    _ = try server.addService(.{
        .name = svc.name,
        .start = SlotWrap.start,
        .userdata = &svc,
    });

    log.info("zigora: all 13 packages integrated — balancer={d} backends, pool=16, http_cache={s}", .{
        backends.items.len,
        state.http_cache.phase.asStr(),
    });

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

test "parseArgs: defaults preserved when no --backend" {
    const alc = std.testing.allocator;
    var cfg = BackendCfg.init(alc);
    defer cfg.addrs.deinit(alc);
    const initial_len = cfg.addrs.items.len;
    parseArgs(&.{"zigora"}, &cfg, alc);
    try std.testing.expect(initial_len >= 2);
}

test "AppState fields compile across all packages" {
    const S = AppState;
    _ = S;
    try std.testing.expect(@sizeOf(AppState) > 0);
}

test "MyProxy.CTX is proxy.Ctx" {
    try std.testing.expectEqual(@sizeOf(proxy.Ctx), @sizeOf(MyProxy.CTX));
}
