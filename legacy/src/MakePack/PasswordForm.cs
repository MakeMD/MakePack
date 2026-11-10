namespace MakePack;

sealed class PasswordForm : Form
{
    readonly TextBox _box;

    PasswordForm(string title, string prompt)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(360, 132);

        var label = new Label { Left = 12, Top = 12, Width = 336, Height = 52, Text = prompt };
        _box = new TextBox { Left = 12, Top = 68, Width = 336, UseSystemPasswordChar = true };
        var ok = new Button { Text = S.Ok, Left = 168, Top = 98, Width = 88, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = S.Cancel, Left = 260, Top = 98, Width = 88, DialogResult = DialogResult.Cancel };
        Controls.AddRange([label, _box, ok, cancel]);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    public static string? Ask(IWin32Window? owner, string title, string? prompt = null)
    {
        using var f = new PasswordForm(title, prompt ?? S.EnterPassword);
        var r = owner == null ? f.ShowDialog() : f.ShowDialog(owner);
        return r == DialogResult.OK ? f._box.Text : null;
    }

    static Archive? Fail(IWin32Window? owner, string text)
    {
        MessageBox.Show(owner, text, S.CannotOpen, MessageBoxButtons.OK, MessageBoxIcon.Error);
        return null;
    }

    /// <summary>
    /// Opens an archive. Missing, not an archive, damaged and "needs a password" are four different
    /// answers and each gets its own; a wrong password re-asks until the user gives up, as 7-Zip does.
    /// </summary>
    public static Archive? OpenArchive(IWin32Window? owner, string path) => OpenArchive(owner, path, out _);

    /// <param name="exit">Why it returned null, as an exit code (Engine.ExitCodeOf); 255 = the user cancelled.</param>
    public static Archive? OpenArchive(IWin32Window? owner, string path, out int exit)
    {
        exit = 255;
        if (!File.Exists(path)) { exit = 10; return Fail(owner, string.Format(S.FileNotFoundFmt, path)); }

        string? password = null;
        switch (Engine.Probe(path))
        {
            case Probe.NotArchive: exit = 2; return Fail(owner, S.NotAnArchive);      // a password could not help: never prompt
            case Probe.Damaged: exit = 3; return Fail(owner, S.Damaged);
            case Probe.EncryptedHeaders:
                password = Ask(owner, Path.GetFileName(path));
                if (password == null) return null;
                break;
        }

        while (true)
        {
            try { return Engine.Open(path, password); }
            catch (Exception ex)
            {
                // ponytail: an intact 7z/rar that will not open IS the encrypted-headers case - telling it
                // apart for real means unpacking the packed header ourselves. The price: an archive in a
                // codec 7z.dll cannot handle is reported here as a wrong password.
                if (!Engine.CanEncryptHeaders(path)) { exit = Engine.ExitCodeOf(ex); return Fail(owner, Engine.Friendly(ex)); }
                password = Ask(owner, Path.GetFileName(path), password == null ? S.EnterPassword : S.WrongPasswordRetry);
                if (password == null) return null;
            }
        }
    }

    /// <summary>
    /// Bodies can be encrypted while the header is not: such an archive lists fine and only fails mid-extract.
    /// Returns the archive to use (a NEW instance when a password was needed - the caller owns both) or null.
    /// </summary>
    public static Archive? EnsurePassword(IWin32Window? owner, Archive a)
    {
        if (a.Password != null || !a.X.ArchiveFileData.Any(f => f.Encrypted)) return a;
        var password = Ask(owner, a.Display);
        if (password == null) return null;
        try { return Engine.Open(a.Source, password); }
        catch (Exception ex)
        {
            MessageBox.Show(owner, Engine.Friendly(ex), S.CannotOpen, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return null;
        }
    }
}
