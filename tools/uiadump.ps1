# Moves a process's top-level window to \\.\DISPLAY<n>, dumps its UIA tree to <Out>.txt and a screenshot to <Out>.png.
# Usage: tools\uiadump.ps1 -ProcessName notepad -Out C:\tmp\notepad [-Class Notepad] [-Screen 1] [-Depth 7] [-Resize]
# Pure ASCII (PS 5.1).
param([Parameter(Mandatory)][string]$ProcessName, [Parameter(Mandatory)][string]$Out,
      [string]$Class = '', [int]$Screen = 1, [int]$Depth = 7, [switch]$Resize)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
if (-not ('Mp.Win2' -as [type])) {
    Add-Type -Namespace Mp -Name Win2 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
[DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
// Windows refuses SetForegroundWindow to a process that is not in front; sharing the front thread's input state lets it through.
public static void Front(IntPtr h)
{
    uint me = GetCurrentThreadId(), fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    bool attached = fg != me && AttachThreadInput(me, fg, true);
    try { BringWindowToTop(h); SetForegroundWindow(h); }
    finally { if (attached) AttachThreadInput(me, fg, false); }
}
'@
}
$A = [System.Windows.Automation.AutomationElement]
$p = Get-Process $ProcessName -ErrorAction Stop | Select-Object -First 1
$cond = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, [int]$p.Id)
$win = $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) |
    Where-Object { -not $Class -or $_.Current.ClassName -eq $Class } | Select-Object -First 1
if (-not $win) { throw "no window for $ProcessName $Class" }
$h = [IntPtr]$win.Current.NativeWindowHandle

$mon = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like "*DISPLAY$Screen" } | Select-Object -First 1
if ($mon) {
    $wa = $mon.WorkingArea
    $r0 = $win.Current.BoundingRectangle
    if ($Resize -or -not $wa.Contains([int]$r0.X + 8, [int]$r0.Y + 8)) {
        [void][Mp.Win2]::ShowWindow($h, 9)   # SW_RESTORE
        # -Resize: 1100x700, comparable shots; otherwise only moved, so a dialog keeps its size
        [void][Mp.Win2]::SetWindowPos($h, [IntPtr]::Zero, $wa.X + 40, $wa.Y + 40, 1100, 700, $(if ($Resize) { 0x0004 } else { 0x0005 }))   # NOZORDER (| NOSIZE)
    }
    [Mp.Win2]::Front($h)
    Start-Sleep -Milliseconds 600
}

function RectOf($r) { if ([double]::IsInfinity($r.X)) { return 'offscreen' } "$([int]$r.X),$([int]$r.Y),$([int]$r.Width),$([int]$r.Height)" }
$sb = New-Object System.Text.StringBuilder
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
function Dump($e, $d) {
    if ($d -gt $Depth) { return }
    $c = $e.Current
    [void]$sb.AppendLine(('  ' * $d) + "$($c.ControlType.ProgrammaticName) [$($c.ClassName)] '$($c.Name)' id=$($c.AutomationId) rect=$(RectOf $c.BoundingRectangle)")
    $ch = $walker.GetFirstChild($e); $n = 0
    while ($ch -ne $null -and $n -lt 40) { Dump $ch ($d + 1); $ch = $walker.GetNextSibling($ch); $n++ }
}
Dump $win 0
$sb.ToString() | Out-File "$Out.txt" -Encoding utf8

$r = $win.Current.BoundingRectangle
$bmp = New-Object System.Drawing.Bitmap([int]$r.Width, [int]$r.Height)
[System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
$bmp.Save("$Out.png")
"saved $Out.txt / .png ($(RectOf $r))"
