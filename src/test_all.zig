//! zig build test: every package's tests in one binary.
test {
    _ = @import("test_base.zig");
    _ = @import("test_sevenzip.zig");
    _ = @import("test_engine.zig");
    _ = @import("test_platform.zig");
    // the GUI's pure parts (no window): find masks, viewer decoding, 7z header sniffing, the model's helpers
    _ = @import("ui/dlg_find.zig");
    _ = @import("ui/dlg_run.zig");
    _ = @import("ui/dlg_viewer.zig");
    _ = @import("ui/mw_model.zig");
}
