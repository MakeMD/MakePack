//! MP-G1: drag-out (MainForm.DragOut) with a real OLE DoDragDrop: a Zig IDataObject that offers CF_HDROP and a
//! Zig IDropSource. Archived files go the 7-Zip way: the drag carries temp-folder paths that do not exist yet and
//! QueryContinueDrag extracts them at the moment the button is released, while the target still waits for its
//! Drop (extracting first and dragging afterwards does not work: a progress window eats the press).
//! A failed or cancelled extraction cancels the drop. UI thread only; DoDragDrop runs a modal loop.
// ponytail: the extraction at drop time runs right there on the UI thread with a wait cursor and no progress
// (the frame loop is stopped inside DoDragDrop anyway); a delayed-render IDataObject
// (CFSTR_FILEDESCRIPTOR/FILECONTENTS) is the upgrade path, as in C#.
const std = @import("std");
const kit = @import("kit");
const shell = @import("mw_shell.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;
/// The COM objects outlive DoDragDrop when a target keeps a reference: heap, freed at refcount 0.
const heap = std.heap.smp_allocator;

/// Runs at drop time; false = failed or cancelled (the drop is cancelled).
pub const Job = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) bool,
};

var ole_ready = false;

/// DoDragDrop of `paths` (CF_HDROP). `effects` = DROPEFFECT_* offered. Returns the effect the target chose
/// (DROPEFFECT_NONE when cancelled). Blocks until the drop.
pub fn run(paths: []const []const u8, effects: w.DWORD, job: ?Job) w.DWORD {
    if (!ole_ready) ole_ready = w.OleInitialize(null) >= 0;
    const data = DataObject.create(paths) orelse return 0;
    defer _ = DataObject.release(&data.iface);
    const src = heap.create(DropSource) catch return 0;
    src.* = .{ .job = job };
    defer _ = DropSource.release(&src.iface);
    var effect: w.DWORD = 0;
    const hr = w.DoDragDrop(@ptrCast(&data.iface), @ptrCast(&src.iface), effects, &effect);
    return if (hr == w.DRAGDROP_S_DROP) effect else 0;
}

pub fn deinit() void {
    if (ole_ready) w.OleUninitialize();
    ole_ready = false;
}

