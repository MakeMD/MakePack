//! MP-G2: ExtractForm (Ask, AfterExtract, Conflicts via dlg_run.Asker), MainForm.DoExtract / DoExtractNoAsk, and
//! Program's extract queue (Enqueue / Pump / Extract): one job at a time, ONE modeless progress "n/N", Cancel
//! drops the rest (exit 255), an error reports itself and the queue carries on (the last failure's code wins).
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const R = @import("dlg_run.zig");
const types = @import("../core/types.zig");

const S = C.S;
const engine = C.engine;
const settings = C.settings;
const pd = C.platform_dispatch;
const im = kit.im;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;

/// Everything the extract dialog decides (ExtractChoice).
pub const Choice = struct {
    dest_buf: [2100]u8 = undefined,
    dest_len: usize = 0,
    mode: engine.OverwriteMode = .Ask,
    options: engine.ExtractOptions = .{},
    delete: engine.DeleteAfter = .Never,

    pub fn dest(c: *const Choice) []const u8 {
        return c.dest_buf[0..c.dest_len];
    }

    fn setDest(c: *Choice, s: []const u8) void {
        const n = @min(s.len, c.dest_buf.len);
        @memcpy(c.dest_buf[0..n], s[0..n]);
        c.dest_len = n;
    }
};

/// 7-Zip-style smart default: a subfolder when the archive has more than one top-level name.
fn manyTopLevel(a: *const engine.Archive) bool {
    var first: ?[]const u8 = null;
    for (a.items()) |it| {
        var p: []const u8 = it.path;
        while (p.len > 0 and (p[0] == '/' or p[0] == '\\')) p = p[1..];
        while (std.mem.startsWith(u8, p, "./") or std.mem.startsWith(u8, p, ".\\")) p = p[2..];
        const top = p[0 .. std.mem.findAny(u8, p, "/\\") orelse p.len];
        if (top.len == 0) continue;
        if (first) |f| {
            if (!types.eqlIgnoreCase(f, top)) return true;
        } else first = top;
    }
    return false;
}

