const std = @import("std");

// astrod build: one static executable, native-musl by default so `zig build`
// yields a deployable static binary even on a glibc host. Cross builds pass
// -Dtarget=aarch64-linux-musl etc. (docs/06 §3: {x86_64,aarch64}-linux-musl).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        // musl ABI default => fully static link without extra flags.
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The OpenAPI spec lives outside src/, so it cannot be @embedFile'd by
    // relative path (module root escape). An anonymous import maps it into
    // the module; served verbatim at GET /api/v1/openapi.json and parsed by
    // the router conformance test (it is authored in JSON syntax).
    root_module.addAnonymousImport("openapi_spec", .{
        .root_source_file = b.path("api/openapi.yaml"),
    });

    const exe = b.addExecutable(.{
        .name = "astrod",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // main.zig references every module in a `test` block, so one test
    // artifact on the root module runs the whole tree's tests.
    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all module tests");
    test_step.dependOn(&run_tests.step);
}
