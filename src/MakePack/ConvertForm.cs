using SevenZip;

namespace MakePack;

/// <summary>Tools > Convert archives (Alt+Q): repack a list of archives into one format.</summary>
sealed class ConvertForm : Form
{
    static readonly CompressionLevel[] LevelMap =
        [CompressionLevel.None, CompressionLevel.Fast, CompressionLevel.Low,
         CompressionLevel.Normal, CompressionLevel.High, CompressionLevel.Ultra];

    readonly ListBox _list;
    readonly ComboBox _format, _level;
    readonly TextBox _folder;
    readonly CheckBox _keepIfNotSmaller, _deleteOriginals, _skipEncrypted;
    readonly Action? _release;

    /// <param name="release">Closes whatever the caller has open of these archives (the main window's view) before they are touched.</param>
    public ConvertForm(IEnumerable<string> archives, Action? release = null)
    {
        _release = release;
        Text = S.ConvertTitle;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 400);

        var lbl = new Label { Left = 12, Top = 10, Width = 430, Text = S.ConvertArchives };
        _list = new ListBox { Left = 12, Top = 30, Width = 430, Height = 140, SelectionMode = SelectionMode.MultiExtended, HorizontalScrollbar = true };
        var add = new Button { Left = 450, Top = 30, Width = 98, Height = 26, Text = S.AddFiles };
        var remove = new Button { Left = 450, Top = 62, Width = 98, Height = 26, Text = S.Remove };
        add.Click += (_, _) =>
        {
            using var d = new OpenFileDialog { Multiselect = true, Filter = $"{S.Archives}|*.{string.Join(";*.", Assoc.All)}|{S.AllFiles}|*.*" };
            if (d.ShowDialog(this) == DialogResult.OK) AddArchives(d.FileNames);
        };
        remove.Click += (_, _) =>
        {
            foreach (var i in _list.SelectedIndices.Cast<int>().OrderByDescending(i => i)) _list.Items.RemoveAt(i);
        };

        var lblFormat = new Label { Left = 12, Top = 186, Width = 70, Text = S.Format };
        _format = new ComboBox { Left = 86, Top = 182, Width = 110, DropDownStyle = ComboBoxStyle.DropDownList, DisplayMember = nameof(KindInfo.Name) };
        _format.Items.AddRange([.. Engine.Kinds.Where(k => k.Multi)]);
        _format.SelectedIndex = 0;
        var lblLevel = new Label { Left = 214, Top = 186, Width = 60, Text = S.Level };
        _level = new ComboBox { Left = 278, Top = 182, Width = 160, DropDownStyle = ComboBoxStyle.DropDownList };
        _level.Items.AddRange([.. S.Levels]);
        _level.SelectedIndex = Math.Max(0, Array.IndexOf(LevelMap, Settings.Current.Level));