pub const Form = struct {
    pub const win_id = "extract";
    gpa: Allocator,
    dest: [2048:0]u8 = @splat(0),
    sub: bool,
    sub_name: []u8,
    mode: usize,
    paths: usize,
    update: usize,
    delete: usize,
    keep_broken: bool,
    out: *Choice,
    reply: ?*Reply,

    pub fn title(_: *Form, _: []u8) []const u8 {
        return D.noDots(S.tr().extract);
    }

    pub fn body(f: *Form, d: *Dialogs) bool {
        const s = D.scale();
        im.ImGui_TextUnformatted(S.tr().destination);
        _ = D.input("extract_dest", &f.dest, 448, 0);
        im.ImGui_SameLine();
        if (D.buttonMin(S.tr().browse, "extract_browse", 80)) {
            if (kit.win.pickFolder(f.gpa, D.owner(d), .{ .title = S.tr().pickFolder, .folder = D.bufText(&f.dest) }) catch null) |p| {
                defer f.gpa.free(p);
                D.setText(&f.dest, p);
            }
        }
        var sb: [600]u8 = undefined;
        _ = D.checkbox(S.fillZ(&sb, S.tr().subFolderFmt, .{f.sub_name}), "extract_sub", &f.sub);

        const modes = [_][]const u8{ S.tr().ask, S.tr().overwrite, S.tr().skip, S.tr().rename };
        const pathss = [_][]const u8{ S.tr().withPaths, S.tr().noPaths };
        const updates = [_][]const u8{ S.tr().updateReplace, S.tr().updateNewer, S.tr().updateExisting };
        const deletes = [_][]const u8{ S.tr().deleteNever, S.tr().deleteAsk, S.tr().deleteRecycle };
        // Columns sized to the language: the captions, then combos that show their longest item whole.
        const cap = D.capWidth(114, &.{ S.tr().ifExists, S.tr().update, S.tr().archiveAfter });
        const cw = @max(D.comboWidth(160, &modes), D.comboWidth(160, &updates), D.comboWidth(160, &deletes));
        const col2 = cap + cw + 14;
        // Update modes settle a clash by date; the overwrite question only belongs to "replace".
        im.ImGui_BeginDisabled(f.update != 0);
        D.caption(S.tr().ifExists, cap);
        _ = D.combo("extract_mode", &modes, &f.mode, cw);
        im.ImGui_EndDisabled();
        D.sameLineAt(col2);
        D.caption(S.tr().paths, col2 + D.capWidth(84, &.{S.tr().paths}));
        _ = D.combo("extract_paths", &pathss, &f.paths, D.comboWidth(168, &pathss));

        D.caption(S.tr().update, cap);
        _ = D.combo("extract_update", &updates, &f.update, cw);
        D.sameLineAt(col2);
        _ = D.checkbox(S.tr().keepBroken, "extract_keep_broken", &f.keep_broken);

        D.caption(S.tr().archiveAfter, cap);
        _ = D.combo("extract_delete", &deletes, &f.delete, cw);
        D.tooltip(S.tr().deleteAfterTip);

        im.ImGui_Dummy(.{ .x = 0, .y = 8 * s });
        const ok_text = D.noDots(S.tr().extract);
        D.alignRight(&.{ ok_text, S.tr().cancel });
        var ok = D.primary(true, ok_text, "extract_ok");
        im.ImGui_SameLine();
        if (D.button(S.tr().cancel, "extract_cancel") or D.escPressed()) return false;
        if (D.enterPressed()) ok = true;
        if (!ok) return true;
        const dest = std.mem.trim(u8, D.bufText(&f.dest), " \t");
        if (dest.len == 0) return false; // C#: an empty folder = cancelled
        if (f.sub) {
            var pb: [2200]u8 = undefined;
            const sep: []const u8 = if (fspath.isSep(dest[dest.len - 1])) "" else "\\";
            f.out.setDest(std.mem.print(&pb, "{s}{s}{s}", .{ dest, sep, f.sub_name }) catch dest);
        } else f.out.setDest(dest);
        f.out.mode = @fromBackingInt(@intCast(f.mode));
        f.out.options = .{ .no_paths = f.paths == 1, .update = @fromBackingInt(@intCast(f.update)), .keep_broken = f.keep_broken };
        f.out.delete = @fromBackingInt(@intCast(f.delete));
        // The choices (not the folder) are remembered for next time.
        const st = settings.current();
        st.ExtractOverwrite = f.out.mode;
        st.ExtractNoPaths = f.out.options.no_paths;
        st.ExtractUpdate = f.out.options.update;
        st.ExtractKeepBroken = f.out.options.keep_broken;
        st.ExtractDeleteAfter = f.out.delete;
        settings.commit();
        if (f.reply) |r| r.* = .{ .done = true, .button = 0 };
        f.reply = null;
        return false;
    }

    pub fn close(_: *Form, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(f: *Form, d: *Dialogs) void {
        _ = d;
        if (f.reply) |r| r.* = .{ .done = true };
        f.gpa.free(f.sub_name);
        f.gpa.destroy(f);
    }
};

/// ExtractForm.Ask: reply.button 0 = `out` filled; null = cancelled.
pub fn ask(d: *Dialogs, a: *const engine.Archive, out: *Choice, reply: *Reply) void {
    const gpa = d.ctx.gpa;
    reply.reset(gpa);
    const st = settings.current();
    const f = gpa.create(Form) catch return {
        reply.* = .{ .done = true };
    };
    f.* = .{
        .gpa = gpa,
        .sub = manyTopLevel(a),
        .sub_name = gpa.dupe(u8, engine.baseName(a.source)) catch &.{},
        .mode = @backingInt(st.ExtractOverwrite),
        .paths = @intFromBool(st.ExtractNoPaths),
        .update = @backingInt(st.ExtractUpdate),
        .delete = @backingInt(st.ExtractDeleteAfter),
        .keep_broken = st.ExtractKeepBroken,
        .out = out,
        .reply = reply,
    };
    D.setText(&f.dest, fspath.dirname(a.source) orelse "");
    D.push(d, Form, f, true);
}

// ---- AfterExtract ------------------------------------------------------------------------------------------

/// After a clean extraction of the WHOLE archive, per the dialog's choice: keep it, ask, or send it to the
/// Recycle Bin (every part of a .001 set). The caller releases the archive when `tick` says so.
const After = struct {
    reply: Reply = .{},
    run: R.Run = .{},
    source: []u8 = &.{},
    state: enum { idle, asking, release, start, recycling, done } = .idle,

    const Step = enum { working, release_now, done };

    fn start(af: *After, d: *Dialogs, source: []const u8, delete: engine.DeleteAfter) void {
        af.source = d.ctx.gpa.dupe(u8, source) catch &.{};
        switch (delete) {
            .Never => af.state = .done,
            .Ask => {
                af.state = .asking;
                var buf: [800]u8 = undefined;
                P.message(d, .question, S.app, S.fillZ(&buf, S.tr().deleteArchiveAskFmt, .{fspath.basename(source)}), .yes_no, false, &af.reply);
            },
            .Recycle => af.state = .release,
        }
    }

    fn work(r: *R.Run) anyerror!void {
        const af = r.user(After);
        try engine.recycleArchive(r.d.ctx.gpa, r.d.ctx.io, af.source, &r.diag);
    }

    fn tick(af: *After, d: *Dialogs) Step {
        switch (af.state) {
            .idle, .done => return .done,
            .asking => {
                if (!af.reply.done) return .working;
                af.state = if (af.reply.button != null) .release else .done;
                af.reply.reset(d.ctx.gpa);
                return .working;
            },
            .release => {
                af.state = .start; // the caller lets go of the archive now; recycling starts next frame
                return .release_now;
            },
            .start => {
                af.state = .recycling;
                af.run.start(d, S.tr().deleting, af, work, true);
                return .working;
            },
            .recycling => {
                _ = af.run.tick() orelse return .working;
                af.state = .done;
                return .done;
            },
        }
    }

    fn deinit(af: *After, d: *Dialogs) void {
        af.run.deinit();
        af.reply.reset(d.ctx.gpa);
        if (af.source.len > 0) d.ctx.gpa.free(af.source);
        af.source = &.{};
    }
};

fn extractWork(r: *R.Run, a: *engine.Archive, c: *const Choice, indices: ?[]const u32) anyerror!void {
    try engine.extract(r.d.ctx.gpa, r.d.ctx.io, a, c.dest(), indices, c.mode, r.progress(), r.conflicts(false), settings.current().Motw, c.options, &r.diag);
}

// ---- MainForm.DoExtract / DoExtractNoAsk -----------------------------------------------------------------------

const ExtractTask = struct {
    e: R.Ensurer = .{},
    run: R.Run = .{},
    after: After = .{},
    reply: Reply = .{},
    choice: Choice = .{},
    a: *engine.Archive,
    use: ?*engine.Archive = null,
    indices: ?[]u32,
    offer_delete: bool,
    no_ask: bool,
    state: enum { ensure, form, run, after } = .ensure,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(ExtractTask);
        try extractWork(r, t.use.?, &t.choice, t.indices);
    }

    pub fn tick(t: *ExtractTask, d: *Dialogs) bool {
        switch (t.state) {
            .ensure => {
                if (!t.e.tick(d)) return true;
                const a = t.e.result orelse return false;
                if (a != t.a) d.ctx.post(.{ .replace_archive = .{ .old = t.a, .new = a } });
                t.use = a;
                if (t.no_ask) {
                    t.state = .run;
                    t.run.start(d, S.tr().extracting, t, work, true);
                } else {
                    t.state = .form;
                    ask(d, a, &t.choice, &t.reply);
                }
                return true;
            },
            .form => {
                if (!t.reply.done) return true;
                if (t.reply.button == null) return false;
                t.state = .run;
                t.run.start(d, S.tr().extracting, t, work, true);
                return true;
            },
            .run => {
                const o = t.run.tick() orelse return true;
                // Only the whole archive on disk, extracted without an error, is ever offered for deletion.
                if (o != .ok or !t.offer_delete or t.no_ask or t.indices != null) return false;
                t.state = .after;
                t.after.start(d, t.use.?.source, t.choice.delete);
                return true;
            },
            .after => switch (t.after.tick(d)) {
                .working => return true,
                .release_now => {
                    d.ctx.post(.release_archive); // the main window closes it and shows its folder
                    t.use = null;
                    return true;
                },
                .done => {
                    d.ctx.post(.refresh);
                    return false;
                },
            },
        }
    }

    pub fn deinit(t: *ExtractTask, d: *Dialogs) void {
        t.run.deinit();
        t.after.deinit(d);
        t.e.deinit(d);
        t.reply.reset(d.ctx.gpa);
        if (t.indices) |i| d.ctx.gpa.free(i);
        d.ctx.gpa.destroy(t);
    }
};

