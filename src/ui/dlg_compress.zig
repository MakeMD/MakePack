//! MP-G2: CompressForm (New archive / "a" from Explorer) and Program.RunProfile (a --quick / a --profile).
const std = @import("std");
const kit = @import("kit");
const D = @import("dialogs.zig");
const C = @import("ctx.zig");
const P = @import("dlg_prompt.zig");
const R = @import("dlg_run.zig");
const types = @import("../core/types.zig");

const S = C.S;
const engine = C.engine;
const settings = C.settings;
const im = kit.im;
const Dialogs = D.Dialogs;
const Reply = P.Reply;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;
const Kind = engine.ArchiveKind;
const Method = engine.CompressionMethod;

const level_map = [_]engine.CompressionLevel{ .None, .Fast, .Low, .Normal, .High, .Ultra };
const min_volume: i64 = 64 << 10;
/// Binary units like 7-Zip's -v: FAT32 tops out at 4 GiB - 1, a DVD+R holds 4482 MiB.
const volume_presets = [_][]const u8{ "100 MB", "700 MB (CD)", "4095 MB (FAT32)", "4482 MB (DVD)", "8152 MB (DVD DL)" };
const dictionaries = [_]i64{ 0, 1 << 20, 4 << 20, 16 << 20, 32 << 20, 64 << 20, 128 << 20, 256 << 20, 512 << 20, 1 << 30, 1536 << 20 };
const solids = [_]?[]const u8{ null, "off", "16m", "64m", "256m", "1g", "4g", "16g" };
const filters = [_]struct { text: ?[]const u8, value: ?[]const u8 }{
    .{ .text = null, .value = null },
    .{ .text = null, .value = "off" },
    .{ .text = "x86 (BCJ2)", .value = "BCJ2" },
    .{ .text = "ARM64", .value = "ARM64" },
};

fn methodName(m: Method) []const u8 {
    return switch (m) {
        .Lzma2 => "LZMA2",
        .Lzma => "LZMA",
        .Ppmd => "PPMd",
        .BZip2 => "BZip2",
        .Deflate => "Deflate",
        .Deflate64 => "Deflate64",
        else => "?",
    };
}

fn levelIndex(l: engine.CompressionLevel) usize {
    return std.mem.findScalar(engine.CompressionLevel, &level_map, l) orelse 0;
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn cpuCount() usize {
    const n = kit.w.GetActiveProcessorCount(@intCast(kit.w.ALL_PROCESSOR_GROUPS));
    return @max(1, @min(n, 256));
}

/// CompressForm.ConfirmOverwrite's question (null = nothing would be overwritten). `volume` > 0: name.001 lands.
pub fn overwriteQuestion(gpa: Allocator, archives: []const []const u8, volume: i64) ?[]u8 {
    var existing: std.ArrayList([]const u8) = .empty;
    defer existing.deinit(gpa);
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| gpa.free(p);
        parts.deinit(gpa);
    }
    for (archives) |a| {
        const p = if (volume > 0) (engine.part(gpa, a, 1) catch continue) else (gpa.dupe(u8, a) catch continue);
        parts.append(gpa, p) catch {
            gpa.free(p);
            continue;
        };
        if (engine.fileExists(p)) existing.append(gpa, p) catch {};
    }
    if (existing.items.len == 0) return null;
    if (existing.items.len == 1) return S.fill(gpa, S.overwriteArchiveFmt.get(), .{fspath.basename(existing.items[0])}) catch null;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    for (existing.items[0..@min(5, existing.items.len)], 0..) |p, i| {
        if (i > 0) names.append(gpa, '\n') catch {};
        names.appendSlice(gpa, fspath.basename(p)) catch {};
    }
    return S.fill(gpa, S.overwriteManyFmt.get(), .{ existing.items.len, names.items }) catch null;
}

