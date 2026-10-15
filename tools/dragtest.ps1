# MakePack drag-and-drop smoke with REAL mouse input (SendInput), both directions. Pure ASCII. PowerShell 5.1.
# Usage: tools\dragtest.ps1 [-Exe <path>]
# Opens its own Explorer window and its own MakePack windows side by side on the primary screen, drags between
# them and checks the result on disk. Closes only the windows it opened. Screenshots: dist\drag-*.png.
param([string]$Exe = "$PSScriptRoot\..\dist\publish\MakePack.exe")

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
if (-not ('Mp.Mouse' -as [type])) {
    Add-Type -Namespace Mp -Name Mouse -UsingNamespace System.Text, System.Threading, System.Collections.Generic -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
[StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
[DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
[DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
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
[void][Mp.Mouse]::SetProcessDpiAwarenessContext([IntPtr](-4))   # per-monitor v2: UIA rects == SendInput pixels

$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$SevenZ = (Resolve-Path (Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe')).Path
$Dist = (Resolve-Path (Join-Path $PSScriptRoot '..\dist')).Path
$script:fails = 0
$script:explorer = [IntPtr]::Zero

function Log([string]$s) { Write-Host $s }
function Pass([string]$s) { Write-Host ("PASS " + $s) }
function Fail([string]$s) { Write-Host ("FAIL " + $s); $script:fails++ }

function Kill-App { Get-Process MakePack -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 400 }

# Graceful first: the app deletes its drag temp folders on a normal exit only.
function Close-App($p) {
    if ($p -and -not $p.HasExited) {
        foreach ($w in (Uia-Windows $p.Id)) { try { [void][Mp.Mouse]::PostMessage([IntPtr]$w.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } catch { } }
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch { } }
    }
    Kill-App
}

function Uia-Windows([int]$ProcId) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $ProcId)
    @($AT::RootElement.FindAll($TS::Children, $cond))
}

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

function Main-Window($p, [string]$TitleLike) {
    Wait-For {
        foreach ($w in (Uia-Windows $p.Id)) { if ($w.Current.Name -like $TitleLike) { return $w } }
    } 15
}

function Find-Item($root, [string[]]$Names) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, $CT::ListItem)
    foreach ($e in $root.FindAll($TS::Descendants, $cond)) {
        if ($Names -contains $e.Current.Name) { return $e }
    }
    $null
}

# A point on the item's name: past the icon, vertically centred.
function Grip($el) {
    $r = $el.Current.BoundingRectangle
    @([int]($r.X + 28), [int]($r.Y + $r.Height / 2))
}

function Shot([string]$name) {
    try {
        $b = New-Object System.Drawing.Bitmap 2560, 1040
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen(0, 0, 0, 0, $b.Size)
        $g.Dispose()
        $b.Save((Join-Path $Dist ("drag-" + $name + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
    } catch { Log ("  (screenshot failed: " + $_.Exception.Message + ")") }
}

function Start-Mp([string[]]$A) {
    Kill-App
    if ($A) { Start-Process -FilePath $Exe -ArgumentList $A -PassThru } else { Start-Process -FilePath $Exe -PassThru }
}

function Place($winEl, [int]$x) {
    $h = [IntPtr]$winEl.Current.NativeWindowHandle
    [void][Mp.Mouse]::ShowWindow($h, 9)   # SW_RESTORE
    [void][Mp.Mouse]::MoveWindow($h, $x, 0, 1270, 1000, $true)
    Start-Sleep -Milliseconds 400
}

function Archive-Has([string]$arc, [string]$name) {
    $out = & $SevenZ l -ba $arc 2>$null
    [bool]($out | Where-Object { $_ -match ('\s' + [regex]::Escape($name) + '$') })
}

# ---------- fixtures ----------
$root = Join-Path $env:TEMP ('MakePack-dragtest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
    [void][Mp.Mouse]::MoveWindow($script:explorer, 1285, 0, 1270, 1000, $true)
    $in1 = Wait-For { Find-Item $exEl @('in1.txt', 'in1') } 15
    if (-not $in1) { throw "in1.txt not found in the Explorer window via UI Automation" }
    $viewCond = New-Object System.Windows.Automation.PropertyCondition($AT::ClassNameProperty, 'UIItemsView')
    $view = $exEl.FindFirst($TS::Descendants, $viewCond)
    if (-not $view) { throw "the Explorer items view was not found" }
    $vr = $view.Current.BoundingRectangle
    $exEmpty = @([int]($vr.X + $vr.Width * 0.6), [int]($vr.Bottom - 60))

    # ---------- IN: Explorer -> archive window ----------
    $p = Start-Mp @('"' + $box + '"')
    $mw = Main-Window $p '*box.7z*'
    if (-not $mw) { throw "MakePack main window with box.7z did not appear" }
    Place $mw 0
    $lr = ($mw.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, $CT::List)))).Current.BoundingRectangle
    $mpEmpty = @([int]($lr.X + $lr.Width / 2), [int]($lr.Y + $lr.Height * 0.7))
    $g = Grip $in1
    [Mp.Mouse]::Drag($g[0], $g[1], $mpEmpty[0], $mpEmpty[1])
    $ok = Wait-For { Archive-Has $box 'in1.txt' } 15
    Shot 'in-archive'
    if ($ok) { Pass "in: Explorer -> archive window (in1.txt is in box.7z)" } else { Fail ("in: in1.txt did not get into box.7z; windows: " + ((Uia-Windows $p.Id | ForEach-Object { $_.Current.Name }) -join ' | ')) }

    # ---------- OUT: archive window -> Explorer ----------
    $mw = Main-Window $p '*box.7z*'
    $item = Wait-For { Find-Item $mw @('inside.txt') } 10
    if (-not $item) { Fail "out: inside.txt not in the MakePack list" } else {
        $g = Grip $item
        [Mp.Mouse]::Drag($g[0], $g[1], $exEmpty[0], $exEmpty[1])
        $target = Join-Path $folder 'inside.txt'
        $ok = Wait-For { (Test-Path -LiteralPath $target) -and ((Get-Content -LiteralPath $target -Raw).Trim() -eq 'inside content') } 10
        Shot 'out-file'
        if ($ok) { Pass "out: file dragged to Explorer (inside.txt, right content)" } else { Fail ("out: inside.txt did not appear in the folder; folder has [" + ((Get-ChildItem -LiteralPath $folder | ForEach-Object { $_.Name }) -join ',') + "]; windows: " + ((Uia-Windows $p.Id | ForEach-Object { $_.Current.Name }) -join ' | ')) }
    }
    $item = Wait-For { Find-Item $mw @('dir') } 10
    if (-not $item) { Fail "out: folder 'dir' not in the MakePack list" } else {
        $g = Grip $item
        [Mp.Mouse]::Drag($g[0], $g[1], $exEmpty[0], $exEmpty[1])
        $ok = Wait-For {
            ((Get-Content -LiteralPath (Join-Path $folder 'dir\child.txt') -Raw).Trim() -eq 'child content') -and
            ((Get-Content -LiteralPath (Join-Path $folder 'dir\sub\deep.txt') -Raw).Trim() -eq 'deep content')
        } 10
        Shot 'out-folder'
        if ($ok) { Pass "out: folder dragged to Explorer (dir\child.txt, dir\sub\deep.txt)" } else { Fail ("out: folder dir did not arrive complete; folder has [" + ((Get-ChildItem -LiteralPath $folder -Recurse | ForEach-Object { $_.Name }) -join ',') + "]") }
    }
    Close-App $p

    # ---------- IN: Explorer -> empty window = new archive dialog ----------
    $p = Start-Mp @()
    $mw = Main-Window $p 'MakePack'
    if (-not $mw) { throw "empty MakePack window did not appear" }
    Place $mw 0
    $in2 = Find-Item $exEl @('in2.txt', 'in2')
    $g = Grip $in2
    [Mp.Mouse]::Drag($g[0], $g[1], 640, 500)
    $dlg = Wait-For { foreach ($w in (Uia-Windows $p.Id)) { if ($w.Current.Name -match '^(New archive|' + [regex]::Escape((@([char]0x041D, [char]0x043E, [char]0x0432, [char]0x0438, [char]0x0439) -join '')) + ')') { return $w } } } 10
    if (-not $dlg) { $dlg = Wait-For { foreach ($w in (Uia-Windows $p.Id)) { foreach ($k in $w.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) { if ($k.Current.ControlType -eq $CT::Window) { return $k } } } } 3 }
    Shot 'in-empty'
    if ($dlg) { Pass ("in: Explorer -> empty window opened '" + $dlg.Current.Name + "'") } else { Fail ("in: no new-archive dialog; windows: " + ((Uia-Windows $p.Id | ForEach-Object { $_.Current.Name }) -join ' | ')) }
    Close-App $p
    $p = $null
} catch {
    Fail ("setup: " + $_.Exception.Message + " [line " + $_.InvocationInfo.ScriptLineNumber + "]")
    Shot 'error'
} finally {
    if ($p) { Close-App $p } else { Kill-App }
    if ($script:explorer -ne [IntPtr]::Zero -and [Mp.Mouse]::IsWindow($script:explorer)) {
        [void][Mp.Mouse]::PostMessage($script:explorer, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE, our window only
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
if ($script:fails -eq 0) { Write-Host "DRAGTEST: ALL OK"; exit 0 }
Write-Host ("DRAGTEST: " + $script:fails + " FAILED"); exit 1
