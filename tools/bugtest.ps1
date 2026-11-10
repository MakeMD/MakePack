# MakePack black-box bug tests (Zig/ImGui app). Pure ASCII. PowerShell 5.1.
# Usage: tools\bugtest.ps1 [-Exe <path>] [-Only <testname>] [-Screen <n>]
# -Screen: the monitor every test window opens on (MAKEKIT_DISPLAY=\\.\DISPLAY<n>, default 1).
#
# Sandbox (nothing here touches the user's MakePack, settings, registry or files):
# - every process gets MAKEPACK_INSTANCE=MakePack-bugtest-<random>-<case> (a private mutex + pipe, so the user's
#   running MakePack never receives our arguments), MAKEPACK_SETTINGS=<temp>\settings.json (reset before each case),
#   MAKEPACK_REGROOT=Software\MakePackTest-<random> (every Assoc read/write lands under that HKCU key, deleted at
#   the end), MAKEKIT_AUTOMATION=1 (real mouse/keyboard ignored; driven over the MakeKit pipe, never SendInput) and
#   MAKEKIT_DISPLAY=\\.\DISPLAY<Screen>;
# - files only in %TEMP%\makepack-test-<random> (removed at the end); the Recycle Bin cases put back only their own
#   files; only processes this script started are killed (by PID).
# GUI cases drive the app with MakeKit's tools\imgui-auto.ps1 and click by ##id (see docs/ZIG-PORT.md "GUI").
param(
    [string]$Exe = "$PSScriptRoot\..\zig-out\bin\MakePack.exe",
    [string]$Only = "",
    [ValidateRange(1, 9)][int]$Screen = 1
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }   # dialog texts in the notes are Ukrainian
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
Set-StrictMode -Off   # imgui-auto.ps1 turns it on for the caller; the cases below are written without it

# Random BYTES are stored almost at memcpy speed (LZMA2 skips incompressible chunks), which leaves no
# window to cancel in. Random LETTERS compress for real: ~2 MB/s, which is what cancel_compress needs.
if (-not ('Mp.Gen' -as [type])) {
    Add-Type -Namespace Mp -Name Gen -MemberDefinition @'
public static void Letters(string path, int bytes, int seed) {
    var r = new System.Random(seed);
    var b = new byte[bytes];
    r.NextBytes(b);
    for (int i = 0; i < b.Length; i++) b[i] = (byte)(97 + (b[i] % 26));
    System.IO.File.WriteAllBytes(path, b);
}
'@
}

$SevenZ  = Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe'
$Rand    = [guid]::NewGuid().ToString('N').Substring(0, 8)
$Root    = Join-Path $env:TEMP ('makepack-test-' + $Rand)
$RegRoot = 'Software\MakePackTest-' + $Rand
$RegHK   = 'Registry::HKEY_CURRENT_USER\' + $RegRoot          # = HKCU as the app sees it under MAKEPACK_REGROOT
# Inherited by every process started from here (Start-Process, &).
$env:MAKEPACK_SETTINGS  = Join-Path $Root 'settings.json'
$env:MAKEPACK_REGROOT   = $RegRoot
$env:MAKEKIT_AUTOMATION = '1'
$env:MAKEKIT_DISPLAY    = '\\.\DISPLAY' + $Screen
foreach ($v in 'MAKEPACK_HIVE', 'MAKEPACK_PASSWORD', 'MAKEPACK_INSTANCE') { Remove-Item ('Env:\' + $v) -ErrorAction SilentlyContinue }
$script:nPass = 0; $script:nFail = 0; $script:nSkip = 0
$script:Procs = New-Object System.Collections.ArrayList

# ---------- helpers ----------
function Q([string]$s) { '"' + $s + '"' }
function Assert([bool]$Cond, [string]$Why) { if (-not $Cond) { throw $Why } }
function Skip-Test([string]$Why) { throw ("SKIP:" + $Why) }

# Only processes this script started, by PID.
function Kill-App {
    foreach ($p in @($script:Procs)) {
        try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; [void]$p.WaitForExit(3000) } } catch { }
    }
    $script:Procs.Clear()
}

function Start-App([string[]]$A) {
    $p = Start-Process -FilePath $Exe -ArgumentList $A -PassThru
    try { $null = $p.Handle } catch { }   # a held handle keeps ExitCode readable after the process is gone
    [void]$script:Procs.Add($p)
    $p
}

# Our started processes that are still running.
function Alive([object[]]$ps) { @($ps | Where-Object { -not $_.HasExited }) }

# The MakeKit automation pipe of an already started process (Start-AutoApp starts AND connects; ours are started by
# Start-App so a forwarded invocation and a primary one look the same). $null if the process exited first.
function Connect-App($p, [int]$Sec = 15) {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('makekit-auto-' + $p.Id), [System.IO.Pipes.PipeDirection]::InOut)
    $deadline = (Get-Date).AddSeconds($Sec)
    while ($true) {
        try { $pipe.Connect(250); break } catch {
            if ($p.HasExited -or (Get-Date) -gt $deadline) { $pipe.Dispose(); return $null }
        }
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $w = New-Object System.IO.StreamWriter($pipe, $utf8)
    $w.AutoFlush = $true
    $w.NewLine = "`n"
    [pscustomobject]@{ Process = $p; Pipe = $pipe; Reader = (New-Object System.IO.StreamReader($pipe, $utf8)); Writer = $w }
}

function Must-Connect($p, [int]$Sec = 15) {
    $app = Connect-App $p $Sec
    if ($app) { return $app }
    if ($p.HasExited) { Assert $false ("the process exited with code " + $p.ExitCode + " before showing a window") }
    Assert $false ("no automation pipe within " + $Sec + " s")
}

function Items($app) { try { @(Get-AutoItems $app) } catch { @() } }
function Windows($app) { try { @(Get-AutoItems $app -Windows | ForEach-Object { $_.name }) } catch { @() } }
function Text-Of([string]$label) { $i = $label.IndexOf('##'); if ($i -ge 0) { $label.Substring(0, $i) } else { $label } }

# An item whose label ends with $Id ('##msg_text', '###title', 'inside1.txt###r'), or $null.
function Find-Item($app, [string]$Id) { @(Items $app | Where-Object { $_.label.EndsWith($Id) }) | Select-Object -First 1 }

# Polls for the item; $null when it did not show up in time or the process exited.
function Wait-Item($app, [string]$Id, [int]$Sec = 10) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ($true) {
        $it = Find-Item $app $Id
        if ($it) { return $it }
        if ($app.Process.HasExited -or (Get-Date) -gt $deadline) { return $null }
        Start-Sleep -Milliseconds 200
    }
}

function Must-Item($app, [string]$Id, [int]$Sec = 10) {
    $it = Wait-Item $app $Id $Sec
    if (-not $it) {
        if ($app.Process.HasExited) { Assert $false ("'" + $Id + "' never appeared: the process exited with code " + $app.Process.ExitCode) }
        Assert $false ("'" + $Id + "' did not appear within " + $Sec + " s; on screen: " + (Dialog-Text $app))
    }
    $it
}

# A click that ends the process (OK, Create, Cancel) closes the pipe under the frames command: that is fine.
function Click($app, [string]$Id) {
    Invoke-AutoClick $app $Id
    try { $null = Invoke-AutoFrames $app 2 } catch { if (-not $app.Process.WaitForExit(3000)) { throw } }
}

# Replaces the text of an input box (click it, select all, type).
function Type-Into($app, [string]$Id, [string]$Text) {
    Invoke-AutoClick $app $Id
    Invoke-AutoKey $app 'ctrl+A'
    Invoke-AutoType $app $Text
    $null = Invoke-AutoFrames $app 2
}

function Set-Check($app, [string]$Id, [bool]$On) {
    $it = Must-Item $app $Id
    if ([bool]$it.checked -ne $On) { Click $app $Id }
    Assert ([bool](Find-Item $app $Id).checked -eq $On) ("could not set '" + $Id + "' to " + $On)
}

# Picks the drop-down entry of D.combo('<id>') whose text is like $Like.
function Pick($app, [string]$Id, [string]$Like) {
    Click $app ('##' + $Id)
    $deadline = (Get-Date).AddSeconds(5)
    $hit = $null
    while (-not $hit -and (Get-Date) -lt $deadline) {
        $hit = @(Items $app | Where-Object { $_.label -match ('##' + [regex]::Escape($Id) + '_\d+$') -and (Text-Of $_.label) -like $Like }) | Select-Object -First 1
        if (-not $hit) { Start-Sleep -Milliseconds 150 }
    }
    Assert ($hit -ne $null) ("no '" + $Like + "' in the " + $Id + " drop-down")
    Click $app $hit.label
}

# Waits for the process to end; $null on timeout.
function Wait-Exit($app, [int]$Sec) {
    $p = if ($app.Process) { $app.Process } else { $app }
    if (-not $p.WaitForExit($Sec * 1000)) { return $null }
    if ($app.Pipe) { try { $app.Pipe.Dispose() } catch { } }
    $p.ExitCode
}

# Every text on screen: window titles and item labels without their ##ids - for exact-match asserts.
function Screen-Texts($app) {
    $out = @()
    foreach ($n in (Windows $app)) { $t = $n.Split('/')[0]; $i = $t.IndexOf('###'); if ($i -ge 0) { $t = $t.Substring(0, $i) }; if ($t.Trim()) { $out += $t.Trim() } }
    foreach ($it in (Items $app)) { $t = (Text-Of $it.label).Trim(); if ($t) { $out += $t } }
    ,$out
}

function Has-Exact([string[]]$Texts, [string[]]$Want) {
    foreach ($t in $Texts) { foreach ($w in $Want) { if ($t -eq $w) { return $true } } }
    $false
}

# Polls until one of $Want is on screen (or the process exits); returns everything it saw last.
function Wait-Text($app, [string[]]$Want, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    $seen = @()
    while ((Get-Date) -lt $deadline) {
        $now = Screen-Texts $app
        if ($now.Count -gt 0) { $seen = $now }
        if (Has-Exact $seen $Want) { return ,$seen }
        if ($app.Process.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    ,$seen
}

function Titles($w) { if (@($w).Count -eq 0) { "<none>" } else { "[" + (@($w) -join " | ") + "]" } }

# Windows plus the texts in them - turns "a window appeared" into a usable bug report.
function Dialog-Text($appOrProc) {
    $app = $appOrProc
    $own = $false
    if (-not $appOrProc.Pipe) { $app = Connect-App $appOrProc 2; $own = $true; if (-not $app) { return "<no window>" } }
    try {
        $t = Screen-Texts $app
        if ($t.Count -eq 0) { return "<no window>" }
        (@($t) | Select-Object -First 12) -join ' / '
    } finally { if ($own) { try { $app.Pipe.Dispose() } catch { } } }
}

# The process's windows with the automation suffix: ImGui window names ("enc.7z###password1").
function Password-Windows($app) { @(Windows $app | Where-Object { $_ -like '*###password*' }) }

function Run-App([string[]]$A, [int]$TimeoutMs) {
    $p = Start-App $A
    if ($p.WaitForExit($TimeoutMs)) {
        return [pscustomobject]@{ Proc = $p; TimedOut = $false; Exit = $p.ExitCode; Wins = "" }
    }
    $w = Dialog-Text $p
    try { $p.Kill(); $p.WaitForExit(3000) | Out-Null } catch { }
    [pscustomobject]@{ Proc = $p; TimedOut = $true; Exit = -1; Wins = $w }
}

function New-Dir([string]$p) { New-Item -ItemType Directory -Force -Path $p | Out-Null; $p }

function New-TestDir([string]$name) {
    $d = Join-Path $Root $name
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    New-Dir $d
}

function Rand-File([string]$path, [int]$bytes, [int]$seed) {
    $b = New-Object byte[] $bytes
    (New-Object System.Random $seed).NextBytes($b)
    [System.IO.File]::WriteAllBytes($path, $b)
}

function Names-In([string]$dir) {
    (Get-ChildItem -LiteralPath $dir -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ','
}

function Hash-Tree([string]$dir) {
    $h = @{}
    $base = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length).TrimStart('\')
        $h[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    $h
}

# "" when the trees match, otherwise a diagnostic string.
function Diff-Trees([string]$src, [string]$dst) {
    if (-not (Test-Path -LiteralPath $dst)) { return "destination folder was not created at all" }
    $a = Hash-Tree $src; $b = Hash-Tree $dst
    $miss = @(); $bad = @(); $extra = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { $miss += $k } elseif ($b[$k] -ne $a[$k]) { $bad += $k }
    }
    foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $extra += $k } }
    $m = ""
    if ($a.Count -eq 0)  { $m += "source tree empty (fixture bug); " }
    if ($miss.Count)     { $m += ("not extracted (" + $miss.Count + "): " + ($miss -join ' , ') + "; ") }
    if ($bad.Count)      { $m += ("SHA256 mismatch: " + ($bad -join ' , ') + "; ") }
    if ($extra.Count)    { $m += ("unexpected extra files: " + ($extra -join ' , ') + "; ") }
    $m
}

function SevenZip([string[]]$A) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $SevenZ @A 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { Skip-Test ("7z.exe fixture failed (" + $code + "): " + ($out -join ' ')) }
}

