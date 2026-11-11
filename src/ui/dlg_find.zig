//! MP-G2: FindForm (Find files): masks + optional text, on disk and inside archives. Modeless; the worker
//! queues hits and the window moves them into the list every 200 ms. Locate -> the main window (.locate), View ->
//! the viewer (ViewFound: an entry is extracted to a temp folder first).
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const R = @import("dlg_run.zig");
const viewer_dlg = @import("dlg_viewer.zig");
const types = @import("../core/types.zig");
const sevenzip = @import("../core/sevenzip.zig");

const S = C.S;
const engine = C.engine;
const settings = C.settings;
const im = kit.im;
const w = kit.w;
const Dialogs = D.Dialogs;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;

// ponytail (C#): 256 MB on disk / 64 MB in an archive are the text-search ceilings; bigger files match by name only.
const max_disk_text: u64 = 256 << 20;
const max_entry_text: u64 = 64 << 20;

// ---- matching (no UI) -----------------------------------------------------------------------------------------

fn upperW(gpa: Allocator, s: []const u8) ?[]u16 {
    const x = kit.win.toW(gpa, s) catch return null;
    if (x.len > 0) _ = w.CharUpperBuffW(x.ptr, @intCast(x.len));
    return x[0 .. x.len + 1]; // keep the NUL in the allocation; callers free the whole
}

/// "*.cs;*.md" against a name - Win32 wildcards ("*.*" = everything), case-insensitive. No masks = everything.
pub fn matches(gpa: Allocator, name: []const u8, masks: []const u8) bool {
    const n = upperW(gpa, name) orelse return false;
    defer gpa.free(n);
    var any = false;
    var it = std.mem.splitScalar(u8, masks, ';');
    while (it.next()) |raw| {
        const m0 = std.mem.trim(u8, raw, " \t");
        if (m0.len == 0) continue;
        any = true;
        const m1 = if (std.mem.eql(u8, m0, "*.*")) "*" else m0;
        const m = upperW(gpa, m1) orelse continue;
        defer gpa.free(m);
        if (wild(m[0 .. m.len - 1], n[0 .. n.len - 1])) return true;
    }
    return !any;
}

