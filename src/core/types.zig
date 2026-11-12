//! Shared data contract (skeleton-owned; package agents read, do not edit): the enums that settings.json and
//! the registry persist, the archive-kind table, CompressOptions/ExtractOptions, Engine.ParseSize and
//! .NET's OrdinalIgnoreCase. settings.zig, engine.zig and assoc.zig all use these, so none of them has to
//! import another package's file. engine.zig re-exports everything here.
//!
//! Persisted enums keep the C# member spelling on purpose: @tagName IS the settings.json value
//! ("SevenZip", "TarGz", "Lzma2") and the registry's QuickFormat value - no mapping table to drift.
const std = @import("std");

// ---- enums (Engine.cs, SevenZipSharp) --------------------------------------------------------------

pub const OverwriteMode = enum { Ask, Overwrite, Skip, Rename };

/// Which extracted files inherit the archive's "from the Internet" mark: none, the risky ones, all.
pub const MotwPolicy = enum { Never, Risky, All };

/// Replace: every file (clashes go to the overwrite mode). Newer: new files and ones newer than on disk.
/// Existing: only files already on disk, and only when the archived copy is newer ("freshen").
pub const UpdateMode = enum { Replace, Newer, Existing };

/// What happens to the archive once everything in it was extracted without an error.
pub const DeleteAfter = enum { Never, Ask, Recycle };

pub const ArchiveKind = enum { SevenZip, Zip, Tar, TarGz, TarBz2, TarXz, GZip, BZip2, XZ, Wim };

/// SevenZipSharp's CompressionLevel (None = Store). The CLI's -m0..-m5 is the backing value.
pub const CompressionLevel = enum(u8) { None, Fast, Low, Normal, High, Ultra };

/// SevenZipSharp's CompressionMethod. TRAP: the zero value is Copy (= no compression); every default in
/// this code base is .Default (the format's own method), exactly as the C# initializers were.
pub const CompressionMethod = enum(u8) { Copy, Deflate, Deflate64, BZip2, Lzma, Lzma2, Ppmd, Default };

/// What 7z.dll writes (SevenZipSharp's OutArchiveFormat), spelled like C#.
pub const OutFormat = enum { SevenZip, Zip, GZip, BZip2, Wim, Tar, XZ };

// ---- the archive kinds we create --------------------------------------------------------------------

/// `multi` false = the format holds exactly one file (gz/bz2/xz). `password` = can be encrypted.
pub const KindInfo = struct { kind: ArchiveKind, name: []const u8, ext: []const u8, format: OutFormat, multi: bool, password: bool };

/// Engine.Kinds, in ArchiveKind order (kind() indexes it).
pub const kinds = [_]KindInfo{
    .{ .kind = .SevenZip, .name = "7z", .ext = ".7z", .format = .SevenZip, .multi = true, .password = true },
    .{ .kind = .Zip, .name = "zip", .ext = ".zip", .format = .Zip, .multi = true, .password = true },
    .{ .kind = .Tar, .name = "tar", .ext = ".tar", .format = .Tar, .multi = true, .password = false },
    .{ .kind = .TarGz, .name = "tar.gz", .ext = ".tar.gz", .format = .GZip, .multi = true, .password = false },
    .{ .kind = .TarBz2, .name = "tar.bz2", .ext = ".tar.bz2", .format = .BZip2, .multi = true, .password = false },
    .{ .kind = .TarXz, .name = "tar.xz", .ext = ".tar.xz", .format = .XZ, .multi = true, .password = false },
    .{ .kind = .GZip, .name = "gz", .ext = ".gz", .format = .GZip, .multi = false, .password = false },
    .{ .kind = .BZip2, .name = "bz2", .ext = ".bz2", .format = .BZip2, .multi = false, .password = false },
    .{ .kind = .XZ, .name = "xz", .ext = ".xz", .format = .XZ, .multi = false, .password = false },
    .{ .kind = .Wim, .name = "wim", .ext = ".wim", .format = .Wim, .multi = true, .password = false },
};

/// Engine.Kind
pub fn kind(k: ArchiveKind) KindInfo {
    return kinds[@backingInt(k)];
}