function Py([string]$file, [string]$code, [string[]]$A) {
    Set-Content -LiteralPath $file -Value $code -Encoding ASCII
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & python -I $file @A 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($rc -ne 0) { Skip-Test ("python fixture failed: " + ($out -join ' ')) }
}

# The settings file is reset before every case; this one starts the case from the given JSON.
function With-Settings([string]$json, [scriptblock]$body) {
    $cfg = $env:MAKEPACK_SETTINGS
    [IO.File]::WriteAllText($cfg, $json)
    & $body $cfg
}

# The clipboard text once it is no longer $Old (the app retries a busy clipboard for 3 s; RDP clipboard sync
# can hold it that long), or $Old after $Sec seconds.
function Wait-Clipboard([string]$Old, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    do {
        Start-Sleep -Milliseconds 250
        $c = $null
        try { $c = Get-Clipboard -Raw } catch { }
        if ($c -and $c -ne $Old) { return $c }
    } while ((Get-Date) -lt $deadline)
    $Old
}

# Puts back from the Recycle Bin what one case sent there: items named like $Like that came from $Folder.
function Restore-FromBin([string]$Like, [string]$Folder) {
    $bin = (New-Object -ComObject Shell.Application).Namespace(10)
    $restore = (@(0x0412, 0x0456, 0x0434, 0x043D, 0x043E, 0x0432, 0x0438, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
    $found = $false
    foreach ($it in @($bin.Items())) {
        if ($it.Name -notlike $Like -or $bin.GetDetailsOf($it, 1) -ne $Folder) { continue }
        $found = $true
        foreach ($v in @($it.Verbs())) { if ($v.Name.Replace('&', '') -in @('Restore', $restore)) { $v.DoIt(); break } }
    }
    Start-Sleep -Milliseconds 800
    $found
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Only -and $Only -ne $Name) { return }
    Kill-App
    $env:MAKEPACK_INSTANCE = 'MakePack-bugtest-' + $Rand + '-' + $Name
    Remove-Item -LiteralPath $env:MAKEPACK_SETTINGS -ErrorAction SilentlyContinue
    try {
        & $Body
        Write-Host ("PASS " + $Name)
        $script:nPass++
    } catch {
        $m = $_.Exception.Message
        if ($m -like 'SKIP:*') {
            Write-Host ("SKIP " + $Name + ": " + $m.Substring(5).Trim()); $script:nSkip++
        } else {
            $where = ""
            if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { $where = " [line " + $_.InvocationInfo.ScriptLineNumber + "]" }
            Write-Host ("FAIL " + $Name + ": " + $m + $where); $script:nFail++
        }
    } finally { Kill-App }
}

# ---------- the app's own wording ----------
# Read straight out of src\strings.zig so this file can stay ASCII. Returns @(uk, en): which of the two is on
# screen depends on the UI language of the machine running the test, so assertions accept either.
# Names are Strings.cs's (S.NotAnArchive), strings.zig's are camelCase (notAnArchive).
$script:StringsSrc = $null
function S-Text([string]$Name) {
    if ($null -eq $script:StringsSrc) {
        $f = Join-Path $PSScriptRoot '..\src\strings.zig'
        if (-not (Test-Path -LiteralPath $f)) { Skip-Test ("strings.zig not found next to the script: " + $f) }
        $script:StringsSrc = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    }
    $zig = $Name.Substring(0, 1).ToLowerInvariant() + $Name.Substring(1)
    $m = [regex]::Match($script:StringsSrc, ('pub const ' + $zig + '\s*=\s*L\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)'))
    if (-not $m.Success) { Skip-Test ("strings.zig has no '" + $zig + "' string") }
    ,@($m.Groups[1].Value, $m.Groups[2].Value)
}

# The library's own wording - A3 says the user must never see it.
function Assert-NoRawLibraryText([string]$text, [string]$where) {
    foreach ($raw in @('SevenZipSharp', 'TAR by mistake', 'Invalid archive', 'error.')) {
        Assert ($text -notlike ('*' + $raw + '*')) ($where + ": raw library text on screen -> " + $text)
    }
}

# Types into the password prompt and presses its OK.
function Drive-Password($app, [string]$Pass) {
    $null = Must-Item $app '##password_input' 15
    Type-Into $app '##password_input' $Pass
    Click $app '##password_ok'
}

function Make-EncryptedFixture([string]$d) {
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'secret1.txt') -Value 'classified one' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'secret2.txt') -Value 'classified two' -Encoding ASCII
    $arc = Join-Path $d 'enc.7z'
    Push-Location $src
    try { SevenZip @('a', '-t7z', '-pSecret', '-mhe=on', $arc, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    Assert (Test-Path -LiteralPath $arc) "fixture enc.7z was not created"
    $arc
}

# The one archive a create run left in $dir named after $base ("payload.7z", "payload.tar.gz"...), or $null.
function Archive-Named([string]$dir, [string]$base) {
    @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.BaseName -eq $base -or $_.Name -like ($base + '.tar.*') }) | Select-Object -First 1
}

# ---------- preflight ----------
$Exe = [System.IO.Path]::GetFullPath($Exe)
if (-not (Test-Path -LiteralPath $Exe)) { Write-Host ("ERROR: " + $Exe + " not found - run 'zig build' first."); exit 2 }
if (-not (Test-Path -LiteralPath $SevenZ)) { Write-Host ("ERROR: fixture tool missing: " + $SevenZ); exit 2 }
New-Dir $Root | Out-Null
Write-Host ("exe : " + $Exe)
Write-Host ("temp: " + $Root)
Write-Host ("reg : HKCU\" + $RegRoot + "   screen: " + $env:MAKEKIT_DISPLAY)
Write-Host ""

# Cyrillic "test" built from char codes so this file stays ASCII.
$UK = (@([char]0x0442, [char]0x0435, [char]0x0441, [char]0x0442) -join '')
$UKFILE = $UK + ' file.txt'

# ---------- 1 ----------
Test-Case 'selftest' {
    $d = New-TestDir 'selftest'
    $out = Join-Path $d 'out.txt'
    $bat = Join-Path $d 'run.cmd'
    Set-Content -LiteralPath $bat -Encoding ASCII -Value @(
        '@echo off',
        ('"' + $Exe + '" --selftest > "' + $out + '" 2>&1'),
        'exit /b %ERRORLEVEL%')
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', (Q $bat) -PassThru -WindowStyle Hidden
    try { $null = $p.Handle } catch { }
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; Assert $false "--selftest did not finish within 120 s (hang)" }
    $code = $p.ExitCode
    $txt = ""
    if (Test-Path -LiteralPath $out) { $txt = [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) }
    $flat = ($txt -replace "\r?\n", " / ")
    Assert ($code -eq 0) ("exit code " + $code + "; output: " + $flat)
    Assert ($txt -match 'ALL OK') ("exit 0 but stdout has no 'ALL OK' (" + $txt.Length + " chars captured): " + $flat)
}

# ---------- 2 ----------
Test-Case 'roundtrip_x_o' {
    $d = New-TestDir 'roundtrip'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'plain.txt') -Value 'hello plain' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src $UKFILE) -Value 'hello unicode' -Encoding UTF8
    Rand-File (Join-Path $src 'big.bin') (5MB) 1234
    $zip = Join-Path $d 'round.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $dst = New-Dir (Join-Path $d 'dst')
    $r = Run-App @('x', (Q $zip), '-o', (Q $dst)) 30000
    Assert (-not $r.TimedOut) ("x -o never exited (30 s); on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("exit code " + $r.Exit)
    $diff = Diff-Trees $src $dst
    Assert ($diff -eq "") $diff
}

# ---------- 3 ----------
Test-Case 'sub_naming' {
    $d = New-TestDir 'subnaming'
    $src = New-Dir (Join-Path $d 'payload')
    Set-Content -LiteralPath (Join-Path $src 'one.txt') -Value 'file one' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'two.txt') -Value 'file two' -Encoding ASCII
    $mk = @'
import tarfile, sys, os
src, dst = sys.argv[1], sys.argv[2]
t = tarfile.open(dst, 'w:gz')
for n in sorted(os.listdir(src)):
    t.add(os.path.join(src, n), arcname=n)
t.close()
print('ok')
'@
    $py = Join-Path $d 'mktar.py'
    $cases = @(
        @{ n = 'pkg';  f = 'pkg.tar.gz' },
        @{ n = 'pkg2'; f = 'pkg2.7z' },
        @{ n = 'pkg3'; f = 'pkg3.tgz' })
    foreach ($c in $cases) {
        $cd  = New-Dir (Join-Path $d $c.n)
        $arc = Join-Path $cd $c.f
        if ($c.f -like '*.7z') {
            Push-Location $src
            try { SevenZip @('a', '-t7z', $arc, '*', '-bso0', '-bsp0') } finally { Pop-Location }
        } else {
            Py $py $mk @($src, $arc)
        }
        Assert (Test-Path -LiteralPath $arc) ("fixture missing: " + $c.f)
        $r = Run-App @('x', (Q $arc), '--sub') 30000
        Assert (-not $r.TimedOut) ($c.f + ": x --sub never exited (30 s); on screen: " + $r.Wins)
        Assert ($r.Exit -eq 0) ($c.f + ": exit code " + $r.Exit)
        $want = Join-Path $cd $c.n
        $dirs = (Get-ChildItem -LiteralPath $cd -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ','
        Assert (Test-Path -LiteralPath $want) ($c.f + ": expected subfolder '" + $c.n + "', found dirs [" + $dirs + "] and files [" + ((Get-ChildItem -LiteralPath $cd -File | ForEach-Object { $_.Name }) -join ',') + "]")
        $files = @(Get-ChildItem -LiteralPath $want -Recurse -File)
        Assert ($files.Count -gt 0) ($c.f + ": subfolder '" + $c.n + "' is empty")
        $tars = @($files | Where-Object { $_.Name -like '*.tar' })
        Assert ($tars.Count -eq 0) ($c.f + ": nested tarball left unpacked (" + (($tars | ForEach-Object { $_.Name }) -join ',') + ") instead of real files")
        $names = @($files | ForEach-Object { $_.Name })
        Assert (($names -contains 'one.txt') -and ($names -contains 'two.txt')) ($c.f + ": expected one.txt + two.txt, got [" + ($names -join ',') + "]")
    }
}