fn wild(p: []const u16, s: []const u16) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (si < s.len) {
        if (pi < p.len and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            pi += 1;
            mark = si;
        } else if (star) |st| {
            pi = st + 1;
            mark += 1;
            si = mark;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

/// The text as UTF-8, UTF-16LE or Windows-1251, fed in chunks: a character split across chunks is completed on
/// the next one and each decoding keeps the last needle-1 units, so a hit across chunks counts.
// ponytail (C#): UTF-16 is decoded from offset 0 only - text in a UTF-16 run that starts at an odd byte is missed.
pub const Matcher = struct {
    gpa: Allocator,
    needle: []const u16,
    ignore_case: bool,
    tails: [3]std.ArrayList(u16) = .{ .empty, .empty, .empty },
    carry8: [4]u8 = undefined,
    carry8_n: usize = 0,
    carry16: ?u8 = null,
    /// The needle's allocation when the Matcher owns it.
    owned: ?[:0]u16 = null,

    pub fn deinit(m: *Matcher) void {
        for (&m.tails) |*t| t.deinit(m.gpa);
        if (m.owned) |o| m.gpa.free(o);
    }

    pub fn feed(m: *Matcher, chunk: []const u8) bool {
        // UTF-8: cut before an incomplete last character
        var b8: std.ArrayList(u8) = .empty;
        defer b8.deinit(m.gpa);
        b8.appendSlice(m.gpa, m.carry8[0..m.carry8_n]) catch return false;
        b8.appendSlice(m.gpa, chunk) catch return false;
        var cut = b8.items.len;
        var back: usize = 0;
        while (back < 3 and cut > 0 and b8.items[cut - 1] & 0xC0 == 0x80) : (back += 1) cut -= 1;
        if (cut > 0 and b8.items[cut - 1] >= 0xC0) {
            const need = std.unicode.utf8ByteSequenceLength(b8.items[cut - 1]) catch 1;
            if (need > back + 1) cut -= 1 else cut = b8.items.len;
        } else cut = b8.items.len;
        m.carry8_n = b8.items.len - cut;
        @memcpy(m.carry8[0..m.carry8_n], b8.items[cut..]);
        if (m.hit(0, decodeCp(m.gpa, w.CP_UTF8, b8.items[0..cut]))) return true;
        // UTF-16LE
        var b16: std.ArrayList(u8) = .empty;
        defer b16.deinit(m.gpa);
        if (m.carry16) |c| b16.append(m.gpa, c) catch return false;
        b16.appendSlice(m.gpa, chunk) catch return false;
        m.carry16 = if (b16.items.len % 2 == 1) b16.items[b16.items.len - 1] else null;
        const units = m.gpa.alloc(u16, b16.items.len / 2) catch return false;
        for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, b16.items[i * 2 ..][0..2], .little);
        if (m.hit(1, units)) return true;
        // Windows-1251
        return m.hit(2, decodeCp(m.gpa, 1251, chunk));
    }

    /// Searches tail ++ decoded (takes `decoded`), keeps the new tail.
    fn hit(m: *Matcher, k: usize, decoded: ?[]u16) bool {
        const dec = decoded orelse return false;
        defer m.gpa.free(dec);
        const t = &m.tails[k];
        t.appendSlice(m.gpa, dec) catch return false;
        const hay = t.items;
        if (hay.len >= m.needle.len and m.needle.len > 0) {
            const r = w.FindStringOrdinal(@intCast(w.FIND_FROMSTART), hay.ptr, @intCast(hay.len), m.needle.ptr, @intCast(m.needle.len), @intFromBool(m.ignore_case));
            if (r >= 0) return true;
        }
        const keep = @min(hay.len, m.needle.len -| 1);
        std.mem.copyForwards(u16, t.items[0..keep], hay[hay.len - keep ..]);
        t.shrinkRetainingCapacity(keep);
        return false;
    }
};

fn decodeCp(gpa: Allocator, cp: c_uint, bytes: []const u8) ?[]u16 {
    if (bytes.len == 0) return gpa.alloc(u16, 0) catch null;
    const n = w.MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), null, 0);
    const out = gpa.alloc(u16, @intCast(@max(n, 0))) catch return null;
    _ = w.MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), out.ptr, n);
    return out;
}

// ---- the window --------------------------------------------------------------------------------------------------

const Hit = struct { path: []u8, inner: ?[]u8, size: u64 };

const Row = struct {
    name: []const u8,
    location: []const u8,
    size: []const u8,
    path: []const u8,
    inner: ?[]const u8,
};

