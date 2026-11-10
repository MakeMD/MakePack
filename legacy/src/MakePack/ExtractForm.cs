namespace MakePack;

/// <summary>Everything the extract dialog decides.</summary>
sealed record ExtractChoice(string Dest, OverwriteMode Mode, ExtractOptions Options, DeleteAfter Delete);

sealed class ExtractForm : Form
{
    readonly TextBox _dest;
    readonly CheckBox _sub, _keepBroken;
    readonly ComboBox _mode, _paths, _update, _delete;
    readonly string _subName;

    ExtractForm(Archive a)
    {
        Text = S.Extract.TrimEnd('…');
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(560, 250);
        _subName = Engine.BaseName(a.Source);
        var st = Settings.Current;

        var lblDest = new Label { Left = 12, Top = 12, Width = 300, Text = S.Destination };
        _dest = new TextBox { Left = 12, Top = 32, Width = 448, Text = Path.GetDirectoryName(a.Source) ?? "" };
        var browse = new Button { Left = 468, Top = 31, Width = 80, Height = 25, Text = S.Browse };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { SelectedPath = _dest.Text, Description = S.PickFolder, UseDescriptionForTitle = true };
            if (d.ShowDialog(this) == DialogResult.OK) _dest.Text = d.SelectedPath;
        };

        _sub = new CheckBox
        {
            Left = 12, Top = 66, Width = 536, AutoEllipsis = true,
            Text = string.Format(S.SubFolderFmt, _subName),
            Checked = TopLevelCount(a) > 1,   // 7-Zip-style smart default
        };

        ComboBox Combo(string label, int left, int top, int labelWidth, int width, string[] items, int selected, Control[] into)
        {
            into[0] = new Label { Left = left, Top = top + 4, Width = labelWidth, Text = label };
            var c = new ComboBox { Left = left + labelWidth + 4, Top = top, Width = width, DropDownStyle = ComboBoxStyle.DropDownList };
            c.Items.AddRange(items);
            c.SelectedIndex = Math.Clamp(selected, 0, items.Length - 1);
            into[1] = c;
            return c;
        }
        var l = new Control[2]; var row = new List<Control>();
        _mode = Combo(S.IfExists, 12, 100, 110, 160, [S.Ask, S.Overwrite, S.Skip, S.Rename], (int)st.ExtractOverwrite, l); row.AddRange(l);
        _paths = Combo(S.Paths, 300, 100, 80, 168, [S.WithPaths, S.NoPaths], st.ExtractNoPaths ? 1 : 0, l); row.AddRange(l);
        _update = Combo(S.Update, 12, 134, 110, 160, [S.UpdateReplace, S.UpdateNewer, S.UpdateExisting], (int)st.ExtractUpdate, l); row.AddRange(l);
        _delete = Combo(S.ArchiveAfter, 12, 168, 110, 160, [S.DeleteNever, S.DeleteAsk, S.DeleteRecycle], (int)st.ExtractDeleteAfter, l); row.AddRange(l);
        new ToolTip().SetToolTip(_delete, S.DeleteAfterTip);
        new ToolTip().SetToolTip(_update, S.UpdateTip);
        // Update modes settle a clash by date; the overwrite question only belongs to "replace".
        _update.SelectedIndexChanged += (_, _) => _mode.Enabled = _update.SelectedIndex == (int)UpdateMode.Replace;
        _mode.Enabled = _update.SelectedIndex == (int)UpdateMode.Replace;
        _keepBroken = new CheckBox { Left = 300, Top = 136, Width = 248, Text = S.KeepBroken, Checked = st.ExtractKeepBroken };