pub const Compress = struct {
    pub const win_id = "compress";
    gpa: Allocator,
    /// Item texts for the combos (methods, dictionaries, threads...) and the profile list.
    strs: std.heap.ArenaAllocator,
    inputs: std.ArrayList([]u8) = .empty,
    sel: std.ArrayList(bool) = .empty,
    out: [2048:0]u8 = @splat(0),
    auto_out: bool = true,
    separate: bool = false,
    kinds: [engine.kinds.len]engine.KindInfo = undefined,
    kinds_n: usize = 0,
    format: usize = 0,
    level: usize = 3,
    password: [256:0]u8 = @splat(0),
    confirm_box: [256:0]u8 = @splat(0),
    encrypt_names: bool = false,
    zip_crypto: bool = false,
    show_password: bool = false,
    volumes: [128:0]u8 = @splat(0),
    sfx: bool = false,
    test_after: bool = false,
    delete_sources: bool = false,
    methods: []const Method = &.{},
    method: usize = 0,
    dict: usize = 0,
    solid: usize = 0,
    threads: usize = 0,
    threads_n: usize = 1,
    filter: usize = 0,
    method_names: [8][]const u8 = undefined,
    dict_names: [dictionaries.len][]const u8 = undefined,
    solid_names: [solids.len][]const u8 = undefined,
    thread_names: [][]const u8 = &.{},
    filter_names: [filters.len][]const u8 = undefined,
    profile_names: [][]const u8 = &.{},
    profile: usize = 0,
    /// The main window's New archive: open the single archive made. Modal = from the main window.
    open_created: bool,
    modal: bool,
    state: enum { idle, save_name, save_replace, confirm, running } = .idle,
    reply: Reply = .{},
    save_name: []u8 = &.{},
    save_default: bool = false,
    save_menu: bool = false,
    run: R.Run = .{},
    job_arena: std.heap.ArenaAllocator,
    job_inputs: []const []const u8 = &.{},
    job_out: []const u8 = "",
    job_plan: ?[]engine.Planned = null,
    job_kind: Kind = .SevenZip,
    job_opts: engine.CompressOptions = .{},
    created: ?[]u8 = null,
    done: bool = false,

    pub fn title(_: *Compress, _: []u8) []const u8 {
        return D.noDots(S.newArchive.get());
    }

    fn currentKind(f: *const Compress) Kind {
        return if (f.format < f.kinds_n) f.kinds[f.format].kind else .SevenZip;
    }

    fn info(f: *const Compress) engine.KindInfo {
        return engine.kind(f.currentKind());
    }

    fn sfxOn(f: *const Compress) bool {
        return f.currentKind() == .SevenZip and f.sfx;
    }

    fn ext(f: *const Compress) []const u8 {
        return if (f.sfxOn()) ".exe" else f.info().ext;
    }

    fn volumesOn(f: *const Compress) bool {
        return !f.sfxOn();
    }

    /// Bytes per volume, 0 = no split, null = not a size we take.
    fn volumeSize(f: *const Compress) ?i64 {
        if (!f.volumesOn()) return 0;
        const v = engine.parseSize(D.bufText(&f.volumes)) orelse return null;
        return if (v == 0 or v >= min_volume) v else null;
    }

    fn passwordOn(f: *const Compress) bool {
        return f.info().password;
    }

    fn confirmOn(f: *const Compress) bool {
        return f.passwordOn() and !f.show_password;
    }

    fn advOn(f: *const Compress) bool {
        return f.methods.len > 0 and level_map[f.level] != .None;
    }

    fn methodValue(f: *const Compress) Method {
        return if (f.method < f.methods.len) f.methods[f.method] else .Default;
    }

    fn dictOn(f: *const Compress) bool {
        return f.advOn() and engine.hasDictionary(f.info().format, f.methodValue());
    }

    fn solidOn(f: *const Compress) bool {
        return f.advOn() and f.currentKind() == .SevenZip;
    }

    // ---- C# events ----

    pub fn addInputs(f: *Compress, d: *Dialogs, paths: []const []const u8) void {
        for (paths) |p| {
            const t = std.mem.trim(u8, std.mem.trim(u8, p, " \t"), "\"");
            if (t.len == 0) continue;
            const full = engine.fullPath(f.gpa, t) catch continue;
            var dup = false;
            for (f.inputs.items) |x| if (std.mem.eql(u8, x, full)) {
                dup = true;
            };
            if (dup or !(engine.fileExists(full) or engine.dirExists(full))) {
                f.gpa.free(full);
                continue;
            }
            f.inputs.append(f.gpa, full) catch {
                f.gpa.free(full);
                continue;
            };
            f.sel.append(f.gpa, false) catch {};
        }
        f.inputsChanged(d);
    }

    fn inputsChanged(f: *Compress, d: *Dialogs) void {
        f.refreshFormats(d);
        f.updateOut(d);
    }

    /// Single-file formats only make sense for exactly one file input, so they are listed only then.
    fn refreshFormats(f: *Compress, d: *Dialogs) void {
        const single = f.inputs.items.len == 1 and engine.fileExists(f.inputs.items[0]);
        var wanted: [engine.kinds.len]engine.KindInfo = undefined;
        var n: usize = 0;
        for (engine.kinds) |k| if (k.multi or single) {
            wanted[n] = k;
            n += 1;
        };
        if (n == f.kinds_n) return;
        const keep = if (f.kinds_n > 0) f.currentKind() else settings.current().Format;
        f.kinds = wanted;
        f.kinds_n = n;
        f.format = 0;
        for (wanted[0..n], 0..) |k, i| if (k.kind == keep) {
            f.format = i;
        };
        f.formatChanged(d);
    }

    fn formatChanged(f: *Compress, d: *Dialogs) void {
        if (!f.passwordOn()) {
            @memset(&f.password, 0);
            @memset(&f.confirm_box, 0);
        }
        if (f.currentKind() != .SevenZip) {
            f.encrypt_names = false;
            f.sfx = false;
        }
        if (f.currentKind() != .Zip) f.zip_crypto = false;
        f.refreshAdvanced();
        f.updateOut(d);
    }

    /// Only what the format and method can take stays enabled; doCreate reads enabled boxes only.
    fn refreshAdvanced(f: *Compress) void {
        const methods = engine.methodsFor(f.currentKind());
        if (!std.mem.eql(Method, methods, f.methods)) {
            const current = if (f.method < f.methods.len) f.methods[f.method] else settings.current().Method;
            f.methods = methods;
            f.method = std.mem.findScalar(Method, methods, current) orelse 0;
            for (methods, 0..) |m, i| f.method_names[i] = methodName(m);
        }
    }

    fn updateOut(f: *Compress, d: *Dialogs) void {
        const e = f.ext();
        if (f.auto_out) {
            const p = engine.defaultArchivePath(f.gpa, d.ctx.io, @ptrCast(f.inputs.items), e, settings.current().ArchiveFolder) catch return;
            defer f.gpa.free(p);
            D.setText(&f.out, p);
        } else {
            const cur = D.bufText(&f.out);
            if (cur.len == 0) return;
            const dir = fspath.dirname(cur) orelse "";
            var buf: [2100]u8 = undefined;
            const sep: []const u8 = if (dir.len == 0 or fspath.isSep(dir[dir.len - 1])) "" else "\\";
            const p = std.mem.print(&buf, "{s}{s}{s}{s}", .{ dir, sep, engine.baseName(cur), e }) catch return;
            D.setText(&f.out, p);
        }
    }

    fn refreshProfiles(f: *Compress, d: *Dialogs, select: ?[]const u8) void {
        const a = f.strs.allocator();
        const profiles = settings.current().Profiles;
        const names = a.alloc([]const u8, profiles.len + 1) catch return;
        names[0] = S.noProfile.get();
        for (profiles, 0..) |p, i| names[i + 1] = if (p.IsDefault) (std.mem.concat(a, u8, &.{ p.Name, S.defaultMark.get() }) catch p.Name) else p.Name;
        f.profile_names = names;
        f.profile = 0;
        if (select) |s| for (profiles, 0..) |p, i| if (std.mem.eql(u8, p.Name, s)) {
            f.profile = i + 1;
        };
        if (f.profile > 0) f.applyProfile(d, profiles[f.profile - 1]);
    }

    fn applyProfile(f: *Compress, d: *Dialogs, p: settings.Profile) void {
        for (f.kinds[0..f.kinds_n], 0..) |k, i| if (k.kind == p.Format and i != f.format) {
            f.format = i; // a gz profile with folders in the list: the format stays what it was
            f.formatChanged(d);
        };
        f.level = levelIndex(p.Level);
        f.refreshAdvanced();
        if (std.mem.findScalar(Method, f.methods, p.Method)) |i| f.method = i;
        if (std.mem.findScalar(i64, &dictionaries, p.Dictionary)) |i| f.dict = i;
        for (solids, 0..) |v, i| if (eqlOpt(v, p.Solid)) {
            f.solid = i;
        };
        if (p.Threads >= 0 and @as(usize, @intCast(p.Threads)) < f.threads_n) f.threads = @intCast(p.Threads);
        for (filters, 0..) |v, i| if (eqlOpt(v.value, p.Filter)) {
            f.filter = i;
        };
        D.setText(&f.volumes, p.Volumes);
        f.test_after = p.TestAfter;
        f.delete_sources = p.DeleteSources;
        f.separate = p.Separate;
        const sfx_was = f.sfx;
        f.sfx = p.Sfx and f.currentKind() == .SevenZip;
        f.encrypt_names = p.EncryptNames and f.currentKind() == .SevenZip;
        f.zip_crypto = p.ZipCrypto and f.currentKind() == .Zip;
        if (sfx_was != f.sfx) f.updateOut(d);
    }

    /// The dialog as it stands, minus the password. Greyed-out boxes are saved as "default".
    fn snapshot(f: *const Compress, name: []const u8, is_default: bool) settings.Profile {
        return .{
            .Name = name,
            .IsDefault = is_default,
            .Format = f.currentKind(),
            .Level = level_map[f.level],
            .Method = if (f.advOn()) f.methodValue() else .Default,
            .Dictionary = if (f.dictOn()) dictionaries[f.dict] else 0,
            .Solid = if (f.solidOn()) solids[f.solid] else null,
            .Threads = if (f.advOn()) @intCast(f.threads) else 0,
            .Filter = if (f.solidOn()) filters[f.filter].value else null,
            .Volumes = if (f.volumesOn()) (settings.arena().dupe(u8, std.mem.trim(u8, D.bufText(&f.volumes), " ")) catch "") else "",
            .TestAfter = f.test_after,
            .DeleteSources = f.delete_sources,
            .Separate = f.separate,
            .Sfx = f.sfxOn(),
            .EncryptNames = f.currentKind() == .SevenZip and f.encrypt_names,
            .ZipCrypto = f.currentKind() == .Zip and f.zip_crypto,
        };
    }

    fn saveProfileStart(f: *Compress, d: *Dialogs) void {
        if (f.volumeSize() == null) return; // a bad volume size is flagged already; do not store it
        const cur: ?settings.Profile = if (f.profile > 0 and f.profile <= settings.current().Profiles.len) settings.current().Profiles[f.profile - 1] else null;
        f.state = .save_name;
        P.askName(d, S.saveProfileTitle.get(), null, .profile_full, if (cur) |c| c.Name else "", if (cur) |c| c.IsDefault else false, if (cur) |c| c.InMenu else false, &f.reply);
    }

    fn saveProfileCommit(f: *Compress, d: *Dialogs) void {
        const a = settings.arena();
        const name = a.dupe(u8, f.save_name) catch return;
        var profile = f.snapshot(name, f.save_default);
        profile.InMenu = f.save_menu;
        const s = settings.current();
        var list: std.ArrayList(settings.Profile) = .empty;
        for (s.Profiles) |p| {
            if (types.eqlIgnoreCase(p.Name, name)) continue;
            var q = p;
            if (profile.IsDefault) q.IsDefault = false;
            list.append(a, q) catch return;
        }
        list.append(a, profile) catch return;
        s.Profiles = list.items;
        settings.commit();
        // a menu profile's item, or a changed extension, shows in Explorer right away
        C.assoc.applyProfiles(d.ctx.hive, s.Profiles) catch {};
        f.refreshProfiles(d, name);
        d.ctx.post(.settings_changed);
    }

    fn doCreate(f: *Compress, d: *Dialogs) void {
        if (f.inputs.items.len == 0) return P.message(d, .info, S.app, S.noInputs.get(), .ok, false, null);
        const volume = f.volumeSize() orelse return; // the error text already says why
        const pw = D.bufText(&f.password);
        if (f.passwordOn() and pw.len > 0 and f.confirmOn() and !std.mem.eql(u8, D.bufText(&f.confirm_box), pw))
            return P.message(d, .warning, S.app, S.passwordsDiffer.get(), .ok, false, null);

        _ = f.job_arena.reset(.free_all);
        const a = f.job_arena.allocator();
        const inputs = a.alloc([]const u8, f.inputs.items.len) catch return;
        for (f.inputs.items, 0..) |p, i| inputs[i] = a.dupe(u8, p) catch return;
        f.job_inputs = inputs;
        f.job_kind = f.currentKind();
        f.job_out = a.dupe(u8, std.mem.trim(u8, D.bufText(&f.out), " \t")) catch return;
        f.job_plan = if (f.separate) (engine.planSeparate(a, d.ctx.io, inputs, f.ext(), settings.current().ArchiveFolder) catch return) else null;
        if (f.job_plan == null and f.job_out.len == 0) return P.message(d, .info, S.app, S.outputFile.get(), .ok, false, null);
        f.job_opts = .{
            .level = level_map[f.level],
            .password = if (f.passwordOn() and pw.len > 0) (a.dupe(u8, pw) catch return) else null,
            .encrypt_headers = f.currentKind() == .SevenZip and f.encrypt_names,
            .method = if (f.advOn()) f.methodValue() else .Default,
            .dictionary = if (f.dictOn()) dictionaries[f.dict] else 0,
            .solid = if (f.solidOn()) solids[f.solid] else null,
            .threads = if (f.advOn()) @intCast(f.threads) else 0,
            .filter = if (f.solidOn()) filters[f.filter].value else null,
            .volume_size = volume,
            .test_after = f.test_after,
            .delete_sources = f.delete_sources,
            .sfx = f.sfxOn(),
            .zip_crypto = f.currentKind() == .Zip and f.zip_crypto and pw.len > 0,
        };
        var outs: std.ArrayList([]const u8) = .empty;
        if (f.job_plan) |plan| {
            for (plan) |p| outs.append(a, p.output) catch return;
        } else outs.append(a, f.job_out) catch return;
        if (overwriteQuestion(f.gpa, outs.items, volume)) |q| {
            defer f.gpa.free(q);
            f.state = .confirm;
            return P.message(d, .warning, S.app, q, .yes_no, false, &f.reply);
        }
        f.startRun(d);
    }

    fn startRun(f: *Compress, d: *Dialogs) void {
        f.state = .running;
        f.run.start(d, S.compressing.get(), f, work, true);
    }

    fn work(r: *R.Run) anyerror!void {
        const f = r.user(Compress);
        const gpa = r.d.ctx.gpa;
        const io = r.d.ctx.io;
        if (f.job_plan) |plan| return engine.compressEach(gpa, io, plan, f.job_kind, f.job_opts, r.progress(), &r.diag);
        return engine.compress(gpa, io, f.job_inputs, f.job_out, f.job_kind, f.job_opts, r.progress(), &r.diag);
    }

    fn finished(f: *Compress, d: *Dialogs) void {
        const s = settings.current();
        const o = f.job_opts;
        s.Format = f.job_kind;
        s.Level = o.level;
        s.TestAfter = o.test_after;
        // A greyed-out box says nothing about the user's choice - keep the remembered one.
        if (f.advOn()) s.Method = o.method;
        if (f.dictOn()) s.Dictionary = o.dictionary;
        if (f.solidOn()) s.Solid = o.solid;
        if (f.advOn()) s.Threads = o.threads;
        if (f.solidOn()) s.Filter = o.filter;
        settings.commit();
        // several archives: nothing single to open
        if (f.job_plan == null and f.open_created) {
            const p = if (o.volume_size > 0) engine.part(f.gpa, f.job_out, 1) catch null else f.gpa.dupe(u8, f.job_out) catch null;
            if (p) |path| d.ctx.post(.{ .open_path = .{ .path = path } });
        }
        f.done = true;
    }

    // ---- drawing ----

    pub fn body(f: *Compress, d: *Dialogs) bool {
        switch (f.state) {
            .idle => {},
            .running => if (f.run.tick()) |o| {
                f.state = .idle;
                if (o == .ok) f.finished(d);
            },
            .confirm => if (f.reply.done) {
                const yes = f.reply.button != null;
                f.reply.reset(f.gpa);
                f.state = .idle;
                if (yes) f.startRun(d);
            },
            .save_name => if (f.reply.done) {
                f.state = .idle;
                if (f.reply.button != null) {
                    if (f.save_name.len > 0) f.gpa.free(f.save_name);
                    f.save_name = f.reply.takeText() orelse &.{};
                    f.save_default = f.reply.flag1;
                    f.save_menu = f.reply.flag2;
                    f.reply.reset(f.gpa);
                    if (settings.current().findProfile(f.save_name)) |taken| {
                        var buf: [600]u8 = undefined;
                        f.state = .save_replace;
                        P.message(d, .question, S.app, S.fillZ(&buf, S.profileExistsFmt.get(), .{taken.Name}), .yes_no, false, &f.reply);
                    } else f.saveProfileCommit(d);
                } else f.reply.reset(f.gpa);
            },
            .save_replace => if (f.reply.done) {
                const yes = f.reply.button != null;
                f.reply.reset(f.gpa);
                f.state = .idle;
                if (yes) f.saveProfileCommit(d);
            },
        }
        if (f.done) return false;
        f.drawControls(d);
        return !f.done;
    }

    fn drawControls(f: *Compress, d: *Dialogs) void {
        const s = D.scale();
        const left: f32 = 430;
        const right: f32 = 98;
        const st = settings.current();

        // Profiles (compression profiles): picking one fills every option below.
        D.caption(S.profile.get(), 74);
        if (D.combo("compress_profile", f.profile_names, &f.profile, left - 74)) {
            if (f.profile > 0 and f.profile <= st.Profiles.len) f.applyProfile(d, st.Profiles[f.profile - 1]);
        }
        im.ImGui_SameLine();
        if (D.button(S.saveProfile.get(), "compress_save_profile")) f.saveProfileStart(d);

        im.ImGui_TextUnformatted(S.inputs.get());
        const list_top = im.ImGui_GetCursorPosY();
        if (im.ImGui_BeginListBox("##compress_inputs", .{ .x = left * s, .y = 116 * s })) {
            const ctrl = im.ImGui_GetIO().*.KeyCtrl;
            for (f.inputs.items, 0..) |p, i| {
                var lb: [2100]u8 = undefined;
                const l = std.mem.printSentinel(&lb, "{s}##compress_in{d}", .{ p, i }, 0) catch continue;
                if (im.ImGui_SelectableEx(l.ptr, f.sel.items[i], 0, .{ .x = 0, .y = 0 })) {
                    if (!ctrl) @memset(f.sel.items, false);
                    f.sel.items[i] = !f.sel.items[i] or !ctrl;
                }
            }
            im.ImGui_EndListBox();
        }
        const after_list = im.ImGui_GetCursorPosY();
        const bx = im.ImGui_GetCursorPosX() + (left + 8) * s;
        im.ImGui_SetCursorPos(.{ .x = bx, .y = list_top });
        if (f.sideButton(S.addFiles.get(), "compress_add_files", right)) {
            if (kit.win.openFiles(f.gpa, D.owner(d), true, .{ .title = S.addFiles.get(), .filters = &.{.{ .name = S.allFiles.get(), .spec = "*.*" }} }) catch null) |files| {
                defer kit.win.freeList(f.gpa, files);
                f.addInputs(d, @ptrCast(files));
            }
        }
        im.ImGui_SetCursorPosX(bx);
        if (f.sideButton(S.addFolder.get(), "compress_add_folder", right)) {
            if (kit.win.pickFolder(f.gpa, D.owner(d), .{ .title = S.pickFolder.get() }) catch null) |dir| {
                defer f.gpa.free(dir);
                f.addInputs(d, &.{dir});
            }
        }
        im.ImGui_SetCursorPosX(bx);
        if (f.sideButton(S.remove.get(), "compress_remove", right)) {
            var i = f.inputs.items.len;
            while (i > 0) {
                i -= 1;
                if (!f.sel.items[i]) continue;
                f.gpa.free(f.inputs.orderedRemove(i));
                _ = f.sel.orderedRemove(i);
            }
            f.inputsChanged(d);
        }
        im.ImGui_SetCursorPosY(after_list + 6 * s);

        im.ImGui_TextUnformatted(S.outputFile.get());
        im.ImGui_SameLineEx((left - 160) * s, -1);
        // Each input gets its own archive next to it: the single Archive path above no longer applies.
        _ = D.checkbox(S.separateArchives.get(), "compress_separate", &f.separate);
        im.ImGui_BeginDisabled(f.separate);
        if (D.input("compress_out", &f.out, left, 0)) f.auto_out = false;
        im.ImGui_SameLine();
        if (f.sideButton(S.browse.get(), "compress_browse", right)) f.browseOut(d);
        im.ImGui_EndDisabled();

        // format, level, SFX
        D.caption(S.format.get(), 74);
        var knames: [engine.kinds.len][]const u8 = undefined;
        for (f.kinds[0..f.kinds_n], 0..) |k, i| knames[i] = k.name;
        if (D.combo("compress_format", knames[0..f.kinds_n], &f.format, 110)) f.formatChanged(d);
        im.ImGui_SameLineEx((74 + 128) * s, -1);
        D.caption(S.level.get(), 0);
        im.ImGui_SameLineEx((74 + 128 + 64) * s, -1);
        const levels = S.levels();
        var lnames: [6][]const u8 = undefined;
        for (levels, 0..) |l, i| lnames[i] = l;
        _ = D.combo("compress_level", &lnames, &f.level, 160);
        im.ImGui_SameLineEx((left + 8) * s, -1);
        im.ImGui_BeginDisabled(f.currentKind() != .SevenZip);
        const sfx_before = f.sfx;
        _ = D.checkbox("SFX (.exe)", "compress_sfx", &f.sfx);
        D.tooltip(S.sfxTip.get());
        im.ImGui_EndDisabled();
        if (sfx_before != f.sfx) f.updateOut(d);

        // password
        var pl: [64]u8 = undefined;
        D.caption(std.mem.print(&pl, "{s}:", .{S.password.get()}) catch "", 74);
        im.ImGui_BeginDisabled(!f.passwordOn());
        _ = D.input("compress_password", &f.password, 180, if (f.show_password) 0 else im.ImGuiInputTextFlags_Password);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx((74 + 192) * s, -1);
        if (f.currentKind() == .Zip) {
            _ = D.checkbox(S.zipCrypto.get(), "compress_zipcrypto", &f.zip_crypto);
            D.tooltip(S.zipCryptoTip.get());
        } else {
            im.ImGui_BeginDisabled(f.currentKind() != .SevenZip);
            _ = D.checkbox(S.encryptNames.get(), "compress_encrypt_names", &f.encrypt_names);
            im.ImGui_EndDisabled();
        }
        // Typed twice while it is hidden (rule): a typo in a hidden password locks the archive for good.
        D.caption(S.confirm.get(), 74);
        im.ImGui_BeginDisabled(!f.confirmOn());
        _ = D.input("compress_confirm", &f.confirm_box, 180, im.ImGuiInputTextFlags_Password);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx((74 + 192) * s, -1);
        im.ImGui_BeginDisabled(!f.passwordOn());
        _ = D.checkbox(S.showPassword.get(), "compress_show_password", &f.show_password);
        im.ImGui_EndDisabled();

        // volumes: an editable drop-down
        D.caption(S.volumes.get(), 74);
        im.ImGui_BeginDisabled(!f.volumesOn());
        _ = D.input("compress_volumes", &f.volumes, 180 - 24, 0);
        im.ImGui_SameLineEx(0, 0);
        var picked: ?usize = null;
        D.dropDownArrow("compress_volume_presets", &volume_presets, &picked);
        if (picked) |i| D.setText(&f.volumes, volume_presets[i]);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx((74 + 192) * s, -1);
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, im.ImGui_GetStyle().*.Colors[im.ImGuiCol_TextDisabled]);
        im.ImGui_TextUnformatted(S.volumesHint.get());
        im.ImGui_PopStyleColor();
        if (f.volumeSize() == null) {
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, kit.app.color(d.ctx.app.cfg.palette.danger, 1));
            kit.ui.text("compress_volume_error", S.badVolumeSize.get(), null, (left + right) * s);
            im.ImGui_PopStyleColor();
        }

        _ = D.checkbox(S.testAfter.get(), "compress_test_after", &f.test_after);
        im.ImGui_SameLineEx((74 + 192) * s, -1);
        // Not remembered on purpose: a forgotten tick here costs the user their files.
        _ = D.checkbox(S.deleteSources.get(), "compress_delete_sources", &f.delete_sources);

        // Advanced block (Compression... / 7-Zip's right-hand column), folded away by default.
        const g = kit.ui.glyph(if (st.ShowAdvanced) 0xE70E else 0xE70D);
        var ab: [128]u8 = undefined;
        const adv_label = std.mem.printSentinel(&ab, "{s}  {s}##compress_advanced", .{ S.advancedOptions.get(), std.mem.sliceTo(&g, 0) }, 0) catch "##compress_advanced";
        if (im.ImGui_SmallButton(adv_label.ptr)) {
            st.ShowAdvanced = !st.ShowAdvanced;
            settings.commit();
        }
        if (st.ShowAdvanced) f.drawAdvanced();

        im.ImGui_Dummy(.{ .x = 0, .y = 4 * s });
        D.alignRight(&.{ S.create.get(), S.cancel.get() });
        const busy = f.state != .idle;
        if (D.buttonOn(f.volumeSize() != null and !busy, S.create.get(), "compress_create")) f.doCreate(d);
        im.ImGui_SameLine();
        if (D.button(S.cancel.get(), "compress_cancel")) f.done = true;
        if (!busy and D.escPressed()) f.done = true;
        if (!busy and D.enterPressed() and f.volumeSize() != null and !im.ImGui_IsAnyItemActive()) f.doCreate(d);
    }

    fn drawAdvanced(f: *Compress) void {
        const s = D.scale();
        im.ImGui_BeginDisabled(!f.advOn());
        D.caption(S.method.get(), 74);
        if (D.combo("compress_method", f.method_names[0..f.methods.len], &f.method, 110)) f.refreshAdvanced();
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx((74 + 128) * s, -1);
        im.ImGui_BeginDisabled(!f.dictOn());
        D.caption(S.dictionary.get(), 0);
        im.ImGui_SameLineEx((74 + 128 + 74) * s, -1);
        _ = D.combo("compress_dictionary", &f.dict_names, &f.dict, 150);
        im.ImGui_EndDisabled();

        im.ImGui_BeginDisabled(!f.solidOn());
        D.caption(S.solidBlock.get(), 74);
        _ = D.combo("compress_solid", &f.solid_names, &f.solid, 110);
        im.ImGui_EndDisabled();
        im.ImGui_SameLineEx((74 + 128) * s, -1);
        im.ImGui_BeginDisabled(!f.advOn());
        D.caption(S.threads.get(), 0);
        im.ImGui_SameLineEx((74 + 128 + 74) * s, -1);
        _ = D.combo("compress_threads", f.thread_names, &f.threads, 150);
        im.ImGui_EndDisabled();

        im.ImGui_BeginDisabled(!f.solidOn());
        D.caption(S.exeFilter.get(), 74);
        _ = D.combo("compress_filter", &f.filter_names, &f.filter, 110);
        im.ImGui_EndDisabled();
    }

    fn sideButton(_: *Compress, text: []const u8, id: []const u8, width: f32) bool {
        var b: [256]u8 = undefined;
        return im.ImGui_ButtonEx(D.lbl(&b, text, id).ptr, .{ .x = width * D.scale(), .y = 0 });
    }

    fn browseOut(f: *Compress, d: *Dialogs) void {
        const cur = D.bufText(&f.out);
        const e = f.ext();
        var sb: [32]u8 = undefined;
        const spec = std.mem.print(&sb, "*{s}", .{e}) catch "*.*";
        const name = if (f.sfxOn()) "SFX" else f.info().name;
        const got = (kit.win.saveFile(f.gpa, D.owner(d), .{
            .file_name = fspath.basename(cur),
            .folder = fspath.dirname(cur),
            .filters = &.{ .{ .name = name, .spec = spec }, .{ .name = S.allFiles.get(), .spec = "*.*" } },
        }) catch null) orelse return;
        defer f.gpa.free(got);
        D.setText(&f.out, got);
        f.auto_out = false;
    }

    pub fn close(f: *Compress, _: *Dialogs) bool {
        return f.state == .idle;
    }

    pub fn deinit(f: *Compress, d: *Dialogs) void {
        if (d.add_form == f) d.add_form = null;
        f.run.deinit();
        f.reply.reset(f.gpa);
        for (f.inputs.items) |p| f.gpa.free(p);
        f.inputs.deinit(f.gpa);
        f.sel.deinit(f.gpa);
        if (f.save_name.len > 0) f.gpa.free(f.save_name);
        std.crypto.secureZero(u8, &f.password);
        std.crypto.secureZero(u8, &f.confirm_box);
        f.job_arena.deinit();
        f.strs.deinit();
        f.gpa.destroy(f);
    }
};

