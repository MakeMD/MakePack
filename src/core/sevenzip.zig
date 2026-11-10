//! MP-A: direct 7z.dll binding (replaces SevenZipSharp). No ImGui (core rule); kit.w only for Win32/OLE.
//! Interfaces as declared in 7-Zip 26.03 (third_party/7zip/include, reference copy of the official headers).
//!
//! # API (what Engine builds on)
//!
//!   try sevenzip.load(dll_path);                       // once per process, idempotent, thread-safe
//!   const a = try InArchive.open(gpa, path, password, cancel_flag_or_null); // detects the format like 7-Zip
//!   defer a.close();      // password prompt = the caller's loop (C# PasswordForm): PasswordNeeded / WrongPassword
//!                         // -> ask -> open again; extract/check/update use the same password for the bodies
//!   a.items[i]     // index == i: path (UTF-8, '\' as 7z.dll reports it), is_dir, size, packed_size, mtime,
//!                  // attrib, crc, encrypted, method
//!   a.props        // format, format_name, solid, method, blocks, volumes, comment, phy_size, error_flags,
//!                  // warning_flags (a truncated zip/tar opens with a partial list: error_flags says so)
//!   try a.extract(indices_or_null, sink);  // sink.target(item) -> .skip | .file(path) | .writer(w),
//!                                          // sink.done(item, OpResult) after each FILE it wrote (not folders)
//!   try a.check(indices_or_null, sink);    // test mode: sink.done for every item (folders too), nothing written
//!   try sevenzip.create(gpa, out_path, &new_items, .{ .format = .SevenZip, .props = &.{.{ .name = "x", .value = "9" }}, .password = "pw" });
//!   try sevenzip.update(a, out_path, &changes, opts);  // keep / rename / add; an index left out = deleted
//!
//! Passwords: "" means none everywhere (C# string.IsNullOrEmpty). Zip + password without an "em" prop = AES-256
//! (C# Pack and Edit both defaulted to Aes256; 7z.dll's own default would be ZipCrypto).
//! create/update write "<out_path>.<pid>-<n>.makepack-tmp" next to out_path, flush it and only then replace
//! out_path (MoveFileEx): a failed / cancelled write never touches an existing out_path.
//! Long paths (>= 248 UTF-16 units) get the \\?\ prefix. NOT guarded here (Engine's job): zip-slip / ".." in item
//! paths, reserved names (CON, AUX...) in Target.file, out_path being one of the sources.
//!
//! Errors (`Error`, plus whatever Sink.target returns):
//! - open: NotArchive (no handler recognised the file), Damaged (one did but could not open it),
//!   PasswordNeeded (encrypted headers, password null), WrongPassword (encrypted headers, password given),
//!   FileNotFound / AccessDenied / FileBusy, Failed + last_hr.
//! - extract / check: the first failing item's verdict once 7z.dll is done: WrongPassword (kWrongPassword, and also
//!   kDataError / kCRCError on an ENCRYPTED item: 7z bodies cannot tell a wrong key from damage - Sink.done got the
//!   raw verdict, so Engine can still say S.dataErrorEncrypted), UnsupportedMethod, DataError (everything else);
//!   PasswordNeeded (an encrypted item and password null); Canceled (Progress.step returned false).
//!   Canceled / an error mid-item: that item's file is closed and LEFT on disk without Sink.done (Engine knows the
//!   path from its Sink.target answer and deletes it unless KeepBroken).
//! - create / update: InvalidOption (E_INVALIDARG: a property or the item list the format cannot take, a format
//!   without update support, o.format not the archive's own), PasswordNeeded (repacking encrypted data and the
//!   archive was opened without a password), WrongPassword (repacking encrypted data with the wrong one),
//!   Canceled, a source file's FileNotFound / AccessDenied / FileBusy, NoSpaceLeft, Failed + last_hr.
//!   On ANY error the temp file is deleted and out_path is left as it was.
//!
//! Threads: 7z.dll objects are plain C++ objects (no apartment): open on one thread, use on another is fine, one
//! thread at a time per InArchive. No CoInitialize is needed (BSTR/PROPVARIANT helpers work without it).
//! Progress.step / Progress.item may run on a 7z.dll worker thread (multithreaded coders), never two at once.
//!
//! Dropped SevenZipSharp workarounds (do NOT port): reflection for packed sizes (Item.packed_size), the doubled
//! volume callback (Engine joins .001 sets itself; IArchiveOpenVolumeCallback here serves each volume once, for
//! part1.rar / .z01 sets and the Split handler), apartment-bound re-opens, temp-file-then-delete-original updates
//! (update() writes a separate out_path; Engine.Edit keeps the .makepack~ hardlink backup).
const std = @import("std");
const kit = @import("kit");
const types = @import("types.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
const fspath = std.Io.Dir.path;

/// Failures the binding reports. Item-level verdicts also reach Sink.done as an OpResult.
pub const Error = error{
    /// 7z.dll missing, not loadable, or without the expected exports.
    DllLoadFailed,
    /// No handler accepted the file.
    NotArchive,
    /// A handler recognised the file (signature or extension) but could not open it (truncated / corrupt headers).
    Damaged,
    /// The headers are encrypted and no password was given; or an encrypted item needs one (extract/check/update).
    PasswordNeeded,
    /// The headers are encrypted and the given password did not open them; or an item said kWrongPassword, or an
    /// encrypted item failed its data / CRC check.
    WrongPassword,
    /// A callback asked to stop (E_ABORT).
    Canceled,
    /// E_INVALIDARG from ISetProperties / UpdateItems: an option the format cannot take.
    InvalidOption,
    /// An item failed: data error, CRC error, unexpected end, data after end, headers error.
    DataError,
    /// An item uses a method this 7z.dll cannot decode.
    UnsupportedMethod,
    /// Windows' own errors for the archive / a source file (std's names, so Engine passes them through).
    FileNotFound,
    AccessDenied,
    /// Locked by another process (sharing violation).
    FileBusy,
    NoSpaceLeft,
    /// Any other failing HRESULT (its text: last_hr / FormatMessage).
    Failed,
    OutOfMemory,
};

/// The HRESULT behind the last Error.Failed (and the Windows errors) on this thread.
pub threadlocal var last_hr: i32 = 0;

/// NArchive::NExtract::NOperationResult, per item.
pub const OpResult = enum(i32) {
    ok = 0,
    unsupported_method = 1,
    data_error = 2,
    crc_error = 3,
    unavailable = 4,
    unexpected_end = 5,
    data_after_end = 6,
    is_not_arc = 7,
    headers_error = 8,
    wrong_password = 9,
    _,
};

/// The input formats Engine branches on (CanDelete, InnerArchive, Edit's output format); everything else is
/// `other` and shown by `Props.format_name`.
pub const Format = enum { SevenZip, Zip, Tar, Wim, GZip, BZip2, XZ, Lzma, Lzma86, Lzw, Split, other };

/// One entry, read once at open time.
pub const Item = struct {
    /// The index 7z.dll's GetProperty / Extract / UpdateItems take (== its position in InArchive.items).
    index: u32,
    /// kpidPath as 7z.dll reports it, UTF-8 (WTF-8). May use '\' or '/', hold "..", a drive or a leading slash:
    /// Engine's zip-slip guard handles that. gz reports the stored name, bz2/xz/lzma none: "".
    path: []const u8,
    is_dir: bool,
    /// kpidSize (0 when unknown).
    size: u64,
    /// kpidPackSize; null when the handler reports none. Solid 7z: the whole block on its first file, null on the
    /// rest (7-Zip's list shows them blank; the C# list showed 0).
    packed_size: ?u64,
    /// kpidMTime as FILETIME ticks (100 ns since 1601-01-01 UTC); 0 = none.
    mtime: u64,
    /// kpidAttrib (FILE_ATTRIBUTE_*, zip/tar from Unix may carry the mode in the high 16 bits), 0 = none.
    attrib: u32,
    crc: ?u32,
    encrypted: bool,
    /// kpidMethod ("LZMA2:24", "Deflate", "AES-256 Deflate"); "" = none.
    method: []const u8,
};

/// Archive-level properties (SevenZipSharp's ArchiveProperties + IsSolid + Format).
pub const Props = struct {
    format: Format,
    /// The handler's own name ("7z", "zip", "gzip", "tar", "Rar5", "Split", ...).
    format_name: []const u8,
    solid: bool,
    /// kpidMethod of the archive ("LZMA2:24 BCJ"), null = none.
    method: ?[]const u8,
    /// kpidNumBlocks
    blocks: ?u64,
    /// kpidNumVolumes
    volumes: ?u64,
    comment: ?[]const u8,
    /// kpidPhySize
    phy_size: ?u64,
    /// kpidErrorFlags / kpidWarningFlags (arc_flag bits, 0 = none): the archive opened, but e.g. ended early
    /// (a truncated zip / tar lists what was there) or has data after its end. 7-Zip prints them as warnings.
    error_flags: u32,
    warning_flags: u32,
};

/// kpv_ErrorFlags_* (PropID.h) for Props.error_flags / warning_flags.
pub const arc_flag = struct {
    pub const headers_error: u32 = 1 << 1;
    pub const encrypted_headers_error: u32 = 1 << 2;
    pub const unavailable_start: u32 = 1 << 3;
    pub const unconfirmed_start: u32 = 1 << 4;
    pub const unexpected_end: u32 = 1 << 5;
    pub const data_after_end: u32 = 1 << 6;
    pub const unsupported_method: u32 = 1 << 7;
    pub const unsupported_feature: u32 = 1 << 8;
    pub const data_error: u32 = 1 << 9;
    pub const crc_error: u32 = 1 << 10;
};

/// Progress for every long call. May be called from a 7z.dll worker thread (never concurrently); a report that
/// would overlap a running one is dropped.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    /// Bytes done of total (extract: unpacked or packed bytes, as the handler counts); return false to stop
    /// (the call ends with error.Canceled).
    step: ?*const fn (ctx: ?*anyopaque, done: u64, total: u64) bool = null,
    /// An item starts: create/update = the file being packed (C# FileCompressionStarted), when 7z.dll asks for its
    /// data - never for folders, and 7z not for empty files either.
    item: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,
};

