pub const zgcore = @import("zigora_core/root.zig");
pub const zghttp = @import("zigora_http/root.zig");
pub const zgerror = @import("zigora_error/root.zig");
pub const zlproxy = @import("zigora_proxy/root.zig");

// v0.2 stubs
pub const zglb = @import("zigora_lb/root.zig");
pub const zgcache = @import("zigora_cache/root.zig");
pub const zglimits = @import("zigora_limits/root.zig");
pub const zgmetrics = @import("zigora_metrics/root.zig");
pub const zgtls = @import("zigora_tls/root.zig");
pub const zgutils = @import("zigora_utils/root.zig");

pub const zigoralib = @This();