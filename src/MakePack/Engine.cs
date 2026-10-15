using System.Runtime.InteropServices;
using SevenZip;
// Engine.Probe() the method hides Probe the enum inside Engine, so the type travels under an alias in this file.
using ProbeResult = MakePack.Probe;

namespace MakePack;

enum OverwriteMode { Ask, Overwrite, Skip, Rename }

/// <summary>What the bytes of a file say it is. Told apart here so each case gets its own message.</summary>
enum Probe { NotArchive, Damaged, Archive, EncryptedHeaders }

/// <summary>
/// Which extracted files inherit the archive's "downloaded from the Internet" mark (its Zone.Identifier stream):
/// none, the ones that can run code (executables, scripts, Office documents, nested archives), or all.
/// </summary>
enum MotwPolicy { Never, Risky, All }

/// <summary>Replace: every file (clashes go to the overwrite mode). Newer: new files, and ones newer than on disk.
/// Existing: only files already on disk, and only when the archived copy is newer ("freshen").</summary>
enum UpdateMode { Replace, Newer, Existing }

/// <summary>What happens to the archive once everything in it was extracted without an error.</summary>
enum DeleteAfter { Never, Ask, Recycle }

/// <summary>The extract dialog's choices on top of the overwrite mode.</summary>
/// <param name="NoPaths">Every file straight into the destination, folders dropped; name clashes go to the overwrite mode.</param>
/// <param name="KeepBroken">Leave a file that failed its check on disk ("Keep broken files"); by default it is removed.</param>
sealed record ExtractOptions(bool NoPaths = false, UpdateMode Update = UpdateMode.Replace, bool KeepBroken = false)
{
    public static readonly ExtractOptions Default = new();
}

enum ArchiveKind { SevenZip, Zip, Tar, TarGz, TarBz2, TarXz, GZip, BZip2, XZ, Wim }

/// <param name="Multi">false = the format holds exactly one file (gz/bz2/xz).</param>
sealed record KindInfo(ArchiveKind Kind, string Name, string Ext, OutArchiveFormat Format, bool Multi, bool Password);

/// <summary>How to compress. A new knob (volumes, SFX...) is a field here, not a new parameter.</summary>
/// <param name="Password">null = none. Append ignores Password and EncryptHeaders: the archive keeps its own.</param>
/// <param name="Method">Default = the format's own (LZMA2 for 7z, Deflate for zip). See Engine.MethodsFor.</param>
/// <param name="Dictionary">Bytes, 0 = the level's default. LZMA/LZMA2 only.</param>
/// <param name="Solid">7z only: 7-Zip's s= value ("off", or a block size like "256m"); null = the level's default.</param>
/// <param name="Threads">0 = all cores.</param>
/// <param name="Filter">7z only: 7-Zip's f= value ("off", "BCJ2", "ARM64"); null = auto by file type.</param>
/// <param name="VolumeSize">Bytes per part, 0 = one file. Parts are name.001, name.002... (7-Zip's split format).</param>
/// <param name="TestAfter">Test the finished archive; a failed test is an error.</param>
/// <param name="DeleteSources">Send the inputs to the Recycle Bin - only once the archive is written (and tested, if asked).</param>
/// <param name="Sfx">7z only, no volumes: prepend 7-Zip's GUI SFX stub, so the output is a self-extracting .exe.</param>
/// <param name="ZipCrypto">Zip only: the old PKWARE encryption Windows Explorer can open, instead of AES-256 (which it cannot).</param>
sealed record CompressOptions(CompressionLevel Level = CompressionLevel.Normal, string? Password = null,
                              bool EncryptHeaders = false, CompressionMethod Method = CompressionMethod.Default,
                              long Dictionary = 0, string? Solid = null, int Threads = 0, string? Filter = null,
                              long VolumeSize = 0, bool TestAfter = false, bool DeleteSources = false, bool Sfx = false,
                              bool ZipCrypto = false)
{
    public static readonly CompressOptions Default = new();
}

/// <summary>An opened archive. For x.tar.gz the extractor holds the inner .tar (see Engine.Open).</summary>
sealed class Archive : IDisposable
{
    public required SevenZipExtractor X { get; init; }
    public required string Source { get; init; }     // what the user opened
    public required string OpenPath { get; init; }   // what the extractor has open (temp .tar when nested)
    public string? Password { get; init; }
    public string? TempDir { get; init; }            // set when nested
    public bool Nested => TempDir != null;
    public string Display => Path.GetFileName(Source);
    public void Dispose() { X.Dispose(); if (TempDir != null) Engine.Nuke(TempDir); }
}

/// <summary>The job finished but left something out (exit code 1).</summary>
sealed class WarningException(string message) : IOException(message);

static class Engine
{
    static readonly List<string> Temps = [];

    static Engine()
    {
        SevenZipBase.SetLibraryPath(Path.Combine(AppContext.BaseDirectory, "7z.dll"));
        AppDomain.CurrentDomain.ProcessExit += (_, _) => { lock (Temps) foreach (var t in Temps) Nuke(t); };
    }

    public static readonly IProgress<(int percent, string file)> NoProgress = new Silent();
    sealed class Silent : IProgress<(int, string)> { public void Report((int, string) v) { } }

    public static readonly KindInfo[] Kinds =
    [
        new(ArchiveKind.SevenZip, "7z",      ".7z",      OutArchiveFormat.SevenZip, true,  true),
        new(ArchiveKind.Zip,      "zip",     ".zip",     OutArchiveFormat.Zip,      true,  true),
        new(ArchiveKind.Tar,      "tar",     ".tar",     OutArchiveFormat.Tar,      true,  false),
        new(ArchiveKind.TarGz,    "tar.gz",  ".tar.gz",  OutArchiveFormat.GZip,     true,  false),
        new(ArchiveKind.TarBz2,   "tar.bz2", ".tar.bz2", OutArchiveFormat.BZip2,    true,  false),
        new(ArchiveKind.TarXz,    "tar.xz",  ".tar.xz",  OutArchiveFormat.XZ,       true,  false),
        new(ArchiveKind.GZip,     "gz",      ".gz",      OutArchiveFormat.GZip,     false, false),
        new(ArchiveKind.BZip2,    "bz2",     ".bz2",     OutArchiveFormat.BZip2,    false, false),
        new(ArchiveKind.XZ,       "xz",      ".xz",      OutArchiveFormat.XZ,       false, false),
        new(ArchiveKind.Wim,      "wim",     ".wim",     OutArchiveFormat.Wim,      true,  false),
    ];

    public static KindInfo Kind(ArchiveKind k) => Kinds.First(i => i.Kind == k);

    static readonly string[] TarballExts = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz"];