/// Where an extracted item goes.
pub const Target = union(enum) {
    skip,
    /// Create (truncate) this file and write the data. A read-only / hidden / system file already there loses those
    /// attributes first (as in 7-Zip), so Overwrite works on a file extracted earlier. Once the item checks out:
    /// mtime and the archive's READONLY/HIDDEN/SYSTEM/ARCHIVE bits. A file that failed its check is left as
    /// written, without them (Engine deletes it unless KeepBroken). The parent folder must exist.
    file: []const u8,
    /// Stream the data (a nested .tar into a temp file, the viewer's buffer); flushed after the item.
    writer: *std.Io.Writer,
};

/// Extract / test callbacks.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    /// Before each requested item, in index order: where its data goes (directories: create it, then .skip;
    /// a directory's answer is never written to). null = skip everything. Ignored by check().
    /// An error from it stops the call and is returned as is.
    target: ?*const fn (ctx: ?*anyopaque, item: *const Item) anyerror!Target = null,
    /// 7z.dll's verdict (the file is closed by then). extract: after each file whose data went to a .file / .writer
    /// target (folders and skipped items never); check: after every requested item, folders included.
    done: ?*const fn (ctx: ?*anyopaque, item: *const Item, result: OpResult) void = null,
    progress: Progress = .{},
};

// ==== loading 7z.dll ======================================================================================

const FormatInfo = struct {
    name: []const u8,
    class_id: Guid,
    /// kExtension: space separated, no dots ("gz gzip tgz tpz apk").
    exts: []const u8,
    sigs: []const []const u8,
    sig_offset: u32,
    flags: u32,
};

