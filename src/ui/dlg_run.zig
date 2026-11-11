//! MP-G2: the long-work plumbing every dialog shares.
//!   Run      = ProgressForm.Run / RunAsync: a kit job + its progress window (label, bar, Cancel; X/Esc = Cancel),
//!              the file-exists question asked from 7z.dll's thread (ExtractForm.Conflicts), the error alert.
//!   Opener   = PasswordForm.OpenArchive (each failure its own alert, wrong password re-asks); the open on a job.
//!   Ensurer  = PasswordForm.EnsurePassword (bodies encrypted, file list not).
//! All three are fields of a heap object (they must not move) and are polled: `tick` returns null while working.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");

const S = C.S;
const engine = C.engine;
const im = kit.im;
const w = kit.w;
const Dialogs = D.Dialogs;
const Reply = P.Reply;

// ---- the file-exists question from a worker thread ---------------------------------------------------------

/// engine.Conflict for a job: the worker blocks until the UI thread has an answer (Run.tick asks).
pub const Asker = struct {
    lock: kit.win.Lock = .{},
    event: w.HANDLE = null,
    append: bool = false,
    pending: bool = false,
    asking: bool = false,
    aborted: bool = false,
    path: [2048]u8 = undefined,
    path_len: usize = 0,
    answer: ?engine.OverwriteMode = null,
    /// "Apply to all" (C#'s sticky).
    sticky: ?engine.OverwriteMode = null,
    reply: Reply = .{},

    pub fn conflict(a: *Asker) engine.Conflict {
        return .{ .ctx = a, .ask = ask };
    }

    fn ask(ctx: ?*anyopaque, path: []const u8) ?engine.OverwriteMode {
        const a: *Asker = @ptrCast(@alignCast(ctx));
        a.lock.lock();
        if (a.sticky) |m| {
            a.lock.unlock();
            return m;
        }
        if (a.aborted or a.event == null) {
            a.lock.unlock();
            return null;
        }
        const n = @min(path.len, a.path.len);
        @memcpy(a.path[0..n], path[0..n]);
        a.path_len = n;
        a.answer = null;
        a.pending = true;
        a.lock.unlock();
        kit.app.wakeGlobal();
        _ = w.WaitForSingleObject(a.event, w.INFINITE);
        a.lock.lock();
        defer a.lock.unlock();
        return a.answer;
    }

    /// UI thread, every frame.
    fn tick(a: *Asker, d: *Dialogs) void {
        a.lock.lock();
        const pending = a.pending;
        a.lock.unlock();
        if (!pending) return;
        if (!a.asking) {
            a.asking = true;
            P.askConflict(d, a.path[0..a.path_len], a.append, &a.reply);
            return;
        }
        if (!a.reply.done) return;
        const m: ?engine.OverwriteMode = if (a.reply.button) |b| switch (b) {
            0 => .Overwrite,
            1 => .Skip,
            else => .Rename,
        } else null;
        a.lock.lock();
        if (a.reply.flag1 and m != null) a.sticky = m;
        a.answer = m;
        a.pending = false;
        a.lock.unlock();
        a.asking = false;
        a.reply = .{};
        _ = w.SetEvent(a.event);
    }

    /// Cancel / teardown: a waiting worker gets "cancelled", later questions too.
    fn abort(a: *Asker) void {
        a.lock.lock();
        a.aborted = true;
        a.answer = null;
        a.pending = false;
        a.lock.unlock();
        if (a.event != null) _ = w.SetEvent(a.event);
    }
};

// ---- ProgressForm ------------------------------------------------------------------------------------------

pub const Outcome = enum { ok, cancelled, failed };

pub const Work = *const fn (r: *Run) anyerror!void;

