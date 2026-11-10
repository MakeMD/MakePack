//! MP-C: the few Win32 file/path questions assoc, cli and single share (File.Exists, Directory.Exists,
//! Path.GetFullPath, Path.IsPathRooted, Environment.ProcessPath). No Io needed: plain Win32 calls.
const std = @import("std");
const kit = @import("kit");
const w = kit.w;

const Allocator = std.mem.Allocator;

fn attributes(path: []const u8) ?u32 {
    var buf: [8192]u8 = undefined; // most paths; a longer one (up to 32k characters) goes to the heap
    var bfa = std.heap.BufferFirstAllocator.init(&buf, std.heap.page_allocator);
    const p = kit.win.toW(bfa.allocator(), path) catch return null;
    defer bfa.allocator().free(p);
    const a = w.GetFileAttributesW(p.ptr);
    return if (a == w.INVALID_FILE_ATTRIBUTES) null else a;
}

/// File.Exists: a file (not a folder) is there. Any failure (bad path, no access) = false.
pub fn fileExists(path: []const u8) bool {
    const a = attributes(path) orelse return false;
    return a & w.FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// Directory.Exists
pub fn dirExists(path: []const u8) bool {
    const a = attributes(path) orelse return false;
    return a & w.FILE_ATTRIBUTE_DIRECTORY != 0;
}

/// Path.GetFullPath (GetFullPathNameW, like .NET on Windows): relative to the current directory.
/// error.BadPath where .NET threw (empty string, embedded NUL).
pub fn fullPath(gpa: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return error.BadPath;
    const p = try kit.win.toW(gpa, path);
    defer gpa.free(p);
    var size: u32 = w.MAX_PATH;
    while (true) {
        const buf = try gpa.alloc(u16, size);
        defer gpa.free(buf);
        const n = w.GetFullPathNameW(p.ptr, size, buf.ptr, null);
        if (n == 0) return error.BadPath;
        if (n < size) return kit.win.fromW(gpa, buf[0..n]);
        size = n; // too small: n = the size needed, NUL included
    }
}

/// Path.IsPathRooted: "\x", "/x", "C:x", "C:\x", "\\server\share".
pub fn isRooted(path: []const u8) bool {
    if (path.len >= 1 and (path[0] == '\\' or path[0] == '/')) return true;
    return path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
}

/// Environment.ProcessPath
pub fn exePath(gpa: Allocator) ![]u8 {
    var small: [1024]u16 = undefined; // Assoc asks once per verb: no 64 KB scratch for the usual short path
    var buf: []u16 = &small;
    defer if (buf.len != small.len) gpa.free(buf);
    while (true) {
        const n = w.GetModuleFileNameW(null, buf.ptr, @intCast(buf.len));
        if (n == 0) return error.Unexpected;
        if (n < buf.len) return kit.win.fromW(gpa, buf[0..n]);
        if (buf.len >= 32768) return error.Unexpected;
        buf = try gpa.alloc(u16, 32768); // truncated: a long path
    }
}

/// Path.GetExtension: from the last '.' of the last component; "" when there is none or the dot ends the
/// name. Unlike std's extension, ".bashrc" has the extension ".bashrc" (as in .NET).
pub fn extension(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        switch (path[i]) {
            '.' => return if (i + 1 == path.len) "" else path[i..],
            '\\', '/', ':' => return "",
            else => {},
        }
    }
    return "";
}

/// Path.GetFileName: what follows the last separator ("" for "C:\dir\").
pub fn fileName(path: []const u8) []const u8 {
    const i = std.mem.findLastAny(u8, path, "\\/:") orelse return path;
    return path[i + 1 ..];
}

/// Path.GetDirectoryName of a full path: "C:\a\b.7z" -> "C:\a", "C:\b.7z" -> "C:\" (the root keeps its
/// backslash); null for a root.
pub fn directoryName(path: []const u8) ?[]const u8 {
    const sep = std.mem.findLastAny(u8, path, "\\/") orelse return null;
    if (sep + 1 == path.len) return null; // "C:\" itself
    const root = if (path.len >= 3 and path[1] == ':') @as(usize, 3) else 0;
    return if (sep + 1 <= root) path[0..root] else path[0..sep];
}

const testing = std.testing;

test "path helpers (.NET semantics)" {
    try testing.expectEqualStrings(".7z", extension("C:\\a.b\\x.7z"));
    try testing.expectEqualStrings("", extension("C:\\a.b\\x"));
    try testing.expectEqualStrings("", extension("x."));
    try testing.expectEqualStrings(".bashrc", extension("C:\\u\\.bashrc"));
    try testing.expectEqualStrings("C:\\a", directoryName("C:\\a\\b.7z").?);
    try testing.expectEqualStrings("C:\\", directoryName("C:\\b.7z").?);
    try testing.expect(directoryName("C:\\") == null);
    try testing.expect(isRooted("C:x") and isRooted("\\\\srv\\s") and isRooted("/x") and !isRooted("x\\y") and !isRooted(""));
    try testing.expectError(error.BadPath, fullPath(testing.allocator, ""));
    const exe = try exePath(testing.allocator);
    defer testing.allocator.free(exe);
    try testing.expect(fileExists(exe) and !dirExists(exe) and !fileExists("C:\\") and dirExists("C:\\"));
    const full = try fullPath(testing.allocator, exe);
    defer testing.allocator.free(full);
    try testing.expectEqualStrings(exe, full);
}
