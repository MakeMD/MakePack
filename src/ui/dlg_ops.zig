//! MP-G2: the main window's one-shot operations (MainForm's DoTest/TestOne, ToTemp, DoDelete, Modify, SaveReport,
//! AddToArchive's offer, Ready, the token prompts). Each is a Task: prompts -> job -> requests to the main window.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const R = @import("dlg_run.zig");
const info_dlg = @import("dlg_info.zig");
const viewer_dlg = @import("dlg_viewer.zig");

const S = C.S;
const engine = C.engine;
const Token = C.Token;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;

fn dupeList(gpa: Allocator, list: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, list.len);
    for (list, 0..) |s, i| out[i] = gpa.dupe(u8, s) catch {
        for (out[0..i]) |x| gpa.free(x);
        gpa.free(out);
        return error.OutOfMemory;
    };
    return out;
}

/// EnsurePassword's new instance goes to the main window (it closes the old one); the borrowed one to use.
fn adopt(d: *Dialogs, old: *engine.Archive, e: *const R.Ensurer) ?*engine.Archive {
    const a = e.result orelse return null;
    if (a != old) d.ctx.post(.{ .replace_archive = .{ .old = old, .new = a } });
    return a;
}

// ---- confirm / nameLine with a token --------------------------------------------------------------------------

const TokenPrompt = struct {
    token: Token,
    reply: Reply = .{},
    line: bool,

    pub fn tick(t: *TokenPrompt, d: *Dialogs) bool {
        if (!t.reply.done) return true;
        if (t.reply.button != null) {
            if (!t.line) d.ctx.post(.{ .confirmed = t.token }) else if (t.reply.takeText()) |v| d.ctx.post(.{ .text = .{ .token = t.token, .value = v } });
        }
        return false;
    }

    pub fn deinit(t: *TokenPrompt, d: *Dialogs) void {
        t.reply.reset(d.ctx.gpa);
        d.ctx.gpa.destroy(t);
    }
};

pub fn confirmToken(d: *Dialogs, kind: kit.ui.MsgKind, title: []const u8, text: []const u8, default_no: bool, token: Token) void {
    const t = d.ctx.gpa.create(TokenPrompt) catch return;
    t.* = .{ .token = token, .line = false };
    P.message(d, kind, title, text, .yes_no, default_no, &t.reply);
    D.addTask(d, TokenPrompt, t, true);
}

pub fn nameLineToken(d: *Dialogs, title: []const u8, prompt: []const u8, text: []const u8, token: Token) void {
    const t = d.ctx.gpa.create(TokenPrompt) catch return;
    t.* = .{ .token = token, .line = true };
    P.askName(d, title, prompt, .line, text, false, false, &t.reply);
    D.addTask(d, TokenPrompt, t, true);
}

// ---- OpenArchive / Ready ------------------------------------------------------------------------------------

const OpenTask = struct {
    o: R.Opener = .{},
    token: Token,
    then_info: bool = false,

    pub fn tick(t: *OpenTask, d: *Dialogs) bool {
        if (!t.o.tick(d)) return true;
        const a = t.o.archive orelse return false;
        t.o.archive = null;
        if (t.then_info) info_dlg.open(d, a, true) else d.ctx.post(.{ .opened = .{ .token = t.token, .archive = a } });
        return false;
    }

    pub fn deinit(t: *OpenTask, d: *Dialogs) void {
        t.o.deinit(d);
        d.ctx.gpa.destroy(t);
    }
};

pub fn openArchive(d: *Dialogs, path: []const u8, password: ?[]const u8, token: Token) void {
    const t = d.ctx.gpa.create(OpenTask) catch return;
    t.* = .{ .token = token };
    t.o.start(d, path, password);
    D.addTask(d, OpenTask, t, true);
}

/// DoInfo on a file on disk: OpenArchive -> InfoForm (it closes the archive).
pub fn infoFile(d: *Dialogs, path: []const u8) void {
    const t = d.ctx.gpa.create(OpenTask) catch return;
    t.* = .{ .token = 0, .then_info = true };
    t.o.start(d, path, null);
    D.addTask(d, OpenTask, t, true);
}

const ReadyTask = struct {
    e: R.Ensurer = .{},
    a: *engine.Archive,
    token: Token,

    pub fn tick(t: *ReadyTask, d: *Dialogs) bool {
        if (!t.e.tick(d)) return true;
        if (adopt(d, t.a, &t.e) != null) d.ctx.post(.{ .ready = t.token });
        return false;
    }

    pub fn deinit(t: *ReadyTask, d: *Dialogs) void {
        t.e.deinit(d);
        d.ctx.gpa.destroy(t);
    }
};

