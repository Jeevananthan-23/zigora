//! Port of pingora-cache: HTTP cache state machine + trait interfaces.
//! See V0.2_ROADMAP.md phase 2.9.
//!
//! Surface ported: `HttpCache` phase machine, `CachePhase`, `NoCacheReason`,
//! `RespCacheable`, `HitStatus`, `Storage`/`HitHandler`/`MissHandler`/
//! `EvictionManager` vtable interfaces.
//!
//! Lazy port: no cache-control parsing, no lock/cache-stampede protection,
//! no predictor, no variance, no disk storage impl, no put/filters. Just
//! the interfaces + state enum so the v0.2 proxy can call `cache_lookup()`
//! and receive a `CachePhase`, then wire the real storage later.
//!
//! Ponytail: the 6000+ lines of pingora-cache come from max_file_size
//! tracking, async lock timeout logic, cache-control header parsing, and
//! a write-ahead meta subsystem. For v0.2's "cache exists and returns a
//! phase" integration, we only need the decision surface.

const std = @import("std");
const http = @import("zigora-http");
const zgcache = @This();

/// The HTTP cache state machine — phase-driven across a request.
pub const HttpCache = struct {
    phase: CachePhase,
    meta: ?CacheMeta = null,
};

/// Lifecycle phase, mirrors `pingora-cache::CachePhase`.
pub const CachePhase = union(enum) {
    /// Caching was never enabled.
    disabled: NoCacheReason,
    /// Enabled, nothing set yet.
    uninit,
    /// Enabled but the request decided not to use it.
    bypass,
    /// Awaiting cache key generation.
    cache_key,
    /// Cache hit.
    hit,
    /// Cache miss.
    miss,
    /// Stale asset found.
    stale,
    /// Stale asset found, another request revalidates.
    stale_updating,
    /// Stale asset found; fresh fetched.
    expired,
    /// Stale asset found; revalidated as fresh.
    revalidated,
    /// Revalidated but deemed uncacheable.
    revalidated_no_cache: NoCacheReason,

    pub fn asStr(self: CachePhase) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .uninit => "uninitialized",
            .bypass => "bypass",
            .cache_key => "key",
            .hit => "hit",
            .miss => "miss",
            .stale => "stale",
            .stale_updating => "stale-updating",
            .expired => "expired",
            .revalidated => "revalidated",
            .revalidated_no_cache => "revalidated-nocache",
        };
    }

    pub fn isEnabled(self: CachePhase) bool {
        return self != .disabled;
    }
};

/// Reason why caching was not possible for this response.
pub const NoCacheReason = enum {
    never_enabled,
    origin_not_cache,
    response_too_large,
    predicted_response_too_large,
    storage_error,
    internal_error,
    deferred,
    declined_to_upstream,
    upstream_error,
    cache_lock_give_up,
    cache_lock_timeout,
    custom,

    pub fn asStr(self: NoCacheReason) []const u8 {
        return switch (self) {
            .never_enabled => "never_enabled",
            .origin_not_cache => "origin_not_cache",
            .response_too_large => "response_too_large",
            .predicted_response_too_large => "predicted_response_too_large",
            .storage_error => "storage_error",
            .internal_error => "internal_error",
            .deferred => "deferred",
            .declined_to_upstream => "declined_to_upstream",
            .upstream_error => "upstream_error",
            .cache_lock_give_up => "cache_lock_give_up",
            .cache_lock_timeout => "cache_lock_timeout",
            .custom => "custom",
        };
    }
};

/// Decision after `cache_lookup`: asset was hit/miss/stale with metadata.
pub const CacheDecision = union(enum) {
    /// Asset found, header + freshness + body reader.
    hit: struct { meta: CacheMeta, handler: HitHandler },
    /// Asset not found; miss handler writes response body into cache.
    miss: MissHandler,
    /// Stale asset found.
    stale: struct { meta: CacheMeta, handler: HitHandler },
};

/// Freshness status of a cached asset.
pub const HitStatus = enum {
    expired,
    force_expired,
    force_miss,
    failed_hit_filter,
    fresh,
    force_fresh,

    pub fn isFresh(self: HitStatus) bool {
        return self == .fresh or self == .force_fresh;
    }

    pub fn isTreatedAsMiss(self: HitStatus) bool {
        return self == .force_miss or self == .failed_hit_filter;
    }
};

/// Response cacheability decision.
pub const RespCacheable = union(enum) {
    cacheable: CacheMeta,
    uncacheable: NoCacheReason,

    pub fn isCacheable(self: RespCacheable) bool {
        return self == .cacheable;
    }
};

/// Static list of known headers that comprise a cache key variant.
pub const KEY_VARIANT_HEADERS = [_][]const u8{
    "Accept-Encoding",
    "Origin",
    "Access-Control-Request-Method",
    "Access-Control-Request-Headers",
};

/// Freshness directives that override cache behaviour.
pub const ForcedFreshness = enum {
    force_expired,
    force_miss,
    force_fresh,
};

// ---- trait-like interfaces (vtable structs) ----

