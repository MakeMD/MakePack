# MP-G1 fix check (PowerShell 5.1, pure ASCII): main window over MakeKit automation on DISPLAY1, sandboxed
# (private MAKEPACK_INSTANCE / MAKEPACK_SETTINGS, files only in %TEMP%\makepack-test-<random>, removed at the end).
# Covers: window bounds restore under test, deep tree scroll, columns fit / flat Path, Alt+T password prompt,
# rename box. Screenshots: zig-out\shots\fix-MP-G1-*.png
#   powershell -ExecutionPolicy Bypass -File tools\gui_g1fix.ps1 [-Exe <MakePack.exe>]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo '..\MakeKit\tools\imgui-auto.ps1')
if ($Exe -eq '') { $Exe = Join-Path $repo 'zig-out\bin\MakePack.exe' }
$Exe = (Resolve-Path $Exe).Path
$sevenZip = Join-Path $repo 'third_party\7zip\7z.exe'
$shots = Join-Path $repo 'zig-out\shots'
New-Item -ItemType Directory -Force $shots | Out-Null
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
if (-not ('G1Fix.Win' -as [type])) {
    Add-Type -Namespace G1Fix -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
'@
}

$rand = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP "makepack-test-$rand"
New-Item -ItemType Directory -Force $root | Out-Null
$results = New-Object System.Collections.ArrayList
$apps = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    Write-Host ('{0} {1} {2}' -f ($(if ($ok) { 'OK  ' } else { 'FAIL' })), $name, $detail)
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = $ok })
}
function Start-Mp([string[]]$ArgList, [hashtable]$envs) {
    $app = Start-AutoApp -Exe $Exe -Args $ArgList -Env $envs
    [void]$apps.Add($app)
    $app
}
function Start-Plain([string[]]$ArgList, [hashtable]$envs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ArgList | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['MAKEKIT_DISPLAY'] = '\\.\DISPLAY1'
    foreach ($k in $envs.Keys) { $psi.EnvironmentVariables[$k] = [string]$envs[$k] }
    [System.Diagnostics.Process]::Start($psi)
}
function Shot($app, [string]$name) {
    $null = Invoke-AutoFrames $app 4
    $bmp = Save-AutoScreenshot $app (Join-Path $root "$name.bmp")
    $img = [System.Drawing.Image]::FromFile($bmp)
    try { $img.Save((Join-Path $shots "fix-MP-G1-$name.png"), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
}
function Find($app, [string]$like) { @(Get-AutoItems $app | Where-Object { $_.label -like $like }) | Select-Object -First 1 }
function Run-7z([string[]]$a) {
    $p = Start-Process -FilePath $sevenZip -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root '7z.out')
    $p.ExitCode
}
function Write-Json([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false))) }

# ---- sandbox ----------------------------------------------------------------------------------------------------
$disk = Join-Path $root 'disk'
New-Item -ItemType Directory -Force (Join-Path $disk 'folder') | Out-Null
Set-Content -LiteralPath (Join-Path $disk 'a.txt') -Value 'alpha' -Encoding ASCII
$src = Join-Path $root 'src'
foreach ($d in 'dir1', 'dir2') {
    New-Item -ItemType Directory -Force (Join-Path $src $d) | Out-Null
    Set-Content -LiteralPath (Join-Path $src "$d\same.txt") -Value "same in $d" -Encoding ASCII
}
Push-Location $src
try {
    $null = Run-7z @('a', '-tzip', (Join-Path $disk 'arc.zip'), 'dir1', 'dir2')
    $null = Run-7z @('a', '-tzip', '-pSecret1', (Join-Path $disk 'pw.zip'), 'dir1')
} finally { Pop-Location }
$deep = Join-Path $root 'deep\level-one-folder\level-two-folder\level-three-folder\the-deepest-folder-name'
New-Item -ItemType Directory -Force $deep | Out-Null
$d1 = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -like '*DISPLAY1' } | Select-Object -First 1
$wa = $d1.WorkingArea