/// CompressForm(inputs): modal over the main window (DoNew) or modeless (dispatch "a").
pub fn open(d: *Dialogs, inputs: []const []const u8, open_created: bool, modal: bool) ?*Compress {
    const gpa = d.ctx.gpa;
    const f = gpa.create(Compress) catch return null;
    f.* = .{ .gpa = gpa, .strs = .init(gpa), .job_arena = .init(gpa), .open_created = open_created, .modal = modal };
    const st = settings.current();
    const a = f.strs.allocator();
    f.level = levelIndex(st.Level);
    f.test_after = st.TestAfter;
    for (dictionaries, 0..) |v, i| {
        var nb: [32]u8 = undefined;
        f.dict_names[i] = if (v == 0) S.auto.get() else (a.dupe(u8, engine.niceSize(&nb, v)) catch "?");
    }
    f.dict = std.mem.findScalar(i64, &dictionaries, st.Dictionary) orelse 0;
    for (solids, 0..) |v, i| f.solid_names[i] = if (v) |x| (if (std.mem.eql(u8, x, "off")) S.off.get() else (std.ascii.allocUpperString(a, x) catch x)) else S.auto.get();
    for (solids, 0..) |v, i| {
        if (v != null and !std.mem.eql(u8, v.?, "off")) f.solid_names[i] = std.mem.concat(a, u8, &.{ f.solid_names[i], "B" }) catch f.solid_names[i];
        if (eqlOpt(v, st.Solid)) f.solid = i;
    }
    f.threads_n = cpuCount() + 1;
    f.thread_names = a.alloc([]const u8, f.threads_n) catch &.{};
    for (f.thread_names, 0..) |*t, i| t.* = if (i == 0) S.auto.get() else (a.print("{d}", .{i}) catch "?");
    if (st.Threads > 0 and @as(usize, @intCast(st.Threads)) < f.thread_names.len) f.threads = @intCast(st.Threads);
    for (filters, 0..) |v, i| {
        f.filter_names[i] = v.text orelse (if (v.value == null) S.auto.get() else S.off.get());
        if (eqlOpt(v.value, st.Filter)) f.filter = i;
    }
    f.addInputs(d, inputs); // also fills the format list - with the inputs known, so a remembered gz/xz can stick
    if (f.kinds_n == 0) f.refreshFormats(d);
    var default_name: ?[]const u8 = null;
    for (st.Profiles) |p| if (p.IsDefault) {
        default_name = p.Name;
        break;
    };
    f.refreshProfiles(d, default_name);
    D.push(d, Compress, f, modal);
    return f;
}