const Dll = struct {
    create_object: *const fn (clsid: *const Guid, iid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT,
    formats: []const FormatInfo,
};

var dll: ?Dll = null;
var dll_lock: kit.win.Lock = .{};

/// Loads 7z.dll once per process (LoadLibraryExW with LOAD_WITH_ALTERED_SEARCH_PATH) and its exports.
/// Engine passes "<exe dir>\7z.dll"; tests pass @import("paths").seven_zip_dll. Idempotent.
pub fn load(dll_path: []const u8) Error!void {
    dll_lock.lock();
    defer dll_lock.unlock();
    if (dll != null) return;
    // ponytail: the format table lives as long as the process (7z.dll is never unloaded either).
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer arena_state.deinit();
    const ar = arena_state.allocator();

    const wpath = try toW(ar, dll_path);
    const m = w.LoadLibraryExW(wpath.ptr, null, w.LOAD_WITH_ALTERED_SEARCH_PATH);
    if (m == null) {
        last_hr = hresultFromWin32(w.GetLastError());
        return error.DllLoadFailed;
    }
    const create_object = w.GetProcAddress(m, "CreateObject") orelse return error.DllLoadFailed;
    const count_fn = w.GetProcAddress(m, "GetNumberOfFormats") orelse return error.DllLoadFailed;
    const prop_fn = w.GetProcAddress(m, "GetHandlerProperty2") orelse return error.DllLoadFailed;
    const count: *const fn (*u32) callconv(.winapi) HRESULT = @ptrCast(count_fn);
    const prop: HandlerPropFn = @ptrCast(prop_fn);

    var n: u32 = 0;
    if (count(&n) != S_OK) return error.DllLoadFailed;
    const formats = try ar.alloc(FormatInfo, n);
    for (formats, 0..) |*f, i| {
        var name = handlerProp(prop, i, handler_name);
        var clsid = handlerProp(prop, i, handler_class_id);
        var exts = handlerProp(prop, i, handler_extension);
        var sig = handlerProp(prop, i, handler_signature);
        var multi = handlerProp(prop, i, handler_multi_signature);
        const offset = handlerProp(prop, i, handler_signature_offset);
        const flags = handlerProp(prop, i, handler_flags);
        defer for ([_]*PropVariant{ &name, &clsid, &exts, &sig, &multi }) |v| v.clear();

        const id_bytes = clsid.bytes();
        if (id_bytes.len != @sizeOf(Guid)) return error.DllLoadFailed;
        var sigs: std.ArrayList([]const u8) = .empty;
        if (sig.bytes().len > 0) try sigs.append(ar, try ar.dupe(u8, sig.bytes()));
        var rest = multi.bytes(); // [len][bytes] [len][bytes] ...
        while (rest.len > 0 and rest[0] > 0 and rest.len > rest[0]) : (rest = rest[1 + rest[0] ..])
            try sigs.append(ar, try ar.dupe(u8, rest[1 .. 1 + rest[0]]));
        f.* = .{
            .name = (try name.string(ar)) orelse "",
            .class_id = std.mem.bytesToValue(Guid, id_bytes),
            .exts = (try exts.string(ar)) orelse "",
            .sigs = sigs.items,
            .sig_offset = @intCast(offset.int() orelse 0),
            .flags = @intCast(flags.int() orelse 0),
        };
    }
    dll = .{ .create_object = @ptrCast(create_object), .formats = formats };
}

const HandlerPropFn = *const fn (u32, u32, *PropVariant) callconv(.winapi) HRESULT;

fn handlerProp(get: HandlerPropFn, index: usize, id: u32) PropVariant {
    var v: PropVariant = .{};
    if (get(@intCast(index), id, &v) != S_OK) return .{};
    return v;
}

fn findFormat(name: []const u8) ?*const FormatInfo {
    for ((dll orelse return null).formats) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

fn newObject(f: *const FormatInfo, iid: *const Guid) Error!*anyopaque {
    var out: ?*anyopaque = null;
    const h = dll.?.create_object(&f.class_id, iid, &out);
    if (h != S_OK) return hrError(h);
    return out orelse error.Failed;
}

// ==== the open archive ====================================================================================

/// One open archive (IInArchive + its stream). Not thread-safe: one thread at a time; open a second
/// InArchive of the same file for another thread (cheap: headers only).
pub const InArchive = struct {
    gpa: Allocator,
    /// Read at open time; the strings live as long as the InArchive.
    items: []const Item,
    props: Props,
    /// The password given to open (also used for the bodies by extract/check/update), null = none.
    password: ?[]const u8,
    arena: std.heap.ArenaAllocator,
    x: *InArchiveCom,
    stream: *Stream,
    handler: *const FormatInfo,

    /// Opens any format 7z.dll knows, detected by signature like 7-Zip does: handlers whose signature matches
    /// first; for an exe (MZ) the 7z handler searching the first 4 MB (a 7z SFX) before PE; then handlers
    /// whose extension matches. `password` answers the open callback (encrypted headers) and is kept for the bodies.
    /// `cancel` set (any thread) stops it at the handler's next progress call: error.Canceled.
    pub fn open(gpa: Allocator, path: []const u8, password: ?[]const u8, cancel: ?*const std.atomic.Value(bool)) Error!*InArchive {
        const d = dll orelse return error.DllLoadFailed;
        const a = try gpa.create(InArchive);
        a.* = .{ .gpa = gpa, .items = &.{}, .props = undefined, .password = null, .arena = .init(gpa), .x = undefined, .stream = undefined, .handler = undefined };
        errdefer {
            a.arena.deinit();
            gpa.destroy(a);
        }
        const ar = a.arena.allocator();
        if (nonEmpty(password)) |p| a.password = try ar.dupe(u8, p);
        const own_path = try ar.dupe(u8, path); // a handler may keep the open callback (volumes) as long as it lives

        a.stream = try Stream.openFile(gpa, path, .read);
        errdefer a.stream.unref();
        var head_buf: [64 * 1024]u8 = undefined;
        var got: w.DWORD = 0;
        if (w.ReadFile(a.stream.h, &head_buf, head_buf.len, &got, null) == 0) return winError(w.GetLastError());
        const head = head_buf[0..got];

        // Candidates, in the order 7-Zip would try them. ponytail: of the SFX finders only 7z is tried (the SFX
        // MakePack writes); zip/rar SFX open as PE. 7-Zip's last resort (every remaining handler, IsArc probes,
        // kStartOpen / kBackwardOpen) is not done either: a headerless format under a foreign extension (a V7 tar
        // named *.bin) is NotArchive. Add the full-scan pass if users bring such files.
        var cands: std.ArrayList(struct { f: usize, search: u64 }) = .empty;
        defer cands.deinit(gpa);
        const ext = std.mem.trimStart(u8, fspath.extension(path), ".");
        var pre_arc = false;
        for (d.formats, 0..) |*f, i| if (sigMatches(f, head)) {
            if (f.flags & arc_flag_pre_arc != 0) pre_arc = true else try cands.append(gpa, .{ .f = i, .search = 0 });
        };
        if (pre_arc) {
            for (d.formats, 0..) |*f, i| if (std.mem.eql(u8, f.name, "7z")) try cands.append(gpa, .{ .f = i, .search = 4 << 20 });
            for (d.formats, 0..) |*f, i| if (f.flags & arc_flag_pre_arc != 0 and sigMatches(f, head)) try cands.append(gpa, .{ .f = i, .search = 0 });
        }
        for (d.formats, 0..) |*f, i| if (!sigMatches(f, head) and extMatches(f.exts, ext)) try cands.append(gpa, .{ .f = i, .search = 0 });

        for (cands.items) |c| {
            const f = &d.formats[c.f];
            const cb = try OpenCallback.create(gpa, own_path, a.password, cancel);
            defer cb.unref();
            const x: *InArchiveCom = @ptrCast(@alignCast(try newObject(f, &IID.in_archive)));
            var seek_to: u64 = 0;
            var h = a.stream.in.vt.seek(&a.stream.in, 0, 0, &seek_to);
            if (h == S_OK) h = x.vt.open(x, &a.stream.in, &c.search, &cb.cb);
            const asked = cb.asked;
            if (h == S_OK and (getProp(x, null, kpid_error_flags).int() orelse 0) & error_flag_is_not_arc != 0) h = S_FALSE;
            if (h != S_OK) {
                _ = x.vt.close(x);
                _ = x.vt.release(x);
                if (cancel != null and cancel.?.load(.acquire)) return error.Canceled;
                if (asked) return if (a.password == null) error.PasswordNeeded else error.WrongPassword;
                if (h == E_ABORT) return error.Canceled;
                continue;
            }
            a.x = x;
            a.handler = f;
            a.read(ar) catch |e| {
                _ = x.vt.close(x);
                _ = x.vt.release(x);
                return e;
            };
            return a;
        }
        return if (cands.items.len > 0) error.Damaged else error.NotArchive;
    }

    fn read(a: *InArchive, ar: Allocator) Error!void {
        var n: u32 = 0;
        if (a.x.vt.get_number_of_items(a.x, &n) != S_OK) return error.Damaged;
        const items = try ar.alloc(Item, n);
        for (items, 0..) |*it, i| {
            const idx: u32 = @intCast(i);
            var path = getProp(a.x, idx, kpid_path);
            var method = getProp(a.x, idx, kpid_method);
            it.* = .{
                .index = idx,
                .path = (try path.string(ar)) orelse "",
                .is_dir = getProp(a.x, idx, kpid_is_dir).boolean(),
                .size = getProp(a.x, idx, kpid_size).int() orelse 0,
                .packed_size = getProp(a.x, idx, kpid_pack_size).int(),
                .mtime = getProp(a.x, idx, kpid_mtime).filetime(),
                .attrib = @truncate(getProp(a.x, idx, kpid_attrib).int() orelse 0),
                .crc = if (getProp(a.x, idx, kpid_crc).int()) |c| @truncate(c) else null,
                .encrypted = getProp(a.x, idx, kpid_encrypted).boolean(),
                .method = (try method.string(ar)) orelse "",
            };
        }
        a.items = items;
        var method = getProp(a.x, null, kpid_method);
        var comment = getProp(a.x, null, kpid_comment);
        a.props = .{
            .format = formatOf(a.handler.name),
            .format_name = a.handler.name,
            .solid = getProp(a.x, null, kpid_solid).boolean(),
            .method = try method.string(ar),
            .blocks = getProp(a.x, null, kpid_num_blocks).int(),
            .volumes = getProp(a.x, null, kpid_num_volumes).int(),
            .comment = try comment.string(ar),
            .phy_size = getProp(a.x, null, kpid_phy_size).int(),
            .error_flags = @truncate(getProp(a.x, null, kpid_error_flags).int() orelse 0),
            .warning_flags = @truncate(getProp(a.x, null, kpid_warning_flags).int() orelse 0),
        };
    }

    pub fn close(a: *InArchive) void {
        _ = a.x.vt.close(a.x);
        _ = a.x.vt.release(a.x);
        a.stream.unref();
        a.arena.deinit();
        a.gpa.destroy(a);
    }

    /// Extracts `indices` (null = everything) in index order through `sink`. The first failing item's
    /// verdict comes back as its Error (WrongPassword / DataError / UnsupportedMethod) after 7z.dll is done.
    pub fn extract(a: *InArchive, indices: ?[]const u32, sink: Sink) anyerror!void {
        return run(a, indices, sink, false);
    }

    /// Test mode (C# Check): decodes and verifies `indices` (null = all), writes nothing; errors as extract.
    pub fn check(a: *InArchive, indices: ?[]const u32, sink: Sink) anyerror!void {
        return run(a, indices, sink, true);
    }

    fn run(a: *InArchive, indices: ?[]const u32, sink: Sink, test_mode: bool) anyerror!void {
        var buf: []u32 = &.{};
        defer a.gpa.free(buf);
        var sorted: ?[]u32 = null;
        if (indices) |list| {
            if (list.len == 0) return; // C#: an empty selection extracts nothing
            for (list) |i| if (i >= a.items.len) return error.InvalidOption;
            buf = try a.gpa.dupe(u32, list);
            std.mem.sortUnstable(u32, buf, {}, std.sort.asc(u32)); // IInArchive::Extract wants them sorted and unique
            var n: usize = 1;
            for (buf[1..]) |i| if (i != buf[n - 1]) {
                buf[n] = i;
                n += 1;
            };
            sorted = buf[0..n];
        }
        const cb = try ExtractCallback.create(a, sink, test_mode);
        defer cb.unref();
        const h = if (sorted) |s|
            a.x.vt.extract(a.x, s.ptr, @intCast(s.len), @intFromBool(test_mode), &cb.cb)
        else
            a.x.vt.extract(a.x, null, 0xFFFF_FFFF, @intFromBool(test_mode), &cb.cb);
        cb.finishFile(null); // aborted mid-item: close the file 7z.dll never finished
        if (cb.err) |e| return e;
        if (cb.need_password) return error.PasswordNeeded;
        if (cb.ticker.aborted.load(.acquire)) return error.Canceled;
        if (cb.first_fail) |f| return failError(f.result, f.encrypted);
        if (h != S_OK) return hrError(h);
    }
};

fn failError(r: OpResult, encrypted: bool) Error {
    return switch (r) {
        .ok => unreachable,
        .unsupported_method => error.UnsupportedMethod,
        .wrong_password => error.WrongPassword,
        .data_error, .crc_error => if (encrypted) error.WrongPassword else error.DataError,
        else => error.DataError,
    };
}

fn sigMatches(f: *const FormatInfo, head: []const u8) bool {
    for (f.sigs) |s| {
        if (f.sig_offset + s.len <= head.len and std.mem.eql(u8, head[f.sig_offset..][0..s.len], s)) return true;
    }
    return false;
}

fn extMatches(exts: []const u8, ext: []const u8) bool {
    if (ext.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, exts, ' ');
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

fn formatOf(name: []const u8) Format {
    const table = .{
        .{ "7z", Format.SevenZip },   .{ "zip", Format.Zip },     .{ "tar", Format.Tar },     .{ "wim", Format.Wim },
        .{ "gzip", Format.GZip },     .{ "bzip2", Format.BZip2 }, .{ "xz", Format.XZ },       .{ "lzma", Format.Lzma },
        .{ "lzma86", Format.Lzma86 }, .{ "Z", Format.Lzw },       .{ "Split", Format.Split },
    };
    inline for (table) |e| if (std.mem.eql(u8, name, e[0])) return e[1];
    return .other;
}

/// The handler name 7z.dll registers for each format we write.
fn handlerName(f: types.OutFormat) []const u8 {
    return switch (f) {
        .SevenZip => "7z",
        .Zip => "zip",
        .GZip => "gzip",
        .BZip2 => "bzip2",
        .Wim => "wim",
        .Tar => "tar",
        .XZ => "xz",
    };
}

// ==== writing =============================================================================================

/// A new entry for create/update.
pub const NewItem = struct {
    /// Name inside the archive: relative, '\' separated, no leading slash.
    name: []const u8,
    /// File to read; null = a directory entry (empty folders survive). Size/times/attributes from the file (a
    /// symlink: from its target, as the data).
    source: ?[]const u8,
    /// Directory entries only: the folder whose times/attributes it keeps (C# did); null = now.
    folder: ?[]const u8 = null,
};

/// One entry of the archive update() writes.
pub const Change = union(enum) {
    /// An existing item, unchanged (by index).
    keep: u32,
    /// An existing item's data under a new name (its other properties are kept).
    rename: struct { index: u32, name: []const u8 },
    /// New data.
    add: NewItem,
};

/// One ISetProperties pair, 7-Zip syntax: x=5, m=LZMA2, d=64m, s=off, mt=4, f=BCJ2, he=on, em=AES256|ZipCrypto.
/// Values convert like 7-Zip's command line: all digits = a number (VT_UI4/UI8), "" = no value, else a string.
pub const Prop = struct { name: []const u8, value: []const u8 };

pub const WriteOptions = struct {
    format: types.OutFormat,
    props: []const Prop = &.{},
    /// null / "" = no encryption (ICryptoGetTextPassword2 answers "not defined"); update: the archive's own.
    password: ?[]const u8 = null,
    progress: Progress = .{},
};

/// Writes a new archive of `items` to `out_path` (via a temp file that replaces it on success; a read-only /
/// hidden / system file there loses those attributes). On any error or cancel the temp file is deleted and an
/// existing out_path is untouched: a half-written archive is worse than none.
pub fn create(gpa: Allocator, out_path: []const u8, items: []const NewItem, o: WriteOptions) anyerror!void {
    _ = dll orelse return error.DllLoadFailed;
    const f = findFormat(handlerName(o.format)) orelse return error.InvalidOption;
    const out: *OutArchiveCom = @ptrCast(@alignCast(try newObject(f, &IID.out_archive)));
    defer _ = out.vt.release(out);
    const changes = try gpa.alloc(Change, items.len);
    defer gpa.free(changes);
    for (items, changes) |it, *c| c.* = .{ .add = it };
    return write(gpa, out, null, out_path, changes, o, nonEmpty(o.password));
}

/// Writes `a` with `changes` (the complete new item list, in order; an index left out is deleted) to `out_path`,
/// which must not be the file `a` has open (same file, also through a hard link: FileBusy before anything is
/// written). Same temp-file handling as create. `o.password` null / "" = keep the archive's own.
pub fn update(a: *InArchive, out_path: []const u8, changes: []const Change, o: WriteOptions) anyerror!void {
    // The handler that read the archive writes it: o.format can only confirm it (C#'s Edit wrote garbage when
    // the compressor was left on another format).
    if (!std.mem.eql(u8, handlerName(o.format), a.handler.name)) return error.InvalidOption;
    for (changes) |c| switch (c) {
        .keep => |i| if (i >= a.items.len) return error.InvalidOption,
        .rename => |r| if (r.index >= a.items.len) return error.InvalidOption,
        .add => {},
    };
    var p: ?*anyopaque = null;
    if (a.x.vt.qi(a.x, &IID.out_archive, &p) != S_OK) return error.InvalidOption; // the format cannot be written
    const out: *OutArchiveCom = @ptrCast(@alignCast(p.?));
    defer _ = out.vt.release(out);
    if (sameFile(a.gpa, a.stream.h, out_path)) {
        last_hr = hresultFromWin32(32);
        return error.FileBusy;
    }
    return write(a.gpa, out, a, out_path, changes, o, nonEmpty(o.password) orelse a.password);
}

/// "" = no password (C# string.IsNullOrEmpty).
fn nonEmpty(p: ?[]const u8) ?[]const u8 {
    return if (p != null and p.?.len > 0) p else null;
}

var tmp_counter: std.atomic.Value(u32) = .init(0);

fn write(gpa: Allocator, out: *OutArchiveCom, base: ?*InArchive, out_path: []const u8, changes: []const Change, o: WriteOptions, password: ?[]const u8) anyerror!void {
    // C# (Pack and Edit) encrypted zips with AES-256 unless ZipCrypto was asked for; 7z.dll's default is ZipCrypto.
    // (update checked that o.format is the archive's own.)
    var with_em: std.ArrayList(Prop) = .empty;
    defer with_em.deinit(gpa);
    var props = o.props;
    if (o.format == .Zip and password != null) {
        for (o.props) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, "em")) break;
        } else {
            try with_em.appendSlice(gpa, o.props);
            try with_em.append(gpa, .{ .name = "em", .value = "AES256" });
            props = with_em.items;
        }
    }
    try setProperties(gpa, out, props);

    // A temp file next to out_path (same volume: the final move is a rename); out_path is only replaced once the
    // archive is complete and flushed.
    const pid = w.GetCurrentProcessId();
    var tmp: []u8 = &.{};
    defer gpa.free(tmp);
    const file = for (0..100) |_| {
        tmp = try gpa.print("{s}.{d}-{d}.makepack-tmp", .{ out_path, pid, tmp_counter.fetchAdd(1, .monotonic) });
        break Stream.openFile(gpa, tmp, .create_new) catch |e| {
            if (last_hr != hresultFromWin32(80)) return e; // ERROR_FILE_EXISTS: a leftover of a crashed run, next
            gpa.free(tmp);
            tmp = &.{};
            continue;
        };
    } else return error.Failed;
    const result = blk: {
        const cb = UpdateCallback.create(gpa, base, changes, password, o.progress) catch |e| break :blk e;
        defer cb.unref();
        const h = out.vt.update_items(out, &file.out, @intCast(changes.len), &cb.cb);
        if (cb.err) |e| break :blk e;
        if (cb.need_password) break :blk error.PasswordNeeded;
        if (cb.ticker.aborted.load(.acquire)) break :blk error.Canceled;
        // Repacking an encrypted 7z block with the wrong key: 7z.dll only says E_FAIL (measured; it took the key the
        // open callback gave, not ours), as extraction only says kDataError: with a key and encrypted items, the key
        // is the suspect (a damaged encrypted block reads the same - Engine words it like S.dataErrorEncrypted).
        if (h == E_FAIL or h == S_FALSE or h == hresultFromWin32(23)) if (base) |b| if (b.password != null) {
            for (b.items) |it| if (it.encrypted) {
                last_hr = h;
                break :blk error.WrongPassword;
            };
        };
        if (h != S_OK) break :blk hrError(h);
        if (w.FlushFileBuffers(file.h) == 0) break :blk winError(w.GetLastError()); // before the rename makes it count
        break :blk {};
    };
    file.close(); // explicitly: 7z.dll may still hold a reference, the delete / move below needs the handle gone
    file.unref();
    errdefer deleteFile(gpa, tmp);
    try result;
    try replaceFile(gpa, tmp, out_path);
}

