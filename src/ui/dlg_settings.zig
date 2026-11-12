//! MP-G2: SettingsForm (archive folder, MotW policy, profiles: rename / delete / default / in menu, reset) and
//! FavoritesForm (Favorites > Organize: reorder, rename, remove). Both edit copies; OK writes them back.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const types = @import("../core/types.zig");

const S = C.S;
const engine = C.engine;
const settings = C.settings;
const im = kit.im;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;

fn listBoxRow(label: []const u8, id: []const u8, i: usize, selected: bool) bool {
    var lb: [1200]u8 = undefined;
    const l = std.mem.printSentinel(&lb, "{s}##{s}{d}", .{ label[0..@min(label.len, 1100)], id, i }, 0) catch return false;
    return im.ImGui_SelectableEx(l.ptr, selected, 0, .{ .x = 0, .y = 0 });
}

fn sideButton(text: []const u8, id: []const u8, width: f32) bool {
    var b: [256]u8 = undefined;
    return im.ImGui_ButtonEx(D.lbl(&b, text, id).ptr, .{ .x = width * D.scale(), .y = 0 });
}

// ---- SettingsForm ---------------------------------------------------------------------------------------------

pub const Settings = struct {
    pub const win_id = "settings";
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    folder: [2048:0]u8 = @splat(0),
    motw: usize,
    /// The language picked here: applied and saved at once (no OK needed); Cancel does not undo it.
    lang: ?kit.i18n.Lang,
    update_check: bool,
    list: std.ArrayList(settings.Profile) = .empty,
    sel: usize = 0,
    reply: Reply = .{},
    state: enum { idle, rename, reset } = .idle,
    done: bool = false,

    pub fn title(_: *Settings, _: []u8) []const u8 {
        return S.tr().settingsTitle;
    }

    pub fn body(f: *Settings, d: *Dialogs) bool {
        f.poll(d);
        if (f.done) return false;
        const s = D.scale();
        D.caption(S.tr().language, 202);
        im.ImGui_SetNextItemWidth(294 * s);
        if (kit.i18n.combo("##settings_lang", S.tr().languageAuto, &f.lang)) saveLanguage(d, f.lang);
        im.ImGui_TextUnformatted(S.tr().archiveFolder);
        _ = D.inputHint("settings_folder", S.tr().nextToFiles, &f.folder, 390);
        im.ImGui_SameLine();
        if (sideButton(S.tr().browse, "settings_browse", 98)) {
            if (kit.win.pickFolder(f.gpa, D.owner(d), .{ .title = S.tr().archiveFolder, .folder = D.bufText(&f.folder) }) catch null) |p| {
                defer f.gpa.free(p);
                D.setText(&f.folder, p);
            }
        }

        // What extracted files inherit from a downloaded archive (Windows' "this came from the Internet" mark).
        D.caption(S.tr().motwLabel, 202);
        const motws = [_][]const u8{ S.tr().motwNever, S.tr().motwRisky, S.tr().motwAll };
        _ = D.combo("settings_motw", &motws, &f.motw, 294);
        D.tooltip(S.tr().motwTip);
        var ub: [256]u8 = undefined;
        _ = kit.ui.checkbox(D.lbl(&ub, S.tr().updateCheckAuto, "settings_updates").ptr, &f.update_check);

        im.ImGui_TextUnformatted(S.tr().profiles);
        const top = im.ImGui_GetCursorPosY();
        // As tall as the four buttons beside it.
        const list_h = 4 * im.ImGui_GetFrameHeight() + 3 * im.ImGui_GetStyle().*.ItemSpacing.y;
        if (im.ImGui_BeginListBox("##settings_profiles", .{ .x = 370 * s, .y = list_h })) {
            for (f.list.items, 0..) |p, i| {
                var nb: [700]u8 = undefined;
                const name = std.mem.print(&nb, "{s}{s}{s}", .{ p.Name, if (p.IsDefault) S.tr().defaultMark else "", if (p.InMenu) S.tr().menuMark else "" }) catch p.Name;
                if (listBoxRow(name, "settings_p", i, i == f.sel)) f.sel = i;
            }
            im.ImGui_EndListBox();
        }
        const after = im.ImGui_GetCursorPosY();
        const bx = im.ImGui_GetCursorPosX() + 378 * s;
        const has = f.sel < f.list.items.len;
        im.ImGui_BeginDisabled(!has);
        im.ImGui_SetCursorPos(.{ .x = bx, .y = top });
        if (sideButton(S.tr().renameButton, "settings_rename", 118) and has) {
            f.state = .rename;
            P.askName(d, S.tr().renameProfile, null, .profile, f.list.items[f.sel].Name, false, false, &f.reply);
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().delete, "settings_delete", 118) and has) {
            _ = f.list.orderedRemove(f.sel);
            if (f.sel > 0 and f.sel >= f.list.items.len) f.sel -= 1;
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().makeDefault, "settings_default", 118) and has) {
            const on = !f.list.items[f.sel].IsDefault;
            for (f.list.items) |*x| x.IsDefault = false;
            f.list.items[f.sel].IsDefault = on; // a second click on the default one turns "default" off
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().profileInMenuButton, "settings_in_menu", 118) and has) {
            const p = &f.list.items[f.sel];
            p.InMenu = !p.InMenu and std.mem.findScalar(u8, p.Name, '"') == null;
        }
        im.ImGui_EndDisabled();
        im.ImGui_SetCursorPosY(@max(after, im.ImGui_GetCursorPosY()) + 8 * s);

        if (sideButton(S.tr().resetDefaults, "settings_reset", 170)) {
            f.state = .reset;
            P.message(d, .question, S.app, S.tr().resetConfirm, .yes_no, false, &f.reply);
        }
        im.ImGui_SameLine();
        D.alignRight(&.{ S.tr().ok, S.tr().cancel });
        if (D.primary(true, S.tr().ok, "settings_ok") or (D.enterPressed() and !im.ImGui_IsAnyItemActive())) {
            f.apply(d);
            return false;
        }
        im.ImGui_SameLine();
        if (D.button(S.tr().cancel, "settings_cancel") or D.escPressed()) return false;
        return true;
    }

    fn poll(f: *Settings, d: *Dialogs) void {
        if (f.state == .idle or !f.reply.done) return;
        const state = f.state;
        f.state = .idle;
        defer f.reply.reset(f.gpa);
        if (f.reply.button == null) return;
        switch (state) {
            .idle => {},
            .rename => {
                const name = f.reply.text orelse return;
                if (f.sel >= f.list.items.len) return;
                for (f.list.items, 0..) |x, i| if (i != f.sel and types.eqlIgnoreCase(x.Name, name)) {
                    var buf: [600]u8 = undefined;
                    return P.message(d, .info, S.app, S.fillZ(&buf, S.tr().profileNameTakenFmt, .{name}), .ok, false, null);
                };
                f.list.items[f.sel].Name = f.arena.allocator().dupe(u8, name) catch return;
            },
            .reset => {
                settings.reset();
                saveLanguage(d, null); // "Auto" again: Windows' language, for the menu DLL too
                d.ctx.post(.settings_changed);
                f.done = true; // already applied; nothing left for OK to save
            },
        }
    }

    fn apply(f: *Settings, d: *Dialogs) void {
        const a = settings.arena();
        const s = settings.current();
        const folder = std.mem.trim(u8, D.bufText(&f.folder), " \t");
        s.ArchiveFolder = if (folder.len == 0) null else (engine.fullPath(a, folder) catch a.dupe(u8, folder) catch null);
        const list = a.alloc(settings.Profile, f.list.items.len) catch return;
        for (f.list.items, 0..) |p, i| {
            list[i] = p;
            list[i].Name = a.dupe(u8, p.Name) catch p.Name;
        }
        s.Profiles = list;
        s.Motw = @fromBackingInt(@intCast(f.motw));
        s.UpdateCheck = f.update_check;
        settings.commit();
        // renamed, deleted or (un)ticked "in menu": Explorer's items follow
        C.assoc.applyProfiles(d.ctx.hive, s.Profiles) catch {};
        d.ctx.post(.settings_changed);
    }

    pub fn close(f: *Settings, _: *Dialogs) bool {
        return f.state == .idle;
    }

    pub fn deinit(f: *Settings, d: *Dialogs) void {
        _ = d;
        f.reply.reset(f.gpa);
        f.list.deinit(f.gpa);
        f.arena.deinit();
        f.gpa.destroy(f);
    }
};

