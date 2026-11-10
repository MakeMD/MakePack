//! test-sevenzip (MP-A owns this file): the 7z.dll binding. 7z.dll path: @import("paths").seven_zip_dll;
//! 7z.exe (@import("paths").seven_zip_exe) is the test oracle, py -3.12 zipfile the ZipCrypto oracle.
//! Files only under testutil.TempDir.
const std = @import("std");
const paths = @import("paths");
const sz = @import("core/sevenzip.zig");
const testutil = @import("testutil.zig");

const testing = std.testing;
const Io = std.Io;
const fspath = Io.Dir.path;

test {
    _ = @import("core/sevenzip.zig");
}

// ---- fixture -------------------------------------------------------------------------------------------

const dirs = [_][]const u8{ "sub", "empty1", "empty1\\empty2", "empty1\\empty2\\empty3" };
const files = [_][]const u8{ "text.txt", "sub\\random.bin", "Їжак ґанок.txt", "empty.txt" };

/// 10 KB text, 1 MB random (seed 20260913), a Cyrillic name, an empty file, nested empty folders.
const Fixture = struct {
    tmp: testutil.TempDir,
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    items: []sz.NewItem,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const io = testing.io;
        try sz.load(paths.seven_zip_dll);
        const fx = try gpa.create(Fixture);
        errdefer gpa.destroy(fx);
        fx.tmp = try testutil.TempDir.init(gpa, io);
        fx.arena = .init(gpa);
        const ar = fx.arena.allocator();
        fx.src = try fx.path("src");
        for (dirs) |d| try Io.Dir.cwd().createDirPath(io, try fx.join(fx.src, d));

        var text: std.ArrayList(u8) = .empty;
        while (text.items.len < 10 * 1024) try text.print(ar, "{d:0>5} The quick brown fox jumps over the lazy dog.\n", .{text.items.len});
        const random = try ar.alloc(u8, 1 << 20);
        var prng: std.Random.DefaultPrng = .init(20260913);
        prng.random().bytes(random);
        const contents = [_][]const u8{ text.items, random, try repeat(ar, "Привіт, світе! Їжак ґанок є.\n", 20), "" };
        for (files, contents) |f, data| try Io.Dir.cwd().writeFile(io, .{ .sub_path = try fx.join(fx.src, f), .data = data });

        fx.items = try ar.alloc(sz.NewItem, dirs.len + files.len);
        for (dirs, fx.items[0..dirs.len]) |d, *it| it.* = .{ .name = d, .source = null };
        for (files, fx.items[dirs.len..]) |f, *it| it.* = .{ .name = f, .source = try fx.join(fx.src, f) };
        return fx;
    }

    fn deinit(fx: *Fixture) void {
        fx.arena.deinit();
        fx.tmp.deinit();
        testing.allocator.destroy(fx);
    }

    /// tmp\<sub> (arena)
    fn path(fx: *Fixture, sub: []const u8) ![]u8 {
        return fx.join(fx.tmp.path, sub);
    }

    fn join(fx: *Fixture, a: []const u8, b: []const u8) ![]u8 {
        return std.mem.concat(fx.arena.allocator(), u8, &.{ a, "\\", b });
    }

    fn read(fx: *Fixture, p: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, p, fx.arena.allocator(), .limited(16 << 20));
    }

    /// Every fixture file under `root` holds the same bytes as the source; every folder exists.
    fn expectTree(fx: *Fixture, root: []const u8) !void {
        for (files) |f| try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, f)), try fx.read(try fx.join(root, f)));
        for (dirs) |d| try testing.expect((try Io.Dir.cwd().statFile(testing.io, try fx.join(root, d), .{})).kind == .directory);
    }
};

/// Sink that extracts into `root` (Engine's job in the app; minimal here).
const ToDir = struct {
    fx: *Fixture,
    root: []const u8,
    /// Name for items without a path (bz2 / xz).
    unnamed: []const u8 = "unnamed",
    done: usize = 0,
    failed: usize = 0,
    first_bad: ?sz.OpResult = null,

    fn sink(t: *ToDir) sz.Sink {
        return .{ .ctx = t, .target = target, .done = onDone };
    }

    fn target(ctx: ?*anyopaque, item: *const sz.Item) anyerror!sz.Target {
        const t: *ToDir = @ptrCast(@alignCast(ctx.?));
        const name = try t.fx.arena.allocator().dupe(u8, if (item.path.len == 0) t.unnamed else item.path);
        std.mem.replaceScalar(u8, name, '/', '\\');
        const p = try t.fx.join(t.root, name);
        if (item.is_dir) {
            try Io.Dir.cwd().createDirPath(testing.io, p);
            return .skip;
        }
        try Io.Dir.cwd().createDirPath(testing.io, fspath.dirname(p).?);
        return .{ .file = p };
    }

    fn onDone(ctx: ?*anyopaque, _: *const sz.Item, r: sz.OpResult) void {
        const t: *ToDir = @ptrCast(@alignCast(ctx.?));
        t.done += 1;
        if (r == .ok) return;
        t.failed += 1;
        if (t.first_bad == null) t.first_bad = r;
    }
};