    /// <summary>parts.7z.001: the first slice of a split set. Its signature says 7z, but the rest lives in .002...</summary>
    static bool IsFirstPart(string path) => path.EndsWith(".001", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Split sets are glued here instead of through 7z.dll's Split handler: SevenZipSharp's volume callback serves
    /// .002 onwards twice (a 4-part set comes back ~1.7x too long), which 7z and zip shrug off and gz does not.
    /// </summary>
    static void Join(string firstPart, string joined)
    {
        var stem = firstPart[..^4];
        Glue(Enumerable.Range(1, int.MaxValue - 1).Select(n => Part(stem, n)).TakeWhile(File.Exists), joined);
    }

    /// <summary>Archive name without its archive extension(s): "x.tar.gz" -> "x", "x.zip" -> "x".</summary>
    public static string BaseName(string fileName)
    {
        fileName = Path.GetFileName(fileName);
        foreach (var e in TarballExts)
            if (fileName.EndsWith(e, StringComparison.OrdinalIgnoreCase)) return fileName[..^e.Length];
        return Path.GetFileNameWithoutExtension(fileName);
    }

    /// <summary>Opens the archive, unwrapping containers that hold one archive: x.tar.gz, parts.7z.001, x.tar.gz.001...</summary>
    public static Archive Open(string path, string? password)
    {
        var openPath = path;
        string? dir = null;
        if (IsFirstPart(path))
        {
            dir = NewTempDir();
            openPath = Path.Combine(dir, Path.GetFileNameWithoutExtension(path));   // parts.7z.001 -> parts.7z
            try { Join(path, openPath); } catch { Nuke(dir); throw; }
        }
        SevenZipExtractor x;
        try { x = Extractor(openPath, password); } catch { if (dir != null) Nuke(dir); throw; }
        try
        {
            for (var depth = 0; ; depth++)
            {
                var data = x.ArchiveFileData; // forces the header read -> bad password / corrupt file throws here
                // ponytail: 3 levels covers split -> gz -> tar; deeper nesting is shown as the file it is.
                if (depth == 3 || !InnerArchive(openPath, x, data, out var innerName))
                    return new Archive { X = x, Source = path, OpenPath = openPath, Password = password, TempDir = dir };

                dir ??= NewTempDir();
                var inner = Path.Combine(dir, depth.ToString(), innerName);
                Directory.CreateDirectory(Path.GetDirectoryName(inner)!);
                using (var fs = File.Create(inner)) x.ExtractFile(data[0].Index, fs);
                x.Dispose();
                x = new SevenZipExtractor(inner);
                openPath = inner;
            }
        }
        catch { x.Dispose(); if (dir != null) Nuke(dir); throw; }
    }

    static SevenZipExtractor Extractor(string path, string? password) =>
        string.IsNullOrEmpty(password) ? new SevenZipExtractor(path) : new SevenZipExtractor(path, password);

    /// <summary>
    /// A fresh extractor for the same file. 7z.dll hands out apartment-bound COM objects, so the one
    /// <see cref="Archive.X"/> holds (created on the UI thread) cannot be used from a worker thread.
    /// </summary>
    static SevenZipExtractor Reopen(Archive a) => Extractor(a.OpenPath, a.Password);

    /// <summary>True when the archive is a container holding exactly one archive (x.tar.gz, x.tgz, parts.7z.001, ...).</summary>
    static bool InnerArchive(string path, SevenZipExtractor x, IList<ArchiveFileInfo> data, out string innerName)
    {
        innerName = "";
        if (data.Count != 1) return false;
        if (x.Format is not (InArchiveFormat.GZip or InArchiveFormat.BZip2 or InArchiveFormat.XZ
            or InArchiveFormat.Lzma or InArchiveFormat.Lzma86 or InArchiveFormat.Lzw or InArchiveFormat.Split)) return false;

        var entry = Path.GetFileName(data[0].FileName ?? "");   // Split reports a full path
        var outer = Path.GetFileName(path);
        if (Nestable(entry)) { innerName = entry; return true; }
        if (!TarballExts.Any(e => outer.EndsWith(e, StringComparison.OrdinalIgnoreCase))) return false;
        innerName = BaseName(outer) + ".tar";
        return true;
    }

    /// <summary>An inner entry worth opening in turn: a .tar or anything with a known archive extension.</summary>
    static bool Nestable(string name) => name.EndsWith(".tar", StringComparison.OrdinalIgnoreCase)
        || Assoc.All.Contains(Path.GetExtension(name).TrimStart('.'), StringComparer.OrdinalIgnoreCase);

    // ---- what is this file? --------------------------------------------------------------------
    // The library throws one and the same exception for "not an archive", "truncated" and "needs a password",
    // so the three are told apart here, from the bytes, before it ever gets asked.

    static readonly (long Offset, byte[] Bytes) Sig7z = (0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]);
    static readonly (long Offset, byte[] Bytes) SigRar4 = (0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);
    static readonly (long Offset, byte[] Bytes) SigRar5 = (0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

    /// <summary>Offset -> bytes that must be there. A negative offset counts back from the end of the file.</summary>
    // ponytail: the formats that carry a signature, minus the three above (which are probed further).
    // Something 7z.dll could still open but that is not listed (msi, exe/nsis, udf, ...) is answered
    // "not an archive" - add its magic here when someone asks for it.
    static readonly (long Offset, byte[] Bytes)[] Signatures =
    [
        (0, [0x50, 0x4B, 0x03, 0x04]), (0, [0x50, 0x4B, 0x05, 0x06]), (0, [0x50, 0x4B, 0x07, 0x08]),   // zip
        (0, [0x1F, 0x8B]),                                              // gzip
        (0, [0x42, 0x5A, 0x68]),                                        // bzip2
        (0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),                      // xz
        (0, [0x1F, 0x9D]),                                              // compress (.z)
        (0, [0x4D, 0x53, 0x43, 0x46]),                                  // cab
        (0, [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]),          // wim
        (0, [0x60, 0xEA]),                                              // arj
        (2, [0x2D, 0x6C, 0x68]),                                        // lzh
        (0, [0x30, 0x37, 0x30, 0x37, 0x30]), (0, [0xC7, 0x71]), (0, [0x71, 0xC7]),   // cpio
        (0, [0xED, 0xAB, 0xEE, 0xDB]),                                  // rpm
        (0, [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A]),          // deb / ar
        (0, [0x78, 0x61, 0x72, 0x21]),                                  // xar
        (0, "conectix"u8.ToArray()), (-512, "conectix"u8.ToArray()),    // vhd
        (-512, "koly"u8.ToArray()),                                     // dmg
        (32769, "CD001"u8.ToArray()),                                   // iso
        (32769, "BEA01"u8.ToArray()),                                   // udf
        (257, "ustar"u8.ToArray()),                                     // tar
        (0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),          // compound: msi, msp
        (0, "ITSF"u8.ToArray()),                                        // chm
        (0, [0x4D, 0x5A]),                                              // exe/dll: SFX, installers (7z.dll reads PE)
    ];

    static readonly (long Offset, byte[] Bytes) SigPe = (0, [0x4D, 0x5A]);

    /// <summary>Formats with no signature at all: only the name can vouch for them (".001" is answered earlier).</summary>
    static readonly string[] NoSignature = ["tar", "lzma"];

    /// <summary>Damaged, not an archive, or an archive - and if so, whether its file list is behind a password.</summary>
    public static ProbeResult Probe(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.');
        // A split volume holds the first slice of an archive: the 7z signature is there but the next header
        // lives in another part, so the structure check below would call every parts.7z.001 damaged.
        if (IsFirstPart(path)) return ProbeResult.Archive;
        try
        {
            using var fs = File.OpenRead(path);
            if (Matches(fs, Sig7z)) return SevenZipStructure(fs);
            if (Matches(fs, SigRar4)) return Rar4Encrypted(At(fs, 7, 7)) ? ProbeResult.EncryptedHeaders : ProbeResult.Archive;
            if (Matches(fs, SigRar5)) return Rar5Encrypted(At(fs, 8, 16)) ? ProbeResult.EncryptedHeaders : ProbeResult.Archive;
            if (Signatures.Any(s => Matches(fs, s))) return ProbeResult.Archive;
            return NoSignature.Contains(ext, StringComparer.OrdinalIgnoreCase) ? ProbeResult.Archive : ProbeResult.NotArchive;
        }
        catch { return ProbeResult.Archive; }   // unreadable: let Engine.Open report the real Windows error
    }

    /// <summary>Only 7z and rar can hide their file list behind a password; any other open failure is real.</summary>
    public static bool CanEncryptHeaders(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            return Matches(fs, Sig7z) || Matches(fs, SigRar4) || Matches(fs, SigRar5) || (Matches(fs, SigPe) && SfxSevenZip(fs));
        }
        catch { return false; }
    }

    /// <summary>
    /// A 7z start header somewhere after an exe stub: the signature plus a start-header CRC that checks out
    /// (the signature alone turns up by chance in big binaries). That is what a 7z SFX looks like.
    /// </summary>
    // ponytail: only the first 4 MB are searched - 7-Zip's own stubs are ~200 KB, installers with bigger ones are not SFX we make.
    static bool SfxSevenZip(FileStream fs)
    {
        var head = At(fs, 0, (int)Math.Min(fs.Length, 4 << 20));
        var sig = Sig7z.Bytes;
        for (var i = head.AsSpan().IndexOf(sig); i >= 0 && i + 32 <= head.Length; )
        {
            if (Crc32(fs, i + 12, 20) == BitConverter.ToUInt32(head, i + 8)) return true;
            var next = head.AsSpan(i + 1).IndexOf(sig);
            i = next < 0 ? -1 : i + 1 + next;
        }
        return false;
    }

    /// <summary><paramref name="count"/> bytes at <paramref name="offset"/> (negative = from the end), or empty.</summary>
    static byte[] At(FileStream fs, long offset, int count)
    {
        if (offset < 0) offset += fs.Length;
        if (offset < 0 || count <= 0 || offset + count > fs.Length) return [];
        fs.Position = offset;
        var b = new byte[count];
        fs.ReadExactly(b);
        return b;
    }

    static bool Matches(FileStream fs, (long Offset, byte[] Bytes) sig)
        => At(fs, sig.Offset, sig.Bytes.Length).AsSpan().SequenceEqual(sig.Bytes);

