# zigora-tls

Reserved for v0.2. Port of pingora-tls (openssl / boringssl / rustls / s2n-tls). Planned:

- TLS accept/connect using one of four backends (mutually exclusive at build time)
- `tls::accept(stream) -> TlsStream` and `tls::connect(stream, peer) -> TlsStream`
- Config via `ConnectorOptions.ca_file`, cert/key paths, ALPN

Depends on the selected TLS C library (not built by default).