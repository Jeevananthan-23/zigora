# zigora-error

Port of [pingora-error](https://github.com/cloudflare/pingora/tree/main/pingora-error). Zero-dependency error type with source tracking:

- `ZgError` — struct with `etype`, `esource`, `retry`, `context`
- `Type` — error set: connect failures, protocol errors, IO errors, HTTP status codes, custom
- `Source` — enum: `Upstream`, `Downstream`, `Internal`, `Unset`
- `newUp`, `newDown`, `newIn`, `explain`, `fromZig` constructors

Imports: `std` only.