# ---------- 4 ----------
Test-Case 'here_extract' {
    $d = New-TestDir 'here'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value 'aaa' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'b.txt') -Value 'bbb' -Encoding ASCII
    $box = New-Dir (Join-Path $d 'box')
    $zip = Join-Path $box 'here.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $r = Run-App @('x', (Q $zip), '--here') 30000
    Assert (-not $r.TimedOut) ("x --here never exited (30 s); on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("exit code " + $r.Exit)
    foreach ($n in @('a.txt', 'b.txt')) {
        Assert (Test-Path -LiteralPath (Join-Path $box $n)) ($n + " is not next to the archive; archive folder contains [" + (Names-In $box) + "]")
    }
}

# ---------- 5 ----------
Test-Case 'zip_slip' {
    $d = New-TestDir 'zipslip'
    $zip = Join-Path $d 'slip.zip'
    $code = @'
import zipfile, sys
dst = sys.argv[1]
names = ['../evil1.txt', '..\\evil2.txt', 'C:/evil3.txt', 'sub/../../evil4.txt', '\\evil5.txt']
z = zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED)
for i, n in enumerate(names):
    zi = zipfile.ZipInfo('x.txt')
    zi.filename = n
    zi.date_time = (2020, 1, 1, 0, 0, 0)
    z.writestr(zi, 'EVIL %d' % (i + 1))
zi = zipfile.ZipInfo('good.txt')
zi.date_time = (2020, 1, 1, 0, 0, 0)
z.writestr(zi, 'GOOD')
z.close()
print('ok')
'@
    Py (Join-Path $d 'mkslip.py') $code @($zip)
    $dest = New-Dir (Join-Path $d 'dest')
    $p = Start-App @('x', (Q $zip), '-o', (Q $dest))
    # Contract: the unsafe entries are skipped and the run ends with a warning box (or a non-zero exit);
    # either way nothing may land outside $dest and the harmless entry must still be there.
    $app = Connect-App $p 15
    $msg = $null
    if ($app) { $msg = Wait-Item $app '##msg_text' 30 }
    $txt = "<exited>"
    if ($msg) { $txt = Dialog-Text $app }
    $exit = -1
    if ($p.HasExited) { $exit = $p.ExitCode } else { try { $p.Kill(); $p.WaitForExit(3000) | Out-Null } catch { } }
    Assert (($msg -ne $null) -or ($exit -ne 0)) "the unsafe entries were skipped silently: no warning and exit 0"
    $escaped = @()
    foreach ($probe in @($d, $Root, 'C:\', $env:TEMP)) {
        foreach ($h in @(Get-ChildItem -LiteralPath $probe -Filter 'evil*.txt' -File -ErrorAction SilentlyContinue)) { $escaped += $h.FullName }
    }
    Assert ($escaped.Count -eq 0) ("CRITICAL zip-slip: entries escaped the destination -> " + ($escaped -join ' ; ') + " (exit " + $exit + ", on screen: " + $txt + ")")
    Assert (Test-Path -LiteralPath (Join-Path $dest 'good.txt')) ("the harmless entry good.txt was not extracted (exit " + $exit + "); dest contains [" + (Names-In $dest) + "]; on screen: " + $txt)
    Assert-NoRawLibraryText $txt "zip_slip"
    Write-Host ("     note: " + $txt)
}

# ---------- 6 ----------
Test-Case 'unicode_archive_path' {
    $d = New-TestDir 'unipath'
    $dir = New-Dir (Join-Path $d ($UK + ' dir (2)'))
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'u1.txt') -Value 'uni one' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src $UKFILE) -Value 'uni two' -Encoding UTF8
    $zip = Join-Path $dir ($UK + ' arc (x).zip')
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $dst = New-Dir (Join-Path $dir 'out dir')
    $r = Run-App @('x', (Q $zip), '-o', (Q $dst)) 30000
    Assert (-not $r.TimedOut) ("x -o on a unicode archive path never exited (30 s); on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("exit code " + $r.Exit)
    $diff = Diff-Trees $src $dst
    Assert ($diff -eq "") $diff
}

# ---------- 7 ----------
Test-Case 'corrupt_archive' {
    $d = New-TestDir 'corrupt'
    $src = New-Dir (Join-Path $d 'src')
    Rand-File (Join-Path $src 'data.bin') (512KB) 77
    Set-Content -LiteralPath (Join-Path $src 'note.txt') -Value 'note' -Encoding ASCII
    $good = Join-Path $d 'good.7z'
    Push-Location $src
    try { SevenZip @('a', '-t7z', $good, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $bytes = [System.IO.File]::ReadAllBytes($good)
    $cut = [int]($bytes.Length * 0.6)
    $bad = Join-Path $d 'broken.7z'
    $fs = [System.IO.File]::Create($bad)
    try { $fs.Write($bytes, 0, $cut) } finally { $fs.Close() }
    $dst = New-Dir (Join-Path $d 'dst')
    # A truncated 7z is damaged, full stop: its own error box, and never a password prompt.
    $damaged = S-Text 'Damaged'
    $enter = S-Text 'EnterPassword'
    $p = Start-App @('x', (Q $bad), '-o', (Q $dst))
    $app = Connect-App $p 15
    Assert ($app -ne $null) ("truncated 7z: the process exited with code " + $p.ExitCode +
        " instead of reporting the damage in a dialog; dst contains [" + (Names-In $dst) + "]")
    $texts = Wait-Text $app $damaged 15
    $pwWins = Password-Windows $app
    $code = "still running"
    if ($p.HasExited) { $code = [string]$p.ExitCode }
    Assert ($code -eq "still running") ("truncated 7z: the process exited with code " + $code +
        " instead of reporting the damage in a dialog; dst contains [" + (Names-In $dst) + "]")
    Assert (Has-Exact $texts $damaged) ("truncated 7z: expected an error box saying exactly '" + $damaged[0] +
        "'; on screen: " + (Titles $texts))
    Assert (-not (Has-Exact $texts $enter)) ("truncated 7z: a password prompt appeared; on screen: " + (Titles $texts))
    Assert ($pwWins.Count -eq 0) ("truncated 7z: a password window appeared: " + (Titles $pwWins))
    Assert-NoRawLibraryText ($texts -join ' / ') "corrupt_archive"
}

# ---------- 8a ----------
Test-Case 'password_prompt_appears' {
    $d = New-TestDir 'pwprompt'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $enter = S-Text 'EnterPassword'
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $app = Connect-App $p 12
    if (-not $app) { Assert $false ("no password prompt: the process exited with code " + $p.ExitCode + " within 12 s; dst contains [" + (Names-In $dst) + "]") }
    $texts = Wait-Text $app $enter 12
    if ($p.HasExited) { Assert $false ("no password prompt: the process exited with code " + $p.ExitCode + " within 12 s; dst contains [" + (Names-In $dst) + "]") }
    Assert ($texts.Count -gt 0) "no window within 12 s for an encrypted (-mhe=on) archive; expected a password prompt"
    Assert (Has-Exact $texts $enter) ("the first prompt must say exactly '" + $enter[0] + "'; on screen: " + (Titles $texts))
}

# ---------- 8b ----------
Test-Case 'wrong_password' {
    $d = New-TestDir 'pwwrong'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $app = Must-Connect $p 10
    $retry = S-Text 'WrongPasswordRetry'
    Drive-Password $app 'WrongPass'
    $texts = Wait-Text $app $retry 15
    if ($p.HasExited) {
        Assert ($p.ExitCode -ne 0) ("CRITICAL: a wrong password was accepted - exit 0; dst contains [" + (Names-In $dst) + "]")
        Assert $false ("after a wrong password the process exited (code " + $p.ExitCode + ") instead of asking again; on screen: " + (Titles $texts))
    }
    Assert (Has-Exact $texts $retry) ("after a wrong password the prompt must say exactly '" + $retry[0] + "'; on screen: " + (Titles $texts))

    # Cancelling that second prompt ends the run: exit 255 (user break), and no error box (a box would keep it alive).
    $null = Must-Item $app '##password_cancel'
    Click $app '##password_cancel'
    $code = Wait-Exit $app 15
    if ($null -eq $code) { Assert $false ("cancelling the password prompt left the process running; on screen: " + (Dialog-Text $app)) }
    Assert ($code -eq 255) ("a cancelled password prompt must end the run with exit 255, got " + $code)
}

# ---------- 8c ----------
Test-Case 'zip_wrong_password_extract' {
    $d = New-TestDir 'zipwrongpw'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'aes1.txt') -Value 'aes payload one' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'aes2.txt') -Value 'aes payload two' -Encoding ASCII
    $arc = Join-Path $d 'aes.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', '-pSecret', '-mem=AES256', $arc, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    Assert (Test-Path -LiteralPath $arc) "fixture aes.zip was not created"
    $dst = New-Dir (Join-Path $d 'dst')
    $enter = S-Text 'EnterPassword'
    $wrong = S-Text 'WrongPassword'
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    # The names in an AES zip are readable, so the prompt comes from the extraction side, not from the open.
    $app = Connect-App $p 15
    if (-not $app) { Assert $false ("no password prompt for an AES zip: exited with code " + $p.ExitCode) }
    $texts = Wait-Text $app $enter 15
    if ($p.HasExited) { Assert $false ("no password prompt for an AES zip: exited with code " + $p.ExitCode) }
    Assert (Has-Exact $texts $enter) ("no password prompt for an AES zip; on screen: " + (Titles $texts))
    Drive-Password $app 'WrongPass'
    $texts2 = Wait-Text $app $wrong 25
    $code = "still running"
    if ($p.HasExited) { $code = [string]$p.ExitCode }
    Assert (Has-Exact $texts2 $wrong) ("a wrong password on an AES zip must raise an error box saying exactly '" +
        $wrong[0] + "' (process: " + $code + "); on screen: " + (Titles $texts2))
}

# ---------- 9 ----------
Test-Case 'right_password_via_uia' {
    $d = New-TestDir 'pwright'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $app = Must-Connect $p 10
    Drive-Password $app 'Secret'
    $code = Wait-Exit $app 20
    if ($null -eq $code) {
        Assert $false ("correct password: still running after 20 s; on screen: " + (Dialog-Text $app) + "; dst contains [" + (Names-In $dst) + "]")
    }
    Assert ($code -eq 0) ("correct password: exit code " + $code + "; dst contains [" + (Names-In $dst) + "]")
    foreach ($n in @('secret1.txt', 'secret2.txt')) {
        Assert (Test-Path -LiteralPath (Join-Path $dst $n)) ($n + " missing after a successful decrypt; dst contains [" + (Names-In $dst) + "]")
    }
}

# ---------- 10 ----------
Test-Case 'multi_select_aggregation' {
    $d = New-TestDir 'multisel'
    $ps = @()
    foreach ($i in 1..3) {
        $f = Join-Path $d ("item" + $i + ".txt")
        Set-Content -LiteralPath $f -Value ("payload " + $i) -Encoding ASCII
        $ps += (Start-App @('a', (Q $f)))
    }
    Start-Sleep -Seconds 3
    $alive = Alive $ps
    Assert ($alive.Count -eq 1) ("expected exactly 1 surviving process after 3 back-to-back 'a' invocations, found " + $alive.Count)
    $app = Connect-App $alive[0] 5
    Assert ($app -ne $null) "the surviving process has no window (the instance holding the dialog was the one that died)"
    $dlg = Wait-Item $app '##compress_create' 5
    Assert ($dlg -ne $null) ("the surviving process shows no create dialog; on screen: " + (Dialog-Text $app))
    $ins = @(Items $app | Where-Object { $_.label -match '##compress_in\d+$' })
    Write-Host ("     note: dialog " + (Titles (Windows $app)) + ", " + $ins.Count + " input(s)")
}

