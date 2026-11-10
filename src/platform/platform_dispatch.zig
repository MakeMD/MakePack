//! MP-C: the GUI-free half of Program.Dispatch / Gather / Extract. Both our own arguments and every forwarded
//! set (single.serve) land in Dispatch on the UI thread; the GUI phase owns the windows each route opens
//! (extract queue + ProgressForm, CompressForm, ConvertForm, MainForm) and RunProfile's overwrite prompt.
const std = @import("std");
const types = @import("../core/types.zig");
const settings = @import("../settings.zig");
const assoc = @import("assoc.zig");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

/// Where Program.Dispatch sends an argument list (slices of the arguments).
pub const Route = union(enum) {
    /// x <archive> [--here | --sub | -o dir]: the extract queue (the whole list; see parseExtractJob).
    extract: []const []const u8,
    /// a --quick <paths>: "Add to name.ext" - gathered, no dialog.
    quick: []const []const u8,
    /// a --profile <name> <paths>: a profile's menu item - gathered, no dialog.
    profile: struct { name: []const u8, paths: []const []const u8 },
    /// a <paths>: the compress dialog (its own 400 ms wait for the siblings).
    add: []const []const u8,
    /// convert <paths>: the convert dialog.
    convert: []const []const u8,
    /// <archive> or nothing: the main window.
    open: ?[]const u8,
};

/// Program.Dispatch's decision table, in its order (so "a --quick" with no paths is an Add of "--quick").
pub fn route(args: []const []const u8) Route {
    const n = args.len;
    if (n > 1 and eql(u8, args[0], "x")) return .{ .extract = args };
    if (n > 2 and eql(u8, args[0], "a") and eql(u8, args[1], "--quick")) return .{ .quick = args[2..] };
    if (n > 3 and eql(u8, args[0], "a") and eql(u8, args[1], "--profile")) return .{ .profile = .{ .name = args[2], .paths = args[3..] } };
    if (n > 1 and eql(u8, args[0], "a")) return .{ .add = args[1..] };
    if (n > 1 and eql(u8, args[0], "convert")) return .{ .convert = args[1..] };
    return .{ .open = if (n > 0) args[0] else null };
}

/// One "x" invocation (Program.Extract's switches; unknown ones are ignored there).
pub const ExtractJob = struct { archive: []const u8, dest: ?[]const u8 = null, here: bool = false, sub: bool = false };

pub fn parseExtractJob(args: []const []const u8) ExtractJob {
    var j: ExtractJob = .{ .archive = args[1] };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (eql(u8, args[i], "--here")) j.here = true else if (eql(u8, args[i], "--sub")) j.sub = true else if (eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            j.dest = args[i];
        }
    }
    return j;
}

/// The key `a --quick` gathers under (a profile can never be named this: no NUL in a name).
pub const quick_key = "\x00quick";

/// Program.QuickProfile: "Add to name.ext" = the format picked in the Associations dialog, the last level used.
pub fn quickProfile(h: assoc.Hive, level: types.CompressionLevel) settings.Profile {
    return .{ .Name = "quick", .Format = assoc.quickKind(h), .Level = level };
}

/// Explorer runs a verb once per selected item: the first call opens a 400 ms window, the siblings that land
/// in it join the same archive (Program.Gather). Keys compare like .NET's OrdinalIgnoreCase (profile names).
/// UI thread only, like C# (Dispatch is marshalled there). ponytail: the caller keeps the clock - it passes
/// `now` (GetTickCount64) and polls takeDue once per frame, instead of a timer per window.
pub const gather_ms = 400;

