//! Port of tinyufo: TinyLFU admission + S3-FIFO eviction in-memory cache.
//! See V0.2_ROADMAP.md phase 1.5.
//!
//! Lazy port: ONE mutex around the whole structure (Pingora's crate is
//! lock-free). Plain `std.ArrayList` FIFOs instead of `SegQueue`. Same
//! algorithm — S3-FIFO small/main split + TinyLFU admission — just
//! serialized. v0.2 use case is the HTTP cache, which is already behind a
//! per-key lock, so contention on this mutex is bounded. Upgrade to lock-free
//! (rust `SegQueue` equivalent → MIT-licensed `mpsc` channels) when
//! benchmarks show this is the hot lock.
//!
//! API mirrors pingora's `TinyUfo`: `get`, `put`, `force_put`, `remove`.
//! `put` returns a list of evicted KV pairs. Keys are u64 (caller-hashed).

const std = @import("std");
const zgtinyufo = @This();

pub const Weight = u16;
pub const Key = u64;
const USES_CAP: u8 = 3;
const SMALL_PCT: f32 = 0.1;

/// Evicted entry. `key` is the (hashed) cache key.
pub fn KV(comptime T: type) type {
    return struct {
        key: Key,
        data: T,
        weight: Weight,
    };
}

const Location = enum(u1) { small = 0, main = 1 };

fn Bucket(comptime T: type) type {
    return struct {
        uses: u8 = 0,
        queue: Location = .small,
        weight: Weight,
        data: T,
    };
}

