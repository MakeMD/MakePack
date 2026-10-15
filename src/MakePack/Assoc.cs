using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace MakePack;

/// <summary>Explorer menu items the user can switch off (Associations dialog). Missing value = all on.</summary>
[Flags]
enum MenuItems
{
    None = 0, Open = 1, ExtractHere = 2, ExtractTo = 4, Add = 8, QuickAdd = 16, New = 32,
    /// <summary>The items of the profiles marked "in menu" (each still needs that mark).</summary>
    Profiles = 64,
    All = Open | ExtractHere | ExtractTo | Add | QuickAdd | New | Profiles,
    /// <summary>What --addmenu on|off switches: the items on every file and folder.</summary>
    Files = Add | QuickAdd | New | Profiles,
}

/// <summary>Every registry write MakePack makes: ProgID, per-extension verbs, the "Add to archive" menu.</summary>
// ponytail: per-user (HKCU) only; all-users needs the same keys under HKLM plus elevation.
static class Assoc
{
    public const string ProgId = "MakePack.Archive";

    /// <summary>Everything 7z.dll opens, in the order the dialog lists them.</summary>
    public static readonly string[] All =
    [
        "7z", "zip", "zipx", "jar", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "tbz", "xz", "txz", "lzma", "z", "taz",
        "cab", "iso", "wim", "swm", "esd", "arj", "lzh", "lha", "cpio", "rpm", "deb", "udeb", "ar", "xar", "dmg",
        "vhd", "001", "ova",
    ];

    /// <summary>Types a default (non-forced) registration may claim - never .zip/.iso/.cab/.jar.</summary>
    public static readonly HashSet<string> Defaults = new(StringComparer.OrdinalIgnoreCase)
    {
        "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "tbz", "xz", "txz", "lzma", "z", "taz",
        "arj", "lzh", "lha", "cpio", "001", "ova",
    };

    /// <summary>Extensions whose UserChoice Windows refused to clear. Callers clear this before a batch.</summary>
    public static readonly List<string> Blocked = [];

    const string Classes = @"Software\Classes\";
    const string Root = @"Software\MakePack";   // also read by shell\MakePackShell.cpp: MenuItems, QuickExt
    const string Caps = @"Software\MakePack\Capabilities";
    const string Prev = @"Software\MakePack\Prev";
    const string FileExts = @"Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\";

    static string Exe => Environment.ProcessPath!;
    static string IconRef => $"\"{Exe}\",0";

    // ---- primitives ------------------------------------------------------------------------------

    static void Set(string key, string? name, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(key);
        k.SetValue(name ?? "", value);
    }

    static void DelValue(string key, string name)
    {
        try { using var k = Registry.CurrentUser.OpenSubKey(key, true); k?.DeleteValue(name, false); } catch { }
    }

    static void DelTree(string key)
    {
        try { Registry.CurrentUser.DeleteSubKeyTree(key, false); } catch { }
    }

    static string? Read(RegistryKey hive, string key, string name)
    {
        using var k = hive.OpenSubKey(key);
        return k?.GetValue(name) as string;
    }

    static void Verb(string key, string caption, string args)
    {
        Set(key, null, caption);
        Set(key, "Icon", IconRef);
        Set(key + @"\command", null, $"\"{Exe}\"{args}");
    }

    /// <summary>The verb when <paramref name="on"/>, no key at all when not.</summary>
    static void Toggle(string key, bool on, string caption, string args)
    {
        if (on) Verb(key, caption, args); else DelTree(key);
    }

    // ---- which menu items, and the quick-add format ---------------------------------------------