/// The language takes effect on the next frame (kit.i18n.apply, done by the combo or here), is saved to
/// settings.json and to Software\MakePack Language for the Explorer menu DLL.
fn saveLanguage(d: *Dialogs, l: ?kit.i18n.Lang) void {
    kit.i18n.apply(l);
    const s = settings.current();
    s.Language = if (l) |x| x.code() else "Auto";
    settings.commit();
    C.assoc.setLanguage(d.ctx.hive, s.Language, s.Profiles) catch {};
}

pub fn openSettings(d: *Dialogs) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Settings) catch return;
    const s = settings.current();
    f.* = .{ .gpa = gpa, .arena = .init(gpa), .motw = @backingInt(s.Motw), .lang = s.lang(), .update_check = s.UpdateCheck };
    D.setText(&f.folder, s.ArchiveFolder orelse "");
    // Edited on a copy and written back on OK: Cancel leaves the profiles as they were.
    for (s.Profiles) |p| {
        var q = p;
        q.Name = f.arena.allocator().dupe(u8, p.Name) catch p.Name;
        f.list.append(gpa, q) catch {};
    }
    D.push(d, Settings, f, true);
}

// ---- FavoritesForm --------------------------------------------------------------------------------------------

pub const Favorites = struct {
    pub const win_id = "favorites";
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(settings.Favorite) = .empty,
    sel: usize = 0,
    reply: Reply = .{},
    renaming: bool = false,

    pub fn title(_: *Favorites, _: []u8) []const u8 {
        return D.noDots(S.tr().organizeFavorites);
    }

    pub fn body(f: *Favorites, d: *Dialogs) bool {
        const s = D.scale();
        if (f.renaming and f.reply.done) {
            f.renaming = false;
            if (f.reply.text) |name| if (name.len > 0 and f.sel < f.items.items.len) {
                f.items.items[f.sel].Name = f.arena.allocator().dupe(u8, name) catch f.items.items[f.sel].Name;
            };
            f.reply.reset(f.gpa);
        }
        const top = im.ImGui_GetCursorPosY();
        if (im.ImGui_BeginListBox("##favorites_list", .{ .x = 380 * s, .y = 276 * s })) {
            for (f.items.items, 0..) |x, i| {
                var lb: [1500]u8 = undefined;
                var inner: [600]u8 = undefined;
                const in = x.Inner orelse "";
                const n = @min(in.len, inner.len);
                @memcpy(inner[0..n], in[0..n]);
                std.mem.replaceScalar(u8, inner[0..n], '/', '\\');
                const row = std.mem.print(&lb, "{s}   \u{2014}   {s}{s}{s}", .{ x.Name, x.Path, if (n > 0) "\\" else "", inner[0..n] }) catch x.Name;
                if (listBoxRow(row, "favorites_i", i, i == f.sel)) f.sel = i;
            }
            im.ImGui_EndListBox();
        }
        const bx = im.ImGui_GetCursorPosX() + 392 * s;
        const has = f.sel < f.items.items.len;
        im.ImGui_SetCursorPos(.{ .x = bx, .y = top });
        if (sideButton(S.tr().moveUp, "favorites_up", 104) and has and f.sel > 0) {
            std.mem.swap(settings.Favorite, &f.items.items[f.sel], &f.items.items[f.sel - 1]);
            f.sel -= 1;
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().moveDown, "favorites_down", 104) and has and f.sel + 1 < f.items.items.len) {
            std.mem.swap(settings.Favorite, &f.items.items[f.sel], &f.items.items[f.sel + 1]);
            f.sel += 1;
        }
        im.ImGui_SetCursorPosX(bx);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().renameButton, "favorites_rename", 104) and has) {
            f.renaming = true;
            P.askName(d, D.noDots(S.tr().renameButton), S.tr().favoritePrompt, .line, f.items.items[f.sel].Name, false, false, &f.reply);
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().remove, "favorites_remove", 104) and has) {
            _ = f.items.orderedRemove(f.sel);
            if (f.sel > 0 and f.sel >= f.items.items.len) f.sel -= 1;
        }
        // OK + Cancel end level with the list's bottom edge.
        im.ImGui_SetCursorPos(.{ .x = bx, .y = top + 276 * s - 2 * im.ImGui_GetFrameHeight() - im.ImGui_GetStyle().*.ItemSpacing.y });
        if (sideButton(S.tr().ok, "favorites_ok", 104) or (D.enterPressed() and !f.renaming)) {
            const a = settings.arena();
            const list = a.alloc(settings.Favorite, f.items.items.len) catch return false;
            for (f.items.items, 0..) |x, i| list[i] = .{
                .Name = a.dupe(u8, x.Name) catch x.Name,
                .Path = a.dupe(u8, x.Path) catch x.Path,
                .Inner = if (x.Inner) |in| a.dupe(u8, in) catch in else null,
            };
            settings.current().Favorites = list;
            settings.commit();
            d.ctx.post(.settings_changed);
            return false;
        }
        im.ImGui_SetCursorPosX(bx);
        if (sideButton(S.tr().cancel, "favorites_cancel", 104) or D.escPressed()) return false;
        return true;
    }

    pub fn close(f: *Favorites, _: *Dialogs) bool {
        return !f.renaming;
    }

    pub fn deinit(f: *Favorites, d: *Dialogs) void {
        _ = d;
        f.reply.reset(f.gpa);
        f.items.deinit(f.gpa);
        f.arena.deinit();
        f.gpa.destroy(f);
    }
};

pub fn openFavorites(d: *Dialogs) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Favorites) catch return;
    f.* = .{ .gpa = gpa, .arena = .init(gpa) };
    for (settings.current().Favorites) |x| f.items.append(gpa, x) catch {};
    D.push(d, Favorites, f, true);
}
