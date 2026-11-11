//! MP-G2: every dialog + Program.Dispatch (legacy/src/MakePack/Program.cs, *Form.cs except MainForm).
//! Owner: MP-G2 = this file + src/ui/dlg_*.zig. The public API below is the CONTRACT with MP-G1 (main window):
//! add to it freely, change a signature only with a line in docs/ZIG-PORT.md "Contract changes".
//!
//! Model (immediate mode, nothing blocks): every entry point only OPENS something and returns at once; the dialog
//! is drawn by `draw` every frame (after MainWindow.draw), long work runs on kit.jobs with progress + Cancel, and
//! results reach the main window through the request channel (ctx.zig: `ctx.post(...)`, handled next frame).
//! The C# modal call sites of MainForm map 1:1 to the functions below (comment = the C# call site).
//!
//! Rules both sides rely on:
//! - Slices passed in are copied; they need to live only during the call.
//! - `a: *engine.Archive` = the main window's open archive, BORROWED: the dialogs use it only while `modal()` is
//!   true and never close it. While `modal()` is true the main window takes no input (menus, hotkeys, clicks),
//!   defers MainWindow.open, and neither closes nor replaces its archive - except on .detach_archive /
//!   .replace_archive / .release_archive, which only the dialogs post.
//! - Edits (deleteEntries / renameEntry / addToArchive) consume the archive: they post .detach_archive (the main
//!   window drops it without closing), run the engine edit (which closes it) and post .reopen at the end - also when
//!   cancelled or failed, so the archive always comes back.
//! - EnsurePassword (PasswordForm.EnsurePassword, C# Ready()) happens inside every operation on `a` that reads
//!   bodies; a new instance is handed over with .replace_archive before the job starts.
//! - Every failure is its own alert (not an archive / damaged / enter password / wrong password / engine.friendly
//!   text), never a combined "either/or" message.
//! - The extract queue (dispatch "x") has ONE modeless progress window "n of N" (S.extractingNofM); without a
//!   main window it is the whole OS window (progress-only mode: Explorer's "Extract here / to").
//! - Automation: every widget label carries a stable "##id" (dialog ids: compress, extract, password, progress,
//!   queue, conflict, settings, assoc, convert, info, viewer, find, favorites, name, msg); texts a test reads are
//!   labelled items, and a dialog's window title is its ImGui window name.
//! - Without a main window (ctx.has_main_window false) the dialogs own the OS window: size, title, visibility.
//!
//! Inside (G2 only): `Win` = one ImGui window (modal = a popup on the modal stack, nested in the one below it);
//! `Task` = a flow polled every frame (prompts answer it through a `Reply` it owns). dlg_*.zig hold the dialogs.
const std = @import("std");
const kit = @import("kit");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const ops = @import("dlg_ops.zig");
const compress_dlg = @import("dlg_compress.zig");
const extract_dlg = @import("dlg_extract.zig");
const settings_dlg = @import("dlg_settings.zig");
const assoc_dlg = @import("dlg_assoc.zig");
const convert_dlg = @import("dlg_convert.zig");
const info_dlg = @import("dlg_info.zig");
const viewer_dlg = @import("dlg_viewer.zig");
const find_dlg = @import("dlg_find.zig");

const Ctx = C.Ctx;
const Token = C.Token;
const S = C.S;
const engine = C.engine;
const pd = C.platform_dispatch;
const Allocator = std.mem.Allocator;
const im = kit.im;
const w = kit.w;

pub const Reply = P.Reply;

