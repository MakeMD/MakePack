//! MP-G2: ConvertForm (Tools > Convert archives, Alt+Q). Two phases: every question first (passwords,
//! skips, overwrites), then one progress bar for the whole batch; one bad archive does not stop the rest.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const R = @import("dlg_run.zig");
const compress_dlg = @import("dlg_compress.zig");

const S = C.S;
const engine = C.engine;
const settings = C.settings;
const assoc = C.assoc;
const im = kit.im;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;

const level_map = [_]engine.CompressionLevel{ .None, .Fast, .Low, .Normal, .High, .Ultra };

const Job = struct { source: []const u8, password: ?[]const u8, target: []const u8 };

pub const Convert = struct {
    pub const win_id = "convert";
    gpa: Allocator,
    list: std.ArrayList([]u8) = .empty,
    sel: std.ArrayList(bool) = .empty,
    kinds: [engine.kinds.len]engine.KindInfo = undefined,
    names: [engine.kinds.len][]const u8 = undefined,
    kinds_n: usize = 0,
    format: usize = 0,
    level: usize = 3,
    folder: [2048:0]u8 = @splat(0),
    keep_if_not_smaller: bool = true,
    delete_originals: bool = false,
    skip_encrypted: bool = false,
    /// Convert of the main window's open archive: it is released when Convert is pressed, reopened at the end.
    release_open: bool,
    released: bool = false,
    reopen: ?[]u8 = null,
    state: enum { idle, release_wait, next, check_enc, opening, ensuring, confirm, running } = .idle,
    // phase 1
    arena: std.heap.ArenaAllocator,
    sources: []const []const u8 = &.{},
    i: usize = 0,
    jobs: std.ArrayList(Job) = .empty,
    skipped: usize = 0,
    kind: engine.ArchiveKind = .SevenZip,
    out_folder: []const u8 = "",
    delete: bool = false,
    oj: R.OpenJob = .{},
    o: R.Opener = .{},
    e: R.Ensurer = .{},
    opened: ?*engine.Archive = null,
    reply: Reply = .{},
    // phase 2
    run: R.Run = .{},
    level_value: engine.CompressionLevel = .Normal,
    keep_value: bool = true,
    converted: usize = 0,
    kept: usize = 0,
    errors: std.ArrayList([]const u8) = .empty,
    done: bool = false,

    pub fn title(_: *Convert, _: []u8) []const u8 {
        return S.tr().convertTitle;
    }

    pub fn addArchives(f: *Convert, paths: []const []const u8) void {
        for (paths) |p| {
            const t = std.mem.trim(u8, std.mem.trim(u8, p, " \t"), "\"");
            if (t.len == 0) continue;
            const full = engine.fullPath(f.gpa, t) catch continue;
            var dup = !engine.fileExists(full);
            for (f.list.items) |x| if (std.mem.eql(u8, x, full)) {
                dup = true;
            };
            if (dup) {
                f.gpa.free(full);
                continue;
            }
            f.list.append(f.gpa, full) catch {
                f.gpa.free(full);
                continue;
            };
            f.sel.append(f.gpa, false) catch {};
        }
    }

    pub fn body(f: *Convert, d: *Dialogs) bool {
        f.poll(d);
        if (f.done) return false;
        const s = D.scale();
        im.ImGui_TextUnformatted(S.tr().convertArchives);
        const top = im.ImGui_GetCursorPosY();
        if (im.ImGui_BeginListBox("##convert_list", .{ .x = 430 * s, .y = 140 * s })) {
            const ctrl = im.ImGui_GetIO().*.KeyCtrl;
            for (f.list.items, 0..) |p, i| {
                var lb: [2100]u8 = undefined;
                const l = std.mem.printSentinel(&lb, "{s}##convert_in{d}", .{ p, i }, 0) catch continue;
                if (im.ImGui_SelectableEx(l.ptr, f.sel.items[i], 0, .{ .x = 0, .y = 0 })) {
                    if (!ctrl) @memset(f.sel.items, false);
                    f.sel.items[i] = !f.sel.items[i] or !ctrl;
                }
            }
            im.ImGui_EndListBox();
        }
        const after = im.ImGui_GetCursorPosY();
        const bx = im.ImGui_GetCursorPosX() + 438 * s;
        im.ImGui_SetCursorPos(.{ .x = bx, .y = top });
        if (D.buttonMin(S.tr().addFiles, "convert_add", 98)) f.browseAdd(d);
        im.ImGui_SetCursorPosX(bx);
        if (D.buttonMin(S.tr().remove, "convert_remove", 98)) {
            var i = f.list.items.len;
            while (i > 0) {
                i -= 1;
                if (!f.sel.items[i]) continue;
                f.gpa.free(f.list.orderedRemove(i));
                _ = f.sel.orderedRemove(i);
            }
        }
        im.ImGui_SetCursorPosY(after + 8 * s);

        const cap = D.capWidth(74, &.{S.tr().format});
        D.caption(S.tr().format, cap);
        _ = D.combo("convert_format", f.names[0..f.kinds_n], &f.format, 110);
        D.sameLineAt(cap + 128);
        D.caption(S.tr().level, cap + 128 + D.capWidth(64, &.{S.tr().level}));
        const levels = S.levels();
        var lnames: [6][]const u8 = undefined;
        for (levels, 0..) |l, i| lnames[i] = l;
        _ = D.combo("convert_level", &lnames, &f.level, D.comboWidth(160, &lnames));

        im.ImGui_TextUnformatted(S.tr().convertFolder);
        _ = D.inputHint("convert_folder", S.tr().nextToOriginals, &f.folder, 430);
        im.ImGui_SameLine();
        if (D.buttonMin(S.tr().browse, "convert_browse", 98)) {
            if (kit.win.pickFolder(f.gpa, D.owner(d), .{ .title = S.tr().convertFolder, .folder = D.bufText(&f.folder) }) catch null) |p| {
                defer f.gpa.free(p);
                D.setText(&f.folder, p);
            }
        }
        _ = D.checkbox(S.tr().keepIfNotSmaller, "convert_keep", &f.keep_if_not_smaller);
        _ = D.checkbox(S.tr().deleteOriginals, "convert_delete", &f.delete_originals);
        _ = D.checkbox(S.tr().skipEncrypted, "convert_skip_encrypted", &f.skip_encrypted);

        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });
        D.alignRight(&.{ S.tr().convertButton, S.tr().cancel });
        const busy = f.state != .idle;
        if (D.primary(!busy, S.tr().convertButton, "convert_go") or (!busy and D.enterPressed() and !im.ImGui_IsAnyItemActive())) f.go(d);
        im.ImGui_SameLine();
        if (D.buttonOn(!busy, S.tr().cancel, "convert_cancel") or (!busy and D.escPressed())) return false;
        return true;
    }

    fn browseAdd(f: *Convert, d: *Dialogs) void {
        var spec: std.ArrayList(u8) = .empty;
        defer spec.deinit(f.gpa);
        for (assoc.all, 0..) |e, i| {
            if (i > 0) spec.append(f.gpa, ';') catch {};
            spec.appendSlice(f.gpa, "*.") catch {};
            spec.appendSlice(f.gpa, e) catch {};
        }
        const files = (kit.win.openFiles(f.gpa, D.owner(d), true, .{ .filters = &.{
            .{ .name = S.tr().archives, .spec = spec.items },
            .{ .name = S.tr().allFiles, .spec = "*.*" },
        } }) catch null) orelse return;
        defer kit.win.freeList(f.gpa, files);
        f.addArchives(@ptrCast(files));
    }

    fn go(f: *Convert, d: *Dialogs) void {
        if (f.list.items.len == 0) return P.message(d, .info, S.app, S.tr().noInputs, .ok, false, null);
        _ = f.arena.reset(.free_all);
        f.jobs = .empty;
        f.errors = .empty;
        const a = f.arena.allocator();
        const srcs = a.alloc([]const u8, f.list.items.len) catch return;
        for (f.list.items, 0..) |p, i| srcs[i] = a.dupe(u8, p) catch return;
        f.sources = srcs;
        f.kind = f.kinds[f.format].kind;
        f.level_value = level_map[f.level];
        f.keep_value = f.keep_if_not_smaller;
        f.out_folder = a.dupe(u8, std.mem.trim(u8, D.bufText(&f.folder), " \t")) catch return;
        if (f.out_folder.len > 0 and !engine.dirExists(f.out_folder))
            std.Io.Dir.cwd().createDirPath(d.ctx.io, f.out_folder) catch |e| return P.message(d, .err, S.tr().@"error", engine.friendly(e, null), .ok, false, null);
        f.delete = f.delete_originals;
        f.i = 0;
        f.skipped = 0;
        f.converted = 0;
        f.kept = 0;
        if (f.release_open and !f.released) {
            // Closes the main window's view of these archives before they are touched; the job starts next frame.
            f.reopen = f.gpa.dupe(u8, f.list.items[0]) catch null;
            d.ctx.post(.release_archive);
            f.released = true;
            f.state = .release_wait;
            return;
        }
        f.state = .next;
    }

    fn skip(f: *Convert) void {
        f.skipped += 1;
        f.i += 1;
        f.state = .next;
    }

    fn poll(f: *Convert, d: *Dialogs) void {
        switch (f.state) {
            .idle => {},
            .release_wait => f.state = .next,
            .next => {
                if (f.i >= f.sources.len) return f.confirm(d);
                const src = f.sources[f.i];
                if (f.skip_encrypted) {
                    if (engine.probe(d.ctx.io, src) == .encrypted_headers) return f.skip();
                    f.state = .check_enc;
                    if (!f.oj.start(d, src, null)) return f.skip();
                    return;
                }
                f.state = .opening;
                f.o.start(d, src, null);
            },
            .check_enc => {
                if (!f.oj.finished()) return;
                if (f.oj.cancelled()) return f.skip();
                const enc = if (f.oj.result) |a| R.anyEncrypted(a) else engine.canEncryptHeaders(d.ctx.io, f.sources[f.i]);
                if (f.oj.result) |a| a.close();
                f.oj.result = null;
                if (enc) return f.skip();
                f.state = .opening;
                f.o.start(d, f.sources[f.i], null);
            },
            .opening => {
                if (!f.o.tick(d)) return;
                f.opened = f.o.archive orelse return f.skip();
                f.o.archive = null;
                f.state = .ensuring;
                f.e.start(d, f.opened.?);
            },
            .ensuring => {
                if (!f.e.tick(d)) return;
                const ready = f.e.result;
                const a = f.arena.allocator();
                const password: ?[]const u8 = if (ready) |r| (if (r.password) |p| a.dupe(u8, p) catch null else null) else null;
                if (ready) |r| if (r != f.opened.?) r.close();
                f.opened.?.close();
                f.opened = null;
                if (ready == null) return f.skip();
                const src = f.sources[f.i];
                const dir = if (f.out_folder.len > 0) f.out_folder else fspath.dirname(src) orelse ".";
                var target: []const u8 = std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, dir, "\\"), "\\", engine.baseName(src), engine.kind(f.kind).ext }) catch return f.skip();
                // Same name as the original: replace it only when the originals are to go anyway, else "name (2).ext".
                if (engine.samePath(src, target) and !f.delete) target = engine.unique(a, d.ctx.io, target) catch target;
                f.jobs.append(a, .{ .source = src, .password = password, .target = target }) catch {};
                f.i += 1;
                f.state = .next;
            },
            .confirm => {
                if (!f.reply.done) return;
                const yes = f.reply.button != null;
                f.reply.reset(f.gpa);
                if (yes) f.startRun(d) else f.state = .idle;
            },
            .running => {
                _ = f.run.tick() orelse return;
                f.summary(d);
            },
        }
    }

    fn confirm(f: *Convert, d: *Dialogs) void {
        var clash: std.ArrayList([]const u8) = .empty;
        defer clash.deinit(f.gpa);
        for (f.jobs.items) |j| if (!engine.samePath(j.source, j.target)) clash.append(f.gpa, j.target) catch {};
        if (f.jobs.items.len > 0) if (compress_dlg.overwriteQuestion(f.gpa, clash.items, 0)) |q| {
            defer f.gpa.free(q);
            f.state = .confirm;
            return P.message(d, .warning, S.app, q, .yes_no, false, &f.reply);
        };
        f.startRun(d);
    }

    fn startRun(f: *Convert, d: *Dialogs) void {
        f.state = .running;
        f.run.start(d, S.tr().converting, f, work, true);
    }

    /// One archive's share of the overall bar, with its name in front of the file being worked on.
    const Slice = struct {
        to: engine.Progress,
        lo: u32,
        hi: u32,
        name: []const u8,

        fn progress(sl: *const Slice) engine.Progress {
            return .{ .ctx = @constCast(sl), .report = report, .cancel = sl.to.cancel };
        }

        fn report(ctx: ?*anyopaque, percent: u8, file: []const u8) void {
            const sl: *const Slice = @ptrCast(@alignCast(ctx));
            var buf: [1200]u8 = undefined;
            const text: []const u8 = if (file.len > 0) S.fillZ(&buf, S.tr().labelValueFmt, .{ sl.name, file[0..@min(file.len, 900)] }) else sl.name;
            sl.to.send(@intCast(sl.lo + percent * (sl.hi - sl.lo) / 100), text);
        }
    };

    fn work(r: *R.Run) anyerror!void {
        const f = r.user(Convert);
        const gpa = r.d.ctx.gpa;
        const io = r.d.ctx.io;
        const n: u32 = @intCast(f.jobs.items.len);
        for (f.jobs.items, 0..) |j, i_| {
            const i: u32 = @intCast(i_);
            const sl: Slice = .{ .to = r.progress(), .lo = i * 100 / n, .hi = (i + 1) * 100 / n, .name = fspath.basename(j.source) };
            var diag: engine.Diag = .{};
            const ok = engine.convert(gpa, io, j.source, j.password, j.target, f.kind, f.level_value, f.keep_value, f.delete, sl.progress(), &diag) catch |e| {
                if (e == error.Canceled) return e;
                const msg = S.fill(f.arena.allocator(), S.tr().labelValueFmt, .{ fspath.basename(j.source), engine.friendly(e, &diag) }) catch continue;
                f.errors.append(f.arena.allocator(), msg) catch {};
                continue;
            };
            if (ok) f.converted += 1 else f.kept += 1;
        }
    }

    fn summary(f: *Convert, d: *Dialogs) void {
        f.state = .idle;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(f.gpa);
        var buf: [1024]u8 = undefined;
        text.appendSlice(f.gpa, S.fillZ(&buf, S.tr().convertSummaryFmt, .{ f.converted, f.kept, f.skipped, f.errors.items.len })) catch {};
        if (f.errors.items.len > 0) text.appendSlice(f.gpa, "\n") catch {};
        for (f.errors.items[0..@min(10, f.errors.items.len)]) |e| {
            text.appendSlice(f.gpa, "\n") catch {};
            text.appendSlice(f.gpa, e) catch {};
        }
        P.message(d, if (f.errors.items.len > 0) .warning else .info, S.tr().convertTitle, text.items, .ok, false, null);
        if (f.errors.items.len == 0) f.done = true;
    }

    pub fn close(f: *Convert, _: *Dialogs) bool {
        return f.state == .idle;
    }

    pub fn deinit(f: *Convert, d: *Dialogs) void {
        f.run.deinit();
        f.oj.deinit();
        f.o.deinit(d);
        f.e.deinit(d);
        if (f.opened) |a| a.close();
        f.reply.reset(f.gpa);
        if (f.reopen) |p| {
            if (engine.fileExists(p)) d.ctx.post(.{ .open_path = .{ .path = p, .record = false } }) else f.gpa.free(p);
        }
        for (f.list.items) |p| f.gpa.free(p);
        f.list.deinit(f.gpa);
        f.sel.deinit(f.gpa);
        f.arena.deinit();
        f.gpa.destroy(f);
    }
};

/// ConvertForm(paths): modal from the main window, modeless from dispatch "convert".
pub fn open(d: *Dialogs, paths: []const []const u8, release_open: bool, modal: bool) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Convert) catch return;
    f.* = .{ .gpa = gpa, .arena = .init(gpa), .release_open = release_open };
    f.level = std.mem.findScalar(engine.CompressionLevel, &level_map, settings.current().Level) orelse 0;
    for (engine.kinds) |k| if (k.multi) {
        f.kinds[f.kinds_n] = k;
        f.names[f.kinds_n] = k.name;
        f.kinds_n += 1;
    };
    f.addArchives(paths);
    D.push(d, Convert, f, modal);
}