pub fn ready(d: *Dialogs, a: *engine.Archive, token: Token) void {
    const t = d.ctx.gpa.create(ReadyTask) catch return;
    t.* = .{ .a = a, .token = token };
    t.e.start(d, a);
    D.addTask(d, ReadyTask, t, true);
}

// ---- ToTemp (extractToTemp, viewEntry) ------------------------------------------------------------------------

pub const TempFor = union(enum) { token: Token, view: []const u8 };

const TempTask = struct {
    e: R.Ensurer = .{},
    run: R.Run = .{},
    a: *engine.Archive,
    use: ?*engine.Archive = null,
    indices: []u32,
    dir: []u8 = &.{},
    /// The viewer's title (the row's name); null = post .temp_ready(token).
    view_name: ?[]u8,
    token: Token,
    state: enum { ensure, run } = .ensure,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(TempTask);
        const d = r.d;
        try engine.extract(d.ctx.gpa, d.ctx.io, t.use.?, t.dir, t.indices, .Overwrite, r.progress(), engine.Conflict.always_overwrite, C.settings.current().Motw, .{}, &r.diag);
    }

    pub fn tick(t: *TempTask, d: *Dialogs) bool {
        switch (t.state) {
            .ensure => {
                if (!t.e.tick(d)) return true;
                t.use = adopt(d, t.a, &t.e) orelse return false;
                t.dir = engine.newTempDir(d.ctx.gpa, d.ctx.io) catch |err| {
                    d.alert(.err, S.@"error".get(), engine.friendly(err, null));
                    return false;
                };
                t.state = .run;
                t.run.start(d, S.extracting.get(), t, work, true);
                return true;
            },
            .run => {
                const o = t.run.tick() orelse return true;
                if (o != .ok) return false;
                if (t.view_name) |name| {
                    // Path.Combine(dir, Norm(f.FileName))
                    const gpa = d.ctx.gpa;
                    const items = t.use.?.items();
                    if (t.indices[0] >= items.len) return false;
                    const n = engine.norm(gpa, items[t.indices[0]].path) catch return false;
                    defer gpa.free(n);
                    std.mem.replaceScalar(u8, n, '/', '\\');
                    const file = std.mem.concat(gpa, u8, &.{ t.dir, "\\", n }) catch return false;
                    defer gpa.free(file);
                    if (engine.fileExists(file)) viewer_dlg.open(d, file, name);
                } else {
                    d.ctx.post(.{ .temp_ready = .{ .token = t.token, .dir = t.dir } });
                    t.dir = &.{};
                }
                return false;
            },
        }
    }

    pub fn deinit(t: *TempTask, d: *Dialogs) void {
        t.run.deinit();
        t.e.deinit(d);
        const gpa = d.ctx.gpa;
        gpa.free(t.indices);
        if (t.dir.len > 0) gpa.free(t.dir);
        if (t.view_name) |v| gpa.free(v);
        gpa.destroy(t);
    }
};

pub fn toTemp(d: *Dialogs, a: *engine.Archive, indices: []const u32, purpose: TempFor) void {
    const gpa = d.ctx.gpa;
    const t = gpa.create(TempTask) catch return;
    const idx = gpa.dupe(u32, indices) catch return gpa.destroy(t);
    const vn: ?[]u8 = switch (purpose) {
        .view => |n| gpa.dupe(u8, n) catch null,
        .token => null,
    };
    t.* = .{ .a = a, .indices = idx, .view_name = vn, .token = if (purpose == .token) purpose.token else 0 };
    t.e.start(d, a);
    D.addTask(d, TempTask, t, true);
}

// ---- Test ---------------------------------------------------------------------------------------------------

