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

    // Shared library exposing the C ABI (src/c_api.zig), loadable from Python.
    const shared = b.addLibrary(.{
        .name = "acmedb",
        .root_module = acmedb,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    const test_step = b.step("test", "Run the tests");

    // Unit tests: the `test` blocks next to the code in src/ (private helpers).
    const unit_tests = b.addTest(.{
        .root_module = acmedb,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Suite: tests/ exercises the library through its public API only.
    const suite = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "acmedb", .module = acmedb }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(suite).step);
}