        var ok = new Button { Left = 360, Top = 210, Width = 94, Height = 26, Text = S.Extract.TrimEnd('…'), DialogResult = DialogResult.OK };
        var cancel = new Button { Left = 462, Top = 210, Width = 86, Height = 26, Text = S.Cancel, DialogResult = DialogResult.Cancel };
        Controls.AddRange([lblDest, _dest, browse, _sub, .. row, _keepBroken, ok, cancel]);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    static int TopLevelCount(Archive a) => a.X.ArchiveFileData
        .Select(f => Engine.Norm(f.FileName))
        .Select(n => n.IndexOf('/') is var i && i >= 0 ? n[..i] : n)
        .Distinct(StringComparer.OrdinalIgnoreCase).Count();

    /// <summary>null = cancelled. The choices (not the folder) are remembered for next time.</summary>
    public static ExtractChoice? Ask(IWin32Window? owner, Archive a)
    {
        using var f = new ExtractForm(a);
        var r = owner == null ? f.ShowDialog() : f.ShowDialog(owner);
        if (r != DialogResult.OK || f._dest.Text.Trim().Length == 0) return null;
        var dest = f._dest.Text.Trim();
        if (f._sub.Checked) dest = Path.Combine(dest, f._subName);
        var choice = new ExtractChoice(dest, (OverwriteMode)f._mode.SelectedIndex,
            new ExtractOptions(f._paths.SelectedIndex == 1, (UpdateMode)f._update.SelectedIndex, f._keepBroken.Checked),
            (DeleteAfter)f._delete.SelectedIndex);
        Settings.Update(s =>
        {
            s.ExtractOverwrite = choice.Mode;
            s.ExtractNoPaths = choice.Options.NoPaths;
            s.ExtractUpdate = choice.Options.Update;
            s.ExtractKeepBroken = choice.Options.KeepBroken;
            s.ExtractDeleteAfter = choice.Delete;
        });
        return choice;
    }

    /// <summary>
    /// After a clean extraction of the WHOLE archive, per the dialog's choice: keep it, ask, or send it to the
    /// Recycle Bin (every part of a .001 set). <paramref name="close"/> releases the archive first.
    /// </summary>
    public static void AfterExtract(IWin32Window? owner, string source, DeleteAfter delete, Action close)
    {
        if (delete == DeleteAfter.Never) return;
        if (delete == DeleteAfter.Ask && MessageBox.Show(owner, string.Format(S.DeleteArchiveAskFmt, Path.GetFileName(source)),
                S.App, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        close();
        try { Engine.RecycleArchive(source); }
        catch (Exception ex) { MessageBox.Show(owner, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    /// <summary>
    /// File-exists prompt for Engine.Extract (or, with <paramref name="append"/>, Engine.Append: Replace / Skip,
    /// no Rename), marshalled onto <paramref name="owner"/>'s thread.
    /// </summary>
    public static Func<string, OverwriteMode?> Conflicts(Control owner, bool append = false)
    {
        OverwriteMode? sticky = null;

        OverwriteMode? AskOne(string file)
        {
            var over = new TaskDialogButton(append ? S.Replace : S.Overwrite);
            var skip = new TaskDialogButton(S.Skip);
            var rename = new TaskDialogButton(S.Rename);
            var all = new TaskDialogVerificationCheckBox(S.ApplyToAll);
            var page = new TaskDialogPage
            {
                Caption = S.App,
                Heading = S.FileExists,
                Text = file,
                Icon = TaskDialogIcon.Warning,
                Buttons = { over, skip },
                Verification = all,
                AllowCancel = true,
            };
            if (!append) page.Buttons.Add(rename);
            page.Buttons.Add(TaskDialogButton.Cancel);
            var clicked = TaskDialog.ShowDialog(owner, page);
            OverwriteMode? m = clicked == over ? OverwriteMode.Overwrite
                             : clicked == skip ? OverwriteMode.Skip
                             : clicked == rename ? OverwriteMode.Rename
                             : null;
            if (all.Checked && m != null) sticky = m;
            return m;
        }

        return file =>
        {
            if (sticky != null) return sticky;
            try { return owner.InvokeRequired ? owner.Invoke(() => AskOne(file)) : AskOne(file); }
            catch { return null; }   // owner already gone: treat as cancel
        };
    }
}
