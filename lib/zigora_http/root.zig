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

    pub fn toSlice(v: Version) []const u8 {
        return switch (v) {
            .http10 => "HTTP/1.0",
            .http11 => "HTTP/1.1",
        };
    }
};

fn versionFromSlice(s: []const u8) ?Version {
    if (std.mem.eql(u8, s, "HTTP/1.1")) return .http11;
    if (std.mem.eql(u8, s, "HTTP/1.0")) return .http10;
    return null;
}

/// HTTP/1.1 status code → canonical reason phrase (RFC 7231 §6).
/// Unknown codes fall back to the empty phrase.
pub fn reasonPhrase(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue", 101 => "Switching Protocols",
        200 => "OK", 201 => "Created", 202 => "Accepted",
        204 => "No Content", 206 => "Partial Content",
        301 => "Moved Permanently", 302 => "Found", 304 => "Not Modified",
        307 => "Temporary Redirect", 308 => "Permanent Redirect",
        400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
        404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout",
        409 => "Conflict", 411 => "Length Required", 413 => "Payload Too Large",
        414 => "URI Too Long", 416 => "Range Not Satisfiable",
        500 => "Internal Server Error", 501 => "Not Implemented",
        502 => "Bad Gateway", 503 => "Service Unavailable", 504 => "Gateway Timeout",
        else => "",
    };
}

/// Serialise a header list to HTTP/1.1 wire bytes into `writer`.
/// Original case is preserved (Zigora's `Header.name` already keeps it).
/// ponytail: Pingora keeps two lockstep HMaps; we already store original
/// case in the slice, so this is the one-pass version.
pub fn headersToH1Wire(headers: []const Header, writer: anytype) !void {
    for (headers) |h| {
        try writer.writeAll(h.name);
        try writer.writeAll(": ");
        try writer.writeAll(h.value);
        try writer.writeAll("\r\n");
    }
    try writer.writeAll("\r\n");
}

pub const ResponseHeader = struct {
    status_code: u16,
    version: Version,
    headers: []const Header,
    /// Custom reason phrase; `null` → canonical for `status_code`.
    reason_phrase: ?[]const u8 = null,
    body_start: usize,

    /// Parse an HTTP/1.x response from a raw buffer. Zero-copy slices.
    pub fn parse(buf: []u8) HttpError!ResponseHeader {
        var pos: usize = 0;
        const ver_end = std.mem.indexOfScalarPos(u8, buf, pos, ' ') orelse return error.InvalidRequestLine;
        const version = versionFromSlice(buf[pos..ver_end]) orelse return error.UnsupportedVersion;
        pos = ver_end + 1;

        const code_end = std.mem.indexOfScalarPos(u8, buf, pos, ' ') orelse
            return error.InvalidRequestLine;
        const status_code = std.fmt.parseInt(u16, buf[pos..code_end], 10) catch
            return error.InvalidRequestLine;
        pos = code_end + 1;

        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return error.Incomplete;
        const reason = buf[pos..line_end];
        pos = line_end + 2;

        var headers: [32]Header = undefined;
        var n: usize = 0;
        while (n < headers.len) {
            if (pos + 2 > buf.len) return error.Incomplete;
            if (std.mem.eql(u8, buf[pos..][0..2], "\r\n")) {
                pos += 2;
                break;
            }
            const he = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return error.Incomplete;
            const line = buf[pos..he];
            pos = he + 2;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.HeaderTooLarge;
            const name = std.mem.trimEnd(u8, line[0..colon], " \t");
            var vs = colon + 1;
            while (vs < line.len and (line[vs] == ' ' or line[vs] == '\t')) vs += 1;
            headers[n] = .{ .name = name, .value = line[vs..] };
            n += 1;
        }

        return .{
            .status_code = status_code,
            .version = version,
            .headers = headers[0..n],
            .reason_phrase = if (reason.len > 0) reason else null,
            .body_start = pos,
        };
    }

    /// Serialise the status line + headers to HTTP/1.1 wire bytes.
    pub fn toH1Wire(self: ResponseHeader, writer: anytype) !void {
        try writer.writeAll(self.version.toSlice());
        try writer.writeAll(" ");
        try writer.print("{d} ", .{self.status_code});
        try writer.writeAll(self.reason_phrase orelse reasonPhrase(self.status_code));
        try writer.writeAll("\r\n");
        try headersToH1Wire(self.headers, writer);
    }
};

