//! MP-G2: the small modal prompts - MessageBox (msg), PasswordForm (password), NameForm (name), the file-exists
//! TaskDialog (conflict) - and cliAskPassword (PasswordForm.Ask before the GUI, in its own little window).
//! A prompt answers through a `Reply` owned by whoever asked (a flow polls `reply.done`).
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");

const S = C.S;
const im = kit.im;
const w = kit.w;
const Allocator = std.mem.Allocator;
const Dialogs = D.Dialogs;

/// A prompt's answer. `button` null = cancelled (Esc, X, Cancel, the prompt torn down).
pub const Reply = struct {
    done: bool = false,
    button: ?usize = null,
    /// Password / name text (gpa-owned; take it with `takeText` or it is freed by `reset`).
    text: ?[]u8 = null,
    /// Conflict: apply to all. Name (profile): default. Name: in menu.
    flag1: bool = false,
    flag2: bool = false,

    pub fn reset(r: *Reply, gpa: Allocator) void {
        if (r.text) |t| {
            std.crypto.secureZero(u8, t);
            gpa.free(t);
        }
        r.* = .{};
    }

    pub fn takeText(r: *Reply) ?[]u8 {
        const t = r.text;
        r.text = null;
        return t;
    }
};

// ---- MessageBox ------------------------------------------------------------------------------------------

pub const Buttons = enum { ok, yes_no };

pub const Msg = struct {
    pub const win_id = "msg";
    kind: kit.ui.MsgKind,
    title_s: []u8,
    body_text: []u8,
    buttons: Buttons,
    default_no: bool,
    reply: ?*Reply,

    pub fn title(m: *Msg, _: []u8) []const u8 {
        return m.title_s;
    }

    pub fn body(m: *Msg, _: *Dialogs) bool {
        const s = D.scale();
        kit.ui.icon(kit.ui.msgIcon(m.kind), 32); // the kit messageBox's pictures
        im.ImGui_SameLineEx(0, 14 * s);
        const wrap = @min(480 * s, @max(300 * s, im.ImGui_CalcTextSizeEx(m.body_text.ptr, m.body_text.ptr + m.body_text.len, false, -1).x + 4));
        kit.ui.text("msg_text", m.body_text, null, wrap);
        im.ImGui_Dummy(.{ .x = 0, .y = 6 * s });

        var yb: [64]u8 = undefined;
        var nb: [64]u8 = undefined;
        const yes = capFirst(&yb, S.tr().yes);
        const no = capFirst(&nb, S.tr().no);
        var answer: ?usize = null;
        switch (m.buttons) {
            .ok => {
                D.alignRight(&.{S.tr().ok});
                if (D.primary(true, S.tr().ok, "msg_ok")) answer = 0;
                if (im.ImGui_IsWindowAppearing()) im.ImGui_SetItemDefaultFocus();
                if (D.enterPressed() or D.escPressed()) answer = 0;
            },
            .yes_no => {
                D.alignRight(&.{ yes, no });
                // a destructive confirm (.danger): Yes is red, No stays plain (one filled button per box)
                const danger = m.kind == .danger;
                if (if (danger) D.danger(yes, "msg_yes") else if (m.default_no) D.button(yes, "msg_yes") else D.primary(true, yes, "msg_yes")) answer = 0;
                if (!m.default_no and im.ImGui_IsWindowAppearing()) im.ImGui_SetItemDefaultFocus();
                im.ImGui_SameLine();
                if (if (m.default_no and !danger) D.primary(true, no, "msg_no") else D.button(no, "msg_no")) answer = 1;
                if (m.default_no and im.ImGui_IsWindowAppearing()) im.ImGui_SetItemDefaultFocus();
                if (D.escPressed()) answer = 1;
            },
        }
        if (answer) |a| {
            if (m.reply) |r| r.* = .{ .done = true, .button = if (m.buttons == .yes_no and a == 1) null else a };
            m.reply = null;
            return false;
        }
        return true;
    }

    pub fn close(m: *Msg, _: *Dialogs) bool {
        _ = m;
        return true;
    }

    pub fn deinit(m: *Msg, d: *Dialogs) void {
        if (m.reply) |r| r.* = .{ .done = true };
        d.ctx.gpa.free(m.title_s);
        d.ctx.gpa.free(m.body_text);
        d.ctx.gpa.destroy(m);
    }
};

