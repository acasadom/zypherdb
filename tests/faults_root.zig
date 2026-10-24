//! Fault tests root: built against the acmedb module whose storage engine
//! fails when a test says (build option `fault_injection`, see build.zig).

test {
    _ = @import("storage/fault_injection_test.zig");
}