const TestTask = struct {
    run: R.Run = .{},
    o: R.Opener = .{},
    /// The archive being tested: the main window's (borrowed) or one we opened (owned).
    a: ?*engine.Archive = null,
    owned: bool = false,
    files: [][]u8 = &.{},
    next: usize = 0,
    good: usize = 0,
    ok: bool = false,
    state: enum { open, run, msg } = .open,
    reply: Reply = .{},

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(TestTask);
        t.ok = try engine.testArchive(r.d.ctx.gpa, r.d.ctx.io, t.a.?, r.progress(), &r.diag);
    }

    fn startRun(t: *TestTask, d: *Dialogs) void {
        t.state = .run;
        t.ok = false;
        var buf: [600]u8 = undefined;
        // several archives: "Testing: name"
        const title: []const u8 = if (t.files.len > 1) std.mem.print(&buf, "{s}: {s}", .{ S.testing.get(), t.a.?.display() }) catch S.testing.get() else S.testing.get();
        t.run.start(d, title, t, work, true);
    }

    fn closeOwned(t: *TestTask) void {
        if (t.owned) if (t.a) |a| a.close();
        t.a = null;
        t.owned = false;
    }

    pub fn tick(t: *TestTask, d: *Dialogs) bool {
        switch (t.state) {
            .open => {
                if (!t.o.tick(d)) return true;
                if (t.o.archive) |a| {
                    t.o.archive = null;
                    t.a = a;
                    t.owned = true;
                    t.startRun(d);
                    return true;
                }
                return t.nextFile(d);
            },
            .run => {
                const o = t.run.tick() orelse return true;
                t.closeOwned();
                if (o == .cancelled and t.files.len > 1) return t.summary(d); // C#: break
                if (o != .ok) return if (t.files.len > 1) t.nextFile(d) else false;
                if (t.files.len > 1) {
                    if (t.ok) t.good += 1;
                    return t.nextFile(d);
                }
                P.message(d, if (t.ok) .info else .warning, S.app, if (t.ok) S.testOk.get() else S.testFailed.get(), .ok, false, null);
                return false;
            },
            .msg => return false,
        }
    }

    fn nextFile(t: *TestTask, d: *Dialogs) bool {
        if (t.next >= t.files.len) return if (t.files.len > 1) t.summary(d) else false;
        t.state = .open;
        t.o.start(d, t.files[t.next], null);
        t.next += 1;
        return true;
    }

    fn summary(t: *TestTask, d: *Dialogs) bool {
        var buf: [256]u8 = undefined;
        const text = S.fillZ(&buf, S.testSummaryFmt.get(), .{ t.files.len, t.good });
        P.message(d, if (t.good == t.files.len) .info else .warning, S.app, text, .ok, false, null);
        return false;
    }

    pub fn deinit(t: *TestTask, d: *Dialogs) void {
        t.run.deinit();
        t.closeOwned();
        t.o.deinit(d);
        t.reply.reset(d.ctx.gpa);
        kit.win.freeList(d.ctx.gpa, t.files);
        d.ctx.gpa.destroy(t);
    }
};

/// TestOne on the main window's archive (no Ready, as in C#: an archive whose bodies need a password fails).
pub fn testOpen(d: *Dialogs, a: *engine.Archive) void {
    const t = d.ctx.gpa.create(TestTask) catch return;
    t.* = .{ .a = a };
    t.startRun(d);
    D.addTask(d, TestTask, t, true);
}

pub fn testFiles(d: *Dialogs, paths: []const []const u8) void {
    if (paths.len == 0) return;
    const t = d.ctx.gpa.create(TestTask) catch return;
    t.* = .{ .files = dupeList(d.ctx.gpa, paths) catch return d.ctx.gpa.destroy(t) };
    _ = t.nextFile(d);
    D.addTask(d, TestTask, t, true);
}

// ---- SaveReport ---------------------------------------------------------------------------------------------

/// ponytail: the report is written on the UI thread (a list of names; the job machinery is for 7z.dll work).
pub fn saveReport(d: *Dialogs, a: *engine.Archive, as_html: bool, dir: []const u8) void {
    const gpa = d.ctx.gpa;
    var nb: [600]u8 = undefined;
    const ext = if (as_html) ".html" else ".txt";
    const name = std.mem.print(&nb, "{s}{s}{s}", .{ engine.baseName(a.display()), S.reportSuffix.get(), ext }) catch return;
    const filters: []const kit.win.Filter = if (as_html) &.{.{ .name = "HTML", .spec = "*.html" }} else &.{.{ .name = S.textFiles.get(), .spec = "*.txt" }};
    const path = (kit.win.saveFile(gpa, D.owner(d), .{ .file_name = name, .folder = dir, .filters = filters, .default_ext = ext[1..] }) catch null) orelse return;
    defer gpa.free(path);
    engine.writeReport(gpa, d.ctx.io, a, path, as_html) catch |e| return d.alert(.err, S.@"error".get(), engine.friendly(e, null));
    const status = S.fill(gpa, S.reportSavedFmt.get(), .{fspath.basename(path)}) catch return;
    d.ctx.post(.{ .status = status });
}

// ---- DoDelete on disk ---------------------------------------------------------------------------------------