/// S3-FIFO + TinyLFU cache.
pub fn TinyUfo(comptime T: type) type {
    return struct {
        const Self = @This();

        total_weight_limit: usize,
        mu: std.Thread.Mutex = .{},

        // FIFO queues (head = oldest)
        small_keys: std.ArrayList(Key),
        small_weight: usize = 0,
        main_keys: std.ArrayList(Key),
        main_weight: usize = 0,

        // The actual key→bucket map
        buckets: std.AutoArrayHashMap(Key, Bucket(T)),

        // TinyLFU estimator: a tiny Count-Min sketch (1 row × N slots)
        lfu_slots: []std.atomic.Value(u32),
        lfu_seeds: [4]u64,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, total_weight_limit: usize, estimated_size: usize) !Self {
            const slot_count = @max(estimated_size, 64);
            const slots = try allocator.alloc(std.atomic.Value(u32), slot_count);
            @memset(slots, std.atomic.Value(u32).init(0));
            var seeds: [4]u64 = undefined;
            for (&seeds) |*s| s.* = std.crypto.random.int(u64);
            return .{
                .total_weight_limit = total_weight_limit,
                .small_keys = .empty,
                .main_keys = .empty,
                .buckets = std.AutoArrayHashMap(Key, Bucket(T)).init(allocator),
                .lfu_slots = slots,
                .lfu_seeds = seeds,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.lfu_slots);
            self.small_keys.deinit(self.allocator);
            self.main_keys.deinit(self.allocator);
            self.buckets.deinit();
        }

        // ---- TinyLFU frequency estimator (1-row CM sketch, min of 4 hashes) ----

        fn lfuIncr(self: *Self, key: Key) u32 {
            var min: u32 = std.math.maxInt(u32);
            for (self.lfu_seeds, 0..) |seed, i| {
                var h = std.hash.Wyhash.init(seed);
                h.update(std.mem.asBytes(&key));
                const idx = h.final() % self.lfu_slots.len;
                const prev = self.lfu_slots[idx].fetchAdd(1, .monotonic);
                if (prev + 1 < min) min = prev + 1;
                _ = i;
            }
            return if (min == std.math.maxInt(u32)) 0 else min;
        }

        fn lfuGet(self: *Self, key: Key) u32 {
            var min: u32 = std.math.maxInt(u32);
            for (self.lfu_seeds) |seed| {
                var h = std.hash.Wyhash.init(seed);
                h.update(std.mem.asBytes(&key));
                const idx = h.final() % self.lfu_slots.len;
                const v = self.lfu_slots[idx].load(.monotonic);
                if (v < min) min = v;
            }
            return if (min == std.math.maxInt(u32)) 0 else min;
        }

        // ---- cache ops (must hold mu) ----

        /// Read `key` from the cache; bumps uses for S3-FIFO.
        pub fn get(self: *Self, key: Key) ?T {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.buckets.getPtr(key)) |b| {
                if (b.uses < USES_CAP) b.uses += 1;
                return b.data;
            }
            return null;
        }

        /// Put `key` with `data` and `weight`. TinyLFU admission may reject
        /// the insert and return the new item as evicted. Returns a list of
        /// evicted `KV(T)` owned by the caller (free with `allocator`).
        pub fn put(self: *Self, key: Key, data: T, weight: Weight) ![]KV(T) {
            return self.admitInternal(key, data, weight, false);
        }

        /// Like `put` but skips TinyLFU admission — the item is always admitted.
        pub fn forcePut(self: *Self, key: Key, data: T, weight: Weight) ![]KV(T) {
            return self.admitInternal(key, data, weight, true);
        }

        /// Remove `key`. Returns the removed data if present.
        pub fn remove(self: *Self, key: Key) ?T {
            self.mu.lock();
            defer self.mu.unlock();
            const b = self.buckets.fetchSwapRemove(key) orelse return null;
            switch (b.value.queue) {
                .small => self.small_weight -= b.value.weight,
                .main => self.main_weight -= b.value.weight,
            }
            // Order list is not kept perfectly in sync; we tolerate stale
            // entries — they get filtered at evict-time via lookup miss.
            return b.value.data;
        }

        fn admitInternal(self: *Self, key: Key, data: T, weight: Weight, force: bool) ![]KV(T) {
            self.mu.lock();
            defer self.mu.unlock();

            const new_freq = self.lfuIncr(key);
            std.debug.assert(weight > 0);

            // existing key: update data/weight + bump uses, queue maybe-moves
            if (self.buckets.getPtr(key)) |b| {
                const old_w = b.weight;
                const uses = if (b.uses < USES_CAP) blk: {
                    b.uses += 1;
                    break :blk b.uses;
                } else b.uses;
                _ = uses;
                const q = b.queue;
                if (old_w != weight) {
                    switch (q) {
                        .small => self.small_weight = self.small_weight - old_w + weight,
                        .main => self.main_weight = self.main_weight - old_w + weight,
                    }
                    b.weight = weight;
                }
                b.data = data;
                // Evict to limit ignoring this key's own weight change.
                return self.evictToLimit(0);
            }

            // Need to make room. Evict first.
            var evicted = try self.evictToLimit(weight);
            // TinyLFU admission: if exactly one item was evicted, compare
            // prev_freq vs new_freq. More popular one stays.
            if (!force and evicted.len == 1) {
                const ev_freq = self.lfuGet(evicted[0].key);
                if (ev_freq > new_freq) {
                    // reject new item: put evicted one back, new item goes into evicted
                    var returned = try self.allocator.alloc(KV(T), 1);
                    returned[0] = .{ .key = key, .data = data, .weight = weight };
                    // re-insert evicted item
                    self.buckets.put(evicted[0].key, .{
                        .uses = 0,
                        .queue = .small,
                        .weight = evicted[0].weight,
                        .data = evicted[0].data,
                    }) catch {};
                    try self.small_keys.append(self.allocator, evicted[0].key);
                    self.small_weight += evicted[0].weight;
                    self.allocator.free(evicted);
                    return returned;
                }
            }

            self.buckets.put(key, .{
                .uses = 0,
                .queue = .small,
                .weight = weight,
                .data = data,
            }) catch {};
            try self.small_keys.append(self.allocator, key);
            self.small_weight += weight;
            return evicted;
        }

        fn evictToLimit(self: *Self, extra_weight: Weight) ![]KV(T) {
            var evicted: std.ArrayList(KV(T)) = .empty;
            while (self.total_weight_limit < self.small_weight + self.main_weight + @as(usize, extra_weight)) {
                if (try self.evictOne()) |e| {
                    try evicted.append(self.allocator, e);
                } else break;
            }
            return evicted.toOwnedSlice(self.allocator);
        }

        fn smallWeightLimit(self: *Self) usize {
            return @intFromFloat(@floor(@as(f32, @floatFromInt(self.total_weight_limit)) * SMALL_PCT)) + 1;
        }

        fn evictOne(self: *Self) !?KV(T) {
            if (self.smallWeightLimit() <= self.small_weight) {
                if (try self.evictOneFromSmall()) |e| return e;
            }
            return self.evictOneFromMain();
        }

        fn evictOneFromSmall(self: *Self) !?KV(T) {
            while (self.small_keys.items.len > 0) {
                const k = self.small_keys.orderedRemove(0);
                const b_ptr = self.buckets.getPtr(k) orelse continue; // stale entry, drop
                if (b_ptr.queue != .small) {
                    // already moved to main by a concurrent path (shouldn't happen with mutex)
                    continue;
                }
                self.small_weight -= b_ptr.weight;
                if (b_ptr.uses > 1) {
                    b_ptr.queue = .main;
                    try self.main_keys.append(self.allocator, k);
                    self.main_weight += b_ptr.weight;
                    continue;
                }
                const weight = b_ptr.weight;
                const data = b_ptr.data;
                _ = self.buckets.swapRemove(k);
                return .{ .key = k, .data = data, .weight = weight };
            }
            return null;
        }

        fn evictOneFromMain(self: *Self) !?KV(T) {
            while (self.main_keys.items.len > 0) {
                const k = self.main_keys.orderedRemove(0);
                const b_ptr = self.buckets.getPtr(k) orelse continue;
                if (b_ptr.queue != .main) continue;
                if (b_ptr.uses > 0) {
                    b_ptr.uses -= 1;
                    try self.main_keys.append(self.allocator, k); // back to tail
                    continue;
                }
                self.main_weight -= b_ptr.weight;
                const weight = b_ptr.weight;
                const data = b_ptr.data;
                _ = self.buckets.swapRemove(k);
                return .{ .key = k, .data = data, .weight = weight };
            }
            return null;
        }

        // ---- introspection (test helpers) ----

        pub fn peekQueue(self: *Self, key: Key) ?Location {
            self.mu.lock();
            defer self.mu.unlock();
            return if (self.buckets.get(key)) |b| b.queue else null;
        }

        pub fn totalWeight(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.small_weight + self.main_weight;
        }
    };
}

