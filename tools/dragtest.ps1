# MakePack drag-and-drop smoke with REAL mouse input (SendInput), both directions. Pure ASCII. PowerShell 5.1.
#
#   *** MANUAL ONLY ***  It moves the real mouse pointer and presses the real left button. Run it yourself, by hand,
#   when nobody (no person, no agent, no other test) is using this desktop, and never from bugtest.ps1, CI or an
#   automation session. Over RDP it moves the pointer of the remote session.
#
# Usage: tools\dragtest.ps1 [-Exe <path>] [-Screen <n>]
# Opens its own Explorer window and its own MakePack windows side by side on \\.\DISPLAY<Screen>, drags between
# them and checks the result on disk. Closes only the windows it opened. Screenshots: zig-out\shots\drag-*.png.
# The ImGui window has no accessibility tree and MakeKit automation ignores real input, so it measures the layout
# first in an automation run (MAKEKIT_AUTOMATION=1, read-only), then drags in a plain run with the same saved
# window bounds. Foreground guard: before every press the window under the start point and under the drop point
# must belong to the expected process (our Explorer window / our MakePack) and our window must be in front;
# otherwise it stops without sending anything - stray input must never land in the user's apps.
# Sandbox: private MAKEPACK_INSTANCE, MAKEPACK_SETTINGS and MAKEPACK_REGROOT, files only in %TEMP%\makepack-test-*.
param([string]$Exe = "$PSScriptRoot\..\zig-out\bin\MakePack.exe", [ValidateRange(1, 9)][int]$Screen = 1)