# ---------- 11 ----------
Test-Case 'non_archive_input' {
    $d = New-TestDir 'nonarchive'
    $f = Join-Path $d 'notanarchive.txt'
    Set-Content -LiteralPath $f -Value 'this is plain text, definitely not an archive' -Encoding ASCII
    $notArchive = S-Text 'NotAnArchive'
    $p = Start-App @((Q $f))
    $app = Connect-App $p 12
    if (-not $app) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
    $texts = Wait-Text $app $notArchive 12
    if ($texts.Count -eq 0) {
        if ($p.HasExited) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
        Assert $false "no window within 12 s and the process is still running (silent hang)"
    }
    # A4: plain text gets an error box, never a password prompt.
    $prompt = Password-Windows $app
    Assert ($prompt.Count -eq 0) ("a password prompt appeared for a plain text file; windows " + (Titles $prompt) + "; on screen: " + (Titles $texts))
    Assert (Has-Exact $texts $notArchive) ("plain text must be reported as exactly '" + $notArchive[0] + "'; on screen: " + (Titles $texts))
    Assert-NoRawLibraryText ($texts -join ' / ') "non_archive_input"
}

# ---------- 11b ----------
Test-Case 'notarchive_named_7z' {
    $d = New-TestDir 'named7z'
    $f = Join-Path $d 'x.7z'
    Set-Content -LiteralPath $f -Value 'plain text wearing an archive extension' -Encoding ASCII
    $notArchive = S-Text 'NotAnArchive'
    $enter = S-Text 'EnterPassword'
    $p = Start-App @((Q $f))
    $app = Connect-App $p 12
    if (-not $app) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
    $texts = Wait-Text $app $notArchive 12
    if ($p.HasExited) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
    Assert ($texts.Count -gt 0) "no window within 12 s for a text file named x.7z (silent hang)"
    # The extension says archive, the bytes do not: that is "not an archive", not a password question.
    Assert (Has-Exact $texts $notArchive) ("a text file named x.7z must be reported as exactly '" + $notArchive[0] + "'; on screen: " + (Titles $texts))
    Assert (-not (Has-Exact $texts $enter)) ("a text file named x.7z got a password prompt; on screen: " + (Titles $texts))
    Assert ((Password-Windows $app).Count -eq 0) ("a password window appeared; windows " + (Titles (Windows $app)))
}

# ---------- 12 ----------
Test-Case 'gui_open_lists_entries' {
    $d = New-TestDir 'guiopen'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'inside1.txt') -Value 'x' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'inside2.txt') -Value 'y' -Encoding ASCII
    $zip = Join-Path $d 'viewme.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $p = Start-App @((Q $zip))
    $app = Connect-App $p 8
    Assert ($app -ne $null) ("the process exited with code " + $p.ExitCode + " instead of showing the archive list")
    $row = Wait-Item $app 'inside1.txt###r' 8
    Assert ($row -ne $null) ("the list does not show inside1.txt; on screen: " + (Dialog-Text $app))
    $t = Find-Item $app '###title'
    $p.Refresh()
    $titles = @($p.MainWindowTitle, $(if ($t) { Text-Of $t.label } else { '' }))
    Assert ($p.MainWindowTitle -like '*viewme.zip*') ("the window title does not contain the archive file name 'viewme.zip'; titles " + (Titles $titles))
    Assert ($t -and $t.label -like '*viewme.zip*') ("the ###title item does not contain 'viewme.zip'; titles " + (Titles $titles))
}

# ---------- 13 ----------
Test-Case 'trailing_backslash_arg' {
    $d = New-TestDir 'trailslash'
    $folder = New-Dir (Join-Path $d 'folder')
    Set-Content -LiteralPath (Join-Path $folder 'f.txt') -Value 'z' -Encoding ASCII
    $p = Start-App @('a', (Q ($folder + '\')))
    $app = Connect-App $p 5
    if (-not $app) { Assert $false ("exited with code " + $p.ExitCode + " on an argument that ends with a backslash before the closing quote (Explorer drive-root case)") }
    $dlg = Wait-Item $app '##compress_create' 5
    if ($p.HasExited) { Assert $false ("exited with code " + $p.ExitCode + " on an argument that ends with a backslash before the closing quote (Explorer drive-root case)") }
    Assert ($dlg -ne $null) ("no create dialog within 5 s for a trailing-backslash path argument; on screen: " + (Dialog-Text $app))
    $in = @(Items $app | Where-Object { $_.label -match '##compress_in\d+$' } | ForEach-Object { Text-Of $_.label })
    Write-Host ("     note: window " + (Titles (Windows $app)) + " inputs " + (Titles $in))
}

# ---------- 14 ----------
Test-Case 'readonly_target_overwrite' {
    Skip-Test "extracting over existing files raises the Ask conflict prompt; covered by tools\gui_dialogs.ps1 (queue), not here"
}

# ---------- 15 ----------
Test-Case 'big_archive_smoke' {
    $d = New-TestDir 'big'
    $src = New-Dir (Join-Path $d 'src')
    foreach ($i in 1..3) { Rand-File (Join-Path $src ("blob" + $i + ".bin")) (20MB) (100 + $i) }
    $zip = Join-Path $d 'big.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', '-mx0', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $dst = New-Dir (Join-Path $d 'dst')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Run-App @('x', (Q $zip), '-o', (Q $dst)) 60000
    $sw.Stop()
    Assert (-not $r.TimedOut) ("a 60 MB extract did not finish within 60 s; on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("exit code " + $r.Exit)
    $diff = Diff-Trees $src $dst
    Assert ($diff -eq "") $diff
    Write-Host ("     note: 60 MB extracted in " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + " s")
}

# ---------- 16 ----------
Test-Case 'cancel_compress' {
    $d = New-TestDir 'cancelpack'
    $src = New-Dir (Join-Path $d 'payload')
    # 30 MB of letters, not 300 MB of random bytes: random bytes are stored at memcpy speed (nothing to cancel),
    # and past 7-Zip's multithreading block size (64 MB at this level) 7z.dll swallows every input file in the
    # first half second, after which the library offers no cancel point at all. 30 MB = ~15 s of real work with
    # a cancel point at every file.
    foreach ($i in 1..10) { [Mp.Gen]::Letters((Join-Path $src ("blob" + $i + ".txt")), 3MB, (500 + $i)) }
    $p = Start-App @('a', (Q $src))
    $app = Must-Connect $p 20
    $null = Must-Item $app '##compress_create' 20
    Click $app '##compress_create'

    $prog = Wait-Item $app '##progress_cancel' 30
    Assert ($prog -ne $null) ("no progress window within 30 s of clicking Create; exited=" + $p.HasExited +
        " windows " + (Titles (Windows $app)) + " archives=[" + (Names-In $d) + "]")
    Start-Sleep -Seconds 3                                   # let it write a real chunk of the archive
    Click $app '##progress_cancel'

    $back = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { $back = $true; break }
        if (-not (Find-Item $app '##progress_cancel')) { $back = $true; break }   # progress gone, create dialog back
        Start-Sleep -Milliseconds 500
    }
    $txt = ""
    if (-not $p.HasExited) { $txt = Dialog-Text $app }
    try { $p.Kill(); $p.WaitForExit(3000) | Out-Null } catch { }
    Assert $back ("the progress window was still up 30 s after Cancel; on screen: " + $txt)
    Start-Sleep -Milliseconds 700
    $left = @(Get-ChildItem -LiteralPath $d -File | Where-Object { $_.Name -like 'payload.*' })
    Assert ($left.Count -eq 0) ("a cancelled compression left a broken archive behind: " + (($left | ForEach-Object { $_.Name + ' (' + [math]::Round($_.Length / 1MB, 1) + ' MB)' }) -join ', '))
}

# ---------- 17 ----------
# --register / --unregister under the test root (MAKEPACK_REGROOT): the real HKCU and the installed MakePack are
# never touched, so there is nothing to hand back afterwards.
Test-Case 'assoc_roundtrip' {
    $cls  = $RegHK + '\Software\Classes\.mkptest'
    $verb = $RegHK + '\Software\Classes\SystemFileAssociations\.mkptest\shell\MakePack.ExtractHere'
    try {
        $r = Run-App @('--register', 'mkptest') 30000
        Assert (-not $r.TimedOut) "--register mkptest never exited (30 s)"
        Assert ($r.Exit -eq 0) ("--register mkptest exit code " + $r.Exit)
        Assert (-not (Test-Path -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\Classes\.mkptest')) "--register wrote to the REAL HKCU despite MAKEPACK_REGROOT"

        Assert (Test-Path -LiteralPath $cls) ("HKCU\" + $RegRoot + "\Software\Classes\.mkptest was not created")
        $def = (Get-Item -LiteralPath $cls).GetValue('')
        Assert ($def -eq 'MakePack.Archive') ("default handler is '" + $def + "', expected MakePack.Archive")
        Assert (Test-Path -LiteralPath ($verb + '\command')) "the ExtractHere verb key was not created"
        $cmd = (Get-Item -LiteralPath ($verb + '\command')).GetValue('')
        Assert ($cmd -like '*--here*') ("ExtractHere command is '" + $cmd + "'")
        $owp = $cls + '\OpenWithProgids'
        Assert (Test-Path -LiteralPath $owp) "OpenWithProgids key was not created"
        Assert ((Get-Item -LiteralPath $owp).GetValue('MakePack.Archive') -ne $null) "OpenWithProgids has no MakePack.Archive value"

        $r2 = Run-App @('--unregister', 'mkptest') 30000
        Assert (-not $r2.TimedOut) "--unregister mkptest never exited (30 s)"
        Assert ($r2.Exit -eq 0) ("--unregister mkptest exit code " + $r2.Exit)
        $left = $null
        if (Test-Path -LiteralPath $cls) { $left = (Get-Item -LiteralPath $cls).GetValue('') }
        Assert ($left -eq $null) ("the default handler survived --unregister: '" + $left + "'")
        Assert (-not (Test-Path -LiteralPath $verb)) "the ExtractHere verb key survived --unregister"
    }
    finally { Remove-Item -LiteralPath $RegHK -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- 18 ----------
Test-Case 'nested_split' {
    $d = New-TestDir 'split'
    $src = New-Dir (Join-Path $d 'src')
    $file = Join-Path $src 'payload.bin'
    Rand-File $file (3MB) 4242
    SevenZip @('a', '-v1m', (Join-Path $d 'parts.7z'), $file, '-bso0', '-bsp0')
    $p001 = Join-Path $d 'parts.7z.001'
    Assert (Test-Path -LiteralPath $p001) ("fixture parts.7z.001 missing; folder has [" + (Names-In $d) + "]")
    $dst = New-Dir (Join-Path $d 'out')
    $r = Run-App @('x', (Q $p001), '-o', (Q $dst)) 60000
    Assert (-not $r.TimedOut) ("x on parts.7z.001 never exited (60 s); on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("exit code " + $r.Exit + "; out contains [" + (Names-In $dst) + "]")
    $names = @(Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $_.Name })
    Assert ($names -notcontains 'parts.7z') ("the split container was unpacked to a plain parts.7z instead of its contents [" + ($names -join ',') + "]")
    Assert ($names -contains 'payload.bin') ("expected payload.bin, got [" + ($names -join ',') + "]")
    $h1 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath (Join-Path $dst 'payload.bin') -Algorithm SHA256).Hash
    Assert ($h1 -eq $h2) "the file extracted from the split archive differs from the original"
}

# ---------- 18b ----------
# Volumes through the real dialog: type a size into the Volumes box, Create, then x the .001 set back.
Test-Case 'create_volumes' {
    $d = New-TestDir 'volumes'
    $src = New-Dir (Join-Path $d 'payload')
    $file = Join-Path $src 'payload.bin'
    Rand-File $file (3MB) 777
    $p = Start-App @('a', (Q $src))
    $app = Must-Connect $p 20
    $null = Must-Item $app '##compress_create' 20
    Type-Into $app '##compress_volumes' '1 MB'
    Click $app '##compress_create'
    $code = Wait-Exit $app 60
    Assert ($null -ne $code) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $app))
    Assert ($code -eq 0) ("create exit code " + $code)

    # The archive path in the box is not readable over automation: the parts are found by name instead.
    $parts = @(Get-ChildItem -LiteralPath $d -File | Where-Object { $_.Name -match '^payload\.[^.]+\.\d{3}$' })
    Assert ($parts.Count -ge 3) ("expected 3+ parts of 1 MB, folder has [" + (Names-In $d) + "]")
    Assert (@($parts | Where-Object { $_.Length -gt 1MB }).Count -eq 0) "a part is larger than 1 MB"
    $archive = Join-Path $d ($parts[0].Name -replace '\.\d{3}$', '')
    Assert (-not (Test-Path -LiteralPath $archive)) "a whole archive was left next to the parts"

    $dst = New-Dir (Join-Path $d 'out')
    $r = Run-App @('x', (Q ($archive + '.001')), '-o', (Q $dst)) 60000
    Assert (-not $r.TimedOut) ("x on the .001 never exited (60 s); on screen: " + $r.Wins)
    Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
    $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.bin' | Select-Object -First 1
    Assert ($back -ne $null) ("payload.bin not extracted; out has [" + (Names-In $dst) + "]")
    Assert ((Get-FileHash -LiteralPath $file).Hash -eq (Get-FileHash -LiteralPath $back.FullName).Hash) "the extracted file differs"
}

# ---------- 18c ----------
# Test + delete through the real dialog: tick both boxes, Create, the archive is there and the sources are in the
# Recycle Bin. The test then puts them back from the bin so the user's bin is left as it was.
Test-Case 'create_test_delete' {
    $d = New-TestDir 'testdelete'
    $src = New-Dir (Join-Path $d 'tobin')
    Set-Content -LiteralPath (Join-Path $src 'keep.txt') -Value ('payload ' * 2000) -Encoding ASCII
    $p = Start-App @('a', (Q $src))
    $app = Must-Connect $p 20
    $null = Must-Item $app '##compress_create' 20
    Set-Check $app '##compress_test_after' $true
    Set-Check $app '##compress_delete_sources' $true
    Click $app '##compress_create'
    $code = Wait-Exit $app 60
    Assert ($null -ne $code) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $app))
    $gone = -not (Test-Path -LiteralPath $src)
    $inBin = $false
    if ($gone) { $inBin = Restore-FromBin 'tobin' $d }   # first, whatever fails below: the bin is left as it was
    $archive = Archive-Named $d 'tobin'
    Assert ($archive -ne $null) ("no tobin archive; folder has [" + (Names-In $d) + "]")
    Assert $gone "the source folder is still there after Create with delete ticked"
    Assert $inBin "the source folder is not in the Recycle Bin"
    Assert (Test-Path -LiteralPath (Join-Path $src 'keep.txt')) "restoring the source folder from the Recycle Bin failed"
    Assert ($code -eq 0) ("create exit code " + $code)
}

# ---------- 18d ----------
# Each item to its own archive through the real dialog: three folders in, three archives out, next to them.
Test-Case 'create_separate' {
    $d = New-TestDir 'separate'
    $ins = @()
    foreach ($n in 'alpha', 'beta', 'gamma') {
        $f = New-Dir (Join-Path $d $n)
        Set-Content -LiteralPath (Join-Path $f ($n + '.txt')) -Value ('payload ' + $n) -Encoding ASCII
        $ins += (Q $f)
    }
    $p = Start-App (@('a') + $ins)
    $app = Must-Connect $p 20
    $null = Must-Item $app '##compress_create' 20
    Set-Check $app '##compress_separate' $true
    $outBox = Find-Item $app '##compress_out'
    Assert ($outBox -ne $null -and $outBox.disabled) "the Archive path box stays enabled with separate archives ticked"
    Click $app '##compress_create'
    $code = Wait-Exit $app 60
    Assert ($null -ne $code) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $app))
    Assert ($code -eq 0) ("create exit code " + $code)

    foreach ($n in 'alpha', 'beta', 'gamma') {
        $arc = @(Get-ChildItem -LiteralPath $d -File | Where-Object { $_.BaseName -eq $n -or $_.Name -like ($n + '.tar.*') })
        Assert ($arc.Count -eq 1) ("expected one archive for " + $n + ", folder has [" + (Names-In $d) + "]")
        $dst = New-Dir (Join-Path $d ('out-' + $n))
        $r = Run-App @('x', (Q $arc[0].FullName), '-o', (Q $dst)) 60000
        Assert ($r.Exit -eq 0) ("x " + $arc[0].Name + " exit code " + $r.Exit)
        $got = @(Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $_.Name })
        Assert (($got -join ',') -eq ($n + '.txt')) ($arc[0].Name + " holds [" + ($got -join ',') + "]")
    }
}

