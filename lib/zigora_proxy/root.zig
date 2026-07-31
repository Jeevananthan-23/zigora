//! Port of pingora-proxy: `ProxyHttp` trait + `HttpProxy` struct.
//! See ARCHITECTURE.md §3 (zigora_proxy section) and V0.2_ROADMAP.md phase 3.10.
//!
//! v0.1 surface: single-fixed-backend splice.
//! v0.2: Session (per-request state), 14-callback vtable, retry loop.
//! v0.2.3: upstream response parsing, max_retries, framework /metrics + /admin,
//! keepalive upstream stream, ConnectionPool integration hook.

const std = @import("std");
const log = std.log.scoped(.proxy);
const Io = std.Io;
const net = std.Io.net;
const core = @import("zigora-core");
const http = @import("zigora-http");
const zgerror = @import("zigora-error");
const pool = @import("zigora-pool");
const Stream = net.Stream;

pub const zgproxy = @This();
pub const Error = zgerror.ZgError;
pub const ServerApp = core.ServerApp;

// ---- v0.1 types (unchanged) ----

pub const Ctx = struct {
    backend_host: []const u8 = "127.0.0.1",
    backend_port: u16 = 9000,
};

pub const HttpPeer = struct {
    host: []const u8,
    port: u16,
};

/// Describes the request body transfer mode for POST/PUT body forwarding.
pub const BodyHint = struct {
    mode: enum { none, content_length, chunked } = .none,
    content_len: u64 = 0,
    body_start: usize = 0,
};

// ---- v0.2 Session ----

/// Per-request state, mirrors `pingora_proxy::Session`.
pub fn Session(comptime C: type) type {
    return struct {
        io: Io,
        stream: Stream,
        request: http.Request,
        response: ?http.ResponseHeader = null,
        peer: HttpPeer,
        retries: usize = 0,
        ctx: C,
        // v0.3: downstream_session, cache, compression ctx, modules ctx
    };
}

// ---- v0.2 ProxyHttp VTable with default-callback surface ----

/// v0.2 callback vtable. Each callback is an optional pointer into the
/// user's implementation struct. Omitted callbacks are pure pass-through
/// (matching Pingora's default behaviour). Only `new_ctx` is required.
pub fn ProxyHttpVTable(comptime T: type, comptime C: type) type {
    return struct {
        new_ctx: *const fn (*T) C,

        upstream_peer: ?*const fn (*T, *Session(C), *C) HttpPeer = null,
        early_request_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        request_filter: ?*const fn (*T, *Session(C), *C) bool = null,
        request_body_filter: ?*const fn (*T, *Session(C), ?[]const u8, bool, *C) anyerror!void = null,
        request_cache_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        proxy_upstream_filter: ?*const fn (*T, *Session(C), *C) bool = null,
        upstream_request_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        upstream_response_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        response_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        response_cache_filter: ?*const fn (*T, *Session(C), *C) anyerror!void = null,
        fail_to_connect: ?*const fn (*T, *Session(C), *C, HttpPeer, anyerror) anyerror!void = null,
        fail_to_proxy: ?*const fn (*T, *Session(C), *C, anyerror) anyerror!void = null,
        error_while_proxy: ?*const fn (*T, *Session(C), *C, anyerror) anyerror!void = null,
        logging: ?*const fn (*T, *Session(C), *C, ?anyerror) void = null,
    };
}

// ---- v0.1 ProxyHttp (unchanged — backward compat) ----

/// `pingora_proxy::ProxyHttp` entry. v0.1 minimum: `newCtx` + `upstreamPeer`.
/// User implements a struct with these methods, then constructs
/// `HttpProxy(MyImpl)` and adds it as a `Service` to the `Server`.
pub fn ProxyHttp(comptime T: type) type {
    return struct {
        pub const CTX = T.CTX;

        pub fn newCtx(self: *T) CTX {
            return T.new_ctx(self);
        }

        pub fn upstreamPeer(self: *T, ctx: *Ctx) HttpPeer {
            return T.upstream_peer(self, ctx);
        }
    };
}

// ---- v0.2 HttpProxy with Pingora filter chain ----

pub const DispatchResult = enum {
    ok,
    failed,
    blocked,
};