// ---- Program.RunProfile ------------------------------------------------------------------------------------

const ProfileRun = struct {
    arena: std.heap.ArenaAllocator,
    profile: settings.Profile,
    paths: []const []const u8 = &.{},
    plan: ?[]engine.Planned = null,
    single: []const u8 = "",
    opts: engine.CompressOptions = .{},
    reply: Reply = .{},
    run: R.Run = .{},
    state: enum { confirm, run } = .run,

    fn work(r: *R.Run) anyerror!void {
        const t = r.user(ProfileRun);
        const gpa = r.d.ctx.gpa;
        const io = r.d.ctx.io;
        if (t.plan) |plan| return engine.compressEach(gpa, io, plan, t.profile.Format, t.opts, r.progress(), &r.diag);
        return engine.compress(gpa, io, t.paths, t.single, t.profile.Format, t.opts, r.progress(), &r.diag);
    }

    pub fn tick(t: *ProfileRun, d: *Dialogs) bool {
        switch (t.state) {
            .confirm => {
                if (!t.reply.done) return true;
                if (t.reply.button == null) {
                    d.ctx.exit_code = 1;
                    return false;
                }
                t.state = .run;
                t.run.start(d, S.compressing.get(), t, work, false);
                return true;
            },
            .run => {
                const o = t.run.tick() orelse return true;
                if (o != .ok) d.ctx.exit_code = 1;
                return false;
            },
        }
    }

    pub fn deinit(t: *ProfileRun, d: *Dialogs) void {
        t.run.deinit();
        t.reply.reset(d.ctx.gpa);
        t.arena.deinit();
        d.ctx.gpa.destroy(t);
    }
};