pub const Find = struct {
    pub const win_id = "find";
    pub const win_size = [2]f32{ 680, 480 };
    gpa: Allocator,
    io: std.Io,
    masks: [512:0]u8 = @splat(0),
    text: [512:0]u8 = @splat(0),
    look_in: [2048:0]u8 = @splat(0),
    match_case: bool = false,
    subfolders: bool = true,
    archives: bool = true,
    rows_arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    sel: ?usize = null,
    // worker
    job: kit.jobs.Job = .{},
    w_root: []u8 = &.{},
    w_masks: []u8 = &.{},
    w_text: ?[]u8 = null,
    w_case: bool = false,
    w_sub: bool = true,
    w_arc: bool = true,
    lock: kit.win.Lock = .{},
    queue: std.ArrayList(Hit) = .empty,
    current: [1024]u8 = undefined,
    current_len: usize = 0,
    skipped: std.atomic.Value(u32) = .init(0),
    err_text: [1024]u8 = undefined,
    err_len: usize = 0,
    last_flush: u64 = 0,
    running: bool = false,

    pub fn title(_: *Find, _: []u8) []const u8 {
        return S.tr().findFilesTitle;
    }

    pub fn body(f: *Find, d: *Dialogs) bool {
        const s = D.scale();
        if (f.running) {
            const now = w.GetTickCount64();
            if (now -% f.last_flush >= 200) {
                f.flush();
                f.last_flush = now;
            }
            if (f.job.takeFinished()) f.finish();
            d.ctx.app.requestFrames(1);
        }
        const cap = D.capWidth(144, &.{ S.tr().fileMasks, S.tr().textToFind, S.tr().lookIn });
        const avail = im.ImGui_GetContentRegionAvail().x / s;
        const browse_w = @max(100, D.textWidth(S.tr().browse) + im.ImGui_GetStyle().*.FramePadding.x * 2 / s);
        D.caption(S.tr().fileMasks, cap);
        _ = D.input("find_masks", &f.masks, avail - cap, 0);
        D.caption(S.tr().textToFind, cap);
        _ = D.input("find_text", &f.text, avail - cap, 0);
        D.caption(S.tr().lookIn, cap);
        _ = D.input("find_look_in", &f.look_in, avail - cap - browse_w - im.ImGui_GetStyle().*.ItemSpacing.x / s, 0);
        im.ImGui_SameLine();
        if (D.buttonMin(S.tr().browse, "find_browse", browse_w)) {
            const cur = D.bufText(&f.look_in);
            if (kit.win.pickFolder(f.gpa, D.owner(d), .{ .folder = if (engine.dirExists(cur)) cur else null }) catch null) |p| {
                defer f.gpa.free(p);
                D.setText(&f.look_in, p);
            }
        }
        im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + cap * s);
        _ = D.checkbox(S.tr().matchCase, "find_case", &f.match_case);
        D.flowAt(cap + 174, D.checkboxWidth(S.tr().subfolders), cap);
        _ = D.checkbox(S.tr().subfolders, "find_subfolders", &f.subfolders);
        D.flowAt(cap + 314, D.checkboxWidth(S.tr().inArchives), cap);
        _ = D.checkbox(S.tr().inArchives, "find_archives", &f.archives);

        const foot = (im.ImGui_GetFrameHeightWithSpacing() + im.ImGui_GetTextLineHeightWithSpacing()) + 8 * s;
        const flags = im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg | im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_Resizable;
        if (im.ImGui_BeginTableEx("##find_table", 3, flags, .{ .x = 0, .y = -foot }, 0)) {
            im.ImGui_TableSetupScrollFreeze(0, 1);
            im.ImGui_TableSetupColumnEx(S.tr().fileColumn, im.ImGuiTableColumnFlags_WidthFixed, 200 * s, 0);
            im.ImGui_TableSetupColumnEx(S.tr().location, im.ImGuiTableColumnFlags_WidthStretch, 0, 0);
            im.ImGui_TableSetupColumnEx(S.tr().size, im.ImGuiTableColumnFlags_WidthFixed, 100 * s, 0);
            im.ImGui_TableHeadersRow();
            var clip = std.mem.zeroes(im.ImGuiListClipper);
            im.ImGuiListClipper_Begin(&clip, @intCast(f.rows.items.len), -1);
            while (im.ImGuiListClipper_Step(&clip)) {
                var i: usize = @intCast(clip.DisplayStart);
                while (i < @as(usize, @intCast(clip.DisplayEnd))) : (i += 1) {
                    const r = f.rows.items[i];
                    im.ImGui_TableNextRow();
                    _ = im.ImGui_TableNextColumn();
                    var lb: [800]u8 = undefined;
                    const l = std.mem.printSentinel(&lb, "{s}##find_r{d}", .{ r.name[0..@min(r.name.len, 700)], i }, 0) catch continue;
                    if (im.ImGui_SelectableEx(l.ptr, f.sel == i, im.ImGuiSelectableFlags_SpanAllColumns | im.ImGuiSelectableFlags_AllowDoubleClick, .{ .x = 0, .y = 0 })) {
                        f.sel = i;
                        if (im.ImGui_IsMouseDoubleClicked(0)) f.locate(d);
                    }
                    _ = im.ImGui_TableNextColumn();
                    im.ImGui_TextUnformattedEx(r.location.ptr, r.location.ptr + r.location.len);
                    _ = im.ImGui_TableNextColumn();
                    const tw = im.ImGui_CalcTextSizeEx(r.size.ptr, r.size.ptr + r.size.len, false, -1).x;
                    im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + @max(0, im.ImGui_GetContentRegionAvail().x - tw));
                    im.ImGui_TextUnformattedEx(r.size.ptr, r.size.ptr + r.size.len);
                }
            }
            im.ImGuiListClipper_End(&clip);
            im.ImGui_EndTable();
        }

        var sb: [1600]u8 = undefined;
        kit.ui.text("find_status", f.statusText(&sb), null, 0);

        const find_text = if (f.running) S.tr().stop else S.tr().tbFind;
        D.alignRight(&.{ find_text, S.tr().locate, S.tr().tbView, S.tr().close });
        if (D.primary(true, find_text, "find_go") or (D.enterPressed() and !f.running)) {
            if (f.running) f.job.cancel() else f.start();
        }
        im.ImGui_SameLine();
        if (D.buttonOn(f.sel != null, S.tr().locate, "find_locate")) f.locate(d); // both act on the selected hit
        im.ImGui_SameLine();
        if (D.buttonOn(f.sel != null, S.tr().tbView, "find_view")) f.view(d);
        im.ImGui_SameLine();
        if (D.button(S.tr().close, "find_close") or D.escPressed()) return false;
        return true;
    }

    fn statusText(f: *Find, buf: []u8) []const u8 {
        if (f.err_len > 0 and !f.running) return f.err_text[0..f.err_len];
        var wr: std.Io.Writer = .fixed(buf);
        S.write(&wr, S.tr().foundFmt, .{f.rows.items.len}) catch {};
        const sk = f.skipped.load(.acquire);
        if (sk > 0) S.write(&wr, S.tr().skippedFmt, .{sk}) catch {};
        f.lock.lock();
        if (f.running and f.current_len > 0) wr.print("  -  {s}", .{f.current[0..f.current_len]}) catch {};
        f.lock.unlock();
        return wr.buffered();
    }

    fn locate(f: *Find, d: *Dialogs) void {
        const i = f.sel orelse return;
        const r = f.rows.items[i];
        const path = d.ctx.dupe(r.path) catch return;
        d.ctx.post(.{ .locate = .{ .path = path, .inner = if (r.inner) |x| d.ctx.dupe(x) catch null else null } });
    }

    fn view(f: *Find, d: *Dialogs) void {
        const i = f.sel orelse return;
        const r = f.rows.items[i];
        if (r.inner == null) return viewer_dlg.open(d, r.path, fspath.basename(r.path));
        viewFound(d, r.path, r.inner.?);
    }

    /// Find, or Stop while a search runs (same button).
    fn start(f: *Find) void {
        f.clearRows();
        f.skipped.store(0, .release);
        f.err_len = 0;
        f.freeWorkerArgs();
        f.w_root = f.gpa.dupe(u8, std.mem.trim(u8, D.bufText(&f.look_in), " \t")) catch return;
        f.w_masks = f.gpa.dupe(u8, D.bufText(&f.masks)) catch return;
        f.w_text = if (D.bufText(&f.text).len > 0) f.gpa.dupe(u8, D.bufText(&f.text)) catch null else null;
        f.w_case = f.match_case;
        f.w_sub = f.subfolders;
        f.w_arc = f.archives;
        f.job.start(f, worker) catch return;
        f.running = true;
        f.last_flush = w.GetTickCount64();
    }

    fn finish(f: *Find) void {
        f.running = false;
        f.flush();
        f.current_len = 0;
    }

    fn clearRows(f: *Find) void {
        f.rows.clearRetainingCapacity();
        _ = f.rows_arena.reset(.retain_capacity);
        f.sel = null;
    }

    /// Moves what the worker found into the list - in batches, not one wake per hit.
    fn flush(f: *Find) void {
        f.lock.lock();
        const got = f.queue;
        f.queue = .empty;
        f.lock.unlock();
        var q = got;
        defer q.deinit(f.gpa);
        const a = f.rows_arena.allocator();
        for (q.items) |h| {
            defer {
                f.gpa.free(h.path);
                if (h.inner) |x| f.gpa.free(x);
            }
            var row: Row = .{ .name = "", .location = "", .size = "", .path = a.dupe(u8, h.path) catch continue, .inner = null };
            if (h.inner) |inner| {
                row.inner = a.dupe(u8, inner) catch continue;
                const slash = std.mem.findScalarLast(u8, inner, '/');
                row.name = a.dupe(u8, if (slash) |k| inner[k + 1 ..] else inner) catch continue;
                if (slash) |k| {
                    const loc = a.dupe(u8, inner[0..k]) catch continue;
                    std.mem.replaceScalar(u8, loc, '/', '\\');
                    row.location = std.mem.concat(a, u8, &.{ h.path, "\\", loc }) catch continue;
                } else row.location = row.path;
            } else {
                row.name = fspath.basename(row.path);
                row.location = fspath.dirname(row.path) orelse "";
            }
            var nb: [32]u8 = undefined;
            row.size = a.dupe(u8, engine.niceSize(&nb, @intCast(@min(h.size, std.math.maxInt(i64))))) catch "";
            f.rows.append(f.gpa, row) catch {};
        }
    }

    // ---- the worker ----

    fn worker(job: *kit.jobs.Job) anyerror!void {
        const f: *Find = @fieldParentPtr("job", job);
        f.search() catch |e| {
            if (e == error.Canceled) return;
            const t = engine.friendly(e, null);
            const n = @min(t.len, f.err_text.len);
            @memcpy(f.err_text[0..n], t[0..n]);
            f.err_len = n;
        };
    }

    fn search(f: *Find) !void {
        if (engine.fileExists(f.w_root)) return f.inArchive(f.w_root);
        try f.walk(f.w_root);
    }

    fn setCurrent(f: *Find, dir: []const u8) void {
        f.lock.lock();
        const n = @min(dir.len, f.current.len);
        @memcpy(f.current[0..n], dir[0..n]);
        f.current_len = n;
        f.lock.unlock();
        f.job.setStatus("{s}", .{dir[0..@min(dir.len, 200)]}); // wakes the UI (throttled)
    }

    fn push(f: *Find, path: []const u8, inner: ?[]const u8, size: u64) void {
        const p = f.gpa.dupe(u8, path) catch return;
        const in: ?[]u8 = if (inner) |x| f.gpa.dupe(u8, x) catch {
            f.gpa.free(p);
            return;
        } else null;
        f.lock.lock();
        f.queue.append(f.gpa, .{ .path = p, .inner = in, .size = size }) catch {
            f.gpa.free(p);
            if (in) |x| f.gpa.free(x);
        };
        f.lock.unlock();
        f.job.addDone(1);
    }

    /// FindFirstFileExW walk; reparse points skipped: a junction loop (or a OneDrive placeholder that would
    /// download) can't hang it.
    fn walk(f: *Find, dir: []const u8) !void {
        if (f.job.cancelled()) return error.Canceled;
        const gpa = f.gpa;
        const pattern = try std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, dir, "\\/"), "\\*" });
        defer gpa.free(pattern);
        const pw = try kit.win.toW(gpa, pattern);
        defer gpa.free(pw);
        var fd: w.WIN32_FIND_DATAW = undefined;
        const h = w.FindFirstFileExW(pw.ptr, w.FindExInfoBasic, &fd, w.FindExSearchNameMatch, null, @intCast(w.FIND_FIRST_EX_LARGE_FETCH));
        if (h == w.INVALID_HANDLE_VALUE) return; // inaccessible: skipped quietly (IgnoreInaccessible)
        defer _ = w.FindClose(h);
        var subdirs: std.ArrayList([]u8) = .empty;
        defer {
            for (subdirs.items) |x| gpa.free(x);
            subdirs.deinit(gpa);
        }
        var announced = false;
        while (true) {
            if (f.job.cancelled()) return error.Canceled;
            const name_w = std.mem.sliceTo(&fd.cFileName, 0);
            const is_dot = std.mem.eql(u16, name_w, &.{'.'}) or std.mem.eql(u16, name_w, &.{ '.', '.' });
            if (!is_dot and fd.dwFileAttributes & @as(u32, @intCast(w.FILE_ATTRIBUTE_REPARSE_POINT)) == 0) {
                const name = try kit.win.fromW(gpa, name_w);
                defer gpa.free(name);
                const full = try std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, dir, "\\/"), "\\", name });
                if (fd.dwFileAttributes & @as(u32, @intCast(w.FILE_ATTRIBUTE_DIRECTORY)) != 0) {
                    if (f.w_sub) subdirs.append(gpa, full) catch gpa.free(full) else gpa.free(full);
                } else {
                    defer gpa.free(full);
                    if (!announced) {
                        f.setCurrent(dir);
                        announced = true;
                    }
                    const size = (@as(u64, fd.nFileSizeHigh) << 32) | fd.nFileSizeLow;
                    if (matches(gpa, name, f.w_masks) and (f.w_text == null or f.fileHas(full, size))) f.push(full, null, size);
                    // ponytail (C#): only known archive extensions are opened (not every docx/apk that is a zip underneath).
                    if (f.w_arc and types.isArchiveExt(std.mem.trimStart(u8, fspath.extension(name), ".")) and engine.looksLikeArchive(f.io, full))
                        try f.inArchive(full);
                }
            }
            if (w.FindNextFileW(h, &fd) == 0) break;
        }
        for (subdirs.items) |sd| try f.walk(sd);
    }

    fn fileHas(f: *Find, path: []const u8, size: u64) bool {
        if (size > max_disk_text) return false;
        const file = std.Io.Dir.cwd().openFile(f.io, path, .{}) catch {
            _ = f.skipped.fetchAdd(1, .acq_rel);
            return false;
        };
        defer file.close(f.io);
        var m = f.matcher() orelse return false;
        defer m.deinit();
        const buf = f.gpa.alloc(u8, 1 << 20) catch return false;
        defer f.gpa.free(buf);
        var off: u64 = 0;
        while (true) {
            if (f.job.cancelled()) return false;
            const n = file.readPositionalAll(f.io, buf, off) catch {
                _ = f.skipped.fetchAdd(1, .acq_rel);
                return false;
            };
            if (n == 0) return false;
            if (m.feed(buf[0..n])) return true;
            off += n;
            if (n < buf.len) return false;
        }
    }

    fn matcher(f: *Find) ?Matcher {
        const needle = kit.win.toW(f.gpa, f.w_text.?) catch return null;
        return .{ .gpa = f.gpa, .needle = needle, .owned = needle, .ignore_case = !f.w_case };
    }

    // ponytail (C#): archives inside archives are not opened; engine.open's own unwrapping (x.tar.gz, .001) applies.
    fn inArchive(f: *Find, path: []const u8) !void {
        const a = engine.open(f.gpa, f.io, path, null, .{ .cancel = &f.job.cancel_flag }, null) catch {
            _ = f.skipped.fetchAdd(1, .acq_rel); // encrypted file list, damaged, locked
            return;
        };
        defer a.close();
        for (a.items()) |it| {
            if (f.job.cancelled()) return error.Canceled;
            const inner = try engine.norm(f.gpa, it.path);
            defer f.gpa.free(inner);
            if (it.is_dir or inner.len == 0) continue;
            const name = if (std.mem.findScalarLast(u8, inner, '/')) |k| inner[k + 1 ..] else inner;
            if (!matches(f.gpa, name, f.w_masks)) continue;
            // Names of encrypted entries are readable, so they still match by name; their contents are skipped.
            if (f.w_text != null and !f.entryHas(a, it)) continue;
            f.push(path, inner, it.size);
        }
    }

    // ponytail (C#): entries are extracted one by one, so a big solid 7z re-decodes its block per entry.
    fn entryHas(f: *Find, a: *engine.Archive, it: sevenzip.Item) bool {
        if (it.encrypted) {
            _ = f.skipped.fetchAdd(1, .acq_rel);
            return false;
        }
        if (it.size > max_entry_text) return false;
        var aw: std.Io.Writer.Allocating = .init(f.gpa);
        defer aw.deinit();
        const Sink = struct {
            aw: *std.Io.Writer.Allocating,
            fn target(ctx: ?*anyopaque, _: *const sevenzip.Item) anyerror!sevenzip.Target {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                return .{ .writer = &s.aw.writer };
            }
        };
        var sk: Sink = .{ .aw = &aw };
        a.x.extract(&.{it.index}, .{ .ctx = &sk, .target = Sink.target }) catch {
            _ = f.skipped.fetchAdd(1, .acq_rel);
            return false;
        };
        var m = f.matcher() orelse return false;
        defer m.deinit();
        return m.feed(aw.written());
    }

    fn freeWorkerArgs(f: *Find) void {
        if (f.w_root.len > 0) f.gpa.free(f.w_root);
        if (f.w_masks.len > 0) f.gpa.free(f.w_masks);
        if (f.w_text) |t| f.gpa.free(t);
        f.w_root = &.{};
        f.w_masks = &.{};
        f.w_text = null;
    }

    pub fn close(_: *Find, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(f: *Find, d: *Dialogs) void {
        if (d.find_win == f) d.find_win = null;
        f.job.cancel(); // closed mid-search: stop it
        f.job.join();
        f.flush();
        f.queue.deinit(f.gpa);
        f.rows.deinit(f.gpa);
        f.rows_arena.deinit();
        f.freeWorkerArgs();
        f.gpa.destroy(f);
    }
};