/// One ImGui window of the dialogs. Heap-allocated (pointers stay valid while the list grows).
pub const Win = struct {
    ptr: *anyopaque,
    vt: *const VT,
    modal: bool,
    serial: u32,
    /// The ImGui id when it differs from vt.id (the queue's Run: "queue", not "progress").
    id: ?[]const u8 = null,
    /// Modal: OpenPopup was called (reset when ImGui closed it under us: it is reopened).
    opened: bool = false,
    closed: bool = false,
    /// The owner took it away (dropWin): no deinit from the sweep.
    dropped: bool = false,

    pub const VT = struct {
        id: []const u8,
        /// The visible title (the ImGui name is title ++ "###" ++ id ++ serial).
        title: *const fn (*anyopaque, []u8) []const u8,
        /// Draws the contents. false = close (then deinit).
        body: *const fn (*anyopaque, *Dialogs) bool,
        /// The title bar's X: true = close now. null = no X.
        close: ?*const fn (*anyopaque, *Dialogs) bool,
        deinit: *const fn (*anyopaque, *Dialogs) void,
        /// Initial size (logical px) of a resizable window; null = sized to its contents.
        size: ?[2]f32,
        /// Not drawn this frame (the queue's progress while a prompt for its job is up).
        hidden: ?*const fn (*anyopaque) bool,
        menu_bar: bool,
    };

    /// T: `const win_id`, `fn title(*T, []u8) []const u8`, `fn body(*T, *Dialogs) bool`, `fn deinit(*T, *Dialogs)`;
    /// optional `fn close(*T, *Dialogs) bool` (X button), `const win_size: [2]f32`, `fn hidden(*T) bool`,
    /// `const menu_bar = true`.
    pub fn vtOf(comptime T: type) *const VT {
        const G = struct {
            fn cast(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn title(p: *anyopaque, b: []u8) []const u8 {
                return T.title(cast(p), b);
            }
            fn body(p: *anyopaque, d: *Dialogs) bool {
                return T.body(cast(p), d);
            }
            fn close(p: *anyopaque, d: *Dialogs) bool {
                return T.close(cast(p), d);
            }
            fn deinit(p: *anyopaque, d: *Dialogs) void {
                T.deinit(cast(p), d);
            }
            fn deinitWin(p: *anyopaque, d: *Dialogs) void {
                T.deinitWin(cast(p), d);
            }
            fn hidden(p: *anyopaque) bool {
                return T.hidden(cast(p));
            }
            const vt: VT = .{
                .id = T.win_id,
                .title = title,
                .body = body,
                .close = if (@hasDecl(T, "close")) close else null,
                .deinit = if (@hasDecl(T, "deinitWin")) deinitWin else deinit,
                .size = if (@hasDecl(T, "win_size")) T.win_size else null,
                .hidden = if (@hasDecl(T, "hidden")) hidden else null,
                .menu_bar = @hasDecl(T, "menu_bar"),
            };
        };
        return &G.vt;
    }
};

/// A flow polled once per frame (before the windows draw). `tick` false = finished (then deinit).
pub const Task = struct {
    ptr: *anyopaque,
    tick: *const fn (*anyopaque, *Dialogs) bool,
    deinit: *const fn (*anyopaque, *Dialogs) void,
    /// Started by the main window on its archive: counts for modal().
    modal: bool,

    pub fn of(comptime T: type, p: *T, modal: bool) Task {
        const G = struct {
            fn tick(q: *anyopaque, d: *Dialogs) bool {
                return T.tick(@ptrCast(@alignCast(q)), d);
            }
            fn deinit(q: *anyopaque, d: *Dialogs) void {
                T.deinit(@ptrCast(@alignCast(q)), d);
            }
        };
        return .{ .ptr = p, .tick = G.tick, .deinit = G.deinit, .modal = modal };
    }
};

const timer_id: usize = 0x4D50; // 'MP'
const add_key = "\x00add"; // the compress dialog's 400 ms gather (C# Add's Thread.Sleep(400))

pub const Dialogs = struct {
    ctx: *Ctx,
    wins: std.ArrayList(*Win) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    serial: u32 = 0,
    gather: pd.Gather,
    /// The compress dialog opened by dispatch "a" (a second "a" adds to it).
    add_form: ?*compress_dlg.Compress = null,
    queue: extract_dlg.Queue = .{},
    find_win: ?*find_dlg.Find = null,
    // OS window state (no main window)
    timer_on: bool = false,
    hidden_os: bool = false,
    had_main: bool = true,
    /// Largest extent drawn this frame (no-main sizing).
    need: [2]f32 = .{ 0, 0 },
    size_sig: u32 = 0,
    settle: u32 = 0,
    /// A window was clamped to the client this frame (it grows, then may shrink to its real size).
    clamped: bool = false,
    base_title: [256]u8 = undefined,
    base_title_len: usize = 0,
    shown_title: [256]u8 = undefined,
    shown_title_len: usize = 0,

    pub fn init(ctx: *Ctx) Dialogs {
        return .{ .ctx = ctx, .gather = .{ .gpa = ctx.gpa } };
    }

    /// Cancels and joins every job (before app.deinit: workers wake the app), closes what is open.
    pub fn deinit(d: *Dialogs) void {
        // Top of the stack first: a prompt writes its answer into the flow below it, which is still alive.
        while (d.wins.pop()) |win| {
            if (!win.dropped) win.vt.deinit(win.ptr, d);
            d.ctx.gpa.destroy(win);
        }
        while (d.tasks.pop()) |t| t.deinit(t.ptr, d); // their Runs call dropWin: the (empty) list must still be there
        d.tasks.deinit(d.ctx.gpa);
        d.queue.deinit(d);
        d.wins.deinit(d.ctx.gpa);
        d.gather.deinit();
        if (d.timer_on) _ = w.KillTimer(d.ctx.app.hwnd, timer_id);
    }

    // ---- Program --------------------------------------------------------------------------------------------

    /// Program.Dispatch (platform_dispatch.route): x -> the extract queue; a --quick / a --profile -> Gather
    /// (400 ms, then RunProfile with ConfirmOverwrite + progress); a <paths> -> the compress dialog (400 ms gather of
    /// Explorer's sibling invocations; a second "a" while it is open adds to it); convert -> the convert dialog;
    /// anything else -> ctx.post(.{ .open_main = path }). Our own arguments, every forwarded set (pipe) and the main
    /// window's Program.Run all come here, on the UI thread. Raises what it opened (ctx.raise).
    pub fn dispatch(d: *Dialogs, args: []const []const u8) void {
        const now = w.GetTickCount64();
        switch (pd.route(args)) {
            .open => |p| {
                const path = if (p) |s| d.ctx.dupe(s) catch return else null;
                d.ctx.post(.{ .open_main = path });
            },
            .extract => |job| d.queue.enqueue(d, job),
            .quick => |paths| _ = d.gather.add(pd.quick_key, paths, now) catch return,
            .profile => |p| _ = d.gather.add(p.name, p.paths, now) catch return,
            .add => |paths| {
                if (d.add_form) |f| {
                    f.addInputs(d, paths);
                    d.ctx.raise();
                    return;
                }
                _ = d.gather.add(add_key, paths, now) catch return;
            },
            .convert => |paths| {
                convert_dlg.open(d, paths, false, false);
                d.ctx.raise();
            },
        }
        d.ctx.app.requestFrames(2);
    }

    /// Every frame, after MainWindow.draw: the open dialogs, the queue's progress, the Gather clock (keep frames
    /// coming with app.animate / requestFrames while a 400 ms window is open), finished jobs.
    pub fn draw(d: *Dialogs) void {
        d.gatherDue();
        d.queue.tick(d);
        var i: usize = 0;
        while (i < d.tasks.items.len) {
            const t = d.tasks.items[i];
            if (t.tick(t.ptr, d)) {
                i += 1;
            } else {
                _ = d.tasks.orderedRemove(i);
                t.deinit(t.ptr, d);
            }
        }
        d.drawWindows();
        d.sweep();
        d.osWindow();
    }

    /// Program.Busy: the extract queue runs or waits, a Gather window is open, a quick/profile run is going.
    pub fn busy(d: *const Dialogs) bool {
        return d.queue.busy() or d.gather.pending() or d.tasks.items.len > 0;
    }

    /// MaybeExit's half: no dialog on screen and not busy. main.zig quits when this holds and there is no main window.
    pub fn idle(d: *const Dialogs) bool {
        return d.wins.items.len == 0 and !d.busy();
    }

    /// A modal dialog or a modal progress is up (see the rules above). The modeless queue progress is not modal.
    /// Without a main window nothing is "modal" (nobody else takes input; the X button cancels instead).
    pub fn modal(d: *const Dialogs) bool {
        if (!d.ctx.has_main_window) return false;
        for (d.wins.items) |x| if (x.modal and !x.closed) return true;
        for (d.tasks.items) |t| if (t.modal) return true;
        return false;
    }

    /// The OS window's close button while there is no main window: cancel what runs (C#: closing ProgressForm =
    /// Cancel). True = the process may end now.
    pub fn closeRequested(d: *Dialogs) bool {
        if (d.queue.busy()) d.ctx.exit_code = 255;
        d.queue.cancelAll(d);
        while (d.wins.pop()) |x| {
            if (!x.dropped) x.vt.deinit(x.ptr, d);
            d.ctx.gpa.destroy(x);
        }
        while (d.tasks.pop()) |t| t.deinit(t.ptr, d); // their jobs are cancelled and joined in deinit
        d.queue.deinit(d);
        d.queue = .{};
        d.gather.deinit();
        d.gather = .{ .gpa = d.ctx.gpa };
        return true;
    }

    /// Files dropped on the OS window: the compress dialog takes them (CompressForm.AddInputs) when it is open.
    /// True = consumed; false = the main window gets them.
    pub fn filesDropped(d: *Dialogs, paths: []const []const u8) bool {
        for (d.wins.items) |x| if (!x.closed and x.vt == Win.vtOf(compress_dlg.Compress)) {
            const f: *compress_dlg.Compress = @ptrCast(@alignCast(x.ptr));
            f.addInputs(d, paths);
            return true;
        };
        return false;
    }

    /// Program.Fail: an unexpected error as an alert (engine.friendly); with nothing else on screen, exit code 1.
    pub fn fail(d: *Dialogs, err: anyerror) void {
        if (!d.ctx.has_main_window and d.wins.items.len == 0 and !d.busy()) d.ctx.exit_code = 1;
        d.alert(.err, S.app, engine.friendly(err, null));
    }

    // ---- prompts and alerts ---------------------------------------------------------------------------------

    /// MessageBox.Show(OK): Say, About, PathNotFound, TryOpen's error, Shell's error, BadName/NameTaken...
    pub fn alert(d: *Dialogs, kind: kit.ui.MsgKind, title: []const u8, text: []const u8) void {
        P.message(d, kind, title, text, .ok, false, null);
    }

    /// MessageBox.Show(YesNo): posts .confirmed(token) on Yes only. `default_no` = MessageBoxDefaultButton.Button2.
    pub fn confirm(d: *Dialogs, kind: kit.ui.MsgKind, title: []const u8, text: []const u8, default_no: bool, token: Token) void {
        ops.confirmToken(d, kind, title, text, default_no, token);
    }

    /// NameForm.Line (Select group mask, Add to favorites name): posts .text(token, value) on OK only.
    pub fn nameLine(d: *Dialogs, title: []const u8, prompt: []const u8, text: []const u8, token: Token) void {
        ops.nameLineToken(d, title, prompt, text, token);
    }

    /// PasswordForm.OpenArchive(owner, path) for Go(): missing / not an archive / damaged / encrypted headers each
    /// get their own alert or prompt, a wrong password re-asks. Posts .opened(token, archive) on success only.
    /// `password` non-null (a Loc that carries one, a favorite) = TryOpen: no prompt, an error is one alert.
    pub fn openArchive(d: *Dialogs, path: []const u8, password: ?[]const u8, token: Token) void {
        ops.openArchive(d, path, password, token);
    }

    /// C# Ready() alone (drag-out needs the password before the drag starts): EnsurePassword on `a`, then
    /// .replace_archive when a new instance was opened, then .ready(token). Cancel: nothing.
    pub fn ready(d: *Dialogs, a: *engine.Archive, token: Token) void {
        ops.ready(d, a, token);
    }

    /// The cli ask_password callback (cli.Env.ask_password, PasswordForm.Ask): runs BEFORE the GUI (x/t -p), so it
    /// brings up its own small kit.app window and blocks until answered. null = cancelled. Result from `gpa`.
    pub fn cliAskPassword(gpa: Allocator, title: []const u8, label: ?[]const u8) ?[]u8 {
        return P.cliAskPassword(gpa, title, label);
    }

    // ---- standalone -----------------------------------------------------------------------------------------

    /// SettingsForm.Edit (Ctrl+S; --settings standalone with ctx.standalone). Commits settings, applies Assoc
    /// profiles under ctx.hive, posts .settings_changed.
    pub fn settings(d: *Dialogs) void {
        settings_dlg.openSettings(d);
    }

    /// AssocForm.Edit (the in-app checkbox dialog - never Windows Settings; --assoc standalone). Registry only
    /// under ctx.hive.
    pub fn assoc(d: *Dialogs) void {
        assoc_dlg.open(d);
    }

    /// FavoritesForm.Edit (Favorites > Organize): posts .settings_changed when closed.
    pub fn organizeFavorites(d: *Dialogs) void {
        settings_dlg.openFavorites(d);
    }

    // ---- archive operations ---------------------------------------------------------------------------------

    /// DoNew: CompressForm(paths) modal; `open_created` = the main window's New archive: posts
    /// .open_path(CreatedPath) when one single archive was made. (Program's "a" dialog goes through dispatch.)
    pub fn compress(d: *Dialogs, paths: []const []const u8, open_created: bool) void {
        _ = compress_dlg.open(d, paths, open_created, true);
    }

    /// DoExtract in an archive: Ready -> ExtractForm.Ask -> progress (conflicts: ExtractForm.Conflicts) ->
    /// when `offer_delete` (whole archive on disk: indices null and no parent archives) and the run was clean,
    /// AfterExtract (posts .release_archive before recycling it). `indices` null = everything.
    pub fn extract(d: *Dialogs, a: *engine.Archive, indices: ?[]const u32, offer_delete: bool) void {
        extract_dlg.extractOpen(d, a, indices, offer_delete, null);
    }

    /// DoExtractNoAsk (Alt+W) in an archive: Ready -> progress into `dest`, OverwriteMode.Ask with conflicts.
    pub fn extractTo(d: *Dialogs, a: *engine.Archive, indices: ?[]const u32, dest: []const u8) void {
        extract_dlg.extractOpen(d, a, indices, false, dest);
    }

    /// ToTemp / CopyFiles: Ready -> progress -> extract `indices` (overwrite) into a new engine.newTempDir ->
    /// .temp_ready(token, dir). (Drag-out extracts at drop time inside DoDragDrop: G1's own synchronous code.)
    pub fn extractToTemp(d: *Dialogs, a: *engine.Archive, indices: []const u32, token: Token) void {
        ops.toTemp(d, a, indices, .{ .token = token });
    }

    /// TestOne on the open archive: progress, then S.testOk (info) or S.testFailed (warning).
    pub fn testArchive(d: *Dialogs, a: *engine.Archive) void {
        ops.testOpen(d, a);
    }

    /// DoTest on disk: one file = OpenArchive + TestOne; several = one by one, then S.testSummaryFmt.
    pub fn testFiles(d: *Dialogs, paths: []const []const u8) void {
        ops.testFiles(d, paths);
    }

    /// InfoForm.Show on the open archive (modeless in look, modal in effect: it borrows `a`).
    pub fn info(d: *Dialogs, a: *engine.Archive) void {
        info_dlg.open(d, a, false);
    }

    /// DoInfo on one archive file on disk: OpenArchive -> InfoForm -> close.
    pub fn infoFile(d: *Dialogs, path: []const u8) void {
        ops.infoFile(d, path);
    }

    /// SaveReport: save dialog (name = base + S.reportSuffix + .html/.txt, in `dir`) -> engine.writeReport ->
    /// .status(S.reportSavedFmt). (CopyReport is G1's: engine.report + clipboard.)
    pub fn saveReport(d: *Dialogs, a: *engine.Archive, as_html: bool, dir: []const u8) void {
        ops.saveReport(d, a, as_html, dir);
    }

    /// ViewerForm.Open on a file on disk.
    pub fn view(d: *Dialogs, path: []const u8, title: []const u8) void {
        viewer_dlg.open(d, path, title);
    }

    /// DoView in an archive: ToTemp(entry `index`) -> ViewerForm titled `name`.
    pub fn viewEntry(d: *Dialogs, a: *engine.Archive, index: u32, name: []const u8) void {
        ops.toTemp(d, a, &.{index}, .{ .view = name });
    }

    /// FindForm.Open(root = open archive's source or the folder): Locate posts .locate; View opens the viewer
    /// itself (ViewFound). Modeless.
    pub fn find(d: *Dialogs, root: []const u8) void {
        find_dlg.open(d, root);
    }

    /// ConvertForm(paths): on disk `release_open` false; for the open archive (paths = its source, no parents)
    /// `release_open` true: posts .release_archive when Convert is pressed (starts the job next frame) and
    /// .open_path(source, record false) at the end when the file is still there.
    pub fn convert(d: *Dialogs, paths: []const []const u8, release_open: bool) void {
        convert_dlg.open(d, paths, release_open, true);
    }

    /// DoDelete on disk: S.confirmRecycleFmt / S.confirmNukeFmt (default No) -> engine.recycle on a job -> .refresh.
    pub fn deleteFiles(d: *Dialogs, paths: []const []const u8, nuke: bool) void {
        ops.deleteFiles(d, paths, nuke);
    }

    /// DoDelete in an archive (G1 checked Editable): S.confirmDelete -> Ready -> edit (S.deleting) ->
    /// .reopen with S.deletedFmt(count).
    pub fn deleteEntries(d: *Dialogs, a: *engine.Archive, indices: []const u32, count: usize, cur: []const u8) void {
        ops.edit(d, a, .{ .delete = .{ .indices = indices, .count = count } }, cur);
    }

    /// DoRename in an archive (G1 validated the name: BadName / NameTaken): edit (S.renaming) of `cur ++ old` to
    /// `cur ++ new` -> .reopen selecting `new` with S.renamedFmt.
    pub fn renameEntry(d: *Dialogs, a: *engine.Archive, cur: []const u8, old: []const u8, new: []const u8) void {
        ops.edit(d, a, .{ .rename = .{ .old = old, .new = new } }, cur);
    }

    /// AddToArchive (Add files, paste, drop into an archive): not `editable` -> S.notSupported + S.offerNewArchive,
    /// Yes = compress(files, true); else Ready -> append under `cur` (conflicts: Replace/Skip) -> .reopen S.addedFmt.
    pub fn addToArchive(d: *Dialogs, a: *engine.Archive, files: []const []const u8, cur: []const u8, editable: bool) void {
        if (!editable) return ops.offerNewArchive(d, files);
        ops.edit(d, a, .{ .add = files }, cur);
    }

    // ---- internals (dlg_*.zig) ------------------------------------------------------------------------------

    /// The owner of `ptr` takes its window away (no deinit from the sweep).
    pub fn dropWin(d: *Dialogs, ptr: *anyopaque) void {
        for (d.wins.items) |x| if (x.ptr == ptr) {
            x.closed = true;
            x.dropped = true;
        };
    }

    fn gatherDue(d: *Dialogs) void {
        const now = w.GetTickCount64();
        while (d.gather.takeDue(now)) |b_| {
            var b = b_;
            defer b.deinit(d.ctx.gpa);
            const paths: []const []const u8 = @ptrCast(b.paths.items);
            if (std.mem.eql(u8, b.key, add_key)) {
                d.add_form = compress_dlg.open(d, paths, false, false);
                d.ctx.raise();
            } else if (std.mem.eql(u8, b.key, pd.quick_key)) {
                compress_dlg.runProfile(d, pd.quickProfile(d.ctx.hive, C.settings.current().Level), paths);
            } else if (C.settings.current().findProfile(b.key)) |p| {
                compress_dlg.runProfile(d, p.*, paths);
            } else {
                // Program.NoSuchProfile
                var buf: [512]u8 = undefined;
                d.alert(.err, S.app, S.fillZ(&buf, S.tr().profileNotFoundFmt, .{b.key}));
                d.ctx.exit_code = 1;
            }
        }
    }

    // ---- drawing ----------------------------------------------------------------------------------------------

    fn drawWindows(d: *Dialogs) void {
        d.need = .{ 0, 0 };
        d.clamped = false;
        var modals: [32]*Win = undefined;
        var n: usize = 0;
        // The base of the OS window without a main window: the first window drawn fills it.
        var base: ?*Win = null;
        for (d.wins.items) |x| {
            if (x.closed or (x.vt.hidden != null and x.vt.hidden.?(x.ptr))) continue;
            if (!d.ctx.has_main_window and base == null) base = x;
            if (x.modal) {
                if (n < modals.len) {
                    modals[n] = x;
                    n += 1;
                }
            } else d.drawOne(x, x == base);
        }
        d.drawModal(modals[0..n], base);
        d.base_title_len = 0;
        if (base) |b| {
            var tb: [256]u8 = undefined;
            const t = b.vt.title(b.ptr, &tb);
            const len = @min(t.len, d.base_title.len);
            @memcpy(d.base_title[0..len], t[0..len]);
            d.base_title_len = len;
        }
    }

    fn drawModal(d: *Dialogs, list: []const *Win, base: ?*Win) void {
        if (list.len == 0) return;
        const x = list[0];
        var nb: [512]u8 = undefined;
        const name = winName(&nb, x);
        if (!x.opened) {
            _ = im.ImGui_OpenPopup(name.ptr, 0);
            x.opened = true;
        }
        var open = true;
        const flags = d.place(x, x == base);
        if (!im.ImGui_BeginPopupModal(name.ptr, if (x.vt.close != null and x != base) &open else null, flags)) {
            for (list) |y| y.opened = false; // ImGui closed it (a parent closed): open again next frame
            return;
        }
        var keep = x.vt.body(x.ptr, d);
        if (!open and keep) keep = !x.vt.close.?(x.ptr, d);
        d.measure(x == base);
        d.drawModal(list[1..], base);
        if (!keep) {
            x.closed = true;
            im.ImGui_CloseCurrentPopup();
        }
        im.ImGui_EndPopup();
    }

    fn drawOne(d: *Dialogs, x: *Win, is_base: bool) void {
        var nb: [512]u8 = undefined;
        const name = winName(&nb, x);
        var open = true;
        const flags = d.place(x, is_base);
        const visible = im.ImGui_Begin(name.ptr, if (x.vt.close != null and !is_base) &open else null, flags);
        var keep = true;
        if (visible) keep = x.vt.body(x.ptr, d);
        if (!open and keep) keep = !x.vt.close.?(x.ptr, d);
        if (visible) d.measure(is_base);
        im.ImGui_End();
        if (!keep) x.closed = true;
    }

    /// Position, size and flags of the next window.
    fn place(d: *Dialogs, x: *Win, is_base: bool) c_int {
        var flags: c_int = im.ImGuiWindowFlags_NoCollapse | im.ImGuiWindowFlags_NoSavedSettings;
        if (x.vt.menu_bar) flags |= im.ImGuiWindowFlags_MenuBar;
        const s = d.ctx.app.scale();
        const vp = im.ImGui_GetMainViewport();
        if (is_base) {
            // No main window: this dialog IS the OS window (its title is the OS title).
            im.ImGui_SetNextWindowPos(vp.*.WorkPos, im.ImGuiCond_Always);
            flags |= im.ImGuiWindowFlags_NoTitleBar | im.ImGuiWindowFlags_NoMove;
            if (x.vt.size != null) {
                im.ImGui_SetNextWindowSize(vp.*.WorkSize, im.ImGuiCond_Always);
                flags |= im.ImGuiWindowFlags_NoResize;
            } else flags |= im.ImGuiWindowFlags_AlwaysAutoResize;
            return flags;
        }
        const cond: c_int = if (d.ctx.has_main_window) im.ImGuiCond_Appearing else im.ImGuiCond_Always;
        im.ImGui_SetNextWindowPosEx(im.ImGuiViewport_GetCenter(vp), cond, .{ .x = 0.5, .y = 0.5 });
        if (x.vt.size) |sz| {
            const ws = vp.*.WorkSize; // a resizable dialog never starts bigger than the main window
            im.ImGui_SetNextWindowSize(.{ .x = @min(sz[0] * s, ws.x * 0.94), .y = @min(sz[1] * s, ws.y * 0.94) }, im.ImGuiCond_Appearing);
        } else flags |= im.ImGuiWindowFlags_AlwaysAutoResize;
        return flags;
    }

    /// The OS client size the dialogs need (no main window). ImGui clamps an auto-sized window to the viewport,
    /// so a window that fills it asks for more room; the next frames measure it again and shrink to fit.
    fn measure(d: *Dialogs, is_base: bool) void {
        if (im.ImGui_IsWindowAppearing()) return; // its size is not known yet
        const s = d.ctx.app.scale();
        const sz = im.ImGui_GetWindowSize();
        const ws = im.ImGui_GetMainViewport().*.WorkSize;
        const pad = im.ImGui_GetStyle().*.DisplaySafeAreaPadding; // ImGui keeps windows this far from the edges
        const mx: f32 = if (is_base) 2 * pad.x + 2 else 32 * s;
        const my: f32 = if (is_base) 2 * pad.y + 2 else 32 * s;
        var x = sz.x + mx;
        var y = sz.y + my;
        if (sz.x >= ws.x - 2 * pad.x - 0.5) {
            x = @max(x, @min(ws.x * 1.5, 1600 * s));
            d.clamped = true;
        }
        if (sz.y >= ws.y - 2 * pad.y - 0.5) {
            y = @max(y, @min(ws.y * 1.5, 1000 * s));
            d.clamped = true;
        }
        d.need[0] = @max(d.need[0], x);
        d.need[1] = @max(d.need[1], y);
    }

    fn sweep(d: *Dialogs) void {
        var i: usize = 0;
        var reopen = false;
        while (i < d.wins.items.len) {
            const x = d.wins.items[i];
            if (reopen and x.modal) x.opened = false;
            if (!x.closed) {
                i += 1;
                continue;
            }
            if (x.modal) reopen = true; // the ones above it were closed along with it
            _ = d.wins.orderedRemove(i);
            if (!x.dropped) x.vt.deinit(x.ptr, d);
            d.ctx.gpa.destroy(x);
        }
    }

    /// No main window: the OS window shows the base dialog (title, size) or hides while there is nothing to show.
    /// Frames keep coming on a timer while flows wait (the 400 ms gathers, jobs, Find's flush).
    fn osWindow(d: *Dialogs) void {
        const app = d.ctx.app;
        const hwnd = app.hwnd;
        if (hwnd == null) return;
        const ticking = d.tasks.items.len > 0 or d.gather.pending() or d.queue.busy() or d.find_win != null;
        if (ticking != d.timer_on) {
            if (ticking) _ = w.SetTimer(hwnd, timer_id, 100, null) else _ = w.KillTimer(hwnd, timer_id);
            d.timer_on = ticking;
        }
        if (d.ctx.has_main_window) {
            if (!d.had_main) {
                app.cfg.min_size = .{ 640, 420 };
                if (d.hidden_os) _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
                d.hidden_os = false;
                d.shown_title_len = 0;
            }
            d.had_main = true;
            return;
        }
        if (d.had_main) app.cfg.min_size = .{ 160, 60 };
        d.had_main = false;
        const visible = d.base_title_len > 0 or d.need[0] > 0;
        if (!visible) {
            if (!d.hidden_os) _ = w.ShowWindow(hwnd, w.SW_HIDE);
            d.hidden_os = true;
            return;
        }
        // Title: the base dialog's.
        const t = d.base_title[0..d.base_title_len];
        if (!std.mem.eql(u8, t, d.shown_title[0..d.shown_title_len])) {
            app.setTitle(if (t.len > 0) t else S.app);
            @memcpy(d.shown_title[0..t.len], t);
            d.shown_title_len = t.len;
        }
        // Size: the client area fits what was drawn. A few frames after the set of windows changed it may also
        // shrink; then it only grows (a centred popup must not move under the mouse every frame).
        var rc: w.RECT = undefined;
        _ = w.GetClientRect(hwnd, &rc);
        var sig: u32 = 0;
        for (d.wins.items) |x| if (!x.closed) {
            sig = sig *% 31 +% x.serial;
        };
        if (sig != d.size_sig or d.clamped) {
            d.size_sig = sig;
            d.settle = 4;
        }
        d.clamped = false;
        var cw: i32 = @intFromFloat(@ceil(d.need[0]));
        var ch: i32 = @intFromFloat(@ceil(d.need[1]));
        if (d.settle > 0) d.settle -= 1 else {
            cw = @max(cw, rc.right);
            ch = @max(ch, rc.bottom);
        }
        if (cw > 0 and ch > 0 and (@abs(rc.right - cw) > 1 or @abs(rc.bottom - ch) > 1)) {
            const dpi = w.GetDpiForWindow(hwnd);
            var r: w.RECT = .{ .left = 0, .top = 0, .right = cw, .bottom = ch };
            _ = w.AdjustWindowRectExForDpi(&r, @intCast(w.WS_OVERLAPPEDWINDOW), 0, 0, dpi);
            _ = w.SetWindowPos(hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, @intCast(w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE));
        }
        if (d.hidden_os) {
            _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
            d.hidden_os = false;
            d.ctx.raise();
        }
    }
};

/// Shows `ptr` (a T, see Win.vtOf). Takes ownership: T.deinit runs when it closes.
pub fn push(d: *Dialogs, comptime T: type, ptr: *T, is_modal: bool) void {
    pushAs(d, T, ptr, is_modal, null);
}

/// push with another ImGui id than T.win_id (`id` must be static).
pub fn pushAs(d: *Dialogs, comptime T: type, ptr: *T, is_modal: bool, id: ?[]const u8) void {
    const vt = Win.vtOf(T);
    const x = d.ctx.gpa.create(Win) catch return vt.deinit(ptr, d);
    d.serial += 1;
    x.* = .{ .ptr = ptr, .vt = vt, .modal = is_modal, .serial = d.serial, .id = id };
    d.wins.append(d.ctx.gpa, x) catch {
        d.ctx.gpa.destroy(x);
        return vt.deinit(ptr, d);
    };
    d.ctx.app.requestFrames(3);
}

pub fn addTask(d: *Dialogs, comptime T: type, ptr: *T, is_modal: bool) void {
    d.tasks.append(d.ctx.gpa, Task.of(T, ptr, is_modal)) catch return T.deinit(ptr, d);
    d.ctx.app.requestFrames(3);
}

fn winName(buf: []u8, x: *const Win) [:0]const u8 {
    var tb: [256]u8 = undefined;
    const t = x.vt.title(x.ptr, &tb);
    return std.mem.printSentinel(buf, "{s}###{s}{d}", .{ t, x.id orelse x.vt.id, x.serial }, 0) catch "###dlg";
}

// ---- small widgets shared by the dialogs (labels always carry a ##id) ----------------------------------------

pub fn scale() f32 {
    return if (kit.app.current()) |a| a.scale() else 1;
}

/// "text##id" (text with the WinForms '&' removed).
pub fn lbl(buf: []u8, text: []const u8, id: []const u8) [:0]const u8 {
    var plain: [256]u8 = undefined;
    const t = if (std.mem.findScalar(u8, text, '&') != null and text.len < plain.len) S.plain(&plain, text) else text;
    return std.mem.printSentinel(buf, "{s}##{s}", .{ t, id }, 0) catch std.mem.printSentinel(buf, "##{s}", .{id}, 0) catch "##x";
}

/// The text without a trailing "…" (C#'s TrimEnd('…')).
pub fn noDots(s: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, "\u{2026}")) s[0 .. s.len - 3] else s;
}