/// Assoc.All: everything 7z.dll opens, in the order the Associations dialog lists them.
/// Also Engine's "known archive extension" (Nestable, the risky-file list of MotW).
pub const archive_exts = [_][]const u8{
    "7z",   "zip",  "zipx", "jar",  "rar", "tar", "gz",  "tgz", "bz2", "tbz2", "tbz", "xz",
    "txz",  "lzma", "z",    "taz",  "cab", "iso", "wim", "swm", "esd", "arj",  "lzh", "lha",
    "cpio", "rpm",  "deb",  "udeb", "ar",  "xar", "dmg", "vhd", "001", "ova",
};

/// Assoc.Defaults: types a default (non-forced) registration may claim - never .zip/.iso/.cab/.jar.
pub const default_exts = [_][]const u8{
    "7z",  "rar", "tar", "gz",   "tgz", "bz2", "tbz2", "tbz", "xz", "txz", "lzma", "z", "taz",
    "arj", "lzh", "lha", "cpio", "001", "ova",
};

/// Case-insensitive membership in archive_exts / default_exts (`ext` without the dot).
pub fn isArchiveExt(ext: []const u8) bool {
    for (archive_exts) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

// ---- options ----------------------------------------------------------------------------------------

/// How to compress (Engine.cs CompressOptions). A new knob is a field here, not a new parameter.
/// Integer types mirror C# (long/int) so a settings.json the C# build accepted loads here too.
pub const CompressOptions = struct {
    level: CompressionLevel = .Normal,
    /// null = none. Append ignores password and encrypt_headers: the archive keeps its own.
    password: ?[]const u8 = null,
    encrypt_headers: bool = false,
    /// .Default = the format's own (LZMA2 for 7z, Deflate for zip). See Engine.MethodsFor.
    method: CompressionMethod = .Default,
    /// Bytes, 0 = the level's default. LZMA/LZMA2 only.
    dictionary: i64 = 0,
    /// 7z only: 7-Zip's s= value ("off", or a block size like "256m"); null = the level's default.
    solid: ?[]const u8 = null,
    /// 0 = all cores.
    threads: i32 = 0,
    /// 7z only: 7-Zip's f= value ("off", "BCJ2", "ARM64"); null = auto by file type.
    filter: ?[]const u8 = null,
    /// Bytes per part, 0 = one file. Parts are name.001, name.002... (7-Zip's split format).
    volume_size: i64 = 0,
    /// Test the finished archive; a failed test is an error.
    test_after: bool = false,
    /// Send the inputs to the Recycle Bin - only once the archive is written (and tested, if asked).
    delete_sources: bool = false,
    /// 7z only, no volumes: prepend 7-Zip's GUI SFX stub, so the output is a self-extracting .exe.
    sfx: bool = false,
    /// Zip only: the old PKWARE encryption Windows Explorer can open, instead of AES-256.
    zip_crypto: bool = false,
};

/// The extract dialog's choices on top of the overwrite mode (Engine.cs ExtractOptions).
pub const ExtractOptions = struct {
    /// Every file straight into the destination, folders dropped; name clashes go to the overwrite mode.
    no_paths: bool = false,
    update: UpdateMode = .Replace,
    /// Leave a file that failed its check on disk ("Keep broken files"); by default it is removed.
    keep_broken: bool = false,
};

// ---- Engine.ParseSize --------------------------------------------------------------------------------

/// "700 MB", "1,5 ГБ", "4095m", "250000" (bytes) -> bytes; "" -> 0; anything else -> null.
/// Units are binary like 7-Zip's -v; a trailing "(...)" note on a preset is ignored. Like C#, "0" -> null
/// (a size must be >= 1 byte) while "" -> 0 (= no volumes).
pub fn parseSize(text: []const u8) ?i64 {
    const before_paren = if (std.mem.findScalar(u8, text, '(')) |p| text[0..p] else text;
    const t = trimWs(before_paren);
    if (t.len == 0) return 0;
    var i: usize = 0;
    var dots: usize = 0;
    var digits: usize = 0;
    while (i < t.len and (std.ascii.isDigit(t[i]) or t[i] == '.' or t[i] == ',')) : (i += 1) {
        if (t[i] == '.' or t[i] == ',') dots += 1 else digits += 1; // C# Replace(',', '.') first
    }
    if (digits == 0 or dots > 1) return null; // double.TryParse(AllowDecimalPoint) refuses "", ".", "1.2.3"
    var num: [64]u8 = undefined;
    if (i + 2 > num.len) return null;
    var n: usize = 0;
    if (t[0] == '.' or t[0] == ',') {
        num[0] = '0'; // ".5"
        n = 1;
    }
    for (t[0..i]) |c| {
        num[n] = if (c == ',') '.' else c;
        n += 1;
    }
    const value = std.fmt.parseFloat(f64, num[0..n]) catch return null;
    const shift: u6 = unitShift(trimWs(t[i..])) orelse return null;
    const bytes = value * std.math.pow(f64, 2, @floatFromInt(shift));
    if (!(bytes >= 1 and bytes < @as(f64, @floatFromInt(std.math.maxInt(i64))))) return null;
    const whole: i64 = @trunc(bytes); // C# (long)bytes truncates
    return whole;
}

/// "" b б -> 0, k kb к кб -> 10, m mb м мб -> 20, g gb г гб -> 30, t tb т тб -> 40 (any case).
fn unitShift(unit: []const u8) ?u6 {
    var low: [8]u8 = undefined;
    if (unit.len > low.len) return null;
    for (unit, 0..) |c, j| low[j] = std.ascii.toLower(c);
    var u = low[0..unit.len];
    // Cyrillic capitals used in units (U+0410..U+042F, UTF-8 D0 90..D0 AF) -> small letters (+0x20).
    var j: usize = 0;
    while (j + 1 < u.len) : (j += 1) {
        if (u[j] == 0xD0 and u[j + 1] >= 0x90 and u[j + 1] <= 0xAF) {
            const cp: u21 = 0x0410 + @as(u21, u[j + 1] - 0x90) + 0x20; // а..я = U+0430..U+044F
            _ = std.unicode.utf8Encode(cp, u[j..][0..2]) catch return null;
            j += 1;
        }
    }
    u = low[0..unit.len];
    const table = [_]struct { u6, []const []const u8 }{
        .{ 0, &.{ "", "b", "б" } },
        .{ 10, &.{ "k", "kb", "к", "кб" } },
        .{ 20, &.{ "m", "mb", "м", "мб" } },
        .{ 30, &.{ "g", "gb", "г", "гб" } },
        .{ 40, &.{ "t", "tb", "т", "тб" } },
    };
    for (table) |row| for (row[1]) |n| if (std.mem.eql(u8, n, u)) return row[0];
    return null;
}

/// .NET Trim() for what users type: ASCII whitespace plus no-break spaces (U+00A0, U+202F).
pub fn trimWs(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (true) {
        if (a < b and std.ascii.isWhitespace(s[a])) {
            a += 1;
        } else if (b - a >= 2 and std.mem.eql(u8, s[a..][0..2], "\u{00A0}")) {
            a += 2;
        } else if (b - a >= 3 and std.mem.eql(u8, s[a..][0..3], "\u{202F}")) {
            a += 3;
        } else break;
    }
    while (true) {
        if (b > a and std.ascii.isWhitespace(s[b - 1])) {
            b -= 1;
        } else if (b - a >= 2 and std.mem.eql(u8, s[b - 2 .. b], "\u{00A0}")) {
            b -= 2;
        } else if (b - a >= 3 and std.mem.eql(u8, s[b - 3 .. b], "\u{202F}")) {
            b -= 3;
        } else break;
    }
    return s[a..b];
}

// ---- StringComparison.OrdinalIgnoreCase -------------------------------------------------------------

extern "kernel32" fn CompareStringOrdinal(a: [*]const u16, na: c_int, b: [*]const u16, nb: c_int, ignore_case: std.os.windows.BOOL) callconv(.winapi) c_int;

/// .NET's OrdinalIgnoreCase (profile names, paths): Unicode simple case folding via CompareStringOrdinal,
/// so "Бекап" == "бекап" (std.ascii.eqlIgnoreCase would say no). ASCII-only patterns can use std.ascii.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    var buf: [4096]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&buf, std.heap.page_allocator);
    const alloc = bfa.allocator();
    const wa = std.unicode.wtf8ToWtf16LeAlloc(alloc, a) catch return false;
    defer alloc.free(wa);
    const wb = std.unicode.wtf8ToWtf16LeAlloc(alloc, b) catch return false;
    defer alloc.free(wb);
    if (wa.len != wb.len) return false;
    return CompareStringOrdinal(wa.ptr, @intCast(wa.len), wb.ptr, @intCast(wb.len), .TRUE) == 2; // CSTR_EQUAL
}

