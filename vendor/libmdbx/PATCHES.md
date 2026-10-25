# Local changes to libmdbx

`vendor/libmdbx` is the amalgamated source of libmdbx **v0.14.4** (tag `v0.14.4`,
commit `a032e40c1c06eaf695a163cfc32d4a01ffb8b26c`, `git_commit` 716ce9d5 in
`VERSION.json`), taken from the project's GitHub mirror
<https://github.com/Mithril-mine/libmdbx>. Only the files ZypherDB builds or must
redistribute were copied: `mdbx.c`, `mdbx.h`, `mdbx-internals.h`, `ntdll.def`,
`LICENSE`, `NOTICE`, `COPYRIGHT`, `VERSION.json`.

Reapply these changes when upgrading (and drop the ones upstream has fixed).

## 1. macOS: available RAM is read with the 64-bit counter

`mdbx_get_sysraminfo()` calls `host_statistics64(..., HOST_VM_INFO64, ...)` with
`count = HOST_VM_INFO_COUNT` (the size of the 32-bit structure). The kernel
answers `KERN_FAILURE`, so every environment open logs
`mdbx_get_sysraminfo(), rc 45` and the default dirty-page limit of a write
transaction falls back to 1024 pages. The patch uses `HOST_VM_INFO64_COUNT`
with `host_statistics64` (the 32-bit path keeps `HOST_VM_INFO_COUNT`).
Marked `zypherdb patch` in `mdbx.c`. To report upstream.

## Known limits (not patched)

- **Windows on ARM64 does not compile** with Zig (`aarch64-windows-gnu`): libmdbx's SEH
  emulation for MinGW (`mdbx_simple_SEH`) walks the x86 TIB exception chain and sets the `Rip`
  register; ARM64 has neither. Renaming the register would compile but not work. Needs an
  upstream fix, or an MSVC-ABI build of that target.
- Build flags ZypherDB passes (see `build.zig`): `MDBX_HAVE_BUILTIN_CPU_SUPPORTS=0` (Zig's
  compiler-rt has no `__cpu_model`; libmdbx then uses the target's CPU features instead of
  choosing SSE2/AVX2 at runtime for its page lists), a fixed `MDBX_BUILD_TIMESTAMP`, `NDEBUG`.
