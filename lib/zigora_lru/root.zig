//! Port of pingora-lru: sharded weighted LRU cache for eviction in the v0.2
//! cache layer. See V0.2_ROADMAP.md phase 1.3.
//!
//! Lazy port: N shards (`comptime`) each guarded by a `std.Thread.Mutex`,
//! backed by `std.AutoArrayHashMap(u64, Node)` + an order list. Items are
//! inserted at head, evicted from tail on weight overflow. No watermarks,
//! no promote-top-n optimization — both easy to add when needed.
//! Memory is `std.heap.PageAllocator`-friendly (no box-per-node, no unsafe).

const std = @import("std");
const zglru = @This();

pub fn Lru(comptime T: type, comptime N: usize) type {
    return struct {
        shards: [N]Shard,
        weight_limit: usize,
        weight: std.atomic.Value(usize) = .{ .raw = 0 },
        len: std.atomic.Value(usize) = .{ .raw = 0 },
        allocator: std.mem.Allocator,

        pub const Shard = struct {
            unit: Unit,
            mu: std.Thread.Mutex = .{},

            pub const Unit = struct {
                lookup: std.AutoArrayHashMap(u64, Node),
                order: std.ArrayList(u64), // head=MRU, tail=LRU
                used_weight: usize = 0,

                pub fn init(allocator: std.mem.Allocator, cap: usize) Unit {
                    var lookup = std.AutoArrayHashMap(u64, Node).init(allocator);
                    lookup.ensureTotalCapacity(cap) catch {};
                    return .{
                        .lookup = lookup,
                        .order = .empty,
                    };
                }

                pub fn deinit(self: *Unit, allocator: std.mem.Allocator) void {
                    self.lookup.deinit();
                    self.order.deinit(allocator);
                }

                /// Promote `key` to MRU. Returns true if key was present.
                pub fn access(self: *Unit, key: u64) bool {
                    if (!self.lookup.contains(key)) return false;
                    self.removeFromOrder(key);
                    self.order.append(self.lookup.allocator, key) catch {};
                    return true;
                }

                /// Insert `key` at MRU. Replaces existing entry's data/weight.
                /// Returns previous weight (0 if new).
                pub fn admit(self: *Unit, key: u64, data: T, weight: usize) usize {
                    const w = @max(weight, 1);
                    if (self.lookup.get(key)) |node| {
                        const old = node.weight;
                        self.lookup.put(key, .{ .data = data, .weight = w }) catch {};
                        self.used_weight = self.used_weight - old + w;
                        return old;
                    }
                    self.lookup.put(key, .{ .data = data, .weight = w }) catch {};
                    self.order.append(self.lookup.allocator, key) catch {};
                    self.used_weight += w;
                    return 0;
                }

                /// Remove LRU item. Returns (T, weight) or null.
                pub fn evict(self: *Unit) ?struct { key: u64, data: T, weight: usize } {
                    if (self.order.items.len == 0) return null;
                    const key = self.order.items[0];
                    const node = self.lookup.fetchSwapRemove(key).?;
                    _ = self.order.orderedRemove(0);
                    self.used_weight -= node.value.weight;
                    return .{ .key = key, .data = node.value.data, .weight = node.value.weight };
                }

                pub fn remove(self: *Unit, key: u64) ?struct { data: T, weight: usize } {
                    const node = self.lookup.fetchSwapRemove(key) orelse return null;
                    self.removeFromOrder(key);
                    self.used_weight -= node.value.weight;
                    return .{ .data = node.value.data, .weight = node.value.weight };
                }

                pub fn peek(self: *const Unit, key: u64) ?T {
                    return if (self.lookup.get(key)) |n| n.data else null;
                }

                pub fn peekWeight(self: *const Unit, key: u64) ?usize {
                    return if (self.lookup.get(key)) |n| n.weight else null;
                }

                pub fn peekLru(self: *const Unit) ?struct { data: T, weight: usize } {
                    if (self.order.items.len == 0) return null;
                    const key = self.order.items[0];
                    const node = self.lookup.get(key).?;
                    return .{ .data = node.data, .weight = node.weight };
                }

                fn removeFromOrder(self: *Unit, key: u64) void {
                    for (self.order.items, 0..) |k, i| {
                        if (k == key) {
                            _ = self.order.orderedRemove(i);
                            return;
                        }
                    }
                }

                pub fn len(self: *const Unit) usize {
                    return self.lookup.count();
                }
            };
        };

        pub const Node = struct {
            data: T,
            weight: usize,
        };

        /// `capacity` is per-shard, total = capacity × N.
        /// `weight_limit` is the global cap that triggers `evictToLimit`.
        pub fn init(allocator: std.mem.Allocator, weight_limit: usize, capacity: usize) !Lru(T, N) {
            var shards: [N]Shard = undefined;
            for (&shards) |*s| s.* = .{ .unit = Shard.Unit.init(allocator, capacity) };
            return .{ .shards = shards, .weight_limit = weight_limit, .allocator = allocator };
        }

        pub fn deinit(self: *Lru(T, N)) void {
            for (&self.shards) |*s| s.unit.deinit(self.allocator);
        }

        /// `key % N` is the shard index — simple, no hash mixing needed
        /// (callers usually pass already-hashed keys).
        fn shardFor(self: *Lru(T, N), key: u64) usize {
            _ = self;
            return @intCast(key % @as(u64, N));
        }

        /// Admit an item to the LRU. Returns the shard index.
        pub fn admit(self: *Lru(T, N), key: u64, data: T, weight: usize) usize {
            const idx = self.shardFor(key);
            const w = @max(weight, 1);
            self.shards[idx].mu.lock();
            defer self.shards[idx].mu.unlock();
            const old = self.shards[idx].unit.admit(key, data, w);
            if (old != w) {
                _ = self.weight.fetchAdd(w, .monotonic);
                if (old > 0) {
                    _ = self.weight.fetchSub(old, .monotonic);
                } else {
                    _ = self.len.fetchAdd(1, .monotonic);
                }
            }
            return idx;
        }

        /// Promote key to MRU. Returns true if key was present.
        pub fn promote(self: *Lru(T, N), key: u64) bool {
            const idx = self.shardFor(key);
            self.shards[idx].mu.lock();
            defer self.shards[idx].mu.unlock();
            return self.shards[idx].unit.access(key);
        }

        /// Remove `key`. Returns (T, weight) if present.
        pub fn remove(self: *Lru(T, N), key: u64) ?struct { data: T, weight: usize } {
            const idx = self.shardFor(key);
            self.shards[idx].mu.lock();
            defer self.shards[idx].mu.unlock();
            const r = self.shards[idx].unit.remove(key) orelse return null;
            _ = self.weight.fetchSub(r.weight, .monotonic);
            _ = self.len.fetchSub(1, .monotonic);
            return r;
        }

        /// Evict one item from the given shard. Ponytail: Pingora evicts
        /// random shards; here the caller picks.
        pub fn evictShard(self: *Lru(T, N), shard: usize) ?struct { data: T, weight: usize } {
            self.shards[shard].mu.lock();
            defer self.shards[shard].mu.unlock();
            const r = self.shards[shard].unit.evict() orelse return null;
            _ = self.weight.fetchSub(r.weight, .monotonic);
            _ = self.len.fetchSub(1, .monotonic);
            return .{ .data = r.data, .weight = r.weight };
        }

        /// Evict (from random shard) until weight ≤ limit (or all shards empty).
        pub fn evictToLimit(self: *Lru(T, N), allocator: std.mem.Allocator) ![]struct { data: T, weight: usize } {
            var out: std.ArrayList(struct { data: T, weight: usize }) = .empty;
            var empty_shards: usize = 0;
            var seed: usize = std.crypto.random.int(usize) % N;
            while (self.weight.fetchLoad(.monotonic) > self.weight_limit and empty_shards < N) {
                if (self.evictShard(seed)) |e| {
                    try out.append(allocator, e);
                } else {
                    empty_shards += 1;
                }
                seed = (seed + 1) % N;
            }
            return out.toOwnedSlice(allocator);
        }

        pub fn peek(self: *Lru(T, N), key: u64) ?T {
            const idx = self.shardFor(key);
            self.shards[idx].mu.lock();
            defer self.shards[idx].mu.unlock();
            return self.shards[idx].unit.peek(key);
        }

        pub fn peekWeight(self: *Lru(T, N), key: u64) ?usize {
            const idx = self.shardFor(key);
            self.shards[idx].mu.lock();
            defer self.shards[idx].mu.unlock();
            return self.shards[idx].unit.peekWeight(key);
        }

        pub fn weight(self: *const Lru(T, N)) usize {
            return self.weight.load(.monotonic);
        }

        pub fn lenFn(self: *const Lru(T, N)) usize {
            return self.len.load(.monotonic);
        }

        pub const shards = N;
    };
}