/// FindForm.Open(root): modeless.
pub fn open(d: *Dialogs, root: []const u8) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Find) catch return;
    f.* = .{ .gpa = gpa, .io = d.ctx.io, .rows_arena = .init(gpa) };
    D.setText(&f.masks, "*.*");
    D.setText(&f.look_in, root);
    d.find_win = f;
    D.push(d, Find, f, false);
}

// ---- ViewFound: an entry of an archive in the viewer ------------------------------------------------------------

const ViewFound = struct {
    o: R.Opener = .{},
    run: R.Run = .{},
    a: ?*engine.Archive = null,
    inner: []u8,
    index: u32 = 0,
    dir: []u8 = &.{},
    state: enum { open, run } = .open,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(ViewFound);
        try engine.extract(r.d.ctx.gpa, r.d.ctx.io, t.a.?, t.dir, &.{t.index}, .Overwrite, r.progress(), engine.Conflict.always_overwrite, settings.current().Motw, .{}, &r.diag);
    }

    pub fn tick(t: *ViewFound, d: *Dialogs) bool {
        const gpa = d.ctx.gpa;
        switch (t.state) {
            .open => {
                if (!t.o.tick(d)) return true;
                t.a = t.o.archive orelse return false;
                t.o.archive = null;
                const found = for (t.a.?.items()) |it| {
                    const n = engine.norm(gpa, it.path) catch continue;
                    defer gpa.free(n);
                    if (types.eqlIgnoreCase(n, t.inner)) break it.index;
                } else return false;
                t.index = found;
                t.dir = engine.newTempDir(gpa, d.ctx.io) catch return false;
                t.state = .run;
                t.run.start(d, S.tr().extracting, t, work, true);
                return true;
            },
            .run => {
                const o = t.run.tick() orelse return true;
                if (o != .ok) return false;
                const rel = gpa.dupe(u8, t.inner) catch return false;
                defer gpa.free(rel);
                std.mem.replaceScalar(u8, rel, '/', '\\');
                const file = std.mem.concat(gpa, u8, &.{ t.dir, "\\", rel }) catch return false;
                defer gpa.free(file);
                if (engine.fileExists(file)) viewer_dlg.open(d, file, fspath.basename(file));
                return false;
            },
        }
    }

    pub fn deinit(t: *ViewFound, d: *Dialogs) void {
        t.run.deinit();
        t.o.deinit(d);
        if (t.a) |a| a.close();
        d.ctx.gpa.free(t.inner);
        if (t.dir.len > 0) d.ctx.gpa.free(t.dir);
        d.ctx.gpa.destroy(t);
    }
};

