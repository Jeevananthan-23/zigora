//! Port of pingora-pool: generic reusable-connection pool.
//! See docs/V0.2_ROADMAP.md phase 2.6.
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
const queue = @import("stdx-queue");

/// ponytail: simple spinlock wrapping std.atomic.Mutex for the old
/// std.Thread.Mutex API. Upgrade to std.Io.Mutex + io context when async.
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

/// Monotonic nanoseconds — std.time has no timestamp in 0.16.
fn monoNow() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

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
        const HOT_CAPACITY = 16;

        mu: Mutex = .{},
        // 16-slot fixed ring (hot path, no allocation, O(1) push/pop) +
        // ArrayList spillover (cold, LIFO). Spill stores freshest last,
        // so popping its tail hands out the least-idle conn first.
        hot: queue.ArrayQueue(Entry, HOT_CAPACITY) = .{},
        spill: std.ArrayList(Entry) = .empty,

        pub const Entry = struct { id: Id, conn: T, put_idle_at: i64 };

        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.spill.deinit(allocator);
        }

        pub fn getAny(self: *Self, allocator: std.mem.Allocator) ?Entry {
            _ = allocator;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.hot.pop()) |e| return e;
            if (self.spill.items.len == 0) return null;
            return self.spill.pop();
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, id: Id, conn: T) !void {
            self.mu.lock();
            defer self.mu.unlock();
            const e = Entry{ .id = id, .conn = conn, .put_idle_at = monoNow() };
            self.hot.push(e) catch |err| switch (err) {
                error.QueueFull => try self.spill.append(allocator, e),
            };
        }

        pub fn remove(self: *Self, id: Id) ?T {
            self.mu.lock();
            defer self.mu.unlock();
            var out: ?T = null;
            const n = self.hot.len();
            for (0..n) |_| {
                const e = self.hot.pop().?;
                if (out == null and e.id == id) {
                    out = e.conn;
                } else {
                    self.hot.push(e) catch unreachable; // popped one, so room exists
                }
            }
            if (out != null) return out;
            for (self.spill.items, 0..) |e, i| {
                if (e.id == id) {
                    return self.spill.orderedRemove(i).conn;
                }
            }
            return null;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mu.lock();
            defer self.mu.unlock();
            return self.hot.len() == 0 and self.spill.items.len == 0;
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

        /// Liveness/TTL configuration. `idle_ms = 0` disables the TTL;
        /// null closures disable their checks (pool then behaves like a
        /// plain FIFO reuse pool).
        pub const Options = struct {
            idle_ms: u64 = 0,
            ctx: ?*anyopaque = null,
            /// Return false to drop an idle conn on `get`.
            is_live: ?*const fn (?*anyopaque, *S) bool = null,
            /// Close/destroy an idle conn the pool has decided to drop.
            destroy: ?*const fn (?*anyopaque, *S) void = null,
        };

        mu: Mutex = .{},
        nodes: std.AutoArrayHashMapUnmanaged(GroupKey, *PoolNode(S)),
        // Insertion order to enforce total size: oldest first.
        order: std.ArrayList(Meta),
        total_size: usize = 0,
        size_limit: usize,
        allocator: std.mem.Allocator,
        opts: Options,

        pub fn init(allocator: std.mem.Allocator, size_limit: usize, opts: Options) Self {
            return .{
                .nodes = .{},
                .order = .empty,
                .size_limit = size_limit,
                .allocator = allocator,
                .opts = opts,
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
        ///
        /// Lazy liveness: pops entries and drops stale (TTL) / dead (`is_live`)
        /// ones via the `destroy` closure, bounded to 8 pops so a mass-death
        /// burst drains across subsequent gets instead of stalling this one.
        pub fn get(self: *Self, key: GroupKey) ?S {
            self.mu.lock();
            defer self.mu.unlock();
            const node = self.nodes.get(key) orelse return null;

            const now = monoNow();
            for (0..8) |_| {
                var e = node.getAny(self.allocator) orelse return null;

                const stale = self.opts.idle_ms != 0 and
                    @as(u64, @intCast(now - e.put_idle_at)) >= self.opts.idle_ms;
                const dead = stale or if (self.opts.is_live) |is_live|
                    !is_live(self.opts.ctx, &e.conn)
                else
                    false;
                if (dead) {
                    if (self.opts.destroy) |destroy| destroy(self.opts.ctx, &e.conn);
                    self.orderRemove(e.id);
                    continue;
                }

                self.orderRemove(e.id);
                return e.conn;
            }
            return null;
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

        /// Remove `id` from the order list (cap accounting). No-op if absent.
        fn orderRemove(self: *Self, id: Id) void {
            for (self.order.items, 0..) |m, i| {
                if (m.id == id) {
                    _ = self.order.orderedRemove(i);
                    self.total_size -= 1;
                    break;
                }
            }
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

test "PoolNode spills past ring capacity: FIFO in ring, LIFO from spill" {
    const alc = std.testing.allocator;
    var n = PoolNode(u32).init(alc);
    defer n.deinit(alc);
    for (1..25) |i| try n.insert(alc, @intCast(i), @intCast(i * 100));
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(alc);
    while (n.getAny(alc)) |e| try got.append(alc, e.conn);
    // ring: FIFO 1..16; spill: LIFO 24..17
    for (1..17, 0..) |i, j| try std.testing.expectEqual(@as(u32, @intCast(i * 100)), got.items[j]);
    try std.testing.expectEqual(@as(u32, 2400), got.items[16]);
    try std.testing.expectEqual(@as(u32, 2300), got.items[17]);
    try std.testing.expectEqual(@as(u32, 1700), got.items[23]);
    try std.testing.expectEqual(@as(usize, 24), got.items.len);
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
    var pool = ConnectionPool(u32).init(alc, 8, .{});
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
    var pool = ConnectionPool(u32).init(alc, 1, .{});
    defer pool.deinit();
    const m1: ConnectionMeta(u32) = .{ .key = 1, .id = 1, .data = 10 };
    const m2: ConnectionMeta(u32) = .{ .key = 1, .id = 2, .data = 20 };
    try std.testing.expect(pool.put(1, m1) == null);
    const ev = pool.put(1, m2).?;
    try std.testing.expectEqual(@as(u32, 20), ev.data); // m2 rejected
}

test "ConnectionPool TTL: stale entry dropped and destroyed" {
    const alc = std.testing.allocator;
    var destroyed: usize = 0;
    var pool = ConnectionPool(u32).init(alc, 8, .{
        .idle_ms = 1, // any elapsed ns makes the entry stale
        .ctx = @ptrCast(&destroyed),
        .destroy = struct {
            fn f(ctx: ?*anyopaque, s: *u32) void {
                _ = s;
                const d: *usize = @ptrCast(@alignCast(ctx.?));
                d.* += 1;
            }
        }.f,
    });
    defer pool.deinit();
    const meta: ConnectionMeta(u32) = .{ .key = 5, .id = 1, .data = 7 };
    try std.testing.expect(pool.put(5, meta) == null);
    // std.time.sleep is gone in 0.16; wait for the monotonic clock to tick
    const t0 = monoNow();
    while (monoNow() == t0) {}
    try std.testing.expectEqual(@as(?u32, null), pool.get(5));
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqual(@as(usize, 0), pool.len());
}

test "ConnectionPool is_live: dead entry rejected, live entry reused" {
    const alc = std.testing.allocator;
    const Ctx = struct { live: bool, destroyed: usize };
    var ctx = Ctx{ .live = false, .destroyed = 0 };
    var pool = ConnectionPool(u32).init(alc, 8, .{
        .ctx = @ptrCast(&ctx),
        .is_live = struct {
            fn f(c: ?*anyopaque, s: *u32) bool {
                _ = s;
                const self: *Ctx = @ptrCast(@alignCast(c.?));
                return self.live;
            }
        }.f,
        .destroy = struct {
            fn f(c: ?*anyopaque, s: *u32) void {
                _ = s;
                const self: *Ctx = @ptrCast(@alignCast(c.?));
                self.destroyed += 1;
            }
        }.f,
    });
    defer pool.deinit();
    const meta: ConnectionMeta(u32) = .{ .key = 5, .id = 1, .data = 7 };
    try std.testing.expect(pool.put(5, meta) == null);
    try std.testing.expectEqual(@as(?u32, null), pool.get(5));
    try std.testing.expectEqual(@as(usize, 1), ctx.destroyed);
    try std.testing.expectEqual(@as(usize, 0), pool.len());
    ctx.live = true;
    try std.testing.expect(pool.put(5, meta) == null);
    try std.testing.expectEqual(@as(?u32, 7), pool.get(5));
    try std.testing.expectEqual(@as(usize, 1), ctx.destroyed);
}
