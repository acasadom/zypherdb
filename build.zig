const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single acmedb module: engine logic + vendored LMDB (C) linked in.
    const acmedb = b.addModule("acmedb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    acmedb.addIncludePath(b.path("vendor/lmdb"));
    acmedb.addCSourceFiles(.{
        .files = &.{ "vendor/lmdb/mdb.c", "vendor/lmdb/midl.c" },
        .flags = &.{"-O2"},
    });

    // Static library: the embeddable/exportable artifact (basis of the Python wrapper).
    const lib = b.addLibrary(.{
        .name = "acmedb",
        .root_module = acmedb,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Shared library exposing the C ABI (src/capi.zig), loadable from Python.
    const shared = b.addLibrary(.{
        .name = "acmedb",
        .root_module = acmedb,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    // Tests: a single executable that walks the module's `test` blocks.
    const tests = b.addTest(.{
        .root_module = acmedb,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);
}
