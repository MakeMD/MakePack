using System.Collections;
using System.Diagnostics;
using System.Runtime.InteropServices;
using SevenZip;

namespace MakePack;

/// <summary>
/// The main window, laid out like the classic (research notes): menu, big toolbar, Up + address bar, optional
/// folder tree, the file list and a two-part status bar. It shows one location at a time - a folder on disk or a
/// folder inside an archive - and every command looks at which one it is.
/// </summary>
sealed class MainForm : Form
{
    /// <summary>A place to show: a folder (Inner null) or an archive plus the folder inside it ("" or "a/b/").</summary>
    sealed record Loc(string Path, string? Inner, string? Password = null, ParentArc[]? Parents = null);

    /// <summary>The archive a nested one was opened from (it lives in a temp file), to go back to on "..".</summary>
    sealed record ParentArc(string Source, string? Password, string Cur);

    /// <summary>One list row. Entry for archived files, Info for disk items, neither for archive folders and "..".</summary>
    sealed record Row(string Name, bool Folder, long Size, long Packed, DateTime Time, string Path = "",
                      ArchiveFileInfo? Entry = null, FileSystemInfo? Info = null, bool IsUp = false);

    enum Col { Name, Size, Packed, Type, Modified, Crc, Path }

    Archive? _a;
    string _cur = "";                       // folder inside the archive: "" or "sub/deeper/"
    string _dir;                            // the folder on disk; in an archive, the folder the (outermost) archive is in
    List<ParentArc> _parents = [];             // nested archives: the chain back to the one on disk
    long[]? _packed;                        // packed size by position in ArchiveFileData, read once per opened archive
    readonly List<Loc> _back = [], _fwd = [];
    Col[] _cols = [];
    bool _dragging;                         // our own drag-out is in flight: a drop back onto us is ignored
    bool _editing;                          // a label edit is open: its keys belong to the edit box
    bool _syncing;                          // the tree is being moved to match the list: its selection is not a click
    Func<bool>? _dropJob;                   // drag-out: extracts the dragged files at drop time; false = failed/cancelled
    DragDropEffects _feedback;              // drag-out: the effect the pointer's current target offers
    string _mask = "*.*";                   // last "select group" mask
    readonly ListView _list;
    readonly TreeView _tree;
    readonly SplitContainer _split;
    readonly ComboBox _address;
    readonly ToolStripStatusLabel _status, _drive, _lock;
    readonly ToolStripMenuItem _favorites, _mFlat, _mList, _mDetails, _mTree, _mReport;
    readonly List<(ToolStripItem Item, bool ArchiveOnly)> _buttons = [];
    readonly FileSystemWatcher _watch = new() { NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Size | NotifyFilters.LastWrite };
    readonly System.Windows.Forms.Timer _refresh = new() { Interval = 400 };
    readonly Comparer _sorter = new();

    bool InArchive => _a != null;
    /// <summary>Edits go to the archive file itself: not to a nested temp copy, not to formats we cannot rewrite.</summary>
    bool Editable => _a != null && _parents.Count == 0 && Engine.CanDelete(_a);

