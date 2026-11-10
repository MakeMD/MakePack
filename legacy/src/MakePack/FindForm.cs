using System.Collections.Concurrent;
using System.IO.Enumeration;
using System.Text;

namespace MakePack;

/// <summary>
/// Find files (F3): masks + optional text, on disk and inside archives. Modeless; a result is
/// (path on disk, entry inside that archive or null) and goes back to the main window through locate / view.
/// </summary>
sealed class FindForm : Form
{
    static readonly Encoding[] Encodings = TextEncodings();

    readonly TextBox _masks, _text, _lookIn;
    readonly CheckBox _case, _subfolders, _archives;
    readonly Button _find;
    readonly ListView _list;
    readonly Label _status;
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 200 };
    readonly ConcurrentQueue<(string Path, string? Inner, long Size)> _queue = new();
    CancellationTokenSource? _cts;
    volatile string? _current;   // folder the worker is in, for the status line
    int _skipped;

    FindForm(string root, Action<string, string?> locate, Action<string, string?> view)
    {
        Text = S.FindFilesTitle;
        Font = new Font("Segoe UI", 9.5f);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = ShowInTaskbar = false;
        ClientSize = new Size(680, 480);
        MinimumSize = new Size(520, 360);

        // Width is set before the children go in so their Right anchors are measured against the real width.
        var top = new Panel { Dock = DockStyle.Top, Height = 132, Width = ClientSize.Width };
        Label Caption(string text, int y) => new() { Text = text, Left = 12, Top = y + 3, Width = 140, AutoEllipsis = true };
        TextBox Box(string text, int y, int right) => new()
        {
            Text = text, Left = 156, Top = y, Width = top.Width - 156 - right, Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right,
        };
        _masks = Box("*.*", 10, 12);
        _text = Box("", 40, 12);
        _lookIn = Box(root, 70, 118);
        var browse = new Button { Text = S.Browse, Left = top.Width - 112, Top = 69, Width = 100, Height = 26, FlatStyle = FlatStyle.System, Anchor = AnchorStyles.Top | AnchorStyles.Right };
        browse.Click += (_, _) => Browse();
        _case = new CheckBox { Text = S.MatchCase, Left = 156, Top = 102, AutoSize = true };
        _subfolders = new CheckBox { Text = S.Subfolders, Left = 330, Top = 102, AutoSize = true, Checked = true };
        _archives = new CheckBox { Text = S.InArchives, Left = 470, Top = 102, AutoSize = true, Checked = true };
        top.Controls.AddRange([Caption(S.FileMasks, 10), _masks, Caption(S.TextToFind, 40), _text, Caption(S.LookIn, 70), _lookIn, browse, _case, _subfolders, _archives]);

        _list = new ListView
        {
            Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
            UseCompatibleStateImageBehavior = false,
        };
        _list.Columns.Add(S.FileColumn, 200);
        _list.Columns.Add(S.Location, 340);
        _list.Columns.Add(S.Size, 100, HorizontalAlignment.Right);
        _list.DoubleClick += (_, _) => Pick(locate);

        _status = new Label { Dock = DockStyle.Bottom, Height = 22, Padding = new Padding(10, 3, 10, 0), AutoEllipsis = true };

        Button Btn(string text) => new() { Text = text, Width = 110, Height = 28, FlatStyle = FlatStyle.System };
        _find = Btn(S.TbFind);
        _find.Click += (_, _) => Find();
        var showBtn = Btn(S.Locate);
        showBtn.Click += (_, _) => Pick(locate);
        var viewBtn = Btn(S.TbView);
        viewBtn.Click += (_, _) => Pick(view);
        var close = Btn(S.Close);
        close.Click += (_, _) => Close();
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8, 6, 8, 6) };
        bottom.Controls.AddRange([close, viewBtn, showBtn, _find]);

        Controls.AddRange([_list, top, _status, bottom]);   // Fill first: docking runs in reverse z-order
        AcceptButton = _find;
        CancelButton = close;
        _timer.Tick += (_, _) => Flush();
    }

    public static void Open(IWin32Window owner, string root, Action<string, string?> locate, Action<string, string?> view)
        => new FindForm(root, locate, view).Show(owner);

    void Browse()
    {
        using var d = new FolderBrowserDialog { SelectedPath = Directory.Exists(_lookIn.Text) ? _lookIn.Text : "" };
        if (d.ShowDialog(this) == DialogResult.OK) _lookIn.Text = d.SelectedPath;
    }

    void Pick(Action<string, string?> to)
    {
        if (_list.SelectedItems.Count == 1 && _list.SelectedItems[0].Tag is ValueTuple<string, string?> r) to(r.Item1, r.Item2);
    }

    /// <summary>Find, or Stop while a search runs (same button, like classic archivers).</summary>
    async void Find()
    {
        if (_cts != null) { _cts.Cancel(); return; }
        _list.Items.Clear();
        _skipped = 0;
        _cts = new CancellationTokenSource();
        _find.Text = S.Stop;
        var (root, masks, text, matchCase, sub, arc, ct) =
            (_lookIn.Text.Trim(), _masks.Text, _text.Text, _case.Checked, _subfolders.Checked, _archives.Checked, _cts.Token);
        string? error = null;
        _timer.Start();
        try
        {
            await Task.Run(() =>
            {
                foreach (var r in Search(root, masks, text, matchCase, sub, arc, ct, d => _current = d, () => Interlocked.Increment(ref _skipped)))
                    _queue.Enqueue(r);
            }, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { error = Engine.Friendly(ex); }
        if (IsDisposed) return;   // closed mid-search: the close already cancelled it
        _timer.Stop();
        _current = null;
        Flush();
        if (error != null) _status.Text = error;
        _cts.Dispose();
        _cts = null;
        _find.Text = S.TbFind;
    }

    /// <summary>Moves what the worker found into the list - in batches on a timer, not one Invoke per hit.</summary>
    void Flush()
    {
        if (!_queue.IsEmpty)
        {
            _list.BeginUpdate();
            while (_queue.TryDequeue(out var r))
            {
                var inner = r.Inner == null ? null : Path.GetDirectoryName(r.Inner.Replace('/', '\\'));
                var location = r.Inner == null ? Path.GetDirectoryName(r.Path) ?? "" : string.IsNullOrEmpty(inner) ? r.Path : r.Path + "\\" + inner;
                var name = Path.GetFileName(r.Inner ?? r.Path);
                _list.Items.Add(new ListViewItem([name, location, Engine.NiceSize(r.Size)]) { Tag = (r.Path, r.Inner) });
            }
            _list.EndUpdate();
        }
        var s = string.Format(S.FoundFmt, _list.Items.Count);
        if (_skipped > 0) s += string.Format(S.SkippedFmt, _skipped);
        if (_current is { } dir) s += "  -  " + dir;
        _status.Text = s;
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _cts?.Cancel();
        _timer.Dispose();
        base.OnFormClosed(e);
    }

    // ---- search (no UI) ----------------------------------------------------------------------------

    static Encoding[] TextEncodings()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        return [new UTF8Encoding(false), new UnicodeEncoding(false, false), Encoding.GetEncoding(1251)];
    }

    /// <summary>Name against "*.cs;*.md" - Win32 wildcard rules (so "*.*" is everything), case-insensitive. Empty = all.</summary>
    internal static bool Matches(string name, string masks)
    {
        var any = false;
        foreach (var m in masks.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            any = true;
            if (FileSystemName.MatchesWin32Expression(FileSystemName.TranslateWin32Expression(m), name, ignoreCase: true)) return true;
        }
        return !any;
    }

    /// <summary>
    /// Every match under <paramref name="root"/> (a folder, or an archive file = only inside it): (path on disk,
    /// entry inside the archive or null, size). <paramref name="folder"/> hears the folder being walked,
    /// <paramref name="skip"/> each archive or file that could not be read.
    /// </summary>
    internal static IEnumerable<(string Path, string? Inner, long Size)> Search(string root, string masks, string? text, bool matchCase,
        bool subfolders, bool archives, CancellationToken ct, Action<string>? folder = null, Action? skip = null)
    {
        text = string.IsNullOrEmpty(text) ? null : text;
        if (File.Exists(root))
        {
            foreach (var r in InArchive(root, masks, text, matchCase, ct, skip)) yield return r;
            yield break;
        }
        // Reparse points skipped: a junction loop (or a OneDrive placeholder that would download) can't hang the walk.
        var opts = new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = subfolders, AttributesToSkip = FileAttributes.ReparsePoint };
        string? last = null;
        foreach (var f in new DirectoryInfo(root).EnumerateFiles("*", opts))
        {
            ct.ThrowIfCancellationRequested();
            if (f.DirectoryName != last) folder?.Invoke(last = f.DirectoryName ?? "");
            if (Matches(f.Name, masks) && (text == null || FileHas(f, text, matchCase, skip)))
                yield return (f.FullName, null, f.Length);
            // ponytail: only known archive extensions are opened (not every docx/apk that is a zip underneath).
            if (archives && Assoc.All.Contains(f.Extension.TrimStart('.'), StringComparer.OrdinalIgnoreCase) && Engine.LooksLikeArchive(f.FullName))
                foreach (var r in InArchive(f.FullName, masks, text, matchCase, ct, skip)) yield return r;
        }
    }

    // ponytail: archives inside archives are not opened; Engine.Open's own unwrapping (x.tar.gz, .001) still applies.
    static IEnumerable<(string Path, string? Inner, long Size)> InArchive(string path, string masks, string? text, bool matchCase,
        CancellationToken ct, Action? skip)
    {
        Archive a;
        try { a = Engine.Open(path, null); }
        catch { skip?.Invoke(); yield break; }   // encrypted file list, damaged, locked
        using (a)
        {
            foreach (var e in a.X.ArchiveFileData)
            {
                ct.ThrowIfCancellationRequested();
                var inner = Engine.Norm(e.FileName);
                if (e.IsDirectory || inner.Length == 0 || !Matches(inner[(inner.LastIndexOf('/') + 1)..], masks)) continue;
                // Names of encrypted entries are readable, so they still match by name; their contents are skipped.
                if (text != null && !EntryHas(a, e, text, matchCase, skip)) continue;
                yield return (path, inner, (long)e.Size);
            }
        }
    }

    // ponytail: 256 MB on disk / 64 MB in an archive are the text-search ceilings; bigger files match by name only.
    // Entries are extracted one by one, so a big solid 7z re-decodes its block per entry - fine for "find", slow for huge solids.
    const long MaxDiskText = 256L << 20, MaxEntryText = 64L << 20;

    static bool FileHas(FileInfo f, string text, bool matchCase, Action? skip)
    {
        if (f.Length > MaxDiskText) return false;
        try { using var s = f.OpenRead(); return Contains(s, text, matchCase); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { skip?.Invoke(); return false; }
    }

    static bool EntryHas(Archive a, SevenZip.ArchiveFileInfo e, string text, bool matchCase, Action? skip)
    {
        if (e.Encrypted) { skip?.Invoke(); return false; }
        if ((long)e.Size > MaxEntryText) return false;
        try
        {
            using var ms = new MemoryStream();
            a.X.ExtractFile(e.Index, ms);
            ms.Position = 0;
            return Contains(ms, text, matchCase);
        }
        catch { skip?.Invoke(); return false; }
    }

    /// <summary>
    /// The text as UTF-8, UTF-16LE or Windows-1251. One pass over the bytes, three stateful decoders (a character split
    /// across reads is completed on the next one), and each keeps the last text.Length-1 chars so a hit across reads counts.
    /// </summary>
    // ponytail: UTF-16 is decoded from offset 0 only - text in a UTF-16 run that starts at an odd byte is missed.
    internal static bool Contains(Stream s, string text, bool matchCase)
    {
        var cmp = matchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var decoders = Encodings.Select(e => e.GetDecoder()).ToArray();
        var tails = new string[decoders.Length];
        Array.Fill(tails, "");
        var buf = new byte[256 << 10];
        var chars = new char[Encodings.Max(e => e.GetMaxCharCount(buf.Length))];
        for (int n; (n = s.Read(buf)) > 0; )
            for (var i = 0; i < decoders.Length; i++)
            {
                var hay = tails[i] + new string(chars, 0, decoders[i].GetChars(buf, 0, n, chars, 0, flush: false));
                if (hay.Contains(text, cmp)) return true;
                tails[i] = hay[Math.Max(0, hay.Length - (text.Length - 1))..];
            }
        return false;
    }
}