const RecycleTask = struct {
    run: R.Run = .{},
    reply: Reply = .{},
    paths: [][]u8,
    nuke: bool,
    state: enum { ask, run } = .ask,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(RecycleTask);
        try engine.recycle(r.d.ctx.gpa, @ptrCast(t.paths), !t.nuke, &r.diag);
    }

    pub fn tick(t: *RecycleTask, d: *Dialogs) bool {
        switch (t.state) {
            .ask => {
                if (!t.reply.done) return true;
                if (t.reply.button == null) return false;
                t.state = .run;
                t.run.start(d, S.deleting.get(), t, work, true);
                return true;
            },
            .run => {
                _ = t.run.tick() orelse return true;
                d.ctx.post(.refresh); // C#: Fill(keep: true) whatever happened
                return false;
            },
        }
    }

    pub fn deinit(t: *RecycleTask, d: *Dialogs) void {
        t.run.deinit();
        t.reply.reset(d.ctx.gpa);
        kit.win.freeList(d.ctx.gpa, t.paths);
        d.ctx.gpa.destroy(t);
    }
};

pub fn deleteFiles(d: *Dialogs, paths: []const []const u8, nuke: bool) void {
    if (paths.len == 0) return;
    const gpa = d.ctx.gpa;
    const t = gpa.create(RecycleTask) catch return;
    t.* = .{ .paths = dupeList(gpa, paths) catch return gpa.destroy(t), .nuke = nuke };
    var wb: [600]u8 = undefined;
    const what: []const u8 = if (paths.len == 1)
        std.mem.print(&wb, "\u{00AB}{s}\u{00BB}", .{fspath.basename(std.mem.trimEnd(u8, paths[0], "\\/"))}) catch ""
    else
        S.fillZ(&wb, S.itemsFmt.get(), .{paths.len});
    var mb: [1024]u8 = undefined;
    const text = S.fillZ(&mb, if (nuke) S.confirmNukeFmt.get() else S.confirmRecycleFmt.get(), .{what});
    P.message(d, if (nuke) .warning else .question, S.app, text, .yes_no, true, &t.reply);
    D.addTask(d, RecycleTask, t, true);
}

// ---- Modify: delete / rename / add inside the open archive ----------------------------------------------------

pub const EditKind = union(enum) {
    delete: struct { indices: []const u32, count: usize },
    rename: struct { old: []const u8, new: []const u8 },
    add: []const []const u8,
};

const EditTask = struct {
    e: R.Ensurer = .{},
    run: R.Run = .{},
    reply: Reply = .{},
    a: *engine.Archive,
    use: ?*engine.Archive = null,
    kind: enum { delete, rename, add },
    indices: []u32 = &.{},
    count: usize = 0,
    from: []u8 = &.{},
    to: []u8 = &.{},
    new_name: []u8 = &.{},
    files: [][]u8 = &.{},
    cur: []u8,
    source: []u8 = &.{},
    password: ?[]u8 = null,
    state: enum { confirm, ensure, run } = .ensure,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(EditTask);
        const gpa = r.d.ctx.gpa;
        const io = r.d.ctx.io;
        const a = t.use.?;
        t.use = null; // the edit closes it, whatever happens
        switch (t.kind) {
            .delete => try engine.delete(gpa, io, a, t.indices, &r.diag),
            .rename => try engine.rename(gpa, io, a, t.from, t.to, &r.diag),
            .add => try engine.append(gpa, io, a, @ptrCast(t.files), t.cur, .{}, r.progress(), r.conflicts(true), &r.diag),
        }
    }

    pub fn tick(t: *EditTask, d: *Dialogs) bool {
        switch (t.state) {
            .confirm => {
                if (!t.reply.done) return true;
                if (t.reply.button == null) return false;
                t.state = .ensure;
                t.e.start(d, t.a);
                return true;
            },
            .ensure => {
                if (!t.e.tick(d)) return true;
                t.use = adopt(d, t.a, &t.e) orelse return false;
                const gpa = d.ctx.gpa;
                t.source = gpa.dupe(u8, t.use.?.source) catch return false;
                t.password = if (t.use.?.password) |p| gpa.dupe(u8, p) catch null else null;
                d.ctx.post(.{ .detach_archive = t.use.? });
                t.state = .run;
                const title = switch (t.kind) {
                    .delete => S.deleting.get(),
                    .rename => S.renaming.get(),
                    .add => S.adding.get(),
                };
                t.run.start(d, title, t, work, true);
                return true;
            },
            .run => {
                const o = t.run.tick() orelse return true;
                if (t.use) |a| { // the job never ran: nobody closed it
                    a.close();
                    t.use = null;
                }
                t.reopen(d, o == .ok);
                return false;
            },
        }
    }

    /// Modify's tail: Go(Loc(source, cur, password), select, record: false), the status on success.
    fn reopen(t: *EditTask, d: *Dialogs, ok: bool) void {
        const gpa = d.ctx.gpa;
        var sb: [600]u8 = undefined;
        const status: []const u8 = switch (t.kind) {
            .delete => S.fillZ(&sb, S.deletedFmt.get(), .{t.count}),
            .rename => S.fillZ(&sb, S.renamedFmt.get(), .{t.new_name}),
            .add => S.fillZ(&sb, S.addedFmt.get(), .{t.files.len}),
        };
        const source = gpa.dupe(u8, t.source) catch return;
        const cur = gpa.dupe(u8, t.cur) catch return gpa.free(source);
        d.ctx.post(.{ .reopen = .{
            .source = source,
            .password = if (t.password) |p| gpa.dupe(u8, p) catch null else null,
            .cur = cur,
            .select = if (ok and t.kind == .rename) gpa.dupe(u8, t.new_name) catch null else null,
            .status = if (ok) gpa.dupe(u8, status) catch null else null,
        } });
    }

    pub fn deinit(t: *EditTask, d: *Dialogs) void {
        const gpa = d.ctx.gpa;
        t.run.deinit();
        t.e.deinit(d);
        t.reply.reset(gpa);
        if (t.use) |a| a.close();
        gpa.free(t.indices);
        gpa.free(t.from);
        gpa.free(t.to);
        gpa.free(t.new_name);
        kit.win.freeList(gpa, t.files);
        gpa.free(t.cur);
        gpa.free(t.source);
        if (t.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        gpa.destroy(t);
    }
};