pub const Run = struct {
    pub const win_id = "progress";
    d: *Dialogs = undefined,
    /// start() was called (d is set).
    started: bool = false,
    job: kit.jobs.Job = .{},
    asker: Asker = .{},
    work: Work = undefined,
    /// The caller's object (r.user(T) in the work function).
    user_ptr: ?*anyopaque = null,
    diag: engine.Diag = .{},
    err: ?anyerror = null,
    err_text: [1536]u8 = undefined,
    err_len: usize = 0,
    title_buf: [512]u8 = undefined,
    title_len: usize = 0,
    /// The window's id: "progress" (modal) or "queue" (the extract queue's modeless one).
    id: []const u8 = "progress",
    state: enum { idle, running, alert, done } = .idle,
    shown: bool = false,
    cancel_pressed: bool = false,
    alert_reply: Reply = .{},
    outcome: Outcome = .ok,
    /// Report errors with an alert (C# Run/RunAsync did); false = the caller looks at `err`.
    report_errors: bool = true,

    pub fn user(r: *Run, comptime T: type) *T {
        return @ptrCast(@alignCast(r.user_ptr.?));
    }

    /// Starts `work` on a job and shows the progress window (modal over the main window / dialogs, or the
    /// queue's modeless one). Restartable after `tick` returned an outcome.
    pub fn start(r: *Run, d: *Dialogs, caption: []const u8, user_ptr: ?*anyopaque, work: Work, modal: bool) void {
        r.d = d;
        r.started = true;
        r.user_ptr = user_ptr;
        r.work = work;
        r.setTitle(caption);
        r.err = null;
        r.err_len = 0;
        r.diag = .{};
        r.cancel_pressed = false;
        r.alert_reply = .{};
        r.asker.lock.lock();
        r.asker.sticky = null;
        r.asker.aborted = false;
        r.asker.pending = false;
        r.asker.lock.unlock();
        r.asker.asking = false;
        if (r.asker.event == null) r.asker.event = w.CreateEventW(null, 0, 0, null);
        r.job.start(r, worker) catch |e| {
            r.err = e;
            r.state = .alert;
            r.shown = false;
            return r.failAlert();
        };
        r.state = .running;
        r.shown = true;
        D.pushAs(d, Run, r, modal, if (std.mem.eql(u8, r.id, "queue")) "queue" else null);
    }

    pub fn setTitle(r: *Run, caption: []const u8) void {
        const n = @min(caption.len, r.title_buf.len);
        @memcpy(r.title_buf[0..n], caption[0..n]);
        r.title_len = n;
    }

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const r: *Run = @fieldParentPtr("job", job);
        kit.win.comInitSta() catch {}; // the Recycle Bin (delete sources, convert) is shell COM
        defer kit.win.comUninit();
        job.setTotal(100);
        r.work(r) catch |e| {
            r.err = e;
            const t = engine.friendly(e, &r.diag); // threadlocal buffer: copy it here
            const n = @min(t.len, r.err_text.len);
            @memcpy(r.err_text[0..n], t[0..n]);
            r.err_len = n;
        };
    }

    /// engine.Progress for the work function (percent + current file into the window, the job's cancel flag).
    pub fn progress(r: *Run) engine.Progress {
        return .{ .ctx = r, .report = report, .cancel = &r.job.cancel_flag };
    }

    fn report(ctx: ?*anyopaque, percent: u8, file: []const u8) void {
        const r: *Run = @ptrCast(@alignCast(ctx));
        r.job.setDone(percent);
        r.job.setStatus("{s}", .{file});
    }

    pub fn conflicts(r: *Run, append: bool) engine.Conflict {
        r.asker.append = append;
        return r.asker.conflict();
    }

    pub fn cancelled(r: *Run) bool {
        return r.job.cancelled();
    }

    pub fn errText(r: *const Run) []const u8 {
        return r.err_text[0..r.err_len];
    }

    /// null while running (or while its error alert is up); then the outcome, once.
    pub fn tick(r: *Run) ?Outcome {
        switch (r.state) {
            .idle, .done => return null,
            .running => {
                r.asker.tick(r.d);
                if (!r.job.takeFinished()) return null;
                if (r.shown) r.d.dropWin(r);
                r.shown = false;
                if (r.err) |e| {
                    if (e == error.Canceled) return r.finish(.cancelled);
                    if (!r.report_errors) return r.finish(.failed);
                    r.state = .alert;
                    r.failAlert();
                    return null;
                }
                if (r.job.cancelled()) return r.finish(.cancelled);
                return r.finish(.ok);
            },
            .alert => {
                if (!r.alert_reply.done) return null;
                return r.finish(.failed);
            },
        }
    }

    fn failAlert(r: *Run) void {
        if (r.err_len == 0) {
            const t = engine.friendly(r.err.?, null);
            const n = @min(t.len, r.err_text.len);
            @memcpy(r.err_text[0..n], t[0..n]);
            r.err_len = n;
        }
        P.message(r.d, .err, S.tr().@"error", r.errText(), .ok, false, &r.alert_reply);
    }

    fn finish(r: *Run, o: Outcome) Outcome {
        r.state = .idle;
        r.outcome = o;
        return o;
    }

    pub fn running(r: *const Run) bool {
        return r.state == .running or r.state == .alert;
    }

    /// The Cancel button (also X and Esc): stops the job; a pending question is answered "cancel".
    pub fn cancel(r: *Run) void {
        r.cancel_pressed = true;
        r.job.cancel();
        r.asker.abort();
    }

    /// Owner's deinit: cancels and joins.
    pub fn deinit(r: *Run) void {
        if (!r.started) return;
        if (r.job.thread != null) {
            r.cancel();
            r.job.join();
        }
        if (r.shown) r.d.dropWin(r);
        r.shown = false;
        if (r.asker.event != null) _ = w.CloseHandle(r.asker.event);
        r.asker.event = null;
        r.asker.reply.reset(r.d.ctx.gpa);
    }

    // ---- the window (Win interface; owned by the Run's owner: dropWin, never deinit from the sweep) ----

    pub fn title(r: *Run, _: []u8) []const u8 {
        return r.title_buf[0..r.title_len];
    }

    pub fn body(r: *Run, d: *Dialogs) bool {
        _ = d;
        const s = D.scale();
        var sb: [512]u8 = undefined;
        const file = r.job.status(&sb);
        var lb: [1100]u8 = undefined;
        const t = r.title_buf[0..r.title_len];
        // ProgressForm's label: "Title…" or "Title: file"
        const label: []const u8 = if (file.len == 0)
            std.mem.print(&lb, "{s}\u{2026}", .{t}) catch t
        else
            S.fillZ(&lb, S.tr().labelValueFmt, .{ t, file });
        var ib: [64]u8 = undefined;
        const status_id = std.mem.print(&ib, "{s}_status", .{r.id}) catch "progress_status";
        var fb: [700]u8 = undefined;
        kit.ui.text(status_id, fit(label, 436 * s, &fb), null, 0);
        const pct: u32 = @intFromFloat(@round(r.job.progress() * 100));
        var ob: [16]u8 = undefined;
        const overlay = std.mem.printSentinel(&ob, "{d}%", .{pct}, 0) catch "";
        im.ImGui_ProgressBar(r.job.progress(), .{ .x = 436 * s, .y = 0 }, overlay.ptr);
        D.alignRight(&.{S.tr().cancel});
        var cb: [64]u8 = undefined;
        const cancel_id = std.mem.print(&cb, "{s}_cancel", .{r.id}) catch "progress_cancel";
        if (D.buttonOn(!r.cancel_pressed, S.tr().cancel, cancel_id) or D.escPressed()) r.cancel();
        return true;
    }

    /// X = Cancel, never an orphaned job (ProgressForm.OnFormClosing).
    pub fn close(r: *Run, _: *Dialogs) bool {
        r.cancel();
        return false;
    }

    pub fn hidden(r: *Run) bool {
        return !r.shown;
    }

    /// Win.deinit: the owner frees the Run (dropWin), so nothing here.
    pub fn deinitWin(_: *Run, _: *Dialogs) void {}
};

