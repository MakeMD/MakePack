namespace MakePack;

/// <summary>Checkbox-per-extension association editor, 7-Zip Options-&gt;System style. Writes HKCU itself.</summary>
sealed class AssocForm : Form
{
    readonly ListView _list;
    readonly Dictionary<MenuItems, CheckBox> _items = [];
    readonly ComboBox _quick;

    AssocForm()
    {
        Text = S.AssocTitle;
        Font = new Font("Segoe UI", 9.5f);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        ClientSize = new Size(520, 664);
        MinimumSize = new Size(500, 520);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { /* icon is optional */ }

        _list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            CheckBoxes = true,
            FullRowSelect = true,
            HideSelection = false,
            UseCompatibleStateImageBehavior = false,
        };
        _list.Columns.Add(S.Extension, 140);
        _list.Columns.Add(S.CurrentApp, 330);
        foreach (var ext in Assoc.All)
        {
            var o = Assoc.Owner(ext);
            var ours = o.ProgId == Assoc.ProgId;
            var owner = ours ? S.App : o.ProgId ?? "";
            if (o.Dead) owner += S.DeadSuffix;
            if (o.UserChoice) owner += S.UserChoiceSuffix;
            _list.Items.Add(new ListViewItem(["." + ext, owner]) { Tag = ext }).Checked = ours;
        }

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 38, Padding = new Padding(8, 6, 8, 2) };
        void Pick(string text, Func<string, bool> want)
        {
            var b = new Button { Text = text, Width = 92, Height = 26, FlatStyle = FlatStyle.System };
            b.Click += (_, _) => { foreach (ListViewItem i in _list.Items) i.Checked = want((string)i.Tag!); };
            buttons.Controls.Add(b);
        }
        Pick(S.SelectAll, _ => true);
        Pick(S.SelectDefaults, ext =>
        {
            var o = Assoc.Owner(ext);
            return Assoc.Defaults.Contains(ext) || o.ProgId == Assoc.ProgId || o.Dead || string.IsNullOrEmpty(o.ProgId);
        });
        Pick(S.SelectNone, _ => false);

        // Which Explorer menu items exist at all (classic menu and the Windows 11 one), "Context menu items".
        var menu = new Panel { Dock = DockStyle.Bottom, Height = 156 };
        menu.Controls.Add(new Label { Left = 8, Top = 6, Width = 500, Text = S.MenuItemsLabel });
        var current = Assoc.Menu;
        void Item(MenuItems item, string text, int col, int row)
        {
            var c = new CheckBox { Left = 8 + col * 252, Top = 28 + row * 24, Width = 248, Text = text, Checked = current.HasFlag(item) };
            _items[item] = c;
            menu.Controls.Add(c);
        }
        Item(MenuItems.Open, S.VerbOpenWith, 0, 0);
        Item(MenuItems.ExtractHere, S.VerbExtractHere, 0, 1);
        Item(MenuItems.ExtractTo, S.VerbExtractTo, 0, 2);
        Item(MenuItems.Add, S.VerbAddTo, 1, 0);
        Item(MenuItems.QuickAdd, S.MenuQuickAdd, 1, 1);
        Item(MenuItems.New, S.MenuNewArchive, 1, 2);
        Item(MenuItems.Profiles, S.MenuProfiles, 1, 3);
        menu.Controls.Add(new Label { Left = 8, Top = 130, Width = 244, Text = S.QuickFormat });
        _quick = new ComboBox { Left = 260, Top = 126, Width = 120, DropDownStyle = ComboBoxStyle.DropDownList, DisplayMember = nameof(KindInfo.Name) };
        _quick.Items.AddRange([.. Engine.Kinds.Where(k => k.Multi)]);
        _quick.SelectedItem = Engine.Kind(Assoc.QuickKind);
        menu.Controls.Add(_quick);
        var note = new Label { Dock = DockStyle.Bottom, Height = 66, Text = S.AssocNote, Padding = new Padding(8, 4, 8, 4) };

        var ok = new Button { Text = S.Ok, Width = 94, Height = 28, DialogResult = DialogResult.OK, FlatStyle = FlatStyle.System };
        var cancel = new Button { Text = S.Cancel, Width = 94, Height = 28, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };
        var bottom = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8, 6, 8, 6),
        };
        bottom.Controls.AddRange([cancel, ok]);

        // Dock order is by z-order from the back: last added is placed first.
        Controls.AddRange([_list, buttons, menu, note, bottom]);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    void Apply()
    {
        Assoc.Blocked.Clear();
        // Ticking a box that is already ours writes nothing, so a ProgID that went missing under us
        // would stay missing: put it back first.
        if (_list.Items.Cast<ListViewItem>().Any(i => i.Checked)) try { Assoc.Heal(); } catch { /* registry */ }
        foreach (ListViewItem i in _list.Items)
        {
            var ext = (string)i.Tag!;
            if (i.Checked) { if (!Assoc.IsOurs(ext)) Assoc.Register(ext, true); }
            else if (Assoc.IsOurs(ext)) Assoc.Unregister(ext);
        }
        Assoc.Menu = _items.Where(i => i.Value.Checked).Aggregate(MenuItems.None, (m, i) => m | i.Key);
        if (_quick.SelectedItem is KindInfo k) Assoc.QuickKind = k.Kind;
        Assoc.ApplyMenu();
        Assoc.Notify();
    }

    public static void Edit(IWin32Window? owner)
    {
        using var f = new AssocForm();
        if ((owner == null ? f.ShowDialog() : f.ShowDialog(owner)) != DialogResult.OK) return;
        f.Apply();
        if (Assoc.Blocked.Count > 0)
            MessageBox.Show(owner, string.Format(S.BlockedFmt, string.Join(", ", Assoc.Blocked.Select(e => "." + e))),
                S.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
}
