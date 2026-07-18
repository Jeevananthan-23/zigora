//! v0.1 HTTP/1.1 parser. Zero-copy, no allocation — all fields are slices
//! into a caller-provided buffer. Headers are stored as a slice of {name,value}
//! pairs; body parsing is out of scope (the proxy forwards raw bytes after
//! headers). HTTP/2 is v0.2+.
//!
//! See ARCHITECTURE.md §3.

const std = @import("std");
const zghttp = @This();

pub const HttpError = error{
    InvalidRequestLine,
    UnsupportedVersion,
    HeaderTooLarge,
    Incomplete,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Method = enum(u8) {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,
    PATCH,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: Version,
    headers: []const Header,
    /// Offset into the buffer where the body starts. 0 if no body.
    body_start: usize,

    /// Parse an HTTP/1.1 request from a raw buffer. Returns a Request with
    /// slices pointing directly into `buf`. Caller owns `buf`'s lifetime.
    pub fn parse(buf: []u8) HttpError!Request {
        var pos: usize = 0;

        // Request line: "METHOD SP PATH SP VERSION CRLF"
        const method_end = std.mem.indexOfScalarPos(u8, buf, pos, ' ') orelse return error.InvalidRequestLine;
        const method_str = buf[pos..method_end];
        pos = method_end + 1;

        const path_end = std.mem.indexOfScalarPos(u8, buf, pos, ' ') orelse return error.InvalidRequestLine;
        const path = buf[pos..path_end];
        pos = path_end + 1;

        const req_line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return error.Incomplete;
        const version_str = buf[pos..req_line_end];
        pos = req_line_end + 2;

        const method = std.meta.stringToEnum(Method, method_str) orelse Method.GET;
        const version = versionFromSlice(version_str) orelse return error.UnsupportedVersion;

        // ponytail: fixed header cap. Grow if someone ships >32 headers.
        var headers: [32]Header = undefined;
        var header_count: usize = 0;

        while (header_count < headers.len) {
            if (pos + 2 > buf.len) return error.Incomplete;
            if (std.mem.eql(u8, buf[pos..][0..2], "\r\n")) {
                pos += 2;
                break;
            }
            const header_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return error.Incomplete;
            const header_line = buf[pos..header_end];
            pos = header_end + 2;

            const colon = std.mem.indexOfScalar(u8, header_line, ':') orelse return error.HeaderTooLarge;
            const name = std.mem.trimEnd(u8, header_line[0..colon], " \t");
            var value_start = colon + 1;
            while (value_start < header_line.len and (header_line[value_start] == ' ' or header_line[value_start] == '\t')) {
                value_start += 1;
            }
            const value = header_line[value_start..];

            headers[header_count] = .{ .name = name, .value = value };
            header_count += 1;
        }

        return .{
            .method = method,
            .path = path,
            .version = version,
            .headers = headers[0..header_count],
            .body_start = pos,
        };
    }
};

pub const Version = enum(u8) {
    http10,
    http11,
};

fn versionFromSlice(s: []const u8) ?Version {
    if (std.mem.eql(u8, s, "HTTP/1.1")) return .http11;
    if (std.mem.eql(u8, s, "HTTP/1.0")) return .http10;
    return null;
}

test "parse simple GET request" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    const req = try Request.parse(buf[0..raw.len]);
    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/", req.path);
    try std.testing.expectEqual(Version.http11, req.version);
    try std.testing.expectEqual(@as(usize, 1), req.headers.len);
    try std.testing.expectEqualStrings("Host", req.headers[0].name);
    try std.testing.expectEqualStrings("localhost", req.headers[0].value);
    try std.testing.expectEqual(@as(usize, raw.len), req.body_start);
}

test "parse POST request with headers" {
    const raw = "POST /api HTTP/1.1\r\nContent-Type: application/json\r\nAccept: */*\r\n\r\n";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    const req = try Request.parse(buf[0..raw.len]);
    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("/api", req.path);
    try std.testing.expectEqual(@as(usize, 2), req.headers.len);
}

test "reject HTTP/2" {
    const raw = "GET / HTTP/2.0\r\n\r\n";
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    try std.testing.expectError(error.UnsupportedVersion, Request.parse(buf[0..raw.len]));
}

test "reject incomplete" {
    const raw = "GET / HTTP/1.1\r\n";
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    try std.testing.expectError(error.Incomplete, Request.parse(buf[0..raw.len]));
}