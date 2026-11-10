//! MP-G2: ViewerForm (View): read-only text, the first 16 MB, BOM / UTF-8 / Windows-1251 autodetect,
//! code page switch (1251 / 866 / UTF-16LE / UTF-8), word wrap, font size, Find (Ctrl+F) / Find next (F3) with
//! match case and wrap-around, Esc closes. Modeless, several at once.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const shell = @import("mw_shell.zig");

const S = C.S;
const engine = C.engine;
const im = kit.im;
const w = kit.w;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;

// ponytail (C#): only the first 16 MB is read and shown; a paged/memory-mapped view if huge logs matter.
const max_bytes = 16 * 1024 * 1024;

pub const Enc = enum { cp1251, cp866, utf16le, utf8, utf16be };

const enc_menu = [_]struct { text: []const u8, enc: Enc }{
    .{ .text = "Windows (1251)", .enc = .cp1251 },
    .{ .text = "DOS (866)", .enc = .cp866 },
    .{ .text = "Unicode UTF-16LE", .enc = .utf16le },
    .{ .text = "UTF-8", .enc = .utf8 },
};

fn encName(e: Enc) []const u8 {
    for (enc_menu) |m| if (m.enc == e) return m.text;
    return "Unicode UTF-16BE"; // BOM-detected only, not in the menu
}

/// Font faces of Font... (ViewerForm's FontDialog: Consolas 10 pt by default). Proper names, not UI text.
const faces = [_][]const u8{ "Consolas", "Segoe UI" };
var mono: ?*im.ImFont = null;
var mono_tried = false;

/// Consolas, added to the atlas on first use (dynamic fonts: any size later); null = not installed.
fn monoFont() ?*im.ImFont {
    if (mono_tried) return mono;
    mono_tried = true;
    var dir_w: [260]u16 = undefined;
    const n = w.GetWindowsDirectoryW(&dir_w, dir_w.len);
    if (n == 0 or n >= dir_w.len) return null;
    var buf: [800]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = dir_buf[0..std.unicode.wtf16LeToWtf8(&dir_buf, dir_w[0..n])];
    const p = std.mem.printSentinel(&buf, "{s}\\Fonts\\consola.ttf", .{dir}, 0) catch return null;
    if (!kit.win.isFile(p)) return null; // ImGui asserts on a missing file
    mono = im.ImFontAtlas_AddFontFromFileTTF(im.ImGui_GetIO().*.Fonts, p.ptr, 16, null, null);
    return mono;
}

/// An invisible 1x1 item labelled "<text>##<id>" at the cursor (state a test reads); the layout is unchanged.
fn stateItem(text: []const u8, id: []const u8) void {
    const pos = im.ImGui_GetCursorScreenPos();
    var buf: [1200]u8 = undefined;
    var t = text[0..@min(text.len, 1024)];
    while (t.len > 0 and t.len < text.len and t[t.len - 1] & 0xC0 == 0x80) t = t[0 .. t.len - 1]; // whole characters
    if (t.len > 0 and t.len < text.len and t[t.len - 1] >= 0xC0) t = t[0 .. t.len - 1];
    const l = std.mem.printSentinel(&buf, "{s}##{s}", .{ t, id }, 0) catch return;
    _ = im.ImGui_InvisibleButton(l.ptr, .{ .x = 1, .y = 1 }, 0);
    im.ImGui_SetCursorScreenPos(pos);
}

/// BOM wins; else strict UTF-8 if the bytes are valid UTF-8 (a character cut by the 16 MB ceiling is fine);
/// else Windows-1251.
pub fn detect(bytes: []const u8) Enc {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .utf8;
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .utf16le;
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .utf16be;
    var end = bytes.len;
    // drop an incomplete sequence at the very end (at most 3 bytes)
    var back: usize = 0;
    while (back < 3 and end > 0 and bytes[end - 1] & 0xC0 == 0x80) : (back += 1) end -= 1;
    if (end > 0 and bytes[end - 1] >= 0xC0) {
        const need = std.unicode.utf8ByteSequenceLength(bytes[end - 1]) catch 1;
        if (need > back + 1) end -= 1 else end = bytes.len;
    } else end = bytes.len;
    return if (std.unicode.utf8ValidateSlice(bytes[0..end])) .utf8 else .cp1251;
}

