//! Every user-visible string goes through `tr()`: the current language's table, src/i18n/<code>.zig (en.zig holds
//! the type and the notes for translators). The language is kit.i18n's: MAKEKIT_LANG > settings "Language" >
//! the Windows UI language > English. `init()` once at startup, `kit.i18n.apply(...)` again once settings load and
//! whenever the user picks a language; tr() reads it on every call, so the next frame is in the new language.
//! Templates ("{0}".."{9}", the *Fmt keys): `fillZ` (= kit.i18n.fmt), `fill`, `write`. Plurals: `kit.i18n.pick`.
const std = @import("std");
const kit = @import("kit");
const i18n = kit.i18n;
const en = @import("i18n/en.zig");

pub const Strings = en.Strings;

const tables = std.enums.EnumArray(i18n.Lang, *const Strings).init(.{
    .en = &en.t,
    .uk = &@import("i18n/uk.zig").t,
    .pl = &@import("i18n/pl.zig").t,
    .de = &@import("i18n/de.zig").t,
    .es = &@import("i18n/es.zig").t,
    .fr = &@import("i18n/fr.zig").t,
});

/// The current language's strings (one atomic load: fine every frame).
pub fn tr() *const Strings {
    return tables.get(i18n.current());
}

/// A string kept in a comptime table (toolbar, menu lists): `.tbAdd`, looked up by `get` when drawn.
pub const Key = std.meta.FieldEnum(Strings);

pub fn get(k: Key) [:0]const u8 {
    return switch (k) {
        inline else => |f| if (@FieldType(Strings, @tagName(f)) == [:0]const u8) @field(tr(), @tagName(f)) else unreachable,
    };
}

pub const app = "MakePack";

/// The user's number format ("#,0", "0.#"): set by init() from the current culture, as .NET formatting did.
/// Independent of the UI language (a Polish UI on a German Windows still groups numbers the German way).
pub var group_sep: []const u8 = ",";
pub var decimal_sep: []const u8 = ".";

extern "kernel32" fn GetLocaleInfoEx(name: ?[*:0]const u16, lctype: u32, data: ?[*]u16, cch: c_int) callconv(.winapi) c_int;

var sep_buf: [2][16]u8 = undefined;

/// Startup: the language from MAKEKIT_LANG or Windows (settings are not loaded yet) and the number separators.
pub fn init() void {
    i18n.apply(null);
    if (localeText(0x0F, &sep_buf[0])) |s| group_sep = s; // LOCALE_STHOUSAND
    if (localeText(0x0E, &sep_buf[1])) |s| decimal_sep = s; // LOCALE_SDECIMAL
}

fn localeText(lctype: u32, out: *[16]u8) ?[]const u8 {
    var w: [4]u16 = undefined; // separators are at most 3 chars + NUL
    const n = GetLocaleInfoEx(null, lctype, &w, w.len); // null = LOCALE_NAME_USER_DEFAULT
    if (n <= 1) return null;
    return out[0..std.unicode.wtf16LeToWtf8(out, w[0..@intCast(n - 1)])];
}

/// Compression levels, in CompressionLevel order (None, Fast, Low, Normal, High, Ultra).
pub fn levels() [6][:0]const u8 {
    const l = tr().levels;
    return .{ l.none, l.fast, l.low, l.normal, l.high, l.ultra };
}

/// "1 234 теки" | "1,234 folders" (C# FoldersN).
pub fn foldersN(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, tr().foldersN);
}

/// "1 234 файли" | "1,234 files" (C# FilesN).
pub fn filesN(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, tr().filesN);
}

/// "1 234 байти" | "1,234 bytes" (C# Bytes).
pub fn bytes(buf: []u8, n: u64) []const u8 {
    return counted(buf, n, tr().bytesN);
}

fn counted(buf: []u8, n: u64, forms: i18n.Forms) []const u8 {
    var g: [40]u8 = undefined;
    return i18n.fmt(buf, i18n.pick(forms, n), .{group(&g, n)});
}

/// .NET "#,0" / "N0": digits in groups of three with the culture's separator.
pub fn group(buf: *[40]u8, n: u64) []const u8 {
    var digits: [20]u8 = undefined;
    const d: []const u8 = std.mem.print(&digits, "{d}", .{n}) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0) w.writeAll(group_sep) catch {};
        w.writeByte(c) catch {};
    }
    return w.buffered();
}

// ---- templates ----------------------------------------------------------------------------------------

/// A template into `buf`, NUL-terminated for ImGui; cut short on a UTF-8 boundary when it does not fit.
pub const fillZ = i18n.fmt;

/// string.Format for the *Fmt templates onto a writer: "{0}".."{9}" become args[0..] (strings as they are,
/// integers in decimal without grouping, like .NET's default). A placeholder without an argument stays.
pub fn write(w: *std.Io.Writer, template: []const u8, args: anytype) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and std.ascii.isDigit(template[i + 1])) {
            const n = template[i + 1] - '0';
            var found = false;
            inline for (args, 0..) |a, k| {
                if (k == n) {
                    found = true;
                    switch (@typeInfo(@TypeOf(a))) {
                        .int, .comptime_int => try w.print("{d}", .{a}),
                        else => try w.print("{s}", .{a}),
                    }
                }
            }
            if (!found) try w.writeAll(template[i .. i + 3]);
            i += 3;
        } else {
            try w.writeByte(template[i]);
            i += 1;
        }
    }
}