/// `dest` non-null = DoExtractNoAsk (Alt+W): no dialog, OverwriteMode.Ask with conflicts.
pub fn extractOpen(d: *Dialogs, a: *engine.Archive, indices: ?[]const u32, offer_delete: bool, dest: ?[]const u8) void {
    const gpa = d.ctx.gpa;
    const t = gpa.create(ExtractTask) catch return;
    t.* = .{
        .a = a,
        .indices = if (indices) |i| gpa.dupe(u32, i) catch return gpa.destroy(t) else null,
        .offer_delete = offer_delete,
        .no_ask = dest != null,
    };
    if (dest) |x| t.choice.setDest(x);
    t.e.start(d, a);
    D.addTask(d, ExtractTask, t, true);
}

// ---- the extract queue (Program.Enqueue / Pump / Extract) --------------------------------------------------------

const QJob = struct {
    args: [][]u8,
    o: R.Opener = .{},
    e: R.Ensurer = .{},
    run: R.Run = .{},
    after: After = .{},
    reply: Reply = .{},
    choice: Choice = .{},
    /// Our own archive (closed at the end).
    a: ?*engine.Archive = null,
    from_dialog: bool = false,
    state: enum { open, ensure, form, run, after, done } = .open,
    /// Program.Extract's return: 0 = done, else the exit code of what ended it; `cancel_all` = Cancel in the
    /// progress (drops the rest of the queue).
    exit: u8 = 0,
    cancel_all: bool = false,

    fn work(r: *R.Run) anyerror!void {
        const j = r.user(QJob);
        try extractWork(r, j.a.?, &j.choice, null);
    }

    fn closeArchive(j: *QJob) void {
        if (j.a) |a| a.close();
        j.a = null;
    }

    /// true = finished (`exit`, `cancel_all`).
    fn tick(j: *QJob, q: *Queue, d: *Dialogs) bool {
        switch (j.state) {
            .done => return true,
            .open => {
                if (!j.o.tick(d)) return false;
                j.cancel_all = j.o.aborted;
                j.a = j.o.archive orelse return j.finish(j.o.exit);
                j.o.archive = null;
                j.state = .ensure;
                j.e.start(d, j.a.?); // bodies encrypted but headers not
                return false;
            },
            .ensure => {
                if (!j.e.tick(d)) return false;
                const ready = j.e.result orelse return j.finish(255);
                if (ready != j.a.?) {
                    j.a.?.close();
                    j.a = ready;
                }
                const job = pd.parseExtractJob(@ptrCast(j.args));
                const full = engine.fullPath(d.ctx.gpa, job.archive) catch null;
                defer if (full) |f| d.ctx.gpa.free(f);
                const dir = if (full) |f| fspath.dirname(f) orelse "." else ".";
                if (job.here) {
                    j.choice.setDest(dir);
                } else if (job.sub) {
                    var buf: [2200]u8 = undefined;
                    j.choice.setDest(std.mem.print(&buf, "{s}\\{s}", .{ std.mem.trimEnd(u8, dir, "\\"), engine.baseName(job.archive) }) catch dir);
                } else if (job.dest) |o| {
                    j.choice.setDest(o);
                } else {
                    j.from_dialog = true;
                    j.state = .form;
                    ask(d, j.a.?, &j.choice, &j.reply);
                    return false;
                }
                j.startRun(q, d);
                return false;
            },
            .form => {
                if (!j.reply.done) return false;
                if (j.reply.button == null) return j.finish(255);
                j.startRun(q, d);
                return false;
            },
            .run => {
                const o = j.run.tick() orelse return false;
                switch (o) {
                    .cancelled => {
                        j.cancel_all = true;
                        return j.finish(255);
                    },
                    // ponytail (C#): the last failure's code wins, as archivers do over a list of archives.
                    .failed => return j.finish(engine.exitCodeOf(j.run.err orelse error.Unexpected)),
                    .ok => {},
                }
                if (!j.from_dialog) return j.finish(0);
                j.state = .after;
                j.after.start(d, j.a.?.source, j.choice.delete);
                return false;
            },
            .after => switch (j.after.tick(d)) {
                .working => return false,
                .release_now => {
                    j.closeArchive();
                    return false;
                },
                .done => return j.finish(0),
            },
        }
    }

    fn startRun(j: *QJob, q: *Queue, d: *Dialogs) void {
        j.state = .run;
        j.run.id = "queue";
        var tb: [600]u8 = undefined;
        const title = S.fillZ(&tb, S.tr().extractingNofM, .{ q.done, q.total, fspath.basename(j.args[1]) });
        j.run.start(d, title, j, work, false);
    }

    fn finish(j: *QJob, exit: u8) bool {
        j.exit = exit;
        j.state = .done;
        j.closeArchive();
        return true;
    }

    fn deinit(j: *QJob, d: *Dialogs) void {
        j.run.deinit();
        j.after.deinit(d);
        j.e.deinit(d);
        j.o.deinit(d);
        j.reply.reset(d.ctx.gpa);
        j.closeArchive();
        for (j.args) |s| d.ctx.gpa.free(s);
        d.ctx.gpa.free(j.args);
        d.ctx.gpa.destroy(j);
    }
};