fn repeat(ar: std.mem.Allocator, s: []const u8, n: usize) ![]u8 {
    const out = try ar.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

fn names(a: *sz.InArchive, ar: std.mem.Allocator) ![]const []const u8 {
    const list = try ar.alloc([]const u8, a.items.len);
    for (a.items, list) |it, *n| {
        const copy = try ar.dupe(u8, it.path);
        std.mem.replaceScalar(u8, copy, '/', '\\');
        n.* = copy;
    }
    std.mem.sortUnstable([]const u8, list, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return list;
}

fn expectNames(a: *sz.InArchive, ar: std.mem.Allocator, want: []const []const u8) !void {
    const sorted = try ar.dupe([]const u8, want);
    std.mem.sortUnstable([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    const got = try names(a, ar);
    try testing.expectEqual(sorted.len, got.len);
    for (sorted, got) |x, y| try testing.expectEqualStrings(x, y);
}

// ---- the oracles ---------------------------------------------------------------------------------------

const Run = struct { ok: bool, out: []const u8 };

fn run(fx: *Fixture, argv: []const []const u8) !Run {
    const r = try std.process.run(testing.allocator, testing.io, .{ .argv = argv });
    defer testing.allocator.free(r.stderr);
    defer testing.allocator.free(r.stdout);
    return .{ .ok = r.term.success(), .out = try fx.arena.allocator().dupe(u8, r.stdout) };
}

/// 7z.exe t (with -p when given): the archive tests clean with 7-Zip itself.
fn oracleTest(fx: *Fixture, arc: []const u8, password: ?[]const u8) !bool {
    const pw = if (password) |p| try std.mem.concat(fx.arena.allocator(), u8, &.{ "-p", p }) else "-p-";
    return (try run(fx, &.{ paths.seven_zip_exe, "t", "-sccUTF-8", pw, arc })).ok;
}

const Listed = struct { path: []const u8, size: []const u8, packed_size: []const u8 };
const Listing = struct { header: std.array_hash_map.String([]const u8), items: []Listed };

/// 7z.exe l -slt: the archive's own header lines and one record per item, in index order.
fn oracleList(fx: *Fixture, arc: []const u8, password: ?[]const u8) !Listing {
    const ar = fx.arena.allocator();
    const pw = if (password) |p| try std.mem.concat(ar, u8, &.{ "-p", p }) else "-p-";
    const r = try run(fx, &.{ paths.seven_zip_exe, "l", "-slt", "-sccUTF-8", pw, arc });
    try testing.expect(r.ok);
    var out: Listing = .{ .header = .empty, .items = &.{} };
    var items: std.ArrayList(Listed) = .empty;
    var in_items = false;
    var cur: ?Listed = null; // one record = a run of "Key = value" lines (bz2/xz items have no Path line)
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "----------")) {
            in_items = true;
            continue;
        }
        const k, const v = std.mem.cut(u8, line, " = ") orelse {
            if (cur) |c| try items.append(ar, c);
            cur = null;
            continue;
        };
        if (!in_items) {
            try out.header.put(ar, k, v);
            continue;
        }
        if (cur == null) cur = .{ .path = "", .size = "", .packed_size = "" };
        if (std.mem.eql(u8, k, "Path")) cur.?.path = v;
        if (std.mem.eql(u8, k, "Size")) cur.?.size = v;
        if (std.mem.eql(u8, k, "Packed Size")) cur.?.packed_size = v;
    }
    if (cur) |c| try items.append(ar, c);
    out.items = items.items;
    return out;
}

/// Our items vs 7-Zip's list: same order, paths, sizes and packed sizes (blank = null).
fn crossCheck(fx: *Fixture, a: *sz.InArchive, arc: []const u8, password: ?[]const u8) !Listing {
    try testing.expect(try oracleTest(fx, arc, password));
    const l = try oracleList(fx, arc, password);
    try testing.expectEqual(a.items.len, l.items.len);
    var buf: [32]u8 = undefined;
    for (a.items, l.items) |it, o| {
        if (it.path.len > 0) try testing.expectEqualStrings(o.path, it.path); // bz2/xz: 7-Zip names it after the archive
        // a size the handler does not know (bz2/xz before decoding) is blank there and 0 here
        if (o.size.len > 0 or it.size != 0) try testing.expectEqualStrings(o.size, try std.mem.print(&buf, "{d}", .{it.size}));
        const ps: []const u8 = if (it.packed_size) |p| try std.mem.print(&buf, "{d}", .{p}) else "";
        try testing.expectEqualStrings(o.packed_size, ps);
    }
    return l;
}

fn py(fx: *Fixture, script: []const u8, args: []const []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(fx.arena.allocator(), &.{ "py", "-3.12", "-I", "-c", script });
    try argv.appendSlice(fx.arena.allocator(), args);
    return run(fx, argv.items);
}

// ---- tests ---------------------------------------------------------------------------------------------

test "load is idempotent" {
    try sz.load(paths.seven_zip_dll);
    try sz.load(paths.seven_zip_dll);
}

test "round trip 7z / zip / tar / wim: create, list, extract, compare, test, 7z.exe cross-check" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();
    const want = try ar.alloc([]const u8, dirs.len + files.len);
    for (fx.items, want) |it, *n| n.* = it.name;

    const cases = [_]struct { fmt: sz.WriteOptions, ext: []const u8, format: sz.Format }{
        .{ .fmt = .{ .format = .SevenZip, .props = &.{ .{ .name = "x", .value = "5" }, .{ .name = "mt", .value = "2" } } }, .ext = "7z", .format = .SevenZip },
        .{ .fmt = .{ .format = .Zip, .props = &.{.{ .name = "x", .value = "9" }} }, .ext = "zip", .format = .Zip },
        .{ .fmt = .{ .format = .Tar }, .ext = "tar", .format = .Tar },
        .{ .fmt = .{ .format = .Wim }, .ext = "wim", .format = .Wim },
    };
    for (cases) |c| {
        const arc = try fx.path(try std.mem.concat(ar, u8, &.{ "rt.", c.ext }));
        var started: usize = 0;
        var opts = c.fmt;
        opts.progress = .{ .ctx = &started, .item = struct {
            fn f(ctx: ?*anyopaque, _: []const u8) void {
                const n: *usize = @ptrCast(@alignCast(ctx.?));
                n.* += 1;
            }
        }.f };
        try sz.create(testing.allocator, arc, fx.items, opts);
        try testing.expect(started >= 3 and started <= files.len); // every file with data; 7z never asks for empty ones

        const a = try sz.InArchive.open(testing.allocator, arc, null);
        defer a.close();
        try testing.expectEqual(c.format, a.props.format);
        try expectNames(a, ar, want);
        for (a.items, 0..) |it, i| {
            try testing.expectEqual(@as(u32, @intCast(i)), it.index);
            try testing.expect(!it.encrypted);
        }

        const out = try fx.path(try std.mem.concat(ar, u8, &.{ "out-", c.ext }));
        var sink: ToDir = .{ .fx = fx, .root = out };
        try a.extract(null, sink.sink());
        try testing.expectEqual(files.len, sink.done);
        try fx.expectTree(out);

        var checked: ToDir = .{ .fx = fx, .root = out };
        try a.check(null, checked.sink());
        try testing.expectEqual(a.items.len, checked.done);
        try testing.expectEqual(0, checked.failed);
        _ = try crossCheck(fx, a, arc, null);
    }
}

