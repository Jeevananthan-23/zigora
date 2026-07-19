//! Port of pingora-limits: lock-free frequency estimators and rate-tracking.
//! See ARCHITECTURE.md §3 (zigora_limits section) and V0.2_ROADMAP.md phase 1.2.
//!
//! Three primitives:
//! - `Estimator`: Count-Min Sketch, atomic counters, O(h) lookup
//!   (h = number of hashes; FP ratio = 1/n^h)
//! - `Inflight`: Estimator + a `Guard` that auto-decrements on `deinit()`
//! - `Rate`: sliding-window estimator across two slots, red/blue toggle
//!
//! All zero cross-module deps, no allocations after `init`.

const std = @import("std");
const zglimits = @This();

/// Fast non-cryptographic hash — uses wyhash (Zig stdlib default).
fn hashUsize(key: usize, seed: u64) u64 {
    var w = std.hash.Wyhash.init(seed);
    w.update(std.mem.asBytes(&key));
    return w.final();
}

// ponytail: Pingora allows any Hash type via generic. We accept u64 keys
// (the usual case — hashed upstream of the call). Use `std.hash.Wyhash`
// on bytes if a caller wants string keys. Less generic, fewer lines, no
// performance loss for the rate-limiter use case.

/// Count-Min Sketch: `hashes` rows × `slots` cols of atomic counters.
/// `incr(key, n)` returns the min across all hashes for `key`.
/// Overflow wraps (allowing negative estimates); caller must clamp if
/// that matters.
pub const Estimator = struct {
    rows: []Row,
    allocator: std.mem.Allocator,

    pub const Row = struct {
        cells: []std.atomic.Value(isize),
        seed: u64,
    };

    pub fn init(allocator: std.mem.Allocator, hashes: usize, slots: usize) !Estimator {
        const rows = try allocator.alloc(Row, hashes);
        errdefer allocator.free(rows);
        for (rows, 0..) |*r, i| {
            r.cells = try allocator.alloc(std.atomic.Value(isize), slots);
            // zero all cells
            @memset(r.cells, std.atomic.Value(isize).init(0));
            r.seed = std.crypto.random.int(u64) ^ (@as(u64, i) *% 0x9e3779b97f4a7c15);
        }
        return .{ .rows = rows, .allocator = allocator };
    }

    pub fn deinit(self: *Estimator) void {
        for (self.rows) |r| self.allocator.free(r.cells);
        self.allocator.free(self.rows);
    }

    /// Increment counters for `key` by `value`, return the new estimate (min across rows).
    pub fn incr(self: *Estimator, key: usize, value: isize) isize {
        var min: isize = std.math.maxInt(isize);
        for (self.rows) |*r| {
            const h = hashUsize(key, r.seed);
            const cell = &r.cells[h % r.cells.len];
            const prev = cell.fetchAdd(value, .monotonic);
            const new = prev +% value; // wrapping on overflow, mirrors Pingora
            if (new < min) min = new;
        }
        return min;
    }

    /// Decrement counters for `key` by `value`. No return value (matches Pingora).
    pub fn decr(self: *Estimator, key: usize, value: isize) void {
        for (self.rows) |*r| {
            const h = hashUsize(key, r.seed);
            _ = r.cells[h % r.cells.len].fetchSub(value, .monotonic);
        }
    }

    /// Estimated frequency of `key`.
    pub fn get(self: *const Estimator, key: usize) isize {
        var min: isize = std.math.maxInt(isize);
        for (self.rows) |*r| {
            const h = hashUsize(key, r.seed);
            const v = r.cells[h % r.cells.len].load(.monotonic);
            if (v < min) min = v;
        }
        return if (min == std.math.maxInt(isize)) 0 else min;
    }

    /// Reset all cells to zero.
    pub fn reset(self: *Estimator) void {
        for (self.rows) |*r| {
            for (r.cells) |*c| c.store(0, .monotonic);
        }
    }
};

