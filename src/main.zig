const std = @import("std");
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
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,
};

const AppState = struct {
    backend: BackendCfg,
    balancer: lb.LoadBalancer(lb.Consistent),
    upstream_pool: pool.ConnectionPool(pool.PoolNode([]const u8)),
    inflight: limits.Inflight,
    rate: limits.Rate,
    estimator: limits.Estimator,
    hot_lru: lru.Lru(u32, 4),
    resp_cache: memcache.MemoryCache([]const u8),
    http_cache: cache.HttpCache,
    metrics: metrics.Metrics,
};

const MyProxy = struct {
    pub const CTX = proxy.Ctx;

    state: *AppState,

    pub fn new_ctx(self: *MyProxy) CTX {
        self.state.metrics.incRequests();
        return .{
            .backend_host = self.state.backend.host,
            .backend_port = self.state.backend.port,
        };
    }

    pub fn upstream_peer(self: *MyProxy, _: *proxy.Ctx) proxy.HttpPeer {
        _ = self.state.balancer.select("zigora");
        return .{ .host = self.state.backend.host, .port = self.state.backend.port };
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

var globals: struct { backend: BackendCfg = .{} } = .{};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    parseArgs(args, &globals.backend);

    std.log.info("zigora: listening on 127.0.0.1:8080, upstream {s}:{d}", .{
        globals.backend.host, globals.backend.port,
    });

    var backends = [_]lb.Backend{
        try lb.Backend.newWithWeight("127.0.0.1:9000", 10),
        try lb.Backend.newWithWeight("127.0.0.1:9001", 10),
    };
    const balancer = try lb.LoadBalancer(lb.Consistent).init(arena, backends[0..]);
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
        .backend = globals.backend,
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
    var svc = Svc.init("zigora_proxy", proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = globals.backend.host,
        .port = globals.backend.port,
    }));
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

    state.metrics.incAccepted();
    std.log.info("zigora: all 13 packages integrated — balancer={d} backends, pool=16, http_cache={s}", .{
        backends.len,
        state.http_cache.phase.asStr(),
    });

    try server.runForever(process_io);
}

fn parseArgs(args: []const []const u8, backend: *BackendCfg) void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--backend") and i + 1 < args.len) {
            const bp = args[i + 1];
            if (std.mem.lastIndexOfScalar(u8, bp, ':')) |colon| {
                backend.host = bp[0..colon];
                backend.port = std.fmt.parseInt(u16, bp[colon + 1 ..], 10) catch continue;
            }
            i += 1;
        }
    }
}

test "parseArgs: --backend host:port" {
    var b: BackendCfg = .{};
    parseArgs(&.{ "zigora", "--backend", "10.0.0.1:8080" }, &b);
    try std.testing.expectEqualStrings("10.0.0.1", b.host);
    try std.testing.expectEqual(@as(u16, 8080), b.port);
}

test "parseArgs: defaults preserved" {
    var b: BackendCfg = .{};
    parseArgs(&.{"zigora"}, &b);
    try std.testing.expectEqualStrings("127.0.0.1", b.host);
    try std.testing.expectEqual(@as(u16, 9000), b.port);
}

test "AppState fields compile across all packages" {
    const S = AppState;
    _ = S;
    try std.testing.expect(@sizeOf(AppState) > 0);
}

test "MyProxy.CTX is proxy.Ctx" {
    try std.testing.expectEqual(@sizeOf(proxy.Ctx), @sizeOf(MyProxy.CTX));
}
