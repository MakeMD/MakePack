//! MP-G1: pictures as D3D11 textures for ImGui (Shell.cs Icons + ShellInfo's image list).
//!   tool(name, siid, large)  toolbar / status bar: icons\<name>.png next to the exe when the user drew one
//!                            (docs/ICONS-NEEDED.md; loaded with GDI+), else the Windows stock icon (SHGetStockIconInfo)
//!   file(name, folder, path) the list's small icons, as Explorer shows them (SHGetFileInfo), cached per extension
//!                            (per path for files that carry their own icon: exe, lnk, ico ...)
//!   drive(root)              a drive's icon
//! UI thread only. Textures die with `deinit` (before app.deinit).
// ponytail: a GPU device reset (kit recreateDevice) leaves these textures dead; the icons go blank until restart.
const std = @import("std");
const kit = @import("kit");
const im = kit.im;
const w = kit.w;
const pw = @import("../platform/platform_win.zig");

const Allocator = std.mem.Allocator;

pub const Tex = im.ImTextureRef;

pub const Icons = struct {
    gpa: Allocator,
    device: [*c]w.ID3D11Device,
    exe_dir: []const u8,
    /// key -> ID3D11ShaderResourceView* (0 = no picture: the caller keeps its text / glyph)
    map: std.StringHashMapUnmanaged(u64) = .empty,
    gdip: ?Gdip = null,

    pub fn init(gpa: Allocator, device: [*c]w.ID3D11Device, exe_dir: []const u8) Icons {
        return .{ .gpa = gpa, .device = device, .exe_dir = exe_dir };
    }

    pub fn deinit(ic: *Icons) void {
        var it = ic.map.iterator();
        while (it.next()) |e| {
            ic.gpa.free(e.key_ptr.*);
            if (e.value_ptr.* != 0) kit.win.release(@as([*c]w.ID3D11ShaderResourceView, @ptrFromInt(e.value_ptr.*)));
        }
        ic.map.deinit(ic.gpa);
        if (ic.gdip) |g| g.shutdown(g.token);
    }

    /// Icons.Get(name, siid, px): the user's png, else the stock icon (32 px = large, else small); null = none.
    pub fn tool(ic: *Icons, name: []const u8, siid: i32, large: bool) ?Tex {
        var kb: [64]u8 = undefined;
        const key = std.mem.print(&kb, "tool:{s}:{d}", .{ name, @intFromBool(large) }) catch return null;
        if (ic.map.get(key)) |t| return ref(t);
        var t: u64 = 0;
        const png = std.mem.concat(ic.gpa, u8, &.{ ic.exe_dir, "\\icons\\", name, ".png" }) catch null;
        if (png) |p| {
            defer ic.gpa.free(p);
            if (pw.fileExists(p)) t = ic.fromPng(p);
        }
        if (t == 0 and siid >= 0) {
            var info = std.mem.zeroes(w.SHSTOCKICONINFO);
            info.cbSize = @sizeOf(w.SHSTOCKICONINFO);
            const flags: w.UINT = @intCast(w.SHGSI_ICON | (if (large) w.SHGSI_LARGEICON else w.SHGSI_SMALLICON));
            if (w.SHGetStockIconInfo(@intCast(siid), flags, &info) >= 0 and info.hIcon != null) {
                t = ic.fromIcon(info.hIcon);
                _ = w.DestroyIcon(info.hIcon);
            }
        }
        return ic.remember(key, t);
    }

    /// ShellInfo.Of(...).Image: `dir` = the folder on disk the file is in (null for archive entries).
    pub fn file(ic: *Icons, name: []const u8, folder: bool, dir: ?[]const u8) ?Tex {
        const ext = if (folder) "\\folder" else pw.extension(name);
        const own = dir != null and !folder and isOwnIcon(ext);
        var path_buf: [1100]u8 = undefined;
        const path: ?[]const u8 = if (own) (std.mem.print(&path_buf, "{s}{s}{s}", .{ dir.?, if (std.mem.endsWith(u8, dir.?, "\\")) "" else "\\", name }) catch return null) else null;
        var kb: [600]u8 = undefined;
        const key: []const u8 = if (own)
            std.mem.print(&kb, "path:{s}", .{path.?}) catch return null
        else
            std.mem.print(&kb, "ext:{s}", .{if (!folder and ext.len == 0) "\\noext" else ext}) catch return null;
        const lower = std.ascii.lowerString(kb[0..key.len], key);
        if (ic.map.get(lower)) |t| return ref(t);
        var pb: [80]u8 = undefined;
        const probe: []const u8 = if (own) path.? else if (folder) "folder" else std.mem.print(&pb, "file{s}", .{ext}) catch "file";
        const wp = kit.win.toW(ic.gpa, probe) catch return null;
        defer ic.gpa.free(wp);
        var info = std.mem.zeroes(w.SHFILEINFOW);
        const attr: w.DWORD = if (folder) w.FILE_ATTRIBUTE_DIRECTORY else w.FILE_ATTRIBUTE_NORMAL;
        const flags: w.UINT = @intCast(w.SHGFI_ICON | w.SHGFI_SMALLICON | (if (own) 0 else w.SHGFI_USEFILEATTRIBUTES));
        var t: u64 = 0;
        if (w.SHGetFileInfoW(wp.ptr, attr, &info, @sizeOf(w.SHFILEINFOW), flags) != 0 and info.hIcon != null) {
            t = ic.fromIcon(info.hIcon);
            _ = w.DestroyIcon(info.hIcon);
        }
        return ic.remember(lower, t);
    }

    pub fn drive(ic: *Icons, root: []const u8) ?Tex {
        var kb: [64]u8 = undefined;
        const key = std.mem.print(&kb, "drive:{s}", .{root}) catch return null;
        if (ic.map.get(key)) |t| return ref(t);
        const wp = kit.win.toW(ic.gpa, root) catch return null;
        defer ic.gpa.free(wp);
        var info = std.mem.zeroes(w.SHFILEINFOW);
        var t: u64 = 0;
        if (w.SHGetFileInfoW(wp.ptr, 0, &info, @sizeOf(w.SHFILEINFOW), w.SHGFI_ICON | w.SHGFI_SMALLICON) != 0 and info.hIcon != null) {
            t = ic.fromIcon(info.hIcon);
            _ = w.DestroyIcon(info.hIcon);
        }
        return ic.remember(key, t);
    }

    fn remember(ic: *Icons, key: []const u8, t: u64) ?Tex {
        const k = ic.gpa.dupe(u8, key) catch return ref(t);
        ic.map.put(ic.gpa, k, t) catch ic.gpa.free(k);
        return ref(t);
    }

    fn ref(t: u64) ?Tex {
        return if (t == 0) null else .{ ._TexData = null, ._TexID = t };
    }

    /// HICON -> 32-bit BGRA texture (alpha from the mask for old icons without one).
    fn fromIcon(ic: *Icons, icon: w.HICON) u64 {
        var ii: w.ICONINFO = undefined;
        if (w.GetIconInfo(icon, &ii) == 0) return 0;
        defer {
            if (ii.hbmColor != null) _ = w.DeleteObject(ii.hbmColor);
            if (ii.hbmMask != null) _ = w.DeleteObject(ii.hbmMask);
        }
        if (ii.hbmColor == null) return 0; // monochrome icon: not worth it
        var bm: w.BITMAP = undefined;
        if (w.GetObjectW(ii.hbmColor, @sizeOf(w.BITMAP), &bm) == 0) return 0;
        const wd: usize = @intCast(bm.bmWidth);
        const ht: usize = @intCast(bm.bmHeight);
        if (wd == 0 or ht == 0 or wd > 512 or ht > 512) return 0;
        const px = ic.gpa.alloc(u32, wd * ht) catch return 0;
        defer ic.gpa.free(px);
        var bi = std.mem.zeroes(w.BITMAPINFO);
        bi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = @intCast(wd);
        bi.bmiHeader.biHeight = -@as(i32, @intCast(ht));
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = w.BI_RGB;
        const dc = w.GetDC(null);
        defer _ = w.ReleaseDC(null, dc);
        if (w.GetDIBits(dc, ii.hbmColor, 0, @intCast(ht), px.ptr, &bi, w.DIB_RGB_COLORS) == 0) return 0;
        var has_alpha = false;
        for (px) |p| if (p >> 24 != 0) {
            has_alpha = true;
            break;
        };
        if (!has_alpha and ii.hbmMask != null) {
            const mask = ic.gpa.alloc(u32, wd * ht) catch return 0;
            defer ic.gpa.free(mask);
            if (w.GetDIBits(dc, ii.hbmMask, 0, @intCast(ht), mask.ptr, &bi, w.DIB_RGB_COLORS) != 0) {
                for (px, mask) |*p, mk| p.* = (p.* & 0xFFFFFF) | (if (mk & 0xFFFFFF == 0) @as(u32, 0xFF000000) else 0);
            }
        }
        return ic.texture(px, wd, ht);
    }

    fn texture(ic: *Icons, px: []const u32, wd: usize, ht: usize) u64 {
        const dev = ic.device;
        if (dev == null) return 0;
        var desc = std.mem.zeroes(w.D3D11_TEXTURE2D_DESC);
        desc.Width = @intCast(wd);
        desc.Height = @intCast(ht);
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = w.DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = w.D3D11_USAGE_DEFAULT;
        desc.BindFlags = w.D3D11_BIND_SHADER_RESOURCE;
        const sub: w.D3D11_SUBRESOURCE_DATA = .{ .pSysMem = px.ptr, .SysMemPitch = @intCast(wd * 4), .SysMemSlicePitch = 0 };
        var tex: [*c]w.ID3D11Texture2D = null;
        if (dev.*.lpVtbl.*.CreateTexture2D.?(dev, &desc, &sub, &tex) < 0) return 0;
        defer kit.win.release(tex);
        var srv: [*c]w.ID3D11ShaderResourceView = null;
        if (dev.*.lpVtbl.*.CreateShaderResourceView.?(dev, @ptrCast(tex), null, &srv) < 0) return 0;
        return @intFromPtr(srv);
    }

    /// icons\<name>.png through GDI+ (loaded on first use; gdiplus.dll ships with every Windows).
    fn fromPng(ic: *Icons, path: []const u8) u64 {
        if (ic.gdip == null) ic.gdip = Gdip.load() orelse return 0;
        const g = ic.gdip.?;
        const wp = kit.win.toW(ic.gpa, path) catch return 0;
        defer ic.gpa.free(wp);
        var bmp: ?*anyopaque = null;
        if (g.fromFile(wp.ptr, &bmp) != 0 or bmp == null) return 0; // a broken png: the stock one
        defer _ = g.dispose(bmp);
        var icon: w.HICON = null;
        if (g.toIcon(bmp, &icon) != 0 or icon == null) return 0;
        defer _ = w.DestroyIcon(icon);
        return ic.fromIcon(icon);
    }
};