/// MoveFileEx(REPLACE_EXISTING); a read-only / hidden / system target loses those attributes first (as the old
/// CREATE_ALWAYS path did), or the move is refused.
fn replaceFile(gpa: Allocator, from: []const u8, to: []const u8) Error!void {
    const wf = try toPathW(gpa, from);
    defer gpa.free(wf);
    const wt = try toPathW(gpa, to);
    defer gpa.free(wt);
    const flags: w.DWORD = w.MOVEFILE_REPLACE_EXISTING | w.MOVEFILE_WRITE_THROUGH;
    if (w.MoveFileExW(wf.ptr, wt.ptr, flags) != 0) return;
    const e = w.GetLastError();
    if (e != w.ERROR_ACCESS_DENIED or !clearOddAttributes(wt) or w.MoveFileExW(wf.ptr, wt.ptr, flags) == 0)
        return winError(if (e == w.ERROR_ACCESS_DENIED) e else w.GetLastError());
}

/// READONLY / HIDDEN / SYSTEM off on a file (not a folder); false = it had none or they could not be cleared.
fn clearOddAttributes(wp: [:0]const u16) bool {
    const attrs = w.GetFileAttributesW(wp.ptr);
    const odd: w.DWORD = w.FILE_ATTRIBUTE_READONLY | w.FILE_ATTRIBUTE_HIDDEN | w.FILE_ATTRIBUTE_SYSTEM;
    return attrs != w.INVALID_FILE_ATTRIBUTES and attrs & w.FILE_ATTRIBUTE_DIRECTORY == 0 and attrs & odd != 0 and
        w.SetFileAttributesW(wp.ptr, w.FILE_ATTRIBUTE_NORMAL) != 0;
}

/// `path` names the file `h` has open (volume serial + file index: hard links count).
fn sameFile(gpa: Allocator, h: w.HANDLE, path: []const u8) bool {
    const wp = toPathW(gpa, path) catch return false;
    defer gpa.free(wp);
    const share: w.DWORD = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
    const h2 = w.CreateFileW(wp.ptr, w.FILE_READ_ATTRIBUTES, share, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h2 == w.INVALID_HANDLE_VALUE) return false;
    defer _ = w.CloseHandle(h2);
    var x: w.BY_HANDLE_FILE_INFORMATION = undefined;
    var y: w.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w.GetFileInformationByHandle(h, &x) == 0 or w.GetFileInformationByHandle(h2, &y) == 0) return false;
    return x.dwVolumeSerialNumber == y.dwVolumeSerialNumber and x.nFileIndexHigh == y.nFileIndexHigh and x.nFileIndexLow == y.nFileIndexLow;
}

fn setProperties(gpa: Allocator, out: *OutArchiveCom, props: []const Prop) Error!void {
    if (props.len == 0) return;
    var p: ?*anyopaque = null;
    if (out.vt.qi(out, &IID.set_properties, &p) != S_OK) return error.InvalidOption;
    const sp: *SetPropertiesCom = @ptrCast(@alignCast(p.?));
    defer _ = sp.vt.release(sp);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const names = try ar.alloc([*:0]const u16, props.len);
    const values = try ar.alloc(PropVariant, props.len);
    @memset(values, .{});
    defer for (values) |*v| v.clear();
    for (props, names, values) |pr, *n, *v| {
        n.* = try toW(ar, pr.name);
        // SetProperties.cpp ParseNumberString: digits -> UI4 (UI8 when bigger), anything else -> BSTR
        if (pr.value.len == 0) continue;
        if (std.fmt.parseInt(u64, pr.value, 10)) |num| {
            v.* = if (num <= std.math.maxInt(u32)) .{ .vt = vt_ui4, .v = .{ .ul = @intCast(num) } } else .{ .vt = vt_ui8, .v = .{ .uh = num } };
        } else |_| try v.setString(pr.value);
    }
    const h = sp.vt.set_properties(sp, names.ptr, values.ptr, @intCast(props.len));
    if (h != S_OK) return hrError(h);
}

fn deleteFile(gpa: Allocator, path: []const u8) void {
    const wp = toPathW(gpa, path) catch return;
    defer gpa.free(wp);
    _ = w.DeleteFileW(wp.ptr);
}

// ==== Win32 / OLE helpers =================================================================================

const HRESULT = i32;
const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_ABORT: HRESULT = @bitCast(@as(u32, 0x80004004));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));

fn hresultFromWin32(code: u32) HRESULT {
    return if (code == 0) S_OK else @bitCast((code & 0xFFFF) | 0x80070000);
}

fn winError(code: u32) Error {
    last_hr = hresultFromWin32(code);
    return switch (code) {
        2, 3, 53, 67, 123, 161 => error.FileNotFound, // file/path not found, bad net path/name, bad name/path
        5 => error.AccessDenied,
        32, 33 => error.FileBusy, // sharing / lock violation
        39, 112 => error.NoSpaceLeft,
        8, 14 => error.OutOfMemory,
        87 => error.InvalidOption, // E_INVALIDARG
        else => error.Failed,
    };
}

fn hrError(h: HRESULT) Error {
    last_hr = h;
    const u: u32 = @bitCast(h);
    if (h == E_ABORT) return error.Canceled;
    if (h == S_FALSE) return error.DataError;
    if (u >> 16 == 0x8007) return winError(u & 0xFFFF);
    return error.Failed;
}

fn toW(gpa: Allocator, s: []const u8) Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => hrError(E_INVALIDARG), // std/Engine strings are WTF-8: never seen
    };
}

/// A file path for Win32: long ones (>= 248 UTF-16 units) made absolute and prefixed \\?\ (\\?\UNC\ for shares),
/// so CreateFileW & co take them past MAX_PATH (.NET did this for the C# version).
fn toPathW(gpa: Allocator, path: []const u8) Error![:0]u16 {
    return kit.win.longPathW(gpa, path) catch |e| if (e == error.OutOfMemory) error.OutOfMemory else hrError(E_INVALIDARG);
}

const BSTR = ?[*:0]u16;

