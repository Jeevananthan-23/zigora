//! Port of pingora-error. Carries error type, source, retryability, and
//! context. Zig error sets are flat (no `Box<dyn Error>` chain like Rust),
//! so callers convert Zig errors to `Error` via `Error.fromZig(err)`.

const std = @import("std");

pub const zgerror = @This();

/// Where in the request lifecycle the error originated. Mirrors
/// `pingora_error::ErrorSource`.
pub const Source = enum {
    Upstream,
    Downstream,
    Internal,
    Unset,

    pub fn asStr(s: Source) []const u8 {
        return switch (s) {
            .Upstream => "Upstream",
            .Downstream => "Downstream",
            .Internal => "Internal",
            .Unset => "",
        };
    }
};

/// Subset of pingora-error's ErrorType. Add variants as packages need them.
/// `HTTPStatus(u16)` and `Custom([]const u8)` mirror Pingora's tagged variants.
pub const Type = error{
    // Connect
    ConnectTimedout,
    ConnectRefused,
    ConnectNoRoute,
    TLSHandshakeFailure,
    TLSHandshakeTimedout,
    InvalidCert,
    HandshakeError,
    // Protocol
    InvalidHTTPHeader,
    H1Error,
    H2Error,
    // IO on established connections
    ReadError,
    WriteError,
    ReadTimedout,
    WriteTimedout,
    ConnectionClosed,
    // App-level
    HTTPStatus,
    // File
    FileOpenError,
    FileReadError,
    FileWriteError,
    // Other
    InternalError,
    UnknownError,
    Custom,
};

/// `pingora_error::ErrorType::as_str()` equivalent — short human-readable name.
pub fn typeStr(t: Type) []const u8 {
    return switch (t) {
        .ConnectTimedout => "ConnectTimedout",
        .ConnectRefused => "ConnectRefused",
        .ConnectNoRoute => "ConnectNoRoute",
        .TLSHandshakeFailure => "TLSHandshakeFailure",
        .TLSHandshakeTimedout => "TLSHandshakeTimedout",
        .InvalidCert => "InvalidCert",
        .HandshakeError => "HandshakeError",
        .InvalidHTTPHeader => "InvalidHTTPHeader",
        .H1Error => "H1Error",
        .H2Error => "H2Error",
        .ReadError => "ReadError",
        .WriteError => "WriteError",
        .ReadTimedout => "ReadTimedout",
        .WriteTimedout => "WriteTimedout",
        .ConnectionClosed => "ConnectionClosed",
        .HTTPStatus => "HTTPStatus",
        .FileOpenError => "FileOpenError",
        .FileReadError => "FileReadError",
        .FileWriteError => "FileWriteError",
        .InternalError => "InternalError",
        .UnknownError => "UnknownError",
        .Custom => "Custom",
    };
}

/// The error struct. In Rust this is `pub struct Error { .. }`; in Zig the
/// `Error` name clashes with the built-in error set keywords in some contexts,
/// so this is `ZgError` and re-exported as `zgerror.Error` from callers.
///
/// All fields are plain values or slices. Memory ownership rules:
///   - `context` borrows from the caller (no allocation here). Caller must keep it alive for the
///     Error's lifetime, OR set it to `null`. For owned strings, use `std.heap.PageAllocator`
///     at the process scope and store the slice — YAGNI a generic storage policy for v0.1.
pub const ZgError = struct {
    etype: Type,
    esource: Source = .Unset,
    retry: bool = false,
    context: ?[]const u8 = null,

    pub fn new(t: Type, source: Source) ZgError {
        return .{ .etype = t, .esource = source };
    }

    pub fn newUp(t: Type) ZgError {
        return .{ .etype = t, .esource = .Upstream };
    }

    pub fn newDown(t: Type) ZgError {
        return .{ .etype = t, .esource = .Downstream };
    }

    pub fn newIn(t: Type) ZgError {
        return .{ .etype = t, .esource = .Internal };
    }

    pub fn explain(t: Type, source: Source, ctx: []const u8) ZgError {
        return .{ .etype = t, .esource = source, .context = ctx };
    }

    /// Map any Zig error to a `ZgError` of InternalError type, source=Internal.
    /// Mirrors Pingora's `OrErr::or_err(self, et, context)`.
    pub fn fromZig(_: void, err: anyerror) ZgError {
        // ponytail: ignore err's identity, classify as InternalError. Per-error
        // classification table lands when more packages pin specific Zig errors
        // to specific ErrorTypes — currently every caller already knows the type.
        _ = err;
        return .{ .etype = .InternalError, .esource = .Internal, .context = "zig error" };
    }

    pub fn isUpstream(e: ZgError) bool {
        return e.esource == .Upstream;
    }
    pub fn isDownstream(e: ZgError) bool {
        return e.esource == .Downstream;
    }
    pub fn isInternal(e: ZgError) bool {
        return e.esource == .Internal;
    }

    pub fn summary(e: ZgError, writer: anytype) !void {
        try writer.print("{s} ({s}", .{ typeStr(e.etype), e.esource.asStr() });
        if (e.context) |c| try writer.print(": {s}", .{c});
        try writer.writeByte(')');
    }
};

test "ZgError basic construction" {
    const e = ZgError.newUp(.ConnectRefused);
    try std.testing.expectEqual(Type.ConnectRefused, e.etype);
    try std.testing.expectEqual(Source.Upstream, e.esource);
    try std.testing.expect(e.isUpstream());
    try std.testing.expect(!e.isDownstream());
}

test "ZgError fromZig maps to InternalError" {
    const e = ZgError.fromZig({}, error.OutOfMemory);
    try std.testing.expectEqual(Type.InternalError, e.etype);
    try std.testing.expectEqual(Source.Internal, e.esource);
}

test "ZgError explain carries context" {
    const e = ZgError.explain(.ConnectTimedout, .Upstream, "backend:9000");
    try std.testing.expectEqualStrings("backend:9000", e.context.?);
}

test "Source.asStr" {
    try std.testing.expectEqualStrings("Upstream", Source.Upstream.asStr());
    try std.testing.expectEqualStrings("Downstream", Source.Downstream.asStr());
    try std.testing.expectEqualStrings("Internal", Source.Internal.asStr());
    try std.testing.expectEqualStrings("", Source.Unset.asStr());
}

test "typeStr covers all variants" {
    _ = typeStr(.ConnectTimedout);
    _ = typeStr(.ConnectRefused);
    _ = typeStr(.InvalidHTTPHeader);
    _ = typeStr(.HTTPStatus);
    _ = typeStr(.Custom);
}