test "round trip gz / bz2 / xz (one file), selected index, writer target" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();
    const random = try fx.read(try fx.join(fx.src, "sub\\random.bin"));
    const one = [_]sz.NewItem{.{ .name = "random.bin", .source = try fx.join(fx.src, "sub\\random.bin") }};
    const cases = [_]struct { fmt: @import("core/types.zig").OutFormat, ext: []const u8, format: sz.Format }{
        .{ .fmt = .GZip, .ext = "gz", .format = .GZip },
        .{ .fmt = .BZip2, .ext = "bz2", .format = .BZip2 },
        .{ .fmt = .XZ, .ext = "xz", .format = .XZ },
    };
    for (cases) |c| {
        const arc = try fx.path(try std.mem.concat(ar, u8, &.{ "random.bin.", c.ext }));
        try sz.create(testing.allocator, arc, &one, .{ .format = c.fmt, .props = &.{.{ .name = "x", .value = "1" }} });
        const a = try sz.InArchive.open(testing.allocator, arc, null);
        defer a.close();
        try testing.expectEqual(c.format, a.props.format);
        try testing.expectEqual(1, a.items.len);
        if (c.format == .GZip) try testing.expectEqualStrings("random.bin", a.items[0].path);

        const out = try fx.path(try std.mem.concat(ar, u8, &.{ "out-", c.ext }));
        var sink: ToDir = .{ .fx = fx, .root = out, .unnamed = "random.bin" };
        try a.extract(&.{0}, sink.sink());
        try testing.expectEqualSlices(u8, random, try fx.read(try fx.join(out, "random.bin")));

        // Target.writer: straight into memory (Engine: nested .tar, the viewer)
        var mem: Io.Writer.Allocating = .init(testing.allocator);
        defer mem.deinit();
        const Mem = struct {
            fn target(ctx: ?*anyopaque, _: *const sz.Item) anyerror!sz.Target {
                return .{ .writer = @ptrCast(@alignCast(ctx.?)) };
            }
        };
        try a.extract(null, .{ .ctx = &mem.writer, .target = Mem.target });
        try testing.expectEqualSlices(u8, random, mem.written());
        _ = try crossCheck(fx, a, arc, null);
    }
}

test "7z password: data only and data + headers (he=on), wrong / missing password" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();
    const pw = "пароль-Їжак 1"; // non-ASCII: proves the BSTR is the UTF-16 7-Zip itself uses

    // data only: the list is readable, every file is encrypted
    const data = try fx.path("data.7z");
    try sz.create(testing.allocator, data, fx.items, .{ .format = .SevenZip, .password = pw });
    {
        const a = try sz.InArchive.open(testing.allocator, data, null);
        defer a.close();
        for (a.items) |it| try testing.expectEqual(!it.is_dir and it.size > 0, it.encrypted);
        var s1: ToDir = .{ .fx = fx, .root = try fx.path("x1") };
        try testing.expectError(error.PasswordNeeded, a.check(null, s1.sink()));
    }
    {
        const a = try sz.InArchive.open(testing.allocator, data, "wrong");
        defer a.close();
        var s2: ToDir = .{ .fx = fx, .root = try fx.path("x2") };
        // 7z.dll says kDataError / kCRCError for a wrong key on 7z bodies: an encrypted item makes it WrongPassword
        try testing.expectError(error.WrongPassword, a.check(null, s2.sink()));
        try testing.expect(s2.failed > 0 and (s2.first_bad == .data_error or s2.first_bad == .crc_error));
    }
    {
        const a = try sz.InArchive.open(testing.allocator, data, ""); // "" = no password (C# IsNullOrEmpty)
        defer a.close();
        try testing.expect(a.password == null);
        var s5: ToDir = .{ .fx = fx, .root = try fx.path("x5") };
        try testing.expectError(error.PasswordNeeded, a.check(null, s5.sink()));
    }
    {
        const a = try sz.InArchive.open(testing.allocator, data, pw);
        defer a.close();
        const out = try fx.path("x3");
        var s3: ToDir = .{ .fx = fx, .root = out };
        try a.extract(null, s3.sink());
        try fx.expectTree(out);
        _ = try crossCheck(fx, a, data, pw);
    }

    // data + headers: nothing without the password
    const both = try fx.path("both.7z");
    try sz.create(testing.allocator, both, fx.items, .{ .format = .SevenZip, .password = pw, .props = &.{.{ .name = "he", .value = "on" }} });
    try testing.expectError(error.PasswordNeeded, sz.InArchive.open(testing.allocator, both, null));
    try testing.expectError(error.PasswordNeeded, sz.InArchive.open(testing.allocator, both, ""));
    try testing.expectError(error.WrongPassword, sz.InArchive.open(testing.allocator, both, "wrong"));
    // create with "": no encryption at all
    const plain = try fx.path("plain.7z");
    try sz.create(testing.allocator, plain, fx.items, .{ .format = .SevenZip, .password = "" });
    {
        const p = try sz.InArchive.open(testing.allocator, plain, null);
        defer p.close();
        for (p.items) |it| try testing.expect(!it.encrypted);
    }
    try testing.expect(!try oracleTest(fx, both, "wrong"));
    const a = try sz.InArchive.open(testing.allocator, both, pw);
    defer a.close();
    try expectNames(a, ar, &(dirs ++ files));
    var s4: ToDir = .{ .fx = fx, .root = try fx.path("x4") };
    try a.check(null, s4.sink());
    _ = try crossCheck(fx, a, both, pw);
}

