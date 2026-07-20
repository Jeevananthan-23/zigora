//! Zigora binary entrypoint. Mirrors a Pingora user's `main.rs`:
//! allocate Server, configure a ProxyHttp-style app, run_forever.

const std = @import("std");
const Io = std.Io;
const core = @import("zigora-core");
const proxy = @import("zigora-proxy");

const BackendCfg = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,
};

/// Minimal ProxyHttp implementation for v0.1: a single fixed upstream.
const MyProxy = struct {
    pub const CTX = struct {};

    pub fn new_ctx(_: *MyProxy) CTX {
        return .{};
    }

    pub fn upstream_peer(_: *MyProxy) proxy.HttpPeer {
        return .{ .host = globals.backend.host, .port = globals.backend.port };
    }
};

// ponytail: globals are the simplest way to pass CLI args into ProxyHttp impls
// without threading them through every callback. With v0.1 having one impl
// and one peer, this is fine. A real context-attachment mechanism lands when
// the ProxyHttp trait grows stateful callbacks.
var globals: struct { backend: BackendCfg = .{} } = .{};

pub fn main(init: std.process.Init) !void {
    const process_io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    parseArgs(args, &globals.backend);

    std.log.info("zigora: listening on 127.0.0.1:8080, upstream {s}:{d}", .{
        globals.backend.host, globals.backend.port,
    });

    var server = core.Server.new(arena, .{});

    var my_proxy = MyProxy{};
    const Svc = core.Service(proxy.HttpProxy(MyProxy));
    var svc = Svc.init("zigora_proxy", proxy.HttpProxy(MyProxy).init(&my_proxy, .{ .host = globals.backend.host, .port = globals.backend.port }));
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