/// A button at least 88 px wide (WinForms' size).
pub fn button(text: []const u8, id: []const u8) bool {
    var b: [512]u8 = undefined;
    const l = lbl(&b, text, id);
    return im.ImGui_ButtonEx(l.ptr, .{ .x = buttonWidth(l), .y = 0 });
}

/// `buttonOn` filled with the accent (kit primaryButton): the dialog's default action.
pub fn primary(enabled: bool, text: []const u8, id: []const u8) bool {
    im.ImGui_BeginDisabled(!enabled);
    defer im.ImGui_EndDisabled();
    var b: [512]u8 = undefined;
    const l = lbl(&b, text, id);
    return kit.ui.primaryButtonEx(l.ptr, .{ .x = buttonWidth(l), .y = 0 });
}

/// `primary` in palette danger (kit dangerButtonEx): Yes of a destructive confirm.
pub fn danger(text: []const u8, id: []const u8) bool {
    var b: [512]u8 = undefined;
    const l = lbl(&b, text, id);
    return kit.ui.dangerButtonEx(l.ptr, .{ .x = buttonWidth(l), .y = 0 });
}

fn buttonWidth(l: [:0]const u8) f32 {
    return buttonWidthMin(l, 88);
}

/// At least `min` (unscaled) px, wider when the translated text needs it.
fn buttonWidthMin(l: [:0]const u8, min: f32) f32 {
    return @max(min * scale(), im.ImGui_CalcTextSizeEx(l.ptr, null, true, -1).x + im.ImGui_GetStyle().*.FramePadding.x * 2);
}