/// The bytes as UTF-8 for the text box: BOM skipped, NULs as spaces, CR dropped. NUL-terminated, with room.
pub fn decode(gpa: Allocator, bytes: []const u8, enc: Enc) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (enc) {
        .utf8 => {
            // invalid sequences become U+FFFD (.NET's Encoding.UTF8 did the same)
            const b = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
            try out.ensureUnusedCapacity(gpa, b.len);
            var i: usize = 0;
            while (i < b.len) {
                const n = std.unicode.utf8ByteSequenceLength(b[i]) catch 0;
                if (n > 0 and i + n <= b.len and (n == 1 or (std.unicode.utf8Decode(b[i .. i + n]) catch null) != null)) {
                    try out.appendSlice(gpa, b[i .. i + n]);
                    i += n;
                } else {
                    try out.appendSlice(gpa, "\u{FFFD}");
                    i += 1;
                }
            }
        },
        .utf16le, .utf16be => {
            const bom: []const u8 = if (enc == .utf16le) "\xFF\xFE" else "\xFE\xFF";
            const b = if (std.mem.startsWith(u8, bytes, bom)) bytes[2..] else bytes;
            const units = try gpa.alloc(u16, b.len / 2);
            defer gpa.free(units);
            for (units, 0..) |*u, i| u.* = if (enc == .utf16le) std.mem.readInt(u16, b[i * 2 ..][0..2], .little) else std.mem.readInt(u16, b[i * 2 ..][0..2], .big);
            try appendWide(gpa, &out, units);
        },
        .cp1251, .cp866 => {
            const cp: c_uint = if (enc == .cp1251) 1251 else 866;
            if (bytes.len > 0) {
                const n = w.MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), null, 0);
                const units = try gpa.alloc(u16, @intCast(@max(n, 0)));
                defer gpa.free(units);
                _ = w.MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), units.ptr, n);
                try appendWide(gpa, &out, units);
            }
        },
    }
    // TextBox stops at '\0'; ImGui would too.
    var j: usize = 0;
    for (out.items) |c| {
        if (c == '\r') continue;
        out.items[j] = if (c == 0) ' ' else c;
        j += 1;
    }
    out.shrinkRetainingCapacity(j);
    try out.appendNTimes(gpa, 0, 2);
    const s = try out.toOwnedSlice(gpa);
    return s[0..j :0];
}

fn appendWide(gpa: Allocator, out: *std.ArrayList(u8), units: []const u16) !void {
    try out.ensureUnusedCapacity(gpa, units.len * 3);
    const n = std.unicode.wtf16LeToWtf8(out.unusedCapacitySlice(), units);
    out.items.len += n;
}

