pub const zgcore = @import("zigora_core/root.zig");
pub const zghttp = @import("zigora_http/root.zig");
pub const zgerror = @import("zigora_error/root.zig");
pub const zlproxy = @import("zigora_proxy/root.zig");

// v0.2 phase 1 (limits, lru, ketama, tinyufo)
pub const zglimits = @import("zigora_limits/root.zig");
pub const zglru = @import("zigora_lru/root.zig");
pub const zgketama = @import("zigora_ketama/root.zig");
pub const zgtinyufo = @import("zigora_tinyufo/root.zig");

// v0.2 phase 2 packages
pub const zgpool = @import("zigora_pool/root.zig");
pub const zgmemcache = @import("zigora_memory_cache/root.zig");
pub const zglb = @import("zigora_lb/root.zig");
pub const zgcache = @import("zigora_cache/root.zig");

pub const zgtls = @import("zigora_tls/root.zig");

// v0.2 stubs (reserved)
pub const zgmetrics = @import("zigora_metrics/root.zig");
pub const zgutils = @import("zigora_utils/root.zig");

pub const zigoralib = @This();