# Live GUI check of the settings store: remembered options, save on Create, Settings dialog.
# Usage: tools\settingstest.ps1 [-Exe <path>]. Pure ASCII (PS 5.1). Restores the user's settings.json afterwards.
# -Screen: the monitor the test windows are moved to (\\.\DISPLAY<n>; 0 = leave them where they open).
param([string]$Exe = "$PSScriptRoot\..\dist\publish\MakePack.exe", [string]$Shot = "", [int]$Screen = 1)
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Start-ScreenPin -Screen $Screen -Exe $Exe
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]
Add-Type -Namespace Mp -Name Win2 -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Mp.Win2]::SetProcessDPIAware()
Add-Type -Namespace Mp -Name Shot -ReferencedAssemblies System.Drawing -MemberDefinition @'
[DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
[DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
public struct RECT { public int L, T, R, B; }
public static bool Save(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new System.Drawing.Bitmap(r.R - r.L, r.B - r.T)) {
        using (var g = System.Drawing.Graphics.FromImage(bmp)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    return true;
}
'@
Add-Type -Namespace Mp -Name Win3 -MemberDefinition @'
delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, System.Text.StringBuilder s);
static string Text(IntPtr h) { var sb = new System.Text.StringBuilder(1024); SendMessage(h, 0x000D, (IntPtr)1024, sb); return sb.ToString(); }
public static string[] Find(uint pid, string title) {
    string[] hit = null;
    EnumWindows((h, l) => {
        uint p; GetWindowThreadProcessId(h, out p);
        if (p != pid || Text(h) != title) return true;
        string edit = null;
        EnumChildWindows(h, (c, l2) => { var cn = new System.Text.StringBuilder(256); GetClassName(c, cn, 256);
            if (edit == null && cn.ToString().ToUpperInvariant().Contains("EDIT")) edit = Text(c); return true; }, IntPtr.Zero);
        hit = new[] { title, edit }; return false;
    }, IntPtr.Zero);
    return hit;
}
'@   # physical pixels from UIA, same as the per-monitor-aware app

$cfgDir = Join-Path $env:APPDATA 'MakePack'
$cfg = Join-Path $cfgDir 'settings.json'
$backup = $null
if (Test-Path $cfg) { $backup = Get-Content $cfg -Raw -Encoding UTF8 }

$work = Join-Path $env:TEMP ('mp-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$outDir = Join-Path $work 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$src = Join-Path $work 'data.txt'
Set-Content $src ('hello ' * 1000)

function Find-Window([string]$titlePart, [int]$ms = 15000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in $AT::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ($w.Current.Name -like "*$titlePart*" -and $w.Current.ProcessId -eq $script:proc.Id) { return $w }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "window '$titlePart' not found"
}
function All($el, $type) { $el.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, $type))) }
function ComboText($c) { $v = $null; if ($c.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$v)) { $v.Current.Value } else { $c.Current.Name } }

