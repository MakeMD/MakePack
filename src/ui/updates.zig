//! Updates (MakeKit docs K11). MakePack never goes online: kit.update runs MakeUpdate.exe (next to MakePack.exe)
//! hidden and reads its one JSON line. Ctx.updates is the one instance; main.zig polls it every frame, the main
//! window starts the daily check when it opens, draws the banner above the toolbar and has Help > Check for updates.
//!   daily:   settings UpdateCheck on, LastUpdateCheck >= 24 h ago, MAKEKIT_NO_UPDATE not set -> a background check;
//!            offline / any failure stays quiet; a newer version except UpdateSkip -> the banner.
//!   manual:  always checks; answers with an alert (latest / failed) or the banner (also for a skipped version).
//!   banner:  Update now = MakeUpdate install (waits for this PID, silent setup, starts MakePack again) + quit;
//!            Release notes = the release page; Later = UpdateSkip = that version.
const std = @import("std");
const kit = @import("kit");
const build_info = @import("build_info");
const C = @import("ctx.zig");
const pw = @import("../platform/platform_win.zig");

const S = C.S;
const settings = C.settings;
const Parsed = std.json.Parsed(kit.update.Result);

pub const repo = "MakeMD/MakePack";
/// build.zig.zon's .version.
pub const version: []const u8 = build_info.version;

pub const Updates = struct {
    checker: kit.update.Checker = .{},
    /// <exe dir>\MakeUpdate.exe (ctx.gpa), once the first check starts.
    updater: ?[]u8 = null,
    /// The newer release the banner offers.
    found: ?Parsed = null,
    /// The running check came from Help > Check for updates: it answers with an alert.
    manual: bool = false,
    daily_done: bool = false,

    /// The main window opened: the daily check, once per process.
    pub fn daily(u: *Updates, ctx: *C.Ctx) void {
        if (u.daily_done) return;
        u.daily_done = true;
        const s = settings.current();
        if (!s.UpdateCheck or kit.update.disabled() or !kit.update.due(s.LastUpdateCheck, now(ctx))) return;
        u.start(ctx, false);
    }

    /// Help > Check for updates.
    pub fn checkNow(u: *Updates, ctx: *C.Ctx) void {
        if (u.checker.running()) {
            u.manual = true; // the daily check is under way: its answer becomes this one
            return;
        }
        u.start(ctx, true);
    }

    fn start(u: *Updates, ctx: *C.Ctx, manual: bool) void {
        u.manual = manual;
        if (u.updater == null) u.updater = kit.update.updaterPath(ctx.gpa, ctx.io) catch |e| return if (manual) failed(ctx, @errorName(e));
        u.checker.start(ctx.gpa, ctx.io, u.updater.?, repo, version) catch |e| if (manual) failed(ctx, @errorName(e));
    }

    /// Every frame (main.zig): takes a finished check.
    pub fn poll(u: *Updates, ctx: *C.Ctx) void {
        const res = u.checker.poll() orelse return;
        const manual = u.manual;
        u.manual = false;
        const s = settings.current();
        s.LastUpdateCheck = now(ctx); // after every attempt: offline is retried tomorrow, not on every start
        settings.commit();
        var r = res catch |e| return if (manual) failed(ctx, @errorName(e));
        if (!r.value.ok or !r.value.newer or (!manual and std.mem.eql(u8, r.value.latest, s.UpdateSkip))) {
            if (manual) {
                var buf: [512]u8 = undefined;
                if (!r.value.ok) failed(ctx, r.value.@"error") else ctx.dialogs.alert(.info, S.tr().checkUpdates, S.fillZ(&buf, S.tr().upToDateFmt, .{version}));
            }
            return r.deinit();
        }
        if (u.found) |*f| f.deinit();
        u.found = r;
        ctx.app.requestFrames(2);
    }

    /// The main window, below its menu bar: the banner while a newer version is on offer.
    pub fn banner(u: *Updates, ctx: *C.Ctx) void {
        const r = u.found orelse return;
        var buf: [128]u8 = undefined;
        const action = kit.update.banner(.{
            .text = S.fillZ(&buf, S.tr().updateAvailableFmt, .{r.value.latest}),
            .update = S.tr().updateNow,
            .notes = S.tr().releaseNotes,
            .later = S.tr().updateLater,
        }) orelse return;
        switch (action) {
            .update => u.install(ctx, r.value),
            .notes => openPage(ctx, r.value.page),
            .later => {
                const s = settings.current();
                s.UpdateSkip = settings.arena().dupe(u8, r.value.latest) catch s.UpdateSkip;
                settings.commit();
                u.found.?.deinit();
                u.found = null;
            },
        }
    }

    fn install(u: *Updates, ctx: *C.Ctx, r: kit.update.Result) void {
        // Quitting would cancel a running extraction or the queue: the user finishes that first.
        if (ctx.dialogs.busy()) return ctx.dialogs.alert(.info, S.app, S.tr().updateBusy);
        const self = pw.exePath(ctx.gpa) catch return;
        defer ctx.gpa.free(self);
        kit.update.install(ctx.io, u.updater.?, repo, r.tag, self) catch |e| return failed(ctx, @errorName(e));
        ctx.app.quit(); // MakeUpdate waits for this PID, runs the setup silently and starts MakePack again
    }

    /// Before app.deinit (joins a running check, at most its 30 s timeout).
    pub fn deinit(u: *Updates, gpa: std.mem.Allocator) void {
        u.checker.deinit();
        if (u.found) |*f| f.deinit();
        u.found = null;
        if (u.updater) |p| gpa.free(p);
        u.updater = null;
    }
};

fn failed(ctx: *C.Ctx, why: []const u8) void {
    var buf: [1024]u8 = undefined;
    ctx.dialogs.alert(.warning, S.tr().checkUpdates, S.fillZ(&buf, S.tr().updateFailedFmt, .{why}));
}

fn now(ctx: *C.Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toSeconds();
}

/// The release page comes off the network: only a web address is handed to the shell (never a file or a program).
fn openPage(ctx: *C.Ctx, page: []const u8) void {
    if (!isWebUrl(page)) return;
    _ = kit.win.shellExecute(ctx.gpa, .{ .file = page }) catch null;
}

fn isWebUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "https://") or std.ascii.startsWithIgnoreCase(s, "http://");
}

test "updates: only web pages are opened, version from build.zig.zon" {
    try std.testing.expect(isWebUrl("https://github.com/MakeMD/MakePack/releases/tag/v2.1.0"));
    try std.testing.expect(isWebUrl("http://127.0.0.1:8080/x"));
    try std.testing.expect(!isWebUrl("C:\\Windows\\System32\\calc.exe"));
    try std.testing.expect(!isWebUrl("file:///C:/x.exe"));
    try std.testing.expect(!isWebUrl(""));
    try std.testing.expect(kit.update.Version.parse(version) != null);
}
