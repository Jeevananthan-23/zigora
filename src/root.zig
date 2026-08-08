//! Public root of the `zigora` library module. Consumers import via
//! `@import("zigora")` and get the full surface: every sub-package.

const std = @import("std");
const log = std.log.scoped(.zigora_src);

// Package namespaces (std-style: `zigora.core`, `zigora.pool`, ...)
pub const core = @import("zigora_core.zig");
pub const http = @import("zigora_http.zig");
pub const proxy = @import("zigora_proxy.zig");
pub const zgerror = @import("zigora_error.zig");

pub const limits = @import("zigora_limits.zig");
pub const lru = @import("zigora_lru.zig");
pub const ketama = @import("zigora_ketama.zig");
pub const tinyufo = @import("zigora_tinyufo.zig");
pub const pool = @import("zigora_pool.zig");
pub const memory_cache = @import("zigora_memory_cache.zig");
pub const lb = @import("zigora_lb.zig");
pub const cache = @import("zigora_cache.zig");
pub const tls = @import("zigora_tls.zig");
pub const metrics = @import("zigora_metrics.zig");
pub const utils = @import("zigora_utils.zig");

pub const Server = core.Server;
pub const ServerConf = core.ServerConf;
pub const Service = core.Service;
pub const ServerApp = core.ServerApp;

pub const Request = http.Request;
pub const Header = http.Header;
pub const Method = http.Method;
pub const HttpError = http.HttpError;

pub const HttpProxy = proxy.HttpProxy;
pub const ProxyHttp = proxy.ProxyHttp;
pub const HttpPeer = proxy.HttpPeer;
pub const http_proxy_service = proxy.http_proxy_service;

pub const ZgError = zgerror.ZgError;
pub const ErrorType = zgerror.Type;
pub const ErrorSource = zgerror.Source;

test "public surface exposes core.Server" {
    _ = Server;
    _ = Service;
}

test "public surface exposes proxy.HttpProxy" {
    _ = HttpProxy;
    _ = ProxyHttp;
}

test "public surface exposes http.Request" {
    var buf: [64]u8 = undefined;
    const raw = "GET / HTTP/1.1\r\n\r\n";
    @memcpy(buf[0..raw.len], raw);
    const req = try Request.parse(buf[0..raw.len]);
    try std.testing.expectEqualStrings("/", req.path);
}
