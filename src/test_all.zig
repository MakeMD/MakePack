//! zig build test: every package's tests in one binary.
test {
    _ = @import("test_base.zig");
    _ = @import("test_sevenzip.zig");
    _ = @import("test_engine.zig");
    _ = @import("test_platform.zig");
}