/// A message box. yes_no: reply.button 0 = Yes, null = No (or closed). Without a reply nobody waits.
pub fn message(d: *Dialogs, kind: kit.ui.MsgKind, title: []const u8, body_text: []const u8, buttons: Buttons, default_no: bool, reply: ?*Reply) void {
    const gpa = d.ctx.gpa;
    if (reply) |r| r.reset(gpa);
    const m = gpa.create(Msg) catch return fallback(reply);
    const t = gpa.dupe(u8, title) catch return {
        gpa.destroy(m);
        fallback(reply);
    };
    const b = gpa.dupe(u8, body_text) catch return {
        gpa.free(t);
        gpa.destroy(m);
        fallback(reply);
    };
    m.* = .{ .kind = kind, .title_s = t, .body_text = b, .buttons = buttons, .default_no = default_no, .reply = reply };
    D.push(d, Msg, m, true);
}

fn fallback(reply: ?*Reply) void {
    if (reply) |r| r.* = .{ .done = true };
}

/// "так" -> "Так" (S.yes/S.no are the lower-case words of the Info rows; MessageBox buttons start upper-case).
fn capFirst(buf: []u8, s: []const u8) []const u8 {
    var wb: [64]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wb, s[0..@min(s.len, 60)]) catch return s;
    if (n > 0) _ = w.CharUpperBuffW(&wb, 1);
    const m = std.unicode.wtf16LeToWtf8(buf, wb[0..n]);
    return buf[0..m];
}

// ---- PasswordForm --------------------------------------------------------------------------------------