/// `pingora_proxy::HttpProxy<SV>` — the `ServerApp` implementation.
pub fn HttpProxy(comptime T: type) type {
    const Vtable = ProxyHttpVTable(T, Ctx);

    return struct {
        inner: *T,
        backend: HttpPeer,
        vtable: Vtable,
        max_retries: usize = 1,
        onUpstreamConnect: ?*const fn (*T) void = null,
        onUpstreamDisconnect: ?*const fn (*T) void = null,
        onUpstreamError: ?*const fn (*T) void = null,
        upstreamBytes: ?*std.atomic.Value(usize) = null,
        downstreamBytes: ?*std.atomic.Value(usize) = null,
        upstream_pool: ?*pool.ConnectionPool(Stream) = null,
        /// Framework-level handler: renders Prometheus metrics → writer. Called
        /// for GET /metrics before upstream dispatch.
        renderMetrics: ?*const fn (*Io.Writer) void = null,
        /// Framework-level handler: renders admin HTML → writer. Called for
        /// GET /admin before upstream dispatch.
        renderAdmin: ?*const fn (*Io.Writer) void = null,

        /// Cache lookup callback. Called before upstream dispatch; returns
        /// cached response bytes (or null) for the given request path.
        cacheLookup: ?*const fn (path: []const u8) ?[]const u8 = null,
        /// Cache put callback. Called after a successful upstream dispatch with
        /// the request path and the raw upstream response bytes (owned by the
        /// caller's stack buffer; the callback must `dupe` if it needs to keep
        /// them past the request).
        cachePut: ?*const fn (path: []const u8, resp: []const u8) void = null,

        const Self = @This();

        pub fn init(impl: *T, backend: HttpPeer) Self {
            var vt: Vtable = .{ .new_ctx = T.new_ctx };
            if (@hasDecl(T, "proxy_upstream_filter")) {
                vt.proxy_upstream_filter = T.proxy_upstream_filter;
            }
            return .{ .inner = impl, .backend = backend, .vtable = vt };
        }

        pub fn initWith(impl: *T, backend: HttpPeer, vt: Vtable) Self {
            return .{ .inner = impl, .backend = backend, .vtable = vt };
        }

        /// Full Pingora lifecycle: parse → filter → framework /metrics|/admin
        /// intercept → retry loop → proxyToH1 → filters → log.
        pub fn process_new(self: *Self, io: Io, stream: Stream, bufs: *core.PerRequestBuffers) error{ProcessFailed}!?Stream {
            const read_buf = &bufs.read;
            const write_buf = &bufs.write;
            @memset(read_buf, 0);
            @memset(write_buf, 0);
            var reader = net.Stream.reader(stream, io, read_buf);
            var writer = net.Stream.writer(stream, io, write_buf);

            const raw = reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return error.ProcessFailed,
            };
            if (raw.len == 0) return null;

            var ctx = ProxyHttp(T).newCtx(self.inner);
            const request = http.Request.parse(read_buf.*[0..raw.len]) catch {
                log.info("proxy: (unparsable request)", .{});
                return error.ProcessFailed;
            };

            // ---- framework /metrics and /admin intercept ----
            if (request.method == .GET) {
                if (std.mem.eql(u8, request.path, "/metrics")) {
                    if (self.renderMetrics) |render| {
                        const wptr = &writer.interface;
                        Io.Writer.writeAll(wptr, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nConnection: close\r\n\r\n") catch {};
                        render(wptr);
                        Io.Writer.flush(wptr) catch {};
                        stream.close(io);
                        return null;
                    }
                } else if (std.mem.eql(u8, request.path, "/admin")) {
                    if (self.renderAdmin) |render| {
                        const wptr = &writer.interface;
                        Io.Writer.writeAll(wptr, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n") catch {};
                        render(wptr);
                        Io.Writer.flush(wptr) catch {};
                        stream.close(io);
                        return null;
                    }
                }
            }

            // ---- cache lookup ----
            if (self.cacheLookup) |lookup| {
                if (lookup(request.path)) |cached| {
                    const wptr = &writer.interface;
                    Io.Writer.writeAll(wptr, cached) catch {};
                    Io.Writer.flush(wptr) catch {};
                    stream.close(io);
                    return null;
                }
            }

            const peer = ProxyHttp(T).upstreamPeer(self.inner, &ctx);
            var session = Session(Ctx){
                .io = io,
                .stream = stream,
                .request = request,
                .peer = peer,
                .ctx = ctx,
            };

            // vtable proxy_upstream_filter — user intercept (replaces old boilerplate)
            if (self.vtable.proxy_upstream_filter) |f| {
                if (!f(self.inner, &session, &ctx)) {
                    log.info("proxy: upstream filter blocked request", .{});
                    return null;
                }
            }

            if (self.vtable.upstream_request_filter) |f| {
                f(self.inner, &session, &ctx) catch return error.ProcessFailed;
            }

            // ---- request body forwarding hint ----
            // ponytail: POST body detection via findHeader crashes on >1st
            // request in concurrent accept path due to stack buffer corruption
            // under std.Io.Threaded scheduling. Disabled until the reader
            // buffer ownership model is fixed.
            const body_hint = BodyHint{};

            // ---- retry loop ----
            var retries: usize = 0;
            while (retries <= self.max_retries) : (retries += 1) {
                if (retries > 0) {
                    session.peer = ProxyHttp(T).upstreamPeer(self.inner, &ctx);
                    session.retries = retries;
                }

                if (self.onUpstreamConnect) |cb| cb(self.inner);
                const result = proxyToH1(io, session.peer.host, session.peer.port, raw, &writer.interface, self.upstreamBytes, self.downstreamBytes, &session, bufs, self.upstream_pool, stream, body_hint);
                if (self.onUpstreamDisconnect) |cb| cb(self.inner);

                if (result == .ok) {
                    break;
                }
                if (self.onUpstreamError) |cb| cb(self.inner);
                if (result == .blocked) return null;
                if (retries == self.max_retries) {
                    if (self.vtable.fail_to_connect) |f| {
                        f(self.inner, &session, &ctx, session.peer, error.ConnectFailed) catch {};
                    }
                    return error.ProcessFailed;
                }
            }

            if (self.vtable.upstream_response_filter) |f| {
                f(self.inner, &session, &ctx) catch {};
            }
            if (self.vtable.response_filter) |f| {
                f(self.inner, &session, &ctx) catch {};
            }

            if (self.vtable.logging) |f| {
                f(self.inner, &session, &ctx, null);
            } else if (session.response) |resp| {
                log.debug("proxy: {s} {s} → {d}", .{ @tagName(request.method), request.path, resp.status_code });
            } else {
                log.debug("proxy: {s} {s}", .{ @tagName(request.method), request.path });
            }

            // ponytail: always close after response until peekGreedy handles
            // keepalive-closed connections without blocking. Re-enable
            // keepalive when the reader can detect TCP RST/FIN.
            stream.close(io);
            return null;
        }

        pub fn cleanup(_: *Self, _: Io) void {}
    };
}

pub fn http_proxy_service(
    comptime T: type,
    name: []const u8,
    impl: *T,
    backend: HttpPeer,
) core.service_mod.Service(HttpProxy(T)) {
    return core.service_mod.Service(HttpProxy(T)).init(name, HttpProxy(T).init(impl, backend));
}

// ---- proxyToH1: upstream dispatch + streaming response ----

/// Connect to upstream, write raw request bytes, stream response back to
/// client. Parses headers first, then streams body chunks directly
/// (no full-buffer copy). Handles Content-Length and chunked encoding.
fn proxyToH1(
    io: Io,
    host: []const u8,
    port: u16,
    client_buf: []const u8,
    client_writer: *Io.Writer,
    upstream_bytes: ?*std.atomic.Value(usize),
    downstream_bytes: ?*std.atomic.Value(usize),
    session_capture: *Session(Ctx),
    bufs: *core.PerRequestBuffers,
    upstream_pool: ?*pool.ConnectionPool(Stream),
    client_stream: Stream,
    body_hint: BodyHint,
) DispatchResult {
    const ip4 = net.Ip4Address.parse(host, port) catch return .failed;
    const addr: net.IpAddress = .{ .ip4 = ip4 };
    const pool_key = ip4AddrKey(ip4);

    var ups: Stream = if (upstream_pool) |p| p.get(pool_key) orelse net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return .failed else net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return .failed;
    var pooled: bool = false;
    defer {
        if (!pooled) ups.close(io);
    }

// send request to upstream (headers + optional body)
    if (client_buf.len > 0) {
        var ups_write_buf: [4096]u8 = undefined;
        var ups_writer = net.Stream.writer(ups, io, &ups_write_buf);

        // write headers only; body handled separately if present
        const head_end = if (body_hint.mode != .none) @min(body_hint.body_start, client_buf.len) else client_buf.len;
        if (head_end > 0) {
            if (upstream_bytes) |ctr| _ = ctr.fetchAdd(head_end, .monotonic);
            ups_writer.interface.writeAll(client_buf[0..head_end]) catch return .failed;
        }

        // forward request body in Content-Length mode
        if (body_hint.mode == .content_length and body_hint.content_len > 0) {
            const rest = client_buf.len - head_end;
            if (rest > 0) {
                ups_writer.interface.writeAll(client_buf[head_end..]) catch return .failed;
                if (upstream_bytes) |ctr| _ = ctr.fetchAdd(rest, .monotonic);
            }

            const total = body_hint.content_len;
            if (rest < total) {
                var remaining: u64 = total - rest;
                var body_read_buf: [4096]u8 = undefined;
                var body_reader = net.Stream.reader(client_stream, io, &body_read_buf);

                while (remaining > 0) {
                    const chunk = body_reader.interface.peekGreedy(@min(remaining, 4096)) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return .failed,
                    };
                    if (chunk.len == 0) break;
                    const n: u64 = @min(chunk.len, remaining);
                    ups_writer.interface.writeAll(chunk[0..n]) catch return .failed;
                    if (upstream_bytes) |ctr| _ = ctr.fetchAdd(n, .monotonic);
                    remaining -= n;
                    _ = body_reader.interface.discard(Io.Limit.limited(n)) catch return .failed;
                }
            }
        }
        // ponytail: chunked transfer-encoding body forwarding not yet
        // implemented; POST with chunked bodies reaches upstream headers-only.
        // Add chunked forwarding when POST body streaming is needed.

        ups_writer.interface.flush() catch return .failed;
    }

    // read upstream response — peek until we have full headers
    var ups_read_buf: [4096]u8 = undefined;
    var ups_reader = net.Stream.reader(ups, io, &ups_read_buf);
    const header_buf = &bufs.header;
    var header_len: usize = 0;

    // accumulate until we find \r\n\r\n (end of headers)
    while (true) {
        const slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return .failed,
        };
        if (slice.len == 0) break;

        const need = header_buf.len - header_len;
        if (need == 0) return .failed; // headers too large

        const n = @min(slice.len, need);
        @memcpy(header_buf.*[header_len..][0..n], slice[0..n]);
        header_len += n;
        _ = ups_reader.interface.discard(Io.Limit.limited(n)) catch return .failed;

        // check if we have complete headers (\r\n\r\n)
        if (header_len >= 4) {
            if (std.mem.eql(u8, header_buf.*[header_len - 4..header_len], "\r\n\r\n")) {
                break;
            }
        }
    }

    if (header_len == 0) return .failed;

    // parse response headers
    const resp = http.ResponseHeader.parse(header_buf.*[0..header_len]) catch {
        // not a valid HTTP response — forward raw and return
        client_writer.writeAll(header_buf.*[0..header_len]) catch return .failed;
        // stream rest
        while (true) {
            const slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return .failed,
            };
            if (slice.len == 0) break;
            client_writer.writeAll(slice) catch return .failed;
            _ = ups_reader.interface.discard(Io.Limit.limited(slice.len)) catch return .failed;
        }
        client_writer.flush() catch return .failed;
        return .ok;
    };

    // store on session for filters + logging
    session_capture.response = resp;

    // write headers to client immediately
    client_writer.writeAll(header_buf.*[0..resp.body_start]) catch return .failed;

    // determine body transfer mode
    const content_length = findHeader(resp.headers, "content-length");
    const transfer_encoding = findHeader(resp.headers, "transfer-encoding");
    const is_chunked = transfer_encoding != null and std.mem.eql(u8, transfer_encoding.?, "chunked");
    const has_content_length = content_length != null;

    var body_remaining: usize = 0;
    if (has_content_length) {
        body_remaining = std.fmt.parseInt(usize, content_length.?, 10) catch 0;
    }

    // stream body
    if (is_chunked) {
        // chunked encoding: read chunk-size + data + CRLF
        var chunk_remaining: usize = 0;
        var reading_chunk_size = true;

        while (true) {
            if (reading_chunk_size) {
                // read chunk size line (hex + \r\n)
                const slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return .failed,
                };
                if (slice.len == 0) break;

                // find end of chunk-size line
                const line_end = std.mem.indexOfPos(u8, slice, 0, "\r\n") orelse {
                    // need more data
                    _ = ups_reader.interface.discard(Io.Limit.limited(slice.len)) catch return .failed;
                    continue;
                };
                const size_line = slice[0..line_end];
                chunk_remaining = std.fmt.parseInt(usize, size_line, 16) catch return .failed;

                const consumed = line_end + 2; // chunk-size + \r\n
                _ = ups_reader.interface.discard(Io.Limit.limited(consumed)) catch return .failed;

                if (chunk_remaining == 0) {
                    // last chunk — read trailers (if any) then final \r\n
                    while (true) {
                        const trailer_slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
                            error.EndOfStream => break,
                            else => return .failed,
                        };
                        if (trailer_slice.len == 0) break;
                        if (std.mem.eql(u8, trailer_slice[0..@min(2, trailer_slice.len)], "\r\n")) {
                            _ = ups_reader.interface.discard(Io.Limit.limited(2)) catch return .failed;
                            break;
                        }
                        _ = ups_reader.interface.discard(Io.Limit.limited(trailer_slice.len)) catch return .failed;
                    }
                    break;
                }
                reading_chunk_size = false;
            } else {
                // read chunk data
                const slice = ups_reader.interface.peekGreedy(chunk_remaining) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return .failed,
                };
                if (slice.len == 0) break;

                const n = @min(slice.len, chunk_remaining);
                client_writer.writeAll(slice[0..n]) catch return .failed;
                if (downstream_bytes) |ctr| _ = ctr.fetchAdd(n, .monotonic);

                chunk_remaining -= n;
                _ = ups_reader.interface.discard(Io.Limit.limited(n)) catch return .failed;

                if (chunk_remaining == 0) {
                    // consume trailing \r\n after chunk
                    const crlf = ups_reader.interface.peekGreedy(2) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return .failed,
                    };
                    if (crlf.len >= 2) {
                        _ = ups_reader.interface.discard(Io.Limit.limited(2)) catch return .failed;
                    }
                    reading_chunk_size = true;
                }
            }
        }
    } else if (has_content_length) {
        // fixed Content-Length: stream exactly body_remaining bytes
        while (body_remaining > 0) {
            const slice = ups_reader.interface.peekGreedy(body_remaining) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return .failed,
            };
            if (slice.len == 0) break;

            const n = @min(slice.len, body_remaining);
            client_writer.writeAll(slice[0..n]) catch return .failed;
            if (downstream_bytes) |ctr| _ = ctr.fetchAdd(n, .monotonic);

            body_remaining -= n;
            _ = ups_reader.interface.discard(Io.Limit.limited(n)) catch return .failed;
        }
    } else {
        // no Content-Length, no chunked — read until EOF (Connection: close)
        while (true) {
            const slice = ups_reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return .failed,
            };
            if (slice.len == 0) break;

            client_writer.writeAll(slice) catch return .failed;
            if (downstream_bytes) |ctr| _ = ctr.fetchAdd(slice.len, .monotonic);

            _ = ups_reader.interface.discard(Io.Limit.limited(slice.len)) catch return .failed;
        }
    }

    client_writer.flush() catch return .failed;

    // pool the upstream connection if pool present and response allows keepalive
    if (upstream_pool) |p| {
        if (session_capture.response) |upstream_resp| {
            const up_conn_hdr = findHeader(upstream_resp.headers, "connection");
            const wants_close = up_conn_hdr != null and std.ascii.eqlIgnoreCase(up_conn_hdr.?, "close");
            if (!wants_close) {
                const meta: pool.ConnectionMeta(Stream) = .{
                    .key = pool_key,
                    .id = ups.socket.handle,
                    .data = ups,
                };
                const evicted = p.put(pool_key, meta);
                if (evicted) |ev| ev.data.close(io);
                pooled = true;
            }
        }
    }

    return .ok;
}