/// Streaming response event — Pingora's `HttpTask`. Six variants, all
/// pure data. Used by the v0.2 proxy pipe; surfaced now so packages that
/// build on `zigora_http` (proxy, cache) can reference it.
pub const HttpTask = union(enum) {
    /// Response header + end-of-response flag.
    header: struct { hdr: ResponseHeader, end: bool },
    /// Body chunk; `null` body + `true` = trailers-only terminator.
    body: struct { data: ?[]const u8, end: bool },
    /// H1.1 upgraded-protocol body (WebSocket, etc.). v0.2 stub.
    upgraded_body: struct { data: ?[]const u8, end: bool },
    /// HTTP trailer header map. v0.2 stub — stored as raw headers.
    trailer: []const Header,
    /// Response fully sent.
    done,
    /// Read/processing failure; caller owns the message slice.
    failed: []const u8,

    pub fn isEnd(self: HttpTask) bool {
        return switch (self) {
            .header => |h| h.end,
            .body => |b| b.end,
            .upgraded_body => |b| b.end,
            .trailer, .done, .failed => true,
        };
    }
};

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

test "ResponseHeader.parse: 200 OK with headers" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    const r = try ResponseHeader.parse(buf[0..raw.len]);
    try std.testing.expectEqual(@as(u16, 200), r.status_code);
    try std.testing.expectEqual(Version.http11, r.version);
    try std.testing.expectEqualStrings("OK", r.reason_phrase.?);
    try std.testing.expectEqual(@as(usize, 2), r.headers.len);
    try std.testing.expectEqualStrings("Content-Length", r.headers[1].name);
    try std.testing.expectEqualStrings("5", r.headers[1].value);
    try std.testing.expectEqual(@as(usize, raw.len - "hello".len), r.body_start);
}

test "ResponseHeader.parse: empty reason phrase" {
    const raw = "HTTP/1.1 999 \r\n\r\n";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    const r = try ResponseHeader.parse(buf[0..raw.len]);
    try std.testing.expectEqual(@as(u16, 999), r.status_code);
    try std.testing.expect(r.reason_phrase == null);
}

test "ResponseHeader.toH1Wire: round-trip" {
    const raw = "HTTP/1.1 200 OK\r\nHost: x\r\n\r\n";
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..raw.len], raw);
    const r = try ResponseHeader.parse(buf[0..raw.len]);
    var out: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try r.toH1Wire(fbs.writer());
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nHost: x\r\n\r\n", fbs.getWritten());
}

test "headersToH1Wire preserves case" {
    const hs = [_]Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "X-Custom", .value = "yes" },
    };
    var out: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try headersToH1Wire(&hs, fbs.writer());
    try std.testing.expectEqualStrings("Content-Type: text/plain\r\nX-Custom: yes\r\n\r\n", fbs.getWritten());
}

test "reasonPhrase canonical" {
    try std.testing.expectEqualStrings("OK", reasonPhrase(200));
    try std.testing.expectEqualStrings("Not Found", reasonPhrase(404));
    try std.testing.expectEqualStrings("", reasonPhrase(999));
}

test "HttpTask.isEnd" {
    const h: HttpTask = .{ .header = .{ .hdr = .{ .status_code = 200, .version = .http11, .headers = &.{}, .body_start = 0 }, .end = true } };
    try std.testing.expect(h.isEnd());
    const b: HttpTask = .{ .body = .{ .data = "x", .end = false } };
    try std.testing.expect(!b.isEnd());
    try std.testing.expect((@as(HttpTask, .done)).isEnd());
}