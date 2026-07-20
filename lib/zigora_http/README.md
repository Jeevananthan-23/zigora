# zigora-http

Port of [pingora-http](https://github.com/cloudflare/pingora/tree/main/pingora-http). v0.1: zero-copy HTTP/1.1 request parser:

- `Request.parse(buf) -> Request` — slices point into `buf`, no allocation
- `Method` — enum: GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH
- `Version` — HTTP/1.0, HTTP/1.1
- `Header` — `{name, value}` pair
- `HttpError` — `InvalidRequestLine`, `UnsupportedVersion`, `HeaderTooLarge`, `Incomplete`

Case-preserving `HeaderMap` (Pingora's `CaseMap`) and `ResponseHeader` are v0.2.

Imports: `std` only.