test "zip encryption: AES-256 and ZipCrypto (Python zipfile reads only ZipCrypto)" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const pw = "zip-Pass_42";
    const verify =
        \\import zipfile, sys, os
        \\z = zipfile.ZipFile(sys.argv[1])
        \\z.setpassword(sys.argv[2].encode())
        \\for n in z.namelist():
        \\    if n.endswith('/'): continue
        \\    with open(os.path.join(sys.argv[3], n.replace('/', os.sep)), 'rb') as f:
        \\        assert f.read() == z.read(n), n
        \\print('OK', len(z.namelist()))
    ;
    for ([_][]const u8{ "AES256", "ZipCrypto" }) |em| {
        const arc = try fx.path(try std.mem.concat(fx.arena.allocator(), u8, &.{ em, ".zip" }));
        const aes = std.mem.eql(u8, em, "AES256");
        // AES-256 is the default with a password (C# Pack/Edit): no "em" needed for it
        const props: []const sz.Prop = if (aes) &.{} else &.{.{ .name = "em", .value = em }};
        try sz.create(testing.allocator, arc, fx.items, .{ .format = .Zip, .password = pw, .props = props });
        {
            const a = try sz.InArchive.open(testing.allocator, arc, null);
            defer a.close();
            for (a.items) |it| if (!it.is_dir and it.size > 0) {
                try testing.expect(it.encrypted);
                try testing.expect((std.mem.find(u8, it.method, "AES") != null) == aes);
            };
            var s1: ToDir = .{ .fx = fx, .root = try fx.path("n") };
            try testing.expectError(error.PasswordNeeded, a.check(null, s1.sink()));
        }
        {
            const a = try sz.InArchive.open(testing.allocator, arc, "not-it");
            defer a.close();
            var s2: ToDir = .{ .fx = fx, .root = try fx.path("w") };
            try testing.expectError(error.WrongPassword, a.check(null, s2.sink()));
        }
        const a = try sz.InArchive.open(testing.allocator, arc, pw);
        defer a.close();
        const out = try fx.path(try std.mem.concat(fx.arena.allocator(), u8, &.{ "out-", em }));
        var s3: ToDir = .{ .fx = fx, .root = out };
        try a.extract(null, s3.sink());
        try fx.expectTree(out);
        _ = try crossCheck(fx, a, arc, pw);
        const r = try py(fx, verify, &.{ arc, pw, fx.src });
        try testing.expectEqual(!aes, r.ok); // zipfile has no AES: it refuses exactly the AES archive

        if (!aes) continue;
        // appending without o.password: the new file gets the archive's password AND AES (C# Edit), never ZipCrypto
        const added = try fx.path("added.txt");
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = added, .data = "appended\n" });
        var changes: std.ArrayList(sz.Change) = .empty;
        for (a.items) |it| try changes.append(fx.arena.allocator(), .{ .keep = it.index });
        try changes.append(fx.arena.allocator(), .{ .add = .{ .name = "added.txt", .source = added } });
        const next = try fx.path("AES256-next.zip");
        try sz.update(a, next, changes.items, .{ .format = .Zip });
        const b = try sz.InArchive.open(testing.allocator, next, pw);
        defer b.close();
        for (b.items) |it| if (!it.is_dir and it.size > 0) {
            try testing.expect(it.encrypted);
            try testing.expect(std.mem.find(u8, it.method, "AES") != null);
        };
        _ = try crossCheck(fx, b, next, pw);
    }

    // a non-ASCII zip password: 7z.dll refuses it in both modes (E_INVALIDARG, measured: zip has no portable
    // password encoding) -> InvalidOption, nothing written. Engine must say so (7z takes any password).
    for ([_][]const u8{ "ZipCrypto", "AES256" }) |em| {
        const bad = try fx.path(try std.mem.concat(fx.arena.allocator(), u8, &.{ "cyr-", em, ".zip" }));
        try testing.expectError(error.InvalidOption, sz.create(testing.allocator, bad, fx.items, .{ .format = .Zip, .password = "Пароль-Ґ", .props = &.{.{ .name = "em", .value = em }} }));
        try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, bad, .{}));
    }
}