/// `button` at least `min` (unscaled) px wide: Browse… next to a box, the side buttons of a list.
pub fn buttonMin(text: []const u8, id: []const u8, min: f32) bool {
    var b: [512]u8 = undefined;
    const l = lbl(&b, text, id);
    return im.ImGui_ButtonEx(l.ptr, .{ .x = buttonWidthMin(l, min), .y = 0 });
}

// ---- layout that survives translation: a column moves right / wraps instead of overlapping -----------------

/// Width of `t` in the current font, unscaled px.
pub fn textWidth(t: []const u8) f32 {
    return im.ImGui_CalcTextSizeEx(t.ptr, t.ptr + t.len, false, -1).x / scale();
}

/// A caption column (unscaled px, measured like SameLineEx: from the window's left edge, padding included) that
/// fits the longest of `texts`: at least `min`.
pub fn capWidth(min: f32, texts: []const []const u8) f32 {
    const st = im.ImGui_GetStyle();
    const air = (st.*.WindowPadding.x + st.*.ItemSpacing.x) / scale();
    var r = min;
    for (texts) |t| r = @max(r, textWidth(t) + air);
    return r;
}

/// A `combo` width (unscaled px) that shows the longest of `items` whole: at least `min`.
pub fn comboWidth(min: f32, items: []const []const u8) f32 {
    const extra = (im.ImGui_GetStyle().*.FramePadding.x * 2 + kit.ui.dropArrowWidth()) / scale();
    var r = min;
    for (items) |t| r = @max(r, textWidth(t) + extra);
    return r;
}

