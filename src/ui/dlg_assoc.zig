//! MP-G2: AssocForm - checkbox per extension (owner + "app removed" / "user choice" markers), All / Default /
//! None, the Explorer menu items, the "Add to" format. Registry only under ctx.hive (tests inject a root).
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");

const S = C.S;
const engine = C.engine;
const assoc = C.assoc;
const settings = C.settings;
const im = kit.im;
const Dialogs = D.Dialogs;
const Allocator = std.mem.Allocator;

const Row = struct {
    ext: []const u8,
    owner: []const u8,
    checked: bool,
    /// What "Default" ticks: a default type, already ours, or nobody usable owns it.
    default: bool,
};

const menu_items = [_]struct { field: []const u8, text: S.Str, col: u1 }{
    .{ .field = "open", .text = S.verbOpenWith, .col = 0 },
    .{ .field = "extract_here", .text = S.verbExtractHere, .col = 0 },
    .{ .field = "extract_to", .text = S.verbExtractTo, .col = 0 },
    .{ .field = "add", .text = S.verbAddTo, .col = 1 },
    .{ .field = "quick_add", .text = S.menuQuickAdd, .col = 1 },
    .{ .field = "new", .text = S.menuNewArchive, .col = 1 },
    .{ .field = "profiles", .text = S.menuProfiles, .col = 1 },
};

pub const Assoc = struct {
    pub const win_id = "assoc";
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    rows: []Row = &.{},
    menu: [menu_items.len]bool = @splat(false),
    quick_names: [engine.kinds.len][]const u8 = undefined,
    quick_kinds: [engine.kinds.len]engine.ArchiveKind = undefined,
    quick_n: usize = 0,
    quick: usize = 0,
    /// Everything but the table, measured last frame (logical px * scale): the table shrinks so it all fits.
    rest_h: f32 = 0,

    pub fn title(_: *Assoc, _: []u8) []const u8 {
        return S.assocTitle.get();
    }

    pub fn body(f: *Assoc, d: *Dialogs) bool {
        const s = D.scale();
        if (D.button(S.selectAll.get(), "assoc_all")) for (f.rows) |*r| {
            r.checked = true;
        };
        im.ImGui_SameLine();
        if (D.button(S.selectDefaults.get(), "assoc_defaults")) for (f.rows) |*r| {
            r.checked = r.default;
        };
        im.ImGui_SameLine();
        if (D.button(S.selectNone.get(), "assoc_none")) for (f.rows) |*r| {
            r.checked = false;
        };

        // The table gives up height so the dialog fits the main window (900x600 by default): the footer stays put.
        var table_h = 330 * s;
        if (d.ctx.has_main_window and f.rest_h > 0)
            table_h = std.math.clamp(im.ImGui_GetMainViewport().*.WorkSize.y * 0.94 - f.rest_h, 96 * s, table_h);
        const flags = im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg | im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_SizingFixedFit;
        if (im.ImGui_BeginTableEx("##assoc_table", 2, flags, .{ .x = 500 * s, .y = table_h }, 0)) {
            im.ImGui_TableSetupScrollFreeze(0, 1);
            im.ImGui_TableSetupColumnEx(S.extension.get(), im.ImGuiTableColumnFlags_WidthFixed, 140 * s, 0);
            im.ImGui_TableSetupColumnEx(S.currentApp.get(), im.ImGuiTableColumnFlags_WidthStretch, 0, 0);
            im.ImGui_TableHeadersRow();
            for (f.rows) |*r| {
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                var lb: [64]u8 = undefined;
                const l = std.mem.printSentinel(&lb, ".{s}##assoc_{s}", .{ r.ext, r.ext }, 0) catch continue;
                _ = kit.ui.checkbox(l.ptr, &r.checked);
                _ = im.ImGui_TableNextColumn();
                var ib: [64]u8 = undefined;
                kit.ui.text(std.mem.print(&ib, "assoc_owner_{s}", .{r.ext}) catch "assoc_owner", r.owner, null, 0);
            }
            im.ImGui_EndTable();
        }

        // Which Explorer menu items exist at all (classic menu and the Windows 11 one).
        im.ImGui_TextUnformatted(S.menuItemsLabel.get());
        // two columns: left = the archive's own verbs (0..2), right = the items on every file (3..6)
        for (0..4) |r| {
            const x0 = im.ImGui_GetCursorPosX();
            if (r < 3) f.menuBox(r) else im.ImGui_Dummy(.{ .x = 0, .y = im.ImGui_GetFrameHeight() });
            im.ImGui_SameLineEx(x0 + 252 * s, -1);
            f.menuBox(r + 3);
        }

        D.caption(S.quickFormat.get(), 252);
        _ = D.combo("assoc_quick", f.quick_names[0..f.quick_n], &f.quick, 120);

        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, im.ImGui_GetStyle().*.Colors[im.ImGuiCol_TextDisabled]);
        kit.ui.text("assoc_note", S.assocNote.get(), null, 500 * s);
        im.ImGui_PopStyleColor();

        D.alignRight(&.{ S.ok.get(), S.cancel.get() });
        const ok = D.primary(true, S.ok.get(), "assoc_ok") or D.enterPressed();
        im.ImGui_SameLine();
        const cancel = D.button(S.cancel.get(), "assoc_cancel") or D.escPressed();
        f.rest_h = im.ImGui_GetCursorPosY() + im.ImGui_GetStyle().*.WindowPadding.y - table_h;
        if (ok) f.apply(d);
        return !ok and !cancel;
    }

    fn menuBox(f: *Assoc, i: usize) void {
        var ib: [48]u8 = undefined;
        const id = std.mem.print(&ib, "assoc_menu_{s}", .{menu_items[i].field}) catch "assoc_menu";
        _ = D.checkbox(menu_items[i].text.get(), id, &f.menu[i]);
    }

    fn apply(f: *Assoc, d: *Dialogs) void {
        const h = d.ctx.hive;
        var blocked: std.ArrayList(u8) = .empty;
        defer blocked.deinit(f.gpa);
        // Ticking a box that is already ours writes nothing, so a ProgID that went missing under us would stay
        // missing: put it back first.
        for (f.rows) |r| if (r.checked) {
            assoc.heal(h) catch {};
            break;
        };
        for (f.rows) |r| {
            if (r.checked) {
                if (!assoc.isOurs(h, r.ext)) {
                    const got = assoc.register(h, r.ext, true) catch continue;
                    if (got.blocked) {
                        if (blocked.items.len > 0) blocked.appendSlice(f.gpa, ", ") catch {};
                        blocked.append(f.gpa, '.') catch {};
                        blocked.appendSlice(f.gpa, r.ext) catch {};
                    }
                }
            } else if (assoc.isOurs(h, r.ext)) assoc.unregister(h, r.ext) catch {};
        }
        var m: assoc.MenuItems = .none;
        inline for (menu_items, 0..) |mi, i| @field(m, mi.field) = f.menu[i];
        assoc.setMenu(h, m) catch {};
        if (f.quick < f.quick_n) assoc.setQuickKind(h, f.quick_kinds[f.quick]) catch {};
        assoc.applyMenu(h, settings.current().Profiles) catch {};
        if (h.prefix.len == 0) assoc.notify(); // a test root (MAKEPACK_REGROOT) is no news for Explorer
        if (blocked.items.len > 0) {
            var buf: [1024]u8 = undefined;
            P.message(d, .info, S.app, S.fillZ(&buf, S.blockedFmt.get(), .{blocked.items}), .ok, false, null);
        }
    }

    pub fn close(_: *Assoc, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(f: *Assoc, d: *Dialogs) void {
        _ = d;
        f.arena.deinit();
        f.gpa.destroy(f);
    }
};