pub const Queue = struct {
    jobs: std.ArrayList([][]u8) = .empty,
    cur: ?*QJob = null,
    done: usize = 0,
    total: usize = 0,

    pub fn enqueue(q: *Queue, d: *Dialogs, args: []const []const u8) void {
        const gpa = d.ctx.gpa;
        const copy = gpa.alloc([]u8, args.len) catch return;
        for (args, 0..) |s, i| copy[i] = gpa.dupe(u8, s) catch {
            for (copy[0..i]) |x| gpa.free(x);
            return gpa.free(copy);
        };
        q.jobs.append(gpa, copy) catch {
            for (copy) |x| gpa.free(x);
            return gpa.free(copy);
        };
        q.total += 1;
    }

    pub fn busy(q: *const Queue) bool {
        return q.cur != null or q.jobs.items.len > 0;
    }

    pub fn tick(q: *Queue, d: *Dialogs) void {
        if (q.cur == null) {
            if (q.jobs.items.len == 0) {
                q.done = 0;
                q.total = 0;
                return;
            }
            const args = q.jobs.orderedRemove(0);
            const j = d.ctx.gpa.create(QJob) catch {
                for (args) |x| d.ctx.gpa.free(x);
                return d.ctx.gpa.free(args);
            };
            j.* = .{ .args = args };
            q.done += 1;
            q.cur = j;
            // the prompts come first: a progress bar behind a password box helps nobody
            j.o.start(d, args[1], null);
        }
        const j = q.cur.?;
        if (!j.tick(q, d)) return;
        if (j.exit != 0) d.ctx.exit_code = j.exit;
        if (j.cancel_all) q.dropAll(d);
        q.cur = null;
        j.deinit(d);
        d.ctx.app.requestFrames(2);
    }

    fn dropAll(q: *Queue, d: *Dialogs) void {
        for (q.jobs.items) |args| {
            for (args) |x| d.ctx.gpa.free(x);
            d.ctx.gpa.free(args);
        }
        q.jobs.clearRetainingCapacity();
    }

    /// The OS window's close button without a main window: Cancel (C#: closing ProgressForm).
    pub fn cancelAll(q: *Queue, d: *Dialogs) void {
        q.dropAll(d);
        if (q.cur) |j| j.run.cancel();
    }

    pub fn deinit(q: *Queue, d: *Dialogs) void {
        q.dropAll(d);
        q.jobs.deinit(d.ctx.gpa);
        if (q.cur) |j| j.deinit(d);
        q.cur = null;
    }
};
