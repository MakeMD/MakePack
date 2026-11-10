using SevenZip;

namespace MakePack;

sealed class CompressForm : Form
{
    static readonly CompressionLevel[] LevelMap =
        [CompressionLevel.None, CompressionLevel.Fast, CompressionLevel.Low,
         CompressionLevel.Normal, CompressionLevel.High, CompressionLevel.Ultra];

    readonly ListBox _inputs;
    readonly TextBox _out;
    readonly ComboBox _format;
    readonly ComboBox _level;
    readonly TextBox _password, _confirm;
    readonly CheckBox _encryptNames, _zipCrypto, _showPassword;
    readonly ComboBox _volumes;
    readonly CheckBox _testAfter, _deleteSources, _separate, _sfx;
    readonly ErrorProvider _volumeError = new() { BlinkStyle = ErrorBlinkStyle.NeverBlink };
    readonly LinkLabel _advToggle;
    readonly Panel _adv;
    readonly ComboBox _method, _dict, _solid, _threads, _filter;
    readonly Button _create, _cancel;
    readonly ComboBox _profile;
    bool _autoOut = true;      // false once the user edits the output path by hand
    bool _setting;

    /// <summary>Set when the archive was created; null when the user cancelled.</summary>
    public string? CreatedPath { get; private set; }

    public CompressForm(IEnumerable<string> inputs)
    {
        Text = S.NewArchive.TrimEnd('…');
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        // Profiles (compression profiles): picking one fills every option below; the default one is
        // picked as the dialog opens.
        var lblProfile = new Label { Left = 12, Top = 14, Width = 70, Text = S.Profile };
        _profile = new ComboBox { Left = 86, Top = 10, Width = 356, DropDownStyle = ComboBoxStyle.DropDownList };
        _profile.SelectedIndexChanged += (_, _) => { if (_profile.SelectedItem is Choice<Profile?> { Value: { } p }) ApplyProfile(p); };
        var saveProfile = new Button { Left = 450, Top = 9, Width = 98, Height = 26, Text = S.SaveProfile };
        saveProfile.Click += (_, _) => SaveProfile();

        var lblIn = new Label { Left = 12, Top = 44, Width = 300, Text = S.Inputs };
        _inputs = new ListBox { Left = 12, Top = 64, Width = 430, Height = 116, SelectionMode = SelectionMode.MultiExtended, HorizontalScrollbar = true };

        var addFiles = new Button { Left = 450, Top = 64, Width = 98, Height = 26, Text = S.AddFiles };
        var addFolder = new Button { Left = 450, Top = 96, Width = 98, Height = 26, Text = S.AddFolder };
        var remove = new Button { Left = 450, Top = 128, Width = 98, Height = 26, Text = S.Remove };
        addFiles.Click += (_, _) =>
        {
            using var d = new OpenFileDialog { Multiselect = true, Title = S.AddFiles, Filter = $"{S.AllFiles}|*.*" };
            if (d.ShowDialog(this) == DialogResult.OK) AddInputs(d.FileNames);
        };
        addFolder.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { Description = S.PickFolder, UseDescriptionForTitle = true };
            if (d.ShowDialog(this) == DialogResult.OK) AddInputs([d.SelectedPath]);
        };
        remove.Click += (_, _) =>
        {
            foreach (var i in _inputs.SelectedIndices.Cast<int>().OrderByDescending(i => i)) _inputs.Items.RemoveAt(i);
            InputsChanged();
        };

        var lblOut = new Label { Left = 12, Top = 192, Width = 260, Text = S.OutputFile };
        _out = new TextBox { Left = 12, Top = 212, Width = 430 };
        _out.TextChanged += (_, _) => { if (!_setting) _autoOut = false; };
        var browse = new Button { Left = 450, Top = 211, Width = 98, Height = 26, Text = S.Browse };
        browse.Click += (_, _) =>
        {
            var ext = Ext();
            using var d = new SaveFileDialog
            {
                FileName = Path.GetFileName(_out.Text),
                InitialDirectory = Path.GetDirectoryName(_out.Text) ?? "",
                Filter = $"{(SfxOn() ? "SFX" : Engine.Kind(CurrentKind()).Name)}|*{ext}|{S.AllFiles}|*.*",
            };
            if (d.ShowDialog(this) == DialogResult.OK) { _out.Text = d.FileName; _autoOut = false; }
        };
        // Each input gets its own archive next to it: the single Archive path above no longer applies.
        _separate = new CheckBox { Left = 278, Top = 189, Width = 270, Text = S.SeparateArchives };
        _separate.CheckedChanged += (_, _) => _out.Enabled = browse.Enabled = !_separate.Checked;