fn viewFound(d: *Dialogs, path: []const u8, inner: []const u8) void {
    const gpa = d.ctx.gpa;
    const t = gpa.create(ViewFound) catch return;
    t.* = .{ .inner = gpa.dupe(u8, inner) catch return gpa.destroy(t) };
    t.o.start(d, path, null);
    D.addTask(d, ViewFound, t, false);
}

test "find: masks and text" {
    const gpa = std.testing.allocator;
    try std.testing.expect(matches(gpa, "readme", "*.*"));
    try std.testing.expect(matches(gpa, "a.TXT", "*.md; *.txt"));
    try std.testing.expect(!matches(gpa, "a.txt", "*.md"));
    try std.testing.expect(matches(gpa, "Звіт.doc", "з*.DOC"));
    try std.testing.expect(matches(gpa, "x", ""));
    try std.testing.expect(matches(gpa, "abc", "a?c"));
    const needle = std.unicode.utf8ToUtf16LeStringLiteral("Привіт");
    var m: Matcher = .{ .gpa = gpa, .needle = needle, .ignore_case = true };
    defer m.deinit();
    const text = "xx привіт yy"; // UTF-8, split inside a character
    try std.testing.expect(!m.feed(text[0..6]));
    try std.testing.expect(m.feed(text[6..]));
}
