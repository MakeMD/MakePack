//! test-engine (MP-B owns this file): Engine operations and the selftest. Files only under testutil.TempDir
//! (the engine's own temp dirs: %TEMP%\MakePack\<guid>, removed); Recycle Bin only for files inside it (and put
//! back); the SFX runs on a hidden desktop.
const std = @import("std");
const engine = @import("core/engine.zig");
const selftest = @import("selftest.zig");
const testutil = @import("testutil.zig");

test {
    _ = @import("core/engine.zig");
    _ = @import("selftest.zig");
}

// Every engine check of `MakePack --selftest`, end to end through 7z.dll (the "cli" check included: it drives
// MP-C's cli.run). Silent unless something fails: then the whole log.
test "selftest: all checks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try testutil.TempDir.init(gpa, io);
    defer tmp.deinit();
    const dir = std.Io.Dir.path.dirname(@import("paths").seven_zip_dll).?;
    try engine.init(gpa, io, dir);
    defer engine.deinit(io);
    const root = try tmp.join("selftest");
    defer gpa.free(root);
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    const fails = selftest.runIn(gpa, io, dir, root, &log.writer);
    if (fails != 0) std.debug.print("{s}", .{log.written()});
    try std.testing.expectEqual(@as(u32, 0), fails);
}