# ---------- 18e ----------
# SFX through the real dialog: the box turns the archive into .exe and greys out Volumes; the exe then unpacks
# itself with 7z.sfx's own -y -o switches, no MakePack involved.
Test-Case 'create_sfx' {
    $d = New-TestDir 'sfx'
    $src = New-Dir (Join-Path $d 'payload')
    $file = Join-Path $src 'payload.bin'
    Rand-File $file (300KB) 2026
    # The SFX box only exists for 7z: start from a 7z default whatever the user last picked.
    With-Settings '{ "Format": "SevenZip" }' {
        $p = Start-App @('a', (Q $src))
        $app = Must-Connect $p 20
        $null = Must-Item $app '##compress_create' 20
        $sfx = Find-Item $app '##compress_sfx'
        Assert ($sfx -ne $null -and -not $sfx.disabled) "no enabled SFX check box in the create dialog for 7z"
        Set-Check $app '##compress_sfx' $true
        $vol = Find-Item $app '##compress_volumes'
        Assert ($vol -ne $null -and $vol.disabled) "Volumes stays enabled with SFX ticked"
        Click $app '##compress_create'
        $code = Wait-Exit $app 60
        Assert ($null -ne $code) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $app))
        Assert ($code -eq 0) ("create exit code " + $code)
        $archive = Join-Path $d 'payload.exe'
        Assert (Test-Path -LiteralPath $archive) ("with SFX ticked no payload.exe was made; folder has [" + (Names-In $d) + "]")
        Assert (-not (Test-Path -LiteralPath (Join-Path $d 'payload.7z'))) "a plain payload.7z was made next to the SFX"

        $dst = Join-Path $d 'unpacked'
        $run = Start-Process -FilePath $archive -ArgumentList @('-y', ('"-o' + $dst + '"')) -PassThru
        try { $null = $run.Handle } catch { }
        [void]$script:Procs.Add($run)
        Assert ($run.WaitForExit(60000)) "the SFX did not finish within 60 s"
        Assert ($run.ExitCode -eq 0) ("the SFX exited with " + $run.ExitCode)
        $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.bin' | Select-Object -First 1
        Assert ($back -ne $null) ("the SFX unpacked [" + (Names-In $dst) + "]")
        Assert ((Get-FileHash -LiteralPath $file).Hash -eq (Get-FileHash -LiteralPath $back.FullName).Hash) "the file the SFX unpacked differs"
    }
}

# ---------- 18f ----------
# Password options through the real dialog: a mistyped confirmation blocks Create; a matching one with
# ZipCrypto ticked gives a zip that a ZipCrypto-only reader (Python's zipfile has no AES) unpacks.
Test-Case 'create_zipcrypto' {
    $d = New-TestDir 'zipcrypto'
    $src = New-Dir (Join-Path $d 'payload')
    $file = Join-Path $src 'payload.txt'
    Set-Content -LiteralPath $file -Value ('zipcrypto payload ' * 500) -Encoding ASCII
    With-Settings '{ "Format": "Zip" }' {
        $p = Start-App @('a', (Q $src))
        $app = Must-Connect $p 20
        $null = Must-Item $app '##compress_create' 20
        $fmt = Find-Item $app '##compress_format'
        Assert ((Text-Of $fmt.label) -eq 'zip') ("the dialog did not start on zip: " + $fmt.label)
        Type-Into $app '##compress_password' 'hunter2'
        Type-Into $app '##compress_confirm' 'hunter3'
        $archive = Join-Path $d 'payload.zip'
        Click $app '##compress_create'
        $box = Wait-Item $app '##msg_text' 10
        Assert ($box -ne $null) ("no warning for mismatched passwords; on screen: " + (Dialog-Text $app))
        Assert (-not (Test-Path -LiteralPath $archive)) "an archive was written with mismatched passwords"
        Click $app '##msg_ok'

        Type-Into $app '##compress_confirm' 'hunter2'
        $zc = Find-Item $app '##compress_zipcrypto'
        Assert ($zc -ne $null -and $zc.visible -and -not $zc.disabled) "no visible ZipCrypto check box for a zip"
        Set-Check $app '##compress_zipcrypto' $true
        Click $app '##compress_create'
        $code = Wait-Exit $app 60
        Assert ($null -ne $code) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $app))
        Assert (Test-Path -LiteralPath $archive) ("no archive at " + $archive + "; folder has [" + (Names-In $d) + "]")

        $dst = Join-Path $d 'py-out'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2], pwd=b'hunter2')" $archive $dst 2>&1
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Assert ($rc -eq 0) ("Python's zipfile (ZipCrypto only) could not unpack it: " + ($out -join ' '))
        $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.txt' | Select-Object -First 1
        Assert ($back -ne $null -and (Get-FileHash -LiteralPath $back.FullName).Hash -eq (Get-FileHash -LiteralPath $file).Hash) "the ZipCrypto zip unpacked to something else"
    }
}

# ---------- 18g ----------
# a --profile: no dialog, the profile's options, and Explorer's per-item invocations of one multi-selection
# (two processes here) end up in ONE archive named after their folder.
Test-Case 'profile_cli' {
    $d = New-TestDir 'profcli'
    $set = New-Dir (Join-Path $d 'set')
    $one = New-Dir (Join-Path $set 'one'); Set-Content -LiteralPath (Join-Path $one 'one.txt') -Value 'one' -Encoding ASCII
    $two = New-Dir (Join-Path $set 'two'); Set-Content -LiteralPath (Join-Path $two 'two.txt') -Value 'two' -Encoding ASCII
    With-Settings '{ "Profiles": [ { "Name": "Quick zip", "Format": "Zip", "Level": "Fast", "TestAfter": true } ] }' {
        $p1 = Start-App @('a', '--profile', (Q 'Quick zip'), (Q $one))
        $p2 = Start-App @('a', '--profile', (Q 'Quick zip'), (Q $two))
        Assert ($p1.WaitForExit(60000)) ("a --profile never exited; on screen: " + (Dialog-Text $p1))
        Assert ($p2.WaitForExit(10000)) ("the second a --profile never exited; on screen: " + (Dialog-Text $p2))
        Assert ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) ("a --profile exit codes " + $p1.ExitCode + " / " + $p2.ExitCode)
        $zips = @(Get-ChildItem -LiteralPath $set -File -Filter '*.zip')
        Assert ($zips.Count -eq 1 -and $zips[0].Name -eq 'set.zip') ("expected one set.zip for both items, got [" + (Names-In $set) + "]")
        $dst = New-Dir (Join-Path $d 'out')
        $r = Run-App @('x', (Q $zips[0].FullName), '-o', (Q $dst)) 60000
        Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
        $got = @(Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        Assert (($got -join ',') -eq 'one.txt,two.txt') ("set.zip holds [" + ($got -join ',') + "]")

        $p = Start-App @('a', '--profile', (Q 'No such profile'), (Q $one))
        $app = Connect-App $p 8
        $msg = $null
        if ($app) { $msg = Wait-Item $app '##msg_text' 8 }
        Assert ($msg -ne $null -and $msg.label -like '*No such profile*') ("an unknown profile did not stop with a message; on screen: " + $(if ($app) { Dialog-Text $app } else { 'exit ' + $p.ExitCode }))
        Assert (@(Get-ChildItem -LiteralPath $set -File).Count -eq 1) "an unknown profile still wrote an archive"
    }
}

