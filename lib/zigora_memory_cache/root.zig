//! Port of pingora-memory-cache: TinyUFO-backed in-memory cache with TTL
//! and explicit cache-status reporting. See V0.2_ROADMAP.md phase 2.7.
//!
//! Wraps `zigora_tinyufo.TinyUfo` with a `Node<T>` carrying an optional
//! expiry timestamp. Lazy expiration on `get` (no background sweep — matches
//! pingora's design). Weight is always 1 per entry.

const std = @import("std");
const tinyufo = @import("zigora-tinyufo");
const zgmemcache = @This();

/// Result of a `get`/`getStale` call.
pub const CacheStatus = union(enum) {
    /// Key found and fresh.
    hit,
    /// Key not found.
    miss,
    /// Key found but past expiry (only `get` returns this; `getStale` returns
    /// the value under `stale` instead).
    expired,
    /// Key found after blocking on a lock (v0.2 no lock yet; same as `hit`).
    lock_hit,
    /// Key found but expired; value returned anyway. Nanoseconds since expiry.
    stale: u64,

    pub fn asStr(self: CacheStatus) []const u8 {
        return switch (self) {
            .hit => "hit",
            .miss => "miss",
            .expired => "expired",
            .lock_hit => "lock_hit",
            .stale => "stale",
        };
    }

    pub fn isHit(self: CacheStatus) bool {
        return switch (self) {
            .hit, .lock_hit, .stale => true,
            .miss, .expired => false,
        };
    }
};

fn Node(comptime T: type) type {
    return struct {
        value: T,
        /// Monotonic timestamp (ns since process start) at which the entry
        /// expires. `null` = never expires.
        expire_on: ?i128,
    };
}

pub fn MemoryCache(comptime T: type) type {
    return struct {
        const Self = @This();
        const N = Node(T);

        store: tinyufo.TinyUfo(N),
        hasher_seed: u64,

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            return .{
                .store = try tinyufo.TinyUfo(N).init(allocator, size, size),
                .hasher_seed = std.crypto.random.int(u64),
            };
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
        }

        fn hashKey(self: *const Self, key: []const u8) u64 {
            var h = std.hash.Wyhash.init(self.hasher_seed);
            h.update(key);
            return h.final();
        }

        /// Look up a key. Returns the value (if any) and a status.
        pub fn get(self: *Self, key: []const u8) struct { value: ?T, status: CacheStatus } {
            const k = self.hashKey(key);
            const node = self.store.get(k) orelse
                return .{ .value = null, .status = .miss };

            if (node.expire_on) |exp| {
                const now = std.time.nanoTimestamp();
                if (now >= exp) {
                    return .{ .value = null, .status = .expired };
                }
            }
            return .{ .value = node.value, .status = .hit };
        }

        /// Like `get` but returns the value even when expired (status `stale`
        /// carries the ns-since-expiry).
        pub fn getStale(self: *Self, key: []const u8) struct { value: ?T, status: CacheStatus } {
            const k = self.hashKey(key);
            const node = self.store.get(k) orelse
                return .{ .value = null, .status = .miss };

            if (node.expire_on) |exp| {
                const now = std.time.nanoTimestamp();
                if (now >= exp) {
                    return .{
                        .value = node.value,
                        .status = .{ .stale = @intCast(now - exp) },
                    };
                }
            }
            return .{ .value = node.value, .status = .hit };
        }

        /// Insert with optional TTL (nanoseconds). Zero TTL → not inserted.
        pub fn put(self: *Self, key: []const u8, value: T, ttl_ns: ?u64) !void {
            if (ttl_ns) |t| if (t == 0) return;
            const k = self.hashKey(key);
            const expire = if (ttl_ns) |t| std.time.nanoTimestamp() + @as(i128, t) else null;
            const ev = try self.store.put(k, .{ .value = value, .expire_on = expire }, 1);
            // `ev` is owned by caller; evicted entries are dropped here.
            // ponytail: evicted nodes just drop. Real cache layer will want
            // to call back into an eviction manager (v0.2 phase 2.9).
            if (ev.len > 0) self.store.allocator.free(ev);
        }

        /// `forcePut` — always admit, skipping TinyLFU check.
        pub fn forcePut(self: *Self, key: []const u8, value: T, ttl_ns: ?u64) !void {
            if (ttl_ns) |t| if (t == 0) return;
            const k = self.hashKey(key);
            const expire = if (ttl_ns) |t| std.time.nanoTimestamp() + @as(i128, t) else null;
            const ev = try self.store.forcePut(k, .{ .value = value, .expire_on = expire }, 1);
            if (ev.len > 0) self.store.allocator.free(ev);
        }

        /// Remove a key.
        pub fn remove(self: *Self, key: []const u8) ?T {
            const k = self.hashKey(key);
            const n = self.store.remove(k) orelse return null;
            return n.value;
        }
    };
}