/// AutoEllipsis: the label cut with "…" to fit `width`.
fn fit(text: []const u8, width: f32, buf: []u8) []const u8 {
    if (im.ImGui_CalcTextSizeEx(text.ptr, text.ptr + text.len, false, -1).x <= width) return text;
    var n = text.len;
    while (n > 0) {
        n -= 1;
        while (n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
        const s = std.mem.print(buf, "{s}\u{2026}", .{text[0..@min(n, buf.len - 8)]}) catch return text;
        if (im.ImGui_CalcTextSizeEx(s.ptr, s.ptr + s.len, false, -1).x <= width) return s;
    }
    return text;
}

// ---- engine.open on a job ------------------------------------------------------------------------------------

/// engine.open on a job + its progress window (after `show_after_ms`: a quick open shows nothing): the file name,
/// an indeterminate bar, Cancel (also X and Esc) = engine.open's cancel flag; the open stops at its next progress
/// call and `err` becomes error.Canceled. Polled with `finished`. Must not move while running (a field of a heap
/// object).
pub const OpenJob = struct {
    pub const win_id = "opening";
    const show_after_ms = 300;
    d: *Dialogs = undefined,
    job: kit.jobs.Job = .{},
    running: bool = false,
    path: []u8 = &.{},
    password: ?[]u8 = null,
    t0: u64 = 0,
    shown: bool = false,
    cancel_pressed: bool = false,
    diag: engine.Diag = .{},
    result: ?*engine.Archive = null,
    err: ?anyerror = null,
    err_text: [1536]u8 = undefined,
    err_len: usize = 0,

    /// Copies `path` / `password`. false = it could not start (`err`).
    pub fn start(o: *OpenJob, d: *Dialogs, path: []const u8, password: ?[]const u8) bool {
        o.d = d;
        o.result = null;
        o.err = null;
        o.err_len = 0;
        o.diag = .{};
        o.cancel_pressed = false;
        o.freeArgs();
        const gpa = d.ctx.gpa;
        o.path = gpa.dupe(u8, path) catch |e| return o.failStart(e);
        if (password) |p| o.password = gpa.dupe(u8, p) catch |e| return o.failStart(e);
        o.job.start(o, run) catch |e| return o.failStart(e);
        o.running = true;
        o.t0 = w.GetTickCount64();
        return true;
    }

    fn failStart(o: *OpenJob, e: anyerror) bool {
        o.err = e;
        o.freeArgs();
        return false;
    }

    fn run(job: *kit.jobs.Job) anyerror!void {
        const o: *OpenJob = @fieldParentPtr("job", job);
        o.result = engine.open(o.d.ctx.gpa, o.d.ctx.io, o.path, o.password, .{ .cancel = &job.cancel_flag }, &o.diag) catch |e| {
            o.err = e;
            const t = engine.friendly(e, &o.diag); // threadlocal buffer: copy it here
            const n = @min(t.len, o.err_text.len);
            @memcpy(o.err_text[0..n], t[0..n]);
            o.err_len = n;
            return;
        };
    }

    /// true once finished (`result`, or `err`: error.Canceled after Cancel). Shows the window when it takes a while.
    pub fn finished(o: *OpenJob) bool {
        if (!o.running) return true;
        if (!o.job.takeFinished()) {
            if (!o.shown and w.GetTickCount64() -% o.t0 >= show_after_ms) {
                o.shown = true;
                D.push(o.d, OpenJob, o, o.d.ctx.has_main_window);
            }
            return false;
        }
        o.running = false;
        o.hide();
        o.freeArgs();
        if (o.cancel_pressed) { // it finished before it saw the flag: the user still asked to stop
            if (o.result) |a| a.close();
            o.result = null;
            o.err = error.Canceled;
        }
        return true;
    }

    fn cancel(o: *OpenJob) void {
        o.cancel_pressed = true;
        o.job.cancel();
    }

    fn hide(o: *OpenJob) void {
        if (o.shown) o.d.dropWin(o);
        o.shown = false;
    }

    fn freeArgs(o: *OpenJob) void {
        const gpa = if (o.path.len > 0 or o.password != null) o.d.ctx.gpa else return;
        if (o.path.len > 0) gpa.free(o.path);
        o.path = &.{};
        if (o.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        o.password = null;
    }

    /// Ended by Cancel.
    pub fn cancelled(o: *const OpenJob) bool {
        return if (o.err) |e| e == error.Canceled else false;
    }

    pub fn errText(o: *const OpenJob) []const u8 {
        if (o.err_len == 0) return engine.friendly(o.err orelse error.Unexpected, null);
        return o.err_text[0..o.err_len];
    }

    /// Teardown: a running open is cancelled and waited for, an archive nobody took is closed.
    pub fn deinit(o: *OpenJob) void {
        if (o.running) {
            o.job.cancel();
            o.job.join();
            o.running = false;
        }
        o.hide();
        if (o.result) |a| a.close();
        o.result = null;
        o.freeArgs();
    }

    // ---- the window (Win; the OpenJob's owner owns it: dropWin, never deinit from the sweep) ----

    pub fn title(o: *OpenJob, _: []u8) []const u8 {
        return std.Io.Dir.path.basename(o.path);
    }

    pub fn body(o: *OpenJob, d: *Dialogs) bool {
        _ = d;
        const s = D.scale();
        var lb: [400]u8 = undefined;
        const name = std.Io.Dir.path.basename(o.path);
        const label = std.mem.print(&lb, "{s}: {s}\u{2026}", .{ S.tr().openCmd, name }) catch name;
        var fb: [700]u8 = undefined;
        kit.ui.text("opening_status", fit(label, 436 * s, &fb), null, 0);
        im.ImGui_ProgressBar(-1.0 * @as(f32, @floatCast(im.ImGui_GetTime())), .{ .x = 436 * s, .y = 0 }, "");
        D.alignRight(&.{S.tr().cancel});
        if (D.buttonOn(!o.cancel_pressed, S.tr().cancel, "opening_cancel") or D.escPressed()) o.cancel();
        return true;
    }

    /// X = Cancel (the window goes when the job has stopped).
    pub fn close(o: *OpenJob, _: *Dialogs) bool {
        o.cancel();
        return false;
    }

    pub fn hidden(o: *OpenJob) bool {
        return !o.shown;
    }

    pub fn deinitWin(_: *OpenJob, _: *Dialogs) void {}
};

/// Whether a 7z's header could be AES-encrypted: false when the file starts with the 7z signature and its next
/// header is a plain header (kHeader) or a packed one (kEncodedHeader) without the AES coder. Then a failed open
/// is damage (a corrupt packed header stream; its CRC is only checked after unpacking, which 7-Zip reports like a
/// wrong password), never a password question. Anything else / unreadable: true (the old ask-for-a-password path).
// ponytail: the AES coder id 06F10701 is searched in the encoded header's bytes instead of parsing its
// StreamsInfo; a chance match in a size field only means the old behaviour (a password prompt).
fn sevenZipMayBeEncrypted(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return true;
    defer f.close(io);
    var head: [32]u8 = undefined;
    if ((f.readPositionalAll(io, &head, 0) catch return true) != 32) return true;
    if (!std.mem.eql(u8, head[0..6], "7z\xBC\xAF\x27\x1C")) return true;
    const off = std.mem.readInt(u64, head[12..20], .little);
    const size = std.mem.readInt(u64, head[20..28], .little);
    if (size == 0 or off > std.math.maxInt(u64) - 32) return true;
    var next: [4096]u8 = undefined;
    const want: usize = @intCast(@min(size, next.len));
    const got = f.readPositionalAll(io, next[0..want], 32 + off) catch return true;
    return headerMayBeEncrypted(next[0..got]);
}

fn headerMayBeEncrypted(next: []const u8) bool {
    if (next.len == 0) return true;
    return switch (next[0]) {
        0x01 => false, // kHeader: stored as is
        0x17 => std.mem.find(u8, next, "\x06\xF1\x07\x01") != null, // kEncodedHeader: AES among its coders?
        else => true,
    };
}

test "7z header: plain / packed / AES" {
    try std.testing.expect(!headerMayBeEncrypted("\x01\x04\x06"));
    try std.testing.expect(!headerMayBeEncrypted("\x17\x06\x80\x01\x01\x09\x30\x00\x07\x0B\x01\x00\x01\x23\x03\x01\x01\x05\x5D"));
    try std.testing.expect(headerMayBeEncrypted("\x17\x06\x80\x01\x01\x09\x30\x00\x07\x0B\x01\x00\x02\x24\x06\xF1\x07\x01\x0A"));
    try std.testing.expect(headerMayBeEncrypted(""));
}

// ---- PasswordForm.OpenArchive ------------------------------------------------------------------------------

pub const Opener = struct {
    path: []u8 = &.{},
    /// The password being tried (owned).
    password: ?[]u8 = null,
    try_only: bool = false,
    state: enum { idle, opening, asking, alerting, done } = .idle,
    reply: Reply = .{},
    oj: OpenJob = .{},
    /// The result: the archive (caller owns it) or null with `exit` (Engine.ExitCodeOf; 255 = cancelled).
    archive: ?*engine.Archive = null,
    exit: u8 = 255,
    /// The open's progress was cancelled (the queue then drops the rest, as with its own progress).
    aborted: bool = false,

    /// `password` non-null = TryOpen (no prompts; an error is one alert).
    pub fn start(o: *Opener, d: *Dialogs, path: []const u8, password: ?[]const u8) void {
        const gpa = d.ctx.gpa;
        o.free(gpa);
        o.path = gpa.dupe(u8, path) catch return o.done(255);
        o.try_only = password != null;
        o.password = if (password) |p| gpa.dupe(u8, p) catch null else null;
        o.archive = null;
        o.exit = 255;
        o.aborted = false;
        if (o.try_only) return o.open(d);
        if (!engine.fileExists(path)) {
            o.exit = 10;
            return o.alert(d, S.tr().fileNotFoundFmt, path);
        }
        switch (engine.probe(d.ctx.io, path)) {
            // a password could not help: never prompt
            .not_archive => {
                o.exit = 2;
                return o.alert(d, S.tr().notAnArchive, null);
            },
            .damaged => {
                o.exit = 3;
                return o.alert(d, S.tr().damaged, null);
            },
            .encrypted_headers => return o.ask(d, null),
            .archive => o.open(d),
        }
    }

    fn open(o: *Opener, d: *Dialogs) void {
        o.state = .opening;
        if (!o.oj.start(d, o.path, o.password)) {
            o.exit = engine.exitCodeOf(o.oj.err.?);
            o.alert(d, o.oj.errText(), null);
        }
    }

    fn ask(o: *Opener, d: *Dialogs, prompt: ?[]const u8) void {
        o.state = .asking;
        P.askPassword(d, std.Io.Dir.path.basename(o.path), prompt, &o.reply);
    }

    fn alert(o: *Opener, d: *Dialogs, template: []const u8, arg: ?[]const u8) void {
        var buf: [2048]u8 = undefined;
        const t = if (arg) |a| S.fillZ(&buf, template, .{a}) else template;
        o.state = .alerting;
        P.message(d, .err, S.tr().cannotOpen, t, .ok, false, &o.reply);
    }

    fn done(o: *Opener, exit: u8) void {
        o.exit = exit;
        o.state = .done;
    }

    /// true when finished: `archive` (taken by the caller) or null with `exit`.
    pub fn tick(o: *Opener, d: *Dialogs) bool {
        switch (o.state) {
            .idle => return false,
            .done => return true,
            .alerting => {
                if (!o.reply.done) return false;
                o.reply.reset(d.ctx.gpa);
                o.state = .done;
                return true;
            },
            .asking => {
                if (!o.reply.done) return false;
                const pw = o.reply.takeText();
                o.reply.reset(d.ctx.gpa);
                if (pw == null) {
                    o.done(255);
                    return true;
                }
                o.setPassword(d, pw.?);
                o.open(d);
                return false;
            },
            .opening => {
                if (!o.oj.finished()) return false;
                if (o.oj.result) |a| {
                    o.oj.result = null;
                    o.archive = a;
                    // opened, but partial (a truncated zip / tar): say so instead of a silently short list
                    if (engine.openWarning(a.x.props)) |t| d.alert(.warning, a.display(), t);
                    o.done(0);
                    return true;
                }
                const e = o.oj.err orelse error.Unexpected;
                if (e == error.Canceled) {
                    o.aborted = true;
                    o.done(255);
                    return true;
                }
                // ponytail (C#): an intact 7z/rar that will not open IS the encrypted-headers case; a codec 7z.dll
                // cannot handle is then reported as a wrong password.
                if (o.try_only or !engine.canEncryptHeaders(d.ctx.io, o.path)) {
                    o.exit = engine.exitCodeOf(e);
                    o.alert(d, o.oj.errText(), null);
                    return false;
                }
                // a 7z whose header is not encrypted cannot want a password: its own "damaged" alert
                if (!sevenZipMayBeEncrypted(d.ctx.io, o.path)) {
                    o.exit = 3;
                    o.alert(d, S.tr().damaged, null);
                    return false;
                }
                o.ask(d, if (o.password == null) S.tr().enterPassword else S.tr().wrongPasswordRetry);
                return false;
            },
        }
    }

    fn setPassword(o: *Opener, d: *Dialogs, pw: []u8) void {
        if (o.password) |p| {
            std.crypto.secureZero(u8, p);
            d.ctx.gpa.free(p);
        }
        o.password = pw;
    }

    pub fn busy(o: *const Opener) bool {
        return o.state != .idle and o.state != .done;
    }

    fn free(o: *Opener, gpa: std.mem.Allocator) void {
        if (o.path.len > 0) gpa.free(o.path);
        o.path = &.{};
        if (o.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        o.password = null;
    }

    pub fn deinit(o: *Opener, d: *Dialogs) void {
        o.oj.deinit();
        if (o.archive) |a| a.close();
        o.archive = null;
        o.reply.reset(d.ctx.gpa);
        o.free(d.ctx.gpa);
    }
};

// ---- PasswordForm.EnsurePassword -------------------------------------------------------------------------

pub const Ensurer = struct {
    src: ?*engine.Archive = null,
    state: enum { idle, asking, opening, alerting, done } = .idle,
    reply: Reply = .{},
    oj: OpenJob = .{},
    password: ?[]u8 = null,
    source: []u8 = &.{},
    /// The archive to use: `src` itself, a NEW instance (the caller owns both), or null = cancelled / failed.
    result: ?*engine.Archive = null,

    pub fn start(e: *Ensurer, d: *Dialogs, a: *engine.Archive) void {
        e.src = a;
        e.result = null;
        if (a.password != null or !anyEncrypted(a)) {
            e.result = a;
            e.state = .done;
            return;
        }
        e.state = .asking;
        P.askPassword(d, a.display(), null, &e.reply);
    }

    pub fn tick(e: *Ensurer, d: *Dialogs) bool {
        switch (e.state) {
            .idle => return false,
            .done => return true,
            .asking => {
                if (!e.reply.done) return false;
                e.password = e.reply.takeText();
                e.reply.reset(d.ctx.gpa);
                if (e.password == null) {
                    e.state = .done;
                    return true;
                }
                e.source = d.ctx.gpa.dupe(u8, e.src.?.source) catch {
                    e.state = .done;
                    return true;
                };
                e.state = .opening;
                if (!e.oj.start(d, e.source, e.password)) e.failAlert(d);
                return false;
            },
            .opening => {
                if (!e.oj.finished()) return false;
                if (e.oj.result) |a| {
                    e.oj.result = null;
                    e.result = a;
                    e.state = .done;
                    return true;
                }
                if (e.oj.cancelled()) {
                    e.state = .done;
                    return true;
                }
                e.failAlert(d);
                return false;
            },
            .alerting => {
                if (!e.reply.done) return false;
                e.reply.reset(d.ctx.gpa);
                e.state = .done;
                return true;
            },
        }
    }

    fn failAlert(e: *Ensurer, d: *Dialogs) void {
        e.state = .alerting;
        P.message(d, .err, S.tr().cannotOpen, e.oj.errText(), .ok, false, &e.reply);
    }

    pub fn deinit(e: *Ensurer, d: *Dialogs) void {
        e.oj.deinit();
        e.reply.reset(d.ctx.gpa);
        if (e.password) |p| {
            std.crypto.secureZero(u8, p);
            d.ctx.gpa.free(p);
        }
        e.password = null;
        if (e.source.len > 0) d.ctx.gpa.free(e.source);
        e.source = &.{};
    }
};

pub fn anyEncrypted(a: *const engine.Archive) bool {
    for (a.items()) |it| if (it.encrypted) return true;
    return false;
}