try {
    # ---- 1. restore: saved bounds on the test monitor apply; deep tree scrolls to the current folder ----------------
    $s1 = Join-Path $root 'restore.json'
    $want = @(($wa.Left + 40), ($wa.Top + 30), 1000, 700)
    Write-Json $s1 ('{"Window":[' + ($want -join ',') + '],"Maximized":false,"Tree":true}')
    $app = Start-Mp @($deep) @{ MAKEPACK_INSTANCE = "MakePack-g1fix-$rand-1"; MAKEPACK_SETTINGS = $s1 }
    $null = Wait-AutoItem $app '###status' 8000
    $null = Invoke-AutoFrames $app 6
    $r = New-Object G1Fix.Win+RECT
    [void][G1Fix.Win]::GetWindowRect($app.Process.MainWindowHandle, [ref]$r)
    $got = @($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    Check 'restore: saved Window bounds applied under test' (($got -join ',') -eq ($want -join ',')) ("got " + ($got -join ','))
    $node = Find $app '*###t*the-deepest-folder-name'
    # 11 levels deep its row starts ~230 px right of the tree's edge unscrolled; scrolled, the name starts near the edge.
    Check 'tree: deep current node scrolled into view' ($node -and $node.visible -and $node.x0 -lt 100) $(if ($node) { "node x0=$($node.x0)" } else { 'no node' })
    Shot $app 'tree-deep'
    $null = Stop-AutoApp $app
    $saved = Get-Content -Raw $s1 | ConvertFrom-Json
    Check 'restore: bounds saved back unchanged' (($saved.Window -join ',') -eq ($want -join ',')) ($saved.Window -join ',')

    # ---- 2. default 900 px window: archive columns fit, flat view shows Path ---------------------------------------
    $s2 = Join-Path $root 'cols.json'
    Write-Json $s2 '{"Tree":true}'
    $envs = @{ MAKEPACK_INSTANCE = "MakePack-g1fix-$rand-2"; MAKEPACK_SETTINGS = $s2 }
    $app = Start-Mp @((Join-Path $disk 'arc.zip')) $envs
    $null = Wait-AutoItem $app 'dir1###r' 8000
    $list = @(Get-AutoItems $app -Windows | Where-Object { $_.name -like '*##list*' -and $_.name -notlike '*##files*' }) | Select-Object -First 1
    $crc = Find $app '*###c_crc'
    Check 'columns: CRC32 header inside the list' ($crc -and $list -and $crc.x1 -le $list.x1 + 1) $(if ($crc) { "crc x1=$($crc.x1) list x1=$($list.x1)" } else { 'no header' })
    Shot $app 'archive-columns'
    Invoke-AutoKey $app 'ctrl+H'
    $null = Wait-AutoItem $app '###c_path' 5000
    $null = Invoke-AutoFrames $app 3
    $path = Find $app '*###c_path'
    $rows = @(Get-AutoItems $app | Where-Object { $_.label -eq 'same.txt###r' })
    Check 'flat: Path column on screen, two same.txt rows' ($path -and $path.visible -and $path.x1 -le $list.x1 + 1 -and $rows.Count -eq 2) $(if ($path) { "path x0=$($path.x0) x1=$($path.x1) rows=$($rows.Count)" } else { 'no Path header' })
    Shot $app 'flat-path'
    Invoke-AutoKey $app 'ctrl+H'
    $null = Invoke-AutoFrames $app 3

    # ---- 3. Alt+T on pw.zip (names readable, bodies encrypted): password prompt, then Test OK ----------------------
    $fw = Start-Plain @((Join-Path $disk 'pw.zip')) $envs   # forwarded to the running instance, exits at once
    Check 'forward: second process exits 0' ($fw.WaitForExit(10000) -and $fw.ExitCode -eq 0)
    $null = Wait-AutoItem $app 'dir1###r' 8000
    $t = Find $app '*###title'
    Check 'open: title has pw.zip' ($t -and $t.label -like '*pw.zip*') $(if ($t) { $t.label } else { '' })
    Invoke-AutoKey $app 'alt+T'
    $prompt = Wait-AutoItem $app '##password_input' 8000
    Check 'test: Alt+T asks for the password' ($prompt -ne $null)
    Shot $app 'test-password'
    Invoke-AutoClick $app '##password_input'
    Invoke-AutoType $app 'Secret1'
    Invoke-AutoClick $app '##password_ok'
    $deadline = (Get-Date).AddSeconds(10); $msg = $null
    while ((Get-Date) -lt $deadline -and -not $msg) {
        Start-Sleep -Milliseconds 200
        $msg = @(Get-AutoItems $app | Where-Object { $_.label -like '*-p*MAKEPACK_PASSWORD*' -or $_.window -like '*###msg*' -or $_.label -like '*##msg*' }) | Select-Object -First 1
    }
    $all = @(Get-AutoItems $app | ForEach-Object { $_.label }) -join ' | '
    Check 'test: no CLI "-p" wording after the password' ($all -notlike '*MAKEPACK_PASSWORD*') ''
    Shot $app 'test-result'
    Write-Host "items after test: $all"
    Invoke-AutoKey $app 'Enter'
    $null = Invoke-AutoFrames $app 3

    # ---- 4. rename box on disk: one row tall --------------------------------------------------------------------
    Invoke-AutoKey $app 'alt+UpArrow'
    $null = Wait-AutoItem $app 'a.txt###r' 8000
    $row = Find $app 'a.txt###r'
    Invoke-AutoClick $app 'a.txt###r'
    $null = Invoke-AutoFrames $app 3
    Shot $app 'selected-row'
    $bm = [System.Drawing.Bitmap]::FromFile((Join-Path $shots 'fix-MP-G1-selected-row.png'))
    try { $px = $bm.GetPixel([int]($row.x1 - 6), [int](($row.y0 + $row.y1) / 2)) } finally { $bm.Dispose() }
    Check 'selection: hovered selected row keeps a visible fill' ($px.G -lt 0xEA) ('{0:X2}{1:X2}{2:X2}' -f $px.R, $px.G, $px.B)
    Invoke-AutoKey $app 'F2'
    $box = Wait-AutoItem $app '##rename' 5000
    $null = Invoke-AutoFrames $app 2
    $box = Find $app '*##rename'
    $h = if ($box) { $box.y1 - $box.y0 } else { -1 }
    Check 'rename: box no taller than a row' ($box -and $h -le ($row.y1 - $row.y0) + 1) "box h=$h row h=$($row.y1 - $row.y0)"
    Shot $app 'rename'
    Invoke-AutoKey $app 'Escape'
    $null = Invoke-AutoFrames $app 3
    $null = Stop-AutoApp $app
}
finally {
    foreach ($a in $apps) { if (-not $a.Process.HasExited) { Stop-Process -Id $a.Process.Id -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
$bad = @($results | Where-Object { -not $_.Ok })
Write-Host ("{0} checks, {1} failed" -f $results.Count, $bad.Count)
exit $bad.Count