# ---------- 18h ----------
# Profiles in the dialog: the default one is applied on open, picking another one changes the options,
# Save... stores the current options under a new name. The option boxes are read back through saved profiles
# (an input box's text is not readable over automation).
Test-Case 'profile_dialog' {
    $d = New-TestDir 'profdlg'
    $src = New-Dir (Join-Path $d 'payload')
    Set-Content -LiteralPath (Join-Path $src 'p.txt') -Value 'p' -Encoding ASCII
    $json = '{ "Profiles": [ { "Name": "Big zip", "IsDefault": true, "Format": "Zip", "Level": "Ultra", "Volumes": "100 MB", "TestAfter": true },' +
            ' { "Name": "Plain 7z", "Format": "SevenZip", "Level": "Normal" } ] }'
    With-Settings $json {
        param($cfg)
        $p = Start-App @('a', (Q $src))
        $app = Must-Connect $p 20
        $null = Must-Item $app '##compress_create' 20
        function Save-As([string]$name) {
            Click $app '##compress_save_profile'
            $null = Must-Item $app '##name_input' 10
            Type-Into $app '##name_input' $name
            Click $app '##name_ok'
            $null = Invoke-AutoFrames $app 3
            Start-Sleep -Milliseconds 300
            $all = (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).Profiles
            @($all | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
        }
        $state = "profile=" + (Text-Of (Find-Item $app '##compress_profile').label) + " format=" + (Text-Of (Find-Item $app '##compress_format').label)
        Assert ($state -like 'profile=Big zip*format=zip') ("the default profile was not applied on open: " + $state)
        Assert ([bool](Find-Item $app '##compress_test_after').checked) "the profile's Test box is not ticked"
        $snap = Save-As 'Snap'
        Assert ($snap -ne $null) ("Save... did not store the profile: " + ((Get-Content -LiteralPath $cfg -Raw) -replace '\s+', ' '))
        Assert ($snap.Format -eq 'Zip' -and $snap.Volumes -eq '100 MB' -and $snap.TestAfter) ("the default profile was not applied on open: saved " + ($snap | ConvertTo-Json -Compress))

        Pick $app 'compress_profile' 'Plain 7z*'
        $fmt = Text-Of (Find-Item $app '##compress_format').label
        Assert ($fmt -eq '7z') ("picking Plain 7z gave format=" + $fmt)
        $mine = Save-As 'Mine'
        Assert ($mine -ne $null) ("Save... did not store the profile: " + ((Get-Content -LiteralPath $cfg -Raw) -replace '\s+', ' '))
        Assert ($mine.Format -eq 'SevenZip' -and [string]::IsNullOrEmpty($mine.Volumes)) ("picking Plain 7z gave " + ($mine | ConvertTo-Json -Compress))
        $saved = [IO.File]::ReadAllText($cfg)
        Assert ($saved -notmatch 'Password') "a saved profile carries a password"
    }
}

# ---------- 18i ----------
# Profiles in Settings (opened standalone with --settings): delete one, rename one, make one the default, OK.
Test-Case 'profile_settings' {
    $json = '{ "Profiles": [ { "Name": "Alpha", "IsDefault": true }, { "Name": "Beta" }, { "Name": "Gamma" } ] }'
    With-Settings $json {
        param($cfg)
        $p = Start-App @('--settings')
        $app = Must-Connect $p 20
        $null = Must-Item $app '##settings_ok' 20
        function Choose([string]$name) {
            $it = @(Items $app | Where-Object { $_.label -match '##settings_p\d+$' -and (Text-Of $_.label) -like ($name + '*') }) | Select-Object -First 1
            Assert ($it -ne $null) ("no '" + $name + "' in the profile list")
            Click $app $it.label
        }
        # The Mark-of-the-Web policy rides along: Never / Risky / All -> All.
        Click $app '##settings_motw'; Click $app '##settings_motw_2'

        Choose 'Beta';  Click $app '##settings_delete'
        Choose 'Gamma'; Click $app '##settings_default'
        Choose 'Alpha'; Click $app '##settings_rename'
        $null = Must-Item $app '##name_input' 10
        Type-Into $app '##name_input' 'Alpha2'
        Click $app '##name_ok'
        Click $app '##settings_ok'
        $code = Wait-Exit $app 15
        Assert ($null -ne $code) ("Settings did not close after OK; on screen: " + (Dialog-Text $app))

        $saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
        $names = @($saved.Profiles | ForEach-Object { $_.Name + $(if ($_.IsDefault) { '*' } else { '' }) }) -join ','
        Assert ($names -eq 'Alpha2,Gamma*') ("profiles after delete/rename/default: " + $names)
        Assert ($saved.Motw -eq 'All') ("the Mark-of-the-Web choice was saved as '" + $saved.Motw + "'")
    }
}

# ---------- 18j ----------
# Mark of the Web: an archive tagged as downloaded passes the tag on to the risky files it unpacks (default
# policy), not to plain text, and an untagged archive tags nothing.
Test-Case 'motw_extract' {
    $d = New-TestDir 'motw'
    $src = New-Dir (Join-Path $d 'payload')
    foreach ($f in 'setup.exe', 'report.docx', 'notes.txt') {
        Set-Content -LiteralPath (Join-Path $src $f) -Value ('content of ' + $f) -Encoding ASCII
    }
    $arc = Join-Path $d 'download.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $arc, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $plain = Join-Path $d 'local.zip'
    Copy-Item -LiteralPath $arc -Destination $plain                    # copied before the tag: untagged
    Set-Content -LiteralPath $arc -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
    function Tagged([string]$dir) {
        @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object {
            (Get-Item -LiteralPath $_.FullName -Stream * -ErrorAction SilentlyContinue | Where-Object Stream -eq 'Zone.Identifier') -ne $null
        } | ForEach-Object { $_.Name } | Sort-Object) -join ','
    }
    With-Settings '{}' {
        $dst = New-Dir (Join-Path $d 'out')
        $r = Run-App @('x', (Q $arc), '-o', (Q $dst)) 60000
        Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
        $t = Tagged $dst
        Assert ($t -eq 'report.docx,setup.exe') ("tagged after extracting a downloaded zip: [" + $t + "]")
        $zone = Get-Content -LiteralPath (Join-Path $dst 'setup.exe') -Stream Zone.Identifier -Raw
        Assert ($zone -match 'ZoneId=3') ("the tag on setup.exe reads: " + $zone)

        $dst2 = New-Dir (Join-Path $d 'out-local')
        $r = Run-App @('x', (Q $plain), '-o', (Q $dst2)) 60000
        Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
        $t = Tagged $dst2
        Assert ($t -eq '') ("an untagged zip tagged [" + $t + "]")
    }
}

# ---------- 18k ----------
# Extract options through the real dialog (x without --here/--sub): no folders + archive to the Recycle Bin.
# The files land flat, the archive goes to the bin (put back afterwards), and the choices are remembered.
Test-Case 'extract_dialog_options' {
    $d = New-TestDir 'xopts'
    $src = New-Dir (Join-Path $d 'payload')
    New-Dir (Join-Path $src 'sub\deeper') | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'sub\a.txt') -Value 'a' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'sub\deeper\b.txt') -Value 'b' -Encoding ASCII
    $arc = Join-Path $d 'flatme.7z'
    SevenZip @('a', $arc, $src, '-bso0', '-bsp0')
    $out = Join-Path $d 'out'
    With-Settings '{}' {
        param($cfg)
        $p = Start-App @('x', (Q $arc))
        $app = Must-Connect $p 20
        $null = Must-Item $app '##extract_ok' 20
        Set-Check $app '##extract_sub' $false
        Type-Into $app '##extract_dest' $out
        Click $app '##extract_paths';  Click $app '##extract_paths_1'    # no folders
        Click $app '##extract_delete'; Click $app '##extract_delete_2'   # archive to the Recycle Bin
        Click $app '##extract_ok'
        $code = Wait-Exit $app 60
        Assert ($null -ne $code) ("x did not finish within 60 s; on screen: " + (Dialog-Text $app))

        $gone = -not (Test-Path -LiteralPath $arc)
        $inBin = $false
        if ($gone) { $inBin = Restore-FromBin 'flatme*' $d }   # first, whatever fails below: the bin is left as it was
        $files = @(Get-ChildItem -LiteralPath $out -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($out.Length + 1) } | Sort-Object) -join ','
        Assert ($files -eq 'a.txt,b.txt') ("with no folders the destination holds [" + $files + "]; folder has [" + (Names-In $d) + "]")
        Assert $gone "the archive is still there after 'Move to Recycle Bin'"
        Assert $inBin "the archive is not in the Recycle Bin"
        Assert (Test-Path -LiteralPath $arc) "putting the archive back from the Recycle Bin failed"

        $saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
        Assert ($saved.ExtractNoPaths -eq $true -and $saved.ExtractDeleteAfter -eq 'Recycle') ("the extract choices were not remembered: " + ($saved | ConvertTo-Json -Compress))
        Assert ($code -eq 0) ("x exit code " + $code)
    }
}

