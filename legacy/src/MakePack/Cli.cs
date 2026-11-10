using SevenZip;

namespace MakePack;

/// <summary>
/// The scriptable commands: no main window, no mutex, output to stdout, errors to stderr, exit codes
/// (Engine.ExitCodeOf). A password never travels in the arguments: -p asks for it in a window, and
/// MAKEPACK_PASSWORD serves unattended runs.
///   t [-p] archive                        test
///   l [-p] archive                        list (the text report)
///   a -switch... archive files|masks...   create: -t7z|zip|tar|tar.gz|..., -m0..5, -v100m, -p, -hp, -y
///   x -y [-p] archive [-o dir | --sub]    extract quietly, overwriting
/// </summary>
static class Cli
{
    const string PasswordVariable = "MAKEPACK_PASSWORD";

    /// <summary>null = not a scripted command; the GUI takes the arguments.</summary>
    public static int? Run(string[] args)
    {
        if (args.Length < 2) return null;
        var headless = args[0] switch
        {
            "t" or "l" => true,
            "a" => args[1].StartsWith('-') && !args[1].StartsWith("--"),   // a <paths> / a --quick: Explorer's verbs
            "x" => args.Contains("-y"),
            _ => false,
        };
        if (!headless) return null;
        Program.UseConsole();

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        try
        {
            return args[0] switch
            {
                "t" => Test(args[1..], cts.Token),
                "l" => List(args[1..]),
                "a" => Add(args[1..], cts.Token),
                _ => Extract(args[1..], cts.Token),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(Engine.Friendly(ex));
            return Engine.ExitCodeOf(ex);
        }
    }

    static int Test(string[] args, CancellationToken ct)
    {
        var (switches, rest) = Split(args, "-p");
        using var a = Open(One(rest), switches.Contains("-p"));
        NeedBodyPassword(a);
        if (!Engine.Test(a, Engine.NoProgress, ct).GetAwaiter().GetResult()) throw new InvalidDataException(S.Damaged);
        Console.WriteLine(S.TestOk);
        return 0;
    }

    static int List(string[] args)
    {
        var (switches, rest) = Split(args, "-p");
        using var a = Open(One(rest), switches.Contains("-p"));
        Console.Write(Engine.Report(a, html: false));
        return 0;
    }

    static int Extract(string[] args, CancellationToken ct)
    {
        string? dest = null;
        var sub = false;
        var rest = new List<string>();
        for (var i = 0; i < args.Length; i++)
            switch (args[i])
            {
                case "-y" or "-p": break;
                case "--sub": sub = true; break;
                case "--here": break;
                case "-o" when i + 1 < args.Length: dest = args[++i]; break;
                default: rest.Add(args[i].StartsWith('-') ? Refuse(args[i]) : args[i]); break;
            }
        var archive = One(rest);
        using var a = Open(archive, args.Contains("-p"));
        NeedBodyPassword(a);
        var dir = Path.GetDirectoryName(Path.GetFullPath(archive))!;
        dest ??= sub ? Path.Combine(dir, Engine.BaseName(archive)) : dir;
        Engine.Extract(a, dest, null, OverwriteMode.Overwrite, Engine.NoProgress, ct, _ => OverwriteMode.Overwrite)
              .GetAwaiter().GetResult();
        return 0;
    }

    static int Add(string[] args, CancellationToken ct)
    {
        var kind = (ArchiveKind?)null;
        var level = CompressionLevel.Normal;
        long volume = 0;
        bool ask = false, headers = false, overwrite = false;
        var rest = new List<string>();
        foreach (var arg in args)
        {
            if (!arg.StartsWith('-') || rest.Count > 0) { rest.Add(arg); continue; }   // switches go before the archive name
            var s = arg.ToLowerInvariant();
            if (s.StartsWith("-t")) kind = KindNamed(s[2..]) ?? throw Bad(arg);
            else if (s.Length == 3 && s[1] == 'm' && s[2] is >= '0' and <= '5') level = (CompressionLevel)(s[2] - '0');
            else if (s.StartsWith("-v")) volume = Engine.ParseSize(s[2..]) is long v and > 0 ? v : throw Bad(arg);
            else if (s == "-p") ask = true;
            else if (s == "-hp") ask = headers = true;
            else if (s == "-y") overwrite = true;
            else throw Bad(arg);
        }
        if (rest.Count < 2) throw Bad(rest.Count == 0 ? "<archive>" : "<files>");

        var archive = Path.GetFullPath(rest[0]);
        kind ??= Engine.Kinds.Where(k => archive.EndsWith(k.Ext, StringComparison.OrdinalIgnoreCase))
                             .OrderByDescending(k => k.Ext.Length).Select(k => (ArchiveKind?)k.Kind).FirstOrDefault() ?? ArchiveKind.SevenZip;
        var info = Engine.Kind(kind.Value);
        if (Path.GetExtension(archive) == "") archive += info.Ext;

        var inputs = rest.Skip(1).SelectMany(Expand).ToList();
        // Only with -p/-hp: a MAKEPACK_PASSWORD left in the environment must not encrypt archives nobody asked to.
        var password = ask ? Password(Path.GetFileName(archive), ask, confirm: true) : null;
        if (password != null && !info.Password) throw new ArgumentException(string.Format(S.CliNoPasswordFmt, info.Name));
        if (headers && kind != ArchiveKind.SevenZip) throw Bad("-hp");

        var taken = volume > 0 ? File.Exists(Engine.Part(archive, 1)) : File.Exists(archive);
        if (taken && !overwrite) throw new IOException(string.Format(S.CliExistsFmt, archive));
        if (taken && volume == 0) File.Delete(archive);   // a set is replaced part by part by Compress itself

        var o = new CompressOptions(level, password, headers, VolumeSize: volume);
        Engine.Compress(inputs, archive, kind.Value, o, Engine.NoProgress, ct).GetAwaiter().GetResult();
        return 0;
    }

    // ---- helpers -------------------------------------------------------------------------------

    static ArchiveKind? KindNamed(string name)
    {
        name = name switch { "tgz" => "tar.gz", "tbz2" => "tar.bz2", "txz" => "tar.xz", _ => name };
        return Engine.Kinds.FirstOrDefault(k => k.Name == name)?.Kind;
    }

    /// <summary>A path, or a mask in its last part (cmd hands "*.txt" over as is).</summary>
    static IEnumerable<string> Expand(string arg)
    {
        var full = Path.GetFullPath(arg);
        if (File.Exists(full) || Directory.Exists(full)) return [full];
        var dir = Path.GetDirectoryName(full);
        var mask = Path.GetFileName(full);
        string[] hits = mask.IndexOfAny(['*', '?']) >= 0 && Directory.Exists(dir) ? Directory.GetFileSystemEntries(dir, mask) : [];
        return hits.Length > 0 ? hits : throw new FileNotFoundException(string.Format(S.CliNoMatchFmt, arg));
    }

    static (HashSet<string> Switches, List<string> Others) Split(string[] args, params string[] known)
    {
        var switches = new HashSet<string>();
        var rest = new List<string>();
        foreach (var a in args)
            if (a.StartsWith('-')) switches.Add(known.Contains(a) ? a : Refuse(a));
            else rest.Add(a);
        return (switches, rest);
    }

    static string Refuse(string arg) => throw Bad(arg);

    static ArgumentException Bad(string arg) =>
        new(arg.StartsWith("-p", StringComparison.OrdinalIgnoreCase) || arg.StartsWith("-hp", StringComparison.OrdinalIgnoreCase)
            ? S.CliPasswordInArgs : string.Format(S.CliBadSwitchFmt, arg));

    static string One(List<string> rest) => rest.Count == 1 ? rest[0] : throw Bad(rest.Count == 0 ? "<archive>" : rest[1]);

    /// <summary>MAKEPACK_PASSWORD first (unattended runs); otherwise -p asks in a window.</summary>
    static string Password(string title, bool ask, bool confirm = false)
    {
        if (Environment.GetEnvironmentVariable(PasswordVariable) is { Length: > 0 } env) return env;
        if (!ask) throw new InvalidDataException(S.PasswordNeeded);
        var first = PasswordForm.Ask(null, title, confirm ? S.Password + ":" : null) ?? throw new OperationCanceledException();
        if (confirm && PasswordForm.Ask(null, title, S.Confirm) != first) throw new InvalidDataException(S.PasswordsDiffer);
        return first;
    }

    /// <summary>The same checks as PasswordForm.OpenArchive, as exceptions instead of message boxes.</summary>
    static Archive Open(string path, bool ask)
    {
        if (!File.Exists(path)) throw new FileNotFoundException(string.Format(S.FileNotFoundFmt, path));
        string? password = null;
        switch (Engine.Probe(path))
        {
            case Probe.NotArchive: throw new IOException(S.NotAnArchive);
            case Probe.Damaged: throw new InvalidDataException(S.Damaged);
            case Probe.EncryptedHeaders: password = Password(Path.GetFileName(path), ask); break;
        }
        if (password == null && (ask || Environment.GetEnvironmentVariable(PasswordVariable) is { Length: > 0 }))
            password = Password(Path.GetFileName(path), ask);   // given up front: used for the bodies too
        try { return Engine.Open(path, password); }
        catch (Exception ex) when (Engine.CanEncryptHeaders(path) && ex is not OperationCanceledException)
        {
            throw new InvalidDataException(password == null ? S.PasswordNeeded : S.WrongPassword, ex);
        }
    }

    static void NeedBodyPassword(Archive a)
    {
        if (a.Password == null && a.X.ArchiveFileData.Any(f => f.Encrypted)) throw new InvalidDataException(S.PasswordNeeded);
    }
}