pub const Password = struct {
    pub const win_id = "password";
    title_s: []u8,
    prompt: []u8,
    box: [256:0]u8 = @splat(0),
    reply: ?*Reply,
    focus: bool = true,

    pub fn title(p: *Password, _: []u8) []const u8 {
        return p.title_s;
    }

    pub fn body(p: *Password, d: *Dialogs) bool {
        const s = D.scale();
        kit.ui.text("password_prompt", p.prompt, null, 336 * s);
        if (p.focus) {
            im.ImGui_SetKeyboardFocusHere();
            p.focus = false;
        }
        const entered = D.input("password_input", &p.box, 336, im.ImGuiInputTextFlags_Password | im.ImGuiInputTextFlags_EnterReturnsTrue);
        D.alignRight(&.{ S.tr().ok, S.tr().cancel });
        var ok = D.primary(true, S.tr().ok, "password_ok") or entered;
        im.ImGui_SameLine();
        const cancel = D.button(S.tr().cancel, "password_cancel") or D.escPressed();
        if (!entered and D.enterPressed()) ok = true;
        if (cancel) return false; // deinit answers "cancelled"
        if (ok) {
            if (p.reply) |r| r.* = .{ .done = true, .button = 0, .text = d.ctx.gpa.dupe(u8, D.bufText(&p.box)) catch null };
            p.reply = null;
            return false;
        }
        return true;
    }

    pub fn close(_: *Password, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(p: *Password, d: *Dialogs) void {
        if (p.reply) |r| r.* = .{ .done = true };
        std.crypto.secureZero(u8, &p.box);
        d.ctx.gpa.free(p.title_s);
        d.ctx.gpa.free(p.prompt);
        d.ctx.gpa.destroy(p);
    }
};

/// PasswordForm.Ask: reply.text = the password (button 0), or cancelled.
pub fn askPassword(d: *Dialogs, title: []const u8, prompt: ?[]const u8, reply: *Reply) void {
    const gpa = d.ctx.gpa;
    reply.reset(gpa);
    const p = gpa.create(Password) catch return fallback(reply);
    const t = gpa.dupe(u8, title) catch return {
        gpa.destroy(p);
        fallback(reply);
    };
    const q = gpa.dupe(u8, prompt orelse S.tr().enterPassword) catch return {
        gpa.free(t);
        gpa.destroy(p);
        fallback(reply);
    };
    p.* = .{ .title_s = t, .prompt = q, .reply = reply };
    D.push(d, Password, p, true);
}

// ---- NameForm ------------------------------------------------------------------------------------------

pub const NameMode = enum {
    /// NameForm.Line: any one line under the given prompt.
    line,
    /// NameForm.Ask(isDefault: null): a profile name (renaming).
    profile,
    /// NameForm.Ask(isDefault: bool): a profile name + "default" + "in menu".
    profile_full,
};

pub const Name = struct {
    pub const win_id = "name";
    title_s: []u8,
    prompt: []u8,
    mode: NameMode,
    box: [512:0]u8 = @splat(0),
    is_default: bool = false,
    in_menu: bool = false,
    reply: ?*Reply,
    focus: bool = true,

    pub fn title(n: *Name, _: []u8) []const u8 {
        return n.title_s;
    }

    fn valid(n: *const Name) bool {
        const t = std.mem.trim(u8, D.bufText(&n.box), " \t");
        // A quote would end a profile name early in the menu's command line (a --profile "name").
        return t.len > 0 and (n.mode == .line or std.mem.findScalar(u8, t, '"') == null);
    }

    pub fn body(n: *Name, d: *Dialogs) bool {
        kit.ui.text("name_prompt", n.prompt, null, 356 * D.scale());
        if (n.focus) {
            im.ImGui_SetKeyboardFocusHere();
            n.focus = false;
        }
        const entered = D.input("name_input", &n.box, 356, im.ImGuiInputTextFlags_EnterReturnsTrue);
        if (n.mode == .profile_full) {
            _ = D.checkbox(S.tr().defaultProfile, "name_default", &n.is_default);
            _ = D.checkbox(S.tr().profileInMenu, "name_menu", &n.in_menu);
        }
        D.alignRight(&.{ S.tr().ok, S.tr().cancel });
        const ok_on = n.valid();
        var ok = D.primary(ok_on, S.tr().ok, "name_ok");
        im.ImGui_SameLine();
        if (D.button(S.tr().cancel, "name_cancel") or D.escPressed()) return false;
        if ((entered or D.enterPressed()) and ok_on) ok = true;
        if (ok) {
            const t = d.ctx.gpa.dupe(u8, std.mem.trim(u8, D.bufText(&n.box), " \t")) catch null;
            if (n.reply) |r| r.* = .{ .done = true, .button = 0, .text = t, .flag1 = n.is_default, .flag2 = n.in_menu };
            n.reply = null;
            return false;
        }
        return true;
    }

    pub fn close(_: *Name, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(n: *Name, d: *Dialogs) void {
        if (n.reply) |r| r.* = .{ .done = true };
        d.ctx.gpa.free(n.title_s);
        d.ctx.gpa.free(n.prompt);
        d.ctx.gpa.destroy(n);
    }
};

/// NameForm: reply.text = the trimmed name (button 0), flag1 = default, flag2 = in menu.
pub fn askName(d: *Dialogs, title: []const u8, prompt: ?[]const u8, mode: NameMode, text: []const u8, is_default: bool, in_menu: bool, reply: *Reply) void {
    const gpa = d.ctx.gpa;
    reply.reset(gpa);
    const n = gpa.create(Name) catch return fallback(reply);
    const t = gpa.dupe(u8, title) catch return {
        gpa.destroy(n);
        fallback(reply);
    };
    const q = gpa.dupe(u8, prompt orelse S.tr().profileName) catch return {
        gpa.free(t);
        gpa.destroy(n);
        fallback(reply);
    };
    n.* = .{ .title_s = t, .prompt = q, .mode = mode, .reply = reply, .is_default = is_default, .in_menu = in_menu };
    D.setText(&n.box, text);
    D.push(d, Name, n, true);
}

// ---- the file-exists TaskDialog (ExtractForm.Conflicts) ---------------------------------------------------

pub const Conflict = struct {
    pub const win_id = "conflict";
    path: []u8,
    append: bool,
    all: bool = false,
    reply: ?*Reply,

    pub fn title(_: *Conflict, _: []u8) []const u8 {
        return S.app;
    }

    pub fn body(c: *Conflict, d: *Dialogs) bool {
        _ = d;
        const s = D.scale();
        im.ImGui_PushFontFloat(d_bold(), im.ImGui_GetStyle().*.FontSizeBase * 1.15);
        im.ImGui_TextUnformatted(S.tr().fileExists);
        im.ImGui_PopFont();
        kit.ui.text("conflict_path", c.path, null, 460 * s);
        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        _ = D.checkbox(S.tr().applyToAll, "conflict_all", &c.all);
        var answer: ?usize = null;
        if (D.button(if (c.append) S.tr().replace else S.tr().overwrite, "conflict_overwrite")) answer = 0;
        if (im.ImGui_IsWindowAppearing()) im.ImGui_SetItemDefaultFocus();
        im.ImGui_SameLine();
        if (D.button(S.tr().skip, "conflict_skip")) answer = 1;
        if (!c.append) {
            im.ImGui_SameLine();
            if (D.button(S.tr().rename, "conflict_rename")) answer = 2;
        }
        im.ImGui_SameLine();
        if (D.button(S.tr().cancel, "conflict_cancel") or D.escPressed()) return false;
        if (answer) |a| {
            if (c.reply) |r| r.* = .{ .done = true, .button = a, .flag1 = c.all };
            c.reply = null;
            return false;
        }
        return true;
    }

    fn d_bold() [*c]im.ImFont {
        return if (kit.app.current()) |a| a.fonts.bold else null;
    }

    pub fn close(_: *Conflict, _: *Dialogs) bool {
        return true;
    }

    pub fn deinit(c: *Conflict, d: *Dialogs) void {
        if (c.reply) |r| r.* = .{ .done = true };
        d.ctx.gpa.free(c.path);
        d.ctx.gpa.destroy(c);
    }
};

/// reply.button: 0 Overwrite/Replace, 1 Skip, 2 Rename, null = cancel; flag1 = apply to all.
pub fn askConflict(d: *Dialogs, path: []const u8, append: bool, reply: *Reply) void {
    const gpa = d.ctx.gpa;
    reply.reset(gpa);
    const c = gpa.create(Conflict) catch return fallback(reply);
    c.* = .{ .path = gpa.dupe(u8, path) catch {
        gpa.destroy(c);
        return fallback(reply);
    }, .append = append, .reply = reply };
    D.push(d, Conflict, c, true);
}

// ---- cli -p: PasswordForm.Ask with no GUI running yet ----------------------------------------------------

const CliAsk = struct {
    title: []const u8,
    prompt: []const u8,
    box: [256:0]u8 = @splat(0),
    answer: ?bool = null,
    focus: bool = true,
};

/// Its own kit.app window (title = the archive name), blocks until OK / Cancel / close. null = cancelled.
pub fn cliAskPassword(gpa: Allocator, title: []const u8, label: ?[]const u8) ?[]u8 {
    if (kit.app.current() != null) return null; // never inside the GUI (the GUI has its own prompt)
    var st: CliAsk = .{ .title = title, .prompt = label orelse S.tr().enterPassword };
    const app = kit.app.App.init(gpa, .{
        .title = title,
        .size = .{ 380, 150 },
        .min_size = .{ 300, 120 },
        .palette = kit.app.palettes.carbon,
        .icon_id = 1,
    }) catch return null;
    app.run(.{ .user = &st, .frame = cliFrame });
    app.deinit();
    defer std.crypto.secureZero(u8, &st.box);
    if (st.answer != true) return null;
    return gpa.dupe(u8, D.bufText(&st.box)) catch null;
}

fn cliFrame(app: *kit.app.App) void {
    const st = app.userData(CliAsk);
    const vp = im.ImGui_GetMainViewport();
    im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
    im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
    _ = im.ImGui_Begin("##cli_password", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoSavedSettings);
    defer im.ImGui_End();
    kit.ui.text("password_prompt", st.prompt, null, im.ImGui_GetContentRegionAvail().x);
    if (st.focus) {
        im.ImGui_SetKeyboardFocusHere();
        st.focus = false;
    }
    im.ImGui_SetNextItemWidth(-1);
    const entered = im.ImGui_InputText("##password_input", &st.box, st.box.len, im.ImGuiInputTextFlags_Password | im.ImGuiInputTextFlags_EnterReturnsTrue);
    D.alignRight(&.{ S.tr().ok, S.tr().cancel });
    if (D.primary(true, S.tr().ok, "password_ok") or entered) st.answer = true;
    im.ImGui_SameLine();
    if (D.button(S.tr().cancel, "password_cancel") or im.ImGui_IsKeyPressed(im.ImGuiKey_Escape)) st.answer = false;
    if (st.answer != null) app.quit();
}