        var lblFormat = new Label { Left = 12, Top = 252, Width = 70, Text = S.Format };
        _format = new ComboBox { Left = 86, Top = 248, Width = 110, DropDownStyle = ComboBoxStyle.DropDownList };
        _format.SelectedIndexChanged += (_, _) => FormatChanged();

        var lblLevel = new Label { Left = 214, Top = 252, Width = 60, Text = S.Level };
        _level = new ComboBox { Left = 278, Top = 248, Width = 160, DropDownStyle = ComboBoxStyle.DropDownList };
        _level.Items.AddRange([.. S.Levels]);
        _level.SelectedIndex = Math.Max(0, Array.IndexOf(LevelMap, Settings.Current.Level));
        _level.SelectedIndexChanged += (_, _) => RefreshAdvanced();

        var lblPassword = new Label { Left = 12, Top = 292, Width = 70, Text = S.Password + ":" };
        _password = new TextBox { Left = 86, Top = 288, Width = 180, UseSystemPasswordChar = true };
        _encryptNames = new CheckBox { Left = 278, Top = 290, Width = 270, Text = S.EncryptNames };
        // Same spot as Encrypt names: that one is 7z-only, this one zip-only, so exactly one of them shows.
        _zipCrypto = new CheckBox { Left = 278, Top = 290, Width = 270, Text = S.ZipCrypto, Visible = false };
        new ToolTip().SetToolTip(_zipCrypto, S.ZipCryptoTip);

        // Typed twice while it is hidden (rule): a typo in a hidden password locks the archive for good.
        var lblConfirm = new Label { Left = 12, Top = 326, Width = 70, Text = S.Confirm };
        _confirm = new TextBox { Left = 86, Top = 322, Width = 180, UseSystemPasswordChar = true };
        _showPassword = new CheckBox { Left = 278, Top = 324, Width = 270, Text = S.ShowPassword };
        _showPassword.CheckedChanged += (_, _) => { _password.UseSystemPasswordChar = !_showPassword.Checked; PasswordBoxes(); };

        var lblVolumes = new Label { Left = 12, Top = 360, Width = 70, Text = S.Volumes };
        _volumes = new ComboBox { Left = 86, Top = 356, Width = 180, DropDownStyle = ComboBoxStyle.DropDown };
        _volumes.Items.AddRange(VolumePresets);
        _volumes.TextChanged += (_, _) => ValidateVolumes();
        // Self-extracting: 7z only, one file (no volumes), written as .exe.
        _sfx = new CheckBox { Left = 450, Top = 250, Width = 98, Text = "SFX (.exe)" };
        new ToolTip().SetToolTip(_sfx, S.SfxTip);
        _sfx.CheckedChanged += (_, _) => { _volumes.Enabled = !_sfx.Checked; ValidateVolumes(); UpdateOut(); };

        var volumesHint = new Label { Left = 292, Top = 360, Width = 256, Text = S.VolumesHint, ForeColor = SystemColors.GrayText };

        _testAfter = new CheckBox { Left = 12, Top = 392, Width = 260, Text = S.TestAfter, Checked = Settings.Current.TestAfter };
        // Not remembered on purpose: a forgotten tick here costs the user their files.
        _deleteSources = new CheckBox { Left = 278, Top = 392, Width = 270, Text = S.DeleteSources };

        // Advanced block (Compression... / 7-Zip's right-hand column), folded away by default.
        _adv = new Panel { Left = 0, Top = AdvTop, Width = 560, Height = AdvHeight };
        ComboBox Combo(string label, int row, int col)
        {
            var x = col == 0 ? 12 : 214;
            _adv.Controls.Add(new Label { Left = x, Top = row * 36 + 4, Width = col == 0 ? 70 : 60, Text = label });
            var c = new ComboBox { Left = x + (col == 0 ? 74 : 64), Top = row * 36, Width = col == 0 ? 110 : 160, DropDownStyle = ComboBoxStyle.DropDownList };
            _adv.Controls.Add(c);
            return c;
        }
        _method = Combo(S.Method, 0, 0);
        _dict = Combo(S.Dictionary, 0, 1);
        _solid = Combo(S.SolidBlock, 1, 0);
        _threads = Combo(S.Threads, 1, 1);
        _filter = Combo(S.ExeFilter, 2, 0);
        _method.SelectedIndexChanged += (_, _) => RefreshAdvanced();