/// `checkbox`'s width (box + gap + text), unscaled px.
pub fn checkboxWidth(text: []const u8) f32 {
    return (im.ImGui_GetFrameHeight() + im.ImGui_GetStyle().*.ItemInnerSpacing.x) / scale() + textWidth(text);
}

/// SameLineEx(col): the next item at column `col` (unscaled, from the window's left), or right after the last
/// item when a longer translation already reaches past the column.
pub fn sameLineAt(col: f32) void {
    const end = im.ImGui_GetItemRectMax().x + im.ImGui_GetStyle().*.ItemSpacing.x;
    im.ImGui_SameLineEx(col * scale(), -1);
    const p = im.ImGui_GetCursorScreenPos();
    if (p.x < end) im.ImGui_SetCursorScreenPos(.{ .x = end, .y = p.y });
}

/// `sameLineAt(col)` for an item `width` px wide (unscaled) when it still fits in the window; else the item
/// starts a new line `indent` px in (a row of check boxes that a long translation would push off the edge).
pub fn flowAt(col: f32, width: f32, indent: f32) void {
    const right = im.ImGui_GetCursorScreenPos().x + im.ImGui_GetContentRegionAvail().x; // from the line start
    sameLineAt(col);
    if (im.ImGui_GetCursorScreenPos().x + width * scale() <= right) return;
    im.ImGui_NewLine();
    im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + indent * scale());
}

