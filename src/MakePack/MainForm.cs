using System.Collections;
using System.Diagnostics;
using System.Runtime.InteropServices;
using SevenZip;

namespace MakePack;

sealed class MainForm : Form
{
    Archive? _a;
    string _cur = "";                       // current folder inside the archive: "" or "sub/deeper/"
    bool _dragging;                         // our own drag-out is in flight: a drop back onto us is ignored
    bool _editing;                          // a label edit is open: its keys belong to the edit box
    Func<bool>? _dropJob;                   // drag-out: extracts the dragged files at drop time; false = failed/cancelled
    DragDropEffects _feedback;              // drag-out: the effect the pointer's current target offers
    readonly ListView _list;
    readonly TextBox _path;
    readonly ToolStripStatusLabel _status;
    readonly ToolStripButton _bAdd, _bExtract, _bTest, _bInfo, _bDelete;
    readonly Comparer _sorter = new();

    public MainForm(string? archive)
    {
        Text = S.App;
        Size = new Size(960, 600);
        MinimumSize = new Size(640, 400);
        Font = new Font("Segoe UI", 9.5f);
        AllowDrop = true;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { /* icon is optional */ }

        var tools = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, RenderMode = ToolStripRenderMode.System, Padding = new Padding(4, 2, 4, 2) };
        ToolStripButton Btn(string text, Action click, string? keys = null)
        {
            var b = new ToolStripButton(text) { DisplayStyle = ToolStripItemDisplayStyle.Text, Padding = new Padding(6, 2, 6, 2), ToolTipText = keys };
            b.Click += (_, _) => click();
            tools.Items.Add(b);
            return b;
        }
        Btn(S.Open, DoOpen, "Ctrl+O");
        Btn(S.NewArchive, () => DoNew(null), "Ctrl+N");
        _bAdd = Btn(S.AddToArchive, DoAddFiles);
        _bExtract = Btn(S.Extract, DoExtract, "Ctrl+E");
        _bTest = Btn(S.Test, DoTest);
        _bInfo = Btn(S.Info, DoInfo);
        _bDelete = Btn(S.Delete, DoDelete, "Del");
        Btn(S.ConvertMenu, DoConvert);
        var report = new ToolStripDropDownButton(S.ReportMenu) { DisplayStyle = ToolStripItemDisplayStyle.Text, Padding = new Padding(6, 2, 6, 2) };
        report.DropDownItems.Add(S.ReportHtml, null, (_, _) => SaveReport(html: true));
        report.DropDownItems.Add(S.ReportTxt, null, (_, _) => SaveReport(html: false));
        report.DropDownItems.Add(S.ReportCopy, null, (_, _) => CopyReport());
        tools.Items.Add(report);
        // Right-aligned items are laid out from the right edge, so the last one added sits leftmost.
        Btn(S.SettingsMenu, () => SettingsForm.Edit(this)).Alignment = ToolStripItemAlignment.Right;
        Btn(S.Assoc, () => AssocForm.Edit(this)).Alignment = ToolStripItemAlignment.Right;

        _path = new TextBox { Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.FixedSingle };
        var up = new Button { Dock = DockStyle.Right, Width = 70, Text = S.Up, FlatStyle = FlatStyle.System };
        up.Click += (_, _) => Up();
        var bar = new Panel { Dock = DockStyle.Top, Height = 26, Padding = new Padding(4, 2, 4, 2) };
        bar.Controls.AddRange([_path, up]);

