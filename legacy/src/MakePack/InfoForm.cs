namespace MakePack;

/// <summary>Archive properties (Show information): a two-column list and a Copy button.</summary>
sealed class InfoForm : Form
{
    InfoForm(Archive a)
    {
        var rows = Engine.Describe(a);
        Text = string.Format(S.InfoTitleFmt, a.Display);
        Font = new Font("Segoe UI", 9.5f);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        ClientSize = new Size(560, 400);
        MinimumSize = new Size(400, 300);

        var list = new ListView
        {
            Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable,
            UseCompatibleStateImageBehavior = false,
        };
        list.Columns.Add(S.Property, 160);
        list.Columns.Add(S.Value, 370);
        foreach (var (label, value) in rows) list.Items.Add(new ListViewItem([label, value]));

        var copy = new Button { Text = S.CopyButton, Width = 110, Height = 28, FlatStyle = FlatStyle.System };
        copy.Click += (_, _) => MainForm.ToClipboard(string.Join(Environment.NewLine, rows.Select(r => $"{r.Label}: {r.Value}")));
        var close = new Button { Text = S.Close, Width = 94, Height = 28, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8, 6, 8, 6) };
        bottom.Controls.AddRange([close, copy]);

        Controls.AddRange([list, bottom]);
        CancelButton = close;
    }

    public static void Show(IWin32Window owner, Archive a)
    {
        using var f = new InfoForm(a);
        f.ShowDialog(owner);
    }
}
