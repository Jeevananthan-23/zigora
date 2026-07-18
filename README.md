# Zigora

A native Zig port of Cloudflare's [Pingora](https://github.com/cloudflare/pingora) — an HTTP reverse proxy and load balancer framework built without a generic async runtime.

## What ships in v0.1

- `Server.new(conf)` → `addService(proxy_svc)` → `runForever()` lifecycle (Pingora `Server` model).
- `ProxyHttp` trait + `HttpProxy` server app dispatching to a configured upstream.
- Zero-copy HTTP/1.1 request parsing (method, path, version, headers).
- Structured `ZgError` type with source tracking (`Upstream` / `Downstream` / `Internal`).
- Working binary: `curl http://127.0.0.1:8080/` through the proxy to a Python upstream returns `200 OK`.

## Modules

The v0.1 actively implements:

- `zigora_core` — Server, Service, Listeners
- `zigora_proxy` — ProxyHttp trait, HttpProxy app
- `zigora_http` — HTTP/1.1 parser
- `zigora_error` — Error types shared by everything else

The remaining packages (`zigora_tls`, `zigora_lb`, `zigora_cache`, etc.) are reserved for v0.2. See `ARCHITECTURE.md` for the full Pingora mirror module map.

## Build + Run

```bash
git clone https://github.com/Jeevananthan-23/zigora.git
cd zigora

# Build
zig build

# Run (listens on 127.0.0.1:8080, forwards to 127.0.0.1:9000 by default)
zig build run -- --backend 127.0.0.1:9000

# Run tests
zig build test
```

Requires Zig ≥ 0.16.0. No dependencies. Offline builds work out of the box.

## Architecture

The authoritative module map and dependency graph live in `ARCHITECTURE.md`. For development commands and build rules, see `AGENTS.md`.

## License

MIT — see `LICENSE`.