/// Files that carry their own icon (ShellInfo.OwnIcon).
fn isOwnIcon(ext: []const u8) bool {
    for ([_][]const u8{ ".exe", ".ico", ".lnk", ".url", ".cur", ".ani", ".msc", ".scr" }) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

/// The four GDI+ flat-API calls a png needs, bound at run time.
const Gdip = struct {
    token: usize,
    shutdown: *const fn (usize) callconv(.winapi) void,
    fromFile: *const fn ([*:0]const u16, *?*anyopaque) callconv(.winapi) c_int,
    toIcon: *const fn (?*anyopaque, *w.HICON) callconv(.winapi) c_int,
    dispose: *const fn (?*anyopaque) callconv(.winapi) c_int,

    const Input = extern struct { version: u32 = 1, callback: ?*anyopaque = null, no_thread: c_int = 0, no_codecs: c_int = 0 };

    fn load() ?Gdip {
        const lib = w.LoadLibraryW(kit.win.L("gdiplus.dll")) orelse return null;
        const startup: *const fn (*usize, *const Input, ?*anyopaque) callconv(.winapi) c_int = @ptrCast(w.GetProcAddress(lib, "GdiplusStartup") orelse return null);
        var g: Gdip = .{
            .token = 0,
            .shutdown = @ptrCast(w.GetProcAddress(lib, "GdiplusShutdown") orelse return null),
            .fromFile = @ptrCast(w.GetProcAddress(lib, "GdipCreateBitmapFromFile") orelse return null),
            .toIcon = @ptrCast(w.GetProcAddress(lib, "GdipCreateHICONFromBitmap") orelse return null),
            .dispose = @ptrCast(w.GetProcAddress(lib, "GdipDisposeImage") orelse return null),
        };
        if (startup(&g.token, &.{}, null) != 0) return null;
        return g;
    }
};
