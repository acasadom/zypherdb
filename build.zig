const std = @import("std");

/// The storage engines acmedb can be built with (src/storage/engine/).
const StorageEngine = enum { lmdb, mdbx };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The storage engine under the key-value store (src/storage/engine.zig).
    const storage_engine = b.option(StorageEngine, "storage-engine", "The storage engine: lmdb (default) or mdbx") orelse .lmdb;
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
        .mdbx => {
            acmedb.addIncludePath(b.path("vendor/libmdbx"));
            // Only for Linux targets: see the shim's comment.
            if (target.result.os.tag == .linux) acmedb.addIncludePath(b.path("vendor/shims"));
            // A fixed timestamp keeps builds reproducible (libmdbx would
            // record __DATE__ and __TIME__). No runtime CPU dispatch: it needs
            // `__cpu_model`, which Zig's compiler-rt lacks, and libmdbx uses it
            // only to pick SIMD for its page lists (on macOS it never does);
            // the target's own CPU features apply instead. Debug builds keep
            // libmdbx's cheap checks. Builds with safety checks (Debug,
            // ReleaseSafe) sanitize C code too: they drop the alignment
            // sanitizer, as libmdbx reads and writes unaligned words on
            // purpose where the CPU allows it.
            const common = .{ "-O2", "-DNDEBUG", "-DMDBX_BUILD_SHARED_LIBRARY=0", "-DMDBX_HAVE_BUILTIN_CPU_SUPPORTS=0", "-DMDBX_BUILD_TIMESTAMP=\"unknown\"", "-DMDBX_BUILD_FLAGS=\"acmedb\"" };
            acmedb.addCSourceFiles(.{
                .files = &.{"vendor/libmdbx/mdbx.c"},
                .flags = switch (optimize) {
                    .debug => &(common ++ .{ "-DMDBX_CHECKING=1", "-fno-sanitize=alignment" }),
                    .safe => &(common ++ .{"-fno-sanitize=alignment"}),
                    .fast, .small => &common,
                },
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

    // Fuzzers: `zig build fuzz -- storage|query [--seed N] [--steps N] [--seeds N]`
    // (tests/fuzz/main.zig); `zig build test` runs a few fixed seeds.
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "acmedb", .module = acmedb }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    run_fuzz.addPassthruArgs();
    b.step("fuzz", "Run a fuzzer: zig build fuzz -- storage|query [--seed N] [--steps N] [--seeds N]").dependOn(&run_fuzz.step);

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