# ---------- 18l ----------
# Explorer menu items (ticket 12) under the test root: --addmenu on writes the quick-add item and New > archive,
# the Associations dialog switches items off and picks the quick format, a --quick run packs without a dialog,
# --addmenu off removes the file items.
Test-Case 'menu_items' {
    try {
        $hk = $RegHK + '\Software\Classes\'
        $r = Run-App @('--addmenu', 'on') 30000
        Assert ($r.Exit -eq 0) ("--addmenu on exit code " + $r.Exit)
        $quick = $hk + '*\shell\MakePack.QuickAdd'
        Assert (Test-Path -LiteralPath $quick) "no quick-add item on files after --addmenu on"
        $cmd = (Get-ItemProperty -LiteralPath ($quick + '\command')).'(default)'
        Assert ($cmd -like '*" a --quick "%1"') ("quick-add command: " + $cmd)
        Assert (Test-Path -LiteralPath ($hk + 'Directory\shell\MakePack.QuickAdd')) "no quick-add item on folders"
        $data = (Get-ItemProperty -LiteralPath ($hk + '.7z\MakePack.Archive\ShellNew') -ErrorAction SilentlyContinue).Data
        Assert ($data -ne $null -and $data.Length -eq 32 -and $data[0] -eq 0x37) "no New > archive entry (.7z\MakePack.Archive\ShellNew Data)"

        # The Associations dialog: quick-add and New off, quick format zip, OK.
        $p = Start-App @('--assoc')
        $app = Must-Connect $p 20
        $null = Must-Item $app '##assoc_ok' 20
        $boxes = @(Items $app | Where-Object { $_.label -like '*##assoc_menu_*' })
        Assert ($boxes.Count -eq 7) ("expected 7 menu check boxes, found " + $boxes.Count)
        Set-Check $app '##assoc_menu_quick_add' $false
        Set-Check $app '##assoc_menu_new' $false
        Click $app '##assoc_quick'; Click $app '##assoc_quick_1'      # 7z, zip, ...
        Click $app '##assoc_ok'
        $code = Wait-Exit $app 30
        Assert ($null -ne $code) ("the Associations dialog did not close; on screen: " + (Dialog-Text $app))
        Assert (-not (Test-Path -LiteralPath $quick)) "quick-add is still on files after switching it off"
        Assert (-not (Test-Path -LiteralPath ($hk + '.7z\MakePack.Archive'))) "New > archive is still there after switching it off"
        Assert (Test-Path -LiteralPath ($hk + '*\shell\MakePack.Add')) "Add to archive went too"
        $v = Get-ItemProperty -LiteralPath ($RegHK + '\Software\MakePack')
        Assert ($v.MenuItems -eq 79 -and $v.QuickExt -eq '.zip') ("saved MenuItems=" + $v.MenuItems + " QuickExt=" + $v.QuickExt)   # all but quick add and New

        # a --quick: no dialog, the picked format, named after the folder.
        $d = New-TestDir 'quickadd'
        $f = New-Dir (Join-Path $d 'photos')
        Set-Content -LiteralPath (Join-Path $f 'p.txt') -Value 'p' -Encoding ASCII
        $r = Run-App @('a', '--quick', (Q $f)) 60000
        Assert (-not $r.TimedOut) ("a --quick did not finish; on screen: " + $r.Wins)
        Assert ($r.Exit -eq 0) ("a --quick exit code " + $r.Exit)
        Assert (Test-Path -LiteralPath (Join-Path $d 'photos.zip')) ("expected photos.zip, folder has [" + (Names-In $d) + "]")

        $r = Run-App @('--addmenu', 'off') 30000
        Assert ($r.Exit -eq 0) ("--addmenu off exit code " + $r.Exit)
        Assert (-not (Test-Path -LiteralPath ($hk + '*\shell\MakePack.Add'))) "--addmenu off left Add to archive"
        Assert (-not (Test-Path -LiteralPath ($hk + 'Directory\shell\MakePack.QuickAdd'))) "--addmenu off left quick-add"
        $real = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\Classes\*\shell\MakePack.Add\command' -ErrorAction SilentlyContinue).'(default)'
        Assert (-not ([string]$real).Contains($Exe)) ("the REAL HKCU got an Add item pointing at the test exe: " + $real)
    }
    finally { Remove-Item -LiteralPath $RegHK -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- 18m ----------
# Profiles in Explorer's menu (ticket 13) under the test root: a profile marked "in menu" gets its own classic
# item running a --profile "name"; the Settings button takes it out again.
Test-Case 'profile_menu' {
    $json = '{ "Profiles": [ { "Name": "Mail zip", "Format": "Zip", "InMenu": true }, { "Name": "Plain" } ] }'
    try {
        With-Settings $json {
            param($cfg)
            $hk = $RegHK + '\Software\Classes\'
            $r = Run-App @('--addmenu', 'on') 30000
            Assert ($r.Exit -eq 0) ("--addmenu on exit code " + $r.Exit)
            $item = $hk + '*\shell\MakePack.P01'
            Assert (Test-Path -LiteralPath $item) "no menu item for the profile marked in menu"
            Assert (-not (Test-Path -LiteralPath ($hk + '*\shell\MakePack.P02'))) "a profile not marked in menu got an item"
            $cmd = (Get-ItemProperty -LiteralPath ($item + '\command')).'(default)'
            Assert ($cmd -like '*" a --profile "Mail zip" "%1"') ("profile item command: " + $cmd)
            Assert ((Get-ItemProperty -LiteralPath $item).'(default)' -like '*.zip*Mail zip*') ("profile item caption: " + (Get-ItemProperty -LiteralPath $item).'(default)')
            Assert (Test-Path -LiteralPath ($hk + 'Directory\shell\MakePack.P01')) "no profile item on folders"
            $list = Get-ItemProperty -LiteralPath ($RegHK + '\Software\MakePack\MenuProfiles\01')
            Assert ($list.Name -eq 'Mail zip' -and $list.Ext -eq '.zip') "MenuProfiles\01 for the Windows 11 menu"

            # Settings: the In menu button on that profile, OK -> the item is gone.
            $p = Start-App @('--settings')
            $app = Must-Connect $p 20
            $null = Must-Item $app '##settings_ok' 20
            $it = @(Items $app | Where-Object { $_.label -match '##settings_p\d+$' -and (Text-Of $_.label) -like 'Mail zip*' }) | Select-Object -First 1
            Assert ($it -ne $null) "no 'Mail zip' in the profile list"
            Click $app $it.label
            Assert ((Find-Item $app '##settings_in_menu') -ne $null) "no In menu button beside the profile list"
            Click $app '##settings_in_menu'
            Click $app '##settings_ok'
            $code = Wait-Exit $app 15
            Assert ($null -ne $code) ("Settings did not close; on screen: " + (Dialog-Text $app))
            Assert (-not (Test-Path -LiteralPath $item)) "the profile item is still in the menu after taking it out"
            Assert (-not (Test-Path -LiteralPath ($RegHK + '\Software\MakePack\MenuProfiles'))) "MenuProfiles is still there"
        }
    }
    finally { Remove-Item -LiteralPath $RegHK -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- 18n ----------
# Convert archives (ticket 14) through the real dialog: a .rar (made by console Rar.exe when it is
# installed, else a .tar made by 7z.exe) and a .zip in one batch -> 7z. Both 7z hold the same bytes, the
# originals stay, and the dialog closes on its own after the summary - which it only does when there were no errors.
Test-Case 'convert_dialog' {
    $rarExe = Join-Path $env:ProgramFiles 'OtherArc\Rar.exe'
    $d = New-TestDir 'convert'
    $src = New-Dir (Join-Path $d 'payload')
    New-Dir (Join-Path $src 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value ('alpha ' * 3000) -Encoding ASCII
    Rand-File (Join-Path $src 'sub\b.bin') (200KB) 1414
    if (Test-Path -LiteralPath $rarExe) {
        $first = Join-Path $d 'payload.rar'
        & $rarExe a -r -ep1 -idq $first (Join-Path $src '*') | Out-Null
        Assert (Test-Path -LiteralPath $first) "Rar.exe did not make the fixture"
    } else {
        $first = Join-Path $d 'payload.tar'
        Push-Location $src
        try { SevenZip @('a', '-ttar', $first, '*', '-bso0', '-bsp0') } finally { Pop-Location }
        Write-Host "     note: Rar.exe is not installed - converting a .tar instead of a .rar"
    }
    $zip = Join-Path $d 'other.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }

    With-Settings '{}' {
        $p = Start-App @('convert', (Q $first), (Q $zip))
        $app = Must-Connect $p 20
        $null = Must-Item $app '##convert_go' 20
        $items = @(Items $app | Where-Object { $_.label -match '##convert_in\d+$' })
        Assert ($items.Count -eq 2) ("expected the 2 archives in the list, found " + $items.Count)
        # Keep-if-not-smaller off: rar is tight, and this case is about the conversion, not the size race.
        Set-Check $app '##convert_keep' $false
        Click $app '##convert_go'
        $box = Wait-Item $app '##msg_text' 90
        Assert ($box -ne $null) ("no summary after converting; on screen: " + (Dialog-Text $app))
        $summary = Text-Of $box.label
        Write-Host ("     note: " + ($summary -replace '\s+', ' '))
        Click $app '##msg_ok'
        $code = Wait-Exit $app 15
        Assert ($null -ne $code) ("the dialog stayed open after the summary, so something failed: " + $summary)
    }

    foreach ($pair in @(@('payload.7z', $first), @('other.7z', $zip))) {
        $new = Join-Path $d $pair[0]
        Assert (Test-Path -LiteralPath $new) ("no " + $pair[0] + "; folder has [" + (Names-In $d) + "]")
        Assert (Test-Path -LiteralPath $pair[1]) ("the original " + (Split-Path $pair[1] -Leaf) + " is gone")
        $out = New-Dir (Join-Path $d ('out-' + $pair[0]))
        $r = Run-App @('x', (Q $new), '-o', (Q $out)) 60000
        Assert ($r.Exit -eq 0) ("x " + $pair[0] + " exit code " + $r.Exit)
        foreach ($rel in 'a.txt', 'sub\b.bin') {
            $got = Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.FullName.EndsWith('\' + $rel) } | Select-Object -First 1
            Assert ($got -ne $null) ($pair[0] + " lacks " + $rel)
            Assert ((Get-FileHash -LiteralPath $got.FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $src $rel)).Hash) ($rel + " in " + $pair[0] + " differs")
        }
    }
}

# ---------- 18o ----------
# The Info window (ticket 15) from the main window's toolbar, then its Copy button: the clipboard gets the
# method and the archive path. The user's clipboard text is put back afterwards.
Test-Case 'info_window' {
    $d = New-TestDir 'info'
    $src = New-Dir (Join-Path $d 'payload')
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value ('info ' * 20000) -Encoding ASCII
    $arc = Join-Path $d 'info.7z'
    SevenZip @('a', '-m0=LZMA2:d=64k', $arc, $src, '-bso0', '-bsp0')
    $saved = $null
    try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
    $p = Start-App @((Q $arc))
    try {
        $app = Must-Connect $p 20
        $null = Must-Item $app '###status' 20
        $null = Must-Item $app 'payload###r' 10
        Click $app '###tb_info'
        $null = Must-Item $app '##info_copy' 15
        Set-Clipboard -Value 'before'
        Click $app '##info_copy'
        $clip = Wait-Clipboard 'before' 5
        Assert ($clip -match 'LZMA2:16') ("the copied info has no LZMA2:16 method: " + $clip)
        Assert ($clip.Contains($arc)) "the copied info has no archive path"
        Click $app '##info_close'
    }
    finally {
        if ($saved) { Set-Clipboard -Value $saved } else { Set-Clipboard -Value $null }
    }
}

# ---------- 18p ----------
# Report > Copy to clipboard (ticket 16) from the main window's toolbar: the clipboard gets the file list with a
# Cyrillic name intact. The user's clipboard text is put back afterwards.
Test-Case 'report_copy' {
    $d = New-TestDir 'report'
    $src = New-Dir (Join-Path $d 'payload')
    $uk = (@(0x0437, 0x0432, 0x0456, 0x0442) | ForEach-Object { [char]$_ }) -join ''   # a Cyrillic file name
    Set-Content -LiteralPath (Join-Path $src ($uk + '.txt')) -Value 'uk' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'plain.txt') -Value 'plain' -Encoding ASCII
    $arc = Join-Path $d 'report.7z'
    SevenZip @('a', $arc, $src, '-bso0', '-bsp0')
    $saved = $null
    try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
    $p = Start-App @((Q $arc))
    try {
        $app = Must-Connect $p 20
        $null = Must-Item $app 'payload###r' 20
        Assert ((Find-Item $app '###tb_report') -ne $null) "no Report button on the toolbar"
        Click $app '###tb_report'
        $item = Wait-Item $app '###rep_copy' 5
        Assert ($item -ne $null) "no Copy item in the Report menu"
        Set-Clipboard -Value 'before'
        Click $app '###rep_copy'
        $clip = Wait-Clipboard 'before' 5
        Assert ($clip -match 'plain\.txt' -and $clip.Contains($uk + '.txt')) ("the copied report lacks a file: " + $clip)
        Assert ($clip.Contains($arc)) "the copied report has no archive path"
    }
    finally {
        if ($saved) { Set-Clipboard -Value $saved } else { Set-Clipboard -Value $null }
    }
}

# ---------- 18q ----------
# The scripted CLI (ticket 17): t / l / a -switches / x -y run in their own process with no window and end with
# exit codes. Every code is checked on a real process; stdout and stderr go to files.
function Run-Cli([string[]]$A, [int]$TimeoutMs = 60000) {
    $out = Join-Path $Root ('cli-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $err = $out + '.err'
    $p = Start-Process -FilePath $Exe -ArgumentList $A -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # without a held handle ExitCode comes back empty once the process is gone
    [void]$script:Procs.Add($p)
    $wins = ""
    if (-not $p.WaitForExit($TimeoutMs)) { $wins = Dialog-Text $p; try { $p.Kill() } catch { }; $code = -1 } else { $code = $p.ExitCode }
    $o = if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllText($out) } else { "" }
    $e = if (Test-Path -LiteralPath $err) { [System.IO.File]::ReadAllText($err) } else { "" }
    [pscustomobject]@{ Exit = $code; Out = $o; Err = $e; Wins = $wins }
}

Test-Case 'cli_exit_codes' {
    $d = New-TestDir 'cli'
    $src = New-Dir (Join-Path $d 'payload')
    Rand-File (Join-Path $src 'one.bin') 200000 17
    Set-Content -LiteralPath (Join-Path $src 'two.txt') -Value ('two ' * 5000) -Encoding ASCII
    function Expect([int]$Want, [string[]]$A, [string]$What) {
        $r = Run-Cli $A
        Assert ($r.Exit -eq $Want) ($What + ": exit " + $r.Exit + ", expected " + $Want + "; stderr: " + $r.Err.Trim() + "; on screen: " + $r.Wins)
        $r
    }

    # a with switches: no dialog, the archive is there, format from -t; then t says 0 and l lists it.
    $arc = Join-Path $d 'out.zip'
    Expect 0 @('a', '-m5', '-v100k', '-t7z', (Q $arc), (Q $src)) "a -m5 -v100k -t7z" | Out-Null
    $first = $arc + '.001'
    Assert ((Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath ($arc + '.002'))) "a -v100k made no volume set"
    Expect 0 @('t', (Q $first)) "t on an intact set" | Out-Null
    $l = Expect 0 @('l', (Q $first)) "l"
    Assert ($l.Out -match 'one\.bin' -and $l.Out -match 'two\.txt') ("l printed no file list to stdout: " + $l.Out)
    $single = Join-Path $d 'single.7z'
    Expect 0 @('a', '-m1', (Q $single), (Q $src)) "a -m1" | Out-Null
    Expect 2 @('a', '-m1', (Q $single), (Q $src)) "a over an existing archive without -y" | Out-Null
    Expect 0 @('a', '-m1', '-y', (Q $single), (Q $src)) "a -y over an existing archive" | Out-Null

    # 7: a password in the arguments is refused, before anything is written.
    $pw = Join-Path $d 'pw.7z'
    $r = Expect 7 @('a', '-pSecret', (Q $pw), (Q $src)) "a -p<value>"
    Assert (-not (Test-Path -LiteralPath $pw)) "a -p<value> still wrote the archive"
    Assert ($r.Err -match 'MAKEPACK_PASSWORD') ("the refusal does not point at the safe way: " + $r.Err)
    Expect 7 @('t', '-pSecret', (Q $first)) "t -p<value>" | Out-Null

    # 10: nothing matches / no such archive.
    Expect 10 @('a', '-y', (Q (Join-Path $d 'x.7z')), (Q (Join-Path $d 'nothing*.xyz'))) "a with a mask matching nothing" | Out-Null
    Expect 10 @('t', (Q (Join-Path $d 'missing.7z'))) "t on a missing archive" | Out-Null

    # 2: not an archive. 3: damaged packed data.
    $txt = Join-Path $d 'plain.txt'
    Set-Content -LiteralPath $txt -Value ('plain text ' * 2000) -Encoding ASCII
    Expect 2 @('t', (Q $txt)) "t on a text file" | Out-Null
    $whole = Join-Path $d 'whole.7z'
    SevenZip @('a', '-t7z', '-mx=1', $whole, (Join-Path $src '*'), '-bso0', '-bsp0')
    $b = [System.IO.File]::ReadAllBytes($whole)
    for ($i = 64; $i -lt [int]($b.Length / 2); $i += 7) { $b[$i] = $b[$i] -bxor 0x5A }
    $bad = Join-Path $d 'bad.7z'
    [System.IO.File]::WriteAllBytes($bad, $b)
    Expect 3 @('t', (Q $bad)) "t on a damaged 7z" | Out-Null

    # 11: encrypted, no password / a wrong one; 0 with the right one from the environment.
    $enc = Make-EncryptedFixture $d
    Expect 11 @('t', (Q $enc)) "t on an encrypted 7z with no password" | Out-Null
    try {
        $env:MAKEPACK_PASSWORD = 'WrongPass'
        Expect 11 @('t', (Q $enc)) "t with a wrong MAKEPACK_PASSWORD" | Out-Null
        $env:MAKEPACK_PASSWORD = 'Secret'
        Expect 0 @('t', (Q $enc)) "t with the right MAKEPACK_PASSWORD" | Out-Null
        $xd = Join-Path $d 'x-enc'
        Expect 0 @('x', '-y', (Q $enc), '-o', (Q $xd)) "x -y with MAKEPACK_PASSWORD" | Out-Null
        Assert (Test-Path -LiteralPath (Join-Path $xd 'secret1.txt')) ("x -y extracted nothing: [" + (Names-In $xd) + "]")
    }
    finally { Remove-Item Env:\MAKEPACK_PASSWORD -ErrorAction SilentlyContinue }

    # 1: x -y on a zip with an entry pointing outside: the rest comes out, the run ends with a warning.
    $slip = Join-Path $d 'slip.zip'
    $code = @'
import zipfile, sys
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('../escaped.txt', 'EVIL')
z.writestr('good.txt', 'GOOD')
z.close()
'@
    Py (Join-Path $d 'mkslip.py') $code @($slip)
    $xs = Join-Path $d 'x-slip'
    Expect 1 @('x', '-y', (Q $slip), '-o', (Q $xs)) "x -y on a zip with an unsafe entry" | Out-Null
    Assert ((Test-Path -LiteralPath (Join-Path $xs 'good.txt')) -and -not (Test-Path -LiteralPath (Join-Path $d 'escaped.txt'))) "x -y on the unsafe zip"

    # 255: t -p asks in a window; Cancel there is a user break.
    $p = Start-App @('t', '-p', (Q $enc))
    $app = Connect-App $p 15
    Assert ($app -ne $null) ("t -p showed no password prompt within 15 s (exit " + $(if ($p.HasExited) { $p.ExitCode } else { 'running' }) + ")")
    Assert ((Wait-Item $app '##password_cancel' 15) -ne $null) ("no Cancel button in the password window; on screen: " + (Dialog-Text $app))
    Click $app '##password_cancel'
    $c = Wait-Exit $app 15
    Assert ($null -ne $c) ("t -p kept running after Cancel; on screen: " + (Dialog-Text $app))
    Assert ($c -eq 255) ("a cancelled prompt must exit 255, got " + $c)
}

# ---------- 19 ----------
Test-Case 'x_multi_single_process' {
    $d = New-TestDir 'multix'
    $zips = @(); $dsts = @()
    foreach ($i in 1..3) {
        $s = New-Dir (Join-Path $d ("src" + $i))
        Set-Content -LiteralPath (Join-Path $s ("f" + $i + ".txt")) -Value ("payload " + $i) -Encoding ASCII
        $zip = Join-Path $d ("m" + $i + ".zip")
        Push-Location $s
        try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
        $zips += $zip
        $dsts += (New-Dir (Join-Path $d ("out" + $i)))
    }
    # Three Explorer-style invocations back to back: one process must serve all three.
    $procs = @()
    foreach ($i in 0..2) { $procs += (Start-App @('x', (Q $zips[$i]), '-o', (Q $dsts[$i]))) }

    Start-Sleep -Milliseconds 1000          # the two clients forward their arguments and exit
    $max = 0
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $n = (Alive $procs).Count
        if ($n -gt $max) { $max = $n }
        if ($n -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    $stuck = Alive $procs
    foreach ($p in $stuck) { try { $p.Kill() } catch { } }
    Assert ($stuck.Count -eq 0) ("" + $stuck.Count + " of 3 'x' invocations never exited within 30 s")
    Assert ($max -le 1) ("expected one shared process, saw " + $max + " MakePack processes at once after the first second")
    foreach ($i in 0..2) {
        $want = "f" + ($i + 1) + ".txt"
        $got = Names-In $dsts[$i]
        Assert ($got -like ("*" + $want + "*")) ("out" + ($i + 1) + " has [" + $got + "], expected " + $want)
    }
    foreach ($p in $procs) { Assert ($p.ExitCode -eq 0) ("a queued extract exited with code " + $p.ExitCode) }
}

# ---------- 20 ----------
Test-Case 'open_reuses_window' {
    $d = New-TestDir 'reuse'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'one.txt') -Value 'one' -Encoding ASCII
    $z1 = Join-Path $d 'first.zip'
    $z2 = Join-Path $d 'second.zip'
    Push-Location $src
    try {
        SevenZip @('a', '-tzip', $z1, '*', '-bso0', '-bsp0')
        SevenZip @('a', '-tzip', $z2, '*', '-bso0', '-bsp0')
    } finally { Pop-Location }
    $ps = @()
    $ps += (Start-App @((Q $z1)))
    Start-Sleep -Seconds 3
    $ps += (Start-App @((Q $z2)))
    Start-Sleep -Seconds 3
    $alive = Alive $ps
    $titles = @()
    foreach ($a in $alive) {
        $a.Refresh(); $titles += $a.MainWindowTitle
        $app = Connect-App $a 5
        if ($app) { $t = Find-Item $app '###title'; if ($t) { $titles += (Text-Of $t.label) }; try { $app.Pipe.Dispose() } catch { } }
    }
    Assert ($alive.Count -eq 1) ("opening a second archive started another process: " + $alive.Count + " alive; titles " + (Titles $titles))
    $hit = @($titles | Where-Object { $_ -like '*second.zip*' })
    Assert ($hit.Count -ge 2) ("the second archive did not take over the window (OS title and ###title); titles " + (Titles $titles))
}

# ---------- 21 ----------
# The in-window editing features: the list is there and the Add toolbar button is on screen. The context menu
# and drag-and-drop need real mouse input; they are covered by tools\dragtest.ps1 (manual only), not here.
Test-Case 'gui_context_menu' {
    $d = New-TestDir 'guimenu'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'inside1.txt') -Value 'x' -Encoding ASCII
    $zip = Join-Path $d 'menu.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $add = S-Text 'TbAdd'
    $p = Start-App @((Q $zip))
    $app = Connect-App $p 10
    Assert ($app -ne $null) ("the process exited with code " + $p.ExitCode + " instead of showing the archive")
    $texts = Wait-Text $app $add 10
    Assert (-not $p.HasExited) ("the process exited with code " + $p.ExitCode + " instead of showing the archive")
    Assert (Has-Exact $texts $add) ("no '" + $add[0] + "' toolbar button on screen: " + (Titles $texts))
    $null = Wait-Item $app 'inside1.txt###r' 5
    $texts = Screen-Texts $app
    Assert (Has-Exact $texts @('inside1.txt')) ("the list does not show inside1.txt; on screen: " + (Titles $texts))
    $lists = @(Windows $app | Where-Object { $_ -like '*##files_*' })
    Assert ($lists.Count -gt 0) ("no file list in the main window; windows " + (Titles (Windows $app)))
    # The context menu opens on a right click (automation rclick, no real mouse).
    Invoke-AutoClick $app 'inside1.txt###r' -Kind rclick
    Assert ((Wait-Item $app '###c_copy' 3) -ne $null) ("no context menu (Copy) after a right click on a row; on screen: " + (Dialog-Text $app))
    Invoke-AutoKey $app 'Escape'
}

# ---------- summary ----------
Kill-App
Write-Host ""
Write-Host ("SUMMARY: " + $script:nPass + " passed, " + $script:nFail + " failed, " + $script:nSkip + " skipped")
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $RegHK -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("sandbox removed: " + (-not (Test-Path -LiteralPath $Root)) + "; test key removed: " + (-not (Test-Path -LiteralPath $RegHK)))
if ($script:nFail -gt 0) { exit 1 }
exit 0
