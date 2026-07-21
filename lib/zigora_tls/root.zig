//! TLS abstraction for Zigora. v0.2 defines the interface; implementation
//! deferred to v0.3 when a TLS backend (BoringSSL via FFI, or pure Zig)
//! is selected. See V0.2_ROADMAP.md phase 3.11.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Stream = net.Stream;

pub const zgtls = @This();

/// TLS config for a server (cert + key paths).
pub const ServerConfig = struct {
    cert_path: []const u8,
    key_path: []const u8,
    // v0.3: ca_path, verify_client, alpn, etc.
};

/// TLS config for a client (upstream).
pub const ClientConfig = struct {
    ca_path: ?[]const u8 = null,
    // v0.3: cert_path, key_path, verify_hostname, alpn, sni
};

/// Opaque TLS stream. Real implementation wraps a Stream and adds TLS.
pub const TlsStream = opaque {};

/// Result of TLS handshake.
pub const HandshakeResult = union(enum) {
    ok: TlsStream,
    err: anyerror,
};

/// Server-side TLS accept. Wraps a raw Stream and performs handshake.
/// v0.2 stub: returns error.Unimplemented. v0.3: real impl.
pub fn accept(
    raw: Stream,
    io: Io,
    config: ServerConfig,
) HandshakeResult {
    _ = raw;
    _ = io;
    _ = config;
    return error.Unimplemented;
}

/// Client-side TLS connect. Connects to `addr`, wraps in TLS, performs handshake.
/// v0.2 stub: returns error.Unimplemented. v0.3: real impl.
pub fn connect(
    io: Io,
    addr: std.Io.net.IpAddress,
    config: ClientConfig,
) HandshakeResult {
    _ = io;
    _ = addr;
    _ = config;
    return error.Unimplemented;
}

// ===== Tests =====

test "tls stub returns unimplemented" {
    const fake_stream: Stream = undefined;
    const fake_io: Io = undefined;
    try std.testing.expectError(error.Unimplemented, accept(fake_stream, fake_io, .{ .cert_path = "a", .key_path = "b" }));
}