pub fn buttonOn(enabled: bool, text: []const u8, id: []const u8) bool {
    im.ImGui_BeginDisabled(!enabled);
    defer im.ImGui_EndDisabled();
    return button(text, id);
}

/// Right-aligns the next `count` buttons of `labels` (call before the first, then SameLine between them).
pub fn alignRight(labels: []const []const u8) void {
    const st = im.ImGui_GetStyle();
    var total: f32 = 0;
    for (labels) |t| total += @max(88 * scale(), im.ImGui_CalcTextSizeEx(t.ptr, t.ptr + t.len, true, -1).x + st.*.FramePadding.x * 2) + st.*.ItemSpacing.x;
    total -= st.*.ItemSpacing.x;
    const avail = im.ImGui_GetContentRegionAvail().x;
    if (avail > total) im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + avail - total);
}

pub fn checkbox(text: []const u8, id: []const u8, v: *bool) bool {
    var b: [512]u8 = undefined;
    return kit.ui.checkbox(lbl(&b, text, id).ptr, v);
}

/// A drop-down list: `items[sel.*]` shown; true when the user picked another one. Automation: "##<id>" (value =
/// the current item), rows "<item>##<id>_<n>".
pub fn combo(id: []const u8, items: []const []const u8, sel: *usize, width: f32) bool {
    return dropDown(id, items, sel, width * scale(), 0);
}