        var st = Settings.Current;
        Fill(_dict, Dictionaries.Select(d => new Choice<long>(d == 0 ? S.Auto : Engine.NiceSize(d), d)), st.Dictionary);
        Fill(_solid, Solids.Select(v => new Choice<string?>(v switch { null => S.Auto, "off" => S.Off, _ => v.ToUpperInvariant() + "B" }, v)), st.Solid);
        Fill(_threads, Enumerable.Range(0, Environment.ProcessorCount + 1).Select(n => new Choice<int>(n == 0 ? S.Auto : n.ToString(), n)), st.Threads);
        Fill(_filter, Filters.Select(f => new Choice<string?>(f.Text ?? (f.Value == null ? S.Auto : S.Off), f.Value)), st.Filter);

        _advToggle = new LinkLabel { Left = 12, Width = 200, AutoSize = false };
        _advToggle.LinkClicked += (_, _) => { Settings.Update(s => s.ShowAdvanced = !s.ShowAdvanced); LayoutAdvanced(); };

        _create = new Button { Left = 350, Width = 94, Height = 28, Text = S.Create };
        _cancel = new Button { Left = 452, Width = 96, Height = 28, Text = S.Cancel, DialogResult = DialogResult.Cancel };
        _create.Click += (_, _) => DoCreate();
        _cancel.Click += (_, _) => Close();   // DialogResult only closes a form that was shown modally

        Controls.AddRange([lblProfile, _profile, saveProfile, lblIn, _inputs, addFiles, addFolder, remove, lblOut, _separate, _out, browse,
                           lblFormat, _format, lblLevel, _level, _sfx, lblPassword, _password, _encryptNames, _zipCrypto,
                           lblConfirm, _confirm, _showPassword,
                           lblVolumes, _volumes, volumesHint, _testAfter, _deleteSources, _adv, _advToggle, _create, _cancel]);
        AcceptButton = _create;
        CancelButton = _cancel;
        LayoutAdvanced();