$ErrorActionPreference = 'Stop'
$env:MAKEKIT_NO_UPDATE = '1'   # no update check from any test process (MakeKit K11)
if (-not ('Mp.Mouse' -as [type])) {
    Add-Type -Namespace Mp -Name Mouse -UsingNamespace System.Text, System.Threading, System.Collections.Generic -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
[StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
[DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
[DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

public static long[] TopWindows(string cls) {
    var r = new List<long>();
    EnumWindows((h, l) => {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        if (sb.ToString() == cls && IsWindowVisible(h)) r.Add(h.ToInt64());
        return true;
    }, IntPtr.Zero);
    return r.ToArray();
}

// The top-level window under a screen point, and its process.
public static long RootAt(int x, int y) { var p = new POINT { X = x, Y = y }; return GetAncestor(WindowFromPoint(p), 2).ToInt64(); }
public static uint PidOf(long h) { uint pid; GetWindowThreadProcessId(new IntPtr(h), out pid); return pid; }

static void Send(int x, int y, uint flags) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    var i = new INPUT[1];
    i[0].type = 0;
    i[0].mi.dx = (int)(((long)(x - vx) * 65535 + (vw - 1) / 2) / (vw - 1));
    i[0].mi.dy = (int)(((long)(y - vy) * 65535 + (vh - 1) / 2) / (vh - 1));
    i[0].mi.flags = flags | 0x0001 | 0x8000 | 0x4000;   // MOVE | ABSOLUTE | VIRTUALDESK
    SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
}

// No click first: click + press is a double-click, which opens the file. The press itself selects the item.
// Press, creep past the drag threshold in small steps, glide over, hover so the target sees DragOver, release.
public static void Drag(int x1, int y1, int x2, int y2) {
    Send(x1, y1, 0); Thread.Sleep(200);
    Send(x1, y1, 0x0002); Thread.Sleep(250);                      // LEFTDOWN
    for (int k = 1; k <= 12; k++) { Send(x1 + k, y1 + k / 2, 0); Thread.Sleep(15); }
    int sx = x1 + 12, sy = y1 + 6, steps = 50;
    for (int k = 1; k <= steps; k++) { Send(sx + (x2 - sx) * k / steps, sy + (y2 - sy) * k / steps, 0); Thread.Sleep(15); }
    for (int k = 0; k < 20; k++) { Send(x2 + (k % 2), y2, 0); Thread.Sleep(30); }
    Send(x2, y2, 0x0004);                                         // LEFTUP
}
'@
}
[void][Mp.Mouse]::SetProcessDpiAwarenessContext([IntPtr](-4))   # per-monitor v2: UIA / ImGui pixels == SendInput pixels
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
Set-StrictMode -Off

$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$SevenZ = (Resolve-Path (Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe')).Path
$Shots = Join-Path $PSScriptRoot '..\zig-out\shots'
New-Item -ItemType Directory -Force $Shots | Out-Null
$script:fails = 0
$script:explorer = [IntPtr]::Zero
$script:procs = New-Object System.Collections.ArrayList

$mon = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like "*DISPLAY$Screen" } | Select-Object -First 1
if (-not $mon) { throw "no \\.\DISPLAY$Screen" }
$wa = $mon.WorkingArea
$half = [int]($wa.Width / 2)
$mpRect = @($wa.Left, $wa.Top, ($half - 10), ($wa.Height - 40))                 # MakePack: left half
$exRect = @(($wa.Left + $half), $wa.Top, ($half - 10), ($wa.Height - 40))     # Explorer: right half

$rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP ('makepack-test-drag-' + $rand)
$cfg = Join-Path $root 'settings.json'
$reg = "Software\MakePackTest-$rand"
$envs = @{ MAKEPACK_INSTANCE = "MakePack-dragtest-$rand"; MAKEPACK_SETTINGS = $cfg; MAKEPACK_REGROOT = $reg; MAKEKIT_DISPLAY = "\\.\DISPLAY$Screen" }

function Log([string]$s) { Write-Host $s }
function Pass([string]$s) { Write-Host ("PASS " + $s) }
function Fail([string]$s) { Write-Host ("FAIL " + $s); $script:fails++ }

function Wait-For([scriptblock]$Cond, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        $r = $null
        try { $r = & $Cond } catch { }
        if ($r) { return $r }
        Start-Sleep -Milliseconds 250
    }
    $null
}

function Shot([string]$name) {
    try {
        $b = New-Object System.Drawing.Bitmap $wa.Width, $wa.Height
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($wa.Left, $wa.Top, 0, 0, $b.Size)
        $g.Dispose()
        $b.Save((Join-Path $Shots ("drag-" + $name + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    } catch { Log ("  (screenshot failed: " + $_.Exception.Message + ")") }
}

function Settings-Json { '{ "Window": [' + ($mpRect -join ',') + '], "Maximized": false }' }

# A plain MakePack (real input on): the run that receives the drags.
function Start-Mp([string[]]$A) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($A) | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    foreach ($k in $envs.Keys) { $psi.EnvironmentVariables[$k] = [string]$envs[$k] }
    $psi.EnvironmentVariables.Remove('MAKEKIT_AUTOMATION')
    $p = [System.Diagnostics.Process]::Start($psi)
    [void]$script:procs.Add($p)
    $h = Wait-For { $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $p.MainWindowHandle } } 15
    if (-not $h) { throw "MakePack (pid $($p.Id)) showed no window" }
    $p
}

# The layout run: the same settings and arguments with automation on; returns screen rects of the wanted items
# (name -> @(x0,y0,x1,y1)) and of the file list, then quits (which saves the same window bounds back).
function Measure-Mp([string[]]$A, [string[]]$Ids) {
    [IO.File]::WriteAllText($cfg, (Settings-Json))
    $app = Start-AutoApp -Exe $Exe -Args $A -Env $envs
    try {
        $null = Wait-AutoItem $app '###status' 15000
        foreach ($id in $Ids) { $null = Wait-AutoItem $app $id 10000 }
        $null = Invoke-AutoFrames $app 5
        $app.Process.Refresh()
        $pt = New-Object Mp.Mouse+POINT
        [void][Mp.Mouse]::ClientToScreen($app.Process.MainWindowHandle, [ref]$pt)
        $out = @{}
        foreach ($it in (Get-AutoItems $app)) { foreach ($id in $Ids) { if ($it.label.EndsWith($id)) { $out[$id] = @(($pt.X + $it.x0), ($pt.Y + $it.y0), ($pt.X + $it.x1), ($pt.Y + $it.y1)) } } }
        $list = @(Get-AutoItems $app -Windows | Where-Object { $_.name -like '*##files_*' }) | Select-Object -First 1
        if ($list) { $out['list'] = @(($pt.X + $list.x0), ($pt.Y + $list.y0), ($pt.X + $list.x1), ($pt.Y + $list.y1)) }
        $out
    } finally { $null = Stop-AutoApp $app }
}

function Close-App($p) {
    if ($p -and -not $p.HasExited) {
        [void][Mp.Mouse]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE: temp folders go
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch { } }
    }
}

# The foreground guard: start and drop point over the expected top-level windows, and one of ours in front.
function Guarded-Drag([int]$x1, [int]$y1, [long]$fromHwnd, [int]$x2, [int]$y2, [long]$toHwnd, [string]$what) {
    $a = [Mp.Mouse]::RootAt($x1, $y1); $b = [Mp.Mouse]::RootAt($x2, $y2)
    if ($a -ne $fromHwnd -or $b -ne $toHwnd) {
        throw ("guard: " + $what + ": the windows under the pointer are not ours (start " + $a + " pid " + [Mp.Mouse]::PidOf($a) +
            ", drop " + $b + " pid " + [Mp.Mouse]::PidOf($b) + ") - stopped before any input")
    }
    [void][Mp.Mouse]::SetForegroundWindow([IntPtr]$fromHwnd)
    Start-Sleep -Milliseconds 300
    $fg = [Mp.Mouse]::GetForegroundWindow().ToInt64()
    if ($fg -ne $fromHwnd -and $fg -ne $toHwnd) { throw ("guard: " + $what + ": foreground is pid " + [Mp.Mouse]::PidOf($fg) + ", not ours - stopped before any input") }
    [Mp.Mouse]::Drag($x1, $y1, $x2, $y2)
}

function Find-ExItem($root, [string[]]$Names) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, $CT::ListItem)
    foreach ($e in $root.FindAll($TS::Descendants, $cond)) { if ($Names -contains $e.Current.Name) { return $e } }
    $null
}
# A point on the item's name: past the icon, vertically centred.
function Grip($r) { @([int]($r[0] + 28), [int](($r[1] + $r[3]) / 2)) }
function ExRect($el) { $r = $el.Current.BoundingRectangle; @($r.X, $r.Y, $r.Right, $r.Bottom) }

