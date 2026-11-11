//! MP-G2: InfoForm (Show information): Engine.Describe's rows in two columns and a Copy button.
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const shell = @import("mw_shell.zig");

const S = C.S;
const engine = C.engine;
const im = kit.im;
const Dialogs = D.Dialogs;
const Allocator = std.mem.Allocator;

pub const Info = struct {
    pub const win_id = "info";
    pub const win_size = [2]f32{ 560, 420 }; // all ~13 rows of a 7z without a scrollbar (22 px rows)
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    a: *engine.Archive,
    /// Opened by us (DoInfo on a file on disk): closed with the window.
    owned: bool,
    rows: []engine.Row = &.{},
    title_text: []const u8 = "",

    pub fn title(f: *Info, _: []u8) []const u8 {
        return f.title_text;
    }

    pub fn body(f: *Info, d: *Dialogs) bool {
        const s = D.scale();
        const foot = im.ImGui_GetFrameHeightWithSpacing() + 6 * s;
        const flags = im.ImGuiTableFlags_Borders | im.ImGuiTableFlags_RowBg | im.ImGuiTableFlags_ScrollY | im.ImGuiTableFlags_Resizable;
        if (im.ImGui_BeginTableEx("##info_table", 2, flags, .{ .x = 0, .y = -foot }, 0)) {
            im.ImGui_TableSetupScrollFreeze(0, 1);
            im.ImGui_TableSetupColumnEx(S.property.get(), im.ImGuiTableColumnFlags_WidthFixed, 160 * s, 0);
            im.ImGui_TableSetupColumnEx(S.value.get(), im.ImGuiTableColumnFlags_WidthStretch, 0, 0);
            im.ImGui_TableHeadersRow();
            for (f.rows, 0..) |r, i| {
                im.ImGui_TableNextRow();
                _ = im.ImGui_TableNextColumn();
                var kb: [600]u8 = undefined;
                _ = im.ImGui_Selectable((std.mem.printSentinel(&kb, "{s}##info_k{d}", .{ r.label[0..@min(r.label.len, 500)], i }, 0) catch continue).ptr);
                _ = im.ImGui_TableNextColumn();
                var vb: [1200]u8 = undefined;
                _ = im.ImGui_Selectable((std.mem.printSentinel(&vb, "{s}##info_v{d}", .{ r.value[0..@min(r.value.len, 1100)], i }, 0) catch continue).ptr);
                // a value the column cuts off (a long path) is whole in its tooltip
                if (im.ImGui_CalcTextSizeEx(r.value.ptr, r.value.ptr + r.value.len, false, -1).x > im.ImGui_GetItemRectSize().x) D.tooltip(r.value);
            }
            im.ImGui_EndTable();
        }
        D.alignRight(&.{ S.copyButton.get(), S.close.get() });
        if (D.button(S.copyButton.get(), "info_copy")) {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(f.gpa);
            for (f.rows, 0..) |r, i| {
                if (i > 0) text.appendSlice(f.gpa, "\r\n") catch {};
                text.print(f.gpa, "{s}: {s}", .{ r.label, r.value }) catch {};
            }
            _ = shell.setText(f.gpa, D.owner(d), text.items);
        }
        im.ImGui_SameLine();
        if (D.button(S.close.get(), "info_close") or D.escPressed()) return false;
        return true;
    }

    pub fn close(_: *Info, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(f: *Info, d: *Dialogs) void {
        _ = d;
        if (f.owned) f.a.close();
        f.arena.deinit();
        f.gpa.destroy(f);
    }
};

/// InfoForm.Show. `owned` = close `a` with the window (a file on disk); else the main window's (borrowed: modal).
pub fn open(d: *Dialogs, a: *engine.Archive, owned: bool) void {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Info) catch {
        if (owned) a.close();
        return;
    };
    f.* = .{ .gpa = gpa, .arena = .init(gpa), .a = a, .owned = owned };
    const ar = f.arena.allocator();
    // ponytail: Describe runs on the UI thread (it reads the list 7z.dll already holds; no decoding).
    f.rows = engine.describe(ar, d.ctx.io, a) catch &.{};
    f.title_text = S.fill(ar, S.infoTitleFmt.get(), .{a.display()}) catch S.app;
    D.push(d, Info, f, true);
}