/// "Add to name.ext" / a profile's menu item: straight to the archive, no dialog (exit 1 when it did not happen).
pub fn runProfile(d: *Dialogs, p: settings.Profile, paths: []const []const u8) void {
    const gpa = d.ctx.gpa;
    const t = gpa.create(ProfileRun) catch return;
    t.* = .{ .arena = .init(gpa), .profile = p };
    const a = t.arena.allocator();
    const copy = a.alloc([]const u8, paths.len) catch return t.deinit(d);
    for (paths, 0..) |x, i| copy[i] = a.dupe(u8, x) catch return t.deinit(d);
    t.paths = copy;
    t.opts = p.toOptions();
    const folder = settings.current().ArchiveFolder;
    t.plan = if (p.Separate) (engine.planSeparate(a, d.ctx.io, copy, p.ext(), folder) catch return t.deinit(d)) else null;
    t.single = engine.defaultArchivePath(a, d.ctx.io, copy, p.ext(), folder) catch return t.deinit(d);
    var outs: std.ArrayList([]const u8) = .empty;
    if (t.plan) |plan| {
        for (plan) |x| outs.append(a, x.output) catch {};
    } else outs.append(a, t.single) catch {};
    if (overwriteQuestion(gpa, outs.items, t.opts.volume_size)) |q| {
        defer gpa.free(q);
        t.state = .confirm;
        P.message(d, .warning, S.app, q, .yes_no, false, &t.reply);
    } else t.run.start(d, S.compressing.get(), t, ProfileRun.work, false);
    D.addTask(d, ProfileRun, t, false);
}
