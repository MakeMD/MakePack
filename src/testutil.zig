//! Test helpers for every package (skeleton-owned). They encode the safety rules: files only in a fresh
//! %TEMP%\makepack-test-<random> that is removed afterwards, registry only under
//! HKCU\Software\MakePackTest-<random> (never the real Software\Classes / Software\MakePack), settings via
//! MAKEPACK_SETTINGS pointing into the temp dir.
const std = @import("std");
const kit = @import("kit");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TempDir = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute, no trailing backslash.
    path: []u8,

    pub fn init(gpa: Allocator, io: Io) !TempDir {
        const tmp = (try kit.win.getEnv(gpa, "TEMP")) orelse return error.NoTempDir;
        defer gpa.free(tmp);
        const path = try gpa.print("{s}\\makepack-test-{x}", .{ std.mem.trimEnd(u8, tmp, "\\"), random(io) });
        errdefer gpa.free(path);
        try Io.Dir.cwd().createDirPath(io, path);
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    /// `path` + "\" + `sub` (caller frees).
    pub fn join(t: TempDir, sub: []const u8) ![]u8 {
        return std.mem.concat(t.gpa, u8, &.{ t.path, "\\", sub });
    }

    pub fn deinit(t: *TempDir) void {
        Io.Dir.cwd().deleteTree(t.io, t.path) catch {};
        t.gpa.free(t.path);
    }
};

/// "Software\MakePackTest-<random>" under HKCU (caller frees the string and removes the key with
/// `kit.win.deleteKeyTree(.hkcu, key, .default)`).
pub fn regTestKey(gpa: Allocator, io: Io) ![]u8 {
    return gpa.print("Software\\MakePackTest-{x}", .{random(io)});
}

/// SetEnvironmentVariableW for this process (null = remove), e.g. MAKEPACK_SETTINGS.
pub fn setEnv(name: []const u8, value: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const n = try kit.win.toW(fba.allocator(), name);
    const v: ?[*:0]const u16 = if (value) |s| (try kit.win.toW(fba.allocator(), s)).ptr else null;
    if (kit.w.SetEnvironmentVariableW(n.ptr, v) == 0) return error.Unexpected;
}

/// std.testing.refAllDecls that also walks into pub struct/enum/union decls (`depth` levels), so every
/// signature and body of a contract file is compiled even before anything calls it.
pub fn refAllDeep(comptime T: type, comptime depth: u8) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type and depth > 0) switch (@typeInfo(decl)) {
            .@"struct", .@"enum", .@"union" => refAllDeep(decl, depth - 1),
            else => {},
        } else _ = &@field(T, name);
    }
}

fn random(io: Io) u64 {
    var b: [8]u8 = undefined;
    io.random(&b);
    return std.mem.readInt(u64, &b, .little);
}

test "TempDir is fresh, absolute and removed" {
    const io = std.testing.io;
    var t = try TempDir.init(std.testing.allocator, io);
    const p = try t.join("a.txt");
    defer std.testing.allocator.free(p);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "x" });
    const kept = try std.testing.allocator.dupe(u8, t.path);
    defer std.testing.allocator.free(kept);
    try std.testing.expect(std.mem.find(u8, kept, "makepack-test-") != null and Io.Dir.path.isAbsolute(kept));
    t.deinit();
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, kept, .{}));
}