pub fn edit(d: *Dialogs, a: *engine.Archive, kind: EditKind, cur: []const u8) void {
    const gpa = d.ctx.gpa;
    const t = gpa.create(EditTask) catch return;
    t.* = .{ .a = a, .kind = .delete, .cur = gpa.dupe(u8, cur) catch return gpa.destroy(t) };
    switch (kind) {
        .delete => |x| {
            t.kind = .delete;
            t.indices = gpa.dupe(u32, x.indices) catch &.{};
            t.count = x.count;
            t.state = .confirm;
            P.message(d, .question, S.app, S.confirmDelete.get(), .yes_no, false, &t.reply);
        },
        .rename => |x| {
            // C# DoRename: no Ready (renaming rewrites the headers only).
            t.kind = .rename;
            t.from = std.mem.concat(gpa, u8, &.{ cur, x.old }) catch &.{};
            t.to = std.mem.concat(gpa, u8, &.{ cur, x.new }) catch &.{};
            t.new_name = gpa.dupe(u8, x.new) catch &.{};
            t.e.result = a;
            t.e.state = .done;
        },
        .add => |files| {
            t.kind = .add;
            t.files = dupeList(gpa, files) catch &.{};
            t.e.start(d, a); // new files get the archive's password too
        },
    }
    D.addTask(d, EditTask, t, true);
}

// ---- AddToArchive on a read-only format ---------------------------------------------------------------------

const OfferTask = struct {
    reply: Reply = .{},
    files: [][]u8,

    pub fn tick(t: *OfferTask, d: *Dialogs) bool {
        if (!t.reply.done) return true;
        if (t.reply.button != null) d.compress(@ptrCast(t.files), true);
        return false;
    }

    pub fn deinit(t: *OfferTask, d: *Dialogs) void {
        t.reply.reset(d.ctx.gpa);
        kit.win.freeList(d.ctx.gpa, t.files);
        d.ctx.gpa.destroy(t);
    }
};

pub fn offerNewArchive(d: *Dialogs, files: []const []const u8) void {
    if (files.len == 0) return;
    const gpa = d.ctx.gpa;
    const t = gpa.create(OfferTask) catch return;
    t.* = .{ .files = dupeList(gpa, files) catch return gpa.destroy(t) };
    var buf: [1024]u8 = undefined;
    const text = std.mem.print(&buf, "{s}\n\n{s}", .{ S.notSupported.get(), S.offerNewArchive.get() }) catch S.notSupported.get();
    P.message(d, .question, S.app, text, .yes_no, false, &t.reply);
    D.addTask(d, OfferTask, t, true);
}
