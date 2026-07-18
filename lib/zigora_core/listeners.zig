//! Pingora `Listeners` port. v0.1: TCP only. TLS and UDS are v0.2.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
// v0.2 surfaces structured errors via `zigora-error`; unused in v0.1.

pub const zgcore_listeners = @This();

pub const ServerAddress = union(enum) {
    Tcp: struct { host: []const u8, port: u16 },
    // v0.2: Uds, Tls
};

/// `Listeners` holds the configured endpoints. `build()` returns live
/// `net.Server` instances. Pingora owns FD transfer logic here — we skip
/// that for v0.1 since `std.Io` listeners are bound synchronously.
pub const Listeners = struct {
    addrs: std.ArrayList(ServerAddress),

    pub fn init() Listeners {
        return .{ .addrs = .empty };
    }

    pub fn deinit(l: *Listeners, allocator: std.mem.Allocator) void {
        l.addrs.deinit(allocator);
    }

    pub fn addTcp(l: *Listeners, allocator: std.mem.Allocator, addr: []const u8) !void {
        // ponytail: parse "host:port" inline. A real splitUri lives in std;
        // `std.net.splitUriPort` doesn't exist in 0.16 stdlib, so hand-roll.
        const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
        const host = addr[0..colon];
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return error.InvalidAddress;
        try l.addrs.append(allocator, .{ .Tcp = .{ .host = host, .port = port } });
    }

    /// Returns slice of `net.Server` capable of `accept(io)`. Caller owns
    /// each listener's lifetime. v0.1 always returns one listener exactly
    /// — multiple endpoints is a v0.2 convenience.
    pub fn build(l: *const Listeners, io: Io, allocator: std.mem.Allocator) ![]net.Server {
        if (l.addrs.items.len == 0) return error.NoEndpoints;
        var out = try allocator.alloc(net.Server, l.addrs.items.len);
        var idx: usize = 0;
        for (l.addrs.items) |a| switch (a) {
            .Tcp => |t| {
                const ip4 = net.Ip4Address.parse(t.host, t.port) catch return error.InvalidAddress;
                const addr: net.IpAddress = .{ .ip4 = ip4 };
                out[idx] = try net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
                idx += 1;
            },
        };
        return out[0..idx];
    }
};

test "Listeners.addTcp parses host:port" {
    const alc = std.testing.allocator;
    var l = Listeners.init();
    defer l.deinit(alc);
    try l.addTcp(alc, "127.0.0.1:8080");
    try std.testing.expectEqual(@as(usize, 1), l.addrs.items.len);
    try std.testing.expectEqualStrings("127.0.0.1", l.addrs.items.items[0].Tcp.host);
    try std.testing.expectEqual(@as(u16, 8080), l.addrs.items.items[0].Tcp.port);
}

test "Listeners.addTcp rejects malformed" {
    const alc = std.testing.allocator;
    var l = Listeners.init();
    defer l.deinit(alc);
    try std.testing.expectError(error.InvalidAddress, l.addTcp(alc, "no-colon"));
    try std.testing.expectError(error.InvalidAddress, l.addTcp(alc, "127.0.0.1:notnum"));
    try std.testing.expectEqual(@as(usize, 0), l.addrs.items.len);
}

test "Listeners.build with no endpoints errors" {
    const alc = std.testing.allocator;
    var l = Listeners.init();
    defer l.deinit(alc);
    // build requires an Io that we don't have in unit tests, so just check
    // the empty-list short-circuit returns NoEndpoints
    try std.testing.expectError(error.NoEndpoints, l.build(undefined, alc));
}