        AddInputs(inputs);   // also fills the format list - with the inputs known, so a remembered gz/xz can stick
        RefreshProfiles(Settings.Current.Profiles.FirstOrDefault(x => x.IsDefault)?.Name);
    }

    /// <summary>The list, with <paramref name="select"/> picked (and so applied); the first item = no profile, options as they are.</summary>
    void RefreshProfiles(string? select)
    {
        var items = Settings.Current.Profiles.Select(x => new Choice<Profile?>(x.IsDefault ? x.Name + S.DefaultMark : x.Name, x));
        _profile.Items.Clear();
        _profile.Items.AddRange([new Choice<Profile?>(S.NoProfile, null), .. items]);
        var i = _profile.Items.Cast<Choice<Profile?>>().ToList().FindIndex(c => c.Value?.Name == select);
        _profile.SelectedIndex = Math.Max(0, i);
    }

    void ApplyProfile(Profile p)
    {
        var f = _format.Items.Cast<KindInfo>().ToList().FindIndex(k => k.Kind == p.Format);
        if (f >= 0) _format.SelectedIndex = f;   // a gz profile with folders in the list: the format stays what it was
        _level.SelectedIndex = Math.Max(0, Array.IndexOf(LevelMap, p.Level));
        RefreshAdvanced();
        Pick(_method, p.Method);
        RefreshAdvanced();                       // whether a dictionary applies depends on the method
        Pick(_dict, p.Dictionary);
        Pick(_solid, p.Solid);
        Pick(_threads, p.Threads);
        Pick(_filter, p.Filter);
        _volumes.Text = p.Volumes;
        _testAfter.Checked = p.TestAfter;
        _deleteSources.Checked = p.DeleteSources;
        _separate.Checked = p.Separate;
        _sfx.Checked = p.Sfx && _sfx.Enabled;
        _encryptNames.Checked = p.EncryptNames && _encryptNames.Enabled;
        _zipCrypto.Checked = p.ZipCrypto && _zipCrypto.Visible;
    }

    static void Pick<T>(ComboBox c, T value)
    {
        var i = c.Items.Cast<Choice<T>>().ToList().FindIndex(x => EqualityComparer<T>.Default.Equals(x.Value, value));
        if (i >= 0) c.SelectedIndex = i;
    }

    /// <summary>The dialog as it stands, minus the password. Boxes that are greyed out are saved as "default".</summary>
    Profile Snapshot(string name, bool isDefault) => new()
    {
        Name = name,
        IsDefault = isDefault,
        Format = CurrentKind(),
        Level = LevelMap[Math.Clamp(_level.SelectedIndex, 0, LevelMap.Length - 1)],
        Method = _method.Enabled ? Value<CompressionMethod>(_method) : CompressionMethod.Default,
        Dictionary = _dict.Enabled ? Value<long>(_dict) : 0,
        Solid = _solid.Enabled ? Value<string?>(_solid) : null,
        Threads = _threads.Enabled ? Value<int>(_threads) : 0,
        Filter = _filter.Enabled ? Value<string?>(_filter) : null,
        Volumes = _volumes.Enabled ? _volumes.Text.Trim() : "",
        TestAfter = _testAfter.Checked,
        DeleteSources = _deleteSources.Checked,
        Separate = _separate.Checked,
        Sfx = SfxOn(),
        EncryptNames = _encryptNames.Enabled && _encryptNames.Checked,
        ZipCrypto = _zipCrypto.Visible && _zipCrypto.Checked,
    };

    void SaveProfile()
    {
        if (VolumeSize() == null) return;   // a bad volume size is flagged already; do not store it
        var current = _profile.SelectedItem is Choice<Profile?> { Value: { } p } ? p : null;
        if (NameForm.Ask(this, S.SaveProfileTitle, current?.Name ?? "", current?.IsDefault ?? false, current?.InMenu ?? false) is not { } answer) return;
        var taken = Settings.Current.FindProfile(answer.Name);
        if (taken != null && MessageBox.Show(this, string.Format(S.ProfileExistsFmt, taken.Name), S.App,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        var profile = Snapshot(answer.Name, answer.IsDefault);
        profile.InMenu = answer.InMenu;
        Settings.Update(s =>
        {
            s.Profiles.RemoveAll(x => x.Name.Equals(answer.Name, StringComparison.OrdinalIgnoreCase));
            if (profile.IsDefault) foreach (var x in s.Profiles) x.IsDefault = false;
            s.Profiles.Add(profile);
        });
        Assoc.ApplyProfiles();   // a menu profile's item, or a changed extension, shows in Explorer right away
        RefreshProfiles(profile.Name);
    }

    /// <summary>
    /// One question for every archive about to be overwritten. The dialog and `a --profile` share it.
    /// <paramref name="volume"/> &gt; 0: what lands on disk is name.001.
    /// </summary>
    public static bool ConfirmOverwrite(IWin32Window? owner, IEnumerable<string> archives, long volume)
    {
        var existing = archives.Select(a => volume > 0 ? Engine.Part(a, 1) : a).Where(File.Exists).ToList();
        if (existing.Count == 0) return true;
        var ask = existing.Count == 1 ? string.Format(S.OverwriteArchiveFmt, Path.GetFileName(existing[0]))
                                      : string.Format(S.OverwriteManyFmt, existing.Count, string.Join("\n", existing.Take(5).Select(Path.GetFileName)));
        return MessageBox.Show(owner, ask, S.App, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;
    }

    const int AdvTop = 426, AdvHeight = 104;
    const long MinVolume = 64 << 10;

    // Binary units like 7-Zip's -v: FAT32 tops out at 4 GiB - 1, a DVD+R holds 4482 MiB.
    static readonly object[] VolumePresets = ["100 MB", "700 MB (CD)", "4095 MB (FAT32)", "4482 MB (DVD)", "8152 MB (DVD DL)"];

    /// <summary>Bytes per volume, 0 = no split, null = not a size we take.</summary>
    long? VolumeSize() => !_volumes.Enabled ? 0
        : Engine.ParseSize(_volumes.Text) is { } v && (v == 0 || v >= MinVolume) ? v : null;

    /// <summary>The extension that will be written: .exe for an SFX, the format's own otherwise.</summary>
    string Ext() => SfxOn() ? ".exe" : Engine.Kind(CurrentKind()).Ext;

    bool SfxOn() => _sfx.Enabled && _sfx.Checked;

    void ValidateVolumes()
    {
        var ok = VolumeSize() != null;
        _volumeError.SetError(_volumes, ok ? "" : S.BadVolumeSize);
        _create.Enabled = ok;
    }

    static readonly long[] Dictionaries =
        [0, 1 << 20, 4 << 20, 16 << 20, 32 << 20, 64 << 20, 128 << 20, 256 << 20, 512 << 20, 1L << 30, 1536L << 20];
    static readonly string?[] Solids = [null, "off", "16m", "64m", "256m", "1g", "4g", "16g"];
    static readonly (string? Text, string? Value)[] Filters = [(null, null), (null, "off"), ("x86 (BCJ2)", "BCJ2"), ("ARM64", "ARM64")];
    static readonly Dictionary<CompressionMethod, string> MethodNames = new()
    {
        [CompressionMethod.Lzma2] = "LZMA2", [CompressionMethod.Lzma] = "LZMA", [CompressionMethod.Ppmd] = "PPMd",
        [CompressionMethod.BZip2] = "BZip2", [CompressionMethod.Deflate] = "Deflate", [CompressionMethod.Deflate64] = "Deflate64",
    };

    sealed record Choice<T>(string Text, T Value) { public override string ToString() => Text; }

    static void Fill<T>(ComboBox c, IEnumerable<Choice<T>> items, T selected)
    {
        c.Items.Clear();
        c.Items.AddRange([.. items]);
        var i = c.Items.Cast<Choice<T>>().ToList().FindIndex(x => EqualityComparer<T>.Default.Equals(x.Value, selected));
        c.SelectedIndex = c.Items.Count == 0 ? -1 : Math.Max(0, i);
    }

    static T Value<T>(ComboBox c) => ((Choice<T>)c.SelectedItem!).Value;

    void LayoutAdvanced()
    {
        var show = Settings.Current.ShowAdvanced;
        _adv.Visible = show;
        var bottom = AdvTop + (show ? AdvHeight : 0);
        _advToggle.Top = bottom + 16;
        _advToggle.Text = S.AdvancedOptions + (show ? " ▴" : " ▾");
        _create.Top = _cancel.Top = bottom + 10;
        ClientSize = new Size(560, bottom + 50);
    }

    /// <summary>Only what the format and method can take stays enabled; DoCreate reads enabled boxes only.</summary>
    void RefreshAdvanced()
    {
        var kind = CurrentKind();
        var methods = Engine.MethodsFor(kind);
        var current = _method.SelectedItem is Choice<CompressionMethod> m ? m.Value : Settings.Current.Method;
        if (!_method.Items.Cast<Choice<CompressionMethod>>().Select(x => x.Value).SequenceEqual(methods))
            Fill(_method, methods.Select(x => new Choice<CompressionMethod>(MethodNames[x], x)), current);

        var on = methods.Length > 0 && LevelMap[Math.Max(0, _level.SelectedIndex)] != CompressionLevel.None;
        var format = Engine.Kind(kind).Format;
        _method.Enabled = _threads.Enabled = on;
        _dict.Enabled = on && _method.SelectedItem is Choice<CompressionMethod> sel && Engine.HasDictionary(format, sel.Value);
        _solid.Enabled = _filter.Enabled = on && kind == ArchiveKind.SevenZip;
    }

    public void AddInputs(IEnumerable<string> paths)
    {
        foreach (var p in paths)
        {
            var full = Path.GetFullPath(p.Trim().Trim('"'));
            if (!_inputs.Items.Contains(full) && (File.Exists(full) || Directory.Exists(full))) _inputs.Items.Add(full);
        }
        InputsChanged();
    }

    List<string> Inputs() => [.. _inputs.Items.Cast<string>()];

    ArchiveKind CurrentKind() => _format.SelectedItem is KindInfo k ? k.Kind : ArchiveKind.SevenZip;

    void InputsChanged() { RefreshFormats(); UpdateOut(); }

    /// <summary>Single-file formats only make sense for exactly one file input, so they are listed only then.</summary>
    // ponytail: rebuilding the list beats owner-drawing disabled combo items.
    void RefreshFormats()
    {
        var paths = Inputs();
        var single = paths.Count == 1 && File.Exists(paths[0]);
        var wanted = Engine.Kinds.Where(k => k.Multi || single).ToArray();
        if (_format.Items.Count == wanted.Length) return;

        var keep = (_format.SelectedItem as KindInfo)?.Kind ?? Settings.Current.Format;
        _format.Items.Clear();
        _format.Items.AddRange([.. wanted]);
        _format.DisplayMember = nameof(KindInfo.Name);
        var index = Array.FindIndex(wanted, k => k.Kind == keep);
        _format.SelectedIndex = index < 0 ? 0 : index;
    }

    void FormatChanged()
    {
        var kind = Engine.Kind(CurrentKind());
        _password.Enabled = kind.Password;
        _encryptNames.Enabled = kind.Kind == ArchiveKind.SevenZip;
        _zipCrypto.Visible = kind.Kind == ArchiveKind.Zip;
        _encryptNames.Visible = !_zipCrypto.Visible;
        if (!_password.Enabled) { _password.Clear(); _confirm.Clear(); }
        if (!_encryptNames.Enabled) _encryptNames.Checked = false;
        if (!_zipCrypto.Visible) _zipCrypto.Checked = false;
        PasswordBoxes();
        _sfx.Enabled = kind.Kind == ArchiveKind.SevenZip;
        if (!_sfx.Enabled) _sfx.Checked = false;
        RefreshAdvanced();
        UpdateOut();
    }

    void PasswordBoxes()
    {
        _showPassword.Enabled = _password.Enabled;
        _confirm.Enabled = _password.Enabled && !_showPassword.Checked;
    }

    void UpdateOut()
    {
        var ext = Ext();
        _setting = true;
        if (_autoOut) _out.Text = DefaultOut(ext);
        else if (_out.Text.Length > 0) _out.Text = Path.Combine(Path.GetDirectoryName(_out.Text) ?? "", Engine.BaseName(_out.Text) + ext);
        _setting = false;
    }

    string DefaultOut(string ext) => Engine.DefaultArchivePath(Inputs(), ext, Settings.Current.ArchiveFolder);

    void DoCreate()
    {
        var paths = Inputs();
        if (paths.Count == 0) { MessageBox.Show(this, S.NoInputs, S.App, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        if (VolumeSize() is not { } volume) return;   // the error icon already says why
        if (_password.Enabled && _password.Text.Length > 0 && _confirm.Enabled && _confirm.Text != _password.Text)
        {
            MessageBox.Show(this, S.PasswordsDiffer, S.App, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            _confirm.Focus();
            _confirm.SelectAll();
            return;
        }
        string OnDisk(string archive) => volume > 0 ? Engine.Part(archive, 1) : archive;   // what lands there, and gets opened

        var kind = CurrentKind();
        var outPath = _out.Text.Trim();
        var plan = _separate.Checked ? Engine.PlanSeparate(paths, Ext(), Settings.Current.ArchiveFolder) : null;
        if (plan == null && outPath.Length == 0) { MessageBox.Show(this, S.OutputFile, S.App, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        if (!ConfirmOverwrite(this, plan?.Select(x => x.Output) ?? [outPath], volume)) return;

        var options = new CompressOptions(
            Level: LevelMap[Math.Clamp(_level.SelectedIndex, 0, LevelMap.Length - 1)],
            Password: _password.Enabled && _password.Text.Length > 0 ? _password.Text : null,
            EncryptHeaders: _encryptNames.Enabled && _encryptNames.Checked,
            Method: _method.Enabled ? Value<CompressionMethod>(_method) : CompressionMethod.Default,
            Dictionary: _dict.Enabled ? Value<long>(_dict) : 0,
            Solid: _solid.Enabled ? Value<string?>(_solid) : null,
            Threads: _threads.Enabled ? Value<int>(_threads) : 0,
            Filter: _filter.Enabled ? Value<string?>(_filter) : null,
            VolumeSize: volume,
            TestAfter: _testAfter.Checked,
            DeleteSources: _deleteSources.Checked,
            Sfx: SfxOn(),
            ZipCrypto: _zipCrypto.Visible && _zipCrypto.Checked && _password.Text.Length > 0);

        using var progress = new ProgressForm(S.Compressing);
        if (!progress.Run(this, (p, ct) => plan != null ? Engine.CompressEach(plan, kind, options, p, ct)
                                                        : Engine.Compress(paths, outPath, kind, options, p, ct))) return;
        Settings.Update(s =>
        {
            s.Format = kind;
            s.Level = options.Level;
            s.TestAfter = options.TestAfter;
            // A greyed-out box says nothing about the user's choice - keep the remembered one.
            if (_method.Enabled) s.Method = options.Method;
            if (_dict.Enabled) s.Dictionary = options.Dictionary;
            if (_solid.Enabled) s.Solid = options.Solid;
            if (_threads.Enabled) s.Threads = options.Threads;
            if (_filter.Enabled) s.Filter = options.Filter;
        });

        CreatedPath = plan == null ? OnDisk(outPath) : null;   // several archives: nothing single to open
        DialogResult = DialogResult.OK;
        if (!Modal) Close();
    }
}