    /// <summary>
    /// The 32-byte 7z start header is self-checking and says where the next header (the file list) is:
    /// signature(6) version(2) StartHeaderCRC(4) NextHeaderOffset(8) NextHeaderSize(8) NextHeaderCRC(4).
    /// </summary>
    static ProbeResult SevenZipStructure(FileStream fs)
    {
        var head = At(fs, 0, 32);
        if (head.Length < 32 || Crc32(fs, 12, 20) != BitConverter.ToUInt32(head, 8)) return ProbeResult.Damaged;
        var offset = BitConverter.ToUInt64(head, 12);
        var size = BitConverter.ToUInt64(head, 20);
        if (size == 0) return ProbeResult.Archive;                                 // intact, and empty
        var room = (ulong)fs.Length - 32;
        if (offset > room || size > room - offset) return ProbeResult.Damaged;     // truncated
        // An intact 7z with encrypted headers looks exactly like this one: the encryption only shows
        // when the open fails, which is where PasswordForm picks it up.
        return Crc32(fs, 32 + (long)offset, (long)size) == BitConverter.ToUInt32(head, 28)
            ? ProbeResult.Archive : ProbeResult.Damaged;
    }

    /// <summary>RAR4 MAIN_HEAD, the 7 bytes after the signature: CRC(2) type(1)=0x73 flags(2 LE) size(2).</summary>
    // ponytail: MHD_PASSWORD (0x0080) is readable only while the main head itself is; when it is not, the
    // open loop in PasswordForm still ends up asking for the password.
    public static bool Rar4Encrypted(byte[] head)
        => head.Length >= 7 && head[2] == 0x73 && (BitConverter.ToUInt16(head, 3) & 0x0080) != 0;

    /// <summary>RAR5 first header, after the signature: CRC32(4) vint HeaderSize, vint HeaderType (4 = encryption).</summary>
    public static bool Rar5Encrypted(byte[] head)
    {
        var i = 4;
        return Vint(head, ref i, out _) && Vint(head, ref i, out var type) && type == 4;
    }

    /// <summary>RAR5 variable int: 7 bits per byte, lowest group first, high bit = another byte follows.</summary>
    static bool Vint(byte[] b, ref int i, out ulong value)
    {
        value = 0;
        for (var shift = 0; i < b.Length && shift < 64; shift += 7)
        {
            var c = b[i++];
            value |= (ulong)(c & 0x7F) << shift;
            if ((c & 0x80) == 0) return true;
        }
        return false;                                   // ran off the end
    }

    static readonly uint[] CrcTable = BuildCrcTable();

    static uint[] BuildCrcTable()
    {
        var t = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            var c = i;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }

    /// <summary>CRC32 (IEEE 802.3) of a byte range - the checksum 7z and zip store.</summary>
    // ponytail: 20 lines instead of a System.IO.Hashing package reference for two header checks.
    static uint Crc32(FileStream fs, long offset, long count)
    {
        fs.Position = offset;
        var buf = new byte[64 * 1024];
        var c = 0xFFFFFFFFu;
        while (count > 0)
        {
            var n = fs.Read(buf, 0, (int)Math.Min(count, buf.Length));
            if (n <= 0) break;
            for (var i = 0; i < n; i++) c = CrcTable[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
            count -= n;
        }
        return c ^ 0xFFFFFFFFu;
    }

    /// <summary>Worth trying to open rather than to compress (drag and drop).</summary>
    // ponytail: a dropped exe is something to pack, not an SFX to peek into - Open... still opens it.
    public static bool LooksLikeArchive(string path)
    {
        try { using var fs = File.OpenRead(path); if (Matches(fs, SigPe)) return false; } catch { }
        return Probe(path) != ProbeResult.NotArchive;
    }

    /// <summary>Why an extraction or a test failed, in words the user can act on.</summary>
    // Measured: an AES zip with a wrong password says "Wrong password."; a body-encrypted 7z with a wrong
    // password says "File is corrupted. Data error has occured." - no mention of a password at all, which
    // is why encrypted data plus a data error is reported as a probable wrong password (7-Zip cannot
    // split that case either).
    static string Explain(SevenZipExtractor x, string? password, Exception ex)
    {
        var msg = ex.Message;
        if (msg.Contains("password", StringComparison.OrdinalIgnoreCase)) return S.WrongPassword;
        if (msg.Contains("Data error", StringComparison.OrdinalIgnoreCase) || msg.Contains("CRC", StringComparison.OrdinalIgnoreCase))
            return password != null || x.ArchiveFileData.Any(f => f.Encrypted) ? S.DataErrorEncrypted : S.Damaged;
        if (msg.Contains("Unsupported", StringComparison.OrdinalIgnoreCase)) return S.UnsupportedMethod;
        return S.OperationFailed + ": " + msg.Split('\n')[0].Trim();
    }

    /// <summary>Library exceptions turned into something a human can act on.</summary>
    public static string Friendly(Exception ex) => ex switch
    {
        OperationCanceledException => S.Cancelled,
        SevenZipArchiveException => S.Damaged,                                    // the open itself failed
        SevenZipException when ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase) => S.WrongPassword,
        SevenZipException => S.OperationFailed + ": " + ex.Message.Split('\n')[0].Trim(),
        // "...no corresponding signature was found." / "Extension "txt" is not a supported archive file name extension."
        ArgumentException when ex.Message.Contains("signature", StringComparison.OrdinalIgnoreCase)
                           || ex.Message.Contains("extension", StringComparison.OrdinalIgnoreCase) => S.NotAnArchive,
        _ => ex.Message,                                                          // IO / access errors are localised by Windows already
    };