/// The arrow-only drop-down next to an editable box (WinForms' DropDown combo): "##<id>".
pub fn dropDownArrow(id: []const u8, items: []const []const u8, picked: *?usize) void {
    var sel: usize = std.math.maxInt(usize);
    if (dropDown(id, items, &sel, 0, im.ImGuiComboFlags_NoPreview)) picked.* = sel;
}

fn dropDown(id: []const u8, items: []const []const u8, sel: *usize, width: f32, flags: c_int) bool {
    var lb: [128]u8 = undefined;
    const l = std.mem.printSentinel(&lb, "##{s}", .{id}, 0) catch return false;
    const cur = if (sel.* < items.len) items[sel.*] else "";
    var pb: [512]u8 = undefined;
    const preview = std.mem.printSentinel(&pb, "{s}", .{cur[0..@min(cur.len, 500)]}, 0) catch "";
    if (width > 0) im.ImGui_SetNextItemWidth(width);
    if (!im.ImGui_BeginCombo(l.ptr, preview.ptr, flags)) return false;
    defer im.ImGui_EndCombo();
    var changed = false;
    for (items, 0..) |it, i| {
        var ib: [600]u8 = undefined;
        const il = std.mem.printSentinel(&ib, "{s}##{s}_{d}", .{ it[0..@min(it.len, 500)], id, i }, 0) catch continue;
        if (im.ImGui_SelectableEx(il.ptr, i == sel.*, 0, .{ .x = 0, .y = 0 }) and i != sel.*) {
            sel.* = i;
            changed = true;
        }
        if (i == sel.*) im.ImGui_SetItemDefaultFocus();
    }
    return changed;
}