function Archive-Has([string]$arc, [string]$name) {
    $out = & $SevenZ l -ba $arc 2>$null
    [bool]($out | Where-Object { $_ -match ('\s' + [regex]::Escape($name) + '$') })
}

# ---------- fixtures ----------
$folder = Join-Path $root 'dragbox'
$src = Join-Path $root 'src'
New-Item -ItemType Directory -Force -Path $folder, (Join-Path $src 'dir\sub') | Out-Null
Set-Content -LiteralPath (Join-Path $folder 'in1.txt') -Value 'in one' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $folder 'in2.txt') -Value 'in two' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $src 'inside.txt') -Value 'inside content' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $src 'dir\child.txt') -Value 'child content' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $src 'dir\sub\deep.txt') -Value 'deep content' -Encoding ASCII
$box = Join-Path $folder 'box.7z'
Push-Location $src
try { & $SevenZ a -t7z $box * -bso0 -bsp0 | Out-Null } finally { Pop-Location }
if (-not (Test-Path -LiteralPath $box)) { throw "fixture box.7z was not created" }
Log ("exe   : " + $Exe)
Log ("folder: " + $folder)

$p = $null
try {
    # ---------- Explorer window of our own ----------
    $before = [Mp.Mouse]::TopWindows('CabinetWClass')
    Start-Process explorer.exe -ArgumentList ('"' + $folder + '"')
    $hw = Wait-For { [Mp.Mouse]::TopWindows('CabinetWClass') | Where-Object { $before -notcontains $_ } | Select-Object -First 1 } 15
    if (-not $hw) { throw "no NEW Explorer window appeared (did it open as a tab in an existing one?) - aborting without touching other windows" }
    $script:explorer = [IntPtr]$hw
    $exEl = $AT::FromHandle($script:explorer)
    [void][Mp.Mouse]::ShowWindow($script:explorer, 9)
    [void][Mp.Mouse]::MoveWindow($script:explorer, $exRect[0], $exRect[1], $exRect[2], $exRect[3], $true)
    $in1 = Wait-For { Find-ExItem $exEl @('in1.txt', 'in1') } 15
    if (-not $in1) { throw "in1.txt not found in the Explorer window via UI Automation" }
    $viewCond = New-Object System.Windows.Automation.PropertyCondition($AT::ClassNameProperty, 'UIItemsView')
    $view = $exEl.FindFirst($TS::Descendants, $viewCond)
    if (-not $view) { throw "the Explorer items view was not found" }
    $vr = $view.Current.BoundingRectangle
    $exEmpty = @([int]($vr.X + $vr.Width * 0.6), [int]($vr.Bottom - 60))
    $exH = $script:explorer.ToInt64()

    # ---------- IN: Explorer -> archive window ----------
    $m = Measure-Mp @($box) @('inside.txt###r', 'dir###r')
    if (-not $m['list']) { throw "the layout run found no file list" }
    $p = Start-Mp @($box)
    $mpH = $p.MainWindowHandle.ToInt64()
    $l = $m['list']
    $mpEmpty = @([int](($l[0] + $l[2]) / 2), [int]($l[1] + ($l[3] - $l[1]) * 0.8))
    $g = Grip (ExRect $in1)
    Guarded-Drag $g[0] $g[1] $exH $mpEmpty[0] $mpEmpty[1] $mpH 'in'
    $ok = Wait-For { Archive-Has $box 'in1.txt' } 15
    Shot 'in-archive'
    if ($ok) { Pass "in: Explorer -> archive window (in1.txt is in box.7z)" } else { Fail "in: in1.txt did not get into box.7z (see drag-in-archive.png)" }
    Close-App $p

    # ---------- OUT: archive window -> Explorer (the list was re-measured: in1.txt is a new row) ----------
    $m = Measure-Mp @($box) @('inside.txt###r', 'dir###r')
    $p = Start-Mp @($box)
    $mpH = $p.MainWindowHandle.ToInt64()
    if (-not $m['inside.txt###r']) { Fail "out: inside.txt not in the MakePack list" } else {
        $g = Grip $m['inside.txt###r']
        Guarded-Drag $g[0] $g[1] $mpH $exEmpty[0] $exEmpty[1] $exH 'out file'
        $target = Join-Path $folder 'inside.txt'
        $ok = Wait-For { (Test-Path -LiteralPath $target) -and ((Get-Content -LiteralPath $target -Raw).Trim() -eq 'inside content') } 10
        Shot 'out-file'
        if ($ok) { Pass "out: file dragged to Explorer (inside.txt, right content)" } else { Fail ("out: inside.txt did not appear in the folder; folder has [" + ((Get-ChildItem -LiteralPath $folder | ForEach-Object { $_.Name }) -join ',') + "]") }
    }
    if (-not $m['dir###r']) { Fail "out: folder 'dir' not in the MakePack list" } else {
        $g = Grip $m['dir###r']
        Guarded-Drag $g[0] $g[1] $mpH $exEmpty[0] $exEmpty[1] $exH 'out folder'
        $ok = Wait-For {
            ((Get-Content -LiteralPath (Join-Path $folder 'dir\child.txt') -Raw).Trim() -eq 'child content') -and
            ((Get-Content -LiteralPath (Join-Path $folder 'dir\sub\deep.txt') -Raw).Trim() -eq 'deep content')
        } 10
        Shot 'out-folder'
        if ($ok) { Pass "out: folder dragged to Explorer (dir\child.txt, dir\sub\deep.txt)" } else { Fail ("out: folder dir did not arrive complete; folder has [" + ((Get-ChildItem -LiteralPath $folder -Recurse | ForEach-Object { $_.Name }) -join ',') + "]") }
    }
    Close-App $p

    # ---------- IN: Explorer -> empty window = new archive dialog (checked on the screenshot) ----------
    [IO.File]::WriteAllText($cfg, (Settings-Json))
    $p = Start-Mp @()
    $mpH = $p.MainWindowHandle.ToInt64()
    $in2 = Find-ExItem $exEl @('in2.txt', 'in2')
    $g = Grip (ExRect $in2)
    $c = @([int]($mpRect[0] + $mpRect[2] / 2), [int]($mpRect[1] + $mpRect[3] * 0.6))
    Guarded-Drag $g[0] $g[1] $exH $c[0] $c[1] $mpH 'in empty'
    Start-Sleep -Seconds 2
    Shot 'in-empty'
    Log "CHECK by eye: drag-in-empty.png must show the New archive dialog with in2.txt (ImGui windows are not visible to UIA)"
    $p.Refresh()
    try { Stop-Process -Id $p.Id -Force } catch { }   # the dialog vetoes WM_CLOSE
    $p = $null
} catch {
    Fail ("setup: " + $_.Exception.Message + " [line " + $_.InvocationInfo.ScriptLineNumber + "]")
    Shot 'error'
} finally {
    if ($p) { Close-App $p }
    foreach ($x in $script:procs) { try { if (-not $x.HasExited) { $x.Kill() } } catch { } }
    if ($script:explorer -ne [IntPtr]::Zero -and [Mp.Mouse]::IsWindow($script:explorer)) {
        [void][Mp.Mouse]::PostMessage($script:explorer, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE, our window only
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "HKCU:\$reg" -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
if ($script:fails -eq 0) { Write-Host "DRAGTEST: ALL OK"; exit 0 }
Write-Host ("DRAGTEST: " + $script:fails + " FAILED"); exit 1