try {
    # 1. Seeded settings are picked up by a fresh process.
    $json = '{ "Format": "Zip", "Level": "Ultra", "ArchiveFolder": "' + ($outDir -replace '\\', '\\') + '" }'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    [IO.File]::WriteAllText($cfg, $json)

    $script:proc = Start-Process $Exe -ArgumentList @('a', "`"$src`"") -PassThru
    $dlg = Find-Window ''
    $combos = @(All $dlg $CT::ComboBox | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
    $fmt = ComboText $combos[1]; $lvl = ComboText $combos[2]   # [0] is the profile
    $edits = All $dlg $CT::Edit
    $outBox = $edits | Where-Object { $_.Current.AutomationId -ne '' -or $true } | ForEach-Object { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } | Where-Object { $_ -like '*.zip' }
    Write-Host "format=$fmt level=$lvl out=$outBox"
    if ($fmt -ne 'zip') { throw "format not restored: $fmt" }
    if ($outBox -ne (Join-Path $outDir 'data.zip')) { throw "archive folder not applied: $outBox" }

    # 2. Create saves the choice: the process already holds the settings in memory, so the file must come back.
    Remove-Item $cfg
    $create = All $dlg $CT::Button | Where-Object { $_.Current.Name -in @($([regex]::Unescape('\u0421\u0442\u0432\u043e\u0440\u0438\u0442\u0438')), 'Create') } | Select-Object -First 1
    $create.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = $script:proc.WaitForExit(30000)
    if (-not (Test-Path (Join-Path $outDir 'data.zip'))) { throw 'data.zip was not created in the archive folder' }
    $saved = Get-Content $cfg -Raw
    Write-Host "saved: $($saved -replace '\s+', ' ')"
    if ($saved -notmatch '"Format": "Zip"' -or $saved -notmatch '"Level": "Ultra"') { throw 'choice not saved after Create' }

    # 3. Settings button on the main window opens the dialog.
    $script:proc = Start-Process $Exe -PassThru
    $main = Find-Window 'MakePack'
    $btn = All $main $CT::Button | Where-Object { $_.Current.Name -like ($([regex]::Unescape('\u041d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u043d\u044f')) + '*') -or $_.Current.Name -like 'Settings*' } | Select-Object -First 1
    if (-not $btn) { throw 'no Settings button on the toolbar' }
    # Invoke does not return while the modal dialog is open, so a helper process does it.
    $helper = Join-Path $PSScriptRoot 'invoke_btn.ps1'
    $inv = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"", $script:proc.Id, '\u041d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u043d\u044f') -WindowStyle Hidden -PassThru
    # The app's UIA side is busy inside that Invoke, so look with plain Win32: top-level window title + its edit text.
    $want = [regex]::Unescape('\u041d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u043d\u044f')
    $deadline = (Get-Date).AddSeconds(15); $found = $null
    while (-not $found -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $found = [Mp.Win3]::Find([uint32]$script:proc.Id, $want)
    }
    if (-not $found) { throw 'settings dialog did not open' }
    Write-Host "settings dialog '$($found[0])' folder=$($found[1])"
    if ($found[1] -ne $outDir) { throw "settings dialog shows '$($found[1])'" }
    Stop-Process -Id $script:proc.Id -Force
    if (-not $inv.HasExited) { Stop-Process -Id $inv.Id -Force }

    # 4. Advanced block: remembered values come back, only what the format takes is enabled, and Create uses them.
    $outDir2 = Join-Path $work 'out2'
    New-Item -ItemType Directory -Force $outDir2 | Out-Null
    function Open-Advanced([string]$format) {
        $json = '{ "Format": "' + $format + '", "Level": "Normal", "ShowAdvanced": true, "Method": "Lzma", "Dictionary": 4194304,' +
                ' "Solid": "off", "Threads": 1, "Filter": "off", "ArchiveFolder": "' + ($outDir2 -replace '\\', '\\') + '" }'
        [IO.File]::WriteAllText($cfg, $json)
        $script:proc = Start-Process $Exe -ArgumentList @('a', "`"$src`"") -PassThru
        $d = Find-Window ''
        $c = @(All $d $CT::ComboBox | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
        # by position: profile, format, level, volumes, then method, dictionary, solid, threads, filter
        $state = ($c[4..8] | ForEach-Object { (ComboText $_) + '=' + $(if ($_.Current.IsEnabled) { 'on' } else { 'off' }) }) -join ' | '
        Write-Host "$format -> $state"
        return @($d, $c, $state)
    }
    $d, $c, $state = Open-Advanced 'SevenZip'
    if ($state -notmatch '^LZMA=on \| 4 MB=on \| \S+=on \| 1=on \| \S+=on$') { throw "7z advanced block: $state" }
    if ($Shot) {
        [void][Mp.Shot]::Save([IntPtr]$d.Current.NativeWindowHandle, $Shot)
        Write-Host "screenshot: $Shot"
    }
    Stop-Process -Id $script:proc.Id -Force

    $d, $c, $state = Open-Advanced 'Tar'
    if ($state -notmatch '=off \| .*=off \| .*=off \| .*=off \| .*=off$') { throw "tar advanced block: $state" }
    Stop-Process -Id $script:proc.Id -Force

    $d, $c, $state = Open-Advanced 'Zip'
    if ($state -notmatch '^LZMA=on \| 4 MB=on \| \S+=off \| 1=on \| \S+=off$') { throw "zip advanced block: $state" }
    $create = All $d $CT::Button | Where-Object { $_.Current.Name -in @($([regex]::Unescape('\u0421\u0442\u0432\u043e\u0440\u0438\u0442\u0438')), 'Create') } | Select-Object -First 1
    $create.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = $script:proc.WaitForExit(30000)
    $zip = Join-Path $outDir2 'data.zip'
    $method = & (Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe') l -slt $zip | Select-String '^Method = ' | Select-Object -First 1
    Write-Host "created zip: $method"
    if ("$method" -notmatch 'LZMA') { throw "zip was not written with LZMA: $method" }
    'PASS'
}
finally {
    Stop-ScreenPin
    Get-Process MakePack -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Resolve-Path $Exe).Path } | Stop-Process -Force
    if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item $cfg -ErrorAction SilentlyContinue }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