pub fn open(d: *Dialogs) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Assoc) catch return;
    f.* = .{ .gpa = gpa, .arena = .init(gpa) };
    const a = f.arena.allocator();
    const h = d.ctx.hive;
    const rows = a.alloc(Row, assoc.all.len) catch return gpa.destroy(f);
    for (assoc.all, 0..) |ext, i| {
        const o = assoc.owner(a, h, ext) catch assoc.Owner{ .prog_id = null, .dead = false, .user_choice = false, .choice_dead = false };
        const ours = if (o.prog_id) |p| std.mem.eql(u8, p, assoc.prog_id) else false;
        var text: []const u8 = if (ours) S.app else (o.prog_id orelse "");
        if (o.dead) text = std.mem.concat(a, u8, &.{ text, S.deadSuffix.get() }) catch text;
        if (o.user_choice) text = std.mem.concat(a, u8, &.{ text, S.userChoiceSuffix.get() }) catch text;
        var is_default = ours or o.dead or (o.prog_id == null or o.prog_id.?.len == 0);
        for (assoc.defaults) |x| if (std.mem.eql(u8, x, ext)) {
            is_default = true;
        };
        rows[i] = .{ .ext = ext, .owner = text, .checked = ours, .default = is_default };
    }
    f.rows = rows;
    const m = assoc.menu(h);
    inline for (menu_items, 0..) |mi, i| f.menu[i] = @field(m, mi.field);
    const qk = assoc.quickKind(h);
    for (engine.kinds) |k| if (k.multi) {
        if (k.kind == qk) f.quick = f.quick_n;
        f.quick_names[f.quick_n] = k.name;
        f.quick_kinds[f.quick_n] = k.kind;
        f.quick_n += 1;
    };
    D.push(d, Assoc, f, true);
}