        var lblFolder = new Label { Left = 12, Top = 222, Width = 430, Text = S.ConvertFolder };
        _folder = new TextBox { Left = 12, Top = 242, Width = 430, PlaceholderText = S.NextToOriginals };
        var browse = new Button { Left = 450, Top = 241, Width = 98, Height = 26, Text = S.Browse };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { SelectedPath = _folder.Text, Description = S.ConvertFolder, UseDescriptionForTitle = true };
            if (d.ShowDialog(this) == DialogResult.OK) _folder.Text = d.SelectedPath;
        };

        _keepIfNotSmaller = new CheckBox { Left = 12, Top = 280, Width = 536, Text = S.KeepIfNotSmaller, Checked = true };
        _deleteOriginals = new CheckBox { Left = 12, Top = 306, Width = 536, Text = S.DeleteOriginals };
        _skipEncrypted = new CheckBox { Left = 12, Top = 332, Width = 536, Text = S.SkipEncrypted };

        var go = new Button { Left = 350, Top = 362, Width = 94, Height = 28, Text = S.ConvertButton };
        var cancel = new Button { Left = 452, Top = 362, Width = 96, Height = 28, Text = S.Cancel, DialogResult = DialogResult.Cancel };
        go.Click += (_, _) => Run();
        cancel.Click += (_, _) => Close();

        Controls.AddRange([lbl, _list, add, remove, lblFormat, _format, lblLevel, _level, lblFolder, _folder, browse,
                           _keepIfNotSmaller, _deleteOriginals, _skipEncrypted, go, cancel]);
        AcceptButton = go;
        CancelButton = cancel;
        AddArchives(archives);
    }

    public void AddArchives(IEnumerable<string> paths)
    {
        foreach (var p in paths)
        {
            var full = Path.GetFullPath(p.Trim().Trim('"'));
            if (File.Exists(full) && !_list.Items.Contains(full)) _list.Items.Add(full);
        }
    }

    sealed record Job(string Source, string? Password, string Target);

    void Run()
    {
        var sources = _list.Items.Cast<string>().ToList();
        if (sources.Count == 0) { MessageBox.Show(this, S.NoInputs, S.App, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        var kind = ((KindInfo)_format.SelectedItem!).Kind;
        var folder = _folder.Text.Trim();
        if (folder.Length > 0 && !Directory.Exists(folder)) Directory.CreateDirectory(folder);
        var delete = _deleteOriginals.Checked;
        _release?.Invoke();

        // Every question first (passwords, skips, overwrites), then one progress bar for the whole batch.
        var jobs = new List<Job>();
        var skipped = new List<string>();
        foreach (var src in sources)
        {
            if (_skipEncrypted.Checked && Encrypted(src)) { skipped.Add(Path.GetFileName(src)); continue; }
            var a = PasswordForm.OpenArchive(this, src);
            if (a == null) { skipped.Add(Path.GetFileName(src)); continue; }
            var ready = PasswordForm.EnsurePassword(this, a);
            var password = ready?.Password;
            if (ready != null && !ReferenceEquals(ready, a)) ready.Dispose();
            a.Dispose();
            if (ready == null) { skipped.Add(Path.GetFileName(src)); continue; }

            var target = Path.Combine(folder.Length > 0 ? folder : Path.GetDirectoryName(src)!, Engine.BaseName(src) + Engine.Kind(kind).Ext);
            // Same name as the original: replace it only when the originals are to go anyway, else take "name (2).ext".
            if (Engine.SamePath(src, target) && !delete) target = Engine.Unique(target);
            jobs.Add(new Job(src, password, target));
        }
        var clash = jobs.Where(j => !Engine.SamePath(j.Source, j.Target)).Select(j => j.Target);
        if (jobs.Count > 0 && !CompressForm.ConfirmOverwrite(this, clash, 0)) return;

        int converted = 0, kept = 0;
        var errors = new List<string>();
        var level = LevelMap[Math.Clamp(_level.SelectedIndex, 0, LevelMap.Length - 1)];
        var keepIfNotSmaller = _keepIfNotSmaller.Checked;
        using (var progress = new ProgressForm(S.Converting))
            progress.Run(this, async (p, ct) =>
            {
                for (var i = 0; i < jobs.Count; i++)
                {
                    var j = jobs[i];
                    var slice = new Slice(p, i * 100 / jobs.Count, (i + 1) * 100 / jobs.Count, Path.GetFileName(j.Source));
                    try
                    {
                        if (await Engine.Convert(j.Source, j.Password, j.Target, kind, level, keepIfNotSmaller, delete, slice, ct)) converted++;
                        else kept++;
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex) { errors.Add(Path.GetFileName(j.Source) + ": " + Engine.Friendly(ex)); }   // one bad archive does not stop the rest
                }
            });

        var summary = string.Format(S.ConvertSummaryFmt, converted, kept, skipped.Count, errors.Count);
        if (errors.Count > 0) summary += "\n\n" + string.Join("\n", errors.Take(10));
        MessageBox.Show(this, summary, S.ConvertTitle, MessageBoxButtons.OK, errors.Count > 0 ? MessageBoxIcon.Warning : MessageBoxIcon.Information);
        if (errors.Count == 0) Close();
    }

    /// <summary>Header-encrypted, or any entry encrypted.</summary>
    static bool Encrypted(string archive)
    {
        if (Engine.Probe(archive) == Probe.EncryptedHeaders) return true;
        try { using var a = Engine.Open(archive, null); return a.X.ArchiveFileData.Any(f => f.Encrypted); }
        catch { return Engine.CanEncryptHeaders(archive); }   // would not open without a password
    }

    /// <summary>One archive's share of the overall bar, with its name in front of the file being worked on.</summary>
    sealed class Slice(IProgress<(int, string)> to, int lo, int hi, string name) : IProgress<(int percent, string file)>
    {
        public void Report((int percent, string file) v) => to.Report((lo + v.percent * (hi - lo) / 100, v.file.Length > 0 ? $"{name}: {v.file}" : name));
    }
}