fn guidEql(a: w.GUID, b: w.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

const DropSource = struct {
    iface: w.IDropSource = .{ .lpVtbl = @constCast(&vtbl) },
    refs: u32 = 1,
    /// The effect the target under the pointer offers (GiveFeedback): none over nothing that takes files.
    feedback: w.DWORD = 0,
    job: ?Job,

    const vtbl: w.IDropSourceVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .QueryContinueDrag = queryContinueDrag,
        .GiveFeedback = giveFeedback,
    };

    fn self(this: [*c]w.IDropSource) *DropSource {
        return @fieldParentPtr("iface", @as(*w.IDropSource, @ptrCast(this)));
    }
    fn queryInterface(this: [*c]w.IDropSource, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) w.HRESULT {
        if (guidEql(riid.*, w.IID_IUnknown) or guidEql(riid.*, w.IID_IDropSource)) {
            out.* = this;
            _ = addRef(this);
            return w.S_OK;
        }
        out.* = null;
        return w.E_NOINTERFACE;
    }
    fn addRef(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs += 1;
        return s.refs;
    }
    fn release(this: [*c]w.IDropSource) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs -= 1;
        const left = s.refs;
        if (left == 0) heap.destroy(s);
        return left;
    }
    fn queryContinueDrag(this: [*c]w.IDropSource, escape: w.WINBOOL, keys: w.DWORD) callconv(.c) w.HRESULT {
        const s = self(this);
        if (escape != 0) return w.DRAGDROP_S_CANCEL;
        if (keys & w.MK_LBUTTON != 0) return w.S_OK;
        // Button released: extract now, while the target still waits for its Drop.
        if (s.job) |job| {
            s.job = null;
            if (s.feedback == 0) return w.DRAGDROP_S_CANCEL;
            const old = w.SetCursor(w.LoadCursorW(null, @ptrFromInt(32514))); // IDC_WAIT
            defer _ = w.SetCursor(old);
            if (!job.run(job.ctx)) return w.DRAGDROP_S_CANCEL;
        }
        return w.DRAGDROP_S_DROP;
    }
    fn giveFeedback(this: [*c]w.IDropSource, effect: w.DWORD) callconv(.c) w.HRESULT {
        self(this).feedback = effect;
        return w.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

const DataObject = struct {
    iface: w.IDataObject = .{ .lpVtbl = @constCast(&vtbl) },
    refs: u32 = 1,
    arena: *std.heap.ArenaAllocator,
    paths_ptr: [*]const []const u8,
    paths_len: usize,

    const vtbl: w.IDataObjectVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .GetData = getData,
        .GetDataHere = getDataHere,
        .QueryGetData = queryGetData,
        .GetCanonicalFormatEtc = getCanonicalFormatEtc,
        .SetData = setData,
        .EnumFormatEtc = enumFormatEtc,
        .DAdvise = dAdvise,
        .DUnadvise = dUnadvise,
        .EnumDAdvise = enumDAdvise,
    };

    const hdrop_fmt: w.FORMATETC = .{ .cfFormat = w.CF_HDROP, .ptd = null, .dwAspect = w.DVASPECT_CONTENT, .lindex = -1, .tymed = w.TYMED_HGLOBAL };

    fn create(paths: []const []const u8) ?*DataObject {
        const arena = heap.create(std.heap.ArenaAllocator) catch return null;
        arena.* = .init(heap);
        const a = arena.allocator();
        const copy = a.alloc([]const u8, paths.len) catch return fail(arena);
        for (paths, copy) |p, *c| c.* = a.dupe(u8, p) catch return fail(arena);
        const d = heap.create(DataObject) catch return fail(arena);
        d.* = .{ .arena = arena, .paths_ptr = copy.ptr, .paths_len = copy.len };
        return d;
    }

    fn fail(arena: *std.heap.ArenaAllocator) ?*DataObject {
        arena.deinit();
        heap.destroy(arena);
        return null;
    }

    fn self(this: [*c]w.IDataObject) *DataObject {
        return @fieldParentPtr("iface", @as(*w.IDataObject, @ptrCast(this)));
    }
    fn isHdrop(f: [*c]w.FORMATETC) bool {
        return f != null and f.*.cfFormat == w.CF_HDROP and f.*.tymed & w.TYMED_HGLOBAL != 0 and f.*.dwAspect == w.DVASPECT_CONTENT;
    }
    fn queryInterface(this: [*c]w.IDataObject, riid: [*c]const w.IID, out: [*c]?*anyopaque) callconv(.c) w.HRESULT {
        if (guidEql(riid.*, w.IID_IUnknown) or guidEql(riid.*, w.IID_IDataObject)) {
            out.* = this;
            _ = addRef(this);
            return w.S_OK;
        }
        out.* = null;
        return w.E_NOINTERFACE;
    }
    fn addRef(this: [*c]w.IDataObject) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs += 1;
        return s.refs;
    }
    fn release(this: [*c]w.IDataObject) callconv(.c) w.ULONG {
        const s = self(this);
        s.refs -= 1;
        const left = s.refs;
        if (left == 0) {
            const arena = s.arena;
            heap.destroy(s);
            arena.deinit();
            heap.destroy(arena);
        }
        return left;
    }
    fn getData(this: [*c]w.IDataObject, f: [*c]w.FORMATETC, medium: [*c]w.STGMEDIUM) callconv(.c) w.HRESULT {
        if (!isHdrop(f)) return w.DV_E_FORMATETC;
        const s = self(this);
        const h = shell.hdrop(heap, s.paths_ptr[0..s.paths_len]);
        if (h == null) return w.E_OUTOFMEMORY;
        medium.* = std.mem.zeroes(w.STGMEDIUM);
        medium.*.tymed = w.TYMED_HGLOBAL;
        medium.*.unnamed_0.hGlobal = h;
        return w.S_OK;
    }
    fn getDataHere(_: [*c]w.IDataObject, _: [*c]w.FORMATETC, _: [*c]w.STGMEDIUM) callconv(.c) w.HRESULT {
        return w.E_NOTIMPL;
    }
    fn queryGetData(_: [*c]w.IDataObject, f: [*c]w.FORMATETC) callconv(.c) w.HRESULT {
        return if (isHdrop(f)) w.S_OK else w.DV_E_FORMATETC;
    }
    fn getCanonicalFormatEtc(_: [*c]w.IDataObject, _: [*c]w.FORMATETC, out: [*c]w.FORMATETC) callconv(.c) w.HRESULT {
        if (out != null) out.*.ptd = null;
        return w.DATA_S_SAMEFORMATETC;
    }
    fn setData(_: [*c]w.IDataObject, _: [*c]w.FORMATETC, _: [*c]w.STGMEDIUM, _: w.WINBOOL) callconv(.c) w.HRESULT {
        return w.E_NOTIMPL; // drop descriptions and the like: not kept
    }
    fn enumFormatEtc(_: [*c]w.IDataObject, dir: w.DWORD, out: [*c][*c]w.IEnumFORMATETC) callconv(.c) w.HRESULT {
        if (dir != w.DATADIR_GET) return w.E_NOTIMPL;
        return w.SHCreateStdEnumFmtEtc(1, &hdrop_fmt, out);
    }
    fn dAdvise(_: [*c]w.IDataObject, _: [*c]w.FORMATETC, _: w.DWORD, _: [*c]w.IAdviseSink, _: [*c]w.DWORD) callconv(.c) w.HRESULT {
        return w.OLE_E_ADVISENOTSUPPORTED;
    }
    fn dUnadvise(_: [*c]w.IDataObject, _: w.DWORD) callconv(.c) w.HRESULT {
        return w.OLE_E_ADVISENOTSUPPORTED;
    }
    fn enumDAdvise(_: [*c]w.IDataObject, _: [*c][*c]w.IEnumSTATDATA) callconv(.c) w.HRESULT {
        return w.OLE_E_ADVISENOTSUPPORTED;
    }
};
