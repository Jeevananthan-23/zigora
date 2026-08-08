const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.zigora);
const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;
const core = @import("zigora_core.zig");
const proxy = @import("zigora_proxy.zig");
const lb = @import("zigora_lb.zig");
const metrics = @import("zigora_metrics.zig");
const memcache = @import("zigora_memory_cache.zig");
const pool = @import("zigora_pool.zig");

const BackendCfg = struct {
    addrs: std.ArrayList([]const u8),

    pub fn init(_: std.mem.Allocator) BackendCfg {
        return .{ .addrs = std.ArrayList([]const u8).empty };
    }
};

const AppState = struct {
    balancer: lb.LoadBalancer(lb.Consistent),
    metrics: metrics.Metrics,
    counter: std.atomic.Value(u64) = .{ .raw = 0 },
    response_cache: memcache.MemoryCache([]const u8),
    cache_allocator: std.mem.Allocator,
    /// Set after the runtime exists; used by the pool's destroy closure.
    runtime: ?*core.NoStealRuntime = null,
    upstream_pool: pool.ConnectionPool(Stream),
};

/// Liveness probe: PEEK the socket without consuming. Alive iff the peer
/// hasn't FIN'd or reset and no leftover bytes sit in the buffer (a leftover
/// means a protocol desync, so the conn must not be reused).
fn poolIsLive(ctx: ?*anyopaque, s: *Stream) bool {
    const st: *AppState = @ptrCast(@alignCast(ctx.?));
    var buf: [1]u8 = undefined;
    const r = std.os.linux.recvfrom(
        s.socket.handle,
        &buf,
        1,
        std.os.linux.MSG.PEEK | std.os.linux.MSG.DONTWAIT,
        null,
        null,
    );
    const live = std.os.linux.errno(r) == .AGAIN;
    if (live) st.metrics.incPoolReuse();
    return live;
}

/// Close a pooled conn the pool decided to drop (dead or stale).
fn poolDestroy(ctx: ?*anyopaque, s: *Stream) void {
    const st: *AppState = @ptrCast(@alignCast(ctx.?));
    st.metrics.incPoolStale();
    if (st.runtime) |rt| s.close(rt.acceptIo());
}

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

    pub fn renderMetrics(self: *MyProxy, w: *Io.Writer) void {
        self.state.metrics.renderPrometheus(w) catch {};
    }

    pub fn renderAdmin(self: *MyProxy, w: *Io.Writer) void {
        self.state.metrics.renderAdmin(w) catch {};
    }

    pub fn cacheLookup(self: *MyProxy, path: []const u8) ?[]const u8 {
        const result = self.state.response_cache.get(path);
        if (result.status.isHit()) {
            self.state.metrics.incCacheHit();
            return result.value;
        }
        self.state.metrics.incCacheMiss();
        return null;
    }

    pub fn cachePut(self: *MyProxy, path: []const u8, resp: []const u8) void {
        // dupe the response bytes into the process arena — the proxy's
        // stack buffer is freed on return.
        const owned = self.state.cache_allocator.dupe(u8, resp) catch return;
        self.state.response_cache.put(path, owned, 60 * std.time.ns_per_s) catch return;
        self.state.metrics.incCachePut();
    }
};