    public MainForm(string? archive)
    {
        Text = S.App;
        Size = new Size(1000, 640);
        MinimumSize = new Size(640, 400);
        Font = new Font("Segoe UI", 9.5f);
        AllowDrop = true;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { /* icon is optional */ }
        _dir = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

        // ---- menu (MAIN_MENU) ----
        var menu = new MenuStrip();
        ToolStripMenuItem Top(string text) { var m = new ToolStripMenuItem(text); menu.Items.Add(m); return m; }
        ToolStripMenuItem Item(ToolStripMenuItem parent, string text, Action click, Keys keys = Keys.None, string? display = null)
        {
            // List keys (Del, F2, Ctrl+C...) are display-only and go through ProcessCmdKey, which knows where the focus is.
            var m = new ToolStripMenuItem(text, null, (_, _) => click()) { ShortcutKeys = keys, ShortcutKeyDisplayString = display };
            parent.DropDownItems.Add(m);
            return m;
        }
        void Sep(ToolStripMenuItem parent) => parent.DropDownItems.Add(new ToolStripSeparator());

        var file = Top(S.MFile);
        Item(file, S.OpenArchive, DoOpen, Keys.Control | Keys.O);
        Item(file, S.NewArchive, () => DoNew(null), Keys.Control | Keys.N);
        Item(file, S.ChangeDrive, ChangeDrive, Keys.Control | Keys.D);
        Sep(file);
        Item(file, S.CopyFiles, CopyFiles, display: "Ctrl+C");
        Item(file, S.PasteFiles, PasteFiles, display: "Ctrl+V");
        Item(file, S.CopyNames, CopyNames);
        Sep(file);
        Item(file, S.SelectAllItems, SelectAll, display: "Ctrl+A");
        Item(file, S.SelectGroup, () => SelectGroup(true), display: "Num +");
        Item(file, S.DeselectGroup, () => SelectGroup(false), display: "Num −");
        Item(file, S.InvertSelection, Invert, display: "Num *");
        Sep(file);
        Item(file, S.Exit, Close);

        var cmd = Top(S.MCommands);
        Item(cmd, S.AddCmd, DoAdd, Keys.Alt | Keys.A);
        Item(cmd, S.ExtractTo, DoExtract, Keys.Alt | Keys.E);
        Item(cmd, S.TestCmd, DoTest, Keys.Alt | Keys.T);
        Sep(cmd);
        Item(cmd, S.ViewCmd, DoView, Keys.Alt | Keys.V);
        Item(cmd, S.DeleteCmd, () => DoDelete(false), display: "Del");
        Item(cmd, S.Rename, BeginRename, display: "F2");
        Sep(cmd);
        Item(cmd, S.ExtractNoAsk, DoExtractNoAsk, Keys.Alt | Keys.W);

        var tools = Top(S.MTools);
        Item(tools, S.ConvertMenu, DoConvert, Keys.Alt | Keys.Q);
        Sep(tools);
        Item(tools, S.FindCmd, DoFind, Keys.F3);
        Item(tools, S.InfoCmd, DoInfo, Keys.Alt | Keys.I);
        _mReport = Item(tools, S.ReportMenu, () => { });
        Item(_mReport, S.ReportHtml, () => SaveReport(html: true), Keys.Alt | Keys.G);
        Item(_mReport, S.ReportTxt, () => SaveReport(html: false));
        Item(_mReport, S.ReportCopy, CopyReport);

        _favorites = Top(S.MFavorites);

        var opt = Top(S.MOptions);
        Item(opt, S.SettingsMenu, () => SettingsForm.Edit(this), Keys.Control | Keys.S);
        Item(opt, S.Assoc, () => AssocForm.Edit(this));
        Sep(opt);
        var list = Item(opt, S.FileListMenu, () => { });
        _mFlat = Item(list, S.FlatView, ToggleFlat, Keys.Control | Keys.H);
        list.DropDownItems.Add(new ToolStripSeparator());
        _mList = Item(list, S.ListMode, () => SetListMode(true));
        _mDetails = Item(list, S.DetailsMode, () => SetListMode(false));
        _mTree = Item(opt, S.FolderTree, ToggleTree, Keys.Control | Keys.T);

        var help = Top(S.MHelp);
        Item(help, S.About, () => MessageBox.Show(this, $"{S.App} {Application.ProductVersion}\n\n{S.AboutText}", S.About,
                                                  MessageBoxButtons.OK, MessageBoxIcon.Information));

        // ---- toolbar: 32 px pictures with the label under them, a set per mode ----
        var bar = new ToolStrip
        {
            GripStyle = ToolStripGripStyle.Hidden,
            RenderMode = ToolStripRenderMode.System,
            Padding = new Padding(4, 2, 4, 2),
            ImageScalingSize = new Size(LogicalToDeviceUnits(32), LogicalToDeviceUnits(32)),
        };
        void Btn(string name, int siid, string text, string tip, Action click, bool archiveOnly = false)
        {
            var b = new ToolStripButton(text, Icons.Get(name, siid, LogicalToDeviceUnits(32)))
            {
                DisplayStyle = ToolStripItemDisplayStyle.ImageAndText,
                TextImageRelation = TextImageRelation.ImageAboveText,
                ToolTipText = tip,
                Padding = new Padding(4, 0, 4, 0),
            };
            b.Click += (_, _) => click();
            bar.Items.Add(b);
            _buttons.Add((b, archiveOnly));
        }
        Btn("add", 105, S.TbAdd, S.AddCmd + " (Alt+A)", DoAdd);
        Btn("extract", 45, S.TbExtract, S.ExtractTo + " (Alt+E)", DoExtract);
        Btn("test", 77, S.TbTest, S.TestCmd + " (Alt+T)", DoTest);
        Btn("view", 1, S.TbView, S.ViewCmd + " (Alt+V)", DoView);
        Btn("delete", 31, S.TbDelete, S.DeleteCmd + " (Del)", () => DoDelete(false));
        bar.Items.Add(new ToolStripSeparator());
        Btn("find", 22, S.TbFind, S.FindCmd + " (F3)", DoFind);
        Btn("info", 79, S.TbInfo, S.InfoCmd + " (Alt+I)", DoInfo);
        Btn("convert", 46, S.TbConvert, S.ConvertMenu + " (Alt+Q)", DoConvert);
        var report = new ToolStripDropDownButton(S.TbReport, Icons.Get("report", 39, LogicalToDeviceUnits(32)))
        {
            DisplayStyle = ToolStripItemDisplayStyle.ImageAndText,
            TextImageRelation = TextImageRelation.ImageAboveText,
            ToolTipText = S.ReportMenu,
            Padding = new Padding(4, 0, 4, 0),
        };
        report.DropDownItems.Add(S.ReportHtml, null, (_, _) => SaveReport(html: true));
        report.DropDownItems.Add(S.ReportTxt, null, (_, _) => SaveReport(html: false));
        report.DropDownItems.Add(S.ReportCopy, null, (_, _) => CopyReport());
        bar.Items.Add(report);
        _buttons.Add((report, true));

        // ---- Up + address bar ----
        var up = new Button { Dock = DockStyle.Left, Width = LogicalToDeviceUnits(30), FlatStyle = FlatStyle.Flat, Text = "↑" };
        up.FlatAppearance.BorderSize = 0;
        if (Icons.Get("up", -1, LogicalToDeviceUnits(16)) is { } upIcon) { up.Image = upIcon; up.Text = ""; }
        up.Click += (_, _) => Up();
        new ToolTip().SetToolTip(up, S.Up + " (Backspace)");
        _address = new ComboBox { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDown, IntegralHeight = false, MaxDropDownItems = 20 };
        _address.DropDown += (_, _) => FillAddressList();
        _address.SelectionChangeCommitted += (_, _) => { if (_address.SelectedItem is AddressItem i) BeginInvoke(() => Go(i.Loc)); };
        _address.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; GoTyped(_address.Text); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; UpdateAddress(); _list!.Focus(); }
        };
        var addressBar = new Panel { Dock = DockStyle.Top, Height = LogicalToDeviceUnits(28), Padding = new Padding(4, 2, 4, 2) };
        addressBar.Controls.AddRange([_address, up]);

        // ---- tree | list ----
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
            SmallImageList = ShellInfo.Images,
            ContextMenuStrip = ListMenu(),
        };
        _list.ItemActivate += (_, _) => OpenItem(_list.FocusedItem?.Tag as Row);
        _list.SelectedIndexChanged += (_, _) => UpdateStatus();
        _list.ColumnClick += (_, e) => SortBy(e.Column);
        _list.DragEnter += (_, e) => Dragging(e);
        _list.DragDrop += (_, e) => Dropped(e);
        _list.ItemDrag += (_, _) => DragOut();
        _list.BeforeLabelEdit += (_, e) =>
        {
            var row = (Row)_list.Items[e.Item].Tag!;
            e.CancelEdit = row.IsUp || (InArchive && !Editable);
            _editing = !e.CancelEdit;
        };
        _list.AfterLabelEdit += (_, e) =>
        {
            _editing = false;
            e.CancelEdit = true;                        // the list is refilled either way
            var old = _list.Items[e.Item].Text;
            var name = e.Label?.Trim();
            // After the event: an edit that rewrites the archive and refills the list must not run inside it.
            if (name != null && name != old) BeginInvoke(() => DoRename(old, name));
        };

        _tree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, ImageList = ShellInfo.Images, BorderStyle = BorderStyle.None };
        _tree.BeforeExpand += (_, e) => LoadChildren(e.Node!);
        _tree.AfterSelect += (_, e) => { if (!_syncing && e.Action != TreeViewAction.Unknown) TreeClicked(e.Node!); };
        _split = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1, SplitterWidth = 4 };
        _split.Panel1.Controls.Add(_tree);
        _split.Panel2.Controls.Add(_list);

        // ---- status bar: drive and lock pictures on the left, the totals on the right ----
        _drive = new ToolStripStatusLabel { Image = Icons.Get("drive", 8, 16), DisplayStyle = ToolStripItemDisplayStyle.Image };
        _lock = new ToolStripStatusLabel { Image = Icons.Get("lock", 47, 16), DisplayStyle = ToolStripItemDisplayStyle.Image, Visible = false };
        _status = new ToolStripStatusLabel { Spring = true, TextAlign = ContentAlignment.MiddleRight };
        var strip = new StatusStrip();
        strip.Items.AddRange([_drive, _lock, _status]);

        Controls.AddRange([_split, addressBar, bar, menu, strip]);
        MainMenuStrip = menu;

        _refresh.Tick += (_, _) => { _refresh.Stop(); if (!InArchive) Fill(keep: true); };
        _watch.SynchronizingObject = this;
        _watch.Changed += (_, _) => Poke();
        _watch.Created += (_, _) => Poke();
        _watch.Deleted += (_, _) => Poke();
        _watch.Renamed += (_, _) => Poke();

        RestoreLayout();
        RebuildFavorites();
        var start = Settings.Current.LastFolder is { } last && Directory.Exists(last) ? last : _dir;
        if (archive == null || !Go(new Loc(Path.GetFullPath(archive), Directory.Exists(archive) ? null : ""), record: false))
            Go(new Loc(archive != null ? Path.GetDirectoryName(Path.GetFullPath(archive)) ?? start : start, null), record: false);
    }

    // ---- locations -----------------------------------------------------------------------------

    Loc Here() => _a == null ? new Loc(_dir, null) : new Loc(_a.Source, _cur, _a.Password, [.. _parents]);

    static bool Same(Loc x, Loc y) => Engine.SamePath(x.Path, y.Path) && x.Inner == y.Inner;

    /// <summary>
    /// Shows <paramref name="to"/>: opens the archive when it is not the one already open (asking for its password),
    /// remembers where we were for Back. False when it could not be shown - nothing changed then.
    /// </summary>
    bool Go(Loc to, string? select = null, bool record = true)
    {
        var from = Here();
        if (to.Inner == null)
        {
            if (!Directory.Exists(to.Path))
            {
                if (File.Exists(to.Path)) return Go(to with { Inner = "" }, select, record);
                MessageBox.Show(this, string.Format(S.PathNotFoundFmt, to.Path), S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            _a?.Dispose();
            _a = null;
            _packed = null;
            _parents = [];
            _cur = "";
            _dir = Path.GetFullPath(to.Path);
        }
        else
        {
            if (_a == null || !Engine.SamePath(_a.Source, to.Path))
            {
                var a = to.Password != null ? TryOpen(to.Path, to.Password) : PasswordForm.OpenArchive(this, to.Path);
                if (a == null) return false;
                _a?.Dispose();
                _a = a;
                _parents = [.. to.Parents ?? []];
                _dir = Path.GetDirectoryName(_parents.Count > 0 ? _parents[0].Source : Path.GetFullPath(to.Path)) ?? _dir;
                _packed = Engine.PackedSizes(a);
            }
            var cur = to.Inner.Length == 0 || to.Inner.EndsWith('/') ? to.Inner : to.Inner + "/";
            // An edit (or a stale favorite) took the folder away: the nearest parent still there.
            while (cur.Length > 0 && !_a.X.ArchiveFileData.Any(f => (Engine.Norm(f.FileName) + "/").StartsWith(cur, StringComparison.OrdinalIgnoreCase)))
                cur = ParentOf(cur);
            _cur = cur;
        }
        if (record && !Same(from, Here())) { _back.Add(from); _fwd.Clear(); }
        Watch();
        Fill(select: select);
        return true;
    }

    Archive? TryOpen(string path, string? password)
    {
        try { return Engine.Open(path, password); }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.CannotOpen, MessageBoxButtons.OK, MessageBoxIcon.Error); return null; }
    }

    /// <summary>From Explorer (Program) and the Open dialog: a new place, Back returns to the old one. A folder works too.</summary>
    public bool OpenArchive(string path) => Go(new Loc(Path.GetFullPath(path), Directory.Exists(path) ? null : ""));

    /// <summary>"..": up a folder; from an archive's root to the folder (or the archive) it came from.</summary>
    internal void Up()
    {
        if (_a != null)
        {
            if (_cur.Length > 0) { Go(new Loc(_a.Source, ParentOf(_cur), _a.Password, [.. _parents]), LastSegment(_cur)); return; }
            var name = Path.GetFileName(_a.Source);
            if (_parents.Count > 0)
            {
                var p = _parents[^1];
                Go(new Loc(p.Source, p.Cur, p.Password, [.. _parents.Take(_parents.Count - 1)]), name);
            }
            else Go(new Loc(_dir, null), name);
            return;
        }
        if (Directory.GetParent(_dir) is { } parent) Go(new Loc(parent.FullName, null), Path.GetFileName(_dir));
    }

    void Root()
    {
        if (_a != null) Go(new Loc(_a.Source, "", _a.Password, [.. _parents]));
        else if (Path.GetPathRoot(_dir) is { Length: > 0 } root) Go(new Loc(root, null));
    }

    internal void Back() => Step(_back, _fwd);
    internal void Forward() => Step(_fwd, _back);

    void Step(List<Loc> from, List<Loc> to)
    {
        if (from.Count == 0) return;
        var here = Here();
        var loc = from[^1];
        from.RemoveAt(from.Count - 1);
        if (Go(loc, record: false)) to.Add(here);
    }

    /// <summary>A path typed into the address bar: a folder, an archive, or a folder inside one (C:\a.zip\sub).</summary>
    void GoTyped(string text)
    {
        var path = Environment.ExpandEnvironmentVariables(text.Trim().Trim('"'));
        if (path.Length == 0) return;
        try { path = Path.GetFullPath(path); } catch { path = ""; }
        if (Directory.Exists(path)) { if (Go(new Loc(path, null))) _list.Focus(); return; }
        for (var p = path; !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            if (File.Exists(p))
            {
                if (Go(new Loc(p, path[p.Length..].Trim('\\').Replace('\\', '/')))) _list.Focus();
                return;
            }
        MessageBox.Show(this, string.Format(S.PathNotFoundFmt, text), S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }

    /// <summary>"a/b/" -> "a/", "a/" -> "".</summary>
    static string ParentOf(string folder)
    {
        var slash = folder.TrimEnd('/').LastIndexOf('/');
        return slash < 0 ? "" : folder[..(slash + 1)];
    }

    static string LastSegment(string folder) => folder.TrimEnd('/') is var f && f.LastIndexOf('/') is var i && i >= 0 ? f[(i + 1)..] : f;

    // ---- listing -------------------------------------------------------------------------------

    /// <param name="keep">A refresh of the same place: keep the selection and the scroll position.</param>
    void Fill(bool keep = false, string? select = null)
    {
        var selected = keep ? _list.SelectedItems.Cast<ListViewItem>().Select(i => i.Text).ToHashSet(StringComparer.OrdinalIgnoreCase) : null;
        var top = keep && _list.Items.Count > 0 ? _list.TopItem?.Index ?? 0 : 0;
        _list.BeginUpdate();
        _list.ListViewItemSorter = null;     // sorting per Add would be quadratic
        _list.Items.Clear();
        var rows = _a != null ? ArchiveRows() : DiskRows();
        SetColumns(_a == null ? [Col.Name, Col.Size, Col.Type, Col.Modified]
                 : Settings.Current.FlatView ? [Col.Name, Col.Size, Col.Packed, Col.Type, Col.Modified, Col.Crc, Col.Path]
                 : [Col.Name, Col.Size, Col.Packed, Col.Type, Col.Modified, Col.Crc]);
        foreach (var r in rows) _list.Items.Add(ItemOf(r));
        _list.ListViewItemSorter = _sorter;
        _list.Sort();
        foreach (ListViewItem i in _list.Items)
            if (selected?.Contains(i.Text) == true || (select != null && i.Text.Equals(select, StringComparison.OrdinalIgnoreCase)))
            { i.Selected = true; if (select != null) { i.Focused = true; i.EnsureVisible(); } }
        _list.EndUpdate();
        if (keep && top < _list.Items.Count) try { _list.TopItem = _list.Items[top]; } catch { /* List view mode has no TopItem */ }
        if (_list.FocusedItem == null && _list.Items.Count > 0) _list.Items[0].Focused = true;
        UpdateUi();
    }

    List<Row> DiskRows()
    {
        var rows = new List<Row>();
        if (Directory.GetParent(_dir) != null) rows.Add(new Row("..", true, -1, -1, default, IsUp: true));
        try
        {
            foreach (var e in new DirectoryInfo(_dir).EnumerateFileSystemInfos())
                rows.Add(e is FileInfo f
                    ? new Row(f.Name, false, f.Length, -1, f.LastWriteTime, Info: f)
                    : new Row(e.Name, true, -1, -1, e.LastWriteTime, Info: e));
        }
        catch (Exception ex) { BeginInvoke(() => _status.Text = Engine.Friendly(ex)); }
        return rows;
    }

    List<Row> ArchiveRows()
    {
        var a = _a!;
        var rows = new List<Row> { new("..", true, -1, -1, default, IsUp: true) };
        var flat = Settings.Current.FlatView;
        var folders = new Dictionary<string, (long Size, long Packed, DateTime Time)>(StringComparer.OrdinalIgnoreCase);
        for (var at = 0; at < a.X.ArchiveFileData.Count; at++)
        {
            var f = a.X.ArchiveFileData[at];
            var n = Engine.Norm(f.FileName);
            if (n.Length == 0 || !n.StartsWith(_cur, StringComparison.OrdinalIgnoreCase)) continue;
            var rest = n[_cur.Length..];
            if (rest.Length == 0) continue;
            var packed = _packed?[at] ?? -1;
            var slash = rest.IndexOf('/');
            if (flat)
            {
                if (!f.IsDirectory) rows.Add(new Row(rest[(rest.LastIndexOf('/') + 1)..], false, (long)f.Size, packed, f.LastWriteTime,
                                                    slash < 0 ? "" : rest[..rest.LastIndexOf('/')].Replace('/', '\\'), Entry: f));
                continue;
            }
            if (slash >= 0 || f.IsDirectory)
            {
                var name = slash >= 0 ? rest[..slash] : rest;
                var agg = folders.GetValueOrDefault(name);
                if (!f.IsDirectory) agg = (agg.Size + (long)f.Size, agg.Packed + Math.Max(0, packed), agg.Time);
                if (slash < 0) agg.Time = f.LastWriteTime;          // the folder's own entry carries its time
                folders[name] = agg;
            }
            else rows.Add(new Row(rest, false, (long)f.Size, packed, f.LastWriteTime, Entry: f));
        }
        foreach (var (name, agg) in folders) rows.Add(new Row(name, true, agg.Size, _packed == null ? -1 : agg.Packed, agg.Time));
        return rows;
    }

    ListViewItem ItemOf(Row r)
    {
        var (image, type) = r.IsUp ? ShellInfo.Of("..", true) : ShellInfo.Of(r.Info?.FullName ?? r.Name, r.Folder, r.Info != null);
        var cells = _cols.Select(c => c switch
        {
            Col.Name => r.Name,
            Col.Size => r.Size < 0 ? "" : r.Size.ToString("#,0"),
            Col.Packed => r.Packed < 0 || r.IsUp ? "" : r.Packed.ToString("#,0"),
            Col.Type => type,
            Col.Modified => r.Time == default ? "" : r.Time.ToString("g"),
            Col.Crc => r.Entry is { Crc: not 0 } e ? e.Crc.ToString("X8") : "",
            Col.Path => r.Path,
            _ => "",
        }).ToArray();
        return new ListViewItem(cells, image) { Tag = r };
    }

    void SetColumns(Col[] cols)
    {
        if (cols.SequenceEqual(_cols)) return;
        _cols = cols;
        _list.Columns.Clear();
        foreach (var c in cols)
            _list.Columns.Add(c switch
            {
                Col.Name => S.Name, Col.Size => S.Size, Col.Packed => S.Packed, Col.Type => S.Type,
                Col.Modified => S.Modified, Col.Crc => S.Crc32, _ => S.PathColumn,
            }, LogicalToDeviceUnits(c switch { Col.Name => 300, Col.Type => 150, Col.Modified => 130, Col.Path => 220, _ => 95 }),
               c is Col.Size or Col.Packed ? HorizontalAlignment.Right : HorizontalAlignment.Left);
        _sorter.Cols = cols;
        if (_sorter.Column >= cols.Length) _sorter.Column = 0;
    }

    void SortBy(int column)
    {
        _sorter.Ascending = _sorter.Column != column || !_sorter.Ascending;
        _sorter.Column = column;
        _list.Sort();
    }

    void UpdateUi()
    {
        var archive = InArchive;
        Text = archive ? $"{_a!.Display} — {S.App}" : $"{_dir} — {S.App}";
        foreach (var (item, archiveOnly) in _buttons) item.Visible = !archiveOnly || archive;
        _mReport.Enabled = archive;
        _mFlat.Enabled = archive;
        _mFlat.Checked = Settings.Current.FlatView;
        _mList.Checked = _list.View == View.List;
        _mDetails.Checked = _list.View == View.Details;
        _mTree.Checked = !_split.Panel1Collapsed;
        _lock.Visible = archive && (_a!.Password != null || _a.X.ArchiveFileData.Any(f => f.Encrypted));
        _drive.ToolTipText = Path.GetPathRoot(_dir);
        UpdateAddress();
        UpdateStatus();
        SyncTree();
    }

    void UpdateAddress()
    {
        if (_a == null) { _address.Text = _dir; return; }
        var total = _a.X.ArchiveFileData.Where(f => !f.IsDirectory).Sum(f => (long)f.Size);
        var where = _a.Display + (_cur.Length > 0 ? "\\" + _cur.TrimEnd('/').Replace('/', '\\') : "");
        _address.Text = string.Format(S.ArchiveAddressFmt, where, FormatName(_a), S.Bytes(total));
    }

    static string FormatName(Archive a) => a.X.Format == InArchiveFormat.SevenZip ? "7z" : a.X.Format.ToString().ToUpperInvariant();

    /// <summary>status line: totals of the list, or of the selection when there is one.</summary>
    void UpdateStatus()
    {
        var sel = _list.SelectedItems.Count > 0;
        var rows = (sel ? _list.SelectedItems.Cast<ListViewItem>() : _list.Items.Cast<ListViewItem>()).Select(i => (Row)i.Tag!).Where(r => !r.IsUp).ToList();
        var folders = rows.Count(r => r.Folder);
        var files = rows.Count - folders;
        var bytes = rows.Sum(r => Math.Max(0, r.Size));
        var parts = new List<string>();
        if (folders > 0) parts.Add(S.FoldersN(folders));
        if (files > 0 || folders == 0) parts.Add(S.FilesN(files));
        if (bytes > 0 || files > 0) parts.Add(S.Bytes(bytes));
        _status.Text = string.Format(sel ? S.ChosenFmt : S.TotalFmt, string.Join(", ", parts));
    }

    // ---- folder tree ---------------------------------------------------------------------------

    void ToggleTree()
    {
        _split.Panel1Collapsed = !_split.Panel1Collapsed;
        Settings.Update(s => s.Tree = !_split.Panel1Collapsed);
        if (!_split.Panel1Collapsed) { _tree.Nodes.Clear(); SyncTree(); }
        UpdateUi();
    }

    /// <summary>Moves the tree's selection to the current place, building what is needed on the way.</summary>
    void SyncTree()
    {
        if (_split.Panel1Collapsed) return;
        _syncing = true;
        _tree.BeginUpdate();
        try
        {
            if (_a != null)
            {
                // The archive's own folders: rebuilt when the archive changes (Tag of the root = that Archive).
                if (_tree.Nodes.Count != 1 || !ReferenceEquals(_tree.Nodes[0].Tag, _a))
                {
                    _tree.Nodes.Clear();
                    var root = new TreeNode(_a.Display, ShellInfo.Of(_a.Source, false, true).Image, ShellInfo.Of(_a.Source, false, true).Image) { Tag = _a, Name = "" };
                    _tree.Nodes.Add(root);
                    var folder = ShellInfo.Of("", true).Image;
                    foreach (var path in ArchiveFolders(_a).Order(StringComparer.OrdinalIgnoreCase))
                    {
                        var parent = path.LastIndexOf('/', path.Length - 2) is var i && i >= 0 ? Find(root, path[..(i + 1)]) : root;
                        (parent ?? root).Nodes.Add(new TreeNode(LastSegment(path), folder, folder) { Name = path });
                    }
                    root.Expand();
                }
                _tree.SelectedNode = Find(_tree.Nodes[0], _cur) ?? _tree.Nodes[0];
            }
            else
            {
                if (_tree.Nodes.Count == 0 || _tree.Nodes[0].Tag is Archive)
                {
                    _tree.Nodes.Clear();
                    foreach (var d in DriveInfo.GetDrives())
                    {
                        var n = new TreeNode(ShellInfo.DriveName(d.Name), ShellInfo.Drive(d.Name), ShellInfo.Drive(d.Name)) { Tag = d.Name };
                        n.Nodes.Add(new TreeNode("…"));       // expandable until it is opened
                        _tree.Nodes.Add(n);
                    }
                }
                var node = _tree.Nodes.Cast<TreeNode>().FirstOrDefault(n => Engine.SamePath((string)n.Tag!, Path.GetPathRoot(_dir) ?? ""));
                if (node != null)
                    foreach (var part in _dir[Path.GetPathRoot(_dir)!.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
                    {
                        node.Expand();
                        var next = node.Nodes.Cast<TreeNode>().FirstOrDefault(n => n.Text.Equals(part, StringComparison.OrdinalIgnoreCase));
                        if (next == null) break;
                        node = next;
                    }
                _tree.SelectedNode = node;
            }
            _tree.SelectedNode?.EnsureVisible();
        }
        finally { _tree.EndUpdate(); _syncing = false; }

        static TreeNode? Find(TreeNode root, string path) => path.Length == 0 ? root : root.Nodes.Find(path, true).FirstOrDefault();
    }

    /// <summary>Every folder of the archive as "a/", "a/b/" - also the ones only implied by file paths.</summary>
    static HashSet<string> ArchiveFolders(Archive a)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in a.X.ArchiveFileData)
        {
            var n = Engine.Norm(f.FileName);
            var end = f.IsDirectory ? n.Length : n.LastIndexOf('/');
            for (var i = n.IndexOf('/'); i >= 0 && i < end; i = n.IndexOf('/', i + 1)) set.Add(n[..(i + 1)]);
            if (f.IsDirectory && n.Length > 0) set.Add(n + "/");
        }
        return set;
    }

    void LoadChildren(TreeNode node)
    {
        if (node.Nodes.Count != 1 || node.Nodes[0].Tag != null || node.Tag is not string path) return;   // loaded, or an archive node
        node.Nodes.Clear();
        var folder = ShellInfo.Of("", true).Image;
        try
        {
            foreach (var d in new DirectoryInfo(path).EnumerateDirectories().OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase))
            {
                var n = new TreeNode(d.Name, folder, folder) { Tag = d.FullName };
                n.Nodes.Add(new TreeNode("…"));
                node.Nodes.Add(n);
            }
        }
        catch { /* no access: a leaf */ }
    }

    void TreeClicked(TreeNode node)
    {
        if (node.Tag is string path) Go(new Loc(path, null));
        else if (_a != null) Go(new Loc(_a.Source, node.Name, _a.Password, [.. _parents]));
    }

    // ---- address bar ---------------------------------------------------------------------------

    sealed record AddressItem(string Text, Loc Loc) { public override string ToString() => Text; }

    /// <summary>The drop-down: drives, then the places visited (most recent first).</summary>
    void FillAddressList()
    {
        _address.Items.Clear();
        foreach (var d in DriveInfo.GetDrives()) _address.Items.Add(new AddressItem(ShellInfo.DriveName(d.Name), new Loc(d.Name, null)));
        foreach (var l in _back.AsEnumerable().Reverse().DistinctBy(l => (l.Path.ToUpperInvariant(), l.Inner)).Take(15))
            _address.Items.Add(new AddressItem(l.Inner == null ? l.Path : l.Path + (l.Inner.Length > 0 ? "\\" + l.Inner.TrimEnd('/').Replace('/', '\\') : ""), l));
    }

    void ChangeDrive()
    {
        _address.Focus();
        _address.DroppedDown = true;
    }

    // ---- opening items -------------------------------------------------------------------------

    /// <summary>Enter / double click: into a folder or an archive, anything else opens in its own app.</summary>
    void OpenItem(Row? row, bool asArchive = false)
    {
        if (row == null) return;
        if (row.IsUp) { Up(); return; }
        if (_a == null)
        {
            var path = row.Info!.FullName;
            if (row.Folder) Go(new Loc(path, null));
            else if (asArchive || IsArchiveFile(path)) Go(new Loc(path, ""));
            else Shell(path);
            return;
        }
        if (row.Entry == null) { Go(new Loc(_a.Source, _cur + row.Name + "/", _a.Password, [.. _parents])); return; }
        if (ToTemp(row.Entry.Value) is not { } file) return;
        if (asArchive || IsArchiveFile(file)) OpenNested(file);
        else Shell(file);
    }

    /// <summary>What OtherArc would open inside itself: one of our archive types that really is an archive (not a .docx).</summary>
    static bool IsArchiveFile(string path) =>
        Assoc.All.Contains(Path.GetExtension(path).TrimStart('.'), StringComparer.OrdinalIgnoreCase) && Engine.LooksLikeArchive(path);

    void OpenNested(string file) =>
        Go(new Loc(file, "", null, [.. _parents, new ParentArc(_a!.Source, _a.Password, _cur)]));

    void Shell(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    /// <summary>One archived file extracted to a fresh temp folder (it lives until MakePack exits); null = failed.</summary>
    string? ToTemp(ArchiveFileInfo f)
    {
        var a = Ready();
        if (a == null) return null;
        var dir = Engine.NewTempDir();
        using var progress = new ProgressForm(S.Extracting);
        if (!progress.Run(this, (p, ct) => Engine.Extract(a, dir, [f.Index], OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite))) return null;
        var file = Path.Combine(dir, Engine.Norm(f.FileName).Replace('/', '\\'));
        return File.Exists(file) ? file : null;
    }

    /// <summary>The open archive with its bodies' password in hand (asked for when needed); null = cancelled.</summary>
    Archive? Ready()
    {
        if (_a == null) return null;
        var ready = PasswordForm.EnsurePassword(this, _a);
        if (ready == null) return null;
        if (!ReferenceEquals(ready, _a)) { _a.Dispose(); _a = ready; }
        return _a;
    }

    // ---- selection -----------------------------------------------------------------------------

    List<Row> SelectedRows() => _list.SelectedItems.Cast<ListViewItem>().Select(i => (Row)i.Tag!).Where(r => !r.IsUp).ToList();

    /// <summary>Disk mode: full paths of the selection.</summary>
    List<string> SelectedPaths() => SelectedRows().Select(r => r.Info!.FullName).ToList();

    /// <summary>Archive mode: entry indices to act on; null when nothing is selected (= the whole archive).</summary>
    int[]? Selected()
    {
        if (_a == null) return null;
        var rows = SelectedRows();
        if (rows.Count == 0) return null;
        var set = new HashSet<int>();
        var folders = new List<string>();
        foreach (var r in rows)
            if (r.Entry is { } e) set.Add(e.Index);
            else folders.Add(_cur + r.Name + "/");
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

    void SelectAll()
    {
        _list.BeginUpdate();
        foreach (ListViewItem i in _list.Items) i.Selected = !((Row)i.Tag!).IsUp;
        _list.EndUpdate();
    }

    void Invert()
    {
        _list.BeginUpdate();
        foreach (ListViewItem i in _list.Items) i.Selected = !i.Selected && !((Row)i.Tag!).IsUp;
        _list.EndUpdate();
    }

    /// <summary>Num+ / Num-: (de)select the items whose name matches a mask, like the classic Select group.</summary>
    void SelectGroup(bool select)
    {
        var mask = NameForm.Line(this, select ? S.SelectGroup.TrimEnd('…') : S.DeselectGroup.TrimEnd('…'), S.MaskPrompt, _mask);
        if (string.IsNullOrWhiteSpace(mask)) return;
        _mask = mask;
        _list.BeginUpdate();
        foreach (ListViewItem i in _list.Items)
            if (!((Row)i.Tag!).IsUp && MakePack.FindForm.Matches(i.Text, mask)) i.Selected = select;
        _list.EndUpdate();
        _list.Focus();
    }

    internal void ToggleFlat()
    {
        if (_a == null) return;
        Settings.Update(s => s.FlatView = !s.FlatView);
        Fill();
    }

    void SetListMode(bool list)
    {
        _list.View = list ? View.List : View.Details;
        Settings.Update(s => s.ListMode = list);
        UpdateUi();
    }

    // ---- commands ------------------------------------------------------------------------------

    void DoOpen()
    {
        using var d = new OpenFileDialog
        {
            Title = S.Open.TrimEnd('…'),
            InitialDirectory = _dir,
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

    /// <summary>Alt+A. On disk: the selection goes to the New archive dialog. In an archive: files are added to it.</summary>
    void DoAdd()
    {
        if (_a != null) { DoAddFiles(); return; }
        var paths = SelectedPaths();
        if (paths.Count == 0) { Say(S.NothingSelected); return; }
        Program.Run(["a", .. paths]);
    }

    /// <summary>The selected archives on disk; a message (and an empty list) when there are none.</summary>
    List<string> SelectedArchives()
    {
        var files = SelectedRows().Where(r => !r.Folder).Select(r => r.Info!.FullName).ToList();
        if (files.Count == 0) Say(SelectedRows().Count == 0 ? S.NothingSelected : S.NoArchivesSelected);
        return files;
    }

    void DoExtract()
    {
        if (_a == null) { foreach (var p in SelectedArchives()) Program.Run(["x", p]); return; }   // the queue says n/N
        var indices = Selected();
        var a = Ready();
        if (a == null) return;
        var choice = ExtractForm.Ask(this, a);
        if (choice == null) return;

        using var progress = new ProgressForm(S.Extracting);
        var ok = progress.Run(this, (p, ct) => Engine.Extract(a, choice.Dest, indices, choice.Mode, p, ct,
                                                              ExtractForm.Conflicts(progress), options: choice.Options));
        // Only the whole archive on disk, extracted without an error, is ever offered for deletion.
        if (ok && indices == null && _parents.Count == 0) ExtractForm.AfterExtract(this, a.Source, choice.Delete, () => Go(new Loc(_dir, null)));
    }

    /// <summary>Alt+W: into a folder named after the archive, next to it, no dialog.</summary>
    void DoExtractNoAsk()
    {
        if (_a == null) { foreach (var p in SelectedArchives()) Program.Run(["x", p, "--sub"]); return; }
        var indices = Selected();
        var a = Ready();
        if (a == null) return;
        var dest = Path.Combine(_dir, Engine.BaseName(a.Display));
        using var progress = new ProgressForm(S.Extracting);
        progress.Run(this, (p, ct) => Engine.Extract(a, dest, indices, OverwriteMode.Ask, p, ct, ExtractForm.Conflicts(progress)));
    }

    void DoTest()
    {
        if (_a != null) { TestOne(_a); return; }
        var files = SelectedArchives();
        if (files.Count == 1)
        {
            using var a = PasswordForm.OpenArchive(this, files[0]);
            if (a != null) TestOne(a);
            return;
        }
        var good = 0;
        foreach (var f in files)
        {
            using var a = PasswordForm.OpenArchive(this, f);
            if (a == null) continue;
            var ok = false;
            using var progress = new ProgressForm(S.Testing + ": " + a.Display);
            if (!progress.Run(this, async (p, ct) => { ok = await Engine.Test(a, p, ct); })) break;
            if (ok) good++;
        }
        if (files.Count > 0)
            MessageBox.Show(this, string.Format(S.TestSummaryFmt, files.Count, good), S.App, MessageBoxButtons.OK,
                            good == files.Count ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
    }

    void TestOne(Archive a)
    {
        var ok = false;
        using var progress = new ProgressForm(S.Testing);
        if (!progress.Run(this, async (p, ct) => { ok = await Engine.Test(a, p, ct); })) return;
        MessageBox.Show(this, ok ? S.TestOk : S.TestFailed, S.App, MessageBoxButtons.OK,
            ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
    }

    /// <summary>Alt+V: the internal viewer for a file; a folder is simply entered.</summary>
    void DoView()
    {
        // The one selected row; with several, the focused one among them.
        var rows = SelectedRows();
        var row = rows.Count == 1 ? rows[0] : _list.FocusedItem is { Selected: true, Tag: Row { IsUp: false } r } ? r : null;
        if (row == null) { Say(S.NothingSelected); return; }
        if (row.Folder) { OpenItem(row); return; }
        if (_a == null) ViewerForm.Open(this, row.Info!.FullName, row.Name);
        else if (ToTemp(row.Entry!.Value) is { } file) ViewerForm.Open(this, file, row.Name);
    }

    void DoDelete(bool nuke)
    {
        if (_a != null)
        {
            var indices = Selected();
            if (indices is not { Length: > 0 }) return;
            if (!Editable) { Say(S.NotSupported); return; }
            if (MessageBox.Show(this, S.ConfirmDelete, S.App, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            var count = SelectedRows().Count;
            var archive = Ready();                       // deleting from a solid encrypted block repacks it
            if (archive == null) return;
            Modify(S.Deleting, (_, _, _) => Engine.Delete(archive, indices), string.Format(S.DeletedFmt, count));
            return;
        }
        var paths = SelectedPaths();
        if (paths.Count == 0) return;
        var what = paths.Count == 1 ? $"«{Path.GetFileName(paths[0])}»" : string.Format(S.ItemsFmt, paths.Count);
        if (MessageBox.Show(this, string.Format(nuke ? S.ConfirmNukeFmt : S.ConfirmRecycleFmt, what), S.App, MessageBoxButtons.YesNo,
                            nuke ? MessageBoxIcon.Warning : MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        try
        {
            Engine.Recycle(paths, undo: !nuke);
        }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); }
        Fill(keep: true);
    }

    void DoInfo()
    {
        if (_a != null) { InfoForm.Show(this, _a); return; }
        var rows = SelectedRows();
        if (rows.Count == 1 && !rows[0].Folder && IsArchiveFile(rows[0].Info!.FullName))
        {
            using var a = PasswordForm.OpenArchive(this, rows[0].Info!.FullName);
            if (a != null) InfoForm.Show(this, a);
            return;
        }
        ShellInfo.Properties(rows.Count > 0 ? rows[0].Info!.FullName : _dir);
    }

    void DoFind() => MakePack.FindForm.Open(this, _a?.Source ?? _dir, Locate, ViewFound);

    /// <summary>Find → Locate: show the found file in this window, selected.</summary>
    void Locate(string path, string? inner)
    {
        if (inner == null) { if (Path.GetDirectoryName(path) is { } dir) Go(new Loc(dir, null), Path.GetFileName(path)); }
        else
        {
            var slash = inner.LastIndexOf('/');
            Go(new Loc(path, slash < 0 ? "" : inner[..(slash + 1)]), inner[(slash + 1)..]);
        }
        Activate();
    }

    void ViewFound(string path, string? inner)
    {
        if (inner == null) { ViewerForm.Open(this, path, Path.GetFileName(path)); return; }
        using var a = PasswordForm.OpenArchive(this, path);
        if (a == null) return;
        var match = a.X.ArchiveFileData.Where(e => Engine.Norm(e.FileName).Equals(inner, StringComparison.OrdinalIgnoreCase)).Take(1).ToList();
        if (match.Count == 0) return;
        var f = match[0];
        var dir = Engine.NewTempDir();
        using var progress = new ProgressForm(S.Extracting);
        if (!progress.Run(this, (p, ct) => Engine.Extract(a, dir, [f.Index], OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite))) return;
        var file = Path.Combine(dir, inner.Replace('/', '\\'));
        if (File.Exists(file)) ViewerForm.Open(this, file, Path.GetFileName(file));
    }

    /// <summary>The file list as HTML (opens in any browser) or text (UTF-8 with BOM, so Notepad shows Cyrillic right).</summary>
    void SaveReport(bool html)
    {
        if (_a == null) return;
        var ext = html ? ".html" : ".txt";
        using var d = new SaveFileDialog
        {
            FileName = Engine.BaseName(_a.Display) + S.ReportSuffix + ext,
            InitialDirectory = _dir,
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
        ToClipboard(Engine.Report(_a, html: false));
        _status.Text = S.ReportCopied;
    }

    /// <summary>Convert the selected archives (on disk) or the open one - closed while converting, reopened after.</summary>
    void DoConvert()
    {
        if (_a == null)
        {
            var files = SelectedRows().Where(r => !r.Folder).Select(r => r.Info!.FullName).ToList();
            using var f = new ConvertForm(files);
            f.ShowDialog(this);
            return;
        }
        if (_parents.Count > 0) { Say(S.NotSupported); return; }
        string? reopen = null;
        using (var f = new ConvertForm([_a.Source], () => { if (_a != null) { reopen = _a.Source; Go(new Loc(_dir, null), record: false); } }))
            f.ShowDialog(this);
        if (reopen != null && File.Exists(reopen)) Go(new Loc(reopen, ""), record: false);
    }

    /// <summary>Runs an edit that closes the archive (Engine.Edit) under a progress window, then reopens it in the same folder.</summary>
    void Modify(string title, Func<Control, IProgress<(int percent, string file)>, CancellationToken, Task> edit,
                string status, string? select = null)
    {
        var (source, password, cur) = (_a!.Source, _a.Password, _cur);
        _a = null;                                   // the edit closes it
        bool ok;
        using (var progress = new ProgressForm(title)) ok = progress.Run(this, (p, ct) => edit(progress, p, ct));
        if (!Go(new Loc(source, cur, password), ok ? select : null, record: false)) { Go(new Loc(_dir, null), record: false); return; }
        if (ok) _status.Text = status;
    }

    void DoAddFiles()
    {
        if (_a == null) return;
        using var d = new OpenFileDialog { Multiselect = true, Title = S.AddFilesToArchive.TrimEnd('…'), Filter = $"{S.AllFiles}|*.*" };
        // ponytail: files only here - folders come in by drag and drop or Ctrl+V (a folder picker is the upgrade path).
        if (d.ShowDialog(this) == DialogResult.OK) AddToArchive(d.FileNames);
    }

    void AddToArchive(string[] files)
    {
        if (_a == null || files.Length == 0) return;
        if (!Editable)
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
        if (_list.FocusedItem is { Selected: true, Tag: Row { IsUp: false } } item && (_a == null || Editable)) item.BeginEdit();
    }

    void DoRename(string old, string name)
    {
        if (name.Length == 0 || name is "." or ".." || name.IndexOfAny(['/', '\\', ':', '*', '?', '"', '<', '>', '|']) >= 0)
        { Say(S.BadName); return; }
        // Case-only renames pass: the sibling with that name is the item itself.
        if (_list.Items.Cast<ListViewItem>().Any(i => i.Text.Equals(name, StringComparison.OrdinalIgnoreCase)
                                                   && !i.Text.Equals(old, StringComparison.OrdinalIgnoreCase)))
        { Say(S.NameTaken); return; }
        if (_a == null)
        {
            try
            {
                var (from, to) = (Path.Combine(_dir, old), Path.Combine(_dir, name));
                if (Directory.Exists(from)) Directory.Move(from, to); else File.Move(from, to);
            }
            catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); }
            Fill(select: name);
            return;
        }
        var a = _a;
        var (src, dst) = (_cur + old, _cur + name);
        Modify(S.Renaming, (_, _, _) => Engine.Rename(a, src, dst), string.Format(S.RenamedFmt, name), name);
    }

    void NewFolder()
    {
        if (_a != null) return;
        var name = S.NewFolderName;
        for (var n = 2; Directory.Exists(Path.Combine(_dir, name)) || File.Exists(Path.Combine(_dir, name)); n++) name = $"{S.NewFolderName} ({n})";
        try { Directory.CreateDirectory(Path.Combine(_dir, name)); }
        catch (Exception ex) { MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        Fill(select: name);
        _list.Focus();
        _list.FocusedItem?.BeginEdit();
    }

    /// <summary>
    /// Clipboard.SetText gives up at once when another process holds the clipboard - rdpclip under Remote Desktop
    /// often does for a moment. A few retries ride that out instead of an exception.
    /// </summary>
    internal static void ToClipboard(object data)
    {
        try { Clipboard.SetDataObject(data, true, 30, 100); }
        catch (ExternalException) { /* still busy after 3 s: nothing copied, nothing lost */ }
    }

    void Say(string text) => MessageBox.Show(this, text, S.App, MessageBoxButtons.OK, MessageBoxIcon.Information);

    // ---- clipboard -----------------------------------------------------------------------------

    /// <summary>Ctrl+C: files Explorer can paste. From an archive they are extracted to temp first, as on drag-out.</summary>
    void CopyFiles()
    {
        List<string> paths;
        if (_a == null) paths = SelectedPaths();
        else
        {
            var indices = Selected();
            var a = Ready();
            if (indices is not { Length: > 0 } || a == null) return;
            var dir = Engine.NewTempDir();
            using var progress = new ProgressForm(S.Extracting);
            if (!progress.Run(this, (p, ct) => Engine.Extract(a, dir, indices, OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite))) return;
            // ponytail: the temp copy lives until MakePack exits; a paste after that finds nothing.
            paths = SelectedRows().Select(r => Path.Combine(dir, (_cur + (r.Path.Length > 0 ? r.Path + "\\" : "") + r.Name).Replace('/', '\\'))).ToList();
        }
        if (paths.Count == 0) return;
        var data = new DataObject(DataFormats.FileDrop, paths.ToArray());
        data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(1 /* DROPEFFECT_COPY */)));
        ToClipboard(data);
    }

    /// <summary>Ctrl+V: on disk a shell copy (or move, after a Cut in Explorer) into this folder; in an archive, Add.</summary>
    void PasteFiles()
    {
        var data = Clipboard.GetDataObject();
        if (data?.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
        if (_a != null) { AddToArchive(files); return; }
        var move = data.GetData("Preferred DropEffect") is MemoryStream ms && ms.Length >= 4 && (BitConverter.ToInt32(ms.ToArray(), 0) & 2) != 0;
        ShellInfo.Copy(this, files, _dir, move);
        Fill(keep: true);
    }

    void CopyNames()
    {
        var rows = SelectedRows();
        if (rows.Count == 0) return;
        ToClipboard(string.Join(Environment.NewLine, rows.Select(r => _a == null
            ? r.Info!.FullName
            : _a.Source + "\\" + (_cur + (r.Path.Length > 0 ? r.Path + "\\" : "") + r.Name).Replace('/', '\\'))));
    }

    // ---- favorites -----------------------------------------------------------------------------

    void RebuildFavorites()
    {
        _favorites.DropDownItems.Clear();
        _favorites.DropDownItems.Add(new ToolStripMenuItem(S.AddFavorite, Icons.Get("favorite", 43, 16), (_, _) => AddFavorite()) { ShortcutKeys = Keys.Control | Keys.F });
        _favorites.DropDownItems.Add(new ToolStripMenuItem(S.OrganizeFavorites, null, (_, _) => { FavoritesForm.Edit(this); RebuildFavorites(); }));
        var favs = Settings.Current.Favorites;
        if (favs.Count > 0) _favorites.DropDownItems.Add(new ToolStripSeparator());
        for (var i = 0; i < favs.Count; i++)
        {
            var f = favs[i];
            var item = new ToolStripMenuItem(f.Name, null, (_, _) => Go(new Loc(f.Path, f.Inner)));
            if (i < 10) item.ShortcutKeys = Keys.Control | (Keys.D1 + (i == 9 ? -1 : i));   // Ctrl+1 ... Ctrl+9, Ctrl+0
            _favorites.DropDownItems.Add(item);
        }
    }

    void AddFavorite()
    {
        // A nested archive lives in a temp file: the favorite points at the archive on disk it came from.
        var (path, inner) = _a == null ? (_dir, (string?)null) : _parents.Count > 0 ? (_parents[0].Source, "") : (_a.Source, _cur);
        var name = NameForm.Line(this, S.AddFavorite.TrimEnd('…'), S.FavoritePrompt,
                                 _a != null ? _a.Display + (_cur.Length > 0 ? "\\" + _cur.TrimEnd('/').Replace('/', '\\') : "") : Path.GetFileName(_dir) is { Length: > 0 } n ? n : _dir);
        if (string.IsNullOrWhiteSpace(name)) return;
        Settings.Update(s => s.Favorites.Add(new Favorite { Name = name, Path = path, Inner = inner }));
        RebuildFavorites();
    }

    // ---- context menu --------------------------------------------------------------------------

    ContextMenuStrip ListMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Opening += (_, e) =>
        {
            menu.Items.Clear();
            var rows = SelectedRows();
            var one = rows.Count == 1 ? rows[0] : null;
            var archive = InArchive;
            ToolStripMenuItem Item(string text, Action click, string keys = "", bool enabled = true)
            {
                var m = new ToolStripMenuItem(text, null, (_, _) => click()) { ShortcutKeyDisplayString = keys, Enabled = enabled };
                menu.Items.Add(m);
                return m;
            }
            Item(S.OpenCmd, () => OpenItem(one), "Enter", one != null).Font = new Font(menu.Font, FontStyle.Bold);
            Item(S.ShowContents, () => OpenItem(one, asArchive: true), "Ctrl+PgDn", one is { Folder: false });
            Item(S.ViewCmd, DoView, "Alt+V", one is { Folder: false });
            menu.Items.Add(new ToolStripSeparator());
            Item(S.AddCmd, DoAdd, "Alt+A", archive || rows.Count > 0);
            Item(S.ExtractTo, DoExtract, "Alt+E", archive || rows.Any(r => !r.Folder));
            Item(S.TestCmd, DoTest, "Alt+T", archive || rows.Any(r => !r.Folder));
            menu.Items.Add(new ToolStripSeparator());
            Item(S.CopyFiles, CopyFiles, "Ctrl+C", rows.Count > 0);
            Item(S.PasteFiles, PasteFiles, "Ctrl+V", Clipboard.ContainsFileDropList() && (!archive || Editable));
            menu.Items.Add(new ToolStripSeparator());
            if (!archive) Item(S.NewFolder, NewFolder);
            Item(S.Rename, BeginRename, "F2", one != null && (!archive || Editable));
            Item(S.Delete, () => DoDelete(false), "Del", rows.Count > 0 && (!archive || Editable));
            menu.Items.Add(new ToolStripSeparator());
            var view = Item(S.ViewAs, () => { });
            view.DropDownItems.Add(new ToolStripMenuItem(S.ListMode, null, (_, _) => SetListMode(true)) { Checked = _list.View == View.List });
            view.DropDownItems.Add(new ToolStripMenuItem(S.DetailsMode, null, (_, _) => SetListMode(false)) { Checked = _list.View == View.Details });
            var sort = Item(S.SortBy, () => { });
            for (var c = 0; c < _list.Columns.Count; c++)
            {
                var col = c;
                sort.DropDownItems.Add(new ToolStripMenuItem(_list.Columns[c].Text, null, (_, _) => SortBy(col)) { Checked = _sorter.Column == c });
            }
            if (archive) Item(S.InfoCmd, DoInfo, "Alt+I");
            else Item(S.PropertiesCmd, DoInfo, "Alt+I");
            e.Cancel = false;
        };
        return menu;
    }

    // ---- input ---------------------------------------------------------------------------------

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_editing) return false;                  // a label edit owns every key: Back, Del, Ctrl+A belong to the edit box
        switch (keyData)                             // anywhere in the window
        {
            case Keys.Alt | Keys.Left: Back(); return true;
            case Keys.Alt | Keys.Right: Forward(); return true;
            case Keys.Alt | Keys.Up: Up(); return true;
            case Keys.Control | Keys.Oem5: Root(); return true;           // Ctrl+\
            case Keys.Control | Keys.E: DoExtract(); return true;         // MakePack's old key for Extract
        }
        if (_list.Focused || _tree.Focused)          // the list's keys; in the address bar they edit text
            switch (keyData)
            {
                case Keys.Back or Keys.Control | Keys.PageUp: Up(); return true;
                case Keys.Control | Keys.PageDown: OpenItem(_list.FocusedItem?.Tag as Row, asArchive: true); return true;
                case Keys.Delete: DoDelete(false); return true;
                case Keys.Shift | Keys.Delete: DoDelete(true); return true;
                case Keys.F2: BeginRename(); return true;
                case Keys.Control | Keys.A: SelectAll(); return true;
                case Keys.Control | Keys.C or Keys.Control | Keys.Insert: CopyFiles(); return true;
                case Keys.Control | Keys.V or Keys.Shift | Keys.Insert: PasteFiles(); return true;
                case Keys.Add: SelectGroup(true); return true;
                case Keys.Subtract: SelectGroup(false); return true;
                case Keys.Multiply: Invert(); return true;
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

    /// <summary>
    /// Drag the selection out to Explorer. Disk items go as they are. Archived ones the 7-Zip way: the drag carries
    /// temp-folder paths that do not exist yet, and the files are extracted there at drop time (OnQueryContinueDrag).
    /// Extracting first and dragging afterwards does not work: the progress window eats the press.
    /// </summary>
    // ponytail: a delayed-render IDataObject (CFSTR_FILEDESCRIPTOR/FILECONTENTS) is the upgrade path.
    // The temp copy lives until MakePack exits.
    void DragOut()
    {
        _dragging = true;
        try
        {
            if (_a == null)
            {
                var paths = SelectedPaths();
                if (paths.Count > 0) DoDragDrop(new DataObject(DataFormats.FileDrop, paths.ToArray()), DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link);
                Fill(keep: true);
                return;
            }
            var before = _a;
            var a = Ready();
            if (a == null || !ReferenceEquals(a, before)) return;   // a password prompt took the press: drag again
            var indices = Selected();
            if (indices is not { Length: > 0 }) return;
            var dir = Engine.NewTempDir();
            var temp = SelectedRows().Select(r => Path.Combine(dir, (_cur + (r.Path.Length > 0 ? r.Path + "\\" : "") + r.Name).Replace('/', '\\'))).ToArray();
            _dropJob = () =>
            {
                using var progress = new ProgressForm(S.Extracting);
                return progress.Run(this, (p, ct) => Engine.Extract(a, dir, indices, OverwriteMode.Overwrite, p, ct, _ => OverwriteMode.Overwrite));
            };
            _feedback = DragDropEffects.None;
            DoDragDrop(new DataObject(DataFormats.FileDrop, temp), DragDropEffects.Copy);
        }
        finally { _dragging = false; _dropJob = null; }
    }

    void Dragging(DragEventArgs e) => e.Effect = !_dragging && e.Data?.GetDataPresent(DataFormats.FileDrop) == true
        ? DragDropEffects.Copy : DragDropEffects.None;

    void Dropped(DragEventArgs e)
    {
        if (_dragging || e.Data?.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } files) return;
        // After the event: Explorer's drag waits for this handler, and the dialogs below are modal.
        // Into an open archive the files are added; on disk a dropped archive is opened and anything else
        // goes to the New archive dialog (drop = Add).
        BeginInvoke(() =>
        {
            if (_a != null) AddToArchive(files);
            else if (files.Length == 1 && File.Exists(files[0]) && Engine.LooksLikeArchive(files[0])) OpenArchive(files[0]);
            else DoNew(files);
        });
    }

    // ---- watching the folder -------------------------------------------------------------------

    /// <summary>On disk the list follows the folder (new archives, extracted files) like Explorer's does.</summary>
    void Watch()
    {
        try
        {
            _watch.EnableRaisingEvents = false;
            // Not before the window has a handle: its events are marshalled with BeginInvoke (OnShown starts it).
            if (_a != null || !IsHandleCreated) return;
            _watch.Path = _dir;
            _watch.EnableRaisingEvents = true;
        }
        catch { /* a drive that cannot be watched: refresh by navigating */ }
    }

    void Poke() { _refresh.Stop(); _refresh.Start(); }

    protected override void OnShown(EventArgs e) { base.OnShown(e); Watch(); }

    // ---- window state --------------------------------------------------------------------------

    void RestoreLayout()
    {
        var s = Settings.Current;
        if (s.Window is [var x, var y, var w, var h] && Screen.AllScreens.Any(sc => sc.WorkingArea.IntersectsWith(new Rectangle(x, y, w, h))))
        {
            StartPosition = FormStartPosition.Manual;
            Bounds = new Rectangle(x, y, Math.Max(w, MinimumSize.Width), Math.Max(h, MinimumSize.Height));
        }
        if (s.Maximized) WindowState = FormWindowState.Maximized;
        _split.Panel1Collapsed = !s.Tree;
        _split.SplitterDistance = LogicalToDeviceUnits(240);
        _list.View = s.ListMode ? View.List : View.Details;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        var b = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
        Settings.Update(s =>
        {
            s.Window = [b.X, b.Y, b.Width, b.Height];
            s.Maximized = WindowState == FormWindowState.Maximized;
            s.LastFolder = _dir;
        });
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e) { _watch.Dispose(); _a?.Dispose(); base.OnFormClosed(e); }

    // ---- what the selftest reads and does (it drives a window that is never shown) ------------

    internal string[] Names => _list.Items.Cast<ListViewItem>().Select(i => i.Text).ToArray();
    internal string CellOf(string name, int column) => _list.Items.Cast<ListViewItem>().First(i => i.Text == name).SubItems[column].Text;
    // From the items: SelectedItems stays empty while the list has no window handle (never shown).
    internal string? Chosen => _list.Items.Cast<ListViewItem>().Where(i => i.Selected).Select(i => i.Text).SingleOrDefault();
    internal string StatusText => _status.Text ?? "";
    internal string AddressText => _address.Text;
    internal void Open(string name) => OpenItem(_list.Items.Cast<ListViewItem>().Select(i => (Row)i.Tag!).First(r => r.Name == name));

    // ---- sorting -------------------------------------------------------------------------------

    sealed class Comparer : IComparer
    {
        public int Column;
        public bool Ascending = true;
        public Col[] Cols = [];

        public int Compare(object? a, object? b)
        {
            var x = (Row)((ListViewItem)a!).Tag!;
            var y = (Row)((ListViewItem)b!).Tag!;
            if (x.IsUp != y.IsUp) return x.IsUp ? -1 : 1;              // ".." always on top
            if (x.Folder != y.Folder) return x.Folder ? -1 : 1;        // folders always first
            var col = Column < Cols.Length ? Cols[Column] : Col.Name;
            var r = col switch
            {
                Col.Size => x.Size.CompareTo(y.Size),
                Col.Packed => x.Packed.CompareTo(y.Packed),
                Col.Modified => x.Time.CompareTo(y.Time),
                _ => string.Compare(((ListViewItem)a).SubItems[Column].Text, ((ListViewItem)b).SubItems[Column].Text, StringComparison.CurrentCultureIgnoreCase),
            };
            if (r == 0 && col != Col.Name) r = string.Compare(x.Name, y.Name, StringComparison.CurrentCultureIgnoreCase);
            return Ascending ? r : -r;
        }
    }
}
