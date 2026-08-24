const std = @import("std");

// cragd build: one static executable, native-musl by default so `zig build`
// yields a deployable static binary even on a glibc host. Cross builds pass
// -Dtarget=aarch64-linux-musl etc. (docs/06 §3: {x86_64,aarch64}-linux-musl).
//
// C dependency: basu (the systemd-free sd-bus extraction, AD-016) is linked
// statically from an extracted apk prefix — see -Dbasu-prefix below. bus.zig
// is the only module that touches its headers.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        // musl ABI default => fully static link without extra flags.
        .default_target = .{ .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Directory holding usr/include/basu/*.h and usr/lib/libbasu.a, produced
    // by extract_cragd_deps in build/lib/cragd.sh (apk extract of the
    // basu-devel + basu-devel-static packages for the target arch). The
    // default points at the conventional x86_64 location so a plain
    // `zig build test` on the build host works with no flags; cross builds
    // pass -Dbasu-prefix=build/state/<arch>/cragd-deps explicitly.
    const basu_prefix = b.option(
        []const u8,
        "basu-prefix",
        "extracted basu apk prefix (usr/include + usr/lib/libbasu.a)",
    ) orelse b.pathFromRoot("../build/state/x86_64/cragd-deps");

    const basu_include: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ basu_prefix, "usr", "include" }),
    };
    const basu_lib: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ basu_prefix, "usr", "lib", "libbasu.a" }),
    };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // basu needs libc (musl provides pthread/rt/m — basu.pc Libs.private
        // lists -pthread -lrt -lm, all inside musl's libc.a).
        .link_libc = true,
    });
    root_module.addIncludePath(basu_include);
    root_module.addObjectFile(basu_lib);
    // The OpenAPI spec lives outside src/, so it cannot be @embedFile'd by
    // relative path (module root escape). An anonymous import maps it into
    // the module; served verbatim at GET /api/v1/openapi.json and parsed by
    // the router conformance test (it is authored in JSON syntax).
    root_module.addAnonymousImport("openapi_spec", .{
        .root_source_file = b.path("api/openapi.yaml"),
    });

    const exe = b.addExecutable(.{
        .name = "cragd",
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