test "corrupt archives: truncated 7z, flipped data byte, not an archive" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const io = testing.io;
    const arc = try fx.path("good.7z");
    try sz.create(testing.allocator, arc, fx.items, .{ .format = .SevenZip, .props = &.{ .{ .name = "s", .value = "off" }, .{ .name = "x", .value = "1" } } });
    const bytes = try fx.read(arc);

    const cut = try fx.path("cut.7z");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cut, .data = bytes[0 .. bytes.len / 2] });
    try testing.expectError(error.Damaged, sz.InArchive.open(testing.allocator, cut, null));

    const flipped = try fx.path("flipped.7z");
    const copy = try fx.arena.allocator().dupe(u8, bytes);
    copy[bytes.len / 2] ^= 0x55; // inside random.bin's packed stream (s=off: one stream per file)
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = flipped, .data = copy });
    {
        const a = try sz.InArchive.open(testing.allocator, flipped, null);
        defer a.close();
        var s: ToDir = .{ .fx = fx, .root = try fx.path("f") };
        try testing.expectError(error.DataError, a.check(null, s.sink()));
        try testing.expectEqual(1, s.failed);
        try testing.expect(!try oracleTest(fx, flipped, null));
        // extract: the broken file is reported and the others still come out
        var e: ToDir = .{ .fx = fx, .root = try fx.path("fe") };
        try testing.expectError(error.DataError, a.extract(null, e.sink()));
        try testing.expectEqual(files.len, e.done);
        try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, "text.txt")), try fx.read(try fx.join(try fx.path("fe"), "text.txt")));
    }

    // truncated zip / tar / gz: either the open fails, or it succeeds with error_flags set and check() fails -
    // never a healthy-looking archive
    for ([_]struct { fmt: @import("core/types.zig").OutFormat, ext: []const u8 }{
        .{ .fmt = .Zip, .ext = "zip" }, .{ .fmt = .Tar, .ext = "tar" }, .{ .fmt = .GZip, .ext = "gz" },
    }) |c| {
        const ar = fx.arena.allocator();
        const whole = try fx.path(try std.mem.concat(ar, u8, &.{ "whole.", c.ext }));
        const items: []const sz.NewItem = if (c.fmt == .GZip) fx.items[dirs.len + 1 ..][0..1] else fx.items;
        try sz.create(testing.allocator, whole, items, .{ .format = c.fmt });
        const full = try fx.read(whole);
        const short = try fx.path(try std.mem.concat(ar, u8, &.{ "short.", c.ext }));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = short, .data = full[0 .. full.len * 2 / 3] });
        const a = sz.InArchive.open(testing.allocator, short, null) catch |e| {
            try testing.expectEqual(error.Damaged, e);
            continue;
        };
        defer a.close();
        var s: ToDir = .{ .fx = fx, .root = try fx.path(try std.mem.concat(ar, u8, &.{ "short-", c.ext })) };
        const checked = a.check(null, s.sink());
        // measured: zip and tar open with a partial list and unexpected_end; gz opens clean, its check fails
        if (c.fmt != .GZip) try testing.expect(a.props.error_flags & sz.arc_flag.unexpected_end != 0);
        try testing.expectError(error.DataError, checked);
        try testing.expect(!try oracleTest(fx, short, null));
    }

    try testing.expectError(error.NotArchive, sz.InArchive.open(testing.allocator, try fx.join(fx.src, "text.txt"), null));
    try testing.expectError(error.FileNotFound, sz.InArchive.open(testing.allocator, try fx.path("missing.7z"), null));
    const fake = try fx.path("fake.zip"); // the extension says zip, the bytes do not
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fake, .data = "not a zip at all" });
    try testing.expectError(error.Damaged, sz.InArchive.open(testing.allocator, fake, null));
}

test "cancel mid-extract and mid-create: Canceled, partial archive removed" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const arc = try fx.path("c.7z");
    try sz.create(testing.allocator, arc, fx.items, .{ .format = .SevenZip, .props = &.{ .{ .name = "s", .value = "off" }, .{ .name = "x", .value = "1" } } });
    const a = try sz.InArchive.open(testing.allocator, arc, null);
    defer a.close();
    var steps: usize = 0;
    var s: ToDir = .{ .fx = fx, .root = try fx.path("c") };
    var sink = s.sink();
    sink.progress = .{
        .ctx = &steps,
        .step = struct {
            fn f(ctx: ?*anyopaque, done: u64, total: u64) bool {
                const n: *usize = @ptrCast(@alignCast(ctx.?));
                n.* += 1;
                return done == 0 or done >= total; // stop at the first real progress
            }
        }.f,
    };
    try testing.expectError(error.Canceled, a.extract(null, sink));
    try testing.expect(steps > 0 and s.done < files.len);

    const stopped = try fx.path("stopped.7z");
    try testing.expectError(error.Canceled, sz.create(testing.allocator, stopped, fx.items, .{ .format = .SevenZip, .progress = .{ .step = struct {
        fn f(_: ?*anyopaque, _: u64, _: u64) bool {
            return false;
        }
    }.f } }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, stopped, .{}));

    // a source that vanished is an error (never a silently missing file), and no archive is left
    const missing = [_]sz.NewItem{.{ .name = "ghost.txt", .source = try fx.path("ghost.txt") }};
    const ghost = try fx.path("ghost.zip");
    try testing.expectError(error.FileNotFound, sz.create(testing.allocator, ghost, &missing, .{ .format = .Zip }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, ghost, .{}));

    // an EXISTING out_path survives a failed / cancelled write untouched; a successful one replaces it, read-only
    // or not; no temp file is ever left behind
    const w = @import("kit").w;
    const precious = try fx.path("precious.zip");
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = precious, .data = "old bytes" });
    try testing.expectError(error.FileNotFound, sz.create(testing.allocator, precious, &missing, .{ .format = .Zip }));
    try testing.expectError(error.Canceled, sz.create(testing.allocator, precious, fx.items, .{ .format = .Zip, .progress = .{ .step = struct {
        fn f(_: ?*anyopaque, _: u64, _: u64) bool {
            return false;
        }
    }.f } }));
    try testing.expectEqualStrings("old bytes", try fx.read(precious));
    const precious_w = try std.unicode.wtf8ToWtf16LeAllocZ(fx.arena.allocator(), precious);
    try testing.expect(w.SetFileAttributesW(precious_w.ptr, w.FILE_ATTRIBUTE_READONLY | w.FILE_ATTRIBUTE_HIDDEN) != 0);
    try sz.create(testing.allocator, precious, fx.items, .{ .format = .Zip });
    try testing.expect(w.GetFileAttributesW(precious_w.ptr) & w.FILE_ATTRIBUTE_READONLY == 0);
    try testing.expect(try oracleTest(fx, precious, null));
    var dir = try Io.Dir.cwd().openDir(testing.io, fx.tmp.path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| try testing.expect(std.mem.find(u8, e.name, "makepack-tmp") == null);
}

