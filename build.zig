const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const error_mod = b.addModule("zigora-error", .{
        .root_source_file = b.path("lib/zigora_error/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const http_mod = b.addModule("zigora-http", .{
        .root_source_file = b.path("lib/zigora_http/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // phase 1 v0.2 packages — no internal deps
    const limits_mod = b.addModule("zigora-limits", .{
        .root_source_file = b.path("lib/zigora_limits/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lru_mod = b.addModule("zigora-lru", .{
        .root_source_file = b.path("lib/zigora_lru/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ketama_mod = b.addModule("zigora-ketama", .{
        .root_source_file = b.path("lib/zigora_ketama/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tinyufo_mod = b.addModule("zigora-tinyufo", .{
        .root_source_file = b.path("lib/zigora_tinyufo/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pool_mod = b.addModule("zigora-pool", .{
        .root_source_file = b.path("lib/zigora_pool/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const memcache_mod = b.addModule("zigora-memory-cache", .{
        .root_source_file = b.path("lib/zigora_memory_cache/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigora-tinyufo", .module = tinyufo_mod },
        },
    });
    const lb_mod = b.addModule("zigora-lb", .{
        .root_source_file = b.path("lib/zigora_lb/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigora-ketama", .module = ketama_mod },
        },
    });

    // core depends on error and http
    const core_mod = b.addModule("zigora-core", .{
        .root_source_file = b.path("lib/zigora_core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigora-error", .module = error_mod },
            .{ .name = "zigora-http", .module = http_mod },
        },
    });

    // proxy depends on core, http, error
    const proxy_mod = b.addModule("zigora-proxy", .{
        .root_source_file = b.path("lib/zigora_proxy/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigora-core", .module = core_mod },
            .{ .name = "zigora-http", .module = http_mod },
            .{ .name = "zigora-error", .module = error_mod },
        },
    });

    // Public library: re-exports all four
    const mod = b.addModule("zigora", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigora-core", .module = core_mod },
            .{ .name = "zigora-http", .module = http_mod },
            .{ .name = "zigora-proxy", .module = proxy_mod },
            .{ .name = "zigora-error", .module = error_mod },
            .{ .name = "zigora-limits", .module = limits_mod },
            .{ .name = "zigora-lru", .module = lru_mod },
            .{ .name = "zigora-ketama", .module = ketama_mod },
            .{ .name = "zigora-tinyufo", .module = tinyufo_mod },
            .{ .name = "zigora-pool", .module = pool_mod },
            .{ .name = "zigora-memory-cache", .module = memcache_mod },
            .{ .name = "zigora-lb", .module = lb_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zigora",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigora", .module = mod },
                .{ .name = "zigora-core", .module = core_mod },
                .{ .name = "zigora-http", .module = http_mod },
                .{ .name = "zigora-proxy", .module = proxy_mod },
                .{ .name = "zigora-error", .module = error_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}