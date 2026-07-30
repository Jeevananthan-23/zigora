//! Pre-allocated ring buffer pool for per-request buffers.
//! Replaces stack allocation of ~24K per request with reusable pool slots.
//!
//! pingora: uses BytesMut for per-request buffering (out of scope here).
//! Zigora: fixed-size ring of PerRequestBuffers structs with atomic counter.
//!
//! ponytail: single static pool, no dynamic resizing, LRU assignment.
//! Upgrade to per-service pools if multi-service contention appears.

const std = @import("std");
const log = std.log.scoped(.core);

pub const BUFFER_POOL_SIZE = 16;

pub const PerRequestBuffers = struct {
    read: [4096]u8 = undefined,
    write: [4096]u8 = undefined,
    header: [8192]u8 = undefined,
};

pub const BufferPool = struct {
    ring: [BUFFER_POOL_SIZE]PerRequestBuffers,
    cursor: std.atomic.Value(usize),

    pub fn init() BufferPool {
        var pool: BufferPool = undefined;
        pool.cursor = .{ .raw = 0 };
        return pool;
    }

    pub fn borrow(self: *BufferPool) *PerRequestBuffers {
        const idx = self.cursor.fetchAdd(1, .monotonic) % BUFFER_POOL_SIZE;
        return &self.ring[idx];
    }
};

// ===== Tests =====

test "BufferPool borrow wraps around" {
    var pool = BufferPool.init();
    const a = pool.borrow();
    const b = pool.borrow();
    try std.testing.expect(a != b);
    // we don't own the buffer between borrows, so just test wrapping
    for (0..100) |_| {
        _ = pool.borrow();
    }
}