// ===== Tests =====

test "MemoryCache hit and miss" {
    var alc = std.testing.allocator;
    var c = try MemoryCache(u32).init(alc, 16);
    defer c.deinit();
    try c.put("hello", 42, null);
    const got = c.get("hello");
    try std.testing.expectEqual(@as(?u32, 42), got.value);
    try std.testing.expectEqual(CacheStatus.hit, got.status);
    const miss = c.get("missing");
    try std.testing.expectEqual(@as(?u32, null), miss.value);
    try std.testing.expectEqual(CacheStatus.miss, miss.status);
}

test "MemoryCache TTL expires" {
    var alc = std.testing.allocator;
    var c = try MemoryCache(u32).init(alc, 16);
    defer c.deinit();
    try c.put("k", 1, 5 * std.time.ns_per_ms); // 5ms TTL
    const fresh = c.get("k");
    try std.testing.expectEqual(@as(?u32, 1), fresh.value);
    try std.testing.expectEqual(CacheStatus.hit, fresh.status);
    std.time.sleep(10 * std.time.ns_per_ms);
    const ex = c.get("k");
    try std.testing.expectEqual(@as(?u32, null), ex.value);
    try std.testing.expectEqual(CacheStatus.expired, ex.status);
}

test "MemoryCache getStale returns value with stale duration" {
    var alc = std.testing.allocator;
    var c = try MemoryCache(u32).init(alc, 16);
    defer c.deinit();
    try c.put("k", 7, 5 * std.time.ns_per_ms);
    std.time.sleep(10 * std.time.ns_per_ms);
    const g = c.getStale("k");
    try std.testing.expectEqual(@as(?u32, 7), g.value);
    try std.testing.expectEqual(@as(CacheStatus, .stale), g.status);
    if (g.status == .stale) |d| {
        try std.testing.expect(d > 0);
    }
}

test "MemoryCache zero TTL is not inserted" {
    var alc = std.testing.allocator;
    var c = try MemoryCache(u32).init(alc, 16);
    defer c.deinit();
    try c.put("k", 1, 0);
    const g = c.get("k");
    try std.testing.expectEqual(CacheStatus.miss, g.status);
}

test "MemoryCache remove" {
    var alc = std.testing.allocator;
    var c = try MemoryCache(u32).init(alc, 16);
    defer c.deinit();
    try c.put("x", 99, null);
    try std.testing.expectEqual(@as(?u32, 99), c.remove("x"));
    try std.testing.expectEqual(CacheStatus.miss, c.get("x").status);
    try std.testing.expectEqual(@as(?u32, null), c.remove("x"));
}

test "CacheStatus.asStr / isHit" {
    try std.testing.expectEqualStrings("hit", CacheStatus.hit.asStr());
    try std.testing.expectEqualStrings("miss", CacheStatus.miss.asStr());
    try std.testing.expect(CacheStatus.hit.isHit());
    try std.testing.expect((@as(CacheStatus, .{ .stale = 100 })).isHit());
    try std.testing.expect(!CacheStatus.miss.isHit());
}