        _list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            MultiSelect = true,
            HideSelection = false,
            UseCompatibleStateImageBehavior = false,
            AllowDrop = true,
            LabelEdit = true,
            SmallImageList = StockIcons(),
            ContextMenuStrip = ListMenu(),
        };
        _list.Columns.Add(S.Name, 360);
        _list.Columns.Add(S.Size, 100, HorizontalAlignment.Right);
        _list.Columns.Add(S.Modified, 140);
        _list.Columns.Add(S.Type, 100);
        _list.Columns.Add(S.Crc, 90);
        _list.ItemActivate += (_, _) => OpenItem(_list.FocusedItem);
        _list.SelectedIndexChanged += (_, _) => UpdateStatus();
        _list.ColumnClick += (_, e) =>
        {
            _sorter.Ascending = _sorter.Column == e.Column ? !_sorter.Ascending : true;
            _sorter.Column = e.Column;
            _list.ListViewItemSorter = _sorter;
            _list.Sort();
        };
        _list.DragEnter += (_, e) => Dragging(e);
        _list.DragDrop += (_, e) => Dropped(e);
        _list.ItemDrag += (_, _) => DragOut();
        _list.BeforeLabelEdit += (_, e) =>
        {
            e.CancelEdit = _a == null || !Engine.CanDelete(_a);
            _editing = !e.CancelEdit;
        };
        _list.AfterLabelEdit += (_, e) =>
        {
            _editing = false;
            e.CancelEdit = true;                        // the list is refilled from the archive either way
            var old = _list.Items[e.Item].Text;
            var name = e.Label?.Trim();
            // After the event: an edit that rewrites the archive and refills the list must not run inside it.
            if (name != null && name != old) BeginInvoke(() => DoRename(old, name));
        };

        _status = new ToolStripStatusLabel();
        var strip = new StatusStrip();
        strip.Items.Add(_status);

        Controls.AddRange([_list, bar, tools, strip]);
        UpdateUi();
        if (archive != null) OpenArchive(archive);
    }

    // ---- opening -------------------------------------------------------------------------------

    public bool OpenArchive(string path, string? password = null, string cur = "")
    {
        var a = password == null ? PasswordForm.OpenArchive(this, path) : TryOpen(path, password);
        if (a == null) return false;
        Adopt(a, cur);
        return true;
    }

    Archive? TryOpen(string path, string? password)
    {
        try { return Engine.Open(path, password); }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.CannotOpen, MessageBoxButtons.OK, MessageBoxIcon.Error); return null; }
    }

    /// <param name="cur">Folder to show; when an edit took it away, the nearest parent still there.</param>
    void Adopt(Archive a, string cur = "")
    {
        _a?.Dispose();
        _a = a;
        while (cur.Length > 0 && !a.X.ArchiveFileData.Any(f => (Engine.Norm(f.FileName) + "/").StartsWith(cur, StringComparison.OrdinalIgnoreCase)))
            cur = ParentOf(cur);
        _cur = cur;
        Text = $"{S.App} — {a.Display}";
        Fill();
    }

    /// <summary>The open archive went away (to the Recycle Bin after extraction): back to the empty window.</summary>
    void Unload()
    {
        _a?.Dispose();
        _a = null;
        _cur = "";
        Text = S.App;
        Fill();
    }

    /// <summary>After an edit: reopen, stay in <paramref name="cur"/>, say what happened.</summary>
    void Reload(string source, string? password, string cur, string? status, string? select = null)
    {
        if (!OpenArchive(source, password, cur)) return;
        var item = _list.Items.Cast<ListViewItem>().FirstOrDefault(i => i.Text.Equals(select, StringComparison.OrdinalIgnoreCase));
        if (item != null) { item.Selected = item.Focused = true; item.EnsureVisible(); }
        if (status != null) _status.Text = status;
    }

    /// <summary>The open archive with its bodies' password in hand (asked for when needed); null = cancelled.</summary>
    Archive? Ready()
    {
        if (_a == null) return null;
        var ready = PasswordForm.EnsurePassword(this, _a);
        if (ready != null && !ReferenceEquals(ready, _a)) Adopt(ready, _cur);   // Adopt disposes the one we came in with
        return ready == null ? null : _a;
    }

    // ---- listing -------------------------------------------------------------------------------

    void Fill()
    {
        _list.BeginUpdate();
        _list.ListViewItemSorter = null;     // sorting per Add would be quadratic
        _list.Items.Clear();
        if (_a != null)
        {
            var folders = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            var files = new List<ArchiveFileInfo>();
            foreach (var f in _a.X.ArchiveFileData)
            {
                var n = Engine.Norm(f.FileName);
                if (n.Length == 0 || !n.StartsWith(_cur, StringComparison.OrdinalIgnoreCase)) continue;
                var rest = n[_cur.Length..];
                if (rest.Length == 0) continue;
                var slash = rest.IndexOf('/');
                if (slash >= 0) folders.Add(rest[..slash]);
                else if (f.IsDirectory) folders.Add(rest);
                else files.Add(f);
            }
            foreach (var folder in folders)
                _list.Items.Add(new ListViewItem([folder, "", "", S.FolderType, ""], 0) { Tag = folder });
            foreach (var f in files)
            {
                var name = Engine.Norm(f.FileName)[_cur.Length..];
                var ext = Path.GetExtension(name).TrimStart('.').ToUpperInvariant();
                _list.Items.Add(new ListViewItem(
                [
                    name,
                    Engine.NiceSize((long)f.Size),
                    f.LastWriteTime == default ? "" : f.LastWriteTime.ToString("yyyy-MM-dd HH:mm"),
                    ext,
                    f.Crc == 0 ? "" : f.Crc.ToString("X8"),
                ], 1) { Tag = f });
            }
        }
        _list.ListViewItemSorter = _sorter;
        _list.Sort();
        _list.EndUpdate();
        UpdateUi();
    }

    void UpdateUi()
    {
        var open = _a != null;
        _bAdd.Enabled = _bExtract.Enabled = _bTest.Enabled = _bInfo.Enabled = open;
        _bDelete.Enabled = open && Engine.CanDelete(_a!);
        _path.Text = _a == null ? "" : _a.Source + "\\" + _cur.Replace('/', '\\');
        UpdateStatus();
    }

    void UpdateStatus()
    {
        if (_a == null) { _status.Text = ""; return; }
        var sel = _list.SelectedItems.Cast<ListViewItem>().ToArray();
        _status.Text = sel.Length == 0
            ? string.Format(S.ItemsFmt, _list.Items.Count)
            : string.Format(S.SelectedFmt, sel.Length,
                Engine.NiceSize(sel.Sum(i => i.Tag is ArchiveFileInfo f ? (long)f.Size : 0)));
    }

    void Navigate(string folder) { _cur += folder + "/"; Fill(); }

    void Up()
    {
        if (_cur.Length == 0) return;
        _cur = ParentOf(_cur);
        Fill();
    }

    /// <summary>"a/b/" -> "a/", "a/" -> "".</summary>
    static string ParentOf(string folder)
    {
        var slash = folder.TrimEnd('/').LastIndexOf('/');
        return slash < 0 ? "" : folder[..(slash + 1)];
    }

    void OpenItem(ListViewItem? item)
    {
        if (item == null || _a == null) return;
        if (item.Tag is string folder) { Navigate(folder); return; }
        if (item.Tag is not ArchiveFileInfo f) return;

        var a = _a;
        var dir = Engine.NewTempDir();
        using var progress = new ProgressForm(S.Extracting);
        if (!progress.Run(this, (p, ct) => Engine.Extract(a, dir, [f.Index], OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite))) return;
        var file = Path.Combine(dir, Engine.Norm(f.FileName).Replace('/', '\\'));
        if (File.Exists(file)) Process.Start(new ProcessStartInfo(file) { UseShellExecute = true });
    }

    /// <summary>Indices to act on: null when nothing is selected (= the whole archive).</summary>
    int[]? Selected()
    {
        if (_a == null || _list.SelectedItems.Count == 0) return null;
        var set = new HashSet<int>();
        var folders = new List<string>();
        foreach (ListViewItem item in _list.SelectedItems)
            if (item.Tag is ArchiveFileInfo f) set.Add(f.Index);
            else folders.Add(_cur + item.Tag + "/");
        if (folders.Count > 0)                      // a selected folder means every entry under it
            foreach (var f in _a.X.ArchiveFileData)
            {
                var n = Engine.Norm(f.FileName);
                if (folders.Any(p => n.StartsWith(p, StringComparison.OrdinalIgnoreCase)
                                  || string.Equals(n, p[..^1], StringComparison.OrdinalIgnoreCase)))
                    set.Add(f.Index);
            }
        return [.. set];
    }

    // ---- commands ------------------------------------------------------------------------------

    void DoOpen()
    {
        using var d = new OpenFileDialog
        {
            Title = S.Open.TrimEnd('…'),
            Filter = $"{S.Archives}|*.7z;*.zip;*.rar;*.tar;*.gz;*.tgz;*.bz2;*.tbz2;*.xz;*.txz;*.wim;*.iso;*.cab;*.lzh;*.arj;*.cpio;*.rpm;*.deb;*.msi;*.chm;*.dmg;*.vhd;*.001|{S.AllFiles}|*.*",
        };
        if (d.ShowDialog(this) == DialogResult.OK) OpenArchive(d.FileName);
    }

    void DoNew(IEnumerable<string>? inputs)
    {
        using var f = new CompressForm(inputs ?? []);
        f.ShowDialog(this);
        if (f.CreatedPath != null) OpenArchive(f.CreatedPath);
    }

    void DoExtract()
    {
        var indices = Selected();
        var a = Ready();
        if (a == null) return;
        var choice = ExtractForm.Ask(this, a);
        if (choice == null) return;

        using var progress = new ProgressForm(S.Extracting);
        var ok = progress.Run(this, (p, ct) => Engine.Extract(a, choice.Dest, indices, choice.Mode, p, ct,
                                                              ExtractForm.Conflicts(progress), options: choice.Options));
        // Only the whole archive, extracted without an error, is ever offered for deletion.
        if (ok && indices == null) ExtractForm.AfterExtract(this, a.Source, choice.Delete, Unload);
    }

    /// <summary>The file list as HTML (opens in any browser) or text (UTF-8 with BOM, so Notepad shows Cyrillic right).</summary>
    void SaveReport(bool html)
    {
        if (_a == null) return;
        var ext = html ? ".html" : ".txt";
        using var d = new SaveFileDialog
        {
            FileName = Engine.BaseName(_a.Source) + S.ReportSuffix + ext,
            InitialDirectory = Path.GetDirectoryName(_a.Source) ?? "",
            Filter = html ? "HTML|*.html" : $"{S.TextFiles}|*.txt",
        };
        if (d.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            Engine.WriteReport(_a, d.FileName, html);
            _status.Text = string.Format(S.ReportSavedFmt, Path.GetFileName(d.FileName));
        }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    void CopyReport()
    {
        if (_a == null) return;
        Clipboard.SetText(Engine.Report(_a, html: false));
        _status.Text = S.ReportCopied;
    }

    /// <summary>Convert archives, starting with the open one. It is closed while converting and reopened if still there.</summary>
    void DoConvert()
    {
        string? reopen = null;
        using (var f = new ConvertForm(_a == null ? [] : [_a.Source], () => { if (_a != null) { reopen = _a.Source; Unload(); } }))
            f.ShowDialog(this);
        if (reopen != null && File.Exists(reopen)) OpenArchive(reopen);
    }

    void DoTest()
    {
        var a = _a;
        if (a == null) return;
        var ok = false;
        using var progress = new ProgressForm(S.Testing);
        if (!progress.Run(this, async (p, ct) => { ok = await Engine.Test(a, p, ct); })) return;
        MessageBox.Show(this, ok ? S.TestOk : S.TestFailed, S.App, MessageBoxButtons.OK,
            ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
    }

    void DoInfo()
    {
        if (_a != null) InfoForm.Show(this, _a);
    }

    void DoDelete()
    {
        if (_a == null) return;
        var indices = Selected();
        if (indices is not { Length: > 0 }) return;
        if (!Engine.CanDelete(_a)) { MessageBox.Show(this, S.NotSupported, S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        if (MessageBox.Show(this, S.ConfirmDelete, S.App, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        var count = _list.SelectedItems.Count;
        var archive = Ready();                       // deleting from a solid encrypted block repacks it
        if (archive == null) return;
        Modify(S.Deleting, (_, _, _) => Engine.Delete(archive, indices), string.Format(S.DeletedFmt, count));
    }

    /// <summary>Runs an edit that closes the archive (Engine.Edit) under a progress window, then reopens it in the same folder.</summary>
    void Modify(string title, Func<Control, IProgress<(int percent, string file)>, CancellationToken, Task> edit,
                string status, string? select = null)
    {
        var (source, password, cur) = (_a!.Source, _a.Password, _cur);
        _a = null;                                   // the edit closes it
        bool ok;
        using (var progress = new ProgressForm(title)) ok = progress.Run(this, (p, ct) => edit(progress, p, ct));
        Reload(source, password, cur, ok ? status : null, ok ? select : null);
    }

    void DoAddFiles()
    {
        if (_a == null) return;
        using var d = new OpenFileDialog { Multiselect = true, Title = S.AddFilesToArchive.TrimEnd('…'), Filter = $"{S.AllFiles}|*.*" };
        // ponytail: files only here - folders come in by drag and drop (a folder picker is the upgrade path).
        if (d.ShowDialog(this) == DialogResult.OK) DoAdd(d.FileNames);
    }

    void DoAdd(string[] files)
    {
        if (_a == null || files.Length == 0) return;
        if (!Engine.CanDelete(_a))
        {
            if (MessageBox.Show(this, S.NotSupported + "\n\n" + S.OfferNewArchive, S.App,
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) DoNew(files);
            return;
        }
        var a = Ready();                             // new files get the archive's password too
        if (a == null) return;
        var cur = _cur;
        Modify(S.Adding, (owner, p, ct) => Engine.Append(a, files, cur, CompressOptions.Default, p, ct,
                                                         ExtractForm.Conflicts(owner, append: true)),
               string.Format(S.AddedFmt, files.Length));
    }

    void BeginRename()
    {
        if (_a != null && Engine.CanDelete(_a) && _list.FocusedItem is { Selected: true } item) item.BeginEdit();
    }

    void DoRename(string old, string name)
    {
        if (_a == null) return;
        if (name.Length == 0 || name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '*', '?', '"', '<', '>', '|']) >= 0)
        { MessageBox.Show(this, S.BadName, S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        // Case-only renames pass: the sibling with that name is the item itself.
        if (_list.Items.Cast<ListViewItem>().Any(i => i.Text.Equals(name, StringComparison.OrdinalIgnoreCase)
                                                   && !i.Text.Equals(old, StringComparison.OrdinalIgnoreCase)))
        { MessageBox.Show(this, S.NameTaken, S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        var a = _a;
        var (from, to) = (_cur + old, _cur + name);
        Modify(S.Renaming, (_, _, _) => Engine.Rename(a, from, to), string.Format(S.RenamedFmt, name), name);
    }

    /// <summary>
    /// Drag the selection out to Explorer, the 7-Zip way: the drag carries temp-folder paths that do not exist yet,
    /// and the files are extracted there at drop time (OnQueryContinueDrag), before the target reads them.
    /// Extracting first and dragging afterwards does not work: the progress window eats the press.
    /// </summary>
    // ponytail: a delayed-render IDataObject (CFSTR_FILEDESCRIPTOR/FILECONTENTS) is the upgrade path.
    // The temp copy lives until MakePack exits.
    void DragOut()
    {
        var before = _a;
        var a = Ready();
        if (a == null || !ReferenceEquals(a, before)) return;   // a password prompt took the press: drag again
        var indices = Selected();
        if (indices is not { Length: > 0 }) return;
        var dir = Engine.NewTempDir();
        var paths = _list.SelectedItems.Cast<ListViewItem>()
                         .Select(i => Path.Combine(dir, (_cur + i.Text).Replace('/', '\\'))).ToArray();
        _dropJob = () =>
        {
            using var progress = new ProgressForm(S.Extracting);
            return progress.Run(this, (p, ct) => Engine.Extract(a, dir, indices, OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite));
        };
        _feedback = DragDropEffects.None;
        _dragging = true;
        try { DoDragDrop(new DataObject(DataFormats.FileDrop, paths), DragDropEffects.Copy); }
        finally { _dragging = false; _dropJob = null; }
    }

    ContextMenuStrip ListMenu()
    {
        var menu = new ContextMenuStrip();
        ToolStripMenuItem Item(string text, Action click, string keys)
        {
            // Display only: the keys themselves go through ProcessCmdKey, a real ShortcutKeys would fire twice.
            var m = new ToolStripMenuItem(text, null, (_, _) => click()) { ShortcutKeyDisplayString = keys };
            menu.Items.Add(m);
            return m;
        }
        var open = Item(S.Open.TrimEnd('…'), () => OpenItem(_list.FocusedItem), "Enter");
        Item(S.Extract, DoExtract, "Ctrl+E");
        var rename = Item(S.Rename, BeginRename, "F2");
        var delete = Item(S.Delete, DoDelete, "Del");
        menu.Items.Add(new ToolStripSeparator());
        Item(S.AddFilesToArchive, DoAddFiles, "");
        menu.Opening += (_, e) =>
        {
            if (_a == null) { e.Cancel = true; return; }
            var sel = _list.SelectedItems.Count;
            var edit = Engine.CanDelete(_a);
            open.Enabled = sel == 1;
            rename.Enabled = sel == 1 && edit;
            delete.Enabled = sel > 0 && edit;
        };
        return menu;
    }

    // ---- input ---------------------------------------------------------------------------------

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_editing) return base.ProcessCmdKey(ref msg, keyData);   // Back, Del, Ctrl+A belong to the edit box
        switch (keyData)
        {
            case Keys.Control | Keys.O: DoOpen(); return true;
            case Keys.Control | Keys.N: DoNew(null); return true;
            case Keys.Control | Keys.E: DoExtract(); return true;
            case Keys.Control | Keys.A when _list.Focused:
                _list.BeginUpdate();
                foreach (ListViewItem i in _list.Items) i.Selected = true;
                _list.EndUpdate();
                return true;
            case Keys.F2: BeginRename(); return true;
            case Keys.Back: Up(); return true;
            case Keys.Delete: DoDelete(); return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnDragEnter(DragEventArgs e) { Dragging(e); base.OnDragEnter(e); }
    protected override void OnDragDrop(DragEventArgs e) { Dropped(e); base.OnDragDrop(e); }

    // Our own drag-out (DoDragDrop is the form's, so these fire here). Feedback = what the pointer is over:
    // None over nothing that takes files, and over this window (Dragging refuses our own drag).
    protected override void OnGiveFeedback(GiveFeedbackEventArgs e) { _feedback = e.Effect; base.OnGiveFeedback(e); }

    protected override void OnQueryContinueDrag(QueryContinueDragEventArgs e)
    {
        // Button released: extract now, while the target still waits for its Drop; a failure cancels the drop.
        if (e.Action == DragAction.Drop && _dropJob is { } job)
        {
            _dropJob = null;
            if (_feedback == DragDropEffects.None || !job()) e.Action = DragAction.Cancel;
        }
        base.OnQueryContinueDrag(e);
    }

    void Dragging(DragEventArgs e) => e.Effect = !_dragging && e.Data?.GetDataPresent(DataFormats.FileDrop) == true
        ? DragDropEffects.Copy : DragDropEffects.None;

    void Dropped(DragEventArgs e)
    {
        if (_dragging || e.Data?.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
        // After the event: Explorer's drag waits for this handler, and the dialogs below are modal.
        // With an archive open the files go into it; otherwise a dropped archive is opened (password prompt and
        // all) and anything else becomes a new archive.
        BeginInvoke(() =>
        {
            if (_a != null) DoAdd(files);
            else if (files.Length == 1 && File.Exists(files[0]) && Engine.LooksLikeArchive(files[0])) OpenArchive(files[0]);
            else DoNew(files);
        });
    }

    protected override void OnFormClosed(FormClosedEventArgs e) { _a?.Dispose(); base.OnFormClosed(e); }

    // ---- sorting & icons -----------------------------------------------------------------------

    sealed class Comparer : IComparer
    {
        public int Column;
        public bool Ascending = true;

        public int Compare(object? a, object? b)
        {
            var x = (ListViewItem)a!;
            var y = (ListViewItem)b!;
            var fx = x.Tag is string;
            var fy = y.Tag is string;
            if (fx != fy) return fx ? -1 : 1;                    // folders always first
            var r = Column switch
            {
                1 => Size(x).CompareTo(Size(y)),
                2 => Time(x).CompareTo(Time(y)),
                _ => string.Compare(x.SubItems[Column].Text, y.SubItems[Column].Text, StringComparison.OrdinalIgnoreCase),
            };
            if (r == 0 && Column != 0) r = string.Compare(x.Text, y.Text, StringComparison.OrdinalIgnoreCase);
            return Ascending ? r : -r;
        }

        static ulong Size(ListViewItem i) => i.Tag is ArchiveFileInfo f ? f.Size : 0;
        static DateTime Time(ListViewItem i) => i.Tag is ArchiveFileInfo f ? f.LastWriteTime : default;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StockIconInfo
    {
        public int cbSize;
        public IntPtr hIcon;
        public int iSysImageIndex;
        public int iIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szPath;
    }

    [DllImport("shell32.dll")] static extern int SHGetStockIconInfo(int siid, int flags, ref StockIconInfo info);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);

    /// <summary>Image 0 = folder, image 1 = generic document. Null when the shell says no.</summary>
    static ImageList? StockIcons()
    {
        try
        {
            var list = new ImageList { ImageSize = new Size(16, 16), ColorDepth = ColorDepth.Depth32Bit };
            foreach (var siid in new[] { 3 /* SIID_FOLDER */, 0 /* SIID_DOCNOASSOC */ })
            {
                var info = new StockIconInfo { cbSize = Marshal.SizeOf<StockIconInfo>() };
                if (SHGetStockIconInfo(siid, 0x101 /* SHGSI_ICON | SHGSI_SMALLICON */, ref info) != 0 || info.hIcon == IntPtr.Zero)
                    return null;
                using (var icon = Icon.FromHandle(info.hIcon)) list.Images.Add(icon.ToBitmap());
                DestroyIcon(info.hIcon);
            }
            return list;
        }
        catch { return null; }
    }
}
