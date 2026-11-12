# MakePack update end-to-end test: the REAL MakePack.exe + MakeUpdate.exe against a fake GitHub (python http.server on
# 127.0.0.1, MAKEKIT_UPDATE_API) that offers v2.1.1, whose "setup" is MakeKit\tools\update-e2e-fake.zig (it only writes
# a marker file). Never contacts GitHub, never runs a real installer, never touches the installed MakePack.
# Sandbox: a copy of zig-out\bin in %TEMP%\makepack-test-upd-<random>, private MAKEPACK_INSTANCE, MAKEPACK_SETTINGS in
# that folder, MAKEPACK_REGROOT=Software\MakePackTest-<random> (deleted), TEMP/LOCALAPPDATA inside the folder,
# MAKEKIT_AUTOMATION=1 on \\.\DISPLAY1 (no SendInput). Stops only processes it started or that run from its folder.
#   powershell -ExecutionPolicy Bypass -File tools\update-e2e.ps1 [-Optimize Debug|ReleaseSafe] [-Shot banner.png]
# Pure ASCII (PS 5.1).
param([string]$Optimize = 'Debug', [string]$Shot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
$kitRoot = Join-Path (Split-Path -Parent $root) 'MakeKit'
. (Join-Path $kitRoot 'tools\imgui-auto.ps1')
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { throw "Zig 0.17.1 not found at $zig" }
$python = (& py -3.12 -c 'import sys; print(sys.executable)').Trim()

$rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path ([IO.Path]::GetTempPath()) "makepack-test-upd-$rand"
$srv = Join-Path $work 'srv'
$app = Join-Path $work 'app'
$marks = Join-Path $work 'marks'
$tmp = Join-Path $work 'tmp'
$lad = Join-Path $work 'lad'
$cfg = Join-Path $work 'settings.json'
$reg = "Software\MakePackTest-$rand"
foreach ($d in @($work, $srv, $app, $marks, $tmp, $lad, "$srv\dl", "$srv\repos\MakeMD\MakePack\releases\tags")) { $null = New-Item -ItemType Directory -Force -Path $d }

$own = New-Object System.Collections.ArrayList
$savedEnv = @{}
function Set-TestEnv([string]$Name, $Value) {
    if (-not $savedEnv.ContainsKey($Name)) { $savedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name) }
    [Environment]::SetEnvironmentVariable($Name, $Value)   # process scope (children inherit); $null removes
}
function Check($cond, [string]$what) { if (-not $cond) { throw "check failed: $what" } else { Write-Host "  ok  $what" } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
function Wait-Until([scriptblock]$Cond, [int]$Ms) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while (-not (& $Cond)) { if ((Get-Date) -gt $deadline) { return $false }; Start-Sleep -Milliseconds 200 }
    $true
}
function Get-Settings { try { Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
function Get-LastCheck { $s = Get-Settings; if ($s -and ($s.PSObject.Properties.Name -contains 'LastUpdateCheck')) { [long]$s.LastUpdateCheck } else { 0 } }
# Processes running an exe from our sandbox folder (ours by construction: the folder name is random).
function Get-Ours([string]$Name) {
    @(Get-CimInstance Win32_Process -Filter "Name='$Name'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($work, [StringComparison]::OrdinalIgnoreCase) })
}
function Has-Banner($a) { [bool](@(Get-AutoItems $a) | Where-Object { $_.label -like '*##updNow' -and $_.visible }) }
function Start-MakePack {
    $a = Start-AutoApp -Exe "$app\MakePack.exe" -TimeoutMs 30000
    $null = $own.Add($a.Process)
    $null = Wait-AutoItem $a '###status' 20000
    $a
}
# The automation pipe of a MakePack we did not start ourselves (the relaunch by MakeUpdate).
function Connect-AutoPid([int]$Id) {
    $p = Get-Process -Id $Id
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', "makekit-auto-$Id", [System.IO.Pipes.PipeDirection]::InOut)
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) { try { $pipe.Connect(250); break } catch { if ((Get-Date) -gt $deadline) { throw "no automation pipe for pid $Id" } } }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($pipe, $utf8)
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"
    [pscustomobject]@{ Process = $p; Pipe = $pipe; Reader = (New-Object System.IO.StreamReader($pipe, $utf8)); Writer = $writer }
}

$ok = $false
try {
    # ---- build (before TEMP/LOCALAPPDATA move: zig keeps its cache there)
    Push-Location $root
    try {
        & $zig build "-Doptimize=$Optimize"
        if ($LASTEXITCODE) { throw "zig build failed ($LASTEXITCODE)" }
        & $zig build-exe (Join-Path $kitRoot 'tools\update-e2e-fake.zig') -O ReleaseSmall "-femit-bin=$work\fake.exe"
        if ($LASTEXITCODE) { throw "building the fake setup failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
    foreach ($f in 'MakePack.exe', 'MakeUpdate.exe', '7z.dll', '7z.sfx') { Copy-Item (Join-Path $root "zig-out\bin\$f") $app }
    $current = [regex]::Match((Get-Content (Join-Path $root 'build.zig.zon') -Raw), '\.version\s*=\s*"([^"]+)"').Groups[1].Value
    Write-Host "MakePack $current ($Optimize) in $app"

    # ---- fake GitHub: MakeMD/MakePack v2.1.1 (newer than any 2.1.0 build)
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $base = "http://127.0.0.1:$port"
    $setupName = 'MakePack-Setup-2.1.1.exe'
    Copy-Item "$work\fake.exe" "$srv\dl\$setupName"
    $hash = (Get-FileHash "$srv\dl\$setupName" -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8 "$srv\dl\SHA256SUMS.txt" "$hash  $setupName`n"
    $rel = '{"tag_name":"v2.1.1","html_url":"BASE/MakeMD/MakePack/releases/tag/v2.1.1","draft":false,"prerelease":false,"body":"Fixes","assets":[' +
        '{"name":"SETUP","browser_download_url":"BASE/dl/SETUP","size":SIZE},' +
        '{"name":"SHA256SUMS.txt","browser_download_url":"BASE/dl/SHA256SUMS.txt","size":90}]}'
    $rel = $rel.Replace('BASE', $base).Replace('SETUP', $setupName).Replace('SIZE', "$((Get-Item "$srv\dl\$setupName").Length)")
    Write-Utf8 "$srv\repos\MakeMD\MakePack\releases\latest" $rel
    Write-Utf8 "$srv\repos\MakeMD\MakePack\releases\tags\v2.1.1" $rel
    $server = Start-Process -FilePath $python -ArgumentList @('-I', '-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $srv) `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput "$work\srv.out" -RedirectStandardError "$work\srv.err"
    $null = $own.Add($server)
    Check (Wait-Until { $c = New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', $port); $true } catch { $false } finally { $c.Close() } } 15000) "fake GitHub on $base"

    # ---- sandbox environment of every process below
    Set-TestEnv 'MAKEPACK_INSTANCE' "MakePack-updtest-$rand"
    Set-TestEnv 'MAKEPACK_SETTINGS' $cfg
    Set-TestEnv 'MAKEPACK_REGROOT' $reg
    Set-TestEnv 'MAKEPACK_HIVE' $null
    Set-TestEnv 'MAKEKIT_LANG' 'en'
    Set-TestEnv 'TEMP' $tmp
    Set-TestEnv 'TMP' $tmp
    Set-TestEnv 'LOCALAPPDATA' $lad
    Set-TestEnv 'MAKEUPDATE_E2E_DIR' $marks
    Set-TestEnv 'MAKEKIT_UPDATE_API' $base

    Write-Host 'MAKEKIT_NO_UPDATE=1:'
    Set-TestEnv 'MAKEKIT_NO_UPDATE' '1'
    $a = Start-MakePack
    $spawned = $false
    for ($i = 0; $i -lt 15; $i++) { if (@(Get-Ours 'MakeUpdate.exe').Count) { $spawned = $true }; $null = Invoke-AutoFrames $a 1; Start-Sleep -Milliseconds 200 }
    Check (-not $spawned) 'no MakeUpdate.exe started'
    Check (-not (Has-Banner $a)) 'no banner'
    Check ((Get-LastCheck) -eq 0) 'no check recorded'
    $null = Stop-AutoApp $a
    Set-TestEnv 'MAKEKIT_NO_UPDATE' $null

    Write-Host 'offline (nothing listens on the API port):'
    Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $dead = $l.LocalEndpoint.Port; $l.Stop()
    Set-TestEnv 'MAKEKIT_UPDATE_API' "http://127.0.0.1:$dead"
    $a = Start-MakePack
    Check (Wait-Until { (Get-LastCheck) -gt 0 } 45000) 'the daily check ran and was recorded'
    $null = Invoke-AutoFrames $a 3
    Check (-not (Has-Banner $a)) 'no banner, no alert'
    Check (-not (@(Get-AutoItems $a) | Where-Object { $_.label -like '*##msgText' })) 'no message box'
    $null = Stop-AutoApp $a
    Set-TestEnv 'MAKEKIT_UPDATE_API' $base

    Write-Host 'banner + Later:'
    Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
    $a = Start-MakePack
    $null = Wait-AutoItem $a 'Update now##updNow' 45000
    Check ((Get-AutoText $a '##updText') -eq 'Version 2.1.1 is available') 'banner text'
    foreach ($b in @('What''s new##updNotes', 'Later##updLater')) { $null = Wait-AutoItem $a $b }
    if ($Shot) { $null = Save-AutoScreenshot $a $Shot -Png; Write-Host "  screenshot: $Shot" }
    Invoke-AutoClick $a 'Later##updLater'
    $null = Invoke-AutoFrames $a 3
    Check (-not (Has-Banner $a)) 'Later hides the banner'
    Check ((Get-Settings).UpdateSkip -eq '2.1.1') 'UpdateSkip = 2.1.1 saved'
    Write-Host 'Help > Check for updates (also offers a skipped version):'
    Invoke-AutoClick $a '###mhelp'
    $null = Invoke-AutoFrames $a 2
    Invoke-AutoClick $a '###m_updates'
    $null = Wait-AutoItem $a 'Update now##updNow' 45000
    Check $true 'manual check shows the banner'
    Invoke-AutoClick $a 'Later##updLater'
    $null = Stop-AutoApp $a
    Write-Host 'daily check after Later stays quiet:'
    $s = Get-Settings
    $s.LastUpdateCheck = 0
    Write-Utf8 $cfg ($s | ConvertTo-Json -Depth 8)
    $a = Start-MakePack
    Check (Wait-Until { (Get-LastCheck) -gt 0 } 45000) 'the daily check ran'
    $null = Invoke-AutoFrames $a 3
    Check (-not (Has-Banner $a)) 'no banner for the skipped 2.1.1'
    $null = Stop-AutoApp $a

    Write-Host 'Update now:'
    Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
    $a = Start-MakePack
    $null = Wait-AutoItem $a 'Update now##updNow' 45000
    $oldPid = $a.Process.Id
    Invoke-AutoClick $a 'Update now##updNow'
    Check ($a.Process.WaitForExit(15000)) 'MakePack quits for the update'
    try { $a.Pipe.Dispose() } catch { }
    $mark = "$marks\$setupName.txt"
    Check (Wait-Until { Test-Path $mark } 90000) 'MakeUpdate verified the hash and ran the (fake) setup'
    $args4 = @((Get-Content $mark -Raw) -split "`n")[0..3] -join ' '
    Check ($args4 -eq '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS') "setup switches ($args4)"
    Check ((Get-Item $mark).LastWriteTime -ge $a.Process.ExitTime.AddMilliseconds(-50)) 'setup ran after MakePack exited'
    Check (Wait-Until { @(@(Get-Ours 'MakePack.exe') | Where-Object { $_.ProcessId -ne $oldPid }).Count -gt 0 } 30000) 'MakePack relaunched'
    $newPid = [int](@(@(Get-Ours 'MakePack.exe') | Where-Object { $_.ProcessId -ne $oldPid })[0].ProcessId)
    $b = Connect-AutoPid $newPid
    $null = $own.Add($b.Process)
    $null = Wait-AutoItem $b '###status' 20000
    Check (-not (Has-Banner $b)) 'relaunched MakePack: main window, no banner (checked < 24 h ago)'
    $null = Stop-AutoApp $b
    Check (Wait-Until { @(Get-ChildItem $tmp -Filter 'MakeUpdate-*').Count -eq 0 } 10000) 'download folder removed'
    Check ((Test-Path "$app\MakeUpdate.exe") -and -not (Test-Path "$app\MakeUpdate.exe.old")) 'MakeUpdate.exe back in place'
    $log = Get-Content "$lad\MakeUpdate\update.log" -Raw
    Check ($log -like '*SHA-256 ok*' -and $log -like '*setup done*' -and $log -like '*relaunched*') 'update.log: SHA-256 ok, setup done, relaunched'

    $ok = $true
} finally {
    foreach ($p in $own) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    foreach ($n in 'MakePack.exe', 'MakeUpdate.exe', 'MakePack-Setup-2.1.1.exe') { foreach ($p in @(Get-Ours $n)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
    foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    Remove-Item -LiteralPath "HKCU:\$reg" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    if (Test-Path $work) { Write-Host "warning: could not remove $work" }
}
if ($ok) { Write-Host 'UPDATE-E2E OK' } else { exit 1 }
