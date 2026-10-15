using System.Text.Json;
using System.Text.Json.Serialization;
using SevenZip;

namespace MakePack;

/// <summary>
/// The user's options, kept in %APPDATA%\MakePack\settings.json. A missing or broken file means defaults;
/// the next Save simply writes a good one over it.
/// </summary>
sealed class Settings
{
    /// <summary>Last format and level picked in the New archive dialog.</summary>
    public ArchiveKind Format { get; set; } = ArchiveKind.SevenZip;
    public CompressionLevel Level { get; set; } = CompressionLevel.Normal;

    /// <summary>"Test the archive when done". Deleting the sources is never remembered.</summary>
    public bool TestAfter { get; set; }

    /// <summary>The Advanced block of that dialog; same meaning as the CompressOptions fields of the same name.</summary>
    public bool ShowAdvanced { get; set; }
    public CompressionMethod Method { get; set; } = CompressionMethod.Default;
    public long Dictionary { get; set; }
    public string? Solid { get; set; }
    public int Threads { get; set; }
    public string? Filter { get; set; }

    /// <summary>The extract dialog's last choices.</summary>
    public OverwriteMode ExtractOverwrite { get; set; } = OverwriteMode.Ask;
    public bool ExtractNoPaths { get; set; }
    public UpdateMode ExtractUpdate { get; set; } = UpdateMode.Replace;
    public bool ExtractKeepBroken { get; set; }
    public DeleteAfter ExtractDeleteAfter { get; set; } = DeleteAfter.Never;

    /// <summary>Which extracted files inherit the archive's "from the Internet" mark.</summary>
    public MotwPolicy Motw { get; set; } = MotwPolicy.Risky;

    /// <summary>Where new archives go. null = next to the files being packed.</summary>
    public string? ArchiveFolder { get; set; }

    /// <summary>Named option sets for the New archive dialog and `a --profile`; at most one IsDefault.</summary>
    public List<Profile> Profiles { get; set; } = [];

    public Profile? FindProfile(string name) =>
        Profiles.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), S.App, "settings.json");

    /// <summary>This process's copy. One process per session (see Program), so no cross-process merging.</summary>
    public static Settings Current { get; private set; } = Load(DefaultPath);

    public static Settings Load(string path)
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json) ?? new(); }
        catch { return new(); }   // missing, unreadable or hand-broken: defaults
    }

    /// <summary>Best effort: losing a remembered option is not worth an error box.</summary>
    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";   // write-then-move, so a crash mid-write never leaves half a file
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
            File.Move(tmp, path, true);
        }
        catch { /* read-only profile, full disk... */ }
    }

    public static void Update(Action<Settings> change)
    {
        change(Current);
        Current.Save(DefaultPath);
    }

    public static void Reset() { Current = new(); Current.Save(DefaultPath); }
}

/// <summary>
/// A named set of New-archive options (compression profiles). Never a password: the encryption flags
/// only take effect once one is typed in the dialog.
/// </summary>
sealed class Profile
{
    public string Name { get; set; } = "";
    /// <summary>Applied whenever the New archive dialog opens.</summary>
    public bool IsDefault { get; set; }
    /// <summary>Has its own "Add to name (profile)" item in Explorer's menu, which runs `a --profile` (no dialog).</summary>
    public bool InMenu { get; set; }
    public ArchiveKind Format { get; set; } = ArchiveKind.SevenZip;
    public CompressionLevel Level { get; set; } = CompressionLevel.Normal;
    public CompressionMethod Method { get; set; } = CompressionMethod.Default;   // default(enum) is Copy
    public long Dictionary { get; set; }
    public string? Solid { get; set; }
    public int Threads { get; set; }
    public string? Filter { get; set; }
    /// <summary>As typed in the Volumes box ("700 MB (CD)"); empty = one file.</summary>
    public string Volumes { get; set; } = "";
    public bool TestAfter { get; set; }
    public bool DeleteSources { get; set; }
    public bool Separate { get; set; }
    public bool Sfx { get; set; }
    public bool EncryptNames { get; set; }
    public bool ZipCrypto { get; set; }

    public Profile Copy() => (Profile)MemberwiseClone();

    public string Ext => Sfx ? ".exe" : Engine.Kind(Format).Ext;

    /// <summary>What a run without the dialog uses (CLI, Explorer menu): no password, so no encryption either.</summary>
    public CompressOptions ToOptions() => new(Level, null, false, Method, Dictionary, Solid, Threads, Filter,
                                              Engine.ParseSize(Volumes) ?? 0, TestAfter, DeleteSources, Sfx);
}
