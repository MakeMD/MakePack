using System.Text;

namespace MakePack;

/// <summary>Read-only text viewer (View): switchable code page, word wrap, font, find.</summary>
sealed class ViewerForm : Form
{
    // ponytail: only the first 16 MB is read and shown in a plain TextBox; a paged/memory-mapped view if huge logs matter.
    const int MaxBytes = 16 * 1024 * 1024;

    static ViewerForm() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    readonly byte[] _bytes;
    readonly TextBox _text;
    readonly List<(ToolStripMenuItem Item, Encoding Enc)> _encItems = [];
    string _find = "";
    bool _matchCase;

    ViewerForm(byte[] bytes, string title, bool truncated)
    {
        _bytes = bytes;
        Shown += (_, _) => _text!.Select(0, 0);   // the first focus selects everything in a TextBox
        Text = $"{title}{(truncated ? S.Truncated : "")} — {S.App}";
        Font = new Font("Segoe UI", 9.5f);
        ClientSize = new Size(900, 650);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { /* icon is optional */ }

        _text = new TextBox
        {
            Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, MaxLength = 0, WordWrap = false, HideSelection = false,
            ScrollBars = ScrollBars.Both, BackColor = SystemColors.Window, Font = new Font("Consolas", 10f),
        };

        var menu = new MenuStrip { RenderMode = ToolStripRenderMode.System };
        var file = new ToolStripMenuItem(S.MFile);
        file.DropDownItems.Add(new ToolStripMenuItem(S.Exit, null, (_, _) => Close()) { ShortcutKeyDisplayString = "Esc" });

        var edit = new ToolStripMenuItem(S.MEdit);
        edit.DropDownItems.AddRange([
            new ToolStripMenuItem(S.CopyCmd, null, (_, _) => _text.Copy(), Keys.Control | Keys.C),
            new ToolStripMenuItem(S.SelectAllItems, null, (_, _) => _text.SelectAll(), Keys.Control | Keys.A),
            new ToolStripSeparator(),
            new ToolStripMenuItem(S.FindText, null, (_, _) => AskFind(), Keys.Control | Keys.F),
            new ToolStripMenuItem(S.FindNext, null, (_, _) => { if (_find.Length == 0) AskFind(); else FindNext(); }, Keys.F3),
        ]);

        var view = new ToolStripMenuItem(S.MView);
        foreach (var (label, cp) in new[] { ("Windows (1251)", 1251), ("DOS (866)", 866), ("Unicode UTF-16LE", 1200), ("UTF-8", 65001) })
        {
            var enc = Encoding.GetEncoding(cp);
            var item = new ToolStripMenuItem(label, null, (_, _) => ShowAs(enc));
            _encItems.Add((item, enc));
            view.DropDownItems.Add(item);
        }
        var wrap = new ToolStripMenuItem(S.WordWrap, null, null, Keys.Control | Keys.W);
        wrap.Click += (_, _) =>
        {
            wrap.Checked = _text.WordWrap = !_text.WordWrap;
            _text.ScrollBars = _text.WordWrap ? ScrollBars.Vertical : ScrollBars.Both;
        };
        view.DropDownItems.AddRange([new ToolStripSeparator(), wrap, new ToolStripMenuItem(S.FontCmd, null, (_, _) => PickFont())]);

        menu.Items.AddRange([file, edit, view]);
        Controls.AddRange([_text, menu]);
        MainMenuStrip = menu;

        ShowAs(Detect(bytes));
    }

    public static void Open(IWin32Window? owner, string file, string title)
    {
        byte[] bytes;
        bool truncated;
        try
        {
            using var fs = File.OpenRead(file);
            truncated = fs.Length > MaxBytes;
            bytes = new byte[(int)Math.Min(fs.Length, MaxBytes)];
            fs.ReadExactly(bytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(owner, ex.Message, S.App, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        new ViewerForm(bytes, title, truncated).Show(owner);
    }

    /// <summary>BOM wins; else strict UTF-8 if the bytes are valid UTF-8; else Windows-1251.</summary>
    internal static Encoding Detect(byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble)) return Encoding.UTF8;
        if (bytes.AsSpan().StartsWith(Encoding.Unicode.Preamble)) return Encoding.Unicode;
        if (bytes.AsSpan().StartsWith(Encoding.BigEndianUnicode.Preamble)) return Encoding.BigEndianUnicode;
        try
        {
            // flush: false so a multi-byte char cut by the 16 MB ceiling does not count as invalid.
            new UTF8Encoding(false, true).GetDecoder().GetCharCount(bytes, 0, bytes.Length, flush: false);
            return Encoding.UTF8;
        }
        catch (DecoderFallbackException)
        {
            return Encoding.GetEncoding(1251);
        }
    }

    void ShowAs(Encoding enc)
    {
        var pre = enc.Preamble;
        int skip = _bytes.AsSpan().StartsWith(pre) ? pre.Length : 0;
        // TextBox stops at '\0' and needs CRLF to break lines.
        _text.Text = enc.GetString(_bytes, skip, _bytes.Length - skip).Replace('\0', ' ').ReplaceLineEndings("\r\n");
        foreach (var (item, e) in _encItems) item.Checked = e.CodePage == enc.CodePage;
    }

    void PickFont()
    {
        using var dlg = new FontDialog { Font = _text.Font, ShowEffects = false };
        if (dlg.ShowDialog(this) == DialogResult.OK) _text.Font = dlg.Font;
    }

    void AskFind()
    {
        using var f = new Form
        {
            Text = S.TbFind, Font = Font, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false, ClientSize = new Size(380, 104),
        };
        var box = new TextBox { Left = 12, Top = 14, Width = 356, Text = _find };
        var cs = new CheckBox { Left = 12, Top = 44, Width = 160, Text = S.MatchCase, Checked = _matchCase };
        var ok = new Button { Left = 176, Top = 64, Width = 94, Height = 28, Text = S.FindNext, DialogResult = DialogResult.OK, FlatStyle = FlatStyle.System };
        var cancel = new Button { Left = 274, Top = 64, Width = 94, Height = 28, Text = S.Cancel, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };
        f.Controls.AddRange([box, cs, ok, cancel]);
        f.AcceptButton = ok;
        f.CancelButton = cancel;
        if (f.ShowDialog(this) != DialogResult.OK || box.Text.Length == 0) return;
        (_find, _matchCase) = (box.Text, cs.Checked);
        FindNext();
    }

    /// <summary>Forward from the caret, wrapping to the top once.</summary>
    void FindNext()
    {
        var cmp = _matchCase ? StringComparison.Ordinal : StringComparison.CurrentCultureIgnoreCase;
        var text = _text.Text;
        int at = text.IndexOf(_find, Math.Min(_text.SelectionStart + _text.SelectionLength, text.Length), cmp);
        if (at < 0) at = text.IndexOf(_find, cmp);
        if (at < 0)
        {
            MessageBox.Show(this, string.Format(S.NotFoundFmt, _find), S.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        _text.Select(at, _find.Length);
        _text.ScrollToCaret();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

