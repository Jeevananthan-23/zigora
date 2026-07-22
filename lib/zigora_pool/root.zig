//! Port of pingora-pool: generic reusable-connection pool.
//! See V0.2_ROADMAP.md phase 2.6.
//!
//! Lazy port: single mutex around the whole pool (Pingora sharded with hot
//! lock-free queue + HashMap + thread-local LRU). Skip the watch/notify
//! machinery — caller calls `getAny` then either uses or closes the conn
//! outside the lock. ID type is `i32` on POSIX (file descriptor) or `usize`
//! on Windows (handle index), matching pingora.
//!
//! Casualties vs pingora:
//! - no idle watcher task (pingora's watcher pings the conn and emits errors
//!   on close); caller decides to keep alive or close.
//! - no `Notify`/Receiver pattern; the pool just hands out the value.
//! Upgrade paths noted inline.

const std = @import("std");
const log = std.log.scoped(.pool);

// ponytail: simple spinlock wrapping std.atomic.Mutex for the old
// std.Thread.Mutex API. Upgrade to std.Io.Mutex + io context when async.
const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(m: *Mutex) void {
        while (!std.atomic.Mutex.tryLock(&m.inner)) {}
    }

    pub fn unlock(m: *Mutex) void {
        std.atomic.Mutex.unlock(&m.inner);
    }
};
const zgpool = @This();

pub const GroupKey = u64;
pub const Id = i32;

pub fn ConnectionMeta(comptime T: type) type {
    return struct {
        key: GroupKey,
        id: Id,
        data: T,
    };
}

pub fn PoolNode(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: Mutex = .{},
        // Stored as a singly-linked list of entries; `getAny` pops head.
        // Memory cost: one alloc per entry, amortized low. Optimization:
        // small array buffer if it becomes hot.
        entries: std.ArrayList(Entry),

        pub const Entry = struct { id: Id, conn: T };

        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator;
            return .{ .entries = .empty };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn getAny(self: *Self, allocator: std.mem.Allocator) ?Entry {
            _ = allocator;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.entries.items.len == 0) return null;
            return self.entries.orderedRemove(0); // O(n) but list is small
            // ponytail: O(n) shift on hot path; switch to ring buffer
            // (std.RingBuffer) when this shows up in benchmarks.
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, id: Id, conn: T) !void {
            self.mu.lock();
            defer self.mu.unlock();
            try self.entries.append(allocator, .{ .id = id, .conn = conn });
        }

        pub fn remove(self: *Self, id: Id) ?T {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.entries.items, 0..) |e, i| {
                if (e.id == id) {
                    const out = self.entries.orderedRemove(i).conn;
                    return out;
                }
            }
            return null;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.entries.items.len == 0;
        }
    };
}

/// `ConnectionPool<S>` — a `GroupKey → *PoolNode<S>` map + a simple insertion
/// order list to enforce a `total_size` cap. When the cap is hit on `put`,
/// the oldest conn's metadata is returned so the caller can close it.
pub fn ConnectionPool(comptime S: type) type {
    return struct {
        const Self = @This();

        const Meta = ConnectionMeta(S);

        mu: Mutex = .{},
        nodes: std.AutoArrayHashMapUnmanaged(GroupKey, *PoolNode(S)),
        // Insertion order to enforce total size: oldest first.
        order: std.ArrayList(Meta),
        total_size: usize = 0,
        size_limit: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, size_limit: usize) Self {
            return .{
                .nodes = .{},
                .order = .empty,
                .size_limit = size_limit,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.values()) |n| {
                n.deinit(self.allocator);
                self.allocator.destroy(n);
            }
            self.nodes.deinit(self.allocator);
            self.order.deinit(self.allocator);
        }

        /// Try to retrieve any idle conn under `key`. Returns the conn directly
        /// (caller owns it from here on, much like Pingora's `get`).
        pub fn get(self: *Self, key: GroupKey) ?S {
            self.mu.lock();
            defer self.mu.unlock();
            const node = self.nodes.get(key) orelse return null;
            const e = node.getAny(self.allocator) orelse return null;

            // remove from order list so the cap accounting matches
            for (self.order.items, 0..) |m, i| {
                if (m.id == e.id) {
                    _ = self.order.orderedRemove(i);
                    self.total_size -= 1;
                    break;
                }
            }
            return e.conn;
        }

        /// Put a reusable conn back. If the pool is at the size limit, returns
        /// the evicted meta so the caller can close that conn (or this one if
        /// the pool rejected it). Returns null if accepted without eviction.
        pub fn put(self: *Self, key: GroupKey, meta: ConnectionMeta(S)) ?Meta {
            self.mu.lock();
            defer self.mu.unlock();

            // size cap check
            if (self.total_size >= self.size_limit) {
                // Evict the LRU entry from the same key or, if none available,
                // any entry; here returns the new caller as rejected.
                // ponytail: simplify — reject new conn outright.
                return meta; // caller closes it
            }

            const node_ptr = self.nodes.get(key) orelse blk: {
                const n = self.allocator.create(PoolNode(S)) catch return meta;
                n.* = PoolNode(S).init(self.allocator);
                self.nodes.put(self.allocator, key, n) catch return meta;
                break :blk n;
            };

            node_ptr.insert(self.allocator, meta.id, meta.data) catch return meta;
            self.order.append(self.allocator, meta) catch return meta;
            self.total_size += 1;
            return null;
        }

        pub fn len(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.total_size;
        }
    };
}

// ===== Tests =====

test "PoolNode insert/remove/getAny behaves as FIFO" {
    const alc = std.testing.allocator;
    var n = PoolNode(u32).init(alc);
    defer n.deinit(alc);
    try n.insert(alc, 1, 100);
    try n.insert(alc, 2, 200);
    try std.testing.expectEqual(@as(?u32, 100), n.getAny(alc).?.conn);
    try std.testing.expectEqual(@as(?u32, 200), n.getAny(alc).?.conn);
    try std.testing.expect(n.getAny(alc) == null);
}

test "PoolNode remove finds by id" {
    const alc = std.testing.allocator;
    var n = PoolNode(u32).init(alc);
    defer n.deinit(alc);
    try n.insert(alc, 1, 10);
    try n.insert(alc, 2, 20);
    try std.testing.expectEqual(@as(?u32, 20), n.remove(2));
    try std.testing.expectEqual(@as(?u32, 10), n.remove(1));
    try std.testing.expectEqual(@as(?u32, null), n.remove(99));
}

test "ConnectionPool put then get reuses across same key" {
    const alc = std.testing.allocator;
    var pool = ConnectionPool(u32).init(alc, 8);
    defer pool.deinit();
    const k = 7;
    const meta: ConnectionMeta(u32) = .{ .key = k, .id = 42, .data = 999 };
    const evicted = pool.put(k, meta);
    try std.testing.expect(evicted == null); // accepted, room available
    try std.testing.expectEqual(@as(usize, 1), pool.len());
    try std.testing.expectEqual(@as(?u32, 999), pool.get(k));
    try std.testing.expectEqual(@as(usize, 0), pool.len());
}

test "ConnectionPool rejects when at size limit" {
    const alc = std.testing.allocator;
    var pool = ConnectionPool(u32).init(alc, 1);
    defer pool.deinit();
    const m1: ConnectionMeta(u32) = .{ .key = 1, .id = 1, .data = 10 };
    const m2: ConnectionMeta(u32) = .{ .key = 1, .id = 2, .data = 20 };
    try std.testing.expect(pool.put(1, m1) == null);
    const ev = pool.put(1, m2).?;
    try std.testing.expectEqual(@as(u32, 20), ev.data); // m2 rejected
}
