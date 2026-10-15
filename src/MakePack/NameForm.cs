namespace MakePack;

/// <summary>Asks for a profile name (and, when saving one, whether it is the default).</summary>
sealed class NameForm : Form
{
    readonly TextBox _name;
    readonly CheckBox? _default, _menu;

    NameForm(string title, string name, bool? isDefault, bool inMenu)
    {
        Text = title;
        Font = new Font("Segoe UI", 9.5f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = ShowInTaskbar = false;
        ClientSize = new Size(380, isDefault == null ? 110 : 164);

        var lbl = new Label { Left = 12, Top = 12, Width = 356, Text = S.ProfileName };
        _name = new TextBox { Left = 12, Top = 36, Width = 356, Text = name };
        Controls.AddRange([lbl, _name]);
        if (isDefault != null)
        {
            _default = new CheckBox { Left = 12, Top = 68, Width = 356, Text = S.DefaultProfile, Checked = isDefault.Value };
            _menu = new CheckBox { Left = 12, Top = 92, Width = 356, Text = S.ProfileInMenu, Checked = inMenu };
            Controls.AddRange([_default, _menu]);
        }
        var ok = new Button { Left = 176, Top = ClientSize.Height - 40, Width = 94, Height = 28, Text = S.Ok, DialogResult = DialogResult.OK, FlatStyle = FlatStyle.System };
        var cancel = new Button { Left = 274, Top = ClientSize.Height - 40, Width = 94, Height = 28, Text = S.Cancel, DialogResult = DialogResult.Cancel, FlatStyle = FlatStyle.System };
        // A quote would end the name early in the menu's command line (a --profile "name").
        bool Valid() => _name.Text.Trim().Length > 0 && !_name.Text.Contains('"');
        _name.TextChanged += (_, _) => ok.Enabled = Valid();
        ok.Enabled = Valid();
        Controls.AddRange([ok, cancel]);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    /// <param name="isDefault">null = no default / in-menu boxes (renaming).</param>
    public static (string Name, bool IsDefault, bool InMenu)? Ask(IWin32Window owner, string title, string name, bool? isDefault, bool inMenu = false)
    {
        using var f = new NameForm(title, name, isDefault, inMenu);
        return f.ShowDialog(owner) == DialogResult.OK ? (f._name.Text.Trim(), f._default?.Checked ?? false, f._menu?.Checked ?? false) : null;
    }
}