fn newBstr(s: []const u8) ?[*:0]u16 {
    const n = std.unicode.calcWtf16LeLen(s) catch return null;
    const raw = w.SysAllocStringLen(null, @intCast(n));
    if (raw == null) return null;
    const b: [*:0]u16 = @ptrCast(raw);
    _ = std.unicode.wtf8ToWtf16Le(b[0..n], s) catch unreachable; // calcWtf16LeLen validated it
    return b;
}

fn putBstr(out: *BSTR, s: []const u8) HRESULT {
    out.* = newBstr(s) orelse return E_OUTOFMEMORY;
    return S_OK;
}

// ==== 7-Zip COM declarations (vtable order = Z7_IFACEM_* lists in IArchive.h / IStream.h / ...) ===========

const Guid = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };

fn guidEql(a: Guid, b: Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

/// IDecl.h: {23170F69-40C1-278A-0000-00gg00ii0000}
fn iid7(group: u8, sub: u8) Guid {
    return .{ .d1 = 0x23170F69, .d2 = 0x40C1, .d3 = 0x278A, .d4 = .{ 0, 0, 0, group, 0, sub, 0, 0 } };
}

const IID_IUnknown: Guid = .{ .d1 = 0, .d2 = 0, .d3 = 0, .d4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID = struct {
    const progress = iid7(0, 0x05);
    const seq_in = iid7(3, 0x01);
    const seq_out = iid7(3, 0x02);
    const in_stream = iid7(3, 0x03);
    const out_stream = iid7(3, 0x04);
    const get_size = iid7(3, 0x06);
    const get_password = iid7(5, 0x10);
    const get_password2 = iid7(5, 0x11);
    const set_properties = iid7(6, 0x03);
    const open_callback = iid7(6, 0x10);
    const extract_callback = iid7(6, 0x20);
    const open_volume_callback = iid7(6, 0x30);
    const in_archive = iid7(6, 0x60);
    const update_callback = iid7(6, 0x80);
    const out_archive = iid7(6, 0xA0);
};

// NHandlerPropID
const handler_name = 0;
const handler_class_id = 1;
const handler_extension = 2;
const handler_signature = 6;
const handler_multi_signature = 7;
const handler_signature_offset = 8;
const handler_flags = 11;
const arc_flag_pre_arc = 1 << 9; // NArcInfoFlags::kPreArc: an exe stub (PE, TE) that may carry an archive

// PropID.h
const kpid_path = 3;
const kpid_name = 4;
const kpid_is_dir = 6;
const kpid_size = 7;
const kpid_pack_size = 8;
const kpid_attrib = 9;
const kpid_ctime = 10;
const kpid_atime = 11;
const kpid_mtime = 12;
const kpid_solid = 13;
const kpid_encrypted = 15;
const kpid_crc = 19;
const kpid_is_anti = 21;
const kpid_method = 22;
const kpid_comment = 28;
const kpid_num_blocks = 38;
const kpid_num_volumes = 39;
const kpid_phy_size = 44;
const kpid_error_flags = 71;
const kpid_warning_flags = 72;
const error_flag_is_not_arc = 1 << 0; // kpv_ErrorFlags_IsNotArc

const ask_extract = 0; // NExtract::NAskMode
const ask_skip = 2;

const vt_empty = 0;
const vt_i4 = 3;
const vt_bstr = 8;
const vt_bool = 11;
const vt_ui1 = 17;
const vt_ui2 = 18;
const vt_ui4 = 19;
const vt_i8 = 20;
const vt_ui8 = 21;
const vt_uint = 23;
const vt_filetime = 64;

/// PROPVARIANT as 7z.dll uses it (24 bytes on x64, like windows.h's).
const PropVariant = extern struct {
    vt: u16 = vt_empty,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    v: extern union { uh: u64, ul: u32, h: i64, l: i32, us: u16, ub: u8, b: i16, bstr: BSTR, pad: [2]u64 } = .{ .pad = .{ 0, 0 } },

    comptime {
        std.debug.assert(@sizeOf(PropVariant) == @sizeOf(w.PROPVARIANT));
    }

    fn clear(p: *PropVariant) void {
        _ = w.PropVariantClear(@ptrCast(p));
    }

    fn int(p: PropVariant) ?u64 {
        return switch (p.vt) {
            vt_ui1 => p.v.ub,
            vt_ui2 => p.v.us,
            vt_ui4, vt_uint => p.v.ul,
            vt_ui8 => p.v.uh,
            vt_i4 => if (p.v.l >= 0) @intCast(p.v.l) else null,
            vt_i8 => if (p.v.h >= 0) @intCast(p.v.h) else null,
            else => null,
        };
    }

    fn boolean(p: PropVariant) bool {
        return p.vt == vt_bool and p.v.b != 0;
    }

    fn filetime(p: PropVariant) u64 {
        return if (p.vt == vt_filetime) p.v.uh else 0;
    }

    /// The raw bytes of a VT_BSTR (handler signatures and class ids are binary BSTRs).
    fn bytes(p: PropVariant) []const u8 {
        if (p.vt != vt_bstr) return &.{};
        const b = p.v.bstr orelse return &.{};
        return @as([*]const u8, @ptrCast(b))[0..w.SysStringByteLen(@ptrCast(b))];
    }

    /// VT_BSTR as UTF-8 (WTF-8) in `gpa`, null for anything else. Frees the BSTR.
    fn string(p: *PropVariant, gpa: Allocator) error{OutOfMemory}!?[]u8 {
        defer p.clear();
        if (p.vt != vt_bstr) return null;
        const b = p.v.bstr orelse return null;
        return try std.unicode.wtf16LeToWtf8Alloc(gpa, b[0..w.SysStringLen(@ptrCast(b))]);
    }

    fn setString(p: *PropVariant, s: []const u8) error{OutOfMemory}!void {
        p.* = .{ .vt = vt_bstr, .v = .{ .bstr = newBstr(s) orelse return error.OutOfMemory } };
    }
};

/// Item property (index) or archive property (null); VT_EMPTY when the handler has none.
fn getProp(x: *InArchiveCom, index: ?u32, id: u32) PropVariant {
    var v: PropVariant = .{};
    const h = if (index) |i| x.vt.get_property(x, i, id, &v) else x.vt.get_archive_property(x, id, &v);
    if (h != S_OK) {
        v.clear();
        return .{};
    }
    return v;
}

const This = *anyopaque;
const QueryFn = *const fn (This, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT;
const RefFn = *const fn (This) callconv(.winapi) u32;
const Unused = *const anyopaque;

/// An interface pointer: points at the object's vtable pointer.
fn I(comptime V: type) type {
    return extern struct { vt: *const V };
}

const InStreamVt = extern struct { // ISequentialInStream + IInStream
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    read: *const fn (This, ?[*]u8, u32, ?*u32) callconv(.winapi) HRESULT,
    seek: *const fn (This, i64, u32, ?*u64) callconv(.winapi) HRESULT,
};
const OutStreamVt = extern struct { // ISequentialOutStream + IOutStream
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    write: *const fn (This, ?[*]const u8, u32, ?*u32) callconv(.winapi) HRESULT,
    seek: *const fn (This, i64, u32, ?*u64) callconv(.winapi) HRESULT,
    set_size: *const fn (This, u64) callconv(.winapi) HRESULT,
};
const GetSizeVt = extern struct { // IStreamGetSize
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    get_size: *const fn (This, *u64) callconv(.winapi) HRESULT,
};
const OpenCallbackVt = extern struct { // IArchiveOpenCallback
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    set_total: *const fn (This, ?*const u64, ?*const u64) callconv(.winapi) HRESULT,
    set_completed: *const fn (This, ?*const u64, ?*const u64) callconv(.winapi) HRESULT,
};
const OpenVolumeVt = extern struct { // IArchiveOpenVolumeCallback
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    get_property: *const fn (This, u32, *PropVariant) callconv(.winapi) HRESULT,
    get_stream: *const fn (This, [*:0]const u16, *?*anyopaque) callconv(.winapi) HRESULT,
};
const PasswordVt = extern struct { // ICryptoGetTextPassword
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    get: *const fn (This, *BSTR) callconv(.winapi) HRESULT,
};
const Password2Vt = extern struct { // ICryptoGetTextPassword2
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    get: *const fn (This, *i32, *BSTR) callconv(.winapi) HRESULT,
};
const ExtractCallbackVt = extern struct { // IProgress + IArchiveExtractCallback
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    set_total: *const fn (This, u64) callconv(.winapi) HRESULT,
    set_completed: *const fn (This, ?*const u64) callconv(.winapi) HRESULT,
    get_stream: *const fn (This, u32, *?*anyopaque, i32) callconv(.winapi) HRESULT,
    prepare_operation: *const fn (This, i32) callconv(.winapi) HRESULT,
    set_operation_result: *const fn (This, i32) callconv(.winapi) HRESULT,
};
const UpdateCallbackVt = extern struct { // IProgress + IArchiveUpdateCallback
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    set_total: *const fn (This, u64) callconv(.winapi) HRESULT,
    set_completed: *const fn (This, ?*const u64) callconv(.winapi) HRESULT,
    get_update_item_info: *const fn (This, u32, ?*i32, ?*i32, ?*u32) callconv(.winapi) HRESULT,
    get_property: *const fn (This, u32, u32, *PropVariant) callconv(.winapi) HRESULT,
    get_stream: *const fn (This, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    set_operation_result: *const fn (This, i32) callconv(.winapi) HRESULT,
};
const InArchiveVt = extern struct { // IInArchive
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    open: *const fn (This, *anyopaque, ?*const u64, ?*anyopaque) callconv(.winapi) HRESULT,
    close: *const fn (This) callconv(.winapi) HRESULT,
    get_number_of_items: *const fn (This, *u32) callconv(.winapi) HRESULT,
    get_property: *const fn (This, u32, u32, *PropVariant) callconv(.winapi) HRESULT,
    extract: *const fn (This, ?[*]const u32, u32, i32, *anyopaque) callconv(.winapi) HRESULT,
    get_archive_property: *const fn (This, u32, *PropVariant) callconv(.winapi) HRESULT,
    get_number_of_properties: Unused,
    get_property_info: Unused,
    get_number_of_archive_properties: Unused,
    get_archive_property_info: Unused,
};
const OutArchiveVt = extern struct { // IOutArchive
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    update_items: *const fn (This, *anyopaque, u32, *anyopaque) callconv(.winapi) HRESULT,
    get_file_time_type: Unused,
};
const SetPropertiesVt = extern struct { // ISetProperties
    qi: QueryFn,
    add_ref: RefFn,
    release: RefFn,
    set_properties: *const fn (This, [*]const [*:0]const u16, [*]const PropVariant, u32) callconv(.winapi) HRESULT,
};

const InArchiveCom = I(InArchiveVt);
const OutArchiveCom = I(OutArchiveVt);
const SetPropertiesCom = I(SetPropertiesVt);

// ==== COM objects implemented here (notes K2; refcounts atomic: 7z.dll worker threads release streams) ======

/// IUnknown for interface field `field` of T. T has `refs`, `interfaces` (.{ IID, field } pairs, IUnknown
/// first) and `destroy()`.
fn Unknown(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn self(this: This) *T {
            return @fieldParentPtr(field, @as(*@FieldType(T, field), @ptrCast(@alignCast(this))));
        }
        fn qi(this: This, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const s = self(this);
            inline for (T.interfaces) |e| if (guidEql(riid.*, e[0])) {
                out.* = @ptrCast(&@field(s, e[1]));
                _ = s.refs.fetchAdd(1, .monotonic);
                return S_OK;
            };
            out.* = null;
            return E_NOINTERFACE;
        }
        fn addRef(this: This) callconv(.winapi) u32 {
            return self(this).refs.fetchAdd(1, .monotonic) + 1;
        }
        fn release(this: This) callconv(.winapi) u32 {
            const s = self(this);
            const n = s.refs.fetchSub(1, .acq_rel) - 1;
            if (n == 0) s.destroy();
            return n;
        }
    };
}

/// A file (archive, source, extracted item, new archive) or a writer, as 7-Zip's streams.
const Stream = struct {
    in: I(InStreamVt),
    out: I(OutStreamVt),
    size: I(GetSizeVt),
    refs: std.atomic.Value(u32),
    gpa: Allocator,
    h: w.HANDLE = null,
    writer: ?*std.Io.Writer = null,

    const interfaces = .{
        .{ IID_IUnknown, "in" }, .{ IID.seq_in, "in" },      .{ IID.in_stream, "in" },
        .{ IID.seq_out, "out" }, .{ IID.out_stream, "out" }, .{ IID.get_size, "size" },
    };
    const in_vt: InStreamVt = .{ .qi = Unknown(Stream, "in").qi, .add_ref = Unknown(Stream, "in").addRef, .release = Unknown(Stream, "in").release, .read = read, .seek = seekIn };
    const out_vt: OutStreamVt = .{ .qi = Unknown(Stream, "out").qi, .add_ref = Unknown(Stream, "out").addRef, .release = Unknown(Stream, "out").release, .write = writeData, .seek = seekOut, .set_size = setSize };
    const size_vt: GetSizeVt = .{ .qi = Unknown(Stream, "size").qi, .add_ref = Unknown(Stream, "size").addRef, .release = Unknown(Stream, "size").release, .get_size = getSize };

    fn new(gpa: Allocator, h: w.HANDLE, writer: ?*std.Io.Writer) error{OutOfMemory}!*Stream {
        const s = try gpa.create(Stream);
        s.* = .{ .in = .{ .vt = &in_vt }, .out = .{ .vt = &out_vt }, .size = .{ .vt = &size_vt }, .refs = .init(1), .gpa = gpa, .h = h, .writer = writer };
        return s;
    }

    /// read: archive, source (others may read too); overwrite: an extracted file (created or truncated);
    /// create_new: the temp archive (ERROR_FILE_EXISTS if there).
    fn openFile(gpa: Allocator, path: []const u8, mode: enum { read, overwrite, create_new }) Error!*Stream {
        const wp = try toPathW(gpa, path);
        defer gpa.free(wp);
        const access: w.DWORD = if (mode == .read) w.GENERIC_READ else w.GENERIC_READ | w.GENERIC_WRITE;
        const share: w.DWORD = if (mode == .read) w.FILE_SHARE_READ | w.FILE_SHARE_DELETE else w.FILE_SHARE_READ;
        const disp: w.DWORD = switch (mode) {
            .read => w.OPEN_EXISTING,
            .overwrite => w.CREATE_ALWAYS,
            .create_new => w.CREATE_NEW,
        };
        var h = w.CreateFileW(wp.ptr, access, share, null, disp, w.FILE_ATTRIBUTE_NORMAL, null);
        if (h == w.INVALID_HANDLE_VALUE and mode == .overwrite and w.GetLastError() == w.ERROR_ACCESS_DENIED) {
            // CREATE_ALWAYS refuses a read-only / hidden / system file: clear them, as 7-Zip does before overwriting.
            if (clearOddAttributes(wp)) h = w.CreateFileW(wp.ptr, access, share, null, disp, w.FILE_ATTRIBUTE_NORMAL, null);
            if (h == w.INVALID_HANDLE_VALUE) w.SetLastError(w.ERROR_ACCESS_DENIED);
        }
        if (h == w.INVALID_HANDLE_VALUE) return winError(w.GetLastError());
        return new(gpa, h, null) catch {
            _ = w.CloseHandle(h);
            return error.OutOfMemory;
        };
    }

    fn close(s: *Stream) void {
        if (s.h != null) _ = w.CloseHandle(s.h);
        s.h = null;
    }

    fn destroy(s: *Stream) void {
        s.close();
        s.gpa.destroy(s);
    }

    fn unref(s: *Stream) void {
        _ = Unknown(Stream, "in").release(&s.in);
    }

    fn read(this: This, data: ?[*]u8, size: u32, processed: ?*u32) callconv(.winapi) HRESULT {
        const s = Unknown(Stream, "in").self(this);
        if (processed) |p| p.* = 0;
        if (size == 0) return S_OK;
        if (s.h == null) return E_FAIL;
        var n: w.DWORD = 0;
        if (w.ReadFile(s.h, data, size, &n, null) == 0) return hresultFromWin32(w.GetLastError());
        if (processed) |p| p.* = n;
        return S_OK;
    }

    fn writeData(this: This, data: ?[*]const u8, size: u32, processed: ?*u32) callconv(.winapi) HRESULT {
        const s = Unknown(Stream, "out").self(this);
        if (processed) |p| p.* = 0;
        if (size == 0) return S_OK;
        if (s.writer) |wr| {
            wr.writeAll(data.?[0..size]) catch return E_FAIL;
            if (processed) |p| p.* = size;
            return S_OK;
        }
        if (s.h == null) return E_FAIL;
        var n: w.DWORD = 0;
        if (w.WriteFile(s.h, data, size, &n, null) == 0) return hresultFromWin32(w.GetLastError());
        if (processed) |p| p.* = n;
        return S_OK;
    }

    fn seek(s: *Stream, offset: i64, origin: u32, new_pos: ?*u64) HRESULT {
        if (s.h == null) return E_NOTIMPL; // a writer cannot seek
        var np: w.LARGE_INTEGER = undefined;
        if (w.SetFilePointerEx(s.h, .{ .QuadPart = offset }, &np, origin) == 0) return hresultFromWin32(w.GetLastError());
        if (new_pos) |p| p.* = @bitCast(np.QuadPart);
        return S_OK;
    }

    fn seekIn(this: This, offset: i64, origin: u32, new_pos: ?*u64) callconv(.winapi) HRESULT {
        return Unknown(Stream, "in").self(this).seek(offset, origin, new_pos);
    }

    fn seekOut(this: This, offset: i64, origin: u32, new_pos: ?*u64) callconv(.winapi) HRESULT {
        return Unknown(Stream, "out").self(this).seek(offset, origin, new_pos);
    }

    /// IOutStream::SetSize: truncate / extend, position unchanged.
    fn setSize(this: This, size: u64) callconv(.winapi) HRESULT {
        const s = Unknown(Stream, "out").self(this);
        if (s.h == null) return E_NOTIMPL;
        var cur: w.LARGE_INTEGER = undefined;
        if (w.SetFilePointerEx(s.h, .{ .QuadPart = 0 }, &cur, w.FILE_CURRENT) == 0 or
            w.SetFilePointerEx(s.h, .{ .QuadPart = @intCast(size) }, null, w.FILE_BEGIN) == 0 or
            w.SetEndOfFile(s.h) == 0 or
            w.SetFilePointerEx(s.h, cur, null, w.FILE_BEGIN) == 0) return hresultFromWin32(w.GetLastError());
        return S_OK;
    }

    fn getSize(this: This, size: *u64) callconv(.winapi) HRESULT {
        const s = Unknown(Stream, "size").self(this);
        if (s.h == null) return E_NOTIMPL;
        var li: w.LARGE_INTEGER = undefined;
        if (w.GetFileSizeEx(s.h, &li) == 0) return hresultFromWin32(w.GetLastError());
        size.* = @bitCast(li.QuadPart);
        return S_OK;
    }
};

/// Shared by the extract and update callbacks: SetTotal / SetCompleted -> Progress.step, lossy and serialized.
const Ticker = struct {
    p: Progress,
    total: std.atomic.Value(u64) = .init(0),
    aborted: std.atomic.Value(bool) = .init(false),
    busy: std.atomic.Value(bool) = .init(false),

    fn tick(t: *Ticker, done: ?*const u64) HRESULT {
        if (t.aborted.load(.acquire)) return E_ABORT;
        const step = t.p.step orelse return S_OK;
        const d = (done orelse return S_OK).*;
        if (t.busy.swap(true, .acquire)) return S_OK; // another 7z.dll thread is reporting: drop this one
        defer t.busy.store(false, .release);
        if (!step(t.p.ctx, d, t.total.load(.monotonic))) {
            t.aborted.store(true, .release);
            return E_ABORT;
        }
        return S_OK;
    }
};

/// IArchiveOpenCallback + ICryptoGetTextPassword (encrypted headers) + IArchiveOpenVolumeCallback (the next
/// volumes of part1.rar / .z01 / Split sets, from the first volume's folder).
const OpenCallback = struct {
    cb: I(OpenCallbackVt),
    pw: I(PasswordVt),
    vol: I(OpenVolumeVt),
    refs: std.atomic.Value(u32),
    gpa: Allocator,
    path: []const u8,
    password: ?[]const u8,
    cancel: ?*const std.atomic.Value(bool),
    asked: bool = false,

    const interfaces = .{ .{ IID_IUnknown, "cb" }, .{ IID.open_callback, "cb" }, .{ IID.get_password, "pw" }, .{ IID.open_volume_callback, "vol" } };
    const cb_vt: OpenCallbackVt = .{ .qi = Unknown(OpenCallback, "cb").qi, .add_ref = Unknown(OpenCallback, "cb").addRef, .release = Unknown(OpenCallback, "cb").release, .set_total = nop, .set_completed = completed };
    const pw_vt: PasswordVt = .{ .qi = Unknown(OpenCallback, "pw").qi, .add_ref = Unknown(OpenCallback, "pw").addRef, .release = Unknown(OpenCallback, "pw").release, .get = getPassword };
    const vol_vt: OpenVolumeVt = .{ .qi = Unknown(OpenCallback, "vol").qi, .add_ref = Unknown(OpenCallback, "vol").addRef, .release = Unknown(OpenCallback, "vol").release, .get_property = volumeProperty, .get_stream = volumeStream };

    /// `path` and `password` must outlive the archive (InArchive owns them).
    fn create(gpa: Allocator, path: []const u8, password: ?[]const u8, cancel: ?*const std.atomic.Value(bool)) error{OutOfMemory}!*OpenCallback {
        const s = try gpa.create(OpenCallback);
        s.* = .{ .cb = .{ .vt = &cb_vt }, .pw = .{ .vt = &pw_vt }, .vol = .{ .vt = &vol_vt }, .refs = .init(1), .gpa = gpa, .path = path, .password = password, .cancel = cancel };
        return s;
    }

    fn destroy(s: *OpenCallback) void {
        s.gpa.destroy(s);
    }

    fn unref(s: *OpenCallback) void {
        _ = Unknown(OpenCallback, "cb").release(&s.cb);
    }

    fn nop(_: This, _: ?*const u64, _: ?*const u64) callconv(.winapi) HRESULT {
        return S_OK;
    }

    fn completed(this: This, _: ?*const u64, _: ?*const u64) callconv(.winapi) HRESULT {
        const c = Unknown(OpenCallback, "cb").self(this).cancel orelse return S_OK;
        return if (c.load(.acquire)) E_ABORT else S_OK;
    }

    fn getPassword(this: This, out: *BSTR) callconv(.winapi) HRESULT {
        const s = Unknown(OpenCallback, "pw").self(this);
        s.asked = true;
        out.* = null;
        return putBstr(out, s.password orelse return E_ABORT); // E_ABORT = "the user gave none"
    }

    fn volumeProperty(this: This, id: u32, value: *PropVariant) callconv(.winapi) HRESULT {
        const s = Unknown(OpenCallback, "vol").self(this);
        value.* = .{};
        if (id == kpid_name) value.setString(fspath.basename(s.path)) catch return E_OUTOFMEMORY;
        return S_OK;
    }

    fn volumeStream(this: This, name: [*:0]const u16, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const s = Unknown(OpenCallback, "vol").self(this);
        out.* = null;
        const name8 = std.unicode.wtf16LeToWtf8Alloc(s.gpa, std.mem.span(name)) catch return E_OUTOFMEMORY;
        defer s.gpa.free(name8);
        const full = if (fspath.dirname(s.path)) |dir| fspath.join(s.gpa, &.{ dir, fspath.basename(name8) }) catch return E_OUTOFMEMORY else s.gpa.dupe(u8, name8) catch return E_OUTOFMEMORY;
        defer s.gpa.free(full);
        const st = Stream.openFile(s.gpa, full, .read) catch |e| return if (e == error.FileNotFound) S_FALSE else hresultOf(e);
        out.* = @ptrCast(&st.in); // 7z.dll owns this reference
        return S_OK;
    }
};

fn hresultOf(e: Error) HRESULT {
    return if (e == error.OutOfMemory) E_OUTOFMEMORY else if (last_hr != 0) last_hr else E_FAIL;
}

/// IArchiveExtractCallback (+IProgress) + ICryptoGetTextPassword (encrypted items).
const ExtractCallback = struct {
    cb: I(ExtractCallbackVt),
    pw: I(PasswordVt),
    refs: std.atomic.Value(u32),
    a: *InArchive,
    sink: Sink,
    test_mode: bool,
    ticker: Ticker,
    /// The item between GetStream and SetOperationResult that was not skipped.
    cur: ?u32 = null,
    /// Its file / writer (our own reference).
    cur_stream: ?*Stream = null,
    /// Sink.target's error, or creating the file failed: returned as is.
    err: ?anyerror = null,
    need_password: bool = false,
    first_fail: ?struct { result: OpResult, encrypted: bool } = null,

    const interfaces = .{ .{ IID_IUnknown, "cb" }, .{ IID.progress, "cb" }, .{ IID.extract_callback, "cb" }, .{ IID.get_password, "pw" } };
    const U = Unknown(ExtractCallback, "cb");
    const cb_vt: ExtractCallbackVt = .{ .qi = U.qi, .add_ref = U.addRef, .release = U.release, .set_total = setTotal, .set_completed = setCompleted, .get_stream = getStream, .prepare_operation = prepare, .set_operation_result = setResult };
    const pw_vt: PasswordVt = .{ .qi = Unknown(ExtractCallback, "pw").qi, .add_ref = Unknown(ExtractCallback, "pw").addRef, .release = Unknown(ExtractCallback, "pw").release, .get = getPassword };

    fn create(a: *InArchive, sink: Sink, test_mode: bool) error{OutOfMemory}!*ExtractCallback {
        const s = try a.gpa.create(ExtractCallback);
        s.* = .{ .cb = .{ .vt = &cb_vt }, .pw = .{ .vt = &pw_vt }, .refs = .init(1), .a = a, .sink = sink, .test_mode = test_mode, .ticker = .{ .p = sink.progress } };
        return s;
    }

    fn destroy(s: *ExtractCallback) void {
        s.finishFile(null);
        s.a.gpa.destroy(s);
    }

    fn unref(s: *ExtractCallback) void {
        _ = U.release(&s.cb);
    }

    fn fail(s: *ExtractCallback, e: anyerror) HRESULT {
        if (s.err == null) s.err = e;
        s.ticker.aborted.store(true, .release);
        return E_ABORT;
    }

    fn setTotal(this: This, total: u64) callconv(.winapi) HRESULT {
        U.self(this).ticker.total.store(total, .monotonic);
        return S_OK;
    }

    fn setCompleted(this: This, done: ?*const u64) callconv(.winapi) HRESULT {
        return U.self(this).ticker.tick(done);
    }

    fn getStream(this: This, index: u32, out: *?*anyopaque, ask: i32) callconv(.winapi) HRESULT {
        const s = U.self(this);
        out.* = null;
        s.finishFile(null); // ponytail: never happens (SetOperationResult always comes first); keeps handles from leaking
        s.cur = null;
        if (s.ticker.aborted.load(.acquire)) return E_ABORT;
        if (ask == ask_skip or index >= s.a.items.len) return S_OK; // a solid block's unrequested neighbours
        const item = &s.a.items[index];
        if (s.test_mode or ask != ask_extract) {
            s.cur = index;
            return S_OK;
        }
        const target_fn = s.sink.target orelse return S_OK;
        const t = target_fn(s.sink.ctx, item) catch |e| return s.fail(e);
        if (item.is_dir) return S_OK;
        const st = switch (t) {
            .skip => return S_OK,
            .file => |path| Stream.openFile(s.a.gpa, path, .overwrite) catch |e| return s.fail(e),
            .writer => |wr| Stream.new(s.a.gpa, null, wr) catch |e| return s.fail(e),
        };
        _ = Unknown(Stream, "out").addRef(&st.out); // one for us, one for 7z.dll
        s.cur_stream = st;
        s.cur = index;
        out.* = @ptrCast(&st.out);
        return S_OK;
    }

    fn prepare(_: This, _: i32) callconv(.winapi) HRESULT {
        return S_OK;
    }

    fn setResult(this: This, result: i32) callconv(.winapi) HRESULT {
        const s = U.self(this);
        const index = s.cur orelse return S_OK; // skipped
        s.cur = null;
        const r: OpResult = @fromBackingInt(result);
        s.finishFile(if (r == .ok) index else null);
        const item = &s.a.items[index];
        if (r != .ok and s.first_fail == null) s.first_fail = .{ .result = r, .encrypted = item.encrypted };
        if (s.sink.done) |done| done(s.sink.ctx, item, r);
        return if (s.err != null) E_ABORT else S_OK;
    }

    /// Closes the current file; `ok_index` (the item checked out) also sets its mtime and attributes - a broken
    /// file gets neither, so it stays deletable.
    fn finishFile(s: *ExtractCallback, ok_index: ?u32) void {
        const st = s.cur_stream orelse return;
        s.cur_stream = null;
        defer st.unref();
        if (st.writer) |wr| {
            wr.flush() catch {
                _ = s.fail(error.WriteFailed);
            };
            return;
        }
        if (ok_index) |index| {
            const item = &s.a.items[index];
            var info: FileBasicInfo = .{ .mtime = @bitCast(item.mtime), .attrs = item.attrib & keep_attrs };
            _ = w.SetFileInformationByHandle(st.h, w.FileBasicInfo, &info, @sizeOf(FileBasicInfo)); // 0 = leave as is
        }
        st.close();
    }

    fn getPassword(this: This, out: *BSTR) callconv(.winapi) HRESULT {
        const s = Unknown(ExtractCallback, "pw").self(this);
        out.* = null;
        const p = s.a.password orelse {
            s.need_password = true;
            return E_ABORT;
        };
        return putBstr(out, p);
    }
};

/// Size, attributes and times of a source. A symlink / junction describes its target (the data GetStream reads),
/// not the link. ponytail: a file that changes between this and GetStream is packed as read; 7z / zip take the
/// size from the data they actually got.
fn fileInfo(gpa: Allocator, path: []const u8) Error!w.WIN32_FILE_ATTRIBUTE_DATA {
    const wp = try toPathW(gpa, path);
    defer gpa.free(wp);
    var fd: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (w.GetFileAttributesExW(wp.ptr, w.GetFileExInfoStandard, &fd) == 0) return winError(w.GetLastError());
    if (fd.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT == 0) return fd;
    const share: w.DWORD = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
    const h = w.CreateFileW(wp.ptr, w.FILE_READ_ATTRIBUTES, share, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == w.INVALID_HANDLE_VALUE) return winError(w.GetLastError());
    defer _ = w.CloseHandle(h);
    var bh: w.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w.GetFileInformationByHandle(h, &bh) == 0) return winError(w.GetLastError());
    return .{ .dwFileAttributes = bh.dwFileAttributes, .ftCreationTime = bh.ftCreationTime, .ftLastAccessTime = bh.ftLastAccessTime, .ftLastWriteTime = bh.ftLastWriteTime, .nFileSizeHigh = bh.nFileSizeHigh, .nFileSizeLow = bh.nFileSizeLow };
}

/// FILE_BASIC_INFO (SetFileInformationByHandle); a zero field leaves that value unchanged.
const FileBasicInfo = extern struct { ctime: i64 = 0, atime: i64 = 0, mtime: i64 = 0, change: i64 = 0, attrs: u32 = 0 };
/// The archive's attribute bits we put back: READONLY, HIDDEN, SYSTEM, ARCHIVE.
const keep_attrs: u32 = 0x1 | 0x2 | 0x4 | 0x20;

/// IArchiveUpdateCallback (+IProgress) + ICryptoGetTextPassword2 (new data) + ICryptoGetTextPassword (repacking
/// encrypted 7z blocks). ponytail: no IArchiveUpdateCallback2 - no 26.03 handler asks for it (only 7-Zip's UI
/// multi-volume stream does); Engine splits volumes itself.
const UpdateCallback = struct {
    cb: I(UpdateCallbackVt),
    pw: I(PasswordVt),
    pw2: I(Password2Vt),
    refs: std.atomic.Value(u32),
    gpa: Allocator,
    base: ?*InArchive,
    changes: []const Change,
    password: ?[]const u8,
    ticker: Ticker,
    err: ?anyerror = null,
    need_password: bool = false,

    const interfaces = .{ .{ IID_IUnknown, "cb" }, .{ IID.progress, "cb" }, .{ IID.update_callback, "cb" }, .{ IID.get_password, "pw" }, .{ IID.get_password2, "pw2" } };
    const U = Unknown(UpdateCallback, "cb");
    const cb_vt: UpdateCallbackVt = .{ .qi = U.qi, .add_ref = U.addRef, .release = U.release, .set_total = setTotal, .set_completed = setCompleted, .get_update_item_info = itemInfo, .get_property = property, .get_stream = getStream, .set_operation_result = setResult };
    const pw_vt: PasswordVt = .{ .qi = Unknown(UpdateCallback, "pw").qi, .add_ref = Unknown(UpdateCallback, "pw").addRef, .release = Unknown(UpdateCallback, "pw").release, .get = decodePassword };
    const pw2_vt: Password2Vt = .{ .qi = Unknown(UpdateCallback, "pw2").qi, .add_ref = Unknown(UpdateCallback, "pw2").addRef, .release = Unknown(UpdateCallback, "pw2").release, .get = encodePassword };

    fn create(gpa: Allocator, base: ?*InArchive, changes: []const Change, password: ?[]const u8, p: Progress) error{OutOfMemory}!*UpdateCallback {
        const s = try gpa.create(UpdateCallback);
        s.* = .{ .cb = .{ .vt = &cb_vt }, .pw = .{ .vt = &pw_vt }, .pw2 = .{ .vt = &pw2_vt }, .refs = .init(1), .gpa = gpa, .base = base, .changes = changes, .password = password, .ticker = .{ .p = p } };
        return s;
    }

    fn destroy(s: *UpdateCallback) void {
        s.gpa.destroy(s);
    }

    fn unref(s: *UpdateCallback) void {
        _ = U.release(&s.cb);
    }

    fn fail(s: *UpdateCallback, e: anyerror) HRESULT {
        if (s.err == null) s.err = e;
        s.ticker.aborted.store(true, .release);
        return E_ABORT;
    }

    fn setTotal(this: This, total: u64) callconv(.winapi) HRESULT {
        U.self(this).ticker.total.store(total, .monotonic);
        return S_OK;
    }

    fn setCompleted(this: This, done: ?*const u64) callconv(.winapi) HRESULT {
        return U.self(this).ticker.tick(done);
    }

    fn itemInfo(this: This, index: u32, new_data: ?*i32, new_props: ?*i32, index_in_archive: ?*u32) callconv(.winapi) HRESULT {
        const s = U.self(this);
        if (index >= s.changes.len) return E_INVALIDARG;
        const data: i32, const props: i32, const old: u32 = switch (s.changes[index]) {
            .keep => |i| .{ 0, 0, i },
            .rename => |r| .{ 0, 1, r.index },
            .add => .{ 1, 1, 0xFFFF_FFFF },
        };
        if (new_data) |p| p.* = data;
        if (new_props) |p| p.* = props;
        if (index_in_archive) |p| p.* = old;
        return S_OK;
    }

    fn property(this: This, index: u32, id: u32, value: *PropVariant) callconv(.winapi) HRESULT {
        const s = U.self(this);
        value.* = .{};
        if (index >= s.changes.len) return E_INVALIDARG;
        const n = switch (s.changes[index]) {
            .keep => |i| return s.base.?.x.vt.get_property(s.base.?.x, i, id, value),
            .rename => |r| {
                if (id != kpid_path) return s.base.?.x.vt.get_property(s.base.?.x, r.index, id, value);
                value.setString(r.name) catch return E_OUTOFMEMORY;
                return S_OK;
            },
            .add => |it| it,
        };
        switch (id) {
            kpid_path => value.setString(n.name) catch return E_OUTOFMEMORY,
            kpid_is_dir => value.* = .{ .vt = vt_bool, .v = .{ .b = if (n.source == null) -1 else 0 } },
            kpid_is_anti => value.* = .{ .vt = vt_bool, .v = .{ .b = 0 } },
            kpid_size, kpid_attrib, kpid_mtime, kpid_ctime, kpid_atime => {
                var fd: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
                if (n.source orelse n.folder) |src| {
                    fd = fileInfo(s.gpa, src) catch |e| return s.fail(e);
                } else {
                    var now: w.FILETIME = undefined;
                    w.GetSystemTimeAsFileTime(&now);
                    fd = .{ .dwFileAttributes = w.FILE_ATTRIBUTE_DIRECTORY, .ftCreationTime = now, .ftLastAccessTime = now, .ftLastWriteTime = now, .nFileSizeHigh = 0, .nFileSizeLow = 0 };
                }
                const ft = switch (id) {
                    kpid_mtime => fd.ftLastWriteTime,
                    kpid_ctime => fd.ftCreationTime,
                    else => fd.ftLastAccessTime,
                };
                value.* = switch (id) {
                    kpid_size => .{ .vt = vt_ui8, .v = .{ .uh = @as(u64, fd.nFileSizeHigh) << 32 | fd.nFileSizeLow } },
                    kpid_attrib => .{ .vt = vt_ui4, .v = .{ .ul = fd.dwFileAttributes } },
                    else => .{ .vt = vt_filetime, .v = .{ .uh = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime } },
                };
            },
            else => {},
        }
        return S_OK;
    }

    fn getStream(this: This, index: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const s = U.self(this);
        out.* = null;
        if (s.ticker.aborted.load(.acquire)) return E_ABORT;
        if (index >= s.changes.len) return E_INVALIDARG;
        const n = switch (s.changes[index]) {
            .add => |it| it,
            else => return S_OK,
        };
        const src = n.source orelse return S_OK; // a directory
        if (s.ticker.p.item) |f| f(s.ticker.p.ctx, n.name);
        // An unreadable source is an error, not a skipped file: Engine may recycle the sources afterwards.
        const st = Stream.openFile(s.gpa, src, .read) catch |e| return s.fail(e);
        out.* = @ptrCast(&st.in);
        return S_OK;
    }

    fn setResult(_: This, _: i32) callconv(.winapi) HRESULT {
        return S_OK;
    }

    fn decodePassword(this: This, out: *BSTR) callconv(.winapi) HRESULT {
        const s = Unknown(UpdateCallback, "pw").self(this);
        out.* = null;
        const p = (if (s.base) |b| b.password else null) orelse {
            s.need_password = true;
            return E_ABORT;
        };
        return putBstr(out, p);
    }

    fn encodePassword(this: This, defined: *i32, out: *BSTR) callconv(.winapi) HRESULT {
        const s = Unknown(UpdateCallback, "pw2").self(this);
        out.* = null;
        defined.* = @intFromBool(s.password != null);
        return if (s.password) |p| putBstr(out, p) else S_OK;
    }
};

test "contract compiles" {
    @import("../testutil.zig").refAllDeep(@This(), 2);
}
