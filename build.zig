const std = @import("std");

/// The storage engines ZypherDB can be built with (src/storage/engine/).
const StorageEngine = enum { lmdb, mdbx };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The storage engine under the key-value store (src/storage/engine.zig).
    const storage_engine = b.option(StorageEngine, "storage-engine", "The storage engine: lmdb (default) or mdbx") orelse .lmdb;

    // Single ZypherDB module: engine logic + the vendored storage engine (C) linked in.
    const zypherdb = zypherdbModule(b, "zypherdb", target, optimize, storage_engine, false);

    // The same module over an engine that fails on purpose
    // (src/storage/engine/faulty.zig), for the fault tests and the fuzzers.
    const zypherdb_with_faults = zypherdbModule(b, null, target, optimize, storage_engine, true);

    // Static library: the embeddable artifact, with the C ABI of src/c_api.zig.
    const lib = b.addLibrary(.{
        .name = "zypherdb",
        .root_module = zypherdb,
        .linkage = .static,
    });
    lib.installHeader(b.path("include/zypherdb.h"), "zypherdb.h");
    b.installArtifact(lib);

    // Shared library with the same C ABI, for C programs and other languages' FFIs.
    const shared = b.addLibrary(.{
        .name = "zypherdb",
        .root_module = zypherdb,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    const test_step = b.step("test", "Run the tests");
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Run only the tests whose name contains this text")) |filter| b.dupeStrings(&.{filter}) else &.{};

    // Unit tests: the `test` blocks next to the code in src/ (private helpers).
    const unit_tests = b.addTest(.{
        .root_module = zypherdb,
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Suite: tests/ exercises the library through its public API only.
    const suite = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zypherdb", .module = zypherdb }},
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(suite).step);

    // Fault tests: the suite's fault-injection test, over the failing engine.
    const fault_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/faults_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zypherdb", .module = zypherdb_with_faults }},
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(fault_tests).step);

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
            // Wheels are built stripped (debug information is most of their size).
            .strip = b.option(bool, "python-strip", "Omit debug information from the Python module"),
            .imports = &.{.{ .name = "zypherdb", .module = zypherdb }},
        });
        const python_api = b.addTranslateC(.{ .root_source_file = b.path("python/native/python.h"), .target = target, .optimize = optimize });
        python_api.addIncludePath(.{ .cwd_relative = include });
        native_module.addImport("python", python_api.createModule());
        const native = b.addLibrary(.{ .name = "_native", .root_module = native_module, .linkage = .dynamic });
        const is_windows = target.result.os.tag == .windows;
        // Declared on every platform (and ignored off Windows), so one command builds everywhere.
        const python_libs = b.option([]const u8, "python-libs", "Directory with python3.lib (Windows only)");
        if (is_windows) {
            // A Windows DLL cannot leave symbols undefined: link the stable-ABI import
            // library (python3.lib, in the `libs` directory of a Python install).
            const libs = python_libs orelse
                @panic("building the Python module for Windows needs -Dpython-libs=<python>/libs");
            native_module.addLibraryPath(.{ .cwd_relative = libs });
            native_module.linkSystemLibrary("python3", .{ .use_pkg_config = .no });
        } else {
            // Python's symbols come from the interpreter that loads the module.
            native.linker_allow_shlib_undefined = true;
        }
        const native_name = if (is_windows) "_native.pyd" else "_native.abi3.so";
        const install_native = b.addInstallFileWithDir(native.getEmittedBin(), .{ .custom = "python" }, native_name);
        b.step("python", "Build the Python extension module into zig-out/python").dependOn(&install_native.step);
    }

    // Fuzzers: `zig build fuzz -- storage|query|faults|crash [--seed N] [--steps N] [--seeds N]`
    // (tests/fuzz/main.zig); `zig build test` runs a few fixed seeds.
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zypherdb", .module = zypherdb_with_faults }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    run_fuzz.addPassthruArgs();
    b.step("fuzz", "Run a fuzzer: zig build fuzz -- storage|query|faults|crash [--seed N] [--steps N] [--seeds N]").dependOn(&run_fuzz.step);

    // Crash tests: the crash fuzzer on fixed seeds (the ones that found its
    // deliberate mutations). It starts the fuzz executable as the writer it
    // kills, so it runs as that program rather than as a test.
    const crash_tests = b.addRunArtifact(fuzz);
    crash_tests.addArgs(&.{ "crash", "--seed", "100", "--seeds", "4", "--steps", "60", "--quiet" });
    test_step.dependOn(&crash_tests.step);

    // Benchmark: `zig build bench -Doptimize=ReleaseFast -- --people 100000`.
    const bench = b.addExecutable(.{
        .name = "bench-access-control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/access_control.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zypherdb", .module = zypherdb }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Run the access-control benchmark").dependOn(&run_bench.step);
}

/// The ZypherDB library over `storage_engine` (its C sources compiled in),
/// wrapped by the fault-injecting engine if `fault_injection`; exported
/// under `name` if one is given.
fn zypherdbModule(b: *std.Build, name: ?[]const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, storage_engine: StorageEngine, fault_injection: bool) *std.Build.Module {
    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const module = if (name) |exported| b.addModule(exported, options) else b.createModule(options);
    const build_options = b.addOptions();
    build_options.addOption(StorageEngine, "storage_engine", storage_engine);
    build_options.addOption(bool, "fault_injection", fault_injection);
    module.addOptions("build_options", build_options);
    // The IANA time zone database, embedded (tools/tzdata.py).
    module.addAnonymousImport("tzdata", .{ .root_source_file = b.path("vendor/tzdata/tzdata.zig") });
    switch (storage_engine) {
        .lmdb => {
            module.addIncludePath(b.path("vendor/lmdb"));
            module.addCSourceFiles(.{
                .files = &.{ "vendor/lmdb/mdb.c", "vendor/lmdb/midl.c" },
                .flags = &.{"-O2"},
            });
        },
        .mdbx => {
            module.addIncludePath(b.path("vendor/libmdbx"));
            // Only for Linux targets: see the shim's comment.
            if (target.result.os.tag == .linux) module.addIncludePath(b.path("vendor/shims"));
            // A fixed timestamp keeps builds reproducible (libmdbx would
            // record __DATE__ and __TIME__). No runtime CPU dispatch: it needs
            // `__cpu_model`, which Zig's compiler-rt lacks, and libmdbx uses it
            // only to pick SIMD for its page lists (on macOS it never does);
            // the target's own CPU features apply instead. Debug builds keep
            // libmdbx's cheap checks. Builds with safety checks (Debug,
            // ReleaseSafe) sanitize C code too: they drop the alignment
            // sanitizer, as libmdbx reads and writes unaligned words on
            // purpose where the CPU allows it.
            const common = .{ "-O2", "-DNDEBUG", "-DMDBX_BUILD_SHARED_LIBRARY=0", "-DMDBX_HAVE_BUILTIN_CPU_SUPPORTS=0", "-DMDBX_BUILD_TIMESTAMP=\"unknown\"", "-DMDBX_BUILD_FLAGS=\"zypherdb\"" };
            module.addCSourceFiles(.{
                .files = &.{"vendor/libmdbx/mdbx.c"},
                .flags = switch (optimize) {
                    .debug => &(common ++ .{ "-DMDBX_CHECKING=1", "-fno-sanitize=alignment" }),
                    .safe => &(common ++ .{"-fno-sanitize=alignment"}),
                    .fast, .small => &common,
                },
            });
        },
    }
    return module;
}