fn findHeader(headers: []const http.Header, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    const lower_first = std.ascii.toLower(name[0]);
    for (headers) |h| {
        if (h.name.len == 0) continue;
        if (std.ascii.toLower(h.name[0]) == lower_first) {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
    }
    return null;
}

fn connectionWantsClose(req: *const http.Request) bool {
    for (req.headers) |h| {
        if (h.name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
            return std.ascii.eqlIgnoreCase(h.value, "close");
        }
    }
    return false;
}

fn ip4AddrKey(ip4: net.Ip4Address) pool.GroupKey {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&ip4.bytes);
    hasher.update(std.mem.asBytes(&ip4.port));
    return hasher.final();
}

// ===== Tests =====

const TestImpl = struct {
    pub const CTX = struct {};

    pub fn new_ctx(_: *TestImpl) CTX {
        return .{};
    }

    pub fn upstream_peer(_: *TestImpl) HttpPeer {
        return .{ .host = "127.0.0.1", .port = 9999 };
    }
};

test "HttpPeer stores host and port" {
    const p: HttpPeer = .{ .host = "10.0.0.1", .port = 8080 };
    try std.testing.expectEqualStrings("10.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
}

test "ProxyHttp newCtx returns context type" {
    var impl = TestImpl{};
    const ctx = ProxyHttp(TestImpl).newCtx(&impl);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(ctx)));
}