pub fn main(init: std.process.Init) !void {
    // Debug/ReleaseSafe: leak-checking allocator; ReleaseFast/Small: the
    // lock-free per-CPU smp allocator (see docs/MEMORY_MANAGEMENT.md).
    var debug_alloc: std.heap.DebugAllocator(.{ .stack_trace_frames = 32 }) = .init;
    const allocator: std.mem.Allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_alloc.allocator(),
        else => std.heap.smp_allocator,
    };
    defer {
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)
            std.debug.assert(debug_alloc.deinit() == .ok);
    }

    // Process args live on the init arena — they outlive everything.
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var cfg = BackendCfg.init(allocator);
    parseArgs(args, &cfg, allocator);

    if (cfg.addrs.items.len == 0) {
        try cfg.addrs.append(allocator, "127.0.0.1:9000");
    }
    defer cfg.addrs.deinit(allocator);

    var backends = try std.ArrayList(lb.Backend).initCapacity(allocator, cfg.addrs.items.len);
    defer backends.deinit(allocator);
    for (cfg.addrs.items) |addr| {
        backends.appendAssumeCapacity(try lb.Backend.newWithWeight(addr, 10));
    }
    log.info("zigora: listening on 127.0.0.1:8080, {d} backends", .{backends.items.len});

    var balancer = try lb.LoadBalancer(lb.Consistent).init(allocator, backends.items);
    defer balancer.deinit();
    var m = metrics.Metrics.init(allocator);
    defer m.deinit();
    const resp_cache = try memcache.MemoryCache([]const u8).init(allocator, 256);

    var state = AppState{
        .balancer = balancer,
        .metrics = m,
        .response_cache = resp_cache,
        .cache_allocator = allocator,
        .upstream_pool = undefined,
    };
    // Deinit the copy AppState holds — the proxy mutates it, so the local
    // copy's arraylist pointers go stale after the first put.
    defer state.response_cache.deinit();
    state.upstream_pool = pool.ConnectionPool(Stream).init(allocator, 16, .{
        .idle_ms = 5 * std.time.ns_per_s,
        .ctx = @ptrCast(&state),
        .is_live = poolIsLive,
        .destroy = poolDestroy,
    });
    defer state.upstream_pool.deinit();

    var server = core.Server.new(allocator, .{});
    defer server.deinit();
    const shutdown = server.shutdownWatch();

    // Pingora-style NoSteal runtime: one engine per CPU. Engine 0 owns the
    // accept loop; connections are spread across engines 1..n (see
    // zigora_core/runtime.zig).
    const n_cpu: usize = std.Thread.getCpuCount() catch 4;
    var runtime = try core.NoStealRuntime.init(allocator, n_cpu);
    defer runtime.deinit();
    state.runtime = &runtime;

    var my_proxy = MyProxy{ .state = &state };
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var proxy_app = proxy.HttpProxy(MyProxy).init(&my_proxy, .{
        .host = "127.0.0.1",
        .port = 8080,
    });
    proxy_app.renderMetrics = MyProxy.renderMetrics;
    proxy_app.renderAdmin = MyProxy.renderAdmin;
    proxy_app.onUpstreamConnect = struct {
        fn cb(p: *MyProxy) void {
            p.state.metrics.incUpstreamActive();
        }
    }.cb;
    proxy_app.onUpstreamDisconnect = struct {
        fn cb(p: *MyProxy) void {
            p.state.metrics.decUpstreamActive();
        }
    }.cb;
    proxy_app.onUpstreamError = struct {
        fn cb(p: *MyProxy) void {
            p.state.metrics.incUpstreamErrors();
        }
    }.cb;
    proxy_app.upstreamBytes = &state.metrics.bytes_upstream;
    proxy_app.downstreamBytes = &state.metrics.bytes_downstream;
    proxy_app.upstream_pool = &state.upstream_pool;
    proxy_app.cacheLookup = MyProxy.cacheLookup;
    proxy_app.cachePut = MyProxy.cachePut;

    var svc = Svc.init("zigora_proxy", proxy_app);
    svc.setShutdown(shutdown, &server);
    svc.setRuntime(&runtime);
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
    try svc.addTcp(allocator, "127.0.0.1:8080");
    defer svc.listeners.deinit(allocator);

    _ = try server.addService(&svc);

    log.info("zigora: listening on 127.0.0.1:8080 with {d} backends", .{backends.items.len});

    try server.runForever(runtime.acceptIo());
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
    parseArgs(&.{"zigora"}, &cfg, alc);
    try std.testing.expectEqual(@as(usize, 0), cfg.addrs.items.len);
}

test "AppState is a struct" {
    try std.testing.expect(@sizeOf(AppState) > 0);
}
