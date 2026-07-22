//! Port of pingora-load-balancing: backend selection algorithms for v0.2.
//! See V0.2_ROADMAP.md phase 2.8.
//!
//! Lazy port: `Backend`, `LoadBalancer(S)` with 4 selectors (RoundRobin,
//! Random, FNVHash, Consistent via zigora-ketama). Health check machinery
//! is stubbed out — `ready(b)` returns `true` until v0.2 phase 4 wires it.
//!
//! `BackendSelection` is a comptime interface: any struct with
//! `build(backends, allocator) → Self!` and `next(key) → usize` works.

const std = @import("std");
const log = std.log.scoped(.lb);
const ketama = @import("zigora-ketama");
const zglb = @This();

/// A backend server.
pub const Backend = struct {
    addr: std.Io.net.IpAddress,
    weight: usize = 1,

    pub fn new(addr_str: []const u8) !Backend {
        const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse
            return error.InvalidAddr;
        const host = addr_str[0..colon];
        const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch
            return error.InvalidAddr;
        const addr = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidAddr;
        return .{ .addr = addr };
    }

    pub fn newWithWeight(addr_str: []const u8, weight: usize) !Backend {
        var b = try new(addr_str);
        b.weight = weight;
        return b;
    }

    pub fn hashKey(self: Backend) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.addr));
        hasher.update(std.mem.asBytes(&self.weight));
        return hasher.final();
    }

    pub fn eql(a: Backend, b: Backend) bool {
        return a.weight == b.weight and std.Io.net.IpAddress.eql(&a.addr, &b.addr);
    }
};

// ---- BackendSelection comptime interface ----
// A type implements it via:
//   pub fn build(backends: []const Backend, allocator: Allocator) !Self;
//   pub fn next(self: *Self, key: []const u8) usize;  // returns backend index

/// Round-robin: atomic counter modulo backends.len. Weight is ignored.
pub const RoundRobin = struct {
    indices: []const usize, // flattened by weight, snapshot of input
    ctr: std.atomic.Value(usize) = .{ .raw = 0 },

    pub fn build(backends: []const Backend, allocator: std.mem.Allocator) !RoundRobin {
        // ponytail: keep weight handling simple — duplicate each index by its weight
        var total: usize = 0;
        for (backends) |b| total += @max(b.weight, 1);
        var idx = try allocator.alloc(usize, total);
        var w: usize = 0;
        for (backends, 0..) |b, i| {
            for (0..@max(b.weight, 1)) |_| {
                idx[w] = i;
                w += 1;
            }
        }
        return .{ .indices = idx };
    }

    pub fn deinit(self: *RoundRobin, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }

    pub fn next(self: *RoundRobin, key: []const u8) usize {
        _ = key;
        const i = self.ctr.fetchAdd(1, .monotonic);
        return self.indices[i % self.indices.len];
    }
};

/// Random selection.
pub const Random = struct {
    indices: []const usize,
    seed: u64,

    pub fn build(backends: []const Backend, allocator: std.mem.Allocator) !Random {
        var total: usize = 0;
        for (backends) |b| total += @max(b.weight, 1);
        var idx = try allocator.alloc(usize, total);
        var w: usize = 0;
        for (backends, 0..) |b, i| {
            for (0..@max(b.weight, 1)) |_| {
                idx[w] = i;
                w += 1;
            }
        }
        return .{ .indices = idx, .seed = 0 }; // ponytail: deterministic seed
    }

    pub fn deinit(self: *Random, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }

    pub fn next(self: *Random, key: []const u8) usize {
        // lazy reseed + key mixing
        var h = std.hash.Wyhash.init(self.seed);
        h.update(key);
        const r = h.final();
        return self.indices[r % self.indices.len];
    }
};