pub const Viewer = struct {
    pub const win_id = "viewer";
    pub const win_size = [2]f32{ 900, 650 };
    pub const menu_bar = true;
    gpa: Allocator,
    bytes: []u8,
    title_text: []u8,
    enc: Enc,
    text: [:0]u8,
    /// UTF-16 copy of `text` for the case-insensitive search (built on the first search).
    wide: ?[:0]u16 = null,
    wrap: bool = false,
    font_size: i32 = 16,
    /// faces[] index.
    face: usize = 0,
    find: [256:0]u8 = @splat(0),
    match_case: bool = false,
    sel: [2]c_int = .{ 0, 0 },
    pending_sel: ?[2]c_int = null,
    focus_text: bool = false,
    reply: Reply = .{},
    asking: bool = false,
    font_popup: bool = false,

    pub fn title(v: *Viewer, _: []u8) []const u8 {
        return v.title_text;
    }

    fn setEnc(v: *Viewer, e: Enc) void {
        const t = decode(v.gpa, v.bytes, e) catch return;
        v.gpa.free(v.text.ptr[0 .. v.text.len + 2]);
        v.text = t;
        v.enc = e;
        if (v.wide) |x| v.gpa.free(x);
        v.wide = null;
        v.sel = .{ 0, 0 };
        v.pending_sel = .{ 0, 0 };
    }

    pub fn body(v: *Viewer, d: *Dialogs) bool {
        if (v.asking and v.reply.done) {
            v.asking = false;
            if (v.reply.text) |t| if (t.len > 0) {
                D.setText(&v.find, t);
                v.match_case = v.reply.flag1;
                v.reply.reset(v.gpa);
                v.findNext(d);
            };
            v.reply.reset(v.gpa);
        }
        var quit = false;
        if (im.ImGui_BeginMenuBar()) {
            var pb: [64]u8 = undefined;
            if (im.ImGui_BeginMenu(D.lbl(&pb, S.mFile.get(), "viewer_mfile").ptr)) {
                var b: [128]u8 = undefined;
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.exit.get(), "viewer_exit").ptr, "Esc", false, true)) quit = true;
                im.ImGui_EndMenu();
            }
            if (im.ImGui_BeginMenu(D.lbl(&pb, S.mEdit.get(), "viewer_medit").ptr)) {
                var b: [128]u8 = undefined;
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.copyCmd.get(), "viewer_copy").ptr, "Ctrl+C", false, true)) v.copy(d);
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.selectAllItems.get(), "viewer_select_all").ptr, "Ctrl+A", false, true)) v.selectAll();
                im.ImGui_Separator();
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.findText.get(), "viewer_find").ptr, "Ctrl+F", false, true)) v.askFind(d);
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.findNext.get(), "viewer_find_next").ptr, "F3", false, true)) v.f3(d);
                im.ImGui_EndMenu();
            }
            if (im.ImGui_BeginMenu(D.lbl(&pb, S.mView.get(), "viewer_mview").ptr)) {
                var b: [128]u8 = undefined;
                for (enc_menu, 0..) |m, i| {
                    var ib: [32]u8 = undefined;
                    const id = std.mem.print(&ib, "viewer_enc{d}", .{i}) catch "viewer_enc";
                    if (im.ImGui_MenuItemEx(D.lbl(&b, m.text, id).ptr, null, v.enc == m.enc, true)) v.setEnc(m.enc);
                }
                im.ImGui_Separator();
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.wordWrap.get(), "viewer_wrap").ptr, "Ctrl+W", v.wrap, true)) v.wrap = !v.wrap;
                if (im.ImGui_MenuItemEx(D.lbl(&b, S.fontCmd.get(), "viewer_font").ptr, null, false, true)) v.font_popup = true;
                im.ImGui_EndMenu();
            }
            im.ImGui_EndMenuBar();
        }
        if (v.font_popup) {
            _ = im.ImGui_OpenPopup("##viewer_font_popup", 0);
            v.font_popup = false;
        }
        if (im.ImGui_BeginPopup("##viewer_font_popup", 0)) {
            im.ImGui_TextUnformatted(D.noDots(S.fontCmd.get()).ptr);
            _ = D.combo("viewer_font_face", &faces, &v.face, 200);
            im.ImGui_SetNextItemWidth(200 * D.scale());
            _ = im.ImGui_SliderInt("##viewer_font_size", &v.font_size, 10, 32);
            if (D.button(S.ok.get(), "viewer_font_ok")) im.ImGui_CloseCurrentPopup();
            im.ImGui_EndPopup();
        }

        const esc = D.escPressed(); // not the Esc that closed a menu / the font list
        if (im.ImGui_IsWindowFocused(im.ImGuiFocusedFlags_RootAndChildWindows) and !v.asking) {
            const io = im.ImGui_GetIO();
            if (esc) quit = true;
            if (io.*.KeyCtrl and im.ImGui_IsKeyPressed(im.ImGuiKey_F)) v.askFind(d);
            if (io.*.KeyCtrl and im.ImGui_IsKeyPressed(im.ImGuiKey_W)) v.wrap = !v.wrap;
            if (im.ImGui_IsKeyPressed(im.ImGuiKey_F3)) v.f3(d);
        }

        // what a test reads: the encoding, wrap, font, and the start of the decoded text
        stateItem(encName(v.enc), "viewer_enc_state");
        stateItem(if (v.wrap) "on" else "off", "viewer_wrap_state");
        var fb: [64]u8 = undefined;
        stateItem(std.mem.print(&fb, "{s} {d}", .{ faces[v.face], v.font_size }) catch "", "viewer_font_state");
        stateItem(v.text, "viewer_content");
        if (v.pending_sel != null or v.focus_text) {
            im.ImGui_SetKeyboardFocusHere();
            v.focus_text = false;
        }
        im.ImGui_PushFontFloat(if (v.face == 0) monoFont() else null, @floatFromInt(v.font_size));
        var flags: c_int = im.ImGuiInputTextFlags_ReadOnly | im.ImGuiInputTextFlags_CallbackAlways;
        if (v.wrap) flags |= im.ImGuiInputTextFlags_WordWrap;
        _ = im.ImGui_InputTextMultilineEx("##viewer_text", v.text.ptr, v.text.len + 1, .{ .x = -1, .y = -1 }, flags, callback, v);
        im.ImGui_PopFont();
        return !quit;
    }

    fn callback(data: [*c]im.ImGuiInputTextCallbackData) callconv(.c) c_int {
        const v: *Viewer = @ptrCast(@alignCast(data.*.UserData.?));
        if (v.pending_sel) |s| {
            data.*.SelectionStart = s[0];
            data.*.SelectionEnd = s[1];
            data.*.CursorPos = s[1];
            v.pending_sel = null;
        }
        v.sel = .{ @min(data.*.SelectionStart, data.*.SelectionEnd), @max(data.*.SelectionStart, data.*.SelectionEnd) };
        return 0;
    }

    fn copy(v: *Viewer, d: *Dialogs) void {
        const a: usize = @intCast(@max(0, v.sel[0]));
        const b: usize = @intCast(@min(@as(c_int, @intCast(v.text.len)), v.sel[1]));
        if (b <= a) return;
        _ = shell.setText(v.gpa, D.owner(d), v.text[a..b]);
    }

    fn selectAll(v: *Viewer) void {
        v.pending_sel = .{ 0, @intCast(v.text.len) };
    }

    fn askFind(v: *Viewer, d: *Dialogs) void {
        const f = v.gpa.create(FindAsk) catch return;
        f.* = .{ .reply = &v.reply, .match_case = v.match_case };
        D.setText(&f.box, D.bufText(&v.find));
        v.reply.reset(v.gpa);
        v.asking = true;
        D.push(d, FindAsk, f, true);
    }

    fn f3(v: *Viewer, d: *Dialogs) void {
        if (D.bufText(&v.find).len == 0) v.askFind(d) else v.findNext(d);
    }

    /// Forward from the caret, wrapping to the top once.
    fn findNext(v: *Viewer, d: *Dialogs) void {
        const needle = D.bufText(&v.find);
        if (needle.len == 0) return;
        const wide = v.wide orelse blk: {
            const x = kit.win.toW(v.gpa, v.text) catch return;
            v.wide = x;
            break :blk x;
        };
        const nw = kit.win.toW(v.gpa, needle) catch return;
        defer v.gpa.free(nw);
        const start_b: usize = @intCast(@max(0, @min(@as(c_int, @intCast(v.text.len)), v.sel[1])));
        const start_w = wideLen(v.text[0..start_b]);
        var at = findWide(wide, start_w, nw, !v.match_case);
        if (at == null) at = findWide(wide, 0, nw, !v.match_case);
        const hit = at orelse {
            var buf: [600]u8 = undefined;
            return P.message(d, .info, S.app, S.fillZ(&buf, S.notFoundFmt.get(), .{needle}), .ok, false, null);
        };
        const b0 = utf8Len(wide[0..hit]);
        const b1 = b0 + utf8Len(wide[hit .. hit + nw.len]);
        v.pending_sel = .{ @intCast(b0), @intCast(b1) };
    }

    pub fn close(_: *Viewer, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(v: *Viewer, d: *Dialogs) void {
        _ = d;
        v.reply.reset(v.gpa);
        v.gpa.free(v.bytes);
        v.gpa.free(v.text.ptr[0 .. v.text.len + 2]);
        if (v.wide) |x| v.gpa.free(x);
        v.gpa.free(v.title_text);
        v.gpa.destroy(v);
    }
};

