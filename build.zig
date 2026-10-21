const std = @import("std");

/// The storage engines acmedb can be built with (src/storage/engine/).
const StorageEngine = enum { lmdb };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The storage engine under the key-value store (src/storage/engine.zig).
    const storage_engine = b.option(StorageEngine, "storage-engine", "The storage engine (default: lmdb)") orelse .lmdb;
    const build_options = b.addOptions();
    build_options.addOption(StorageEngine, "storage_engine", storage_engine);

    // Single acmedb module: engine logic + the vendored storage engine (C) linked in.
    const acmedb = b.addModule("acmedb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    acmedb.addOptions("build_options", build_options);
    switch (storage_engine) {
        .lmdb => {
            acmedb.addIncludePath(b.path("vendor/lmdb"));
            acmedb.addCSourceFiles(.{
                .files = &.{ "vendor/lmdb/mdb.c", "vendor/lmdb/midl.c" },
                .flags = &.{"-O2"},
            });
        },
    }

    // Static library: the embeddable artifact, with the C ABI of src/c_api.zig.
    const lib = b.addLibrary(.{
        .name = "acmedb",
        .root_module = acmedb,
        .linkage = .static,
    });
    lib.installHeader(b.path("include/acmedb.h"), "acmedb.h");
    b.installArtifact(lib);

    // Shared library with the same C ABI, for C programs and other languages' FFIs.
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

    // The Python extension module (python/native/module.zig), built against
    // the headers of a Python 3.10+ install: `zig build python
    // -Dpython-include=$(python3 -c "import sysconfig; print(sysconfig.get_paths()['include'])")`.
    // It uses the limited API (abi3), so one build serves every Python version.
    if (b.option([]const u8, "python-include", "Python.h directory, to build the Python extension module")) |include| {
        const native_module = b.createModule(.{
            .root_source_file = b.path("python/native/module.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "acmedb", .module = acmedb }},
        });
        const python_api = b.addTranslateC(.{ .root_source_file = b.path("python/native/python.h"), .target = target, .optimize = optimize });
        python_api.addIncludePath(.{ .cwd_relative = include });
        native_module.addImport("python", python_api.createModule());
        const native = b.addLibrary(.{ .name = "_native", .root_module = native_module, .linkage = .dynamic });
        // Python's symbols come from the interpreter that loads the module.
        native.linker_allow_shlib_undefined = true;
        const install_native = b.addInstallFileWithDir(native.getEmittedBin(), .{ .custom = "python" }, "_native.abi3.so");
        b.step("python", "Build the Python extension module into zig-out/python").dependOn(&install_native.step);
    }

    // Benchmark: `zig build bench -Doptimize=ReleaseFast -- --people 100000`.
    const bench = b.addExecutable(.{
        .name = "bench-access-control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/access_control.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "acmedb", .module = acmedb }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Run the access-control benchmark").dependOn(&run_bench.step);
}
