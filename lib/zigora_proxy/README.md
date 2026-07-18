# zigora-proxy

Port of [pingora-proxy](https://github.com/cloudflare/pingora/tree/main/pingora-proxy). v0.1: minimal proxy dispatch:

- `ProxyHttp(T)` — trait-like generic with `new_ctx()` and `upstream_peer()`
- `HttpProxy(T)` — `ServerApp` implementation that parse/log/forward-to-upstream/splice-back
- `http_proxy_service()` — convenience to build `Service<HttpProxy<T>>`
- `HttpPeer` — upstream host:port

V0.2 adds the full ProxyHttp callback chain (request_filter, response_filter, logging, fail_to_proxy, retry loop).

Imports: `zigora-core`, `zigora-http`, `zigora-error`.