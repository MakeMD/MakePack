using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using SevenZip;

namespace MakePack;

static class Program
{
    static Control _ui = null!;          // hidden message-loop anchor: every dispatch is marshalled onto it
    static Mutex? _mutex;
    static MainForm? _main;
    static CompressForm? _form;
    static int _exit;

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--selftest") return SelfTest();
        if (args.Length > 0 && args[0] is "--register" or "--unregister" or "--addmenu") return RegistryVerb(args);

        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => Fail(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Fail(e.ExceptionObject as Exception);

        if (args.Length > 0 && args[0] == "--assoc") { AssocForm.Edit(null); return 0; }   // the dialog, standalone
        if (args.Length > 0 && args[0] == "--settings") { SettingsForm.Edit(null); return 0; }
        if (Cli.Run(args) is int code) return code;   // t, l, a -switches, x -y: scripts, no window, no queue

        // One process per session. Explorer runs its verbs once per selected item, so three archives
        // used to mean three windows and five "Extract here" five progress dialogs. Whoever takes the
        // mutex owns the UI; every other instance hands over its argument list and leaves.
        var name = "MakePack-" + Process.GetCurrentProcess().SessionId;
        _mutex = new Mutex(false, name);
        bool server;
        try { server = _mutex.WaitOne(0); }
        catch (AbandonedMutexException) { server = true; }
        if (!server && Send(name, Absolute(args))) return 0;
        // Not the server and nobody answered within 1.5 s: the server was on its way out as we knocked.
        // ponytail: run standalone instead of retrying - the next invocation takes the free mutex.

        _ui = new Control();
        _ = _ui.Handle;                  // parks a hidden window; BeginInvoke needs one
        if (server)
        {
            Serve(name);
            try { Assoc.Heal(); } catch { /* a broken registry must never stop the app from starting */ }
        }
        Post(args);
        Application.Run(new ApplicationContext());

        if (server) { try { _mutex.ReleaseMutex(); } catch { /* abandoned */ } }   // held until the very end
        _mutex.Dispose();
        return _exit;
    }

    static void Fail(Exception? ex)
    {
        MessageBox.Show(ex == null ? S.Error : Engine.Friendly(ex), S.App, MessageBoxButtons.OK, MessageBoxIcon.Error);
        // A crash with a window still up is survivable; one with nothing on screen would hang Explorer's verb.
        if (Application.OpenForms.Count == 0) Environment.Exit(1);
    }

    // ---- dispatch ------------------------------------------------------------------------------
    // Both our own arguments and every forwarded set land here, on the UI thread.

    static void Post(string[] args)
    {
        // ponytail: a dispatch that arrives while a modal dialog is up still runs - the window it opens
        // is simply disabled until the dialog closes. Holding it back needs state nobody has asked for.
        try { _ui.BeginInvoke(() => Dispatch(args)); } catch { /* shutting down */ }
    }

    static void Dispatch(string[] args)
    {
        if (args.Length > 1 && args[0] == "x") Enqueue(args);
        else if (args.Length > 2 && args[0] == "a" && args[1] == "--quick") Gather("\0quick", args[2..], QuickProfile);
        else if (args.Length > 3 && args[0] == "a" && args[1] == "--profile")
        {
            var name = args[2];
            Gather(name, args[3..], () => Settings.Current.FindProfile(name) ?? NoSuchProfile(name));
        }
        else if (args.Length > 1 && args[0] == "a") Add(args[1..]);
        else if (args.Length > 1 && args[0] == "convert")
        {
            var f = new ConvertForm(args[1..]);
            f.FormClosed += (_, _) => MaybeExit();
            f.Show();
            Raise(f);
        }
        else OpenMain(args.Length > 0 ? args[0] : null);
        MaybeExit();
    }

    /// <summary>Nothing on screen and nothing queued: the session is over.</summary>
    static void MaybeExit()
    {
        if (Application.OpenForms.Count == 0 && !Busy) Application.ExitThread();
    }

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

    /// <summary>Activate() alone does not raise a window when the invocation came from another process.</summary>
    static void Raise(Form f)
    {
        if (f.WindowState == FormWindowState.Minimized) f.WindowState = FormWindowState.Normal;
        f.Activate();
        SetForegroundWindow(f.Handle);
    }

    // ---- <archive> (or nothing): the main window ------------------------------------------------

    static void OpenMain(string? archive)
    {
        if (_main is { IsDisposed: false })
        {
            if (archive != null) _main.OpenArchive(archive);   // ponytail: one window; tabs/second window when someone asks
            Raise(_main);
            return;
        }
        _main = new MainForm(archive);
        _main.FormClosed += (_, _) => { _main = null; MaybeExit(); };
        _main.Show();
        Raise(_main);
    }

    // ---- a <path> [<path> ...]: the compress dialog ---------------------------------------------

    static readonly List<string> _pending = [];

    static void Add(string[] paths)
    {
        lock (_pending) _pending.AddRange(paths);
        if (_form is { IsDisposed: false }) { Drain(); Raise(_form); return; }

        // ponytail: blocks the UI thread for 400 ms so Explorer's sibling invocations land in the same
        // dialog instead of flashing one up with a single file. A timer would buy nothing here.
        Thread.Sleep(400);
        List<string> initial;
        lock (_pending) { initial = [.. _pending]; _pending.Clear(); }

        var form = new CompressForm(initial);
        form.Shown += (_, _) => Drain();
        form.FormClosed += (_, _) => { lock (_pending) _form = null; MaybeExit(); };
        lock (_pending) _form = form;
        form.Show();
        Raise(form);
    }

    static void Drain()
    {
        CompressForm form;
        List<string> paths;
        lock (_pending)
        {
            if (_form is not { IsHandleCreated: true } f || _pending.Count == 0) return;
            form = f;
            paths = [.. _pending];
            _pending.Clear();
        }
        try { form.BeginInvoke(() => form.AddInputs(paths)); } catch { /* closing */ }
    }

    // ---- a --quick | --profile <name>  <path> [<path> ...]: straight to the archive, no dialog -----
    // What Explorer's "Add to name.7z" and the profiles' menu items run ("Add to <name>").

    static readonly Dictionary<string, List<string>> _quick = new(StringComparer.OrdinalIgnoreCase);
    static int _quickRuns;

    /// <summary>"Add to name.ext": the format picked for it in the Associations dialog, the last level used.</summary>
    static Profile? QuickProfile() => new() { Name = "quick", Format = Assoc.QuickKind, Level = Settings.Current.Level };

    static Profile? NoSuchProfile(string name)
    {
        MessageBox.Show(string.Format(S.ProfileNotFoundFmt, name), S.App, MessageBoxButtons.OK, MessageBoxIcon.Error);
        return null;
    }

    static async void Gather(string key, string[] paths, Func<Profile?> profile)
    {
        // Explorer runs the verb once per selected item: the first call opens a 400 ms window, the
        // siblings that land in it join the same archive. Unlike Add() this one waits without blocking.
        if (_quick.TryGetValue(key, out var more)) { more.AddRange(paths); return; }
        _quick[key] = [.. paths];
        await Task.Delay(400);
        var all = _quick[key];
        _quick.Remove(key);
        _quickRuns++;
        try { if (!await RunProfile(profile(), all)) _exit = 1; }
        finally { _quickRuns--; MaybeExit(); }
    }

    static async Task<bool> RunProfile(Profile? p, List<string> paths)
    {
        if (p == null) return false;
        var o = p.ToOptions();
        var folder = Settings.Current.ArchiveFolder;
        var plan = p.Separate ? Engine.PlanSeparate(paths, p.Ext, folder) : null;
        var single = Engine.DefaultArchivePath(paths, p.Ext, folder);
        if (!CompressForm.ConfirmOverwrite(null, plan?.Select(x => x.Output) ?? [single], o.VolumeSize)) return false;

        using var progress = new ProgressForm(S.Compressing);
        return await progress.RunAsync(null, (pr, ct) => plan != null ? Engine.CompressEach(plan, p.Format, o, pr, ct)
                                                                      : Engine.Compress(paths, single, p.Format, o, pr, ct));
    }

    // ---- x <archive> [--here | --sub | -o dir]: the extract queue -------------------------------
    // Jobs run one at a time on the UI thread under a single progress window. Cancel kills the
    // running job and drops the rest; an error reports itself and the queue carries on.

    static readonly Queue<string[]> _jobs = new();
    static bool _running;
    static int _done, _total;

    static bool Busy => _running || _jobs.Count > 0 || _quick.Count > 0 || _quickRuns > 0;

    static void Enqueue(string[] job)
    {
        _jobs.Enqueue(job);
        _total++;
        if (!_running) _ = Pump();
    }

    static async Task Pump()
    {
        _running = true;
        try
        {
            using var progress = new ProgressForm(S.Extracting);
            await progress.RunAsync(null, async (p, ct) =>
            {
                while (_jobs.Count > 0)
                {
                    var job = _jobs.Dequeue();
                    progress.Text = string.Format(S.ExtractingNofM, ++_done, _total, Path.GetFileName(job[1]));
                    // ponytail: the last failure's code wins, as with classic archivers over a list of archives.
                    try { if (await Extract(progress, job, p, ct) is var code and not 0) _exit = code; }
                    catch (OperationCanceledException) { _jobs.Clear(); _exit = 255; return; }
                    catch (Exception ex)
                    {
                        _exit = Engine.ExitCodeOf(ex);
                        MessageBox.Show(progress, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            });
        }
        finally
        {
            _running = false;
            if (_jobs.Count > 0) _ = Pump();              // a job that arrived while we were closing down
            else { _done = _total = 0; MaybeExit(); }
        }
    }

    /// <summary>One "x" invocation. Returns the exit code of a prompt that ended it (255 = cancelled), 0 = done.</summary>
    static async Task<int> Extract(ProgressForm progress, string[] args,
                                    IProgress<(int percent, string file)> p, CancellationToken ct)
    {
        var archive = args[1];
        string? dest = null;
        bool here = false, sub = false;
        for (var i = 2; i < args.Length; i++)
            switch (args[i])
            {
                case "--here": here = true; break;
                case "--sub": sub = true; break;
                case "-o" when i + 1 < args.Length: dest = args[++i]; break;
            }

        progress.Visible = false;                   // the prompts come first: a progress bar behind a password box helps nobody
        var a = PasswordForm.OpenArchive(null, archive, out var failed);
        try
        {
            if (a == null) return failed;
            var ready = PasswordForm.EnsurePassword(null, a);     // bodies encrypted but headers not
            if (ready == null) return 255;
            if (!ReferenceEquals(ready, a)) { a.Dispose(); a = ready; }

            var mode = OverwriteMode.Ask;
            ExtractChoice? choice = null;     // the dialog's extras; Extract here / to folder\ keep the plain defaults
            var dir = Path.GetDirectoryName(Path.GetFullPath(archive)) ?? Environment.CurrentDirectory;
            if (here) dest = dir;
            else if (sub) dest = Path.Combine(dir, Engine.BaseName(archive));
            else if (dest == null)
            {
                choice = ExtractForm.Ask(null, a);
                if (choice == null) return 255;
                (dest, mode) = (choice.Dest, choice.Mode);
            }

            progress.Visible = true;
            await Engine.Extract(a, dest, null, mode, p, ct, ExtractForm.Conflicts(progress), options: choice?.Options);
            if (choice != null) ExtractForm.AfterExtract(progress, archive, choice.Delete, () => { a.Dispose(); a = null; });
            return 0;
        }
        finally { a?.Dispose(); progress.Visible = true; }
    }

    // ---- the pipe ------------------------------------------------------------------------------
    // One UTF-8 line per argument, one connection per invocation.

    static bool Send(string name, string[] args)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(1500);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", name, PipeDirection.Out);
                client.Connect(200);
                using var writer = new StreamWriter(client, new UTF8Encoding(false));
                foreach (var a in args) writer.WriteLine(a);
                writer.Flush();
                return true;
            }
            catch { Thread.Sleep(50); }
        }
        return false;
    }