/// FNV hash selection.
pub const FNVHash = struct {
    indices: []const usize,

    pub fn build(backends: []const Backend, allocator: std.mem.Allocator) !FNVHash {
        var total: usize = 0;
        for (backends) |b| total += @max(b.weight, 1);
        var idx = try allocator.alloc(usize, total);
        var w: usize = 0;
        for (backends, 0..) |b, i| {
            for (0..@max(b.weight, 1)) |_| {
                idx[w] = i;
                w += 1;
            }
        }
        return .{ .indices = idx };
    }

    pub fn deinit(self: *FNVHash, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }

    pub fn next(self: *FNVHash, key: []const u8) usize {
        var hasher = std.hash.Fnv1a_64{};
        hasher.update(key);
        const r = hasher.final();
        return self.indices[r % self.indices.len];
    }
};

/// Consistent hashing using `zigora-ketama`.
pub const Consistent = struct {
    continuum: ketama.Continuum,
    // Sorted Backend snapshot
    backends: []const Backend,

    pub fn build(backends: []const Backend, allocator: std.mem.Allocator) !Consistent {
        // Sort by addr to ensure Backends order is stable
        const sorted = try allocator.alloc(Backend, backends.len);
        defer allocator.free(sorted);
        @memcpy(sorted, backends);
        std.mem.sort(Backend, sorted, {}, backendLessThan);
        // Build buckets, deduping by address
        var unique = std.ArrayList(Backend).empty;
        defer unique.deinit(allocator);
        for (sorted) |b| {
            if (unique.items.len == 0 or !std.Io.net.IpAddress.eql(&unique.items[unique.items.len - 1].addr, &b.addr)) {
                try unique.append(allocator, b);
            }
        }
        var buckets = try allocator.alloc(ketama.Bucket, unique.items.len);
        defer allocator.free(buckets);
        for (unique.items, 0..) |b, i| {
            buckets[i] = ketama.Bucket.new(b.addr, @intCast(@max(b.weight, 1)));
        }
        const cont = try ketama.Continuum.init(allocator, buckets);
        return .{ .continuum = cont, .backends = try unique.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Consistent, allocator: std.mem.Allocator) void {
        self.continuum.deinit();
        allocator.free(self.backends);
    }

    pub fn next(self: *Consistent, key: []const u8) ?usize {
        // Continuum.node already wraps the addr — we need an index into `backends`.
        const addr = self.continuum.node(key) orelse return null;
        for (self.backends, 0..) |b, i| {
            if (std.Io.net.IpAddress.eql(&b.addr, &addr)) return i;
        }
        return null;
    }
};

fn backendLessThan(_: void, a: Backend, b: Backend) bool {
    // lexicographic on ip bytes then port — wyhash would suffice but
    // std.net.Address has no builtin compare, just by port is fine for sorting.
    return std.Io.net.IpAddress.getPort(a.addr) < std.Io.net.IpAddress.getPort(b.addr);
}

/// `LoadBalancer<S>` — wraps selection algorithm + backend snapshot.
pub fn LoadBalancer(comptime S: type) type {
    return struct {
        const Self = @This();

        backends: []Backend, // caller-owned snapshot
        selector: S,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, backends: []Backend) !Self {
            // snapshot for stability
            const snap = try allocator.alloc(Backend, backends.len);
            @memcpy(snap, backends);
            return .{
                .backends = snap,
                .selector = try S.build(snap, allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.backends);
            if (@hasDecl(S, "deinit")) self.selector.deinit(self.allocator);
        }

        /// Select a backend using the algorithm. `key` is used for hashing
        /// selectors (Random/FNVHash/Consistent) and ignored for RoundRobin.
        pub fn select(self: *Self, key: []const u8) ?Backend {
            return self.selectWith(key, struct {
                fn ok(_: Backend, _: bool) bool {
                    return true;
                }
            }.ok);
        }

        /// `select` with an accept predicate. `(backend, ready) → bool`.
        /// ponytail: ready is always `true` until health check lands.
        pub fn selectWith(self: *Self, key: []const u8, accept: anytype) ?Backend {
            // Consistent.next returns ?usize; algorithms that return usize
            // wrap with modulo internally. Use comptime to unify the shape.
            const T_result = @typeInfo(@TypeOf(S.next)).@"fn".return_type.?;
            const idx = if (T_result == usize)
                self.selector.next(key)
            else
                (self.selector.next(key) orelse return null);
            const backend = self.backends[idx];
            if (accept(backend, true)) return backend;
            return null;
        }
    };
}

// ===== Tests =====

test "Backend.new parses host:port" {
    const b = try Backend.new("127.0.0.1:9000");
    try std.testing.expectEqual(@as(u16, 9000), std.Io.net.IpAddress.getPort(b.addr));
}

test "Backend weight defaults to 1" {
    const b = try Backend.new("127.0.0.1:9000");
    try std.testing.expectEqual(@as(usize, 1), b.weight);
}

test "RoundRobin distributes evenly" {
    const alc = std.testing.allocator;
    var backends = [_]Backend{
        try Backend.new("127.0.0.1:9000"),
        try Backend.new("127.0.0.1:9001"),
    };
    var lb = try LoadBalancer(RoundRobin).init(alc, &backends);
    defer lb.deinit();
    const a = lb.select("k").?;
    const b = lb.select("k").?;
    const c = lb.select("k").?;
    try std.testing.expect(std.Io.net.IpAddress.eql(&a.addr, &backends[0].addr));
    try std.testing.expect(std.Io.net.IpAddress.eql(&b.addr, &backends[1].addr));
    try std.testing.expect(std.Io.net.IpAddress.eql(&c.addr, &backends[0].addr));
}

test "RoundRobin respects weight" {
    const alc = std.testing.allocator;
    var backends = [_]Backend{
        try Backend.newWithWeight("127.0.0.1:9000", 3),
        try Backend.newWithWeight("127.0.0.1:9001", 1),
    };
    var lb = try LoadBalancer(RoundRobin).init(alc, &backends);
    defer lb.deinit();
    var count0: usize = 0;
    var count1: usize = 0;
    for (0..40) |_| {
        const b = lb.select("k").?;
        if (std.Io.net.IpAddress.getPort(b.addr) == 9000) count0 += 1 else count1 += 1;
    }
    try std.testing.expectEqual(@as(usize, 30), count0);
    try std.testing.expectEqual(@as(usize, 10), count1);
}

test "FNVHash deterministic for same key" {
    const alc = std.testing.allocator;
    var backends = [_]Backend{
        try Backend.new("127.0.0.1:9000"),
        try Backend.new("127.0.0.1:9001"),
        try Backend.new("127.0.0.1:9002"),
    };
    var lb = try LoadBalancer(FNVHash).init(alc, &backends);
    defer lb.deinit();
    const a = lb.select("testkey").?;
    const b = lb.select("testkey").?;
    try std.testing.expect(std.Io.net.IpAddress.eql(&a.addr, &b.addr));
}

test "Consistent distributes and is stable" {
    const alc = std.testing.allocator;
    var backends = [_]Backend{
        try Backend.new("127.0.0.1:9000"),
        try Backend.new("127.0.0.1:9001"),
        try Backend.new("127.0.0.1:9002"),
    };
    var lb = try LoadBalancer(Consistent).init(alc, &backends);
    defer lb.deinit();
    const a = lb.select("hello").?;
    const b = lb.select("hello").?;
    try std.testing.expect(std.Io.net.IpAddress.eql(&a.addr, &b.addr));
    var seen = [_]bool{ false, false, false };
    for (0..300) |i| {
        var k: [4]u8 = undefined;
        std.mem.writeInt(u32, &k, i, .little);
        const b_ = lb.select(&k) orelse continue;
        const p = std.Io.net.IpAddress.getPort(b_.addr);
        const idx: usize = p - 9000;
        if (idx < seen.len) seen[idx] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}
