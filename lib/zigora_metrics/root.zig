//! Prometheus /metrics endpoint + Admin status page for v0.2.
//! See V0.2_ROADMAP.md phase 4.13.
//!
//! Lazy: simple atomic counters + a `GET /metrics` handler that emits
//! Prometheus text format. Admin page is a basic HTML status page.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = @import("zigora-http");

pub const zgmetrics = @This();

/// Global metrics registry — single instance per process.
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},

    connections_accepted: std.atomic.Value(usize) = .{ .raw = 0 },
    connections_active: std.atomic.Value(usize) = .{ .raw = 0 },
    requests_total: std.atomic.Value(usize) = .{ .raw = 0 },
    requests_errors: std.atomic.Value(usize) = .{ .raw = 0 },
    bytes_upstream: std.atomic.Value(usize) = .{ .raw = 0 },
    bytes_downstream: std.atomic.Value(usize) = .{ .raw = 0 },
    upstream_errors: std.atomic.Value(usize) = .{ .raw = 0 },

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Metrics) void {
        _ = self;
    }

    pub fn incAccepted(self: *Metrics) void {
        _ = self.connections_accepted.fetchAdd(1, .monotonic);
    }

    pub fn incActive(self: *Metrics) void {
        _ = self.connections_active.fetchAdd(1, .monotonic);
    }

    pub fn decActive(self: *Metrics) void {
        _ = self.connections_active.fetchSub(1, .monotonic);
    }

    pub fn incRequests(self: *Metrics) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
    }

    pub fn incErrors(self: *Metrics) void {
        _ = self.requests_errors.fetchAdd(1, .monotonic);
    }

    pub fn addUpstreamBytes(self: *Metrics, n: usize) void {
        _ = self.bytes_upstream.fetchAdd(n, .monotonic);
    }

    pub fn addDownstreamBytes(self: *Metrics, n: usize) void {
        _ = self.bytes_downstream.fetchAdd(n, .monotonic);
    }

    pub fn incUpstreamErrors(self: *Metrics) void {
        _ = self.upstream_errors.fetchAdd(1, .monotonic);
    }

    /// Render Prometheus text format into `writer`.
    pub fn renderPrometheus(self: *Metrics, writer: anytype) !void {
        try writer.print("# HELP zigora_connections_accepted Total connections accepted\n", .{});
        try writer.print("# TYPE zigora_connections_accepted counter\n", .{});
        try writer.print("zigora_connections_accepted {}\n", .{self.connections_accepted.load(.monotonic)});

        try writer.print("# HELP zigora_connections_active Currently active connections\n", .{});
        try writer.print("# TYPE zigora_connections_active gauge\n", .{});
        try writer.print("zigora_connections_active {}\n", .{self.connections_active.load(.monotonic)});

        try writer.print("# HELP zigora_requests_total Total HTTP requests proxied\n", .{});
        try writer.print("# TYPE zigora_requests_total counter\n", .{});
        try writer.print("zigora_requests_total {}\n", .{self.requests_total.load(.monotonic)});

        try writer.print("# HELP zigora_requests_errors Total request errors\n", .{});
        try writer.print("# TYPE zigora_requests_errors counter\n", .{});
        try writer.print("zigora_requests_errors {}\n", .{self.requests_errors.load(.monotonic)});

        try writer.print("# HELP zigora_bytes_upstream Total bytes sent to upstream\n", .{});
        try writer.print("# TYPE zigora_bytes_upstream counter\n", .{});
        try writer.print("zigora_bytes_upstream {}\n", .{self.bytes_upstream.load(.monotonic)});

        try writer.print("# HELP zigora_bytes_downstream Total bytes received from upstream\n", .{});
        try writer.print("# TYPE zigora_bytes_downstream counter\n", .{});
        try writer.print("zigora_bytes_downstream {}\n", .{self.bytes_downstream.load(.monotonic)});

        try writer.print("# HELP zigora_upstream_errors Total upstream connection errors\n", .{});
        try writer.print("# TYPE zigora_upstream_errors counter\n", .{});
        try writer.print("zigora_upstream_errors {}\n", .{self.upstream_errors.load(.monotonic)});
    }

    /// Simple HTML admin page.
    pub fn renderAdmin(self: *Metrics, writer: anytype) !void {
        try writer.print(
            \\<!DOCTYPE html>
            <html><head><title>Zigora Admin</title>
            <style>body{font-family:monospace;margin:2rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:0.5rem}</style>
            </head><body>
            <h1>Zigora Admin</h1>
            <table>
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Connections Accepted</td><td>{}</td></tr>
            <tr><td>Active Connections</td><td>{}</td></tr>
            <tr><td>Requests Total</td><td>{}</td></tr>
            <tr><td>Request Errors</td><td>{}</td></tr>
            <tr><td>Upstream Bytes</td><td>{}</td></tr>
            <tr><td>Downstream Bytes</td><td>{}</td></tr>
            <tr><td>Upstream Errors</td><td>{}</td></tr>
            </table>
            <p><a href="/metrics">Prometheus /metrics</a></p>
            </body></html>
            \\,
            .{
                self.connections_accepted.load(.monotonic),
                self.connections_active.load(.monotonic),
                self.requests_total.load(.monotonic),
                self.requests_errors.load(.monotonic),
                self.bytes_upstream.load(.monotonic),
                self.bytes_downstream.load(.monotonic),
                self.upstream_errors.load(.monotonic),
            },
        );
    }
};

/// Handler that serves `/metrics` (Prometheus) and `/admin` (HTML).
pub fn adminHandler(metrics: *Metrics, io: Io, stream: net.Stream, req: http.Request) !void {
    var buf: [4096]u8 = undefined;
    var w = std.io.fixedBufferStream(&buf).writer();

    if (std.mem.eql(u8, req.path, "/metrics")) {
        w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\n\r\n") catch {};
        metrics.renderPrometheus(w) catch {};
    } else if (std.mem.eql(u8, req.path, "/admin")) {
        w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n") catch {};
        metrics.renderAdmin(w) catch {};
    } else {
        w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found") catch {};
    }

    stream.write(io, buf[0..w.bytesWritten]) catch {};
}

// ===== Tests =====

test "Metrics counters increment" {
    var alc = std.testing.allocator;
    var m = Metrics.init(alc);
    defer m.deinit();

    m.incAccepted();
    m.incAccepted();
    m.incActive();
    m.incRequests();
    m.incErrors();

    try std.testing.expectEqual(@as(usize, 2), m.connections_accepted.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), m.connections_active.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), m.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), m.requests_errors.load(.monotonic));
}

test "Prometheus format renders" {
    var alc = std.testing.allocator;
    var m = Metrics.init(alc);
    defer m.deinit();
    m.incAccepted();

    var buf: [1024]u8 = undefined;
    var w = std.io.fixedBufferStream(&buf).writer();
    try m.renderPrometheus(w);
    const out = w.bytesWrittenSlice();

    try std.testing.expect(std.mem.indexOfScalar(u8, out, 'zigora_connections_accepted') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '2') != null); // counter value
}