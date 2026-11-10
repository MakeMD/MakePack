namespace MakePack;

/// <summary>Options that are not remembered on their own from the last use. Grows with each settings ticket.</summary>
sealed class SettingsForm : Form
{
    readonly TextBox _folder;
    readonly ListBox _profiles;
    readonly ComboBox _motw;
    // Edited on a copy and written back on OK, like the folder: Cancel leaves the profiles as they were.
    readonly List<Profile> _list = [.. Settings.Current.Profiles.Select(p => p.Copy())];

    SettingsForm()
    {
        Text = S.SettingsTitle;
        Font = new Font("Segoe UI", 9.5f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        ClientSize = new Size(520, 362);

        var lbl = new Label { Left = 12, Top = 14, Width = 496, Text = S.ArchiveFolder };
        _folder = new TextBox { Left = 12, Top = 38, Width = 390, Text = Settings.Current.ArchiveFolder ?? "", PlaceholderText = S.NextToFiles };
        var browse = new Button { Left = 410, Top = 37, Width = 98, Height = 27, Text = S.Browse, FlatStyle = FlatStyle.System };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { Description = S.ArchiveFolder, UseDescriptionForTitle = true, SelectedPath = _folder.Text };
            if (d.ShowDialog(this) == DialogResult.OK) _folder.Text = d.SelectedPath;
        };
        var note = new Label { Left = 12, Top = 70, Width = 496, Height = 36, Text = S.ArchiveFolderNote, ForeColor = SystemColors.GrayText };

        // What extracted files inherit from a downloaded archive (Windows' "this came from the Internet" mark).
        var lblMotw = new Label { Left = 12, Top = 114, Width = 200, Text = S.MotwLabel };
        _motw = new ComboBox { Left = 214, Top = 110, Width = 294, DropDownStyle = ComboBoxStyle.DropDownList };
        _motw.Items.AddRange([S.MotwNever, S.MotwRisky, S.MotwAll]);   // in MotwPolicy order
        _motw.SelectedIndex = (int)Settings.Current.Motw;
        new ToolTip().SetToolTip(_motw, S.MotwTip);

        var lblProfiles = new Label { Left = 12, Top = 150, Width = 390, Text = S.Profiles };
        _profiles = new ListBox { Left = 12, Top = 172, Width = 370, Height = 128, IntegralHeight = false };
        Button Side(string text, int top, Action<Profile> act)
        {
            var b = new Button { Left = 390, Top = top, Width = 118, Height = 27, Text = text, FlatStyle = FlatStyle.System };
            b.Click += (_, _) => { if (_profiles.SelectedIndex >= 0) { act(_list[_profiles.SelectedIndex]); ShowProfiles(); } };
            return b;
        }
        var rename = Side(S.RenameButton, 172, p =>
        {
            if (NameForm.Ask(this, S.RenameProfile, p.Name, null) is not { } a) return;
            if (_list.Any(x => x != p && x.Name.Equals(a.Name, StringComparison.OrdinalIgnoreCase)))
                MessageBox.Show(this, string.Format(S.ProfileNameTakenFmt, a.Name), S.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
            else p.Name = a.Name;
        });
        var delete = Side(S.Delete, 204, p => _list.Remove(p));
        var makeDefault = Side(S.MakeDefault, 236, p =>
        {
            var on = !p.IsDefault;
            foreach (var x in _list) x.IsDefault = false;
            p.IsDefault = on;   // a second click on the default one turns "default" off
        });
        var inMenu = Side(S.ProfileInMenuButton, 268, p => p.InMenu = !p.InMenu && !p.Name.Contains('"'));

        var reset = new Button { Left = 12, Top = 320, Width = 170, Height = 28, Text = S.ResetDefaults, FlatStyle = FlatStyle.System };
        reset.Click += (_, _) =>
        {
            if (MessageBox.Show(this, S.ResetConfirm, S.App, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            Settings.Reset();
            DialogResult = DialogResult.Cancel;   // already applied; nothing left for OK to save
        };
        var ok = new Button { Left = 314, Top = 320, Width = 94, Height = 28, Text = S.Ok, DialogResult = DialogResult.OK, FlatStyle = FlatStyle.System };
        var cancel = new Button { Left = 414, Top = 320, Width = 94, Height = 28, Text = S.Cancel, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };

        Controls.AddRange([lbl, _folder, browse, note, lblMotw, _motw, lblProfiles, _profiles, rename, delete, makeDefault, inMenu, reset, ok, cancel]);
        AcceptButton = ok;
        CancelButton = cancel;
        ShowProfiles();
    }

    void ShowProfiles()
    {
        var keep = _profiles.SelectedIndex;
        _profiles.Items.Clear();
        foreach (var p in _list) _profiles.Items.Add(p.Name + (p.IsDefault ? S.DefaultMark : "") + (p.InMenu ? S.MenuMark : ""));
        if (_profiles.Items.Count > 0) _profiles.SelectedIndex = Math.Clamp(keep, 0, _profiles.Items.Count - 1);
    }

    public static void Edit(IWin32Window? owner)
    {
        using var f = new SettingsForm();
        if ((owner == null ? f.ShowDialog() : f.ShowDialog(owner)) != DialogResult.OK) return;
        var folder = f._folder.Text.Trim();
        Settings.Update(s =>
        {
            s.ArchiveFolder = folder.Length == 0 ? null : Path.GetFullPath(folder);
            s.Profiles = f._list;
            s.Motw = (MotwPolicy)f._motw.SelectedIndex;
        });
        Assoc.ApplyProfiles();   // renamed, deleted or (un)ticked "in menu": Explorer's items follow
    }
}