/// A one-line text box over a NUL-terminated buffer. true = edited.
pub fn input(id: []const u8, buf: []u8, width: f32, flags: c_int) bool {
    var b: [128]u8 = undefined;
    const l = std.mem.printSentinel(&b, "##{s}", .{id}, 0) catch return false;
    im.ImGui_SetNextItemWidth(width * scale());
    return im.ImGui_InputText(l.ptr, buf.ptr, buf.len, flags);
}

pub fn inputHint(id: []const u8, hint: []const u8, buf: []u8, width: f32) bool {
    var b: [128]u8 = undefined;
    const l = std.mem.printSentinel(&b, "##{s}", .{id}, 0) catch return false;
    var hb: [256]u8 = undefined;
    const h = std.mem.printSentinel(&hb, "{s}", .{hint}, 0) catch "";
    im.ImGui_SetNextItemWidth(width * scale());
    return im.ImGui_InputTextWithHint(l.ptr, h.ptr, buf.ptr, buf.len, 0);
}

/// The text of a NUL-terminated input buffer.
pub fn bufText(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

pub fn setText(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

pub fn tooltip(t: []const u8) void {
    if (im.ImGui_BeginItemTooltip()) {
        im.ImGui_PushTextWrapPos(420 * scale());
        im.ImGui_TextUnformattedEx(t.ptr, t.ptr + t.len);
        im.ImGui_PopTextWrapPos();
        im.ImGui_EndTooltip();
    }
}

/// Caption at the left of a row of controls (WinForms' Label), vertically aligned with them; the controls start
/// at `width` (unscaled), or after the text when a translation is longer.
pub fn caption(t: []const u8, width: f32) void {
    im.ImGui_AlignTextToFramePadding();
    im.ImGui_TextUnformattedEx(t.ptr, t.ptr + t.len);
    if (width > 0) sameLineAt(width);
}

/// Esc / Enter for the window being drawn (only while it, or a child, has the focus).
pub fn keyPressed(key: im.ImGuiKey) bool {
    return im.ImGui_IsWindowFocused(im.ImGuiFocusedFlags_RootAndChildWindows) and !im.ImGui_IsWindowAppearing() and im.ImGui_IsKeyPressed(key);
}

/// The last frame a popup was open above the window being drawn (a drop-down list, a menu).
var popup_frame: c_int = -10;

/// Esc for the dialog. ImGui closes an open drop-down / menu on Esc before the frame's widgets run, so an Esc
/// within a frame of a popup being open was that popup's (WinForms: Esc closes the drop-down only).
pub fn escPressed() bool {
    const f = im.ImGui_GetFrameCount();
    if (im.ImGui_IsPopupOpen("", im.ImGuiPopupFlags_AnyPopupId)) popup_frame = f;
    return keyPressed(im.ImGuiKey_Escape) and popup_frame < f - 1;
}

pub fn enterPressed() bool {
    return keyPressed(im.ImGuiKey_Enter) or keyPressed(im.ImGuiKey_KeypadEnter);
}

/// The Win32 file dialogs' owner: the OS window.
pub fn owner(d: *const Dialogs) w.HWND {
    return d.ctx.app.hwnd;
}
