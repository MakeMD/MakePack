namespace MakePack;

/// <summary>Favorites → Organize: reorder, rename, remove. Saved only on OK.</summary>
sealed class FavoritesForm : Form
{
    readonly List<Favorite> _items;
    readonly ListBox _list;

    FavoritesForm(List<Favorite> items)
    {
        _items = items;
        Text = S.OrganizeFavorites.TrimEnd('…');
        Font = new Font("Segoe UI", 9.5f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        ClientSize = new Size(520, 300);

        _list = new ListBox { Left = 12, Top = 12, Width = 380, Height = 276, IntegralHeight = false };
        Button Btn(string text, int top, Action click)
        {
            var b = new Button { Left = 404, Top = top, Width = 104, Height = 28, Text = text, FlatStyle = FlatStyle.System };
            b.Click += (_, _) => click();
            Controls.Add(b);
            return b;
        }
        Btn(S.MoveUp, 12, () => MoveItem(-1));
        Btn(S.MoveDown, 44, () => MoveItem(1));
        Btn(S.RenameButton, 84, Rename);
        Btn(S.Remove, 116, () => { if (_list.SelectedIndex is var i and >= 0) { _items.RemoveAt(i); Fill(Math.Min(i, _items.Count - 1)); } });
        var ok = Btn(S.Ok, 224, () => { });
        ok.DialogResult = DialogResult.OK;
        var cancel = Btn(S.Cancel, 260, () => { });
        cancel.DialogResult = DialogResult.Cancel;
        AcceptButton = ok;
        CancelButton = cancel;
        Controls.Add(_list);
        Fill(0);
    }

    void Fill(int select)
    {
        _list.Items.Clear();
        foreach (var f in _items) _list.Items.Add($"{f.Name}   —   {f.Path}{(string.IsNullOrEmpty(f.Inner) ? "" : "\\" + f.Inner.Replace('/', '\\'))}");
        if (select >= 0 && select < _items.Count) _list.SelectedIndex = select;
    }

    void MoveItem(int by)
    {
        var i = _list.SelectedIndex;
        if (i < 0 || i + by < 0 || i + by >= _items.Count) return;
        (_items[i], _items[i + by]) = (_items[i + by], _items[i]);
        Fill(i + by);
    }

    void Rename()
    {
        var i = _list.SelectedIndex;
        if (i < 0) return;
        if (NameForm.Line(this, S.RenameButton.TrimEnd('…'), S.FavoritePrompt, _items[i].Name) is { Length: > 0 } name)
        { _items[i].Name = name; Fill(i); }
    }

    public static void Edit(IWin32Window owner)
    {
        using var f = new FavoritesForm(Settings.Current.Favorites.Select(x => new Favorite { Name = x.Name, Path = x.Path, Inner = x.Inner }).ToList());
        if (f.ShowDialog(owner) == DialogResult.OK) Settings.Update(s => s.Favorites = f._items);
    }
}