test "packed sizes and archive props: solid / non-solid 7z, zip comment, split volumes" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();

    const solid = try fx.path("solid.7z");
    try sz.create(testing.allocator, solid, fx.items, .{ .format = .SevenZip, .props = &.{ .{ .name = "s", .value = "on" }, .{ .name = "m", .value = "LZMA2" }, .{ .name = "d", .value = "1m" } } });
    {
        const a = try sz.InArchive.open(testing.allocator, solid, null);
        defer a.close();
        try testing.expect(a.props.solid);
        try testing.expectEqual(@as(?u64, 1), a.props.blocks);
        try testing.expect(std.mem.startsWith(u8, a.props.method.?, "LZMA2"));
        try testing.expectEqualStrings("7z", a.props.format_name);
        var with_size: usize = 0;
        for (a.items) |it| if (it.packed_size) |p| {
            if (p > 0) with_size += 1;
        };
        try testing.expectEqual(1, with_size); // the whole block on its first file
        const l = try crossCheck(fx, a, solid, null);
        try testing.expectEqualStrings(a.props.method.?, l.header.get("Method").?);
        try testing.expectEqualStrings("+", l.header.get("Solid").?);
        try testing.expectEqualStrings("1", l.header.get("Blocks").?);
        try testing.expectEqual(try std.fmt.parseInt(u64, l.header.get("Physical Size").?, 10), a.props.phy_size.?);
    }

    const loose = try fx.path("loose.7z");
    try sz.create(testing.allocator, loose, fx.items, .{ .format = .SevenZip, .props = &.{.{ .name = "s", .value = "off" }} });
    {
        const a = try sz.InArchive.open(testing.allocator, loose, null);
        defer a.close();
        try testing.expect(!a.props.solid);
        try testing.expectEqual(@as(?u64, 3), a.props.blocks); // the three non-empty files
        for (a.items) |it| if (!it.is_dir and it.size > 0) try testing.expect(it.packed_size.? > 0);
        _ = try crossCheck(fx, a, loose, null);
    }

    const zip = try fx.path("comment.zip");
    const r = try py(fx,
        \\import zipfile, sys
        \\with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
        \\    z.writestr('a.txt', 'hello ' * 100)
        \\    z.comment = b'MakePack test comment'
    , &.{zip});
    try testing.expect(r.ok);
    {
        const a = try sz.InArchive.open(testing.allocator, zip, null);
        defer a.close();
        try testing.expectEqualStrings("MakePack test comment", a.props.comment.?);
        try testing.expectEqualStrings("Deflate", a.items[0].method);
        try testing.expectEqual(@as(?u32, std.hash.Crc32.hash(try repeat(ar, "hello ", 100))), a.items[0].crc);
        try testing.expect(a.items[0].packed_size.? < 600);
        _ = try crossCheck(fx, a, zip, null);
    }

    // 7-Zip's split format: the 7z signature in .001 but the rest in .002...: the Split handler takes over and
    // reads the next parts through IArchiveOpenVolumeCallback.
    const parts = try fx.path("parts.7z");
    const made = try run(fx, &.{ paths.seven_zip_exe, "a", "-v300k", "-mx=0", parts, try fx.join(fx.src, "sub\\random.bin") });
    try testing.expect(made.ok);
    const first = try std.mem.concat(ar, u8, &.{ parts, ".001" });
    const a = try sz.InArchive.open(testing.allocator, first, null);
    defer a.close();
    try testing.expectEqual(sz.Format.Split, a.props.format);
    try testing.expectEqual(@as(?u64, 4), a.props.volumes);
    const out = try fx.path("joined");
    var s: ToDir = .{ .fx = fx, .root = out };
    try a.extract(null, s.sink());
    const joined = try sz.InArchive.open(testing.allocator, try fx.join(out, fspath.basename(a.items[0].path)), null);
    defer joined.close();
    try testing.expectEqual(sz.Format.SevenZip, joined.props.format);
}