/// '*' and '?' (one UTF-16 unit), every unit compared OrdinalIgnoreCase ("Їжак" matches "їж*").
pub fn globIgnoreCase(name: []const u16, mask: []const u16) bool {
    var n: usize = 0;
    var m: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (m < mask.len and mask[m] == '*') {
            star = m;
            m += 1;
            mark = n;
        } else if (m < mask.len and (mask[m] == '?' or sameChar(mask[m], name[n]))) {
            n += 1;
            m += 1;
        } else if (star) |s| {
            m = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (m < mask.len and mask[m] == '*') m += 1;
    return m == mask.len;
}

fn sameChar(x: u16, y: u16) bool {
    if (x == y) return true;
    var a = x;
    var b = y;
    return CompareStringOrdinal(@ptrCast(&a), 1, @ptrCast(&b), 1, .TRUE) == 2; // CSTR_EQUAL, ignoring case
}

// ---- tests ------------------------------------------------------------------------------------------

const testing = std.testing;

test "kinds table is in ArchiveKind order" {
    for (kinds, 0..) |k, i| try testing.expectEqual(i, @backingInt(k.kind));
    try testing.expectEqualStrings(".tar.gz", kind(.TarGz).ext);
    try testing.expect(!kind(.XZ).multi and kind(.Zip).password);
    try testing.expect(isArchiveExt("7Z") and !isArchiveExt("txt"));
}

test "parseSize (Engine.ParseSize)" {
    try testing.expectEqual(@as(?i64, 0), parseSize(""));
    try testing.expectEqual(@as(?i64, 0), parseSize("   "));
    try testing.expectEqual(@as(?i64, 700 << 20), parseSize("700 MB (CD)"));
    try testing.expectEqual(@as(?i64, 3 << 29), parseSize("1,5 ГБ"));
    try testing.expectEqual(@as(?i64, 3 << 29), parseSize("1.5gb"));
    try testing.expectEqual(@as(?i64, 4095 << 20), parseSize("4095m"));
    try testing.expectEqual(@as(?i64, 250000), parseSize("250000"));
    try testing.expectEqual(@as(?i64, 64 << 10), parseSize("64 Кб"));
    try testing.expectEqual(@as(?i64, 1 << 40), parseSize("1 T"));
    try testing.expectEqual(@as(?i64, 512), parseSize(".5k"));
    try testing.expectEqual(@as(?i64, 1), parseSize("1.b"));
    try testing.expectEqual(@as(?i64, 100 << 20), parseSize("100\u{00A0}MB"));
    try testing.expectEqual(@as(?i64, null), parseSize("0")); // >= 1 byte, like C#
    try testing.expectEqual(@as(?i64, null), parseSize("mb"));
    try testing.expectEqual(@as(?i64, null), parseSize("1.2.3"));
    try testing.expectEqual(@as(?i64, null), parseSize("5 parsecs"));
    try testing.expectEqual(@as(?i64, null), parseSize("-5m"));
    try testing.expectEqual(@as(?i64, null), parseSize("99999999 TB")); // past long.MaxValue
}

test "eqlIgnoreCase is OrdinalIgnoreCase" {
    try testing.expect(eqlIgnoreCase("Backup", "bACKUP"));
    try testing.expect(eqlIgnoreCase("Бекап Ґ", "бекап ґ"));
    try testing.expect(!eqlIgnoreCase("Бекап", "Бекапи"));
    try testing.expect(!eqlIgnoreCase("a", "b"));
    try testing.expect(eqlIgnoreCase("", ""));
}