/// `Inflight`: tracks count of events actively occurring. The `Guard`
/// returned from `incr` decrements the count when `deinit` is called.
pub const Inflight = struct {
    estimator: *Estimator,
    seed: u64,

    pub const HASHES = 4;
    pub const SLOTS = 8192;

    pub fn init(allocator: std.mem.Allocator) !Inflight {
        // ponytail: keep the Estimator internal — Pingora has it outside.
        // Single owner keeps lifetime simple. Hoist out if a second Inflight
        // should share one estimator.
        const est = try allocator.create(Estimator);
        est.* = try Estimator.init(allocator, HASHES, SLOTS);
        return .{ .estimator = est, .seed = std.crypto.random.int(u64) };
    }

    pub fn deinit(self: *Inflight, allocator: std.mem.Allocator) void {
        self.estimator.deinit();
        allocator.destroy(self.estimator);
    }

    /// `key` is hashed by `Inflight`'s own seed — caller passes the raw key.
    /// Returns a Guard and the estimated count after increment.
    pub fn incr(self: *Inflight, key: usize, value: isize) struct { guard: Guard, estimate: isize } {
        const id = hashUsize(key, self.seed);
        const estimate = self.estimator.incr(id, value);
        return .{
            .guard = .{ .estimator = self.estimator, .id = id, .value = value },
            .estimate = estimate,
        };
    }
};

/// `Guard`: increment-on-create, decrement-on-deinit handle.
/// Caller MUST call `deinit` (Zig has no Drop trait).
pub const Guard = struct {
    estimator: *Estimator,
    id: u64,
    value: isize,

    /// Re-increment (used when extending a hold). Returns new estimate.
    pub fn incr(self: *const Guard) isize {
        return self.estimator.incr(self.id, self.value);
    }

    /// Current estimated count for this guard's key.
    pub fn get(self: *const Guard) isize {
        return self.estimator.get(self.id);
    }

    /// Decrement — call when the inflight event finishes. Idempotent.
    pub fn deinit(self: *Guard) void {
        self.estimator.decr(self.id, self.value);
    }
};