/// `write` into a new allocation (caller frees).
pub fn fill(gpa: std.mem.Allocator, template: []const u8, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    write(&aw.writer, template, args) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// A menu caption without its mnemonic: "Tool&s" -> "Tools", "&&" -> "&".
pub fn plain(buf: []u8, s: []const u8) [:0]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n + 1 < buf.len) : (i += 1) {
        if (s[i] == '&') {
            if (i + 1 < s.len and s[i + 1] == '&') i += 1 else continue;
        }
        buf[n] = s[i];
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

// ---- tests ------------------------------------------------------------------------------------------

const tt = std.testing;

test "every language table: no empty string, English placeholders, the language's plural forms" {
    for (i18n.all) |l| {
        if (i18n.check(Strings, &en.t, tables.get(l), l)) |bad| {
            std.debug.print("{s}.zig: {s}\n", .{ l.code(), bad });
            return error.BadTable;
        }
    }
}

test "switching languages" {
    const saved = i18n.current();
    defer i18n.set(saved);
    i18n.set(.en);
    try tt.expectEqualStrings("Open…", tr().open);
    try tt.expectEqualStrings("Store", levels()[0]);
    try tt.expectEqualStrings("Add", get(.tbAdd));
    i18n.set(.uk);
    try tt.expectEqualStrings("Відкрити…", tr().open);
    try tt.expectEqualStrings("Ультра", levels()[5]);
    try tt.expectEqualStrings("Помилка", tr().@"error");
    try tt.expectEqualStrings("Додати", get(.tbAdd));
    try tt.expectEqualStrings("CRC", tr().crc);
}

test "plural and counted nouns" {
    const saved = .{ i18n.current(), group_sep };
    defer {
        i18n.set(saved[0]);
        group_sep = saved[1];
    }
    var buf: [64]u8 = undefined;
    i18n.set(.en);
    group_sep = ",";
    try tt.expectEqualStrings("1 file", filesN(&buf, 1));
    try tt.expectEqualStrings("1,234,567 bytes", bytes(&buf, 1234567));
    try tt.expectEqualStrings("0 folders", foldersN(&buf, 0));
    i18n.set(.uk);
    group_sep = "\u{00A0}";
    for ([_]u64{ 1, 21, 101 }) |n| try tt.expect(std.mem.endsWith(u8, filesN(&buf, n), " файл"));
    for ([_]u64{ 2, 3, 4, 22, 104 }) |n| try tt.expect(std.mem.endsWith(u8, filesN(&buf, n), " файли"));
    for ([_]u64{ 0, 5, 11, 12, 13, 14, 111, 112 }) |n| try tt.expect(std.mem.endsWith(u8, filesN(&buf, n), " файлів"));
    try tt.expectEqualStrings("12\u{00A0}345 тек", foldersN(&buf, 12345));
    try tt.expectEqualStrings("1 байт", bytes(&buf, 1));
    try tt.expectEqualStrings("3 блоки", fillZ(&buf, i18n.pick(tr().blocksN, 3), .{3}));
    var g: [40]u8 = undefined;
    try tt.expectEqualStrings("999", group(&g, 999));
    try tt.expectEqualStrings("1\u{00A0}000", group(&g, 1000));
}

test "fill templates" {
    const saved = i18n.current();
    defer i18n.set(saved);
    i18n.set(.en);
    const s = try fill(tt.allocator, tr().extractingNofM, .{ 2, @as(u64, 10), "a.7z" });
    defer tt.allocator.free(s);
    try tt.expectEqualStrings("Extracting 2/10: a.7z", s);
    var buf: [16]u8 = undefined;
    try tt.expectEqualStrings("Added: x", fillZ(&buf, tr().addedFmt, .{"x"}));
    const cut = fillZ(&buf, tr().deletedFmt, .{"1234567890"});
    try tt.expect(cut.len <= 15 and std.mem.startsWith(u8, cut, "Deleted: ") and cut.ptr[cut.len] == 0);
    try tt.expectEqualStrings("{0} items", fillZ(&buf, tr().itemsN.other.?, .{})); // a missing arg stays
}

test "plain strips mnemonics" {
    var buf: [32]u8 = undefined;
    try tt.expectEqualStrings("Tools", plain(&buf, "Tool&s"));
    try tt.expectEqualStrings("Файл", plain(&buf, "&Файл"));
    try tt.expectEqualStrings("A&B", plain(&buf, "A&&B"));
}

test "init reads the separators" {
    const saved = .{ i18n.current(), group_sep, decimal_sep };
    defer {
        i18n.set(saved[0]);
        group_sep = saved[1];
        decimal_sep = saved[2];
    }
    init();
    try tt.expect(group_sep.len > 0 and decimal_sep.len > 0);
}
