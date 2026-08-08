//! Port of pingora-core. v0.1 surface: Server, Service<A>, ServerApp vtable,
//! Listeners (TCP only), Stream alias. Disjoint from `server.zig` (the old
//! echo server) which is being removed; this file is the new home.
//!
//! See docs/ARCHITECTURE.md §3 for the Pingora map.

const std = @import("std");
const log = std.log.scoped(.core);
const Io = std.Io;
const net = std.Io.net;
// v0.2 surfaces structured errors via `zigora-error`; unused in v0.1.

pub const zgcore = @This();
pub const Stream = net.Stream;

// Re-export sub-modules for consumers
pub const listeners_mod = @import("zigora_core/listeners.zig");
pub const Listeners = listeners_mod.Listeners;
pub const service_mod = @import("zigora_core/service.zig");
pub const Service = service_mod.Service;
pub const ServiceHandle = service_mod.ServiceHandle;
pub const ServerApp = service_mod.ServerApp;
pub const server_mod = @import("zigora_core/server.zig");
pub const Server = server_mod.Server;
pub const ServerConf = server_mod.ServerConf;
pub const ExecutionPhase = server_mod.ExecutionPhase;
pub const ShutdownWatch = server_mod.ShutdownWatch;
pub const runtime_mod = @import("zigora_core/runtime.zig");
pub const NoStealRuntime = runtime_mod.NoStealRuntime;