pub const Gather = struct {
    gpa: Allocator,
    open: std.ArrayList(Batch) = .empty,

    pub const Batch = struct {
        key: []u8,
        paths: std.ArrayList([]u8) = .empty,
        due: u64,

        pub fn deinit(b: *Batch, gpa: Allocator) void {
            for (b.paths.items) |p| gpa.free(p);
            b.paths.deinit(gpa);
            gpa.free(b.key);
        }
    };

    pub fn deinit(g: *Gather) void {
        for (g.open.items) |*b| b.deinit(g.gpa);
        g.open.deinit(g.gpa);
    }

    /// Adds `paths` (copied) under `key`. True = this call opened the window (it closes at now + gather_ms).
    pub fn add(g: *Gather, key: []const u8, paths: []const []const u8, now: u64) !bool {
        var opened = false;
        const b = for (g.open.items) |*b| {
            if (types.eqlIgnoreCase(b.key, key)) break b;
        } else blk: {
            const k = try g.gpa.dupe(u8, key);
            errdefer g.gpa.free(k);
            try g.open.append(g.gpa, .{ .key = k, .due = now + gather_ms });
            opened = true;
            break :blk &g.open.items[g.open.items.len - 1];
        };
        for (paths) |p| {
            const copy = try g.gpa.dupe(u8, p);
            errdefer g.gpa.free(copy);
            try b.paths.append(g.gpa, copy);
        }
        return opened;
    }

    /// The first batch whose window has closed (the caller runs it, then `deinit`s it), or null.
    pub fn takeDue(g: *Gather, now: u64) ?Batch {
        for (g.open.items, 0..) |b, i| if (now >= b.due) return g.open.orderedRemove(i);
        return null;
    }

    /// Program.Busy's share: a window is still open.
    pub fn pending(g: *const Gather) bool {
        return g.open.items.len > 0;
    }
};

const testing = std.testing;

test "route: Program.Dispatch's table" {
    try testing.expectEqual(@as(usize, 3), route(&.{ "x", "a.7z", "--here" }).extract.len);
    try testing.expectEqualStrings("f", route(&.{ "a", "--quick", "f" }).quick[0]);
    const p = route(&.{ "a", "--profile", "Backup", "f", "g" }).profile;
    try testing.expect(eql(u8, p.name, "Backup") and p.paths.len == 2);
    try testing.expectEqualStrings("--profile", route(&.{ "a", "--profile", "Backup" }).add[0]); // no paths: the dialog
    try testing.expectEqualStrings("--quick", route(&.{ "a", "--quick" }).add[0]);
    try testing.expectEqualStrings("f", route(&.{ "convert", "f" }).convert[0]);
    try testing.expectEqualStrings("C:\\a.7z", route(&.{"C:\\a.7z"}).open.?);
    try testing.expect(route(&.{}).open == null);
    try testing.expectEqualStrings("x", route(&.{"x"}).open.?); // a lone verb opens as a file name, as in C#
}

test "parseExtractJob" {
    const j = parseExtractJob(&.{ "x", "C:\\a.7z", "--sub", "-o", "C:\\out", "--here", "-o" });
    try testing.expect(eql(u8, j.archive, "C:\\a.7z") and j.sub and j.here and eql(u8, j.dest.?, "C:\\out"));
}

test "Gather: one window per key (OrdinalIgnoreCase), closes after 400 ms" {
    var g: Gather = .{ .gpa = testing.allocator };
    defer g.deinit();
    try testing.expect(try g.add("Бекап", &.{"C:\\a"}, 1000));
    try testing.expect(!try g.add("бекап", &.{ "C:\\b", "C:\\c" }, 1100)); // a sibling joins
    try testing.expect(try g.add(quick_key, &.{"C:\\q"}, 1150));
    try testing.expect(try g.add("quick", &.{}, 1160)); // a profile named "quick" is not the quick items
    try testing.expect(g.takeDue(1399) == null);
    var b = g.takeDue(1400).?;
    defer b.deinit(testing.allocator);
    try testing.expectEqualStrings("Бекап", b.key);
    try testing.expectEqual(@as(usize, 3), b.paths.items.len);
    try testing.expect(g.takeDue(1400) == null);
    var q = g.takeDue(1550).?;
    defer q.deinit(testing.allocator);
    try testing.expectEqualStrings("C:\\q", q.paths.items[0]);
    try testing.expect(g.pending()); // "quick" (empty) is still open
    var e = g.takeDue(1560).?;
    e.deinit(testing.allocator);
    try testing.expect(!g.pending());
    try testing.expect(try g.add("Бекап", &.{"C:\\d"}, 2000)); // a new window
}