test "update: keep / rename / delete / add on 7z and zip; append keeps the archive's password" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();
    const added = try fx.path("added.txt");
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = added, .data = "new data\n" });

    for ([_]@import("core/types.zig").OutFormat{ .SevenZip, .Zip }) |fmt| {
        const base = try fx.path(if (fmt == .Zip) "base.zip" else "base.7z");
        const next = try fx.path(if (fmt == .Zip) "next.zip" else "next.7z");
        try sz.create(testing.allocator, base, fx.items, .{ .format = fmt });
        const a = try sz.InArchive.open(testing.allocator, base, null);
        defer a.close();
        try testing.expectError(error.InvalidOption, sz.update(a, next, &.{}, .{ .format = .Tar })); // not its own format

        var changes: std.ArrayList(sz.Change) = .empty;
        for (a.items) |it| {
            const name = try ar.dupe(u8, it.path);
            std.mem.replaceScalar(u8, name, '/', '\\');
            if (std.mem.eql(u8, name, "empty.txt")) continue; // deleted
            if (std.mem.eql(u8, name, "Їжак ґанок.txt")) {
                try changes.append(ar, .{ .rename = .{ .index = it.index, .name = "renamed\\Їжак.txt" } });
            } else try changes.append(ar, .{ .keep = it.index });
        }
        try changes.append(ar, .{ .add = .{ .name = "added.txt", .source = added } });
        try sz.update(a, next, changes.items, .{ .format = fmt });

        const b = try sz.InArchive.open(testing.allocator, next, null);
        defer b.close();
        try expectNames(b, ar, &.{ "added.txt", "empty1", "empty1\\empty2", "empty1\\empty2\\empty3", "renamed\\Їжак.txt", "sub", "sub\\random.bin", "text.txt" });
        const out = try fx.path(if (fmt == .Zip) "u-zip" else "u-7z");
        var s: ToDir = .{ .fx = fx, .root = out };
        try b.extract(null, s.sink());
        try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, "Їжак ґанок.txt")), try fx.read(try fx.join(out, "renamed\\Їжак.txt")));
        try testing.expectEqualSlices(u8, "new data\n", try fx.read(try fx.join(out, "added.txt")));
        try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, "text.txt")), try fx.read(try fx.join(out, "text.txt")));
        _ = try crossCheck(fx, b, next, null);
        // the same file as the open archive: refused by the sharing mode, and the archive survives
        try testing.expectError(error.FileBusy, sz.update(a, base, changes.items, .{ .format = fmt }));
        _ = try fx.read(base);
        try testing.expect(try oracleTest(fx, base, null));
    }

    // encrypted 7z (data + headers): a file appended without o.password is encrypted with the archive's own
    const pw = "secret";
    const enc = try fx.path("enc.7z");
    try sz.create(testing.allocator, enc, fx.items, .{ .format = .SevenZip, .password = pw, .props = &.{.{ .name = "he", .value = "on" }} });
    const a = try sz.InArchive.open(testing.allocator, enc, pw);
    defer a.close();
    var changes: std.ArrayList(sz.Change) = .empty;
    for (a.items) |it| try changes.append(ar, .{ .keep = it.index });
    try changes.append(ar, .{ .add = .{ .name = "added.txt", .source = added } });
    const enc2 = try fx.path("enc2.7z");
    try sz.update(a, enc2, changes.items, .{ .format = .SevenZip });
    try testing.expectError(error.PasswordNeeded, sz.InArchive.open(testing.allocator, enc2, null)); // headers stay encrypted
    const b = try sz.InArchive.open(testing.allocator, enc2, pw);
    defer b.close();
    for (b.items) |it| if (std.mem.eql(u8, it.path, "added.txt")) try testing.expect(it.encrypted);
    _ = try crossCheck(fx, b, enc2, pw);

    // deleting from an encrypted solid block needs the key: opened without one (headers plain) -> PasswordNeeded
    const data_only = try fx.path("data-only.7z");
    try sz.create(testing.allocator, data_only, fx.items, .{ .format = .SevenZip, .password = pw });
    const c = try sz.InArchive.open(testing.allocator, data_only, null);
    defer c.close();
    var drop_one: std.ArrayList(sz.Change) = .empty;
    for (c.items) |it| if (!std.mem.eql(u8, it.path, "text.txt")) try drop_one.append(ar, .{ .keep = it.index });
    const out3 = try fx.path("data-only2.7z");
    try testing.expectError(error.PasswordNeeded, sz.update(c, out3, drop_one.items, .{ .format = .SevenZip }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, out3, .{}));
    // ... and opened with the wrong one: WrongPassword (7z.dll only says the repacked block failed its check)
    const d = try sz.InArchive.open(testing.allocator, data_only, "wrong");
    defer d.close();
    try testing.expectError(error.WrongPassword, sz.update(d, out3, drop_one.items, .{ .format = .SevenZip }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, out3, .{}));

    // the open archive's own file under another name (a hard link, as Engine's .makepack~ backup): FileBusy
    const w = @import("kit").w;
    const link = try fx.path("data-only.7z.makepack~");
    const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, link);
    const target_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, data_only);
    try testing.expect(w.CreateHardLinkW(link_w.ptr, target_w.ptr, null) != 0);
    const via_link = try sz.InArchive.open(testing.allocator, link, pw);
    defer via_link.close();
    try testing.expectError(error.FileBusy, sz.update(via_link, data_only, drop_one.items, .{ .format = .SevenZip }));
    try testing.expect(try oracleTest(fx, data_only, pw));
}

test "SFX: 7z.sfx + 7z data opens as 7z, extracts" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const arc = try fx.path("payload.7z");
    try sz.create(testing.allocator, arc, fx.items, .{ .format = .SevenZip });
    const sfx = try fx.path("setup.exe");
    const stub = try Io.Dir.cwd().readFileAlloc(testing.io, paths.seven_zip_sfx, fx.arena.allocator(), .limited(4 << 20));
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = sfx, .data = try std.mem.concat(fx.arena.allocator(), u8, &.{ stub, try fx.read(arc) }) });
    const a = try sz.InArchive.open(testing.allocator, sfx, null);
    defer a.close();
    try testing.expectEqual(sz.Format.SevenZip, a.props.format);
    const out = try fx.path("sfx-out");
    var s: ToDir = .{ .fx = fx, .root = out };
    try a.extract(null, s.sink());
    try fx.expectTree(out);
}