/// `Rate`: sliding-window estimator across two slots, red/blue toggle.
/// `observe(key, n)` counts into the current slot; `rate(key)` returns
/// the per-second estimate from the previous (completed) slot.
pub const Rate = struct {
    red_slot: Estimator,
    blue_slot: Estimator,
    red_or_blue: std.atomic.Value(bool), // true = red is current
    start_ms: i64,
    reset_interval_ms: u64,
    last_reset_time: std.atomic.Value(u64),

    pub const HASHES = 4;
    pub const SLOTS = 1024;

    /// `interval_ms` is the slot duration (e.g. 1000 = 1 second).
    pub fn init(allocator: std.mem.Allocator, interval_ms: u64) !Rate {
        return .{
            .red_slot = try Estimator.init(allocator, HASHES, SLOTS),
            .blue_slot = try Estimator.init(allocator, HASHES, SLOTS),
            .red_or_blue = std.atomic.Value(bool).init(true),
            .start_ms = std.time.milliTimestamp(),
            .reset_interval_ms = interval_ms,
            .last_reset_time = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Rate) void {
        self.red_slot.deinit();
        self.blue_slot.deinit();
    }

    fn current(self: *Rate, red: bool) *Estimator {
        return if (red) &self.red_slot else &self.blue_slot;
    }

    fn previous(self: *Rate, red: bool) *Estimator {
        return if (red) &self.blue_slot else &self.red_slot;
    }

    /// Reset if enough time has passed. Returns ms since last reset.
    fn maybeReset(self: *Rate) u64 {
        const now = @as(u64, @intCast(@as(i64, @truncate(std.time.milliTimestamp() - self.start_ms))));
        const last = self.last_reset_time.load(.seq_cst);
        const past = now -% last;
        if (past < self.reset_interval_ms) return past;

        const red = self.red_or_blue.load(.seq_cst);
        if (self.last_reset_time.cmpxchgStrong(last, now, .seq_cst, .acquire) == null) {
            // we won the race: clear the previous slot, then flip the flag
            self.previous(red).reset();
            self.red_or_blue.store(!red, .seq_cst);
            // if we missed >=2 intervals, the new "current" (was previous before
            // flip) is also stale — clear it too
            if (now -% last >= self.reset_interval_ms * 2) {
                self.current(red).reset();
            }
        }
        return past;
    }

    /// Observe `events` for `key`. Returns the count in the current slot
    /// **before** the increment (matches Pingora's `observe`).
    pub fn observe(self: *Rate, key: usize, events: isize) isize {
        _ = self.maybeReset();
        const red = self.red_or_blue.load(.seq_cst);
        return self.current(red).incr(key, events);
    }

    /// Per-second rate from the previous (completed) slot.
    pub fn rate(self: *Rate, key: usize) f64 {
        const past = self.maybeReset();
        if (past >= self.reset_interval_ms * 2) return 0;
        const red = self.red_or_blue.load(.seq_cst);
        const v: f64 = @floatFromInt(self.previous(red).get(key));
        return v * 1000.0 / @as(f64, @floatFromInt(self.reset_interval_ms));
    }
};

// ===== Tests =====

test "Estimator incr/get/decr" {
    var alc = std.testing.allocator;
    var est = try Estimator.init(alc, 8, 8);
    defer est.deinit();
    try std.testing.expectEqual(@as(isize, 1), est.incr(1, 1));
    try std.testing.expectEqual(@as(isize, 1), est.incr(2, 1));
    try std.testing.expectEqual(@as(isize, 3), est.incr(1, 2));
    try std.testing.expectEqual(@as(isize, 3), est.incr(2, 2));
    try std.testing.expectEqual(@as(isize, 3), est.get(1));
    est.decr(1, 1);
    try std.testing.expectEqual(@as(isize, 2), est.get(1));
}

test "Estimator reset zeros everything" {
    var alc = std.testing.allocator;
    var est = try Estimator.init(alc, 4, 16);
    defer est.deinit();
    _ = est.incr(7, 5);
    _ = est.incr(7, 5);
    try std.testing.expectEqual(@as(isize, 10), est.get(7));
    est.reset();
    try std.testing.expectEqual(@as(isize, 0), est.get(7));
}

test "Inflight auto-decrement via Guard.deinit" {
    var alc = std.testing.allocator;
    var inf = try Inflight.init(alc);
    defer inf.deinit(alc);

    var g1 = inf.incr(42, 1);
    try std.testing.expectEqual(@as(isize, 1), g1.estimate);
    var g2 = inf.incr(42, 2);
    try std.testing.expectEqual(@as(isize, 3), g2.estimate);
    g1.guard.deinit();
    try std.testing.expectEqual(@as(isize, 2), g2.guard.get());
    g2.guard.deinit();
    var g3 = inf.incr(42, 1);
    try std.testing.expectEqual(@as(isize, 1), g3.estimate);
    g3.guard.deinit();
}

test "Rate observe + rate across intervals" {
    var alc = std.testing.allocator;
    // 100ms interval — short for tests
    var r = try Rate.init(alc, 100);
    defer r.deinit();

    const key = 7;
    try std.testing.expectEqual(@as(isize, 3), r.observe(key, 3));
    try std.testing.expectEqual(@as(isize, 5), r.observe(key, 2));
    // No interval passed yet — previous is empty
    try std.testing.expectEqual(@as(f64, 0), r.rate(key));

    // Sleep past first interval so previous = current red slot
    std.time.sleep(120 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(isize, 4), r.observe(key, 4));
    // Previous (red) held 5 events over 100ms = 50/sec
    const got = r.rate(key);
    try std.testing.expect(got > 40 and got < 60);
}

test "Rate returns 0 after 2+ missed intervals" {
    var alc = std.testing.allocator;
    var r = try Rate.init(alc, 50);
    defer r.deinit();
    _ = r.observe(1, 10);
    std.time.sleep(150 * std.time.ns_per_ms); // 3 intervals
    try std.testing.expectEqual(@as(f64, 0), r.rate(1));
}
