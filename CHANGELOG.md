# Changelog

## v0.1.0 — 2026-07-18

Initial release. Zig port of Cloudflare [Pingora](https://github.com/cloudflare/pingora) HTTP reverse proxy framework.

### Packages shipped (v0.1 surface)

- **zigora-core** — `Server`, `Service<A>`, `Listeners` (TCP only), `ServerApp` vtable, `ServerConf`. Port of `pingora-core`.
- **zigora-proxy** — `ProxyHttp(T)` trait, `HttpProxy(T)`, `http_proxy_service()`. `process_new()` dispatches to the configured upstream. Port of `pingora-proxy`.
- **zigora-http** — Zero-copy HTTP/1.1 `Request` parser (`Method`, `Version`, `Header`). Port of `pingora-http`.
- **zigora-error** — `ZgError` (struct), `ErrorType` (23 variants), `ErrorSource` (`Upstream`/`Downstream`/`Internal`). Port of `pingora-error`.

### Executable

`zigora` binary accepts `--backend host:port` (default `127.0.0.1:9000`), listens on `127.0.0.1:8080`, and proxies HTTP/1.1 requests to the upstream.

### Packages reserved for v0.2

`zigora-lb`, `zigora-cache`, `zigora-tls`, `zigora-limits`, `zigora-metrics`, `zigora-utils` — on-disk stubs exist for forward-compatibility.

### Design notes

- No async runtime port — Zigora uses `std.Io` (`io_uring`/`epoll`) directly.
- No `HTTP/2`, no `TLS`, no `LoadBalancer` selectors.
- Architecture map against Pingora crates: see `ARCHITECTURE.md`.