test "one item out of a solid block; mtime + attributes; overwriting a read-only hidden file" {
    const w = @import("kit").w;
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();
    const src = try fx.join(fx.src, "Їжак ґанок.txt");
    const src_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, src);
    try testing.expect(w.SetFileAttributesW(src_w.ptr, w.FILE_ATTRIBUTE_READONLY | w.FILE_ATTRIBUTE_HIDDEN) != 0);
    const arc = try fx.path("solid.7z");
    const made = sz.create(testing.allocator, arc, fx.items, .{ .format = .SevenZip, .props = &.{.{ .name = "s", .value = "on" }} });
    _ = w.SetFileAttributesW(src_w.ptr, w.FILE_ATTRIBUTE_NORMAL);
    try made;

    const a = try sz.InArchive.open(testing.allocator, arc, null);
    defer a.close();
    const item = for (a.items) |*it| {
        if (std.mem.eql(u8, it.path, "Їжак ґанок.txt")) break it;
    } else return error.TestUnexpectedResult;
    try testing.expect(item.attrib & 0x3 == 0x3);

    const out = try fx.path("one");
    const dest = try fx.join(out, "Їжак ґанок.txt");
    const dest_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, dest);
    defer _ = w.SetFileAttributesW(dest_w.ptr, w.FILE_ATTRIBUTE_NORMAL); // or the temp dir cannot be removed
    // the first round overwrites (truncates) a longer ordinary file, the second the read-only hidden file the
    // first one left
    try Io.Dir.cwd().createDirPath(testing.io, out);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dest, .data = try repeat(ar, "junk", 16 << 10) });
    for (0..2) |_| {
        var s: ToDir = .{ .fx = fx, .root = out };
        try a.extract(&.{item.index}, s.sink());
        try testing.expectEqual(1, s.done);
        try testing.expectEqualSlices(u8, try fx.read(src), try fx.read(dest));
        const attrs = w.GetFileAttributesW(dest_w.ptr);
        try testing.expect(attrs & (w.FILE_ATTRIBUTE_READONLY | w.FILE_ATTRIBUTE_HIDDEN) == w.FILE_ATTRIBUTE_READONLY | w.FILE_ATTRIBUTE_HIDDEN);
        const st = try Io.Dir.cwd().statFile(testing.io, dest, .{});
        const unix_100ns: i128 = @as(i128, item.mtime) - 116444736000000000; // FILETIME epoch 1601 -> 1970
        try testing.expectEqual(unix_100ns * 100, @as(i128, st.mtime.nanoseconds));
    }
    // its solid neighbours were decoded (skip mode) but never written
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(testing.io, try fx.join(out, "text.txt"), .{}));

    // check() of a subset; duplicate indices are passed to 7z.dll once
    const other: u32 = @intCast((item.index + 1) % a.items.len);
    var c: ToDir = .{ .fx = fx, .root = out };
    try a.check(&.{ item.index, other, item.index, other }, c.sink());
    try testing.expectEqual(2, c.done);
    try testing.expectEqual(0, c.failed);
}

test "folder times (NewItem.folder), a symlinked source, paths past MAX_PATH" {
    const w = @import("kit").w;
    const fx = try Fixture.init();
    defer fx.deinit();
    const ar = fx.arena.allocator();

    // a folder entry keeps its folder's mtime (C#), instead of "now"
    const folder = try fx.join(fx.src, "empty1");
    const folder_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, folder);
    const h = w.CreateFileW(folder_w.ptr, w.FILE_WRITE_ATTRIBUTES, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null);
    try testing.expect(h != w.INVALID_HANDLE_VALUE);
    const old: i64 = 132_000_000_000_000_000; // 2019-04-17
    var info: extern struct { ctime: i64 = 0, atime: i64 = 0, mtime: i64, change: i64 = 0, attrs: u32 = 0 } = .{ .mtime = old };
    const set = w.SetFileInformationByHandle(h, w.FileBasicInfo, &info, @sizeOf(@TypeOf(info)));
    _ = w.CloseHandle(h);
    try testing.expect(set != 0);

    var items: std.ArrayList(sz.NewItem) = .empty;
    try items.append(ar, .{ .name = "empty1", .source = null, .folder = folder });
    try items.append(ar, .{ .name = "text.txt", .source = try fx.join(fx.src, "text.txt") });
    // a symlink source (needs Developer Mode or admin; skipped otherwise): sized and read as its target
    const link = try fx.path("link.bin");
    const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, link);
    const target_w = try std.unicode.wtf8ToWtf16LeAllocZ(ar, try fx.join(fx.src, "sub\\random.bin"));
    const linked = w.CreateSymbolicLinkW(link_w.ptr, target_w.ptr, 0x2) != 0; // ALLOW_UNPRIVILEGED_CREATE
    if (linked) try items.append(ar, .{ .name = "link.bin", .source = link }) else std.debug.print("symlink source: skipped (no privilege)\n", .{});

    // the archive and the extracted files live deeper than MAX_PATH
    var deep: []const u8 = fx.tmp.path;
    while (deep.len < 300) deep = try fx.join(deep, "a-rather-long-folder-name-for-max-path");
    try Io.Dir.cwd().createDirPath(testing.io, deep);
    const arc = try fx.join(deep, "deep.7z");
    try sz.create(testing.allocator, arc, items.items, .{ .format = .SevenZip });
    const a = try sz.InArchive.open(testing.allocator, arc, null);
    defer a.close();
    for (a.items) |it| {
        if (std.mem.eql(u8, it.path, "empty1")) try testing.expectEqual(@as(u64, @intCast(old)), it.mtime);
        if (std.mem.eql(u8, it.path, "link.bin")) {
            try testing.expectEqual(1 << 20, it.size);
            try testing.expect(it.attrib & w.FILE_ATTRIBUTE_REPARSE_POINT == 0);
        }
    }
    const out = try fx.join(deep, "out");
    var s: ToDir = .{ .fx = fx, .root = out };
    try a.extract(null, s.sink());
    try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, "text.txt")), try fx.read(try fx.join(out, "text.txt")));
    if (linked) try testing.expectEqualSlices(u8, try fx.read(try fx.join(fx.src, "sub\\random.bin")), try fx.read(try fx.join(out, "link.bin")));
}

test "an archive opened on one thread extracts on another" {
    const fx = try Fixture.init();
    defer fx.deinit();
    const arc = try fx.path("t.7z");
    try sz.create(testing.allocator, arc, fx.items, .{ .format = .SevenZip, .props = &.{.{ .name = "mt", .value = "4" }} });
    const a = try sz.InArchive.open(testing.allocator, arc, null);
    defer a.close();
    const out = try fx.path("thread");
    var s: ToDir = .{ .fx = fx, .root = out };
    var result: anyerror!void = {};
    const Worker = struct {
        fn work(x: *sz.InArchive, sink: sz.Sink, res: *anyerror!void) void {
            res.* = x.extract(null, sink);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.work, .{ a, s.sink(), &result });
    t.join();
    try result;
    try fx.expectTree(out);
}