    /// <summary>exit codes: 0 OK, 1 warning, 2 fatal, 3 CRC/damaged, 7 bad switch, 10 no files, 11 password, 255 cancelled.</summary>
    public static int ExitCodeOf(Exception ex) => ex switch
    {
        OperationCanceledException => 255,
        WarningException => 1,
        InvalidDataException d when d.Message == S.WrongPassword || d.Message == S.DataErrorEncrypted || d.Message == S.PasswordNeeded
                                 || d.Message == S.PasswordsDiffer => 11,
        InvalidDataException or SevenZipArchiveException => 3,
        SevenZipException when ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase) => 11,
        ArgumentException when Friendly(ex) == S.NotAnArchive => 2,
        ArgumentException => 7,
        FileNotFoundException or DirectoryNotFoundException => 10,
        InvalidOperationException when ex.Message == S.NoInputs => 10,
        _ => 2,
    };

    // ---- extract -------------------------------------------------------------------------------

    /// <param name="indices">null = whole archive.</param>
    /// <param name="onConflict">Called only while mode is Ask; null return cancels.</param>
    /// <param name="motw">null = the user's setting.</param>
    public static Task Extract(Archive a, string destDir, int[]? indices, OverwriteMode mode,
                               IProgress<(int percent, string file)> progress, CancellationToken ct,
                               Func<string, OverwriteMode?> onConflict, MotwPolicy? motw = null,
                               ExtractOptions? options = null) => Task.Run(() =>
    {
        var o = options ?? ExtractOptions.Default;
        Directory.CreateDirectory(destDir);
        var destFull = Path.GetFullPath(destDir).TrimEnd('\\') + "\\";
        using var x = Reopen(a);
        x.PreserveDirectoryStructure = !o.NoPaths;
        var current = "";
        var cancelled = false;
        var unsafeEntries = 0;
        var policy = motw ?? Settings.Current.Motw;
        var zone = policy == MotwPolicy.Never ? null : ZoneOf(a.Source);
        var written = new List<string>();   // what actually landed on disk, renames included: the files to mark
        string? renamedTo = null;
        string? inFlight = null;            // started and not finished: when the extraction throws, this is the broken one

        string Dest(string raw) => Path.GetFullPath(Path.Combine(destFull, o.NoPaths ? Path.GetFileName(raw.TrimEnd('/', '\\')) : raw));
        // Update modes decide a clash by date, and FileExists only knows the target path: so map path -> archived date.
        var dates = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        if (o.Update != UpdateMode.Replace)
            foreach (var f in x.ArchiveFileData)
                if (!f.IsDirectory && !Escapes(destFull, f.FileName ?? "")) dates[Dest(f.FileName ?? "")] = f.LastWriteTime;

        // 7z.dll raises these hundreds of times a second; posting every one of them to the UI thread
        // starves its input queue and the Cancel button stops answering. One report per percent is plenty.
        var last = -1;
        x.Extracting += (_, e) => { if (e.PercentDone != last) { last = e.PercentDone; progress.Report((e.PercentDone, current)); } };

        // Per file 7z.dll raises FileExists (only when there is a clash) and then FileExtractionStarted.
        // Renaming and cancelling work from the first; skipping only works from the second, hence the flag.
        // ProgressEventArgs carries no Cancel at all, so cancellation rides on FileExtractionStarted too.
        var skipNext = false;
        x.FileExists += (_, e) =>
        {
            skipNext = false;
            if (o.Update != UpdateMode.Replace)
            {
                // ponytail: 2 s of slack for zip's 2-second timestamps; a 7z copy newer by under 2 s counts as the same.
                var archived = dates.TryGetValue(Path.GetFullPath(e.FileName), out var t) ? t : DateTime.MaxValue;
                skipNext = archived - File.GetLastWriteTime(e.FileName) <= TimeSpan.FromSeconds(2);
                return;
            }
            switch (mode == OverwriteMode.Ask ? onConflict(e.FileName) : mode)
            {
                case OverwriteMode.Overwrite: break;
                case OverwriteMode.Skip: skipNext = true; break;
                case OverwriteMode.Rename: e.FileName = renamedTo = Unique(e.FileName); break;
                default: e.Cancel = true; cancelled = true; break;   // null = the user cancelled
            }
        };
        x.FileExtractionStarted += (_, e) =>
        {
            var skip = skipNext;
            var renamed = renamedTo;
            skipNext = false;
            renamedTo = null;
            if (ct.IsCancellationRequested) { e.Cancel = true; cancelled = true; return; }
            var raw = e.FileInfo.FileName ?? "";
            if (Escapes(destFull, raw)) { e.Skip = true; unsafeEntries++; return; }
            current = raw;
            if (!skip && o.Update == UpdateMode.Existing && !e.FileInfo.IsDirectory && !File.Exists(Dest(raw))) skip = true;
            if (skip || (o.NoPaths && e.FileInfo.IsDirectory)) { e.Skip = true; return; }   // no paths: no (empty) folders either
            if (e.FileInfo.IsDirectory) return;
            inFlight = renamed ?? Dest(raw);
            if (zone != null) written.Add(inFlight);
        };
        x.FileExtractionFinished += (_, _) => inFlight = null;

        try
        {
            if (indices == null) x.ExtractArchive(destDir);
            else if (indices.Length > 0) x.ExtractFiles(destDir, indices);
        }
        catch when (cancelled || ct.IsCancellationRequested) { throw new OperationCanceledException(); }
        catch (SevenZipException ex) { throw new InvalidDataException(Explain(x, a.Password, ex), ex); }
        finally
        {
            // 7z.dll leaves a file that failed its CRC on disk, full of garbage, and never finishes it.
            if (inFlight != null && !o.KeepBroken) TryDelete(inFlight);
            // Cancelled or failed half way, what did land is marked all the same: an unmarked exe is the hole.
            if (zone != null) Mark(written, zone, policy);
        }
        if (cancelled || ct.IsCancellationRequested) throw new OperationCanceledException();
        if (unsafeEntries > 0) throw new WarningException(string.Format(S.UnsafeSkippedFmt, unsafeEntries));
        progress.Report((100, ""));
    }, ct);

    // ---- info ------------------------------------------------------------------------------------

    /// <summary>
    /// What the Info window lists, label and value, in order. Unpacked size is summed from the entries: SevenZipSharp's
    /// own UnpackedSize answers -1. Packed size is the file(s) on disk, not the inner tar of a .tar.gz.
    /// </summary>
    public static List<(string Label, string Value)> Describe(Archive a)
    {
        var x = a.X;
        var data = x.ArchiveFileData;
        var props = x.ArchiveProperties.Where(p => p.Value != null && $"{p.Value}".Length > 0).ToDictionary(p => p.Name, p => $"{p.Value}");
        var files = data.Where(f => !f.IsDirectory).ToList();
        var folders = data.Where(f => f.IsDirectory).Select(f => Norm(f.FileName))
            .Concat(files.Select(f => Norm(f.FileName)).Where(n => n.Contains('/')).Select(n => n[..n.LastIndexOf('/')]))
            .SelectMany(n => n.Split('/').Select((_, i) => string.Join('/', n.Split('/').Take(i + 1))))   // every parent of every path
            .Where(n => n.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        long unpacked = files.Sum(f => (long)f.Size), packed = SizeOnDisk(a.Source);
        var methods = props.TryGetValue("Method", out var m) ? m
            : string.Join(", ", files.Select(f => f.Method).Where(s => !string.IsNullOrEmpty(s)).Distinct());
        var rows = new List<(string, string)>
        {
            (S.InfoFile, a.Source),
            (S.Format.TrimEnd(':'), (x.Format == InArchiveFormat.SevenZip ? "7z" : x.Format.ToString()) + (a.Nested ? " (" + Path.GetFileName(a.OpenPath) + ")" : "")),
            (S.Method.TrimEnd(':'), methods.Length > 0 ? methods : "-"),
        };
        if (DictionaryOf(methods) is { } dict) rows.Add((S.Dictionary.TrimEnd(':'), NiceSize(dict)));
        rows.Add((S.Solid, x.IsSolid ? S.Yes + (props.TryGetValue("Number of blocks", out var b) ? $" ({string.Format(S.BlocksFmt, b)})" : "") : S.No));
        rows.Add((S.Encrypted, !files.Any(f => f.Encrypted) ? S.No : NamesEncrypted(a) ? S.EncryptedDataAndNames : S.EncryptedData));
        rows.Add((S.Files, files.Count.ToString()));
        rows.Add((S.Folders, folders.ToString()));
        rows.Add((S.Unpacked, NiceSize(unpacked)));
        rows.Add((S.Packed, NiceSize(packed)));
        rows.Add((S.Ratio, unpacked > 0 ? $"{packed * 100.0 / unpacked:0.#}%" : "-"));
        if (IsFirstPart(a.Source)) rows.Add((S.VolumesCount, Enumerable.Range(1, int.MaxValue - 1).Select(n => Part(a.Source[..^4], n)).TakeWhile(File.Exists).Count().ToString()));
        else if (props.TryGetValue("Number of volumes", out var v)) rows.Add((S.VolumesCount, v));
        if (props.TryGetValue("Comment", out var c)) rows.Add((S.Comment, c));
        return rows;
    }

    /// <summary>
    /// The file list as a report: the archive's properties (the same rows as the Info window, so the totals agree),
    /// then one line per file - path, size, modified, CRC, method - in path order.
    /// </summary>
    // ponytail: no per-file packed size - SevenZipSharp's ArchiveFileInfo does not carry it; the total is in the header.
    public static string Report(Archive a, bool html)
    {
        var head = Describe(a);
        var files = a.X.ArchiveFileData.Where(f => !f.IsDirectory).OrderBy(f => Norm(f.FileName), StringComparer.OrdinalIgnoreCase).ToList();
        var cols = new[] { S.Name, S.Size, S.Modified, S.Crc, S.Method.TrimEnd(':') };
        string[] Row(ArchiveFileInfo f) =>
            [Norm(f.FileName), f.Size.ToString("N0"), f.LastWriteTime.ToString("yyyy-MM-dd HH:mm"), f.Crc.ToString("X8"), f.Method ?? ""];
        var sb = new System.Text.StringBuilder();
        if (!html)
        {
            foreach (var (label, value) in head) sb.AppendLine($"{label}: {value}");
            sb.AppendLine();
            var rows = files.Select(Row).Prepend(cols).ToList();
            var width = Enumerable.Range(0, cols.Length).Select(i => rows.Max(r => r[i].Length)).ToArray();
            foreach (var r in rows)
                sb.AppendLine(string.Join("  ", r.Select((c, i) => i is 1 or 3 ? c.PadLeft(width[i]) : c.PadRight(width[i]))).TrimEnd());
            return sb.ToString();
        }
        static string E(string s) => System.Net.WebUtility.HtmlEncode(s);   // names can hold < > & " - from zips made anywhere
        sb.Append("<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>").Append(E(a.Display)).Append("</title>\n<style>")
          .Append("body{font:14px Segoe UI,sans-serif;margin:24px}table{border-collapse:collapse}td,th{padding:3px 10px;text-align:left}")
          .Append("th{border-bottom:1px solid #999}.n{text-align:right;font-variant-numeric:tabular-nums}tr:nth-child(even) td{background:#f4f4f4}")
          .Append("</style></head><body>\n<h1>").Append(E(a.Display)).Append("</h1>\n<table>\n");
        foreach (var (label, value) in head) sb.Append("<tr><th>").Append(E(label)).Append("</th><td>").Append(E(value)).Append("</td></tr>\n");
        sb.Append("</table>\n<h2>").Append(E(S.FilesHeading)).Append("</h2>\n<table>\n<tr>");
        foreach (var c in cols) sb.Append("<th>").Append(E(c)).Append("</th>");
        sb.Append("</tr>\n");
        foreach (var f in files)
        {
            var r = Row(f);
            sb.Append("<tr>");
            for (var i = 0; i < r.Length; i++) sb.Append(i is 1 or 3 ? "<td class=\"n\">" : "<td>").Append(E(r[i])).Append("</td>");
            sb.Append("</tr>\n");
        }
        return sb.Append("</table>\n</body></html>\n").ToString();
    }

    /// <summary>Text with a UTF-8 BOM (Notepad and Excel then read Cyrillic right); HTML without (its meta charset says it).</summary>
    public static void WriteReport(Archive a, string path, bool html) =>
        File.WriteAllText(path, Report(a, html), new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: !html));

    /// <summary>"LZMA2:24" -> 2^24, "LZMA:1536m" -> 1.5 GB, "PPMD:o6:mem24" -> 2^24; null when the method has none.</summary>
    public static long? DictionaryOf(string method)
    {
        foreach (var part in method.Split(' ', ':'))
        {
            var t = part.StartsWith("mem", StringComparison.OrdinalIgnoreCase) ? part[3..] : part;
            if (t.Length == 0 || !char.IsDigit(t[0])) continue;   // "LZMA2", "BCJ", "o6"; the first number is the coder's
            if (int.TryParse(t, out var n) && n < 40) return 1L << n;               // a bare number is a power of two
            if (ParseSize(t) is > 0 and var s) return s;                             // "1536m"
        }
        return null;
    }

    /// <summary>Opened only with a password, but would not even list without one: the names are encrypted too.</summary>
    static bool NamesEncrypted(Archive a)
    {
        if (a.Password == null) return false;
        try { Open(a.Source, null).Dispose(); return false; } catch { return true; }
    }

    // ---- convert ---------------------------------------------------------------------------------

    /// <summary>
    /// Repacks <paramref name="source"/> as <paramref name="target"/> in <paramref name="kind"/>: unpack to a temp folder,
    /// pack into a hidden file next to the target, then keep it only if it tests clean and holds as many files and
    /// bytes as the original. True = converted; false = kept the original because the new one was not smaller
    /// (<paramref name="keepIfNotSmaller"/>). Any failure or cancel removes the new file and leaves the original alone.
    /// <paramref name="target"/> == <paramref name="source"/> replaces the original - the caller allows that only
    /// together with <paramref name="deleteOriginal"/>.
    /// </summary>
    // ponytail: no volumes or SFX here - the converted archive is always one plain file.
    public static Task<bool> Convert(string source, string? password, string target, ArchiveKind kind, CompressionLevel level,
                                     bool keepIfNotSmaller, bool deleteOriginal,
                                     IProgress<(int percent, string file)> progress, CancellationToken ct) => Task.Run(() =>
    {
        // The original's password goes on, so an encrypted archive never comes out readable by anyone.
        if (password != null && !Kind(kind).Password)
            throw new InvalidOperationException(string.Format(S.ConvertWouldDecryptFmt, Kind(kind).Name));
        var o = new CompressOptions(level, password, EncryptHeaders: password != null && kind == ArchiveKind.SevenZip);
        var work = NewTempDir();
        var hidden = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(target))!,
                                  ".makepack-" + Guid.NewGuid().ToString("N")[..8] + "-" + Path.GetFileName(target));
        try
        {
            (int Files, long Bytes) before;
            using (var a = Open(source, password))
            {
                before = Stats(a);
                Extract(a, work, null, OverwriteMode.Overwrite, new Scaled(progress, 0, 45), ct, _ => OverwriteMode.Overwrite,
                        MotwPolicy.Never).GetAwaiter().GetResult();
            }
            var inputs = Directory.EnumerateFileSystemEntries(work).ToList();
            Compress(inputs, hidden, kind, o, new Scaled(progress, 45, 90), ct).GetAwaiter().GetResult();

            BeforeTestHook?.Invoke(hidden);
            try
            {
                using var b = Open(hidden, password);
                var ok = Test(b, new Scaled(progress, 90, 100), ct).GetAwaiter().GetResult();
                ct.ThrowIfCancellationRequested();
                if (!ok || Stats(b) != before) throw new InvalidDataException(S.ConvertMismatch);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) { throw new InvalidDataException(S.ConvertMismatch, ex); }   // would not even open: same verdict, one message
            if (keepIfNotSmaller && new FileInfo(hidden).Length >= SizeOnDisk(source)) { TryDelete(hidden); return false; }

            var zone = ZoneOf(source);   // a downloaded archive's "from the Internet" mark stays on its converted copy
            if (deleteOriginal && !SamePath(source, target)) RecycleArchive(source);
            File.Move(hidden, target, true);
            if (zone != null) try { File.WriteAllText(target + ":Zone.Identifier", zone); } catch { /* no streams here */ }
            progress.Report((100, ""));
            return true;
        }
        catch { TryDelete(hidden); throw; }
        finally { Nuke(work); }
    }, ct);

    /// <summary>Files (not folders) and their unpacked bytes, as the archive itself lists them.</summary>
    static (int Files, long Bytes) Stats(Archive a)
    {
        var files = a.X.ArchiveFileData.Where(f => !f.IsDirectory).ToList();
        return (files.Count, files.Sum(f => (long)f.Size));
    }

    /// <summary>A .001 set counts all its parts.</summary>
    static long SizeOnDisk(string archive) => IsFirstPart(archive)
        ? Enumerable.Range(1, int.MaxValue - 1).Select(n => Part(archive[..^4], n)).TakeWhile(File.Exists).Sum(p => new FileInfo(p).Length)
        : new FileInfo(archive).Length;

    public static bool SamePath(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The archive to the Recycle Bin after a clean extraction - every part of a .001 set. The caller closes it first:
    /// 7z.dll keeps the file open while it is.
    /// </summary>
    public static void RecycleArchive(string source) =>
        Recycle(IsFirstPart(source)
            ? Enumerable.Range(1, int.MaxValue - 1).Select(n => Part(source[..^4], n)).TakeWhile(File.Exists).ToList()
            : [source]);

    // ---- Mark of the Web -----------------------------------------------------------------------
    // Windows tags downloads with a Zone.Identifier stream; SmartScreen and Office's Protected View act on it.
    // An archive that drops it on extraction launders a downloaded exe into a "local" one - so it is passed on.

    /// <summary>Files that can run code, or open into something that can (archives, disk images): list, roughly.</summary>
    static readonly HashSet<string> Risky = new(StringComparer.OrdinalIgnoreCase)
    {
        "exe", "com", "scr", "pif", "cpl", "msi", "msp", "msix", "appx", "appxbundle", "dll", "ocx", "sys", "drv",
        "bat", "cmd", "ps1", "psm1", "psd1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "lnk", "url", "scf", "reg", "inf",
        "jar", "chm", "iso", "img", "vhd", "vhdx",
        "doc", "docx", "docm", "dot", "dotx", "dotm", "rtf", "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "xla", "xlam",
        "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm", "ppam", "one", "pub", "vsd", "vsdx", "vsdm", "pdf",
    };

    /// <summary>The archive's Zone.Identifier stream, or null when it has none (made here, or on a drive without streams).</summary>
    public static string? ZoneOf(string archive)
    {
        try { return File.ReadAllText(archive + ":Zone.Identifier"); } catch { return null; }
    }

    public static bool Marks(MotwPolicy policy, string file) => policy switch
    {
        MotwPolicy.All => true,
        MotwPolicy.Risky => Path.GetExtension(file).TrimStart('.') is var e && (Risky.Contains(e) || Assoc.All.Contains(e, StringComparer.OrdinalIgnoreCase)),
        _ => false,
    };

    static void Mark(IEnumerable<string> files, string zone, MotwPolicy policy)
    {
        foreach (var f in files)
            if (Marks(policy, f) && File.Exists(f))
                try { File.WriteAllText(f + ":Zone.Identifier", zone); } catch { /* FAT32 / exFAT have no streams */ }
    }

    /// <summary>Zip-slip guard: true when the entry would land outside <paramref name="destFull"/> (which ends with \).</summary>
    // 7z.dll only neuters a "C:" prefix; "../x", "..\x", "\x" and "//server/share/x" all still escape.
    static bool Escapes(string destFull, string raw)
    {
        if (raw.Length == 0) return false;
        foreach (var seg in raw.Split('/', '\\'))
            if (seg.Trim(' ', '.').Length == 0 && seg.Count(c => c == '.') > 1) return true;   // "..", ".. ", "..." - but "." is fine
        try { return !Path.GetFullPath(Path.Combine(destFull, raw)).StartsWith(destFull, StringComparison.OrdinalIgnoreCase); }
        catch { return true; }   // invalid characters, path too long, ...
    }

    /// <summary>Entry name for display: forward slashes, no trailing slash, no leading "./" (GNU tar).</summary>
    public static string Norm(string? name)
    {
        var n = (name ?? "").Replace('\\', '/').TrimEnd('/');
        while (n.StartsWith("./", StringComparison.Ordinal)) n = n[2..];
        return n == "." ? "" : n;
    }

    public static string Unique(string path)
    {
        var dir = Path.GetDirectoryName(path) ?? "";
        var name = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (var i = 2; ; i++)
        {
            var p = Path.Combine(dir, $"{name} ({i}){ext}");
            if (!File.Exists(p)) return p;
        }
    }

    // ---- compress ------------------------------------------------------------------------------

    public static Task Compress(IReadOnlyList<string> inputs, string outPath, ArchiveKind kind, CompressOptions o,
                                IProgress<(int percent, string file)> progress, CancellationToken ct) => Task.Run(() =>
    {
        var info = Kind(kind);
        var dict = BuildDict(inputs);
        if (dict.Count == 0) throw new InvalidOperationException(S.NoInputs);
        if (!info.Multi && dict.Count != 1) throw new InvalidOperationException(S.SingleFileOnly);
        var input = dict.Values.Sum(f => f == null ? 0 : new FileInfo(f).Length);
        var ram = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
        if (!DictionaryFits(o, input, ram, out var need))
            throw new InvalidOperationException(string.Format(S.DictionaryTooBigFmt, NiceSize(o.Dictionary), NiceSize(need), NiceSize(ram)));
        if (o.VolumeSize < 0) throw new ArgumentException("negative volume size");
        // ponytail: 7z only and no volumes - a split SFX needs a stub that reads .002..., 7z.sfx does not.
        if (o.Sfx && (kind != ArchiveKind.SevenZip || o.VolumeSize > 0)) throw new ArgumentException("SFX is 7z-only and single-file");
        if (o.ZipCrypto && kind != ArchiveKind.Zip) throw new ArgumentException("ZipCrypto is zip-only");
        if (o.DeleteSources && inputs.Any(i => Inside(outPath, i)))
            throw new InvalidOperationException(S.ArchiveInsideSources);   // recycling the folder would take the archive along
        var outDir = Path.GetDirectoryName(outPath);
        if (!string.IsNullOrEmpty(outDir)) Directory.CreateDirectory(outDir);
        var whole = progress;
        if (o.TestAfter) progress = new Scaled(whole, 0, 80);

        // Volumes: write the whole archive, then cut it (SevenZipSharp only splits 7z and tar itself).
        var target = o.VolumeSize > 0 || o.Sfx ? outPath + ".makepack-tmp" : outPath;
        if (o.VolumeSize > 0) DeleteParts(outPath);   // a stale .004 from an older, bigger set would join the new one

        if (kind is ArchiveKind.TarGz or ArchiveKind.TarBz2 or ArchiveKind.TarXz)
        {
            var dir = NewTempDir();
            try
            {
                var tar = Path.Combine(dir, BaseName(outPath) + ".tar");
                var plain = new CompressOptions(o.Level);   // tar.* has no method/solid/filter knobs
                Pack(dict, tar, OutArchiveFormat.Tar, plain, progress, 0, 50, ct);
                Pack(new Dictionary<string, string?> { [Path.GetFileName(tar)] = tar },
                     target, info.Format, plain, progress, 50, 100, ct);
            }
            finally { Nuke(dir); }
        }
        else Pack(dict, target, info.Format, o, progress, 0, 100, ct);

        if (o.VolumeSize > 0)
            try { Split(target, outPath, o.VolumeSize); }
            catch { TryDelete(target); DeleteParts(outPath); throw; }
        if (o.Sfx)
            try { Glue([SfxModule, target], outPath); }
            catch { TryDelete(outPath); throw; }
            finally { TryDelete(target); }

        // The archive is complete from here on: a failed or cancelled test leaves it, and never touches the sources.
        if (o.TestAfter)
        {
            BeforeTestHook?.Invoke(o.VolumeSize > 0 ? Part(outPath, 1) : outPath);
            using var a = Open(o.VolumeSize > 0 ? Part(outPath, 1) : outPath, o.Password);
            var ok = Test(a, new Scaled(whole, 80, 100), ct).GetAwaiter().GetResult();
            ct.ThrowIfCancellationRequested();   // a cancelled Check() also answers false
            if (!ok) throw new InvalidDataException(S.TestAfterFailed);
        }
        ct.ThrowIfCancellationRequested();
        if (o.DeleteSources) Recycle(inputs);
        whole.Report((100, ""));
    }, ct);

    /// <summary>
    /// Where one archive of all the inputs goes by default: named after the single input, or after the folder
    /// several inputs share; next to them, or in <paramref name="folder"/>.
    /// </summary>
    public static string DefaultArchivePath(IReadOnlyList<string> inputs, string ext, string? folder)
    {
        if (inputs.Count == 0) return "";
        var first = Path.GetFullPath(inputs[0].TrimEnd('\\', '/'));
        var parent = Path.GetDirectoryName(first) ?? first;
        var name = inputs.Count == 1
            ? (Directory.Exists(first) ? Path.GetFileName(first) : Path.GetFileNameWithoutExtension(first))
            : Path.GetFileName(parent);
        if (string.IsNullOrEmpty(name)) name = S.App;
        return Path.Combine(Directory.Exists(folder) ? folder! : parent, name + ext);
    }

    /// <summary>
    /// One archive per input, named after it ("photos" -> photos.7z, "a.txt" -> a.7z), next to it or in
    /// <paramref name="folder"/>. Inputs that would share a name (a.txt + a.doc) keep their whole names
    /// (a.txt.7z, a.doc.7z); anything still clashing gets " (2)", " (3)"... like a copy in Explorer.
    /// </summary>
    public static List<(string Input, string Output)> PlanSeparate(IReadOnlyList<string> inputs, string ext, string? folder)
    {
        (string Dir, string Name) Parts(string input, bool whole)
        {
            var full = Path.GetFullPath(input.TrimEnd('\\', '/'));
            var name = Directory.Exists(full) || whole ? Path.GetFileName(full) : Path.GetFileNameWithoutExtension(full);
            if (name.Length == 0) name = Path.GetFileName(full);   // ".gitignore"
            if (name.Length == 0) name = S.App;                     // a drive root
            return (Directory.Exists(folder) ? folder! : Path.GetDirectoryName(full) ?? full, name);
        }
        string Join((string Dir, string Name) p) => Path.Combine(p.Dir, p.Name + ext);

        var clash = inputs.GroupBy(i => Join(Parts(i, false)), StringComparer.OrdinalIgnoreCase)
                          .Where(g => g.Count() > 1).SelectMany(g => g).ToHashSet();
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var plan = new List<(string, string)>();
        foreach (var input in inputs)
        {
            var p = Parts(input, clash.Contains(input));
            var output = Join(p);
            for (var n = 2; !used.Add(output); n++) output = Path.Combine(p.Dir, $"{p.Name} ({n}){ext}");
            plan.Add((input, output));
        }
        return plan;
    }

    /// <summary>
    /// The plan, one archive after another under one progress bar. Cancel stops the series: archives already made
    /// stay, the one in progress is removed by Compress itself.
    /// </summary>
    public static async Task CompressEach(IReadOnlyList<(string Input, string Output)> plan, ArchiveKind kind, CompressOptions o,
                                          IProgress<(int percent, string file)> progress, CancellationToken ct)
    {
        for (var i = 0; i < plan.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var slice = new Scaled(progress, i * 100 / plan.Count, (i + 1) * 100 / plan.Count);
            await Compress([plan[i].Input], plan[i].Output, kind, o, slice, ct);
        }
    }

    /// <summary>Selftest only: damages the fresh archive, standing in for a bad disk between write and test.</summary>
    internal static Action<string>? BeforeTestHook;

    sealed class Scaled(IProgress<(int, string)> to, int lo, int hi) : IProgress<(int, string)>
    {
        public void Report((int, string) v) => to.Report((lo + v.Item1 * (hi - lo) / 100, v.Item2));
    }

    /// <summary>True when <paramref name="path"/> is <paramref name="folder"/> itself or somewhere under it.</summary>
    static bool Inside(string path, string folder)
    {
        var f = Path.GetFullPath(folder).TrimEnd('\\', '/') + "\\";
        return Directory.Exists(folder) && (Path.GetFullPath(path) + "\\").StartsWith(f, StringComparison.OrdinalIgnoreCase);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd; public uint wFunc; public string pFrom; public string? pTo; public ushort fFlags;
        public int fAnyOperationsAborted; public IntPtr hNameMappings; public string? lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    /// <summary>
    /// To the Recycle Bin, all in one shell call. Where there is no bin (network share, bin too small) the
    /// shell asks before deleting for good (FOF_WANTNUKEWARNING) instead of doing it silently.
    /// </summary>
    public static void Recycle(IEnumerable<string> paths)
    {
        const uint FO_DELETE = 3;
        const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400, FOF_WANTNUKEWARNING = 0x4000;
        var list = paths.Select(p => Path.GetFullPath(p.TrimEnd('\\', '/'))).Where(p => File.Exists(p) || Directory.Exists(p)).ToList();
        if (list.Count == 0) return;
        var op = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = string.Join("\0", list) + "\0\0",   // double-NUL-terminated list
            fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_ALLOWUNDO | FOF_NOERRORUI | FOF_WANTNUKEWARNING,
        };
        var rc = SHFileOperation(ref op);
        if (rc != 0 || op.fAnyOperationsAborted != 0) throw new IOException(string.Format(S.RecycleFailedFmt, rc));
    }

    /// <summary>7-Zip's GUI self-extractor stub, shipped next to the exe (see MakePack.csproj).</summary>
    public static string SfxModule => Path.Combine(AppContext.BaseDirectory, "7z.sfx");

    /// <summary>
    /// A self-extracting 7z: the 7z data after an exe stub. 7z.dll opens it as 7z, so an in-place edit would
    /// rewrite it as a plain 7z under the .exe name and cut the stub off - these stay read-only.
    /// </summary>
    public static bool IsSfx(Archive a)
    {
        try { using var fs = File.OpenRead(a.OpenPath); return Matches(fs, SigPe); } catch { return false; }
    }

    static void Glue(IEnumerable<string> pieces, string output)
    {
        using var o = new FileStream(output, FileMode.Create);
        foreach (var piece in pieces)
            using (var i = File.OpenRead(piece)) i.CopyTo(o);
    }

    /// <summary>name.001, name.002... - the numbering 7-Zip's split format reads back.</summary>
    public static string Part(string path, int n) => $"{path}.{n:D3}";

    /// <summary>Every name.NNN, not just a run from .001: a gap must not let an old .009 survive into the new set.</summary>
    static void DeleteParts(string path)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path))!;
        var name = Path.GetFileName(path) + ".";
        foreach (var f in Directory.EnumerateFiles(dir, name + "*"))
            if (Path.GetFileName(f)[name.Length..] is { Length: >= 3 } n && n.All(char.IsAsciiDigit)) File.Delete(f);
    }

    /// <summary>
    /// Cuts a finished file into parts in place, from the end: copy the tail out, truncate, repeat. The extra
    /// disk space is one part instead of a second copy of the whole archive.
    /// </summary>
    // ponytail: not cancellable - it is a plain file copy, seconds even for big sets.
    static void Split(string whole, string outPath, long size)
    {
        using (var fs = new FileStream(whole, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var count = Math.Max(1, (fs.Length + size - 1) / size);
            for (var n = count; n > 1; n--)
            {
                fs.Position = (n - 1) * size;
                using (var part = new FileStream(Part(outPath, (int)n), FileMode.CreateNew)) fs.CopyTo(part);
                fs.SetLength((n - 1) * size);
            }
        }
        File.Move(whole, Part(outPath, 1));
    }

    /// <summary>
    /// "700 MB", "1,5 ГБ", "4095m", "250000" (bytes) -> bytes; "" -> 0; anything else -> null.
    /// Units are binary like 7-Zip's -v; a trailing "(...)" note on a preset is ignored.
    /// </summary>
    public static long? ParseSize(string text)
    {
        var t = text.Split('(')[0].Trim().Replace(',', '.').ToLowerInvariant();
        if (t.Length == 0) return 0;
        var i = 0;
        while (i < t.Length && (char.IsDigit(t[i]) || t[i] == '.')) i++;
        if (!double.TryParse(t[..i], System.Globalization.NumberStyles.AllowDecimalPoint,
                             System.Globalization.CultureInfo.InvariantCulture, out var n)) return null;
        var shift = t[i..].Trim() switch
        {
            "" or "b" or "б" => 0,
            "k" or "kb" or "к" or "кб" => 10,
            "m" or "mb" or "м" or "мб" => 20,
            "g" or "gb" or "г" or "гб" => 30,
            "t" or "tb" or "т" or "тб" => 40,
            _ => -1,
        };
        if (shift < 0) return null;
        var bytes = n * Math.Pow(2, shift);
        return bytes is >= 1 and < long.MaxValue ? (long)bytes : null;
    }

    static void Pack(IDictionary<string, string?> dict, string outPath, OutArchiveFormat format, CompressOptions o,
                     IProgress<(int, string)> progress, int lo, int hi, CancellationToken ct)
    {
        var c = new SevenZipCompressor
        {
            ArchiveFormat = format,
            CompressionMethod = CompressionMethod.Default,
            CompressionMode = CompressionMode.Create,
            DirectoryStructure = true,
            PreserveDirectoryRoot = false,
            EncryptHeaders = o.EncryptHeaders && format == OutArchiveFormat.SevenZip,
            ZipEncryptionMethod = o.ZipCrypto ? ZipEncryptionMethod.ZipCrypto : ZipEncryptionMethod.Aes256,
        };
        Apply(c, o);
        // A half-written archive is worse than none: never leave one behind on cancel or failure.
        try { Run(c, dict, outPath, o.Password, progress, lo, hi, ct); }
        catch { TryDelete(outPath); throw; }
    }

    /// <summary>The methods a format can be written with, its default first.</summary>
    public static CompressionMethod[] MethodsFor(ArchiveKind kind) => kind switch
    {
        ArchiveKind.SevenZip => [CompressionMethod.Lzma2, CompressionMethod.Lzma, CompressionMethod.Ppmd, CompressionMethod.BZip2],
        ArchiveKind.Zip => [CompressionMethod.Deflate, CompressionMethod.Deflate64, CompressionMethod.BZip2,
                            CompressionMethod.Lzma, CompressionMethod.Ppmd],
        _ => [],
    };

    /// <summary>Only LZMA-family coders take d=; PPMd wants mem= and 7z.dll rejects d= for it (E_INVALIDARG).</summary>
    public static bool HasDictionary(OutArchiveFormat format, CompressionMethod m) =>
        m is CompressionMethod.Lzma or CompressionMethod.Lzma2
        || (m == CompressionMethod.Default && format == OutArchiveFormat.SevenZip);

    /// <summary>
    /// LZMA's match finder needs ~11.5x the dictionary to compress. 7-Zip shrinks the dictionary to the input
    /// size, so only that part counts. Checked against installed RAM, like the classic large-dictionary warning.
    /// </summary>
    // ponytail: installed RAM, not free RAM - free memory moves while we look; 7z.dll's own E_OUTOFMEMORY covers the rest.
    public static bool DictionaryFits(CompressOptions o, long inputBytes, long ramBytes, out long need)
    {
        need = (long)(Math.Min(o.Dictionary, Math.Max(inputBytes, 1)) * 11.5);
        return o.Dictionary == 0 || need <= ramBytes;
    }

    /// <summary>
    /// The knobs shared by create and append. Each one is checked against the format first: 7z.dll takes a
    /// wrong one either with E_INVALIDARG or (zip + s=) by writing a broken archive.
    /// </summary>
    static void Apply(SevenZipCompressor c, CompressOptions o)
    {
        c.CompressionLevel = o.Level;
        if (o.Level == CompressionLevel.None) return;   // Store: no coder, nothing below applies

        var f = c.ArchiveFormat;
        var sevenZip = f == OutArchiveFormat.SevenZip;
        var kind = sevenZip ? ArchiveKind.SevenZip : f == OutArchiveFormat.Zip ? ArchiveKind.Zip : (ArchiveKind?)null;
        void Need(bool ok, string what) { if (!ok) throw new ArgumentException($"{what} is not valid for {f}"); }

        Need(o.Method == CompressionMethod.Default || (kind != null && MethodsFor(kind.Value).Contains(o.Method)), $"method {o.Method}");
        Need(o.Dictionary == 0 || HasDictionary(f, o.Method), "a dictionary size");
        Need(o.Solid == null || sevenZip, "solid");
        Need(o.Filter == null || sevenZip, "an exe filter");
        Need(o.Threads == 0 || kind != null, "a thread count");

        c.CompressionMethod = o.Method;
        if (o.Dictionary > 0) c.CustomParameters["d"] = Size7z(o.Dictionary);
        if (o.Solid != null) c.CustomParameters["s"] = o.Solid;
        if (o.Filter != null) c.CustomParameters["f"] = o.Filter;
        if (o.Threads > 0) c.CustomParameters["mt"] = o.Threads.ToString();
    }

    /// <summary>7-Zip size syntax. A bare number under 32 would mean 2^n, so the unit is always spelled out.</summary>
    public static string Size7z(long bytes) =>
        bytes % (1L << 20) == 0 ? $"{bytes >> 20}m" : bytes % 1024 == 0 ? $"{bytes >> 10}k" : $"{bytes}b";

    /// <summary>CompressFileDictionary with progress and cancel wired up. Cancel = OperationCanceledException.</summary>
    static void Run(SevenZipCompressor c, IDictionary<string, string?> dict, string path, string? password,
                    IProgress<(int, string)> progress, int lo, int hi, CancellationToken ct)
    {
        var current = "";
        var cancelled = false;
        c.FileCompressionStarted += (_, e) =>
        {
            if (ct.IsCancellationRequested) { e.Cancel = true; cancelled = true; }
            else current = e.FileName;
        };
        var last = -1;   // see Extract: one report per percent, or the UI thread never gets to the Cancel click
        c.Compressing += (_, e) =>
        {
            var pct = lo + e.PercentDone * (hi - lo) / 100;
            if (pct == last) return;
            last = pct;
            progress.Report((pct, current));
        };
        // ponytail: 7z.dll only lets us abort between files, and once an input is past its multithreading block
        // size it reads every file up front - the cancel then only lands when the job ends.
        try { c.CompressFileDictionary(dict!, path, password ?? ""); }
        catch when (cancelled || ct.IsCancellationRequested) { throw new OperationCanceledException(); }
        if (cancelled || ct.IsCancellationRequested) throw new OperationCanceledException();
    }

    /// <summary>Hidden and system files are archived too; an unreadable subfolder is skipped, not fatal.</summary>
    // ponytail: AttributesToSkip = 0 also follows reparse points - junction loops are not detected.
    static readonly EnumerationOptions Everything =
        new() { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = true };

    /// <summary>
    /// archive entry name -> file on disk, null for a folder (SevenZipSharp writes a directory entry for it, so
    /// empty folders survive). Entry names are relative to each input's parent, under <paramref name="prefix"/>.
    /// </summary>
    static Dictionary<string, string?> BuildDict(IReadOnlyList<string> inputs, string prefix = "")
    {
        var dict = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var input in inputs)
        {
            var full = Path.GetFullPath(input.TrimEnd('\\', '/'));
            var parent = Path.GetDirectoryName(full) ?? full;
            if (Directory.Exists(full))
                foreach (var e in new DirectoryInfo(full).EnumerateFileSystemInfos("*", Everything).Prepend(new DirectoryInfo(full)))
                    dict[prefix + Path.GetRelativePath(parent, e.FullName)] = e is FileInfo ? e.FullName : null;
            else if (File.Exists(full))
                dict[prefix + Path.GetFileName(full)] = full;
        }
        return dict;
    }

    // ---- test / delete -------------------------------------------------------------------------

    public static Task<bool> Test(Archive a, IProgress<(int percent, string file)> progress, CancellationToken ct)
        => Task.Run(() =>
        {
            using var x = Reopen(a);
            var current = "";
            x.Extracting += (_, e) => progress.Report((e.PercentDone, current));
            x.FileExtractionStarted += (_, e) =>
            {
                if (ct.IsCancellationRequested) e.Cancel = true; else current = e.FileInfo.FileName;
            };
            try { return x.Check(); }
            catch (SevenZipException ex) { throw new InvalidDataException(Explain(x, a.Password, ex), ex); }
        }, ct);

    // ---- edit in place: delete / rename / append --------------------------------------------------

    /// <summary>
    /// 7z.dll can rewrite these in place (delete, rename, append - measured on each, solid 7z included);
    /// everything else is read-only for us.
    /// </summary>
    public static bool CanDelete(Archive a) => !a.Nested && !IsSfx(a) && a.X.Format
        is InArchiveFormat.SevenZip or InArchiveFormat.Zip or InArchiveFormat.Tar or InArchiveFormat.Wim;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool CreateHardLink(string link, string existing, IntPtr security);

    /// <summary>
    /// Runs <paramref name="edit"/>(path, password, new compressor) against the archive file. Closes
    /// <paramref name="a"/> - the caller must reopen afterwards.
    /// </summary>
    // SevenZipSharp writes the new archive to a temp file and deletes the original in a finally block, success
    // or not. Measured: a wrong password or a cancel left the archive missing or unreadable, and a compressor
    // left on its default 7z format "deleted" from a zip by replacing it with garbage. So the old bytes stay
    // reachable under a second name (a hard link, a copy where links are not supported) until the edit succeeded.
    // The header-encryption state needs no help: 7z.dll keeps it as it was (measured both ways).
    static Task Edit(Archive a, Action<string, string, Func<SevenZipCompressor>> edit)
    {
        if (!CanDelete(a)) throw new InvalidOperationException(S.NotSupported);
        var path = a.OpenPath;
        var password = a.Password ?? "";
        var format = a.X.Format switch
        {
            InArchiveFormat.Zip => OutArchiveFormat.Zip,
            InArchiveFormat.Tar => OutArchiveFormat.Tar,
            InArchiveFormat.Wim => OutArchiveFormat.Wim,
            _ => OutArchiveFormat.SevenZip,
        };
        a.Dispose();
        return Task.Run(() =>
        {
            var tmp = NewTempDir();
            var keep = path + ".makepack~";
            TryDelete(keep);
            if (!CreateHardLink(keep, path, IntPtr.Zero)) File.Copy(path, keep);
            try
            {
                edit(path, password, () => new SevenZipCompressor(tmp)
                {
                    ArchiveFormat = format,
                    DirectoryStructure = true,
                    PreserveDirectoryRoot = false,
                    ZipEncryptionMethod = ZipEncryptionMethod.Aes256,
                });
                File.Delete(keep);
            }
            catch { File.Move(keep, path, true); throw; }
            finally { Nuke(tmp); }
        });
    }

    public static Task Delete(Archive a, int[] indices) => Edit(a, (path, password, c) =>
        c().ModifyArchive(path, indices.ToDictionary(i => i, _ => (string)null!), password));

    /// <summary>Renames entry <paramref name="from"/> ("dir/name", as <see cref="Norm"/> gives it) and, for a folder, everything under it.</summary>
    public static Task Rename(Archive a, string from, string to)
    {
        var names = new Dictionary<int, string>();
        foreach (var f in a.X.ArchiveFileData)
        {
            var n = Norm(f.FileName);
            if (n.Equals(from, StringComparison.OrdinalIgnoreCase) || n.StartsWith(from + "/", StringComparison.OrdinalIgnoreCase))
                names[f.Index] = (to + n[from.Length..]).Replace('/', '\\');
        }
        return Edit(a, (path, password, c) => c().ModifyArchive(path, names, password));
    }

    /// <summary>
    /// Adds files and folders into the archive under <paramref name="prefix"/> ("" or "dir/sub/").
    /// A name already in the archive goes to <paramref name="onConflict"/>: Overwrite replaces it, Skip keeps the
    /// old one, null cancels before anything is written.
    /// </summary>
    public static Task Append(Archive a, IReadOnlyList<string> inputs, string prefix, CompressOptions o,
                              IProgress<(int percent, string file)> progress, CancellationToken ct,
                              Func<string, OverwriteMode?> onConflict)
    {
        var existing = new Dictionary<string, ArchiveFileInfo>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in a.X.ArchiveFileData) existing.TryAdd(Norm(f.FileName), f);   // read here: X is bound to this thread
        return Edit(a, (path, password, c) =>
        {
            var dict = BuildDict(inputs, prefix.Replace('/', '\\'));
            if (dict.Count == 0) throw new InvalidOperationException(S.NoInputs);
            var replace = new Dictionary<int, string>();
            foreach (var (name, file) in dict.ToList())
            {
                if (!existing.TryGetValue(Norm(name), out var old)) continue;
                if (old.IsDirectory && file == null) { dict.Remove(name); continue; }   // the folder is there already
                switch (onConflict(Norm(name)))
                {
                    case OverwriteMode.Overwrite: replace[old.Index] = null!; break;
                    case OverwriteMode.Skip: dict.Remove(name); break;
                    default: throw new OperationCanceledException();
                }
            }
            if (replace.Count > 0) c().ModifyArchive(path, replace, password);
            if (dict.Count == 0) return;
            var add = c();
            add.CompressionMode = CompressionMode.Append;
            Apply(add, o);
            Run(add, dict, path, password, progress, 0, 100, ct);
            progress.Report((100, ""));
        });
    }

    // ---- misc ----------------------------------------------------------------------------------

    public static string NiceSize(long b) => b switch
    {
        < 1024 => $"{b} B",
        < 1024L * 1024 => $"{b / 1024.0:0.#} KB",
        < 1024L * 1024 * 1024 => $"{b / (1024.0 * 1024):0.#} MB",
        _ => $"{b / (1024.0 * 1024 * 1024):0.##} GB",
    };

    public static string NewTempDir()
    {
        var d = Path.Combine(Path.GetTempPath(), "MakePack", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        lock (Temps) Temps.Add(d);
        return d;
    }

    public static void Nuke(string dir) { try { Directory.Delete(dir, true); } catch { } }
    public static void TryDelete(string file) { try { File.Delete(file); } catch { } }
}