// ===== Tests =====

test "Lru admit + peek + weight" {
    var alc = std.testing.allocator;
    var lru = try Lru(u32, 4).init(alc, 100, 8);
    defer lru.deinit();
    _ = lru.admit(1, 100, 10);
    _ = lru.admit(5, 200, 20);
    try std.testing.expectEqual(@as(?u32, 100), lru.peek(1));
    try std.testing.expectEqual(@as(?u32, 200), lru.peek(5));
    try std.testing.expectEqual(@as(usize, 30), lru.weight());
    try std.testing.expectEqual(@as(usize, 2), lru.lenFn());
}

test "Lru admit replaces weight" {
    var alc = std.testing.allocator;
    var lru = try Lru(u32, 2).init(alc, 1000, 16);
    defer lru.deinit();
    _ = lru.admit(1, 10, 5);
    _ = lru.admit(1, 20, 7); // replace, weight changes 5 -> 7
    try std.testing.expectEqual(@as(?u32, 20), lru.peek(1));
    try std.testing.expectEqual(@as(usize, 7), lru.weight());
    try std.testing.expectEqual(@as(usize, 1), lru.lenFn());
}

test "Lru promote moves LRU" {
    var alc = std.testing.allocator;
    var lru = try Lru(u32, 1).init(alc, 1000, 8);
    defer lru.deinit();
    _ = lru.admit(1, 11, 1);
    _ = lru.admit(2, 22, 1);
    _ = lru.admit(3, 33, 1);
    // LRU order is now [1, 2, 3] (1 = LRU). Promote 1.
    try std.testing.expect(lru.promote(1));
    // shard 0 evict should now return 2 (the new LRU)
    const e = lru.evictShard(0).?;
    try std.testing.expectEqual(@as(u32, 22), e.data);
}

test "Lru evictToLimit evicts oldest until under weight" {
    var alc = std.testing.allocator;
    var lru = try Lru(u32, 2).init(alc, 10, 8);
    defer lru.deinit();
    _ = lru.admit(1, 100, 5);
    _ = lru.admit(2, 200, 5);
    _ = lru.admit(3, 300, 5); // weight 15 > limit 10
    const evicted = try lru.evictToLimit(alc);
    defer alc.free(evicted);
    try std.testing.expect(lru.weight() <= 10);
    try std.testing.expect(evicted.len >= 1);
}

test "Lru remove" {
    var alc = std.testing.allocator;
    var lru = try Lru(u32, 2).init(alc, 1000, 8);
    defer lru.deinit();
    _ = lru.admit(7, 700, 3);
    const r = lru.remove(7).?;
    try std.testing.expectEqual(@as(u32, 700), r.data);
    try std.testing.expectEqual(@as(?u32, null), lru.peek(7));
    try std.testing.expectEqual(@as(usize, 0), lru.lenFn());
}