    public static MenuItems Menu
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(Root); return k?.GetValue("MenuItems") is int v ? (MenuItems)v & MenuItems.All : MenuItems.All; }
        set { using var k = Registry.CurrentUser.CreateSubKey(Root); k.SetValue("MenuItems", (int)value, RegistryValueKind.DWord); }
    }

    /// <summary>The format "Add to name.ext" packs into. Stored with its extension too, for the Windows 11 menu DLL.</summary>
    public static ArchiveKind QuickKind
    {
        get => Enum.TryParse<ArchiveKind>(Read(Registry.CurrentUser, Root, "QuickFormat"), out var k) && Engine.Kind(k).Multi ? k : ArchiveKind.SevenZip;
        set { Set(Root, "QuickFormat", value.ToString()); Set(Root, "QuickExt", Engine.Kind(value).Ext); }
    }

    /// <summary>
    /// Puts every menu entry in line with <see cref="Menu"/>: the archive verbs of the types MakePack is registered
    /// for, the ProgID's own verbs, and the file/folder items. Call after changing Menu or QuickKind.
    /// </summary>
    public static void ApplyMenu()
    {
        var m = Menu;
        QuickKind = QuickKind;   // writes QuickExt for the DLL even when nobody ever picked a format
        foreach (var ext in All)
            if (Read(Registry.CurrentUser, Classes + "." + ext + @"\OpenWithProgids", ProgId) != null) ExtVerbs(ext, m);
        using (var p = Registry.CurrentUser.OpenSubKey(Classes + ProgId)) if (p != null) ProgIdVerbs(m);
        foreach (var key in FileKeys("Add")) Toggle(key, m.HasFlag(MenuItems.Add), S.VerbAddTo, " a \"%1\"");
        foreach (var key in FileKeys("QuickAdd"))
            Toggle(key, m.HasFlag(MenuItems.QuickAdd), string.Format(S.VerbQuickAddFmt, Engine.Kind(QuickKind).Ext), " a --quick \"%1\"");
        foreach (var key in FileKeys("Add").Concat(FileKeys("QuickAdd")))
            if (Registry.CurrentUser.OpenSubKey(key) is { } k) { k.Dispose(); Set(key, "MultiSelectModel", "Player"); }   // one call per item: MakePack merges them
        ShellNew(m.HasFlag(MenuItems.New));
        ApplyProfiles();
    }

    // ---- the profiles' own items ----------------------------------------------------------------

    const string MenuProfilesKey = Root + @"\MenuProfiles";   // MenuProfiles\01..: Name, Ext, Separate - read by the DLL

    /// <summary>
    /// One "Add to ext - profile" item per profile marked "in menu" (classic: *\shell\MakePack.P01..., running
    /// `a --profile "name"`), plus their list for the Windows 11 menu. Rewritten whole on every call; writes
    /// nothing at all while no profile is in the menu. Call after profiles or <see cref="Menu"/> change.
    /// </summary>
    public static void ApplyProfiles()
    {
        ClearProfiles();
        if (!Menu.HasFlag(MenuItems.Profiles)) return;
        var list = Settings.Current.Profiles.Where(p => p.InMenu && !p.Name.Contains('"')).ToList();   // a quote would end the name in the command line
        for (var i = 0; i < list.Count; i++)
        {
            var p = list[i];
            var id = (i + 1).ToString("D2");   // zero-padded: the DLL lists the subkeys in name order
            var caption = string.Format(p.Separate ? S.VerbProfileSeparateFmt : S.VerbProfileFmt, p.Ext, p.Name);
            foreach (var key in ProfileKeys(id))
            {
                Verb(key, caption, $" a --profile \"{p.Name}\" \"%1\"");
                Set(key, "MultiSelectModel", "Player");   // one call per item: MakePack merges them into one archive
            }
            Set(MenuProfilesKey + @"\" + id, "Name", p.Name);
            Set(MenuProfilesKey + @"\" + id, "Ext", p.Ext);
            Set(MenuProfilesKey + @"\" + id, "Separate", p.Separate ? "1" : "0");
        }
    }

    static string[] ProfileKeys(string id) => [Classes + @"*\shell\MakePack.P" + id, Classes + @"Directory\shell\MakePack.P" + id];

    static void ClearProfiles()
    {
        foreach (var parent in new[] { Classes + @"*\shell", Classes + @"Directory\shell" })
        {
            using var k = Registry.CurrentUser.OpenSubKey(parent, true);
            if (k == null) continue;
            foreach (var name in k.GetSubKeyNames().Where(n => n.StartsWith("MakePack.P", StringComparison.Ordinal)))
                k.DeleteSubKeyTree(name, false);
        }
        DelTree(MenuProfilesKey);
    }

    static string[] FileKeys(string verb) => [Classes + @"*\shell\MakePack." + verb, Classes + @"Directory\shell\MakePack." + verb];

    static void ExtVerbs(string ext, MenuItems m)
    {
        var shell = Classes + @"SystemFileAssociations\." + ext + @"\shell\MakePack.";
        Toggle(shell + "Open", m.HasFlag(MenuItems.Open), S.VerbOpenWith, " \"%1\"");
        Toggle(shell + "ExtractHere", m.HasFlag(MenuItems.ExtractHere), S.VerbExtractHere, " x \"%1\" --here");
        Toggle(shell + "ExtractTo", m.HasFlag(MenuItems.ExtractTo), S.VerbExtractTo, " x \"%1\" --sub");
    }

    static void ProgIdVerbs(MenuItems m)
    {
        var p = Classes + ProgId + @"\shell\MakePack.";
        Toggle(p + "ExtractHere", m.HasFlag(MenuItems.ExtractHere), S.VerbExtractHere, " x \"%1\" --here");
        Toggle(p + "ExtractTo", m.HasFlag(MenuItems.ExtractTo), S.VerbExtractTo, " x \"%1\" --sub");
    }

    // ---- Explorer's New > MakePack archive ------------------------------------------------------

    /// <summary>An empty 7z: signature, version 0.4, start-header CRC of 20 zero bytes, no next header.</summary>
    public static readonly byte[] EmptySevenZip =
    [
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x8D, 0x9B, 0xD5, 0x0F,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ];

    /// <summary>Under our ProgID, not .7z itself: Explorer only looks there while .7z is MakePack's.</summary>
    const string ShellNewKey = Classes + @".7z\" + ProgId;

    /// <summary>
    /// .7z\MakePack.Archive\ShellNew with the empty archive as its data. Explorer lists it as "MakePack archive" only
    /// while .7z belongs to MakePack - under .7z\ShellNew it would be named after whoever owns .7z (measured: a
    /// second "OtherArc archive" next to own), and someone else's ShellNew could sit there.
    /// </summary>
    static void ShellNew(bool on)
    {
        if (!on) { DelTree(ShellNewKey); return; }
        using var w = Registry.CurrentUser.CreateSubKey(ShellNewKey + @"\ShellNew");
        w.SetValue("Data", EmptySevenZip, RegistryValueKind.Binary);
    }

    // ---- ProgID ----------------------------------------------------------------------------------

    /// <summary>Idempotent; always rewrites the exe path (the app may have been moved or reinstalled).</summary>
    public static void RegisterProgId()
    {
        var p = Classes + ProgId;
        Set(p, null, S.ProgIdDesc);
        Set(p + @"\DefaultIcon", null, IconRef);
        Set(p + @"\shell\open\command", null, $"\"{Exe}\" \"%1\"");
        ProgIdVerbs(Menu);
        Set(Caps, "ApplicationName", S.App);
        Set(Caps, "ApplicationDescription", S.ProgIdDesc);
        Set(@"Software\RegisteredApplications", "MakePack", Caps);
    }

    /// <summary>
    /// Repairs a half-removed registration: extensions still pointing at MakePack.Archive while the
    /// ProgID itself, its Capabilities or its exe are gone (an --unregister that raced an install, or
    /// the app was moved). Registry reads only when there is nothing to fix.
    /// </summary>
    // ponytail: a ProgID that merely lives somewhere else is another copy of MakePack running, not
    // damage - a portable or dev build must not hijack an installed one, so it is left alone.
    public static void Heal()
    {
        var exe = ExeOf(Read(Registry.CurrentUser, Classes + ProgId + @"\shell\open\command", "") ?? "");
        if (exe.Length > 0 && File.Exists(exe)
            && Read(Registry.CurrentUser, @"Software\RegisteredApplications", "MakePack") is { Length: > 0 }) return;
        if (All.Any(IsOurs)) RegisterProgId();
    }

    // ---- who owns an extension -------------------------------------------------------------------

    /// <param name="Dead">The owner's open command points at an exe that is not there any more.</param>
    /// <param name="UserChoice">Explorer has an explicit user choice for some other app.</param>
    /// <param name="ChoiceDead">...and that choice points at a ProgID/exe that is gone (uninstalled app).</param>
    public static (string? ProgId, bool Dead, bool UserChoice, bool ChoiceDead) Owner(string ext)
    {
        var owner = Read(Registry.ClassesRoot, "." + ext, "");   // HKCR = HKCU over HKLM, which is what Explorer sees
        var dead = !string.IsNullOrEmpty(owner) && Dead(owner);
        var choice = Read(Registry.CurrentUser, FileExts + "." + ext + @"\UserChoice", "ProgId");
        var foreign = !string.IsNullOrEmpty(choice) && choice != ProgId;
        return (owner, dead, foreign, foreign && Dead(choice!));
    }

    /// <summary>A ProgID that no longer exists, or whose open command names an exe that is gone.</summary>
    static bool Dead(string progId)
    {
        using var k = Registry.ClassesRoot.OpenSubKey(progId);
        if (k == null) return true;
        var cmd = Read(Registry.ClassesRoot, progId + @"\shell\open\command", "");
        if (string.IsNullOrWhiteSpace(cmd)) return false;      // DelegateExecute / packaged apps: not ours to judge
        var exe = ExeOf(cmd);
        return exe.Length > 0 && !File.Exists(exe);
    }

    /// <summary>The exe out of a shell command line: the first quoted token, else everything up to the first space.</summary>
    static string ExeOf(string command)
    {
        command = Environment.ExpandEnvironmentVariables(command.Trim());
        if (command.StartsWith('"'))
        {
            var end = command.IndexOf('"', 1);
            return end > 0 ? command[1..end] : command.Trim('"');
        }
        var space = command.IndexOf(' ');
        return space > 0 ? command[..space] : command;
    }

    public static bool IsOurs(string ext) => Read(Registry.ClassesRoot, "." + ext, "") == ProgId;

    // ---- register / unregister one extension -----------------------------------------------------

    /// <summary>Verbs + Open-with always; the default handler when <paramref name="force"/> or nobody usable owns it.</summary>
    /// <returns>True when MakePack became the default handler for the extension.</returns>
    public static bool Register(string ext, bool force)
    {
        RegisterProgId();
        Set(Caps + @"\FileAssociations", "." + ext, ProgId);
        Set(Classes + "." + ext + @"\OpenWithProgids", ProgId, "");
        ExtVerbs(ext, Menu);

        // Unforced: only free (unowned, or owned by an uninstalled app) extensions, and .zip & co. only when dead.
        var o = Owner(ext);
        if (!(force || o.Dead || (string.IsNullOrEmpty(o.ProgId) && Defaults.Contains(ext)))) return false;

        if (Read(Registry.CurrentUser, Classes + "." + ext, "") is { Length: > 0 } prev && prev != ProgId)
            Set(Prev, "." + ext, prev);
        Set(Classes + "." + ext, null, ProgId);

        // A live UserChoice overrides HKCR, so it has to go when forced; a dead one (app uninstalled) always goes.
        // Windows puts a deny-SetValue ACE on UserChoice; deleting the key needs only DELETE and usually works.
        if (o.UserChoice && (force || o.ChoiceDead))
            try { Registry.CurrentUser.OpenSubKey(FileExts + "." + ext, true)?.DeleteSubKey("UserChoice", false); }
            catch { Blocked.Add(ext); }
        return true;
    }

    public static void Unregister(string ext)
    {
        var shell = Classes + @"SystemFileAssociations\." + ext + @"\shell\MakePack.";
        foreach (var v in new[] { "Open", "ExtractHere", "ExtractTo" }) DelTree(shell + v);
        DelValue(Classes + "." + ext + @"\OpenWithProgids", ProgId);
        DelValue(Caps + @"\FileAssociations", "." + ext);

        using var k = Registry.CurrentUser.OpenSubKey(Classes + "." + ext, true);
        if (k?.GetValue("") as string != ProgId) return;       // never touch someone else's default
        if (Read(Registry.CurrentUser, Prev, "." + ext) is { } prev) k.SetValue("", prev);
        else k.DeleteValue("", false);
        DelValue(Prev, "." + ext);
    }

    // ---- the items on every file and folder (--addmenu, the installer's "context menu" task) -----

    public static void SetAddMenu(bool on)
    {
        Menu = on ? Menu | MenuItems.Files : Menu & ~MenuItems.Files;
        ApplyMenu();
    }

    public static void UnregisterAll()
    {
        foreach (var ext in All) Unregister(ext);
        foreach (var key in FileKeys("Add").Concat(FileKeys("QuickAdd"))) DelTree(key);
        ShellNew(false);
        ClearProfiles();
        DelTree(Classes + ProgId);
        DelTree(@"Software\MakePack");
        DelValue(@"Software\RegisteredApplications", "MakePack");
    }

    // ---- tell Explorer ---------------------------------------------------------------------------

    [DllImport("shell32.dll")] static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    /// <summary>Call once after a batch of changes, never per extension.</summary>
    public static void Notify()
    {
        try { SHChangeNotify(0x08000000 /* SHCNE_ASSOCCHANGED */, 0, IntPtr.Zero, IntPtr.Zero); } catch { }
    }
}
