const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modulo unico de acmedb: logica del motor + LMDB vendido (C) enlazado.
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

    // Libreria estatica: el artefacto embeble/exportable (base del wrapper Python).
    const lib = b.addLibrary(.{
        .name = "acmedb",
        .root_module = acmedb,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests: un solo ejecutable que recorre los bloques `test` del modulo.
    const tests = b.addTest(.{
        .root_module = acmedb,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Ejecutar los tests");
    test_step.dependOn(&run_tests.step);
}
