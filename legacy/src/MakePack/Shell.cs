using System.Runtime.InteropServices;

namespace MakePack;

/// <summary>
/// Toolbar and status-bar pictures: icons\&lt;name&gt;.png next to the exe when the user has drawn one
/// (docs/ICONS-NEEDED.md), else a Windows stock icon. Null when neither is there - the button keeps its text.
/// </summary>
static class Icons
{
    static readonly Dictionary<string, Image?> Cache = [];

    public static Image? Get(string name, int siid, int px)
    {
        var key = $"{name}@{px}";
        if (Cache.TryGetValue(key, out var hit)) return hit;
        Image? img = null;
        var file = Path.Combine(AppContext.BaseDirectory, "icons", name + ".png");
        try { if (File.Exists(file)) using (var raw = Image.FromFile(file)) img = new Bitmap(raw, px, px); } catch { /* a broken png: the stock one */ }
        img ??= Stock(siid, px);
        return Cache[key] = img;
    }

    static Image? Stock(int siid, int px)
    {
        if (siid < 0) return null;
        var info = new SHSTOCKICONINFO { cbSize = Marshal.SizeOf<SHSTOCKICONINFO>() };
        // SHGSI_ICON | (SHGSI_SMALLICON for 16 px, the large one otherwise)
        if (SHGetStockIconInfo(siid, px <= 16 ? 0x101 : 0x100, ref info) != 0 || info.hIcon == IntPtr.Zero) return null;
        try { using var icon = Icon.FromHandle(info.hIcon); using var bmp = icon.ToBitmap(); return new Bitmap(bmp, px, px); }
        finally { DestroyIcon(info.hIcon); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHSTOCKICONINFO
    {
        public int cbSize;
        public IntPtr hIcon;
        public int iSysImageIndex;
        public int iIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szPath;
    }

    [DllImport("shell32.dll")] static extern int SHGetStockIconInfo(int siid, int flags, ref SHSTOCKICONINFO info);
    [DllImport("user32.dll")] internal static extern bool DestroyIcon(IntPtr icon);
}

/// <summary>
/// Small file icons and type names the way Explorer shows them, cached per extension (per path for files that
/// carry their own icon). One ImageList shared by the list and the tree.
/// </summary>
// ponytail: our own ImageList instead of the system image list via LVM_SETIMAGELIST - WinForms does not know
// an image list it did not create. The cache grows with the extensions seen, a few hundred at most.
static class ShellInfo
{
    public static readonly ImageList Images = new() { ImageSize = new Size(16, 16), ColorDepth = ColorDepth.Depth32Bit };
    static readonly Dictionary<string, (int Image, string Type)> Cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> OwnIcon = new(StringComparer.OrdinalIgnoreCase) { ".exe", ".ico", ".lnk", ".url", ".cur", ".ani", ".msc", ".scr" };

    /// <param name="name">A file or folder name (archive entries) or a full path (disk).</param>
    /// <param name="onDisk">The path exists: files with their own icon (exe, lnk...) get it.</param>
    public static (int Image, string Type) Of(string name, bool folder, bool onDisk = false)
    {
        var ext = folder ? "\\folder" : Path.GetExtension(name);
        var real = onDisk && !folder && OwnIcon.Contains(ext);
        var key = real ? name : ext.Length == 0 && !folder ? "\\noext" : ext;
        if (Cache.TryGetValue(key, out var hit)) return hit;

        const uint SHGFI_ICON = 0x100, SHGFI_TYPENAME = 0x400, SHGFI_SMALLICON = 0x1, SHGFI_USEFILEATTRIBUTES = 0x10;
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_NORMAL = 0x80;
        var info = new SHFILEINFO();
        var flags = SHGFI_ICON | SHGFI_SMALLICON | SHGFI_TYPENAME | (real ? 0 : SHGFI_USEFILEATTRIBUTES);
        var probe = real ? name : folder ? "folder" : "file" + ext;
        var r = (Image: -1, Type: folder ? S.FolderType : ext.TrimStart('.').ToUpperInvariant());
        if (SHGetFileInfo(probe, folder ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), flags) != IntPtr.Zero)
        {
            if (info.szTypeName.Length > 0) r.Type = info.szTypeName;
            if (info.hIcon != IntPtr.Zero)
            {
                using (var icon = Icon.FromHandle(info.hIcon)) Images.Images.Add(icon.ToBitmap());
                Icons.DestroyIcon(info.hIcon);
                r.Image = Images.Images.Count - 1;
            }
        }
        return Cache[key] = r;
    }

    /// <summary>The image index of a drive's icon (the tree's roots).</summary>
    public static int Drive(string root)
    {
        if (Cache.TryGetValue(root, out var hit)) return hit.Image;
        var info = new SHFILEINFO();
        var r = (Image: -1, Type: root);
        if (SHGetFileInfo(root, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), 0x100 | 0x1 | 0x200 /* ICON|SMALLICON|DISPLAYNAME */) != IntPtr.Zero
            && info.hIcon != IntPtr.Zero)
        {
            using (var icon = Icon.FromHandle(info.hIcon)) Images.Images.Add(icon.ToBitmap());
            Icons.DestroyIcon(info.hIcon);
            r = (Images.Images.Count - 1, info.szDisplayName);
        }
        Cache[root] = r;
        return r.Image;
    }

    /// <summary>"Local Disk (C:)" - what Explorer calls a drive.</summary>
    public static string DriveName(string root) { Drive(root); return Cache[root].Type; }

    /// <summary>Explorer's own Properties sheet (Info on something that is not an archive).</summary>
    public static void Properties(string path) => SHObjectProperties(IntPtr.Zero, 2 /* SHOP_FILEPATH */, path, null);

    /// <summary>
    /// Copies (or moves) files into a folder with the shell's own progress and "file exists" dialogs,
    /// so a paste behaves exactly as it would in Explorer. False when the user cancelled or it failed.
    /// </summary>
    public static bool Copy(IWin32Window owner, IEnumerable<string> paths, string destDir, bool move)
    {
        const uint FO_MOVE = 1, FO_COPY = 2;
        const ushort FOF_ALLOWUNDO = 0x40, FOF_RENAMEONCOLLISION = 0x8;
        var list = paths.Select(p => Path.GetFullPath(p.TrimEnd('\\', '/'))).ToList();
        if (list.Count == 0) return true;
        // Pasting a folder's own files back into it: Explorer makes "name - Copy"; so do we.
        var same = list.All(p => Engine.SamePath(Path.GetDirectoryName(p) ?? "", destDir));
        var op = new Engine.SHFILEOPSTRUCT
        {
            hwnd = owner.Handle,
            wFunc = move ? FO_MOVE : FO_COPY,
            pFrom = string.Join("\0", list) + "\0\0",
            pTo = destDir + "\0\0",
            fFlags = (ushort)(FOF_ALLOWUNDO | (same && !move ? FOF_RENAMEONCOLLISION : 0)),
        };
        return Engine.SHFileOperation(ref op) == 0 && op.fAnyOperationsAborted == 0;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern bool SHObjectProperties(IntPtr hwnd, uint type, string name, string? page);
}