/// `CacheMeta` — the metadata for one cached asset.
pub const CacheMeta = struct {
    header: http.ResponseHeader,
    /// Monotonic timestamp (ns) when the entry was created.
    created_ns: i128,
    /// Monotonic timestamp (ns) when the asset was last updated.
    updated_ns: i128,
    /// Monotonic timestamp (ns) until which the asset is fresh.
    fresh_until_ns: i128,

    /// Load the default CacheMeta into this instance.
    pub fn fromDefaults(defaults: CacheMetaDefaults) CacheMeta {
        _ = defaults;
        return .{
            .header = .{ .status_code = 0, .version = .http11, .headers = &.{}, .body_start = 0 },
            .created_ns = 0,
            .updated_ns = 0,
            .fresh_until_ns = 0,
        };
    }
};

/// Defaults used by a `Storage` implementation.
pub const CacheMetaDefaults = struct {
    version: http.Version = .http11,
    variance: enum { none, hash64 } = .none,
};

// ---- storage interfaces (vtable, matching `pingora-cache::Storage`) ----

pub const HitHandler = struct {
    vtable: *const VTable,
    userdata: *anyopaque,

    pub const VTable = struct {
        readBody: *const fn (*anyopaque) ?[]const u8,
        finish: *const fn (*anyopaque) void,
    };

    pub fn readBody(self: HitHandler) ?[]const u8 {
        return self.vtable.readBody(self.userdata);
    }

    pub fn finish(self: HitHandler) void {
        return self.vtable.finish(self.userdata);
    }
};

pub const MissHandler = struct {
    vtable: *const VTable,
    userdata: *anyopaque,

    pub const VTable = struct {
        writeBody: *const fn (*anyopaque, []const u8, bool) void,
        finish: *const fn (*anyopaque) MissFinishType,
    };

    pub fn writeBody(self: MissHandler, data: []const u8, eof: bool) void {
        return self.vtable.writeBody(self.userdata, data, eof);
    }

    pub fn finish(self: MissHandler) MissFinishType {
        return self.vtable.finish(self.userdata);
    }
};

pub const MissFinishType = enum { done, cancelled, errored };

pub const Storage = struct {
    vtable: *const VTable,
    userdata: *anyopaque,

    pub const VTable = struct {
        lookup: *const fn (*anyopaque, key: []const u8) ?CacheDecision,
    };

    pub fn lookup(self: Storage, key: []const u8) ?CacheDecision {
        return self.vtable.lookup(self.userdata, key);
    }
};

pub const EvictionManager = struct {
    vtable: *const VTable,
    userdata: *anyopaque,

    pub const VTable = struct {
        /// Admit a new asset. Returns keys (hash64) that were evicted.
        admit: *const fn (*anyopaque, hash64: u64, size: usize, fresh_until_ns: i128, allocator: std.mem.Allocator) !?[]const u64,
        /// Record that the asset was recently accessed.
        access: *const fn (*anyopaque, hash64: u64) void,
    };

    pub fn admit(self: EvictionManager, hash64: u64, size: usize, fresh_until_ns: i128, allocator: std.mem.Allocator) !?[]const u64 {
        return self.vtable.admit(self.userdata, hash64, size, fresh_until_ns, allocator);
    }

    pub fn access(self: EvictionManager, hash64: u64) void {
        self.vtable.access(self.userdata, hash64);
    }
};

// ===== Tests =====

test "CachePhase asStr covers all variants" {
    try std.testing.expectEqualStrings("miss", CachePhase.miss.asStr());
    try std.testing.expectEqualStrings("hit", CachePhase.hit.asStr());
    try std.testing.expectEqualStrings("stale", CachePhase.stale.asStr());
    try std.testing.expectEqualStrings("disabled", (@as(CachePhase, .{ .disabled = .internal_error })).asStr());
    try std.testing.expect(CachePhase.hit.isEnabled());
    try std.testing.expect(!(@as(CachePhase, .{ .disabled = .never_enabled })).isEnabled());
}

test "HttpCache starts disabled by default" {
    const c = HttpCache{ .phase = .{ .disabled = .never_enabled } };
    try std.testing.expect(!c.phase.isEnabled());
    try std.testing.expect(c.meta == null);
}

test "RespCacheable cacheable/uncacheable" {
    const rc = @as(RespCacheable, .{ .cacheable = .{
        .header = .{ .status_code = 200, .version = .http11, .headers = &.{}, .body_start = 0 },
        .created_ns = 0,
        .updated_ns = 0,
        .fresh_until_ns = 0,
    } });
    try std.testing.expect(rc.isCacheable());
    const unc = @as(RespCacheable, .{ .uncacheable = .origin_not_cache });
    try std.testing.expect(!unc.isCacheable());
}

test "HitStatus fresh checks" {
    try std.testing.expect(HitStatus.fresh.isFresh());
    try std.testing.expect(HitStatus.force_fresh.isFresh());
    try std.testing.expect(!HitStatus.expired.isFresh());
    try std.testing.expect(HitStatus.force_miss.isTreatedAsMiss());
    try std.testing.expect(!HitStatus.fresh.isTreatedAsMiss());
}

test "NoCacheReason asStr" {
    try std.testing.expectEqualStrings("origin_not_cache", NoCacheReason.origin_not_cache.asStr());
    try std.testing.expectEqualStrings("storage_error", NoCacheReason.storage_error.asStr());
}