//! GUI shared context: what main.zig, the main window (MP-G1, src/ui/main_window.zig + mw_*.zig) and the dialogs
//! (MP-G2, src/ui/dialogs.zig + dlg_*.zig) all see. One Ctx per process, owned by main.zig's gui(), at a fixed
//! address for the whole run. UI thread only unless a field says otherwise.
//!
//! The request channel (dialogs -> main window): a dialog never reaches into the main window; it `post`s a Request.
//! main.zig drains the channel at the START of every frame, before MainWindow.draw and Dialogs.draw:
//!   .open_main goes to main.zig (create the main window or open a path in it, then raise),
//!   everything else to MainWindow.handle (or is dropped, freed, when there is no main window).
//! So a request posted during frame N is handled at the start of frame N+1, before the dialogs draw again. A dialog
//! that needs the main window to let go of something first (.release_archive) posts it and continues next frame.
//! Each Request owns its strings (allocated with ctx.gpa); whoever handles it calls `deinit`.
const std = @import("std");
const kit = @import("kit");

pub const S = @import("../strings.zig");
pub const settings = @import("../settings.zig");
pub const engine = @import("../core/engine.zig");
pub const assoc = @import("../platform/assoc.zig");
pub const Dialogs = @import("dialogs.zig").Dialogs;
pub const platform_dispatch = @import("../platform/platform_dispatch.zig");
pub const Updates = @import("updates.zig").Updates;

const Allocator = std.mem.Allocator;

/// The main window's tag for an asynchronous answer (G1 picks the values and keeps what each one means).
/// A cancelled prompt posts nothing: a pending token simply never comes back.
pub const Token = u32;

pub const Request = union(enum) {
    /// Program.OpenMain(path): main.zig creates the main window (path = what to show) or calls MainWindow.open.
    open_main: ?[]u8,
    /// Go(path): a folder, or an archive opened at its root (CompressForm.CreatedPath, convert's reopen).
    /// `record` false = not added to Back. `select` = the row to select after the fill.
    open_path: struct { path: []u8, select: ?[]u8 = null, record: bool = true },
    /// Find -> Locate: `inner` null = a file on disk (show its folder, select it); else an entry ("dir/name") of
    /// the archive `path` (open it at that folder, select the name).
    locate: struct { path: []u8, inner: ?[]u8 = null },
    /// Fill(keep: true): the current folder changed on disk (recycled, extracted into it, ...).
    refresh,
    /// Close the open archive and show its folder (record false): convert of the open archive is about to touch
    /// it, AfterExtract recycles it. The dialog waits one frame after posting this.
    release_archive,
    /// The dialogs took over the main window's open archive (an edit consumes and closes it): drop the reference
    /// WITHOUT closing it and clear the rows. A .reopen follows when the edit is over.
    detach_archive: *engine.Archive,
    /// EnsurePassword gave a new instance: close `old` (still the main window's) and adopt `new`.
    replace_archive: struct { old: *engine.Archive, new: *engine.Archive },
    /// After an edit (Modify): Go(Loc(source, cur, password), select, record: false); when that fails, the folder.
    /// `status` (when set) goes to the status bar after a successful reopen.
    reopen: struct { source: []u8, password: ?[]u8, cur: []u8, select: ?[]u8 = null, status: ?[]u8 = null },
    /// Dialogs.openArchive succeeded: the main window owns `archive` now.
    opened: struct { token: Token, archive: *engine.Archive },
    /// Dialogs.ready: the main window's archive (after any .replace_archive) has its bodies' password.
    ready: Token,
    /// Dialogs.extractToTemp: the entries are under `dir` (an engine.newTempDir, removed at exit).
    temp_ready: struct { token: Token, dir: []u8 },
    /// Dialogs.confirm: the user answered Yes.
    confirmed: Token,
    /// Dialogs.nameLine: the user pressed OK with this text.
    text: struct { token: Token, value: []u8 },
    /// Status bar text (report saved, ...).
    status: []u8,
    /// Settings / favorites / profiles were changed and committed: re-read what the window shows from them.
    settings_changed,

    pub fn deinit(r: Request, gpa: Allocator) void {
        switch (r) {
            .open_main => |p| if (p) |s| gpa.free(s),
            .open_path => |o| {
                gpa.free(o.path);
                if (o.select) |s| gpa.free(s);
            },
            .locate => |l| {
                gpa.free(l.path);
                if (l.inner) |s| gpa.free(s);
            },
            .reopen => |o| {
                gpa.free(o.source);
                if (o.password) |s| gpa.free(s);
                gpa.free(o.cur);
                if (o.select) |s| gpa.free(s);
                if (o.status) |s| gpa.free(s);
            },
            .temp_ready => |t| gpa.free(t.dir),
            .text => |t| gpa.free(t.value),
            .status => |s| gpa.free(s),
            // Archives in requests are never freed here: detach/replace/opened hand them over, they are not copies.
            .refresh, .release_archive, .detach_archive, .replace_archive, .opened, .ready, .confirmed, .settings_changed => {},
        }
    }
};

pub const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    app: *kit.app.App,
    /// The folder of MakePack.exe (7z.dll, 7z.sfx).
    exe_dir: []const u8,
    /// Registry root for every Assoc call from the GUI. Tests: MAKEPACK_HIVE = "Software\MakePackTest-<random>\"
    /// (never the real HKCU MakePack / Classes / RegisteredApplications).
    hive: assoc.Hive = .{},
    dialogs: *Dialogs = undefined,
    /// A MainWindow exists (main.zig keeps it in sync). False = the dialogs own the OS window: its size, title and
    /// what it shows (the progress-only mode of Explorer's "Extract here / to", the compress dialog of "a", ...).
    has_main_window: bool = false,
    /// --assoc / --settings: one dialog, no pipe, no main window ever; the process ends when it closes.
    standalone: bool = false,
    /// Program._exit: the process exit code (the last failure's code wins; 255 = cancelled).
    exit_code: u8 = 0,
    requests: std.ArrayList(Request) = .empty,
    /// Update check + banner (updates.zig); main.zig polls it every frame and deinits it before the app.
    updates: Updates = .{},

    /// UI thread only. Takes ownership of `r`'s strings (freed here if the queue cannot grow).
    pub fn post(c: *Ctx, r: Request) void {
        c.requests.append(c.gpa, r) catch return r.deinit(c.gpa);
        c.app.requestFrames(2);
    }

    /// main.zig: the requests posted so far; the caller handles (and deinits) each one.
    pub fn takeRequests(c: *Ctx) std.ArrayList(Request) {
        const taken = c.requests;
        c.requests = .empty;
        return taken;
    }

    /// Program.Raise: restore + bring to the front (an invocation from another process does not do it by itself).
    /// Skipped under MakeKit automation: a test must never steal the user's focus.
    pub fn raise(c: *Ctx) void {
        const w = kit.w;
        if (kit.automation.active) return;
        if (w.IsIconic(c.app.hwnd) != 0) _ = w.ShowWindow(c.app.hwnd, w.SW_RESTORE);
        _ = w.SetForegroundWindow(c.app.hwnd);
    }

    pub fn dupe(c: *Ctx, s: []const u8) ![]u8 {
        return c.gpa.dupe(u8, s);
    }
};