// ===== Tests =====

test "TinyUfo basic get/put" {
    var alc = std.testing.allocator;
    var c = try TinyUfo(u32).init(alc, 100, 64);
    defer c.deinit();
    var ev = try c.put(1, 11, 1);
    alc.free(ev);
    try std.testing.expectEqual(@as(?u32, 11), c.get(1));
    try std.testing.expectEqual(@as(?u32, null), c.get(2));
}

test "TinyUfo evicts when full" {
    var alc = std.testing.allocator;
    var c = try TinyUfo(u32).init(alc, 5, 8);
    defer c.deinit();
    var e1 = try c.put(1, 1, 1); if (e1.len > 0) alc.free(e1);
    var e2 = try c.put(2, 2, 2); if (e2.len > 0) alc.free(e2);
    var e3 = try c.put(3, 3, 2); if (e3.len > 0) alc.free(e3);
    // total weight 5, full
    var e4 = try c.put(4, 4, 3);
    defer alc.free(e4);
    try std.testing.expect(e4.len >= 1);
    try std.testing.expect(c.totalWeight() <= 5);
}

test "TinyUfo promotes from small to main on second use" {
    var alc = std.testing.allocator;
    var c = try TinyUfo(u32).init(alc, 5, 8);
    defer c.deinit();
    var e1 = try c.put(1, 1, 1); if (e1.len > 0) alc.free(e1);
    var e2 = try c.put(2, 2, 2); if (e2.len > 0) alc.free(e2);
    var e3 = try c.put(3, 3, 2); if (e3.len > 0) alc.free(e3);
    _ = c.get(1);
    _ = c.get(1); // bump uses to 2
    try std.testing.expectEqual(Location.small, c.peekQueue(1).?);
    var e4 = try c.put(4, 4, 2); // triggers eviction from small
    defer alc.free(e4);
    // 1 should be promoted to main to escape eviction
    try std.testing.expectEqual(Location.main, c.peekQueue(1).?);
}

test "TinyUfo remove" {
    var alc = std.testing.allocator;
    var c = try TinyUfo(u32).init(alc, 100, 64);
    defer c.deinit();
    var e1 = try c.put(7, 77, 1); if (e1.len > 0) alc.free(e1);
    try std.testing.expectEqual(@as(?u32, 77), c.remove(7));
    try std.testing.expectEqual(@as(?u32, null), c.get(7));
}

test "TinyUfo forcePut always admits" {
    var alc = std.testing.allocator;
    var c = try TinyUfo(u32).init(alc, 5, 8);
    defer c.deinit();
    var e1 = try c.put(1, 1, 1); if (e1.len > 0) alc.free(e1);
    var e2 = try c.put(1, 1, 1); if (e2.len > 0) alc.free(e2);
    var e3 = try c.put(1, 1, 1); if (e3.len > 0) alc.free(e3); // bump freq of 1
    var ef = try c.forcePut(99, 99, 1); // force admit new key 99
    if (ef.len > 0) alc.free(ef);
    try std.testing.expect(c.get(99) != null);
}
