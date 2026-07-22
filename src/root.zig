//! Public root of the `zigora` library module. Consumers import via
//! `@import("zigora")` and get the v0.1 surface: core + proxy + http + error.

const std = @import("std");
const log = std.log.scoped(.zigora_src);
const core = @import("zigora-core");
const http = @import("zigora-http");
const proxy = @import("zigora-proxy");
const zgerror = @import("zigora-error");

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