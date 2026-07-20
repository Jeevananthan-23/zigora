# zigora-core

Port of [pingora-core](https://github.com/cloudflare/pingora/tree/main/pingora-core). v0.1 surface:

- `Server` — process orchestrator, `new()` → `addService()` → `runForever()`
- `Service<A>` — listening service wrapping a `ServerApp` vtable
- `ServerApp` — trait with `process_new(stream) -> ?Stream` (accept → handle → keepalive)
- `Listeners` — TCP endpoint builder: `addTcp("host:port")` → `build(io)`
- `ServerConf` — configuration (threads count, v0.1 minimal)

Imports: `zigora-error`, `zigora-http`.