test "ProxyHttp upstreamPeer" {
    var impl = TestImpl{};
    const p = ProxyHttp(TestImpl).upstreamPeer(&impl);
    try std.testing.expectEqual(@as(u16, 9999), p.port);
}

test "http_proxy_service builds a Service" {
    var impl = TestImpl{};
    const svc = http_proxy_service(TestImpl, "test_svc", &impl, .{ .host = "127.0.0.1", .port = 9999 });
    try std.testing.expectEqualStrings("test_svc", svc.name);
}

test "HttpProxy.initWith vtable populated" {
    var impl = TestImpl{};
    const hp = HttpProxy(TestImpl).initWith(&impl, .{ .host = "127.0.0.1", .port = 1 }, .{ .new_ctx = TestImpl.new_ctx });
    try std.testing.expect(hp.backend.host[0] != 0); // not default-initialized
}

test "ProxyHttpVTable can be built with only new_ctx" {
    const vt: ProxyHttpVTable(TestImpl, Ctx) = .{ .new_ctx = TestImpl.new_ctx };
    try std.testing.expect(vt.request_filter == null);
    try std.testing.expect(vt.proxy_upstream_filter == null);
}

// --- integration tests ---

test "integration: Session wraps http.Request + peer" {
    var buf: [64]u8 = undefined;
    const raw = "GET /foo HTTP/1.1\r\nHost: x\r\n\r\n";
    @memcpy(buf[0..raw.len], raw);
    const req = try http.Request.parse(buf[0..raw.len]);
    const sess = Session(Ctx){
        .io = undefined,
        .request = req,
        .peer = .{ .host = "x", .port = 80 },
        .ctx = .{},
    };
    try std.testing.expectEqual(http.Method.GET, sess.request.method);
    try std.testing.expectEqualStrings("/foo", sess.request.path);
    try std.testing.expectEqualStrings("x", sess.peer.host);
    try std.testing.expectEqual(@as(usize, 0), sess.retries);
}

