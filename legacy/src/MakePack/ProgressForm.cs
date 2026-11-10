namespace MakePack;

/// <summary>Progress + cancel. Create it, then Run (modal) or RunAsync (modeless); errors are reported here.</summary>
sealed class ProgressForm : Form
{
    readonly Label _label;
    readonly ProgressBar _bar;
    readonly Button _cancel;
    readonly CancellationTokenSource _cts = new();
    bool _done;

    public ProgressForm(string title)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(460, 110);

        _label = new Label { Left = 12, Top = 12, Width = 436, Height = 34, AutoEllipsis = true, Text = title + "…" };
        _bar = new ProgressBar { Left = 12, Top = 48, Width = 436, Height = 20, Maximum = 100 };
        _cancel = new Button { Text = S.Cancel, Left = 348, Top = 76, Width = 100, Height = 26 };
        _cancel.Click += (_, _) => Cancel();
        Controls.AddRange([_label, _bar, _cancel]);
        CancelButton = _cancel;
    }

    void Cancel()
    {
        _cancel.Enabled = false;
        _cts.Cancel();
    }

    IProgress<(int percent, string file)> Reporter() => new Progress<(int percent, string file)>(p =>
    {
        _bar.Value = Math.Clamp(p.percent, 0, 100);
        _label.Text = string.IsNullOrEmpty(p.file) ? Text + "…" : Text + ": " + p.file;
    });

    /// <summary>Runs <paramref name="work"/> while the dialog is up. True = finished without cancel or error.</summary>
    public bool Run(IWin32Window? owner, Func<IProgress<(int percent, string file)>, CancellationToken, Task> work)
    {
        var ok = false;
        Exception? error = null;
        Shown += async (_, _) =>
        {
            var progress = Reporter();
            try { await work(progress, _cts.Token); ok = true; }
            catch (OperationCanceledException) { }
            catch (Exception ex) { error = ex; }
            _done = true;
            Close();
        };
        if (owner == null) ShowDialog(); else ShowDialog(owner);
        if (error != null) MessageBox.Show(owner, Engine.Friendly(error), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error);
        return ok;
    }

    /// <summary>
    /// Modeless twin of <see cref="Run"/> for the extract queue: ShowDialog would disable every other
    /// top-level window of the thread, freezing the main window while a queued job runs.
    /// </summary>
    public async Task<bool> RunAsync(IWin32Window? owner, Func<IProgress<(int percent, string file)>, CancellationToken, Task> work)
    {
        StartPosition = FormStartPosition.CenterScreen;   // CenterParent is a modal-only setting
        if (owner == null) Show(); else Show(owner);
        try { await work(Reporter(), _cts.Token); return true; }
        catch (OperationCanceledException) { return false; }
        catch (Exception ex)
        {
            MessageBox.Show(this, Engine.Friendly(ex), S.Error, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        finally { _done = true; Close(); }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_done) { e.Cancel = true; Cancel(); }   // X / Esc cancels the job instead of orphaning it
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _cts.Dispose();
        base.Dispose(disposing);
    }
}