fn wideLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    const n = w.MultiByteToWideChar(w.CP_UTF8, 0, s.ptr, @intCast(s.len), null, 0);
    return @intCast(@max(n, 0));
}

fn utf8Len(s: []const u16) usize {
    if (s.len == 0) return 0;
    const n = w.WideCharToMultiByte(w.CP_UTF8, 0, s.ptr, @intCast(s.len), null, 0, null, null);
    return @intCast(@max(n, 0));
}

/// FindStringOrdinal from `from`: the index in `hay`, or null.
fn findWide(hay: []const u16, from: usize, needle: []const u16, ignore_case: bool) ?usize {
    if (from >= hay.len) return null;
    const r = w.FindStringOrdinal(@intCast(w.FIND_FROMSTART), hay[from..].ptr, @intCast(hay.len - from), needle.ptr, @intCast(needle.len), @intFromBool(ignore_case));
    return if (r < 0) null else from + @as(usize, @intCast(r));
}

/// The viewer's Find box: text, match case, Find next / Cancel. reply.text + flag1 (match case).
const FindAsk = struct {
    pub const win_id = "viewer_find";
    box: [256:0]u8 = @splat(0),
    match_case: bool,
    reply: ?*Reply,
    focus: bool = true,

    pub fn title(_: *FindAsk, _: []u8) []const u8 {
        return S.tbFind.get();
    }

    pub fn body(f: *FindAsk, d: *Dialogs) bool {
        if (f.focus) {
            im.ImGui_SetKeyboardFocusHere();
            f.focus = false;
        }
        const entered = D.input("viewer_find_text", &f.box, 356, im.ImGuiInputTextFlags_EnterReturnsTrue);
        _ = D.checkbox(S.matchCase.get(), "viewer_find_case", &f.match_case);
        D.alignRight(&.{ S.findNext.get(), S.cancel.get() });
        const ok = D.button(S.findNext.get(), "viewer_find_go") or entered;
        im.ImGui_SameLine();
        if (D.button(S.cancel.get(), "viewer_find_cancel") or D.escPressed()) return false;
        if (ok and D.bufText(&f.box).len > 0) {
            if (f.reply) |r| r.* = .{ .done = true, .button = 0, .text = d.ctx.gpa.dupe(u8, D.bufText(&f.box)) catch null, .flag1 = f.match_case };
            f.reply = null;
            return false;
        }
        return true;
    }

    pub fn close(_: *FindAsk, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(f: *FindAsk, d: *Dialogs) void {
        if (f.reply) |r| r.* = .{ .done = true };
        d.ctx.gpa.destroy(f);
    }
};

/// ViewerForm.Open: a read error is one alert.
pub fn open(d: *Dialogs, path: []const u8, title_text: []const u8) void {
    const gpa = d.ctx.gpa;
    const io = d.ctx.io;
    const bytes = readHead(gpa, io, path) catch |e| {
        var buf: [1200]u8 = undefined;
        return P.message(d, .err, S.app, S.fillZ(&buf, S.cannotReadFmt.get(), .{ std.Io.Dir.path.basename(path), engine.friendly(e, null) }), .ok, false, null);
    };
    const v = gpa.create(Viewer) catch return gpa.free(bytes.data);
    const enc = detect(bytes.data);
    const text = decode(gpa, bytes.data, enc) catch {
        gpa.free(bytes.data);
        return gpa.destroy(v);
    };
    const t = gpa.print("{s}{s} \u{2014} {s}", .{ title_text, if (bytes.truncated) S.truncated.get() else "", S.app }) catch {
        gpa.free(bytes.data);
        gpa.free(text.ptr[0 .. text.len + 2]);
        return gpa.destroy(v);
    };
    v.* = .{ .gpa = gpa, .bytes = bytes.data, .title_text = t, .enc = enc, .text = text, .focus_text = true };
    D.push(d, Viewer, v, false);
}

fn readHead(gpa: Allocator, io: std.Io, path: []const u8) !struct { data: []u8, truncated: bool } {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const n: usize = @intCast(@min(len, max_bytes));
    const data = try gpa.alloc(u8, n);
    errdefer gpa.free(data);
    const got = try f.readPositionalAll(io, data, 0);
    return .{ .data = if (got < n) try gpa.realloc(data, got) else data, .truncated = len > max_bytes };
}

test "viewer: detect and decode" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Enc.utf8, detect("\xEF\xBB\xBFabc"));
    try std.testing.expectEqual(Enc.utf16le, detect("\xFF\xFEa\x00"));
    try std.testing.expectEqual(Enc.utf8, detect("\xD0\x87\xD0")); // cut inside a character: still UTF-8
    try std.testing.expectEqual(Enc.cp1251, detect("\xCF\xF0\xE8")); // "При" in 1251
    const t = try decode(gpa, "a\r\nb\x00c", .utf8);
    defer gpa.free(t.ptr[0 .. t.len + 2]);
    try std.testing.expectEqualStrings("a\nb c", t);
    const r = try decode(gpa, "\xCFa", .utf8); // cp1251 read as UTF-8
    defer gpa.free(r.ptr[0 .. r.len + 2]);
    try std.testing.expectEqualStrings("\u{FFFD}a", r);
    const u = try decode(gpa, "\xCF\xF0\xE8", .cp1251);
    defer gpa.free(u.ptr[0 .. u.len + 2]);
    try std.testing.expectEqualStrings("\u{041F}\u{0440}\u{0438}", u);
}