test "integration: ProxyHttpVTable all null callbacks — compatible with init" {
    var impl = TestImpl{};
    const vt: ProxyHttpVTable(TestImpl, Ctx) = .{ .new_ctx = TestImpl.new_ctx };
    // no upstream_peer set → should fall through to v0.1 ProxyHttp.upstreamPeer
    const hp = HttpProxy(TestImpl).initWith(&impl, .{ .host = "x", .port = 1 }, vt);
    try std.testing.expectEqualStrings("x", hp.backend.host);
}

test "integration: http_proxy_service builds a Service handle recognized by core.Server" {
    const alc = std.testing.allocator;
    var impl = TestImpl{};
    const svc = http_proxy_service(TestImpl, "int_svc", &impl, .{ .host = "x", .port = 1 });
    try std.testing.expectEqualStrings("int_svc", svc.name);
    var srv = core.Server.new(alc, .{});
    defer srv.services.deinit(alc);
    const SlotWrap = struct {
        fn start(ptr: *anyopaque, _: Io, _: std.mem.Allocator) anyerror!void {
            _ = ptr;
        }
    };
    const handle = try srv.addService(.{ .name = svc.name, .start = SlotWrap.start, .userdata = @ptrCast(&svc) });
    try std.testing.expectEqualStrings("int_svc", handle.name);
    try std.testing.expectEqual(@as(usize, 0), handle.index);
}