    static void Serve(string name) => Task.Run(async () =>
    {
        while (true)
        {
            try
            {
                using var server = new NamedPipeServerStream(name, PipeDirection.In,
                    NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync();
                using var reader = new StreamReader(server, new UTF8Encoding(false));
                var got = new List<string>();
                while (await reader.ReadLineAsync() is { } line)
                    if (line.Length > 0) got.Add(line);
                Post([.. got]);                     // no arguments at all = "show me the window"
            }
            catch { await Task.Delay(50); }
        }
    });

    /// <summary>Explorer's working directory is not the one a shell hands us, so paths travel absolute.</summary>
    static string[] Absolute(string[] args)
    {
        var copy = (string[])args.Clone();
        for (var i = 0; i < copy.Length; i++)
        {
            if (i == 0 ? copy[0] is "x" or "a" or "convert" : copy[i] is "--here" or "--sub" or "-o" or "--profile" or "--quick") continue;
            if (i > 0 && copy[i - 1] == "--profile") continue;   // a profile name, not a path
            if (Path.IsPathRooted(copy[i])) continue;
            try { copy[i] = Path.GetFullPath(copy[i]); } catch { /* not a path after all */ }
        }
        return copy;
    }

    // ---- --register [defaults|ext,ext] / --unregister [ext,ext] / --addmenu on|off -------------
    // Silent, no UI, exit 0/1. The installer calls these; the toolbar button opens AssocForm instead.

    static int RegistryVerb(string[] args)
    {
        try
        {
            var arg = args.Length > 1 ? args[1] : "";
            var list = arg.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                          .Select(e => e.TrimStart('.').ToLowerInvariant()).ToArray();
            switch (args[0])
            {
                case "--register" when list.Length == 0 || arg == "defaults":
                    foreach (var ext in Assoc.All) Assoc.Register(ext, false);
                    break;
                case "--register":
                    foreach (var ext in list) Assoc.Register(ext, true);
                    break;
                case "--unregister" when list.Length == 0:
                    Assoc.UnregisterAll();
                    break;
                case "--unregister":
                    foreach (var ext in list) Assoc.Unregister(ext);
                    break;
                case "--addmenu":
                    Assoc.SetAddMenu(arg == "on");
                    break;
            }
            Assoc.Notify();
            return 0;
        }
        catch (Exception ex) { UseConsole(); Console.WriteLine(ex.Message); return 1; }
    }

    // ---- --selftest ----------------------------------------------------------------------------

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int processId);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);

    /// <summary>Gives this GUI subsystem process a usable stdout.</summary>
    static bool _console;

    internal static void UseConsole()
    {
        if (_console) return;   // once: the selftest swaps Console.Out afterwards and wants to keep it
        _console = true;
        // Attaching hijacks the standard handles, so only do it when we have none (AttachConsole
        // would otherwise steal output away from a caller that redirected us to a pipe or file).
        var stdout = GetStdHandle(-11);
        if (stdout == IntPtr.Zero || stdout == -1) AttachConsole(-1);   // ATTACH_PARENT_PROCESS
        try { Console.OutputEncoding = Encoding.UTF8; } catch { /* no console attached */ }
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
        Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
    }

    static int SelfTest()
    {
        UseConsole();

        var root = Path.Combine(Path.GetTempPath(), "MakePack-selftest-" + Guid.NewGuid().ToString("N")[..8]);
        var src = Path.Combine(root, "src");
        var fails = 0;

        void Check(string what, Action body)
        {
            try { body(); }
            catch (Exception ex) { Console.WriteLine($"FAIL {what}: {ex.Message}"); fails++; }
        }
        static void Must(bool ok, string what) { if (!ok) throw new Exception(what); }

        try
        {
            Directory.CreateDirectory(Path.Combine(src, "sub", "deeper"));
            var rnd = new Random(20260913);
            Noise(Path.Combine(src, "a.txt"), 10 * 1024, rnd);
            Noise(Path.Combine(src, "sub", "b.bin"), 1024 * 1024, rnd);
            File.WriteAllText(Path.Combine(src, "sub", "deeper", "тест ïé.txt"), "Привіт, світ! ïé\r\n", new UTF8Encoding(false));
            File.WriteAllBytes(Path.Combine(src, "empty.txt"), []);
            Directory.CreateDirectory(Path.Combine(src, "void", "deeper"));   // empty folders: Same() checks they come back

            foreach (var kind in new[] { ArchiveKind.SevenZip, ArchiveKind.Zip, ArchiveKind.Tar,
                                         ArchiveKind.TarGz, ArchiveKind.TarBz2, ArchiveKind.TarXz, ArchiveKind.Wim })
                Check(kind.ToString(), () => RoundTrip(kind, src, root));

            Check("7z+password", () =>
            {
                var archive = Path.Combine(root, "secret.7z");
                Pack([src], archive, ArchiveKind.SevenZip, "hunter2", true);
                var opened = false;
                try { Engine.Open(archive, null).Dispose(); opened = true; } catch { /* expected */ }
                if (opened) throw new Exception("opened with encrypted headers and no password");
                using var a = Engine.Open(archive, "hunter2");
                Unpack(a, Path.Combine(root, "out-secret"), OverwriteMode.Overwrite);
                Same(src, Path.Combine(root, "out-secret", "src"));
                Console.WriteLine($"OK 7z+password ({new FileInfo(archive).Length} bytes)");
            });

            Check("zip+aes", () =>
            {
                var archive = Path.Combine(root, "secret.zip");
                Pack([src], archive, ArchiveKind.Zip, "hunter2", false);
                using var a = Engine.Open(archive, "hunter2");
                Unpack(a, Path.Combine(root, "out-zipaes"), OverwriteMode.Overwrite);
                Same(src, Path.Combine(root, "out-zipaes", "src"));
                Console.WriteLine($"OK zip+aes ({new FileInfo(archive).Length} bytes)");
            });

            Check("empty_dirs", () =>
            {
                foreach (var kind in new[] { ArchiveKind.SevenZip, ArchiveKind.Zip, ArchiveKind.Tar })
                    if (!Directory.Exists(Path.Combine(root, "out-" + kind, "src", "void", "deeper")))
                        throw new Exception(kind + ": the empty folder did not come back");
                Console.WriteLine("OK empty_dirs");
            });

            // The edits below work on copies, so the fixtures above stay as packed.
            string Fresh(string name, string copy)
            {
                var p = Path.Combine(root, copy);
                File.Copy(Path.Combine(root, name), p, true);
                return p;
            }
            var extra = Path.Combine(root, "extra.txt");
            File.WriteAllText(extra, "appended later");

            Check("append", () =>
            {
                foreach (var name in new[] { "SevenZip.7z", "Zip.zip", "Tar.tar", "Wim.wim" })
                {
                    var archive = Fresh(name, "append-" + name);
                    var before = Count(archive, null);
                    Append(archive, null, [extra], "src/sub/", OverwriteMode.Overwrite);
                    if (Count(archive, null) != before + 1) throw new Exception($"{name}: {before} entries before, {Count(archive, null)} after");
                    var dest = Path.Combine(root, "out-append-" + name);
                    using (var a = Engine.Open(archive, null)) Unpack(a, dest, OverwriteMode.Overwrite);
                    Same(src, Path.Combine(dest, "src"));
                    if (File.ReadAllText(Path.Combine(dest, "src", "sub", "extra.txt")) != "appended later") throw new Exception(name + ": appended file differs");
                }
                // Header-encrypted 7z: the new file gets in, and the list stays behind the password.
                var secret = Fresh("secret.7z", "append-secret.7z");
                var n = Count(secret, "hunter2");
                Append(secret, "hunter2", [extra], "", OverwriteMode.Overwrite);
                if (Count(secret, "hunter2") != n + 1) throw new Exception("encrypted 7z: count did not grow");
                if (Opens(secret)) throw new Exception("encrypted 7z: the file list opened without a password after append");
                Console.WriteLine("OK append (7z, zip, tar, wim, 7z with encrypted headers)");
            });

            Check("append_replace", () =>
            {
                foreach (var name in new[] { "SevenZip.7z", "Zip.zip" })
                {
                    var archive = Fresh(name, "replace-" + name);
                    var before = Count(archive, null);
                    var dir = Path.Combine(root, "replace-src");
                    Directory.CreateDirectory(dir);
                    File.WriteAllText(Path.Combine(dir, "a.txt"), "replaced");
                    Append(archive, null, [Path.Combine(dir, "a.txt")], "src/", OverwriteMode.Overwrite);
                    if (Count(archive, null) != before) throw new Exception($"{name}: {before} entries before, {Count(archive, null)} after");
                    var dest = Path.Combine(root, "out-replace-" + name);
                    using (var a = Engine.Open(archive, null)) Unpack(a, dest, OverwriteMode.Overwrite);
                    if (File.ReadAllText(Path.Combine(dest, "src", "a.txt")) != "replaced") throw new Exception(name + ": old content survived");

                    File.WriteAllText(Path.Combine(dir, "a.txt"), "skipped");
                    Append(archive, null, [Path.Combine(dir, "a.txt")], "src/", OverwriteMode.Skip);
                    using (var a = Engine.Open(archive, null)) Unpack(a, dest, OverwriteMode.Overwrite);
                    if (File.ReadAllText(Path.Combine(dest, "src", "a.txt")) != "replaced") throw new Exception(name + ": Skip replaced the file");
                }
                Console.WriteLine("OK append_replace");
            });

            Check("rename_file", () =>
            {
                foreach (var (name, password) in new[] { ("SevenZip.7z", (string?)null), ("Zip.zip", null), ("secret.7z", "hunter2") })
                {
                    var archive = Fresh(name, "renfile-" + name);
                    var before = Count(archive, password);
                    using (var a = Engine.Open(archive, password)) Engine.Rename(a, "src/a.txt", "src/b renamed.txt").GetAwaiter().GetResult();
                    var dest = Path.Combine(root, "out-renfile-" + name);
                    using (var a = Engine.Open(archive, password))
                    {
                        if (a.X.ArchiveFileData.Count != before) throw new Exception(name + ": entry count changed");
                        Unpack(a, dest, OverwriteMode.Overwrite);
                    }
                    if (File.Exists(Path.Combine(dest, "src", "a.txt"))) throw new Exception(name + ": the old name is still there");
                    if (!File.ReadAllBytes(Path.Combine(src, "a.txt")).SequenceEqual(File.ReadAllBytes(Path.Combine(dest, "src", "b renamed.txt"))))
                        throw new Exception(name + ": renamed file differs");
                    if (password != null && Opens(archive)) throw new Exception(name + ": the file list opened without a password after rename");
                }
                Console.WriteLine("OK rename_file");
            });

            Check("rename_folder", () =>
            {
                foreach (var name in new[] { "SevenZip.7z", "Zip.zip", "Tar.tar" })
                {
                    var archive = Fresh(name, "rendir-" + name);
                    using (var a = Engine.Open(archive, null)) Engine.Rename(a, "src/sub", "src/moved").GetAwaiter().GetResult();
                    var dest = Path.Combine(root, "out-rendir-" + name);
                    using (var a = Engine.Open(archive, null))
                    {
                        if (a.X.ArchiveFileData.Any(f => Engine.Norm(f.FileName).StartsWith("src/sub", StringComparison.OrdinalIgnoreCase)))
                            throw new Exception(name + ": entries left under src/sub");
                        Unpack(a, dest, OverwriteMode.Overwrite);
                    }
                    Same(Path.Combine(src, "sub"), Path.Combine(dest, "src", "moved"));
                }
                Console.WriteLine("OK rename_folder");
            });

            Check("edit_guard", () =>
            {
                // A failing edit must leave the archive as it was: SevenZipSharp deletes it in a finally block.
                var secret = Fresh("secret.7z", "guard-secret.7z");
                var bytes = File.ReadAllBytes(secret);
                var failed = false;
                try
                {
                    var a = new Archive { X = new SevenZipExtractor(secret, "hunter2"), Source = secret, OpenPath = secret, Password = "WRONG" };
                    Engine.Append(a, [extra], "", CompressOptions.Default, Engine.NoProgress, default, _ => OverwriteMode.Overwrite).GetAwaiter().GetResult();
                }
                catch { failed = true; }
                if (!failed) throw new Exception("append with a wrong password did not fail");
                if (!File.Exists(secret) || !File.ReadAllBytes(secret).SequenceEqual(bytes)) throw new Exception("a failed append changed the archive");

                var seven = Fresh("SevenZip.7z", "guard-cancel.7z");
                bytes = File.ReadAllBytes(seven);
                using var cts = new CancellationTokenSource();
                var cancelled = false;
                try
                {
                    Engine.Append(Engine.Open(seven, null), [src], "copy/", CompressOptions.Default, new CancelOnReport(cts), cts.Token,
                                  _ => OverwriteMode.Overwrite).GetAwaiter().GetResult();
                }
                catch (OperationCanceledException) { cancelled = true; }
                if (!cancelled) throw new Exception("a cancelled append did not report the cancel");
                if (!File.ReadAllBytes(seven).SequenceEqual(bytes)) throw new Exception("a cancelled append changed the archive");
                if (File.Exists(seven + ".makepack~")) throw new Exception("the safety link was left behind");
                Console.WriteLine("OK edit_guard");
            });

            Check("delete", () =>
            {
                foreach (var name in new[] { "SevenZip.7z", "Zip.zip", "Tar.tar", "Wim.wim" })
                {
                    var archive = Fresh(name, "delete-" + name);
                    int before, after;
                    using (var a = Engine.Open(archive, null))
                    {
                        before = a.X.ArchiveFileData.Count;
                        Engine.Delete(a, [a.X.ArchiveFileData.First(f => !f.IsDirectory).Index]).GetAwaiter().GetResult();
                    }
                    using (var a = Engine.Open(archive, null)) after = a.X.ArchiveFileData.Count;
                    if (after != before - 1) throw new Exception($"{name}: {before} entries before, {after} after");
                }
                Console.WriteLine("OK delete (7z, zip, tar, wim)");
            });

            Check("check", () =>
            {
                using var a = Engine.Open(Path.Combine(root, "SevenZip.7z"), null);
                if (!Engine.Test(a, Engine.NoProgress, default).GetAwaiter().GetResult()) throw new Exception("Check() said false");
                Console.WriteLine("OK check");
            });

            Check("GZip", () =>
            {
                var archive = Path.Combine(root, "a.txt.gz");
                Pack([Path.Combine(src, "a.txt")], archive, ArchiveKind.GZip, null, false);
                using var a = Engine.Open(archive, null);
                if (a.Nested) throw new Exception("a plain .gz must not be treated as a tarball");
                var dest = Path.Combine(root, "out-gz");
                Unpack(a, dest, OverwriteMode.Overwrite);
                if (!File.ReadAllBytes(Path.Combine(src, "a.txt")).SequenceEqual(File.ReadAllBytes(Path.Combine(dest, "a.txt"))))
                    throw new Exception("a.txt differs");
                Console.WriteLine($"OK GZip ({new FileInfo(archive).Length} bytes)");
            });

            Check("conflicts", () =>
            {
                var dest = Path.Combine(root, "out-conflict");
                using var a = Engine.Open(Path.Combine(root, "Zip.zip"), null);
                Unpack(a, dest, OverwriteMode.Overwrite);
                var marked = Path.Combine(dest, "src", "a.txt");
                File.WriteAllText(marked, "marker");
                Unpack(a, dest, OverwriteMode.Skip);
                if (File.ReadAllText(marked) != "marker") throw new Exception("Skip overwrote the file");
                Unpack(a, dest, OverwriteMode.Rename);
                if (File.ReadAllText(marked) != "marker") throw new Exception("Rename overwrote the file");
                if (!File.Exists(Path.Combine(dest, "src", "a (2).txt"))) throw new Exception("Rename made no copy");
                Console.WriteLine("OK conflicts");
            });

            Check("probe", () =>
            {

                var text = Path.Combine(root, "plain.txt");
                File.WriteAllText(text, string.Concat(Enumerable.Repeat("plain text, definitely not an archive\r\n", 300)));
                Must(new FileInfo(text).Length >= 10 * 1024, "the text fixture is smaller than 10 KB");
                Must(Engine.Probe(text) == Probe.NotArchive, "10 KB of text was not called NotArchive");

                var renamed = Path.Combine(root, "renamed.7z");
                File.Copy(text, renamed, true);
                Must(Engine.Probe(renamed) == Probe.NotArchive, "a text file named .7z was not called NotArchive");

                var seven = Path.Combine(root, "SevenZip.7z");
                Must(Engine.Probe(seven) == Probe.Archive, "an intact 7z was not called Archive");
                Must(Engine.Probe(Path.Combine(root, "Zip.zip")) == Probe.Archive, "an intact zip was not called Archive");

                var bytes = File.ReadAllBytes(seven);
                var cut = Path.Combine(root, "cut.7z");
                File.WriteAllBytes(cut, bytes[..(bytes.Length * 6 / 10)]);
                Must(Engine.Probe(cut) == Probe.Damaged, "a 7z truncated to 60% was not called Damaged");

                var flipped = (byte[])bytes.Clone();
                flipped[32 + (int)BitConverter.ToUInt64(flipped, 12)] ^= 0xFF;   // first byte of the next header
                var bad = Path.Combine(root, "flipped.7z");
                File.WriteAllBytes(bad, flipped);
                Must(Engine.Probe(bad) == Probe.Damaged, "a flipped next-header byte was not called Damaged");

                var secret = Path.Combine(root, "secret.7z");
                Must(Engine.Probe(secret) == Probe.Archive, "a header-encrypted 7z is intact and must probe as Archive");
                var opened = false;
                try { Engine.Open(secret, null).Dispose(); opened = true; } catch { /* expected */ }
                Must(!opened, "the header-encrypted 7z opened without a password");

                // The two rar header parsers, on hand-built bytes - no rar fixture needed.
                Must(Engine.Rar4Encrypted([0, 0, 0x73, 0x80, 0x00, 0x0D, 0x00]), "rar4 MHD_PASSWORD was not seen");
                Must(!Engine.Rar4Encrypted([0, 0, 0x73, 0x00, 0x00, 0x0D, 0x00]), "rar4 without the flag was called encrypted");
                Must(!Engine.Rar4Encrypted([0, 0, 0x74, 0x80, 0x00, 0x0D, 0x00]), "rar4 flags read from a block that is not MAIN_HEAD");
                Must(Engine.Rar5Encrypted([0, 0, 0, 0, 0x0A, 0x04]), "rar5 encryption header (type 4) was not seen");
                Must(Engine.Rar5Encrypted([0, 0, 0, 0, 0x80, 0x01, 0x04]), "rar5 two-byte vint size was mis-parsed");
                Must(!Engine.Rar5Encrypted([0, 0, 0, 0, 0x0A, 0x01]), "rar5 main header (type 1) was called encrypted");
                Console.WriteLine("OK probe");
            });

            // Compressible text: on noise zip just stores every file, and the method under test never shows.
            var text = Path.Combine(root, "text");
            Directory.CreateDirectory(Path.Combine(text, "sub"));
            foreach (var (n, i) in new[] { "a.txt", "b.txt", "sub/c.txt", "sub/d.txt" }.Select((n, i) => (n, i)))
                File.WriteAllText(Path.Combine(text, n), string.Concat(Enumerable.Range(0, 20000).Select(k => $"line {k * (i + 1)} of {n}\n")));

            Check("methods", () =>
            {
                foreach (var kind in new[] { ArchiveKind.SevenZip, ArchiveKind.Zip })
                    foreach (var m in Engine.MethodsFor(kind))
                    {
                        var used = RoundTrip(kind, text, root, new CompressOptions(Method: m, Threads: 2), "-" + m);
                        Must(used.All(u => u.StartsWith(m.ToString(), StringComparison.OrdinalIgnoreCase)),
                             $"{kind} {m}: archive says '{string.Join(", ", used)}'");
                    }
                // Store ignores the coder knobs instead of tripping over them.
                RoundTrip(ArchiveKind.SevenZip, text, root, new CompressOptions(SevenZip.CompressionLevel.None, Method: SevenZip.CompressionMethod.Ppmd, Dictionary: 1 << 20), "-store");
            });

            Check("advanced_7z", () =>
            {
                var used = RoundTrip(ArchiveKind.SevenZip, text, root, new CompressOptions(Dictionary: 64 << 10, Filter: "off"), "-d64k");
                Must(used.All(u => u == "LZMA2:16"), $"d=64k f=off gave '{string.Join(", ", used)}'");
                used = RoundTrip(ArchiveKind.SevenZip, text, root, new CompressOptions(Filter: "BCJ2"), "-bcj2");
                Must(used.All(u => u.Contains("BCJ2")), $"f=BCJ2 gave '{string.Join(", ", used)}'");

                int Blocks(string tag)
                {
                    using var a = Engine.Open(Path.Combine(root, "SevenZip" + tag + ".7z"), null);
                    var p = a.X.ArchiveProperties.Where(x => x.Name == "Number of blocks").ToList();
                    if (p.Count == 0) throw new Exception("no block count among " + string.Join(", ", a.X.ArchiveProperties.Select(x => $"{x.Name}={x.Value}")));
                    return Convert.ToInt32(p[0].Value);
                }
                RoundTrip(ArchiveKind.SevenZip, text, root, new CompressOptions(Solid: "off"), "-nonsolid");
                Must(Blocks("-nonsolid") >= 4, $"s=off packed into {Blocks("-nonsolid")} block(s)");
                Must(Blocks("-d64k") == 1, $"default solid packed into {Blocks("-d64k")} blocks");
                Console.WriteLine("OK advanced_7z (dictionary, filter, solid)");
            });

            Check("advanced_guard", () =>
            {
                void Rejected(ArchiveKind kind, CompressOptions o, string what)
                {
                    var archive = Path.Combine(root, "guard" + Engine.Kind(kind).Ext);
                    var threw = false;
                    try { Engine.Compress([src], archive, kind, o, Engine.NoProgress, default).GetAwaiter().GetResult(); }
                    catch (ArgumentException) { threw = true; }
                    Must(threw, what + " was accepted");
                    Must(!File.Exists(archive), what + " left a file behind");
                }
                Rejected(ArchiveKind.Zip, new CompressOptions(Solid: "on"), "zip + solid");   // 7z.dll would write a broken zip
                Rejected(ArchiveKind.SevenZip, new CompressOptions(Method: SevenZip.CompressionMethod.Ppmd, Dictionary: 1 << 20), "PPMd + dictionary");
                Rejected(ArchiveKind.Zip, new CompressOptions(Method: SevenZip.CompressionMethod.Lzma2), "zip + LZMA2");
                Rejected(ArchiveKind.Tar, new CompressOptions(Threads: 2), "tar + threads");

                const long G = 1L << 30;
                Must(!Engine.DictionaryFits(new CompressOptions(Dictionary: G), 10 * G, 8 * G, out var need) && need > 8 * G,
                     "a 1 GB dictionary over 10 GB of input fit in 8 GB of RAM");
                Must(Engine.DictionaryFits(new CompressOptions(Dictionary: G), 1 << 20, 8 * G, out _),
                     "a 1 GB dictionary over 1 MB of input (shrunk by 7-Zip) did not fit");
                Must(Engine.DictionaryFits(CompressOptions.Default, 100 * G, 1, out _), "the default dictionary was checked at all");
                Must(Engine.Size7z(64 << 10) == "64k" && Engine.Size7z(3 << 20) == "3m" && Engine.Size7z(1000) == "1000b",
                     "7-Zip size syntax");
                Console.WriteLine("OK advanced_guard");
            });

            Check("volumes", () =>
            {
                const long vol = 300 << 10;
                foreach (var kind in new[] { ArchiveKind.SevenZip, ArchiveKind.Zip, ArchiveKind.TarGz })
                {
                    var archive = Path.Combine(root, "vol" + Engine.Kind(kind).Ext);
                    File.WriteAllText(Engine.Part(archive, 9), "stale part of an older set");
                    Engine.Compress([src], archive, kind, new CompressOptions(VolumeSize: vol), Engine.NoProgress, default)
                          .GetAwaiter().GetResult();
                    var parts = Directory.GetFiles(root, Path.GetFileName(archive) + ".*");
                    Must(parts.Length >= 3 && parts.All(p => new FileInfo(p).Length <= vol),
                         $"{kind}: parts {string.Join(", ", parts.Select(p => $"{Path.GetFileName(p)}={new FileInfo(p).Length}"))}");
                    Must(!File.Exists(archive) && !File.Exists(Engine.Part(archive, 9)), $"{kind}: a whole file or the stale .009 is left");
                    try
                    {
                        using var a = Engine.Open(Engine.Part(archive, 1), null);
                        var dest = Path.Combine(root, "out-vol-" + kind);
                        Unpack(a, dest, OverwriteMode.Overwrite);
                        Same(src, Path.Combine(dest, Path.GetFileName(src)));
                    }
                    catch (Exception ex) { throw new Exception($"{kind}: {ex.Message}"); }
                }

                var cancelled = Path.Combine(root, "vol-cancel.7z");
                using (var cts = new CancellationTokenSource())
                    try
                    {
                        Engine.Compress([src], cancelled, ArchiveKind.SevenZip, new CompressOptions(VolumeSize: vol),
                                        new CancelOnReport(cts), cts.Token).GetAwaiter().GetResult();
                    }
                    catch (OperationCanceledException) { }
                Must(Directory.GetFiles(root, "vol-cancel.7z*").Length == 0, "cancel left parts or the temp file behind");

                foreach (var (text, want) in new (string, long?)[]
                         {
                             ("", 0), ("100 MB", 100L << 20), ("700 MB (CD)", 700L << 20), ("1,5 ГБ", 3L << 29), ("1.5g", 3L << 29),
                             ("650m", 650L << 20), ("64 кб", 64 << 10), ("250000", 250000), ("abc", null), ("10 parsecs", null), ("0", null),
                         })
                    Must(Engine.ParseSize(text) == want, $"ParseSize('{text}') = {Engine.ParseSize(text)}, expected {want}");
                Console.WriteLine("OK volumes (7z, zip, tar.gz, cancel, sizes)");
            });

            Check("after_actions", () =>
            {
                string Sources(string name)
                {
                    var dir = Path.Combine(root, name);
                    Directory.CreateDirectory(Path.Combine(dir, "inner"));
                    File.WriteAllText(Path.Combine(dir, "one.txt"), string.Concat(Enumerable.Repeat("after-actions ", 5000)));
                    File.WriteAllText(Path.Combine(dir, "inner", "two.txt"), "two");
                    return dir;
                }
                CompressOptions Both(long volume = 0, string? password = null) =>
                    new(TestAfter: true, DeleteSources: true, VolumeSize: volume, Password: password);

                // Happy path: tested, then the sources are gone (to the Recycle Bin).
                var ok = Sources("MakePack-selftest-recycled");
                var okArc = Path.Combine(root, "after-ok.7z");
                Engine.Compress([ok], okArc, ArchiveKind.SevenZip, Both(), Engine.NoProgress, default).GetAwaiter().GetResult();
                Must(File.Exists(okArc) && !Directory.Exists(ok), "after a passed test the sources should be gone and the archive there");
                Must(FromRecycleBin(root) >= 1, "the deleted sources are not in the Recycle Bin");

                // Test after a volume set with a password: Open has to glue the parts and know the password.
                var vol = Sources("MakePack-selftest-recycled-vol");
                var volArc = Path.Combine(root, "after-vol.7z");
                Engine.Compress([vol], volArc, ArchiveKind.SevenZip, Both(128, "hunter2"), Engine.NoProgress, default).GetAwaiter().GetResult();
                Must(File.Exists(Engine.Part(volArc, 2)), "volumes + password + test: no second part; got " +
                     string.Join(", ", Directory.GetFiles(root, "after-vol*").Select(f => $"{Path.GetFileName(f)}={new FileInfo(f).Length}")));
                Must(!Directory.Exists(vol), "volumes + password + test: the sources are still there");
                FromRecycleBin(root);

                // A damaged archive: the test fails, the sources stay.
                var bad = Sources("after-bad");
                var badArc = Path.Combine(root, "after-bad.7z");
                Engine.BeforeTestHook = path =>
                {
                    var bytes = File.ReadAllBytes(path);
                    for (var i = 40; i < bytes.Length - 40; i += 7) bytes[i] ^= 0x5A;   // the packed stream, not the signature
                    File.WriteAllBytes(path, bytes);
                };
                var failed = false;
                try { Engine.Compress([bad], badArc, ArchiveKind.SevenZip, Both(), Engine.NoProgress, default).GetAwaiter().GetResult(); }
                catch (Exception) { failed = true; }
                finally { Engine.BeforeTestHook = null; }
                Must(failed, "a damaged archive passed the test");
                Must(File.Exists(Path.Combine(bad, "inner", "two.txt")), "a failed test still deleted the sources");

                // Cancelled while packing: no archive, sources untouched.
                var cancelled = Sources("after-cancel");
                using (var cts = new CancellationTokenSource())
                    try
                    {
                        Engine.Compress([cancelled], Path.Combine(root, "after-cancel.7z"), ArchiveKind.SevenZip, Both(),
                                        new CancelOnReport(cts), cts.Token).GetAwaiter().GetResult();
                    }
                    catch (OperationCanceledException) { }
                Must(File.Exists(Path.Combine(cancelled, "one.txt")), "cancel deleted the sources");

                // The archive inside a folder that is about to be recycled: refused before anything is written.
                var home = Sources("after-inside");
                var inside = Path.Combine(home, "inner", "self.7z");
                var refused = false;
                try { Engine.Compress([home], inside, ArchiveKind.SevenZip, Both(), Engine.NoProgress, default).GetAwaiter().GetResult(); }
                catch (InvalidOperationException) { refused = true; }
                Must(refused && !File.Exists(inside) && Directory.Exists(home), "an archive inside a source folder was not refused");
                Console.WriteLine("OK after_actions (test, recycle, damaged, cancel, inside)");
            });

            Check("separate", () =>
            {
                var sep = Path.Combine(root, "sep");
                Directory.CreateDirectory(Path.Combine(sep, "photos"));
                Directory.CreateDirectory(Path.Combine(sep, "other"));
                foreach (var f in new[] { "photos/p.jpg", "a.txt", "a.doc", "b.txt", "other/a.txt" })
                    File.WriteAllText(Path.Combine(sep, f), "content of " + f);
                string In(string rel) => Path.Combine(sep, rel);
                string Names(IEnumerable<(string Input, string Output)> plan) =>
                    string.Join(", ", plan.Select(x => Path.GetRelativePath(sep, x.Output).Replace('\\', '/')));

                var plan = Engine.PlanSeparate([In("photos"), In("a.txt"), In("a.doc"), In("b.txt")], ".7z", null);
                Must(Names(plan) == "photos.7z, a.txt.7z, a.doc.7z, b.7z", "plan: " + Names(plan));
                // Into one folder: the two a.txt files clash even by whole name.
                var into = Path.Combine(sep, "into");
                Directory.CreateDirectory(into);
                plan = Engine.PlanSeparate([In("a.txt"), In("other/a.txt"), In("b.txt")], ".zip", into);
                Must(Names(plan) == "into/a.txt.zip, into/a.txt (2).zip, into/b.zip", "plan into a folder: " + Names(plan));

                // The series: one archive per input, each with its own content.
                plan = Engine.PlanSeparate([In("photos"), In("a.txt"), In("b.txt")], ".7z", null);
                Engine.CompressEach(plan, ArchiveKind.SevenZip, CompressOptions.Default, Engine.NoProgress, default).GetAwaiter().GetResult();
                foreach (var (input, output) in plan)
                {
                    using var a = Engine.Open(output, null);
                    var names = a.X.ArchiveFileData.Where(f => !f.IsDirectory).Select(f => Path.GetFileName(f.FileName)).ToList();
                    var want = Directory.Exists(input) ? ["p.jpg"] : new List<string> { Path.GetFileName(input) };
                    Must(names.SequenceEqual(want), $"{Path.GetFileName(output)} holds [{string.Join(", ", names)}]");
                }

                // Cancel in the middle of the second archive: the first stays, the second and third never appear.
                var series = Path.Combine(root, "series");
                Directory.CreateDirectory(series);
                var cancelPlan = new List<(string, string)>
                {
                    (In("a.txt"), Path.Combine(series, "1.7z")), (text, Path.Combine(series, "2.7z")), (In("b.txt"), Path.Combine(series, "3.7z")),
                };
                using (var cts = new CancellationTokenSource())
                    try
                    {
                        Engine.CompressEach(cancelPlan, ArchiveKind.SevenZip, new CompressOptions(Solid: "off"),
                                            new CancelPast(cts, 40), cts.Token).GetAwaiter().GetResult();
                    }
                    catch (OperationCanceledException) { }
                Must(File.Exists(Path.Combine(series, "1.7z")), "cancel removed an archive that was already finished");
                Must(!File.Exists(Path.Combine(series, "2.7z")), "cancel left the unfinished archive behind");
                Must(!File.Exists(Path.Combine(series, "3.7z")), "the series went on after cancel");
                Console.WriteLine("OK separate (names, series, cancel)");
            });

            Check("sfx", () =>
            {
                var exe = Path.Combine(root, "self.exe");
                Engine.Compress([src], exe, ArchiveKind.SevenZip, new CompressOptions(Sfx: true, TestAfter: true), Engine.NoProgress, default)
                      .GetAwaiter().GetResult();
                var module = File.ReadAllBytes(Engine.SfxModule);
                Must(File.ReadAllBytes(exe).AsSpan(0, module.Length).SequenceEqual(module), "the exe does not start with 7z.sfx");
                Must(!File.Exists(exe + ".makepack-tmp"), "the temp 7z was left behind");

                using (var a = Engine.Open(exe, null))
                {
                    Must(!Engine.CanDelete(a), "an SFX exe is offered for in-place editing (that would cut its stub off)");
                    var dest = Path.Combine(root, "out-sfx-open");
                    Unpack(a, dest, OverwriteMode.Overwrite);
                    Same(src, Path.Combine(dest, Path.GetFileName(src)));
                }

                // The real thing: run it. 7z.sfx takes -y (no questions) and -o<folder>.
                var ran = Path.Combine(root, "out-sfx-run");
                using (var p = System.Diagnostics.Process.Start(exe, $"-y \"-o{ran}\""))
                {
                    Must(p.WaitForExit(60000), "the SFX did not finish within 60 s");
                    Must(p.ExitCode == 0, "the SFX exited with " + p.ExitCode);
                }
                Same(src, Path.Combine(ran, Path.GetFileName(src)));

                // Encrypted names: the file list is behind the password, so MakePack must ask instead of failing.
                var locked = Path.Combine(root, "locked.exe");
                Engine.Compress([src], locked, ArchiveKind.SevenZip, new CompressOptions(Password: "hunter2", EncryptHeaders: true, Sfx: true),
                                Engine.NoProgress, default).GetAwaiter().GetResult();
                Must(Engine.CanEncryptHeaders(locked), "an SFX with encrypted names is not recognised as password-protected");
                Must(!Engine.CanEncryptHeaders(Environment.ProcessPath!), "a plain exe was taken for a password-protected SFX");
                using (var a = Engine.Open(locked, "hunter2")) Must(a.X.ArchiveFileData.Count > 4, "the encrypted SFX did not list with its password");

                foreach (var (kind, o, what) in new[]
                         {
                             (ArchiveKind.Zip, new CompressOptions(Sfx: true), "zip SFX"),
                             (ArchiveKind.SevenZip, new CompressOptions(Sfx: true, VolumeSize: 1 << 20), "SFX in volumes"),
                         })
                {
                    var bad = Path.Combine(root, "bad-sfx.exe");
                    var threw = false;
                    try { Engine.Compress([src], bad, kind, o, Engine.NoProgress, default).GetAwaiter().GetResult(); }
                    catch (ArgumentException) { threw = true; }
                    Must(threw && !File.Exists(bad), what + " was not refused up front");
                }
                Console.WriteLine("OK sfx (glue, open, read-only, run, encrypted, refused)");
            });

            Check("zipcrypto", () =>
            {
                string[] Methods(string zip)
                {
                    using var a = Engine.Open(zip, "hunter2");
                    return [.. a.X.ArchiveFileData.Where(f => f.Size > 0).Select(f => f.Method ?? "").Distinct()];
                }
                var legacy = Path.Combine(root, "legacy.zip");
                Engine.Compress([text], legacy, ArchiveKind.Zip, new CompressOptions(Password: "hunter2", ZipCrypto: true), Engine.NoProgress, default)
                      .GetAwaiter().GetResult();
                Must(Methods(legacy).All(m => m.StartsWith("ZipCrypto")), "ZipCrypto zip says " + string.Join(", ", Methods(legacy)));
                using (var a = Engine.Open(legacy, "hunter2"))
                {
                    var dest = Path.Combine(root, "out-zipcrypto");
                    Unpack(a, dest, OverwriteMode.Overwrite);
                    Same(text, Path.Combine(dest, Path.GetFileName(text)));
                }
                var aes = Path.Combine(root, "aes.zip");
                Engine.Compress([text], aes, ArchiveKind.Zip, new CompressOptions(Password: "hunter2"), Engine.NoProgress, default)
                      .GetAwaiter().GetResult();
                Must(Methods(aes).All(m => m.StartsWith("AES-256")), "the default zip encryption says " + string.Join(", ", Methods(aes)));

                var threw = false;
                try { Engine.Compress([text], Path.Combine(root, "zc.7z"), ArchiveKind.SevenZip, new CompressOptions(Password: "x", ZipCrypto: true), Engine.NoProgress, default).GetAwaiter().GetResult(); }
                catch (ArgumentException) { threw = true; }
                Must(threw && !File.Exists(Path.Combine(root, "zc.7z")), "ZipCrypto on a 7z was not refused up front");
                Console.WriteLine("OK zipcrypto (method, round trip, AES default, refused for 7z)");
            });

            Check("settings", () =>
            {
                var path = Path.Combine(root, "cfg", "settings.json");
                Must(Settings.Load(path).Format == ArchiveKind.SevenZip, "a missing file did not give defaults");
                new Settings { Format = ArchiveKind.TarXz, Level = SevenZip.CompressionLevel.Ultra, ArchiveFolder = @"D:\Архіви" }.Save(path);
                var back = Settings.Load(path);
                Must(back.Format == ArchiveKind.TarXz && back.Level == SevenZip.CompressionLevel.Ultra
                     && back.ArchiveFolder == @"D:\Архіви", "settings did not survive a save/load round trip");
                Must(!File.Exists(path + ".tmp"), "the temp file of the atomic save was left behind");
                foreach (var junk in new[] { "{broken", "", "null", "{\"Format\":\"NoSuchKind\"}", "[1,2]" })
                {
                    File.WriteAllText(path, junk);
                    var d = Settings.Load(path);
                    Must(d.Format == ArchiveKind.SevenZip && d.ArchiveFolder == null, $"'{junk}' did not fall back to defaults");
                }
                Console.WriteLine("OK settings");
            });

            Check("motw", () =>
            {
                var dir = Path.Combine(root, "motw", "payload");
                Directory.CreateDirectory(Path.Combine(dir, "sub"));
                foreach (var f in new[] { "a.exe", "b.docx", "c.txt", "d.zip", "sub/e.ps1" })
                    File.WriteAllText(Path.Combine(dir, f), "content of " + f);
                const string zone = "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=https://example.test/payload.7z\r\n";
                var marked = Path.Combine(root, "motw", "marked.7z");
                var clean = Path.Combine(root, "motw", "clean.7z");
                foreach (var arc in new[] { marked, clean })
                    Engine.Compress([dir], arc, ArchiveKind.SevenZip, CompressOptions.Default, Engine.NoProgress, default).GetAwaiter().GetResult();
                File.WriteAllText(marked + ":Zone.Identifier", zone);   // what a browser leaves on a download
                Must(Engine.ZoneOf(marked) == zone && Engine.ZoneOf(clean) == null, "the fixture's Zone.Identifier");

                string Got(string archive, MotwPolicy policy, string tag, OverwriteMode mode = OverwriteMode.Overwrite)
                {
                    var dest = Path.Combine(root, "motw", "out-" + tag);
                    using (var a = Engine.Open(archive, null))
                        Engine.Extract(a, dest, null, mode, Engine.NoProgress, default, _ => mode, policy).GetAwaiter().GetResult();
                    return string.Join(",", Directory.EnumerateFiles(dest, "*", SearchOption.AllDirectories)
                        .Where(f => Engine.ZoneOf(f) is { } z && z == zone)
                        .Select(f => Path.GetRelativePath(Path.Combine(dest, "payload"), f).Replace('\\', '/')).Order());
                }
                Must(Got(marked, MotwPolicy.Risky, "risky") == "a.exe,b.docx,d.zip,sub/e.ps1", "Risky marked: " + Got(marked, MotwPolicy.Risky, "risky"));
                Must(Got(marked, MotwPolicy.All, "all") == "a.exe,b.docx,c.txt,d.zip,sub/e.ps1", "All marked: " + Got(marked, MotwPolicy.All, "all"));
                Must(Got(marked, MotwPolicy.Never, "never") == "", "Never still marked something");
                Must(Got(clean, MotwPolicy.All, "clean") == "", "an archive without a mark passed one on");

                // Rename on clash: the renamed copy is the one written, so it is the one marked.
                Got(marked, MotwPolicy.Risky, "rename");
                var renamed = Got(marked, MotwPolicy.Risky, "rename", OverwriteMode.Rename);
                Must(renamed.Contains("a (2).exe"), "a file renamed on a clash was not marked: " + renamed);

                // A split set carries the mark on its first part, the way the browser leaves it.
                var parts = Path.Combine(root, "motw", "parts.7z");
                Engine.Compress([dir], parts, ArchiveKind.SevenZip, new CompressOptions(Level: SevenZip.CompressionLevel.None, VolumeSize: 512),
                                Engine.NoProgress, default).GetAwaiter().GetResult();
                File.WriteAllText(Engine.Part(parts, 1) + ":Zone.Identifier", zone);
                Must(Got(Engine.Part(parts, 1), MotwPolicy.Risky, "split") == "a.exe,b.docx,d.zip,sub/e.ps1", "a marked .001 set did not pass the mark on");
                Console.WriteLine("OK motw (risky, all, never, unmarked, rename, split)");
            });

            Check("extract_options", () =>
            {
                var home = Path.Combine(root, "xo");
                Directory.CreateDirectory(home);
                var arc = Path.Combine(home, "src.7z");
                Engine.Compress([src], arc, ArchiveKind.SevenZip, CompressOptions.Default, Engine.NoProgress, default).GetAwaiter().GetResult();
                void X(string archive, string dest, ExtractOptions o, OverwriteMode mode = OverwriteMode.Overwrite)
                {
                    using var a = Engine.Open(archive, null);
                    Engine.Extract(a, dest, null, mode, Engine.NoProgress, default, _ => mode, MotwPolicy.Never, o).GetAwaiter().GetResult();
                }

                // No folders: every file lands in the destination itself.
                var flat = Path.Combine(home, "flat");
                X(arc, flat, new ExtractOptions(NoPaths: true));
                var got = Directory.GetFiles(flat, "*", SearchOption.AllDirectories).Select(Path.GetFileName).Order().ToList();
                var want = Directory.GetFiles(src, "*", SearchOption.AllDirectories).Select(Path.GetFileName).Order().ToList();
                Must(got.SequenceEqual(want) && Directory.GetDirectories(flat).Length == 0, "no-paths gave " + string.Join(", ", got));

                // Update modes: a file newer on disk stays, an older one is refreshed, a missing one depends on the mode.
                var upd = Path.Combine(home, "upd");
                X(arc, upd, ExtractOptions.Default);
                var root2 = Path.Combine(upd, Path.GetFileName(src));
                string P(string rel) => Path.Combine(root2, rel);
                void Prepare()
                {
                    File.WriteAllText(P("a.txt"), "edited later");      File.SetLastWriteTime(P("a.txt"), DateTime.Now.AddDays(1));
                    File.WriteAllText(P("empty.txt"), "stale copy");    File.SetLastWriteTime(P("empty.txt"), new DateTime(2001, 1, 1));
                    File.Delete(P(@"sub\b.bin"));
                }
                Prepare();
                X(arc, upd, new ExtractOptions(Update: UpdateMode.Newer));
                Must(File.ReadAllText(P("a.txt")) == "edited later", "Newer overwrote a file that is newer on disk");
                Must(new FileInfo(P("empty.txt")).Length == 0, "Newer did not refresh an older file");
                Must(File.Exists(P(@"sub\b.bin")), "Newer did not extract a file missing on disk");
                Prepare();
                X(arc, upd, new ExtractOptions(Update: UpdateMode.Existing));
                Must(File.ReadAllText(P("a.txt")) == "edited later", "Existing overwrote a file that is newer on disk");
                Must(new FileInfo(P("empty.txt")).Length == 0, "Existing did not refresh an older file");
                Must(!File.Exists(P(@"sub\b.bin")), "Existing extracted a file that was not on disk");

                // Broken data: by default the half-written file goes, with Keep broken files it stays.
                var bad = Path.Combine(home, "bad");
                Directory.CreateDirectory(bad);
                var rnd = new Random(9);
                foreach (var n in new[] { "a.bin", "b.bin" }) { var b = new byte[200_000]; rnd.NextBytes(b); File.WriteAllBytes(Path.Combine(bad, n), b); }
                var broken = Path.Combine(home, "broken.7z");
                Engine.Compress([Path.Combine(bad, "a.bin"), Path.Combine(bad, "b.bin")], broken, ArchiveKind.SevenZip,
                                new CompressOptions(SevenZip.CompressionLevel.None, Solid: "off"), Engine.NoProgress, default).GetAwaiter().GetResult();
                var bytes = File.ReadAllBytes(broken);
                for (var i = 300_000; i < 300_064; i++) bytes[i] ^= 0xFF;     // inside b.bin's stored data
                File.WriteAllBytes(broken, bytes);
                foreach (var keep in new[] { false, true })
                {
                    var dest = Path.Combine(home, "broken-" + keep);
                    var threw = false;
                    try { X(broken, dest, new ExtractOptions(KeepBroken: keep)); } catch (InvalidDataException) { threw = true; }
                    Must(threw, "a CRC error went unreported");
                    Must(File.Exists(Path.Combine(dest, "a.bin")), "the intact file before the broken one is gone");
                    Must(File.Exists(Path.Combine(dest, "b.bin")) == keep, keep ? "Keep broken files dropped it" : "a broken file was left on disk");
                }

                // Zip-slip in no-paths and update modes too: nothing lands outside the destination.
                var slip = Path.Combine(home, "slip.zip");
                using (var z = System.IO.Compression.ZipFile.Open(slip, System.IO.Compression.ZipArchiveMode.Create))
                {
                    using (var w = new StreamWriter(z.CreateEntry("ok.txt").Open())) w.Write("fine");
                    using (var w = new StreamWriter(z.CreateEntry("../escaped.txt").Open())) w.Write("evil");
                }
                foreach (var o in new[] { new ExtractOptions(NoPaths: true), new ExtractOptions(Update: UpdateMode.Newer) })
                {
                    var dest = Path.Combine(home, "slip-out", o.NoPaths ? "flat" : "newer");
                    try { X(slip, dest, o); } catch (WarningException) { }
                    Must(!File.Exists(Path.Combine(dest, "..", "escaped.txt")) && File.Exists(Path.Combine(dest, "ok.txt")), "zip-slip got through with " + o);
                }

                // Deleting after extraction: a .001 set goes to the Recycle Bin whole.
                var parts = Path.Combine(home, "set.7z");
                Engine.Compress([src], parts, ArchiveKind.SevenZip, new CompressOptions(SevenZip.CompressionLevel.None, VolumeSize: 300 << 10),
                                Engine.NoProgress, default).GetAwaiter().GetResult();
                Must(File.Exists(Engine.Part(parts, 3)), "the volume fixture");
                Engine.RecycleArchive(Engine.Part(parts, 1));
                Must(Directory.GetFiles(home, "set.7z.*").Length == 0, "parts left after recycling the set");
                FromRecycleBin(root);
                Console.WriteLine("OK extract_options (no paths, newer, existing, broken, zip-slip, recycle set)");
            });

            Check("shellnew", () =>
            {
                // Explorer's New > MakePack archive writes these 32 bytes as "New MakePack archive.7z".
                var fresh = Path.Combine(root, "New archive.7z");
                File.WriteAllBytes(fresh, Assoc.EmptySevenZip);
                Must(Engine.Probe(fresh) == Probe.Archive, "the empty 7z does not probe as an archive");
                using (var a = Engine.Open(fresh, null)) Must(a.X.ArchiveFileData.Count == 0, "the empty 7z is not empty");
                Engine.Append(Engine.Open(fresh, null), [Path.Combine(src, "a.txt")], "", CompressOptions.Default, Engine.NoProgress, default,
                              _ => OverwriteMode.Overwrite).GetAwaiter().GetResult();
                using (var a = Engine.Open(fresh, null)) Must(a.X.ArchiveFileData.Count == 1, "a file dropped into the new archive is not there");
                Console.WriteLine("OK shellnew (empty 7z opens, takes files)");
            });

            Check("info", () =>
            {
                var home = Path.Combine(root, "info");
                Directory.CreateDirectory(home);
                string Make(string name, ArchiveKind kind, CompressOptions o)
                {
                    var path = Path.Combine(home, name);
                    Engine.Compress([text], path, kind, o, Engine.NoProgress, default).GetAwaiter().GetResult();
                    return path;
                }
                Dictionary<string, string> Rows(string archive, string? password = null)
                {
                    using var a = Engine.Open(archive, password);
                    return Engine.Describe(a).ToDictionary(r => r.Label, r => r.Value);
                }
                var textBytes = Directory.GetFiles(text, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length);

                var seven = Make("d64k.7z", ArchiveKind.SevenZip, new CompressOptions(Dictionary: 64 << 10, Filter: "off"));
                var r = Rows(seven);
                Must(r[S.Method.TrimEnd(':')] == "LZMA2:16", "7z method: " + r[S.Method.TrimEnd(':')]);
                Must(r[S.Dictionary.TrimEnd(':')] == Engine.NiceSize(64 << 10), "7z dictionary: " + r[S.Dictionary.TrimEnd(':')]);
                Must(r[S.Solid].StartsWith(S.Yes), "7z solid: " + r[S.Solid]);
                Must(r[S.Files] == "4" && r[S.Folders] == "2", $"7z counts: {r[S.Files]} files, {r[S.Folders]} folders");
                Must(r[S.Unpacked] == Engine.NiceSize(textBytes), $"unpacked {r[S.Unpacked]}, expected {Engine.NiceSize(textBytes)}");
                Must(r[S.Packed] == Engine.NiceSize(new FileInfo(seven).Length), "packed " + r[S.Packed]);
                Must(r[S.Encrypted] == S.No && !r.ContainsKey(S.VolumesCount), "plain 7z: encryption/volumes rows");

                var zip = Make("plain.zip", ArchiveKind.Zip, CompressOptions.Default);
                r = Rows(zip);
                Must(r[S.Method.TrimEnd(':')] == "Deflate" && !r.ContainsKey(S.Dictionary.TrimEnd(':')), "zip method/dictionary: " + r[S.Method.TrimEnd(':')]);

                var parts = Make("vol.7z", ArchiveKind.SevenZip, new CompressOptions(SevenZip.CompressionLevel.None, VolumeSize: 100 << 10));
                var count = Directory.GetFiles(home, "vol.7z.*").Length;
                Must(count >= 3 && Rows(Engine.Part(parts, 1))[S.VolumesCount] == count.ToString(), "volume count row");

                var locked = Make("locked.7z", ArchiveKind.SevenZip, new CompressOptions(Password: "hunter2", EncryptHeaders: true));
                Must(Rows(locked, "hunter2")[S.Encrypted] == S.EncryptedDataAndNames, "7z with encrypted names");
                var aes = Make("aes.zip", ArchiveKind.Zip, new CompressOptions(Password: "hunter2"));
                Must(Rows(aes, "hunter2")[S.Encrypted] == S.EncryptedData, "zip with encrypted data only");

                var tgz = Make("t.tar.gz", ArchiveKind.TarGz, CompressOptions.Default);
                Must(Rows(tgz)[S.Packed] == Engine.NiceSize(new FileInfo(tgz).Length), "tar.gz packed size is the inner tar's");

                Must(Engine.DictionaryOf("PPMD:o6:mem24") == 1 << 24 && Engine.DictionaryOf("LZMA:1536m") == 1536L << 20
                     && Engine.DictionaryOf("BCJ2 LZMA2:20 LZMA:20:lc0:lp2") == 1 << 20 && Engine.DictionaryOf("Deflate") == null,
                     "DictionaryOf");
                Console.WriteLine("OK info (7z, zip, volumes, encryption, tar.gz, dictionary)");
            });

            Check("report", () =>
            {
                var home = Path.Combine(root, "report");
                Directory.CreateDirectory(home);
                // Names Windows itself would never allow, the way a zip from elsewhere can carry them.
                var zip = Path.Combine(home, "odd.zip");
                using (var z = System.IO.Compression.ZipFile.Open(zip, System.IO.Compression.ZipArchiveMode.Create))
                    foreach (var (name, body) in new[] { ("R&D.txt", "rd"), ("x<script>alert(1)</script>.txt", "xss"), ("звіт.txt", "uk"), ("sub/b.txt", new string('b', 5000)) })
                        using (var w = new StreamWriter(z.CreateEntry(name).Open())) w.Write(body);
                using var a = Engine.Open(zip, null);
                var info = Engine.Describe(a).ToDictionary(r => r.Label, r => r.Value);

                var html = Engine.Report(a, html: true);
                Must(html.Contains("R&amp;D.txt") && html.Contains("x&lt;script&gt;alert(1)&lt;/script&gt;.txt"), "names are not escaped in HTML");
                Must(!html.Contains("<script>"), "a raw <script> got into the HTML report");
                Must(html.Contains("звіт.txt") && html.Contains("<meta charset=\"utf-8\">"), "Cyrillic name or charset missing from HTML");

                var txtPath = Path.Combine(home, "odd.txt");
                Engine.WriteReport(a, txtPath, html: false);
                var bytes = File.ReadAllBytes(txtPath);
                Must(bytes.Length > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "the text report has no UTF-8 BOM");
                var txt = File.ReadAllText(txtPath);
                Must(txt.Contains("звіт.txt") && txt.Contains("sub/b.txt") && txt.Contains("R&D.txt"), "the text report lacks a file");
                foreach (var label in new[] { S.Files, S.Unpacked, S.Packed })
                    Must(txt.Contains($"{label}: {info[label]}"), $"text report total '{label}' differs from Info ({info[label]})");
                Must(txt.Contains("5,000") || txt.Contains("5 000") || txt.Contains("5 000") || txt.Contains("5000"), "b.txt's size is not in the report");
                var htmlPath = Path.Combine(home, "odd.html");
                Engine.WriteReport(a, htmlPath, html: true);
                Must(File.ReadAllBytes(htmlPath)[0] == (byte)'<', "the HTML report starts with a BOM");
                Console.WriteLine("OK report (HTML escaping, BOM text, totals = Info)");
            });

            Check("convert", () =>
            {
                var home = Path.Combine(root, "conv");
                Directory.CreateDirectory(home);
                string Make(string name, ArchiveKind kind, CompressOptions? o = null)
                {
                    var path = Path.Combine(home, name);
                    Engine.Compress([text], path, kind, o ?? CompressOptions.Default, Engine.NoProgress, default).GetAwaiter().GetResult();
                    return path;
                }
                bool Conv(string src, string dst, ArchiveKind kind, bool keep = false, bool delete = false, string? password = null,
                          IProgress<(int, string)>? p = null, CancellationToken ct = default) =>
                    Engine.Convert(src, password, dst, kind, SevenZip.CompressionLevel.Normal, keep, delete, p ?? Engine.NoProgress, ct)
                          .GetAwaiter().GetResult();
                void SameAs(string archive, string? password = null)
                {
                    using var a = Engine.Open(archive, password);
                    var dest = Path.Combine(home, "check-" + Path.GetFileName(archive));
                    Unpack(a, dest, OverwriteMode.Overwrite);
                    Same(text, Path.Combine(dest, Path.GetFileName(text)));
                }
                void NoLeftovers(string what) =>
                    Must(Directory.GetFiles(home, ".makepack-*").Length == 0, what + " left a hidden .makepack-* file");

                // zip -> 7z, and a nested tar.gz -> 7z: same files, original kept, its download mark carried over.
                var zip = Make("a.zip", ArchiveKind.Zip);
                File.WriteAllText(zip + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
                Must(Conv(zip, Path.Combine(home, "a.7z"), ArchiveKind.SevenZip), "zip -> 7z was not kept");
                SameAs(Path.Combine(home, "a.7z"));
                Must(File.Exists(zip), "the original went without delete-originals");
                Must(Engine.ZoneOf(Path.Combine(home, "a.7z")) != null, "the converted copy lost the original's download mark");
                var tgz = Make("b.tar.gz", ArchiveKind.TarGz);
                Must(Conv(tgz, Path.Combine(home, "b.7z"), ArchiveKind.SevenZip), "tar.gz -> 7z was not kept");
                SameAs(Path.Combine(home, "b.7z"));

                // Not smaller: the old one stays, no new file.
                var tight = Make("tight.7z", ArchiveKind.SevenZip, new CompressOptions(SevenZip.CompressionLevel.Ultra));
                Must(!Conv(tight, Path.Combine(home, "tight.tar"), ArchiveKind.Tar, keep: true), "a bigger tar replaced a 7z");
                Must(!File.Exists(Path.Combine(home, "tight.tar")), "the bigger new archive was left");
                NoLeftovers("keep-if-not-smaller");

                // A new archive that fails its test: removed, original untouched.
                Engine.BeforeTestHook = path => { var b = File.ReadAllBytes(path); for (var i = 40; i < b.Length - 40; i += 7) b[i] ^= 0x5A; File.WriteAllBytes(path, b); };
                var failed = false;
                try { Conv(zip, Path.Combine(home, "bad.7z"), ArchiveKind.SevenZip); } catch (InvalidDataException) { failed = true; }
                finally { Engine.BeforeTestHook = null; }
                Must(failed && !File.Exists(Path.Combine(home, "bad.7z")) && File.Exists(zip), "a damaged conversion was kept or hurt the original");
                NoLeftovers("a failed conversion");

                // Delete originals: to the Recycle Bin (and back, for the user's bin). Same path: replaced in place.
                var gone = Make("gone.zip", ArchiveKind.Zip);
                Must(Conv(gone, Path.Combine(home, "gone.7z"), ArchiveKind.SevenZip, delete: true) && !File.Exists(gone), "delete-originals kept it");
                FromRecycleBin(root);
                var inPlace = Make("inplace.zip", ArchiveKind.Zip, new CompressOptions(SevenZip.CompressionLevel.None));
                var stored = new FileInfo(inPlace).Length;
                Must(Conv(inPlace, inPlace, ArchiveKind.Zip, delete: true), "zip -> zip in place was not kept");
                Must(new FileInfo(inPlace).Length < stored, "the in-place zip was not recompressed");
                SameAs(inPlace);

                // Encrypted: the password goes on; into a format without one it is refused.
                var secret = Make("secret.7z", ArchiveKind.SevenZip, new CompressOptions(Password: "hunter2", EncryptHeaders: true));
                var refused = false;
                try { Conv(secret, Path.Combine(home, "secret.tar"), ArchiveKind.Tar, password: "hunter2"); } catch (InvalidOperationException) { refused = true; }
                Must(refused && !File.Exists(Path.Combine(home, "secret.tar")), "an encrypted archive was converted into plain tar");
                Must(Conv(secret, Path.Combine(home, "secret.zip"), ArchiveKind.Zip, password: "hunter2"), "encrypted 7z -> zip was not kept");
                using (var z = Engine.Open(Path.Combine(home, "secret.zip"), null))
                    Must(z.X.ArchiveFileData.Where(f => !f.IsDirectory).All(f => f.Encrypted), "the converted zip is not encrypted");
                SameAs(Path.Combine(home, "secret.zip"), "hunter2");

                // Cancel: nothing half-made.
                using (var cts = new CancellationTokenSource())
                    try { Conv(zip, Path.Combine(home, "cancel.7z"), ArchiveKind.SevenZip, p: new CancelPast(cts, 50), ct: cts.Token); }
                    catch (OperationCanceledException) { }
                Must(!File.Exists(Path.Combine(home, "cancel.7z")) && File.Exists(zip), "cancel left a new archive or hurt the original");
                NoLeftovers("cancel");
                Console.WriteLine("OK convert (zip, tar.gz, not smaller, damaged, delete, in place, encrypted, cancel)");
            });

            Check("profiles", () =>
            {
                var path = Path.Combine(root, "cfg-profiles", "settings.json");
                var fresh = new Profile { Name = "Fresh" };
                Must(fresh.Method == SevenZip.CompressionMethod.Default, "a new profile's method is not Default (default(enum) is Copy = no compression)");
                var cfg = new Settings();
                cfg.Profiles.Add(new Profile
                {
                    Name = "Backup", IsDefault = true, Format = ArchiveKind.Zip, Level = SevenZip.CompressionLevel.High,
                    Method = SevenZip.CompressionMethod.Lzma, Dictionary = 4 << 20, Threads = 2, Volumes = "700 MB (CD)",
                    TestAfter = true, DeleteSources = true, Separate = true, ZipCrypto = true,
                });
                cfg.Profiles.Add(new Profile { Name = "Setup", Format = ArchiveKind.SevenZip, Sfx = true, Solid = "off", Filter = "BCJ2" });
                cfg.Save(path);
                var back = Settings.Load(path);
                var b = back.FindProfile("backup")!;   // names match case-insensitively
                Must(back.Profiles.Count == 2 && b.IsDefault && b.Format == ArchiveKind.Zip && b.Method == SevenZip.CompressionMethod.Lzma
                     && b.Volumes == "700 MB (CD)" && b.Separate && b.ZipCrypto && b.DeleteSources, "a profile did not survive the save/load round trip");
                Must(!File.ReadAllText(path).Contains("Password", StringComparison.OrdinalIgnoreCase), "a profile carries a password field");

                var o = b.ToOptions();
                Must(o.Password == null && !o.ZipCrypto && !o.EncryptHeaders, "a profile run without the dialog asked for encryption");
                Must(o.VolumeSize == 700L << 20 && o.Dictionary == 4 << 20 && o.TestAfter && o.DeleteSources, "ToOptions lost an option");
                var setup = back.FindProfile("Setup")!;
                Must(setup.Ext == ".exe" && setup.ToOptions().Sfx && setup.ToOptions().Solid == "off", "the SFX profile");

                // The same default name the dialog proposes: one input -> its name, several -> their folder's.
                var dir = Path.Combine(root, "names");
                Directory.CreateDirectory(Path.Combine(dir, "photos"));
                File.WriteAllText(Path.Combine(dir, "a.txt"), "a");
                Must(Engine.DefaultArchivePath([Path.Combine(dir, "photos")], ".zip", null) == Path.Combine(dir, "photos.zip"), "single folder name");
                Must(Engine.DefaultArchivePath([Path.Combine(dir, "a.txt")], ".7z", null) == Path.Combine(dir, "a.7z"), "single file name");
                Must(Engine.DefaultArchivePath([Path.Combine(dir, "a.txt"), Path.Combine(dir, "photos")], ".7z", root)
                     == Path.Combine(root, "names.7z"), "several inputs into a folder");

                // A profile with options its format cannot take (hand-edited JSON) fails before anything is written.
                var broken = new Profile { Name = "Broken", Format = ArchiveKind.Zip, Solid = "on" };
                var target = Path.Combine(root, "broken.zip");
                var threw = false;
                try { Engine.Compress([Path.Combine(dir, "a.txt")], target, broken.Format, broken.ToOptions(), Engine.NoProgress, default).GetAwaiter().GetResult(); }
                catch (ArgumentException) { threw = true; }
                Must(threw && !File.Exists(target), "an impossible profile was not refused up front");
                Console.WriteLine("OK profiles (round trip, no password, options, names, refused)");
            });

            Check("cli", () =>
            {
                var home = Path.Combine(root, "cli");
                Directory.CreateDirectory(home);
                var outText = new StringWriter();
                var (stdout, stderr) = (Console.Out, Console.Error);
                int Run(params string[] args)
                {
                    outText.GetStringBuilder().Clear();
                    Console.SetOut(outText);
                    Console.SetError(outText);
                    try { return Cli.Run(args) ?? -1; }
                    finally { Console.SetOut(stdout); Console.SetError(stderr); }
                }
                void Code(int want, params string[] args)
                {
                    var got = Run(args);
                    Must(got == want, $"'{string.Join(' ', args)}' exited {got}, expected {want}: {outText.ToString().Trim()}");
                }

                // a -switches: headless, format from -t or the extension, volumes, no overwrite without -y.
                var zip = Path.Combine(home, "out.zip");
                Code(0, "a", "-m5", zip, text);
                using (var z = Engine.Open(zip, null)) Must(z.X.Format == InArchiveFormat.Zip, "a -m5 out.zip did not write a zip");
                Code(2, "a", "-m1", zip, text);                                   // exists, no -y
                Code(0, "a", "-y", "-t7z", zip, text);                            // -t beats the extension
                using (var z = Engine.Open(zip, null)) Must(z.X.Format == InArchiveFormat.SevenZip, "-t7z ignored");
                var bare = Path.Combine(home, "bare");
                Code(0, "a", "-ttar.gz", bare, Path.Combine(text, "*.txt"));     // a mask, and the extension added
                using (var z = Engine.Open(bare + ".tar.gz", null))
                    Must(z.X.ArchiveFileData.Count(f => !f.IsDirectory) == 2, "the mask did not pick exactly a.txt and b.txt");
                var vol = Path.Combine(home, "vol.7z");
                Code(0, "a", "-v20k", vol, text);
                Must(File.Exists(Engine.Part(vol, 2)), "-v20k made no second part");
                Code(7, "a", "-q", zip, text);
                Code(7, "a", "-psecret", zip, text);                              // never a password in the arguments
                Code(7, "a", "-hpsecret", zip, text);
                Code(7, "a", "-v0", zip, text);
                Code(10, "a", "-y", zip, Path.Combine(home, "nothing*.xyz"));

                // Password from the environment only; t/l/x refuse to guess without one.
                var secret = Path.Combine(home, "secret.7z");
                Environment.SetEnvironmentVariable("MAKEPACK_PASSWORD", "hunter2");
                try
                {
                    Code(0, "a", "-hp", secret, text);
                    Code(0, "t", secret);
                    Code(0, "x", "-y", secret, "-o", Path.Combine(home, "x-secret"));
                    Same(text, Path.Combine(home, "x-secret", "text"));
                    Environment.SetEnvironmentVariable("MAKEPACK_PASSWORD", "WRONG");
                    Code(11, "t", secret);
                    Code(7, "a", "-y", "-p", "-ttar", Path.Combine(home, "p.tar"), text);   // tar takes no password
                    Code(0, "a", "-y", Path.Combine(home, "open.7z"), text);              // no -p: the variable is not used
                    Must(Opens(Path.Combine(home, "open.7z")) && Run("t", Path.Combine(home, "open.7z")) == 0, "a without -p encrypted");
                }
                finally { Environment.SetEnvironmentVariable("MAKEPACK_PASSWORD", null); }
                Code(11, "t", secret);
                Code(11, "l", secret);

                // t: intact 0, damaged 3, not an archive 2, missing 10; l lists to stdout.
                Code(0, "t", zip);
                Code(0, "l", vol + ".001");
                Must(outText.ToString().Contains("sub/c.txt") || outText.ToString().Contains("sub\\c.txt"), "l did not list sub/c.txt");
                var bytes = File.ReadAllBytes(zip);
                // The packed data only: with the header gone too, an unopenable 7z reads as one with encrypted names (11).
                for (var i = 64; i < bytes.Length / 2; i += 7) bytes[i] ^= 0x5A;
                var bad = Path.Combine(home, "bad.7z");
                File.WriteAllBytes(bad, bytes);
                Code(3, "t", bad);
                var plain = Path.Combine(home, "plain.txt");
                File.WriteAllText(plain, string.Concat(Enumerable.Repeat("not an archive\r\n", 1000)));
                Code(2, "t", plain);
                Code(10, "t", Path.Combine(home, "missing.7z"));
                Code(7, "t", "-psecret", zip);

                // x -y: an unsafe entry is skipped and the rest extracted -> a warning (1).
                var evil = Path.Combine(home, "evil.zip");
                using (var z = System.IO.Compression.ZipFile.Open(evil, System.IO.Compression.ZipArchiveMode.Create))
                    foreach (var name in new[] { "ok.txt", "../escaped.txt" })
                        using (var w = new StreamWriter(z.CreateEntry(name).Open())) w.Write(name);
                Code(1, "x", "-y", evil, "-o", Path.Combine(home, "x-evil"));
                Must(File.Exists(Path.Combine(home, "x-evil", "ok.txt")) && !File.Exists(Path.Combine(home, "escaped.txt")), "x -y on the unsafe zip");

                // Not ours: the GUI keeps these.
                Must(Cli.Run(["a", "--quick", zip]) == null && Cli.Run(["a", zip]) == null && Cli.Run(["x", zip, "--here"]) == null, "a GUI command was taken");

                Must(Engine.ExitCodeOf(new OperationCanceledException()) == 255 && Engine.ExitCodeOf(new InvalidOperationException(S.NoInputs)) == 10
                     && Engine.ExitCodeOf(new IOException("disk full")) == 2, "ExitCodeOf");
                Console.WriteLine("OK cli (a switches, volumes, masks, refused password, env password, t/l/x codes 0 1 2 3 7 10 11)");
            });
        }
        catch (Exception ex) { Console.WriteLine($"FAIL setup: {ex}"); fails++; }
        finally { Engine.Nuke(root); }

        Console.WriteLine(fails == 0 ? "ALL OK" : $"{fails} FAILED");
        return fails == 0 ? 0 : 1;
    }

    /// <summary>
    /// Puts back what this run sent to the Recycle Bin (items whose original folder is under <paramref name="root"/>),
    /// so the selftest proves the bin got them and still leaves the user's bin as it found it. Returns the count.
    /// </summary>
    static int FromRecycleBin(string root)
    {
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!)!;
        dynamic bin = shell.Namespace(10);   // CSIDL_BITBUCKET
        var restored = 0;
        foreach (var item in bin.Items())
        {
            string from = bin.GetDetailsOf(item, 1);   // "Original location"
            if (!from.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var verb in item.Verbs())
                if (((string)verb.Name).Replace("&", "") is "Restore" or "Відновити") { verb.DoIt(); restored++; break; }
        }
        return restored;
    }

    static void Noise(string path, int size, Random rnd)
    {
        var bytes = new byte[size];
        rnd.NextBytes(bytes);
        File.WriteAllBytes(path, bytes);
    }

    static void Pack(string[] inputs, string archive, ArchiveKind kind, string? password, bool encryptHeaders) =>
        Engine.Compress(inputs, archive, kind, new CompressOptions(Password: password, EncryptHeaders: encryptHeaders), Engine.NoProgress, default)
              .GetAwaiter().GetResult();

    static void Append(string archive, string? password, string[] inputs, string prefix, OverwriteMode onConflict) =>
        Engine.Append(Engine.Open(archive, password), inputs, prefix, CompressOptions.Default, Engine.NoProgress, default, _ => onConflict)
              .GetAwaiter().GetResult();

    static int Count(string archive, string? password)
    {
        using var a = Engine.Open(archive, password);
        return a.X.ArchiveFileData.Count;
    }

    static bool Opens(string archive)
    {
        try { Engine.Open(archive, null).Dispose(); return true; } catch { return false; }
    }

    /// <summary>Cancels on the first progress report: the job is under way by then.</summary>
    sealed class CancelOnReport(CancellationTokenSource cts) : IProgress<(int, string)>
    {
        public void Report((int, string) value) => cts.Cancel();
    }

    /// <summary>Cancels once the overall progress passes <paramref name="percent"/>.</summary>
    sealed class CancelPast(CancellationTokenSource cts, int percent) : IProgress<(int, string)>
    {
        public void Report((int, string) value) { if (value.Item1 > percent) cts.Cancel(); }
    }

    static void Unpack(Archive a, string dest, OverwriteMode mode) =>
        Engine.Extract(a, dest, null, mode, Engine.NoProgress, default, _ => OverwriteMode.Overwrite)
              .GetAwaiter().GetResult();

    /// <summary>Packs, lists, unpacks and compares. Returns the archive's per-file Method strings (e.g. "LZMA2:16 BCJ2").</summary>
    static string[] RoundTrip(ArchiveKind kind, string src, string root, CompressOptions? o = null, string tag = "")
    {
        var name = kind + tag;
        var archive = Path.Combine(root, name + Engine.Kind(kind).Ext);
        Engine.Compress([src], archive, kind, o ?? CompressOptions.Default, Engine.NoProgress, default).GetAwaiter().GetResult();
        using var a = Engine.Open(archive, null);
        var entries = a.X.ArchiveFileData.Where(f => !f.IsDirectory).ToList();
        if (entries.Count < 4) throw new Exception($"listed {entries.Count} file entries, expected 4+");
        var dest = Path.Combine(root, "out-" + name);
        Unpack(a, dest, OverwriteMode.Overwrite);
        Same(src, Path.Combine(dest, Path.GetFileName(src)));
        Console.WriteLine($"OK {name} ({new FileInfo(archive).Length} bytes)");
        return [.. entries.Where(f => f.Size > 0).Select(f => f.Method ?? "")];
    }

    static void Same(string expected, string actual)
    {
        foreach (var dir in Directory.EnumerateDirectories(expected, "*", SearchOption.AllDirectories))
            if (!Directory.Exists(Path.Combine(actual, Path.GetRelativePath(expected, dir))))
                throw new Exception("missing folder " + Path.GetRelativePath(expected, dir));
        foreach (var file in Directory.EnumerateFiles(expected, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(expected, file);
            var other = Path.Combine(actual, rel);
            if (!File.Exists(other)) throw new Exception("missing " + rel);
            if (!File.ReadAllBytes(file).SequenceEqual(File.ReadAllBytes(other))) throw new Exception("differs " + rel);
        }
    }
}
