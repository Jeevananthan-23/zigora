const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One public module; sub-packages import each other by relative path
    // (std-style), so no module graph or import tables are needed.
    const mod = b.addModule("zigora", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zigora",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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

    // --- Examples ---
    const ex_name = "simple_proxy";
    const ex = b.addExecutable(.{
        .name = ex_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ ex_name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigora", .module = mod }},
        }),
    });
    b.installArtifact(ex);
    const run_ex = b.step("example-" ++ ex_name, "Run example: " ++ ex_name);
    const run_ex_cmd = b.addRunArtifact(ex);
    run_ex.dependOn(&run_ex_cmd.step);
    run_ex_cmd.step.dependOn(b.getInstallStep());

    const ex2_name = "load_balancer";
    const ex2 = b.addExecutable(.{
        .name = ex2_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ ex2_name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigora", .module = mod }},
        }),
    });
    b.installArtifact(ex2);

    // --- Tests: the zigora module transitively imports every sub-package,
    // so one test root collects all of their test blocks. The exe tests
    // cover the app wiring itself.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- Benchmarks ---
    const bench_step = b.step("bench", "Run all benchmarks");

    {
        const b_tiny = b.addExecutable(.{
            .name = "bench-tinyufo_perf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("benches/tinyufo_perf.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigora", .module = mod }},
            }),
        });
        const run_tiny = b.addRunArtifact(b_tiny);
        bench_step.dependOn(&run_tiny.step);
        const s_tiny = b.step("bench-tinyufo_perf", "Run tinyufo perf benchmark");
        s_tiny.dependOn(&run_tiny.step);
    }
    {
        const b_lru = b.addExecutable(.{
            .name = "bench-lru",
            .root_module = b.createModule(.{
                .root_source_file = b.path("benches/lru_bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigora", .module = mod }},
            }),
        });
        const run_lru = b.addRunArtifact(b_lru);
        bench_step.dependOn(&run_lru.step);
        const s_lru = b.step("bench-lru", "Run lru benchmark");
        s_lru.dependOn(&run_lru.step);
    }
    {
        const b_ket = b.addExecutable(.{
            .name = "bench-ketama",
            .root_module = b.createModule(.{
                .root_source_file = b.path("benches/ketama_bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigora", .module = mod }},
            }),
        });
        const run_ket = b.addRunArtifact(b_ket);
        bench_step.dependOn(&run_ket.step);
        const s_ket = b.step("bench-ketama", "Run ketama benchmark");
        s_ket.dependOn(&run_ket.step);
    }
    {
        const b_lim = b.addExecutable(.{
            .name = "bench-limits",
            .root_module = b.createModule(.{
                .root_source_file = b.path("benches/limits_bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigora", .module = mod }},
            }),
        });
        const run_lim = b.addRunArtifact(b_lim);
        bench_step.dependOn(&run_lim.step);
        const s_lim = b.step("bench-limits", "Run limits benchmark");
        s_lim.dependOn(&run_lim.step);
    }
}
