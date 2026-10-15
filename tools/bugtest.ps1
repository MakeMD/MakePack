# MakePack black-box bug tests. Pure ASCII. PowerShell 5.1.
# Usage: tools\bugtest.ps1 [-Exe <path>] [-Only <testname>] [-Screen <n>]
# -Screen: the monitor the test windows are moved to (\\.\DISPLAY<n>; 0 = leave them where they open).
param(
    [string]$Exe = "$PSScriptRoot\..\dist\publish\MakePack.exe",
    [string]$Only = "",
    [int]$Screen = 1
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
# WinForms controls often surface as generic Panes without ValuePattern/InvokePattern
# (and UIA always refuses SetValue on a password box), so keep a window-message fallback.
if (-not ('Mp.Win' -as [type])) {
    Add-Type -Namespace Mp -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, string l);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
}
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

$SevenZ = Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe'
$Root   = Join-Path $env:TEMP 'MakePack-bugtest'
# The app (started from here, so it inherits this) and the tests below share a settings file of their own:
# the main window saves its size and last folder on close, which must never land in the user's settings.json.
$env:MAKEPACK_SETTINGS = Join-Path $env:TEMP 'MakePack-bugtest-settings.json'
Remove-Item -LiteralPath $env:MAKEPACK_SETTINGS -ErrorAction SilentlyContinue
$script:nPass = 0; $script:nFail = 0; $script:nSkip = 0
$AT = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

# ---------- helpers ----------
function Q([string]$s) { '"' + $s + '"' }
function Assert([bool]$Cond, [string]$Why) { if (-not $Cond) { throw $Why } }
function Skip-Test([string]$Why) { throw ("SKIP:" + $Why) }
function App-Name { [System.IO.Path]::GetFileNameWithoutExtension($Exe) }

function Kill-App {
    Get-Process (App-Name) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

function Uia-Windows([int]$ProcId) {
    $out = @()
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition($AT::ProcessIdProperty, $ProcId)
        $els = $AT::RootElement.FindAll($TS::Children, $cond)
        foreach ($e in $els) { $out += $e }
    } catch { }
    ,$out
}

function Windows-Of([int]$ProcId) {
    $n = @()
    foreach ($e in (Uia-Windows $ProcId)) {
        try { $t = $e.Current.Name } catch { $t = $null }
        if ($t -and $t.Trim().Length -gt 0) { $n += $t }
    }
    ,$n
}

function Titles($w) { if ($w.Count -eq 0) { "<none>" } else { "[" + ($w -join " | ") + "]" } }

# Window titles plus the text inside them - turns "a window appeared" into a usable bug report.
function Dialog-Text([int]$ProcId) {
    $out = @()
    foreach ($w in (Uia-Windows $ProcId)) {
        try { $t = $w.Current.Name } catch { $t = "?" }
        $body = @()
        foreach ($k in (All-Desc $w)) {
            try { $n = $k.Current.Name } catch { $n = "" }
            if ($n -and $n.Trim().Length -gt 0 -and $n.Trim() -ne 'OK') { $body += $n.Trim() }
        }
        $out += ("'" + $t + "' says: " + ((@($body) | Select-Object -First 6) -join ' / '))
    }
    if ($out.Count -eq 0) { return "<no window>" }
    ($out -join ' ;; ')
}

# Poll until the process shows a titled top-level window (or exits). Returns titles.
function Wait-Window($p, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        $w = Windows-Of $p.Id
        if ($w.Count -gt 0) { return ,$w }
        if ($p.HasExited) { Start-Sleep -Milliseconds 200; return ,(Windows-Of $p.Id) }
        Start-Sleep -Milliseconds 400
    }
    ,(Windows-Of $p.Id)
}

function Start-App([string[]]$A) { Start-Process -FilePath $Exe -ArgumentList $A -PassThru }

function Run-App([string[]]$A, [int]$TimeoutMs) {
    $p = Start-App $A
    if ($p.WaitForExit($TimeoutMs)) {
        return [pscustomobject]@{ Proc = $p; TimedOut = $false; Exit = $p.ExitCode; Wins = "" }
    }
    $w = Dialog-Text $p.Id
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
    $out = & python $file @A 2>&1
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($rc -ne 0) { Skip-Test ("python fixture failed: " + ($out -join ' ')) }
}

# Selecting a combo item the way a user does: CB_SETCURSEL, then the CBN_SELCHANGE notification to the parent
# (WinForms raises SelectedIndexChanged from that, not from CB_SETCURSEL alone).
if (-not ('Mp.Combo' -as [type])) {
    Add-Type -Namespace Mp -Name Combo -MemberDefinition @'
[DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
[DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
public static void Pick(IntPtr combo, int index) {
    SendMessage(combo, 0x014E, (IntPtr)index, IntPtr.Zero);                       // CB_SETCURSEL
    var wp = (IntPtr)((1 << 16) | (GetDlgCtrlID(combo) & 0xFFFF));                // CBN_SELCHANGE, control id
    SendMessage(GetParent(combo), 0x0111, wp, combo);                              // WM_COMMAND
}
'@
}

function With-Settings([string]$json, [scriptblock]$body) {
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
        [IO.File]::WriteAllText($cfg, $json)
        & $body $cfg
    }
    finally {
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
    }
}

function Value-Of($el) { try { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $el.Current.Name } }

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Only -and $Only -ne $Name) { return }
    Kill-App
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

# ---------- UI Automation: drive the password dialog ----------
function All-Desc($el) {
    $r = @()
    try { foreach ($x in $el.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { $r += $x } } catch { }
    ,$r
}

function First-Window($p) {
    foreach ($e in (Uia-Windows $p.Id)) {
        try { if ($e.Current.Name -and $e.Current.Name.Trim().Length -gt 0) { return $e } } catch { }
    }
    $null
}

function Controls-Of($winEl, $type) {
    $r = @()
    foreach ($k in (All-Desc $winEl)) {
        try { if ($k.Current.ControlType -eq $type) { $r += $k } } catch { }
    }
    ,$r
}

# The first titled window of the process that is NOT the progress dialog (which owns a progress bar).
function Wait-Dialog($p, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { return $null }
        foreach ($w in (Uia-Windows $p.Id)) {
            try { $n = $w.Current.Name } catch { $n = "" }
            if ($n -and $n.Trim().Length -gt 0 -and (Controls-Of $w $CT::ProgressBar).Count -eq 0) { return $w }
        }
        Start-Sleep -Milliseconds 300
    }
    $null
}

function Window-With($p, $type) {
    foreach ($w in (Uia-Windows $p.Id)) { if ((Controls-Of $w $type).Count -gt 0) { return $w } }
    $null
}

# BM_CLICK is POSTED, never sent, and UI Automation's Invoke() is only a fallback: the Create handler does
# not return until the whole archive is written, so a synchronous click would block here until it times out
# (and a timed-out UIA element then answers null to everything).
function Click-El($el) {
    if ($el -eq $null) { return $false }
    $h = [IntPtr]::Zero
    try { $h = [IntPtr]$el.Current.NativeWindowHandle } catch { }
    if ($h -ne [IntPtr]::Zero) {
        [void][Mp.Win]::PostMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
        return $true
    }
    try {
        $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        return $true
    } catch { }
    $false
}

function Find-Button($winEl, [string[]]$Names) {
    $all = Controls-Of $winEl $CT::Button
    foreach ($k in $all) {
        try { $nm = $k.Current.Name } catch { $nm = "" }
        if (-not $nm) { continue }
        $nm = $nm.Replace('&', '').Trim()
        foreach ($n in $Names) { if ($nm -eq $n) { return $k } }
    }
    if ($all.Count -eq 1) { return $all[0] }    # only one button: it can only be that one
    $null
}

# ---------- the app's own wording ----------
# Read straight out of Strings.cs so this file can stay ASCII. Returns @(uk, en): which of the two is on
# screen depends on the UI culture of the machine running the test, so assertions accept either.
$script:StringsSrc = $null
function S-Text([string]$Name) {
    if ($null -eq $script:StringsSrc) {
        $f = Join-Path $PSScriptRoot '..\src\MakePack\Strings.cs'
        if (-not (Test-Path -LiteralPath $f)) { Skip-Test ("Strings.cs not found next to the script: " + $f) }
        $script:StringsSrc = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    }
    $m = [regex]::Match($script:StringsSrc, ('string\s+' + $Name + '\s*=>\s*Uk[\s\S]*?"([^"]*)"[\s\S]*?"([^"]*)"'))
    if (-not $m.Success) { Skip-Test ("Strings.cs has no '" + $Name + "' string") }
    ,@($m.Groups[1].Value, $m.Groups[2].Value)
}

# Every piece of text on screen right now, one entry per window and per control - for exact-match asserts.
function Screen-Texts([int]$ProcId) {
    $out = @()
    foreach ($w in (Uia-Windows $ProcId)) {
        try { $n = $w.Current.Name } catch { $n = "" }
        if ($n -and $n.Trim().Length -gt 0) { $out += $n.Trim() }
        foreach ($k in (All-Desc $w)) {
            try { $t = $k.Current.Name } catch { $t = "" }
            if ($t -and $t.Trim().Length -gt 0) { $out += $t.Trim() }
        }
    }
    ,$out
}

function Has-Exact([string[]]$Texts, [string[]]$Want) {
    foreach ($t in $Texts) { foreach ($w in $Want) { if ($t -eq $w) { return $true } } }
    $false
}

# Polls until one of $Want is on screen (or the process exits); returns everything it saw last.
function Wait-Text($p, [string[]]$Want, [int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    $seen = @()
    while ((Get-Date) -lt $deadline) {
        $seen = Screen-Texts $p.Id
        if (Has-Exact $seen $Want) { return ,$seen }
        if ($p.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }
    ,$seen
}

# The library's own wording - A3 says the user must never see it.
function Assert-NoRawLibraryText([string]$text, [string]$where) {
    foreach ($raw in @('SevenZipSharp', 'TAR by mistake', 'Invalid archive')) {
        Assert ($text -notlike ('*' + $raw + '*')) ($where + ": raw library text on screen -> " + $text)
    }
}

function Drive-Password($winEl, [string]$Pass) {
    $kids = All-Desc $winEl
    if ($kids.Count -eq 0) { Skip-Test "the password window exposes no child controls to UI Automation" }
    $edit = $kids | Where-Object {
        try { ($_.Current.ControlType -eq $CT::Edit) -or ($_.Current.ClassName -match 'EDIT') } catch { $false }
    } | Select-Object -First 1
    if (-not $edit) { Skip-Test ("no text box in the password window; controls: " + (($kids | ForEach-Object { $_.Current.ClassName }) -join ',')) }

    $typed = $false
    try {
        $vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $vp.SetValue($Pass); $typed = $true
    } catch { $typed = $false }
    if (-not $typed) {
        # UIA refuses SetValue on password fields - WM_SETTEXT works and needs no focus.
        $h = [IntPtr]$edit.Current.NativeWindowHandle
        if ($h -eq [IntPtr]::Zero) { Skip-Test "the password text box has no window handle and refuses ValuePattern" }
        [void][Mp.Win]::SendMessageW($h, 0x000C, [IntPtr]::Zero, $Pass)   # WM_SETTEXT
        Start-Sleep -Milliseconds 200
    }

    $okNames = @('OK', (@([char]0x041E, [char]0x041A) -join ''),
                 (@([char]0x0413, [char]0x0430, [char]0x0440, [char]0x0430, [char]0x0437, [char]0x0434) -join ''))
    $btn = $kids | Where-Object {
        try { $nm = $_.Current.Name } catch { $nm = "" }
        if (-not $nm) { return $false }
        $nm = $nm.Replace('&', '').Trim()
        foreach ($o in $okNames) { if ($nm -eq $o) { return $true } }
        $false
    } | Select-Object -First 1

    if ($btn) {
        try {
            $ip = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $ip.Invoke(); return
        } catch { }
        $bh = [IntPtr]$btn.Current.NativeWindowHandle
        if ($bh -ne [IntPtr]::Zero) { [void][Mp.Win]::SendMessage($bh, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); return }  # BM_CLICK
    }
    # last resort: default button via Enter
    [void][Mp.Win]::SetForegroundWindow([IntPtr]$winEl.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
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

# ---------- wait for the exe to be built ----------
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host ("Waiting for " + $Exe + " (up to 25 min)")
    $tries = 0
    while (-not (Test-Path -LiteralPath $Exe) -and $tries -lt 100) {
        Start-Sleep -Seconds 15; Write-Host "." -NoNewline; $tries++
    }
    Write-Host ""
    if (-not (Test-Path -LiteralPath $Exe)) {
        Write-Host ("ERROR: " + $Exe + " never appeared after 25 minutes - the build did not finish.")
        exit 2
    }
    Start-Sleep -Seconds 10
}
if (-not (Test-Path -LiteralPath $SevenZ)) { Write-Host ("ERROR: fixture tool missing: " + $SevenZ); exit 2 }

if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
New-Dir $Root | Out-Null
Write-Host ("exe : " + $Exe)
Write-Host ("temp: " + $Root)
. (Join-Path $PSScriptRoot 'screenpin.ps1')
Start-ScreenPin -Screen $Screen -Exe $Exe
Write-Host ""

# Cyrillic "test" built from char codes so this file stays ASCII.
$UK = (@([char]0x0442, [char]0x0435, [char]0x0441, [char]0x0442) -join '')
$UKFILE = $UK + ' file.txt'
# "Stvoryty" (Create) and "Skasuvaty" (Cancel) - the app runs in Ukrainian on a uk UI.
$UK_CREATE = (@([char]0x0421, [char]0x0442, [char]0x0432, [char]0x043E, [char]0x0440, [char]0x0438, [char]0x0442, [char]0x0438) -join '')
$UK_CANCEL = (@([char]0x0421, [char]0x043A, [char]0x0430, [char]0x0441, [char]0x0443, [char]0x0432, [char]0x0430, [char]0x0442, [char]0x0438) -join '')

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
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; Assert $false "--selftest did not finish within 60 s (hang)" }
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
    $dlg = Wait-Dialog $p 30
    $txt = "<exited>"
    if ($dlg) {
        # The progress window closes and the warning box opens a few ms apart - do not read the gap.
        $txt = Dialog-Text $p.Id
        $stop = (Get-Date).AddSeconds(5)
        while ($txt -eq "<no window>" -and (Get-Date) -lt $stop -and -not $p.HasExited) {
            Start-Sleep -Milliseconds 300
            $txt = Dialog-Text $p.Id
        }
    }
    $exit = -1
    if ($p.HasExited) { $exit = $p.ExitCode } else { try { $p.Kill(); $p.WaitForExit(3000) | Out-Null } catch { } }
    Assert (($dlg -ne $null) -or ($exit -ne 0)) "the unsafe entries were skipped silently: no warning and exit 0"
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
    $texts = Wait-Text $p $damaged 15
    $titles = Windows-Of $p.Id
    $code = "still running"
    if ($p.HasExited) { $code = [string]$p.ExitCode }
    try { $p.Kill() } catch { }
    Assert ($code -eq "still running") ("truncated 7z: the process exited with code " + $code +
        " instead of reporting the damage in a dialog; dst contains [" + (Names-In $dst) + "]")
    Assert (Has-Exact $texts $damaged) ("truncated 7z: expected an error box saying exactly '" + $damaged[0] +
        "'; on screen: " + (Titles $texts))
    Assert (-not (Has-Exact $texts $enter)) ("truncated 7z: a password prompt appeared; on screen: " + (Titles $texts))
    $prompt = @($titles | Where-Object { $_ -like '*broken.7z*' })
    Assert ($prompt.Count -eq 0) ("truncated 7z: a window titled with the file name (the password prompt) appeared; windows " + (Titles $titles))
    Assert-NoRawLibraryText ($texts -join ' / ') "corrupt_archive"
}

# ---------- 8a ----------
Test-Case 'password_prompt_appears' {
    $d = New-TestDir 'pwprompt'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $enter = S-Text 'EnterPassword'
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $texts = Wait-Text $p $enter 12
    if ($p.HasExited) { Assert $false ("no password prompt: the process exited with code " + $p.ExitCode + " within 12 s; dst contains [" + (Names-In $dst) + "]") }
    try { $p.Kill() } catch { }
    Assert ($texts.Count -gt 0) "no window within 12 s for an encrypted (-mhe=on) archive; expected a password prompt"
    Assert (Has-Exact $texts $enter) ("the first prompt must say exactly '" + $enter[0] + "'; on screen: " + (Titles $texts))
}

# ---------- 8b ----------
Test-Case 'wrong_password' {
    $d = New-TestDir 'pwwrong'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $w = Wait-Window $p 10
    Assert ($w.Count -gt 0) "no password prompt window within 10 s"
    $el = First-Window $p
    if (-not $el) { Skip-Test "the password window is not reachable via UI Automation" }
    $retry = S-Text 'WrongPasswordRetry'
    Drive-Password $el 'WrongPass'
    $texts = Wait-Text $p $retry 15
    if ($p.HasExited) {
        Assert ($p.ExitCode -ne 0) ("CRITICAL: a wrong password was accepted - exit 0; dst contains [" + (Names-In $dst) + "]")
        Assert $false ("after a wrong password the process exited (code " + $p.ExitCode + ") instead of asking again; on screen: " + (Titles $texts))
    }
    Assert (Has-Exact $texts $retry) ("after a wrong password the prompt must say exactly '" + $retry[0] + "'; on screen: " + (Titles $texts))

    # Cancelling that second prompt ends the run: exit 255 (user break), and no error box (a box would keep it alive).
    $el2 = First-Window $p
    if (-not $el2) { try { $p.Kill() } catch { }; Skip-Test "the second password window is not reachable via UI Automation" }
    $cancel = Find-Button $el2 @('Cancel', $UK_CANCEL)
    if (-not $cancel) { try { $p.Kill() } catch { }; Skip-Test "no Cancel button in the password window" }
    Assert (Click-El $cancel) "could not click Cancel on the second prompt"
    if (-not $p.WaitForExit(15000)) {
        $late = Dialog-Text $p.Id
        try { $p.Kill() } catch { }
        Assert $false ("cancelling the password prompt left the process running; on screen: " + $late)
    }
    Assert ($p.ExitCode -eq 255) ("a cancelled password prompt must end the run with exit 255, got " + $p.ExitCode)
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
    $texts = Wait-Text $p $enter 15
    if ($p.HasExited) { Assert $false ("no password prompt for an AES zip: exited with code " + $p.ExitCode) }
    Assert (Has-Exact $texts $enter) ("no password prompt for an AES zip; on screen: " + (Titles $texts))
    $el = First-Window $p
    if (-not $el) { Skip-Test "the password window is not reachable via UI Automation" }
    Drive-Password $el 'WrongPass'
    $texts2 = Wait-Text $p $wrong 25
    $code = "still running"
    if ($p.HasExited) { $code = [string]$p.ExitCode }
    try { $p.Kill() } catch { }
    Assert (Has-Exact $texts2 $wrong) ("a wrong password on an AES zip must raise an error box saying exactly '" +
        $wrong[0] + "' (process: " + $code + "); on screen: " + (Titles $texts2))
}

# ---------- 9 ----------
Test-Case 'right_password_via_uia' {
    $d = New-TestDir 'pwright'
    $arc = Make-EncryptedFixture $d
    $dst = New-Dir (Join-Path $d 'dst')
    $p = Start-App @('x', (Q $arc), '-o', (Q $dst))
    $w = Wait-Window $p 10
    Assert ($w.Count -gt 0) "no password prompt window within 10 s"
    $el = First-Window $p
    if (-not $el) { Skip-Test "the password window is not reachable via UI Automation" }
    Drive-Password $el 'Secret'
    if (-not $p.WaitForExit(20000)) {
        $late = Dialog-Text $p.Id
        try { $p.Kill() } catch { }
        Assert $false ("correct password: still running after 20 s; on screen: " + $late + "; dst contains [" + (Names-In $dst) + "]")
    }
    Assert ($p.ExitCode -eq 0) ("correct password: exit code " + $p.ExitCode + "; dst contains [" + (Names-In $dst) + "]")
    foreach ($n in @('secret1.txt', 'secret2.txt')) {
        Assert (Test-Path -LiteralPath (Join-Path $dst $n)) ($n + " missing after a successful decrypt; dst contains [" + (Names-In $dst) + "]")
    }
}

# ---------- 10 ----------
Test-Case 'multi_select_aggregation' {
    $d = New-TestDir 'multisel'
    foreach ($i in 1..3) {
        $f = Join-Path $d ("item" + $i + ".txt")
        Set-Content -LiteralPath $f -Value ("payload " + $i) -Encoding ASCII
        Start-App @('a', (Q $f)) | Out-Null
    }
    Start-Sleep -Seconds 3
    $alive = @(Get-Process (App-Name) -ErrorAction SilentlyContinue)
    Assert ($alive.Count -eq 1) ("expected exactly 1 surviving process after 3 back-to-back 'a' invocations, found " + $alive.Count)
    $w = Wait-Window $alive[0] 5
    Assert ($w.Count -gt 0) "the surviving process has no window (the instance holding the dialog was the one that died)"
    Write-Host ("     note: dialog " + (Titles $w))
}

# ---------- 11 ----------
Test-Case 'non_archive_input' {
    $d = New-TestDir 'nonarchive'
    $f = Join-Path $d 'notanarchive.txt'
    Set-Content -LiteralPath $f -Value 'this is plain text, definitely not an archive' -Encoding ASCII
    $notArchive = S-Text 'NotAnArchive'
    $p = Start-App @((Q $f))
    $texts = Wait-Text $p $notArchive 12
    $w = Windows-Of $p.Id
    if ($w.Count -eq 0) {
        if ($p.HasExited) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
        try { $p.Kill() } catch { }
        Assert $false "no window within 12 s and the process is still running (silent hang)"
    }
    # A4: plain text gets an error box, never a password prompt - the prompt is titled with the file name.
    $prompt = @($w | Where-Object { $_ -like '*notanarchive.txt*' })
    try { $p.Kill() } catch { }
    Assert ($prompt.Count -eq 0) ("a password prompt appeared for a plain text file; windows " + (Titles $w) + "; on screen: " + (Titles $texts))
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
    $texts = Wait-Text $p $notArchive 12
    $w = Windows-Of $p.Id
    if ($p.HasExited) { Assert $false ("no window at all; the process exited with code " + $p.ExitCode + " (the error must be reported in a dialog)") }
    try { $p.Kill() } catch { }
    Assert ($w.Count -gt 0) "no window within 12 s for a text file named x.7z (silent hang)"
    # The extension says archive, the bytes do not: that is "not an archive", not a password question.
    Assert (Has-Exact $texts $notArchive) ("a text file named x.7z must be reported as exactly '" + $notArchive[0] + "'; on screen: " + (Titles $texts))
    Assert (-not (Has-Exact $texts $enter)) ("a text file named x.7z got a password prompt; on screen: " + (Titles $texts))
    Assert (@($w | Where-Object { $_ -like '*x.7z*' }).Count -eq 0) ("a window titled with the file name (the password prompt) appeared; windows " + (Titles $w))
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
    Start-Sleep -Seconds 3
    Assert (-not $p.HasExited) ("the process exited with code " + $p.ExitCode + " instead of showing the archive list")
    $w = Wait-Window $p 5
    Assert ($w.Count -gt 0) "no window within 8 s when opening a valid zip"
    $hit = @($w | Where-Object { $_ -like '*viewme.zip*' })
    Assert ($hit.Count -gt 0) ("no window title contains the archive file name 'viewme.zip'; titles " + (Titles $w))
}

# ---------- 13 ----------
Test-Case 'trailing_backslash_arg' {
    $d = New-TestDir 'trailslash'
    $folder = New-Dir (Join-Path $d 'folder')
    Set-Content -LiteralPath (Join-Path $folder 'f.txt') -Value 'z' -Encoding ASCII
    $p = Start-App @('a', (Q ($folder + '\')))
    $w = Wait-Window $p 5
    if ($p.HasExited) { Assert $false ("exited with code " + $p.ExitCode + " on an argument that ends with a backslash before the closing quote (Explorer drive-root case)") }
    try { $p.Kill() } catch { }
    Assert ($w.Count -gt 0) "no window within 5 s for a trailing-backslash path argument"
    Write-Host ("     note: window " + (Titles $w))
}

# ---------- 14 ----------
Test-Case 'readonly_target_overwrite' {
    Skip-Test "extracting over existing files raises the Ask conflict TaskDialog from the CLI; not testable without driving that dialog"
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
    # a cancel point at every file. See the ponytail note in Engine.Pack.
    foreach ($i in 1..10) { [Mp.Gen]::Letters((Join-Path $src ("blob" + $i + ".txt")), 3MB, (500 + $i)) }
    $out = Join-Path $d 'payload.7z'
    $p = Start-App @('a', (Q $src))
    $w = Wait-Window $p 20
    Assert ($w.Count -gt 0) "no create dialog within 20 s"
    $dlg = First-Window $p
    if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
    $create = Find-Button $dlg @('Create', $UK_CREATE)
    if (-not $create) { Skip-Test "no Create button in the create dialog" }
    Assert (Click-El $create) "could not click Create"

    $prog = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $prog) {
        $prog = Window-With $p $CT::ProgressBar
        if (-not $prog) { Start-Sleep -Milliseconds 300 }
    }
    Assert ($prog -ne $null) ("no progress window within 30 s of clicking Create; exited=" + $p.HasExited +
        " windows " + (Titles (Windows-Of $p.Id)) + " archive=" + (Test-Path -LiteralPath $out))
    Start-Sleep -Seconds 3                                   # let it write a real chunk of the archive
    $cancel = Find-Button $prog @('Cancel', $UK_CANCEL)
    if (-not $cancel) { Skip-Test "no Cancel button in the progress window" }
    Assert (Click-El $cancel) "could not click Cancel"

    $back = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { $back = $true; break }
        if ((Window-With $p $CT::ProgressBar) -eq $null) { $back = $true; break }   # progress gone, create dialog back
        Start-Sleep -Milliseconds 500
    }
    $txt = ""
    if (-not $p.HasExited) { $txt = Dialog-Text $p.Id }
    try { $p.Kill(); $p.WaitForExit(3000) | Out-Null } catch { }
    Assert $back ("the progress window was still up 30 s after Cancel; on screen: " + $txt)
    Start-Sleep -Milliseconds 700
    Assert (-not (Test-Path -LiteralPath $out)) ("a cancelled compression left a broken archive behind: " + $out +
        " (" + [math]::Round((Get-Item -LiteralPath $out -ErrorAction SilentlyContinue).Length / 1MB, 1) + " MB)")
}

# ---------- 17 ----------
Test-Case 'assoc_roundtrip' {
    $cls  = 'HKCU:\Software\Classes\.mkptest'
    $verb = 'HKCU:\Software\Classes\SystemFileAssociations\.mkptest\shell\MakePack.ExtractHere'
    # Note what the machine looked like before we touch it: a --unregister here strips the ProgID the
    # INSTALLED copy owns too, so it has to be handed back at the end.
    $inst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{8C3F2B7E-5D0A-4E1B-9F6C-3A2B1C0D9E8F}_is1'
    $installedExe = $null
    if (Test-Path $inst) {
        $loc = (Get-ItemProperty -Path $inst -ErrorAction SilentlyContinue).InstallLocation
        if ($loc) {
            $cand = Join-Path $loc 'MakePack.exe'
            if (Test-Path -LiteralPath $cand) { $installedExe = $cand }
        }
    }
    $r = Run-App @('--register', 'mkptest') 30000
    Assert (-not $r.TimedOut) "--register mkptest never exited (30 s)"
    Assert ($r.Exit -eq 0) ("--register mkptest exit code " + $r.Exit)

    Assert (Test-Path $cls) "HKCU\Software\Classes\.mkptest was not created"
    $def = (Get-Item $cls).GetValue('')
    Assert ($def -eq 'MakePack.Archive') ("default handler is '" + $def + "', expected MakePack.Archive")
    Assert (Test-Path ($verb + '\command')) "the ExtractHere verb key was not created"
    $cmd = (Get-Item ($verb + '\command')).GetValue('')
    Assert ($cmd -like '*--here*') ("ExtractHere command is '" + $cmd + "'")
    $owp = $cls + '\OpenWithProgids'
    Assert (Test-Path $owp) "OpenWithProgids key was not created"
    Assert ((Get-Item $owp).GetValue('MakePack.Archive') -ne $null) "OpenWithProgids has no MakePack.Archive value"

    $r2 = Run-App @('--unregister', 'mkptest') 30000
    Assert (-not $r2.TimedOut) "--unregister mkptest never exited (30 s)"
    Assert ($r2.Exit -eq 0) ("--unregister mkptest exit code " + $r2.Exit)
    $left = $null
    if (Test-Path $cls) { $left = (Get-Item $cls).GetValue('') }
    Assert ($left -eq $null) ("the default handler survived --unregister: '" + $left + "'")
    Assert (-not (Test-Path $verb)) "the ExtractHere verb key survived --unregister"

    # Put the machine back: the installed copy re-claims the ProgID, and on a machine without MakePack
    # nothing is left pointing at dist\publish.
    if ($installedExe) {
        $p3 = Start-Process -FilePath $installedExe -ArgumentList '--register', 'defaults' -PassThru
        if (-not $p3.WaitForExit(30000)) {
            try { $p3.Kill() } catch { }
            Assert $false "the installed copy's --register defaults never exited (30 s)"
        }
        Assert ($p3.ExitCode -eq 0) ("installed --register defaults exit code " + $p3.ExitCode)
        Write-Host ("     note: handed the ProgID back to " + $installedExe)
    } else {
        $r3 = Run-App @('--unregister') 30000
        Assert ($r3.Exit -eq 0) ("full --unregister exit code " + $r3.Exit)
        Write-Host "     note: MakePack is not installed, ran a full --unregister afterwards"
    }
    Remove-Item -Path $cls -Recurse -Force -ErrorAction SilentlyContinue
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
    # Create remembers format/level in the user's settings.json: put it back afterwards.
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        $p = Start-App @('a', (Q $src))
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no create dialog within 20 s"
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
        # Combos by position: profile on top, then format and level on one row, Volumes alone further down.
        $combos = @((Controls-Of $dlg $CT::ComboBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
        Assert ($combos.Count -ge 4) ("expected 4+ combo boxes, found " + $combos.Count)
        $vol = [IntPtr]$combos[3].Current.NativeWindowHandle
        [void][Mp.Win]::SendMessageW($vol, 0x000C, [IntPtr]::Zero, '1 MB')   # WM_SETTEXT
        $archive = $null
        foreach ($e in (Controls-Of $dlg $CT::Edit)) {
            try { $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { continue }
            if ($v -like '*payload.*') { $archive = $v }
        }
        Assert ($archive -ne $null) "could not read the archive path from the dialog"
        $create = Find-Button $dlg @('Create', $UK_CREATE)
        Assert (Click-El $create) "could not click Create"
        Assert ($p.WaitForExit(60000)) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $p.Id))

        $parts = @(Get-ChildItem -LiteralPath $d -File | Where-Object { $_.Name -like ((Split-Path $archive -Leaf) + '.*') })
        Assert ($parts.Count -ge 3) ("expected 3+ parts of 1 MB, folder has [" + (Names-In $d) + "]")
        Assert (@($parts | Where-Object { $_.Length -gt 1MB }).Count -eq 0) "a part is larger than 1 MB"
        Assert (-not (Test-Path -LiteralPath $archive)) "a whole archive was left next to the parts"

        $dst = New-Dir (Join-Path $d 'out')
        $r = Run-App @('x', (Q ($archive + '.001')), '-o', (Q $dst)) 60000
        Assert (-not $r.TimedOut) ("x on the .001 never exited (60 s); on screen: " + $r.Wins)
        Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
        $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.bin' | Select-Object -First 1
        Assert ($back -ne $null) ("payload.bin not extracted; out has [" + (Names-In $dst) + "]")
        Assert ((Get-FileHash -LiteralPath $file).Hash -eq (Get-FileHash -LiteralPath $back.FullName).Hash) "the extracted file differs"
    }
    finally {
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
    }
}

# ---------- 18c ----------
# Test + delete through the real dialog: tick both boxes, Create, the archive is there and the sources are in the
# Recycle Bin. The test then puts them back from the bin so the user's bin is left as it was.
Test-Case 'create_test_delete' {
    $d = New-TestDir 'testdelete'
    $src = New-Dir (Join-Path $d 'tobin')
    Set-Content -LiteralPath (Join-Path $src 'keep.txt') -Value ('payload ' * 2000) -Encoding ASCII
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        $p = Start-App @('a', (Q $src))
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no create dialog within 20 s"
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
        # Test and delete share the bottom row of check boxes (the Advanced block has none).
        $boxes = @((Controls-Of $dlg $CT::CheckBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
        Assert ($boxes.Count -ge 3) ("expected 3+ check boxes, found " + $boxes.Count)
        foreach ($b in @($boxes | Where-Object { $_.Current.BoundingRectangle.Y -eq $boxes[-1].Current.BoundingRectangle.Y })) {
            $t = $b.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($t.Current.ToggleState -ne 'On') { $t.Toggle() }
        }
        $archive = $null
        foreach ($e in (Controls-Of $dlg $CT::Edit)) {
            try { $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { continue }
            if ($v -like '*tobin.*') { $archive = $v }
        }
        Assert ($archive -ne $null) "could not read the archive path from the dialog"
        $create = Find-Button $dlg @('Create', $UK_CREATE)
        Assert (Click-El $create) "could not click Create"
        Assert ($p.WaitForExit(60000)) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $p.Id))
        Assert (Test-Path -LiteralPath $archive) ("no archive at " + $archive)
        Assert (-not (Test-Path -LiteralPath $src)) "the source folder is still there after Create with delete ticked"

        $bin = (New-Object -ComObject Shell.Application).Namespace(10)
        $restore = (@(0x0412, 0x0456, 0x0434, 0x043D, 0x043E, 0x0432, 0x0438, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
        $found = $false
        foreach ($it in @($bin.Items())) {
            if ($it.Name -ne 'tobin' -or $bin.GetDetailsOf($it, 1) -ne $d) { continue }
            $found = $true
            foreach ($v in @($it.Verbs())) { if ($v.Name.Replace('&', '') -in @('Restore', $restore)) { $v.DoIt(); break } }
        }
        Assert $found "the source folder is not in the Recycle Bin"
        Start-Sleep -Milliseconds 800
        Assert (Test-Path -LiteralPath (Join-Path $src 'keep.txt')) "restoring the source folder from the Recycle Bin failed"
    }
    finally {
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
    }
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
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        $p = Start-App (@('a') + $ins)
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no create dialog within 20 s"
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
        # The separate-archives box is the topmost check box (on the Archive label row).
        $boxes = @((Controls-Of $dlg $CT::CheckBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y })
        $boxes[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        Start-Sleep -Milliseconds 300
        $outBox = (Controls-Of $dlg $CT::Edit) | Where-Object { try { $_.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -like '*.*' } catch { $false } } | Select-Object -First 1
        Assert ($outBox -ne $null -and -not $outBox.Current.IsEnabled) "the Archive path box stays enabled with separate archives ticked"
        $create = Find-Button $dlg @('Create', $UK_CREATE)
        Assert (Click-El $create) "could not click Create"
        Assert ($p.WaitForExit(60000)) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $p.Id))

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
    finally {
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
    }
}

# ---------- 18e ----------
# SFX through the real dialog: the box turns the path into .exe and greys out Volumes; the exe then unpacks
# itself with 7z.sfx's own -y -o switches, no MakePack involved.
Test-Case 'create_sfx' {
    $d = New-TestDir 'sfx'
    $src = New-Dir (Join-Path $d 'payload')
    $file = Join-Path $src 'payload.bin'
    Rand-File $file (300KB) 2026
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        # The SFX box only exists for 7z: start from a 7z default whatever the user last picked.
        New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
        [IO.File]::WriteAllText($cfg, '{ "Format": "SevenZip" }')
        $p = Start-App @('a', (Q $src))
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no create dialog within 20 s"
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
        $sfx = (Controls-Of $dlg $CT::CheckBox) | Where-Object { $_.Current.Name -like 'SFX*' } | Select-Object -First 1
        Assert ($sfx -ne $null) "no SFX check box in the create dialog"
        $sfx.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        Start-Sleep -Milliseconds 400
        $archive = $null
        foreach ($e in (Controls-Of $dlg $CT::Edit)) {
            try { $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { continue }
            if ($v -like '*payload.*') { $archive = $v }
        }
        Assert ($archive -like '*.exe') ("with SFX ticked the archive path is '" + $archive + "', expected .exe")
        $combos = @((Controls-Of $dlg $CT::ComboBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
        Assert (-not $combos[3].Current.IsEnabled) "Volumes stays enabled with SFX ticked"
        $create = Find-Button $dlg @('Create', $UK_CREATE)
        Assert (Click-El $create) "could not click Create"
        Assert ($p.WaitForExit(60000)) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $p.Id))
        Assert (Test-Path -LiteralPath $archive) ("no SFX at " + $archive)

        $dst = Join-Path $d 'unpacked'
        $run = Start-Process -FilePath $archive -ArgumentList @('-y', ('"-o' + $dst + '"')) -PassThru
        Assert ($run.WaitForExit(60000)) "the SFX did not finish within 60 s"
        Assert ($run.ExitCode -eq 0) ("the SFX exited with " + $run.ExitCode)
        $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.bin' | Select-Object -First 1
        Assert ($back -ne $null) ("the SFX unpacked [" + (Names-In $dst) + "]")
        Assert ((Get-FileHash -LiteralPath $file).Hash -eq (Get-FileHash -LiteralPath $back.FullName).Hash) "the file the SFX unpacked differs"
    }
    finally {
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
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
    $cfg = $env:MAKEPACK_SETTINGS
    $backup = $null
    if (Test-Path -LiteralPath $cfg) { $backup = [IO.File]::ReadAllText($cfg) }
    try {
        New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
        [IO.File]::WriteAllText($cfg, '{ "Format": "Zip" }')
        $p = Start-App @('a', (Q $src))
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no create dialog within 20 s"
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
        # Plain text boxes by position: archive path, password, confirmation (combo edits come later).
        $edits = @((Controls-Of $dlg $CT::Edit) | ForEach-Object { $_ } | Where-Object { $_.Current.ClassName -notlike '*Combo*' } |
            Sort-Object { $_.Current.BoundingRectangle.Y })
        $pwd = [IntPtr]$edits[1].Current.NativeWindowHandle
        $again = [IntPtr]$edits[2].Current.NativeWindowHandle
        [void][Mp.Win]::SendMessageW($pwd, 0x000C, [IntPtr]::Zero, 'hunter2')     # WM_SETTEXT
        [void][Mp.Win]::SendMessageW($again, 0x000C, [IntPtr]::Zero, 'hunter3')
        $archive = $null
        foreach ($e in $edits) {
            try { $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { continue }
            if ($v -like '*payload.zip') { $archive = $v }
        }
        Assert ($archive -ne $null) "could not read the .zip archive path from the dialog"
        $create = Find-Button $dlg @('Create', $UK_CREATE)
        Assert (Click-El $create) "could not click Create"
        # The warning box is owned by the dialog, so UIA lists it inside the dialog, not as a second top-level window.
        $box = $null
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and -not $box) {
            $box = (Controls-Of $dlg $CT::Window) | Where-Object { $_.Current.Name -eq 'MakePack' } | Select-Object -First 1
            if (-not $box) { Start-Sleep -Milliseconds 300 }
        }
        Assert ($box -ne $null) ("no warning for mismatched passwords; on screen: " + (Dialog-Text $p.Id))
        Assert (-not (Test-Path -LiteralPath $archive)) "an archive was written with mismatched passwords"
        [void][Mp.Win]::PostMessage([IntPtr]$box.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        Start-Sleep -Milliseconds 500

        [void][Mp.Win]::SendMessageW($again, 0x000C, [IntPtr]::Zero, 'hunter2')
        $zc = (Controls-Of $dlg $CT::CheckBox) | Where-Object { $_.Current.Name -like '*ZipCrypto*' } | Select-Object -First 1
        Assert ($zc -ne $null -and -not $zc.Current.IsOffscreen) "no visible ZipCrypto check box for a zip"
        $zc.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        Assert (Click-El $create) "could not click Create the second time"
        Assert ($p.WaitForExit(60000)) ("the dialog was still up 60 s after Create; on screen: " + (Dialog-Text $p.Id))
        Assert (Test-Path -LiteralPath $archive) ("no archive at " + $archive)

        $dst = Join-Path $d 'py-out'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2], pwd=b'hunter2')" $archive $dst 2>&1
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prev
        Assert ($rc -eq 0) ("Python's zipfile (ZipCrypto only) could not unpack it: " + ($out -join ' '))
        $back = Get-ChildItem -LiteralPath $dst -Recurse -File -Filter 'payload.txt' | Select-Object -First 1
        Assert ($back -ne $null -and (Get-FileHash -LiteralPath $back.FullName).Hash -eq (Get-FileHash -LiteralPath $file).Hash) "the ZipCrypto zip unpacked to something else"
    }
    finally {
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        if ($null -ne $backup) { [IO.File]::WriteAllText($cfg, $backup) } else { Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue }
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
        Assert ($p1.WaitForExit(60000)) ("a --profile never exited; on screen: " + (Dialog-Text $p1.Id))
        Assert ($p1.ExitCode -eq 0) ("a --profile exit code " + $p1.ExitCode)
        [void]$p2.WaitForExit(10000)
        $zips = @(Get-ChildItem -LiteralPath $set -File -Filter '*.zip')
        Assert ($zips.Count -eq 1 -and $zips[0].Name -eq 'set.zip') ("expected one set.zip for both items, got [" + (Names-In $set) + "]")
        $dst = New-Dir (Join-Path $d 'out')
        $r = Run-App @('x', (Q $zips[0].FullName), '-o', (Q $dst)) 60000
        Assert ($r.Exit -eq 0) ("x exit code " + $r.Exit)
        $got = @(Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
        Assert (($got -join ',') -eq 'one.txt,two.txt') ("set.zip holds [" + ($got -join ',') + "]")

        $r = Run-App @('a', '--profile', (Q 'No such profile'), (Q $one)) 8000
        Assert ($r.TimedOut -and $r.Wins -like '*No such profile*') ("an unknown profile did not stop with a message; on screen: " + $r.Wins)
        Assert (@(Get-ChildItem -LiteralPath $set -File).Count -eq 1) "an unknown profile still wrote an archive"
    }
}

# ---------- 18h ----------
# Profiles in the dialog: the default one is applied on open, picking another one changes the options,
# Save... stores the current options under a new name.
Test-Case 'profile_dialog' {
    $d = New-TestDir 'profdlg'
    $src = New-Dir (Join-Path $d 'payload')
    Set-Content -LiteralPath (Join-Path $src 'p.txt') -Value 'p' -Encoding ASCII
    $json = '{ "Profiles": [ { "Name": "Big zip", "IsDefault": true, "Format": "Zip", "Level": "Ultra", "Volumes": "100 MB", "TestAfter": true },' +
            ' { "Name": "Plain 7z", "Format": "SevenZip", "Level": "Normal" } ] }'
    With-Settings $json {
        param($cfg)
        $p = Start-App @('a', (Q $src))
        try {
            $w = Wait-Window $p 20
            Assert ($w.Count -gt 0) "no create dialog within 20 s"
            $dlg = First-Window $p
            if (-not $dlg) { Skip-Test "the create dialog is not reachable via UI Automation" }
            # By position: profile, format, level, volumes.
            $combos = @((Controls-Of $dlg $CT::ComboBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
            $state = "profile=" + (Value-Of $combos[0]) + " format=" + (Value-Of $combos[1]) + " volumes=" + (Value-Of $combos[3])
            Assert ($state -like 'profile=Big zip*format=zip volumes=100 MB') ("the default profile was not applied on open: " + $state)
            $test = (Controls-Of $dlg $CT::CheckBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X } | Select-Object -Last 2 | Select-Object -First 1
            Assert ($test.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq 'On') "the profile's Test box is not ticked"

            [Mp.Combo]::Pick([IntPtr]$combos[0].Current.NativeWindowHandle, 2)   # "-", Big zip, Plain 7z
            Start-Sleep -Milliseconds 400
            $state = "format=" + (Value-Of $combos[1]) + " volumes=" + (Value-Of $combos[3])
            Assert ($state -eq 'format=7z volumes=') ("picking Plain 7z gave " + $state)

            $ell = [string][char]0x2026
            $save = Find-Button $dlg @(('Save' + $ell), (((@(0x0417, 0x0431, 0x0435, 0x0440, 0x0435, 0x0433, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join '') + $ell))
            Assert (Click-El $save) "could not click Save"
            $nameBox = $null
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not $nameBox) {
                $win = (Controls-Of $dlg $CT::Window) | Select-Object -First 1
                if ($win) { $nameBox = (Controls-Of $win $CT::Edit) | Select-Object -First 1 }
                if (-not $nameBox) { Start-Sleep -Milliseconds 300 }
            }
            Assert ($nameBox -ne $null) ("no name prompt after Save; on screen: " + (Dialog-Text $p.Id))
            [void][Mp.Win]::SendMessageW([IntPtr]$nameBox.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, 'Mine')
            $ok = Find-Button $win @('OK', ((@(0x0413, 0x0430, 0x0440, 0x0430, 0x0437, 0x0434) | ForEach-Object { [char]$_ }) -join ''))
            Assert (Click-El $ok) "could not click OK in the name prompt"
            Start-Sleep -Milliseconds 800
            $saved = [IO.File]::ReadAllText($cfg)
            Assert ($saved -match '"Name": "Mine"') ("Save... did not store the profile: " + ($saved -replace '\s+', ' '))
            Assert ($saved -notmatch 'Password') "a saved profile carries a password"
        }
        finally { try { $p.Kill() } catch { } }
    }
}

# ---------- 18i ----------
# Profiles in Settings (opened standalone with --settings): delete one, rename one, make one the default, OK.
Test-Case 'profile_settings' {
    $json = '{ "Profiles": [ { "Name": "Alpha", "IsDefault": true }, { "Name": "Beta" }, { "Name": "Gamma" } ] }'
    With-Settings $json {
        param($cfg)
        $p = Start-App @('--settings')
        try {
            $w = Wait-Window $p 20
            Assert ($w.Count -gt 0) "no Settings window within 20 s"
            $dlg = First-Window $p
            $list = (Controls-Of $dlg $CT::List) | Select-Object -First 1
            Assert ($list -ne $null) "no profile list in Settings"
            function Item([string]$name) {
                (Controls-Of $list $CT::ListItem) | Where-Object { $_.Current.Name -like ($name + '*') } | Select-Object -First 1
            }
            function Button-At([int]$row) {   # the three buttons beside the list, top to bottom (not Browse, not a combo arrow)
                @((Controls-Of $dlg $CT::Button) | ForEach-Object { $_ } | Where-Object {
                    $_.Current.BoundingRectangle.X -gt $list.Current.BoundingRectangle.Right -and
                    $_.Current.BoundingRectangle.Y -ge $list.Current.BoundingRectangle.Y - 2 } |
                    Sort-Object { $_.Current.BoundingRectangle.Y })[$row]
            }
            function Choose([string]$name) {
                $it = Item $name
                Assert ($it -ne $null) ("no '" + $name + "' in the profile list")
                $it.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
                Start-Sleep -Milliseconds 200
            }
            $rename = Button-At 0; $delete = Button-At 1; $default = Button-At 2
            # The Mark-of-the-Web policy rides along: Never / Risky / All -> All.
            $motw = (Controls-Of $dlg $CT::ComboBox) | Select-Object -First 1
            [Mp.Combo]::Pick([IntPtr]$motw.Current.NativeWindowHandle, 2)

            Choose 'Beta';  Assert (Click-El $delete) "could not click Delete"; Start-Sleep -Milliseconds 300
            Choose 'Gamma'; Assert (Click-El $default) "could not click Default"; Start-Sleep -Milliseconds 300
            Choose 'Alpha'; Assert (Click-El $rename) "could not click Rename"
            $nameBox = $null
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not $nameBox) {
                $win = (Controls-Of $dlg $CT::Window) | Select-Object -First 1
                if ($win) { $nameBox = (Controls-Of $win $CT::Edit) | Select-Object -First 1 }
                if (-not $nameBox) { Start-Sleep -Milliseconds 300 }
            }
            Assert ($nameBox -ne $null) ("no name prompt after Rename; on screen: " + (Dialog-Text $p.Id))
            [void][Mp.Win]::SendMessageW([IntPtr]$nameBox.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, 'Alpha2')
            $okName = Find-Button $win @('OK', ((@(0x0413, 0x0430, 0x0440, 0x0430, 0x0437, 0x0434) | ForEach-Object { [char]$_ }) -join ''))
            Assert (Click-El $okName) "could not click OK in the name prompt"
            Start-Sleep -Milliseconds 500
            $ok = Find-Button $dlg @('OK', ((@(0x0413, 0x0430, 0x0440, 0x0430, 0x0437, 0x0434) | ForEach-Object { [char]$_ }) -join ''))
            Assert (Click-El $ok) "could not click OK in Settings"
            Assert ($p.WaitForExit(15000)) "Settings did not close after OK"

            $saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            $names = @($saved.Profiles | ForEach-Object { $_.Name + $(if ($_.IsDefault) { '*' } else { '' }) }) -join ','
            Assert ($names -eq 'Alpha2,Gamma*') ("profiles after delete/rename/default: " + $names)
            Assert ($saved.Motw -eq 'All') ("the Mark-of-the-Web choice was saved as '" + $saved.Motw + "'")
        }
        finally { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
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
        try {
            $w = Wait-Window $p 20
            Assert ($w.Count -gt 0) "no extract dialog within 20 s"
            $dlg = First-Window $p
            if (-not $dlg) { Skip-Test "the extract dialog is not reachable via UI Automation" }
            $edit = (Controls-Of $dlg $CT::Edit) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y } | Select-Object -First 1
            [void][Mp.Win]::SendMessageW([IntPtr]$edit.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $out)
            # By position: if-exists, paths (same row), update, archive-after.
            $combos = @((Controls-Of $dlg $CT::ComboBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y }, { $_.Current.BoundingRectangle.X })
            Assert ($combos.Count -ge 4) ("expected 4 combo boxes in the extract dialog, found " + $combos.Count)
            [Mp.Combo]::Pick([IntPtr]$combos[1].Current.NativeWindowHandle, 1)   # no folders
            [Mp.Combo]::Pick([IntPtr]$combos[3].Current.NativeWindowHandle, 2)   # archive to the Recycle Bin
            $uk = (@(0x0420, 0x043E, 0x0437, 0x043F, 0x0430, 0x043A, 0x0443, 0x0432, 0x0430, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
            $go = Find-Button $dlg @('Extract', $uk)
            Assert (Click-El $go) "could not click Extract"
            Assert ($p.WaitForExit(60000)) ("x did not finish within 60 s; on screen: " + (Dialog-Text $p.Id))

            $files = @(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object { $_.FullName.Substring($out.Length + 1) } | Sort-Object) -join ','
            Assert ($files -eq 'a.txt,b.txt') ("with no folders the destination holds [" + $files + "]")
            Assert (-not (Test-Path -LiteralPath $arc)) "the archive is still there after 'Move to Recycle Bin'"
            $bin = (New-Object -ComObject Shell.Application).Namespace(10)
            $restore = (@(0x0412, 0x0456, 0x0434, 0x043D, 0x043E, 0x0432, 0x0438, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
            $found = $false
            foreach ($it in @($bin.Items())) {
                if ($it.Name -notlike 'flatme*' -or $bin.GetDetailsOf($it, 1) -ne $d) { continue }
                $found = $true
                foreach ($v in @($it.Verbs())) { if ($v.Name.Replace('&', '') -in @('Restore', $restore)) { $v.DoIt(); break } }
            }
            Assert $found "the archive is not in the Recycle Bin"
            Start-Sleep -Milliseconds 800
            Assert (Test-Path -LiteralPath $arc) "putting the archive back from the Recycle Bin failed"

            $saved = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            Assert ($saved.ExtractNoPaths -eq $true -and $saved.ExtractDeleteAfter -eq 'Recycle') ("the extract choices were not remembered: " + ($saved | ConvertTo-Json -Compress))
        }
        finally { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    }
}

# ---------- 18l ----------
# Explorer menu items (ticket 12), on the REAL HKCU: --addmenu on writes the quick-add item and New > archive,
# the Associations dialog switches items off and picks the quick format, a --quick run packs without a dialog,
# --addmenu off removes the file items. Every key this can touch is exported first and put back at the end,
# so the installed MakePack's menu is exactly as it was.
# Same list as Assoc.All in src\MakePack\Assoc.cs.
$MenuExts = '7z zip zipx jar rar tar gz tgz bz2 tbz2 tbz xz txz lzma z taz cab iso wim swm esd arj lzh lha cpio rpm deb udeb ar xar dmg vhd 001 ova'.Split(' ')

function Snapshot-Menu {
    $keys = @('Software\Classes\*\shell\MakePack.Add', 'Software\Classes\*\shell\MakePack.QuickAdd',
              'Software\Classes\Directory\shell\MakePack.Add', 'Software\Classes\Directory\shell\MakePack.QuickAdd',
              'Software\Classes\.7z\MakePack.Archive',
              'Software\Classes\MakePack.Archive\shell\MakePack.ExtractHere', 'Software\Classes\MakePack.Archive\shell\MakePack.ExtractTo',
              'Software\MakePack\MenuProfiles')
    foreach ($n in 1..9) { foreach ($parent in '*', 'Directory') { $keys += ('Software\Classes\' + $parent + '\shell\MakePack.P0' + $n) } }
    foreach ($e in $MenuExts) { foreach ($v in 'Open', 'ExtractHere', 'ExtractTo') { $keys += ('Software\Classes\SystemFileAssociations\.' + $e + '\shell\MakePack.' + $v) } }
    $dir = New-Dir (Join-Path $Root 'regsnap')
    $snap = @(); $i = 0
    foreach ($k in $keys) {
        $i++; $file = $null
        if (Test-Path -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $k)) {
            $file = Join-Path $dir ('k' + $i + '.reg')
            & cmd.exe /c ('reg export "HKCU\' + $k + '" "' + $file + '" /y >nul 2>&1')
            if ($LASTEXITCODE -ne 0) { throw ("could not snapshot HKCU\" + $k + "; nothing was changed") }
        }
        $snap += [pscustomobject]@{ Key = $k; File = $file }
    }
    $v = Get-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\MakePack' -ErrorAction SilentlyContinue
    [pscustomobject]@{ Keys = $snap; Values = @{ MenuItems = $v.MenuItems; QuickFormat = $v.QuickFormat; QuickExt = $v.QuickExt } }
}

function Restore-Menu($snap) {
    $bad = @()
    foreach ($k in $snap.Keys) {
        Remove-Item -LiteralPath ('Registry::HKEY_CURRENT_USER\' + $k.Key) -Recurse -Force -ErrorAction SilentlyContinue
        if ($k.File) {
            & cmd.exe /c ('reg import "' + $k.File + '" >nul 2>&1')
            if ($LASTEXITCODE -ne 0) { $bad += $k.Key }
        }
    }
    $root = 'Registry::HKEY_CURRENT_USER\Software\MakePack'
    foreach ($name in 'MenuItems', 'QuickFormat', 'QuickExt') {
        $old = $snap.Values[$name]
        if ($null -eq $old) { Remove-ItemProperty -LiteralPath $root -Name $name -ErrorAction SilentlyContinue }
        elseif ($name -eq 'MenuItems') { Set-ItemProperty -LiteralPath $root -Name $name -Value $old -Type DWord }
        else { Set-ItemProperty -LiteralPath $root -Name $name -Value $old }
    }
    if ($bad.Count -gt 0) { Write-Host ("     WARNING: could not put back " + ($bad -join ', ')) -ForegroundColor Red }
}

Test-Case 'menu_items' {
    $snap = Snapshot-Menu
    try {
        $hk = 'Registry::HKEY_CURRENT_USER\Software\Classes\'
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
        $w = Wait-Window $p 20
        $dlg = First-Window $p
        if (-not $dlg) { Skip-Test "the Associations dialog is not reachable via UI Automation" }
        $boxes = @((Controls-Of $dlg $CT::CheckBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.X }, { $_.Current.BoundingRectangle.Y })
        Assert ($boxes.Count -eq 7) ("expected 7 menu check boxes, found " + $boxes.Count)
        foreach ($b in $boxes[4], $boxes[5]) {   # second column: Add, quick add, New, profiles
            $t = $b.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($t.Current.ToggleState -eq 'On') { $t.Toggle() }
        }
        $fmt = (Controls-Of $dlg $CT::ComboBox) | Select-Object -First 1
        [Mp.Combo]::Pick([IntPtr]$fmt.Current.NativeWindowHandle, 1)   # 7z, zip, ...
        $okText = (@(0x0413, 0x0430, 0x0440, 0x0430, 0x0437, 0x0434) | ForEach-Object { [char]$_ }) -join ''
        Assert (Click-El (Find-Button $dlg @('OK', $okText))) "could not click OK"
        Assert ($p.WaitForExit(30000)) "the Associations dialog did not close"
        Assert (-not (Test-Path -LiteralPath $quick)) "quick-add is still on files after switching it off"
        Assert (-not (Test-Path -LiteralPath ($hk + '.7z\MakePack.Archive'))) "New > archive is still there after switching it off"
        Assert (Test-Path -LiteralPath ($hk + '*\shell\MakePack.Add')) "Add to archive went too"
        $v = Get-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\MakePack'
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
    }
    finally { Restore-Menu $snap }
}

# ---------- 18m ----------
# Profiles in Explorer's menu (ticket 13), on the REAL HKCU with the same snapshot as menu_items: a profile
# marked "in menu" gets its own classic item running a --profile "name"; the Settings button takes it out again.
Test-Case 'profile_menu' {
    $snap = Snapshot-Menu
    $json = '{ "Profiles": [ { "Name": "Mail zip", "Format": "Zip", "InMenu": true }, { "Name": "Plain" } ] }'
    try {
        With-Settings $json {
            param($cfg)
            $hk = 'Registry::HKEY_CURRENT_USER\Software\Classes\'
            $r = Run-App @('--addmenu', 'on') 30000
            Assert ($r.Exit -eq 0) ("--addmenu on exit code " + $r.Exit)
            $item = $hk + '*\shell\MakePack.P01'
            Assert (Test-Path -LiteralPath $item) "no menu item for the profile marked in menu"
            Assert (-not (Test-Path -LiteralPath ($hk + '*\shell\MakePack.P02'))) "a profile not marked in menu got an item"
            $cmd = (Get-ItemProperty -LiteralPath ($item + '\command')).'(default)'
            Assert ($cmd -like '*" a --profile "Mail zip" "%1"') ("profile item command: " + $cmd)
            Assert ((Get-ItemProperty -LiteralPath $item).'(default)' -like '*.zip*Mail zip*') ("profile item caption: " + (Get-ItemProperty -LiteralPath $item).'(default)')
            Assert (Test-Path -LiteralPath ($hk + 'Directory\shell\MakePack.P01')) "no profile item on folders"
            $list = Get-ItemProperty -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\MakePack\MenuProfiles\01'
            Assert ($list.Name -eq 'Mail zip' -and $list.Ext -eq '.zip') "MenuProfiles\01 for the Windows 11 menu"

            # Settings: the In menu button on that profile, OK -> the item is gone.
            $p = Start-App @('--settings')
            $w = Wait-Window $p 20
            $dlg = First-Window $p
            $lst = (Controls-Of $dlg $CT::List) | Select-Object -First 1
            $it = (Controls-Of $lst $CT::ListItem) | Where-Object { $_.Current.Name -like 'Mail zip*' } | Select-Object -First 1
            $it.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            $side = @((Controls-Of $dlg $CT::Button) | ForEach-Object { $_ } | Where-Object {
                $_.Current.BoundingRectangle.X -gt $lst.Current.BoundingRectangle.Right -and
                $_.Current.BoundingRectangle.Y -ge $lst.Current.BoundingRectangle.Y - 2 -and $_.Current.BoundingRectangle.Y -lt $lst.Current.BoundingRectangle.Bottom } | Sort-Object { $_.Current.BoundingRectangle.Y })
            Assert ($side.Count -eq 4) ("expected 4 buttons beside the profile list, found " + $side.Count)
            Assert (Click-El $side[3]) "could not click In menu"
            Start-Sleep -Milliseconds 300
            $okText = (@(0x0413, 0x0430, 0x0440, 0x0430, 0x0437, 0x0434) | ForEach-Object { [char]$_ }) -join ''
            Assert (Click-El (Find-Button $dlg @('OK', $okText))) "could not click OK"
            Assert ($p.WaitForExit(15000)) "Settings did not close"
            Assert (-not (Test-Path -LiteralPath $item)) "the profile item is still in the menu after taking it out"
            Assert (-not (Test-Path -LiteralPath 'Registry::HKEY_CURRENT_USER\Software\MakePack\MenuProfiles')) "MenuProfiles is still there"
        }
    }
    finally { Restore-Menu $snap }
}

# ---------- 18n ----------
# Convert archives (ticket 14) through the real dialog: a .rar (made by console Rar.exe when it is
# installed) and a .zip in one batch -> 7z. Both 7z hold the same bytes, the originals stay, and the dialog
# closes on its own after the summary - which it only does when there were no errors.
Test-Case 'convert_dialog' {
    $rarExe = Join-Path $env:ProgramFiles 'OtherArc\Rar.exe'
    if (-not (Test-Path -LiteralPath $rarExe)) { Skip-Test "Rar.exe is not installed - no way to make a .rar fixture" }
    $d = New-TestDir 'convert'
    $src = New-Dir (Join-Path $d 'payload')
    New-Dir (Join-Path $src 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value ('alpha ' * 3000) -Encoding ASCII
    Rand-File (Join-Path $src 'sub\b.bin') (200KB) 1414
    $rar = Join-Path $d 'payload.rar'
    & $rarExe a -r -ep1 -idq $rar (Join-Path $src '*') | Out-Null
    Assert (Test-Path -LiteralPath $rar) "Rar.exe did not make the fixture"
    $zip = Join-Path $d 'other.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }

    With-Settings '{}' {
        $p = Start-App @('convert', (Q $rar), (Q $zip))
        try {
            $w = Wait-Window $p 20
            Assert ($w.Count -gt 0) "no Convert window within 20 s"
            $dlg = First-Window $p
            if (-not $dlg) { Skip-Test "the Convert dialog is not reachable via UI Automation" }
            $items = @((Controls-Of $dlg $CT::ListItem) | ForEach-Object { $_ })
            Assert ($items.Count -eq 2) ("expected the 2 archives in the list, found " + $items.Count)
            # Keep-if-not-smaller off: rar is tight, and this case is about the conversion, not the size race.
            $keep = (Controls-Of $dlg $CT::CheckBox) | ForEach-Object { $_ } | Sort-Object { $_.Current.BoundingRectangle.Y } | Select-Object -First 1
            $t = $keep.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($t.Current.ToggleState -eq 'On') { $t.Toggle() }
            $uk = (@(0x041A, 0x043E, 0x043D, 0x0432, 0x0435, 0x0440, 0x0442, 0x0443, 0x0432, 0x0430, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
            Assert (Click-El (Find-Button $dlg @('Convert', $uk))) "could not click Convert"

            $box = $null
            $deadline = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $deadline -and -not $box) {
                # The summary is the owned message box whose text reads "<label>: <count>". A modern message box shows
                # its text and buttons to UI Automation as Panes, not Text/Button.
                $box = (Controls-Of $dlg $CT::Window) | ForEach-Object { $_ } | Where-Object {
                    $_.Current.NativeWindowHandle -ne 0 -and
                    @((Controls-Of $_ $CT::Pane) | ForEach-Object { $_ } | Where-Object { $_.Current.Name -match ':\s*\d' }).Count -gt 0 } | Select-Object -First 1
                if (-not $box) { Start-Sleep -Milliseconds 400 }
            }
            Assert ($box -ne $null) ("no summary after converting; on screen: " + (Dialog-Text $p.Id))
            $summary = ((Controls-Of $box $CT::Pane) | ForEach-Object { $_ } | Where-Object { $_.Current.Name -match ':\s*\d' } | ForEach-Object { $_.Current.Name }) -join ' '
            Write-Host ("     note: " + ($summary -replace '\s+', ' '))
            [void][Mp.Win]::PostMessage([IntPtr]$box.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            Assert ($p.WaitForExit(15000)) ("the dialog stayed open after the summary, so something failed: " + $summary)
        }
        finally { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    }

    foreach ($pair in @(@('payload.7z', $rar), @('other.7z', $zip))) {
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
# method and the archive path. UIA Invoke on a toolbar button that opens a modal window blocks the app's UIA
# side, so a helper process presses it (tools\invoke_btn.ps1) and the window is driven with plain Win32.
# The user's clipboard text is put back afterwards.
if (-not ('Mp.Wnd' -as [type])) {
    Add-Type -Namespace Mp -Name Wnd -MemberDefinition @'
delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
static string Text(IntPtr h) { var sb = new System.Text.StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
public static IntPtr Top(uint pid, string prefix) {
    IntPtr hit = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && Text(h).StartsWith(prefix)) { hit = h; return false; } return true; }, IntPtr.Zero);
    return hit;
}
public static IntPtr Child(IntPtr parent, string text) {
    IntPtr hit = IntPtr.Zero;
    EnumChildWindows(parent, (h, l) => { if (Text(h).Replace("&", "") == text) { hit = h; return false; } return true; }, IntPtr.Zero);
    return hit;
}
'@
}

Test-Case 'info_window' {
    $d = New-TestDir 'info'
    $src = New-Dir (Join-Path $d 'payload')
    Set-Content -LiteralPath (Join-Path $src 'a.txt') -Value ('info ' * 20000) -Encoding ASCII
    $arc = Join-Path $d 'info.7z'
    SevenZip @('a', '-m0=LZMA2:d=64k', $arc, $src, '-bso0', '-bsp0')
    $saved = $null
    try { $saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
    $p = Start-App @((Q $arc))
    $helper = $null
    try {
        $w = Wait-Window $p 20
        Assert ($w.Count -gt 0) "no main window within 20 s"
        Start-Sleep -Milliseconds 500
        $infoUk = (@(0x0412, 0x0456, 0x0434, 0x043E, 0x043C, 0x043E, 0x0441, 0x0442, 0x0456) | ForEach-Object { [char]$_ }) -join ''
        $esc = ($infoUk.ToCharArray() | ForEach-Object { '\u{0:x4}' -f [int]$_ }) -join ''
        $helper = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            ('"' + (Join-Path $PSScriptRoot 'invoke_btn.ps1') + '"'), $p.Id, $esc) -WindowStyle Hidden -PassThru
        $info = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and $info -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 300
            $info = [Mp.Wnd]::Top([uint32]$p.Id, $infoUk)
            if ($info -eq [IntPtr]::Zero) { $info = [Mp.Wnd]::Top([uint32]$p.Id, 'Info - ') }
        }
        Assert ($info -ne [IntPtr]::Zero) "the Info window did not open"
        $copyUk = (@(0x041A, 0x043E, 0x043F, 0x0456, 0x044E, 0x0432, 0x0430, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
        $copy = [Mp.Wnd]::Child($info, $copyUk)
        if ($copy -eq [IntPtr]::Zero) { $copy = [Mp.Wnd]::Child($info, 'Copy') }
        Assert ($copy -ne [IntPtr]::Zero) "no Copy button in the Info window"
        Set-Clipboard -Value 'before'
        [void][Mp.Win]::PostMessage($copy, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
        Start-Sleep -Milliseconds 800
        $clip = Get-Clipboard -Raw
        Assert ($clip -match 'LZMA2:16') ("the copied info has no LZMA2:16 method: " + $clip)
        Assert ($clip.Contains($arc)) "the copied info has no archive path"
        [void][Mp.Win]::PostMessage($info, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    }
    finally {
        try { $p.Kill() } catch { }
        if ($helper) { try { $helper.Kill() } catch { } }
        if ($saved) { Set-Clipboard -Value $saved } else { Set-Clipboard -Value $null }
    }
}

# ---------- 18p ----------
# Report > Copy to clipboard (ticket 16) from the main window: the clipboard gets the file list with a
# Cyrillic name intact. The drop-down and its item are not modal, so plain UI Automation drives them.
# The user's clipboard text is put back afterwards.
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
        $w = Wait-Window $p 20
        $main = First-Window $p
        if (-not $main) { Skip-Test "the main window is not reachable via UI Automation" }
        $reportUk = (@(0x0417, 0x0432, 0x0456, 0x0442) | ForEach-Object { [char]$_ }) -join ''
        $btn = (All-Desc $main) | ForEach-Object { $_ } | Where-Object { $_.Current.Name -in @('Report', $reportUk) } | Select-Object -First 1
        Assert ($btn -ne $null) "no Report button on the toolbar"
        $btn.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $copyUk = (@(0x041A, 0x043E, 0x043F, 0x0456, 0x044E, 0x0432, 0x0430, 0x0442, 0x0438) | ForEach-Object { [char]$_ }) -join ''
        $item = $null
        $deadline = (Get-Date).AddSeconds(5)   # the drop-down can take a while to show up under load
        while (-not $item -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            foreach ($win in (Uia-Windows $p.Id)) {
                $item = (All-Desc $win) | ForEach-Object { $_ } | Where-Object { $_.Current.Name -like ($copyUk + '*') -or $_.Current.Name -like 'Copy to*' } | Select-Object -First 1
                if ($item) { break }
            }
        }
        Assert ($item -ne $null) "no Copy item in the Report menu"
        Set-Clipboard -Value 'before'
        $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 800
        $clip = Get-Clipboard -Raw
        Assert ($clip -match 'plain\.txt' -and $clip.Contains($uk + '.txt')) ("the copied report lacks a file: " + $clip)
        Assert ($clip.Contains($arc)) "the copied report has no archive path"
    }
    finally {
        try { $p.Kill() } catch { }
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
    $wins = ""
    if (-not $p.WaitForExit($TimeoutMs)) { $wins = Dialog-Text $p.Id; try { $p.Kill() } catch { }; $code = -1 } else { $code = $p.ExitCode }
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
    try {
        $w = Wait-Window $p 15
        Assert ($w.Count -gt 0) "t -p showed no password prompt within 15 s"
        $el = First-Window $p
        if (-not $el) { Skip-Test "the password window is not reachable via UI Automation" }
        $cancel = Find-Button $el @('Cancel', $UK_CANCEL)
        if (-not $cancel) { Skip-Test "no Cancel button in the password window" }
        Assert (Click-El $cancel) "could not click Cancel"
        Assert ($p.WaitForExit(15000)) ("t -p kept running after Cancel; on screen: " + (Dialog-Text $p.Id))
        Assert ($p.ExitCode -eq 255) ("a cancelled prompt must exit 255, got " + $p.ExitCode)
    }
    finally { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
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
        $n = @(Get-Process (App-Name) -ErrorAction SilentlyContinue).Count
        if ($n -gt $max) { $max = $n }
        if (@($procs | Where-Object { -not $_.HasExited }).Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    $stuck = @($procs | Where-Object { -not $_.HasExited })
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
    Start-App @((Q $z1)) | Out-Null
    Start-Sleep -Seconds 3
    Start-App @((Q $z2)) | Out-Null
    Start-Sleep -Seconds 3
    $alive = @(Get-Process (App-Name) -ErrorAction SilentlyContinue)
    $titles = @()
    foreach ($a in $alive) { $titles += (Windows-Of $a.Id) }
    foreach ($a in $alive) { try { $a.Kill() } catch { } }
    Assert ($alive.Count -eq 1) ("opening a second archive started another process: " + $alive.Count + " alive; titles " + (Titles $titles))
    $hit = @($titles | Where-Object { $_ -like '*second.zip*' })
    Assert ($hit.Count -gt 0) ("the second archive did not take over the window; titles " + (Titles $titles))
}

# ---------- 21 ----------
# The in-window editing features: the list is there and the new toolbar button is on screen. The context menu
# and drag-and-drop need real mouse input; they are covered by a manual/SendInput smoke, not here.
Test-Case 'gui_context_menu' {
    $d = New-TestDir 'guimenu'
    $src = New-Dir (Join-Path $d 'src')
    Set-Content -LiteralPath (Join-Path $src 'inside1.txt') -Value 'x' -Encoding ASCII
    $zip = Join-Path $d 'menu.zip'
    Push-Location $src
    try { SevenZip @('a', '-tzip', $zip, '*', '-bso0', '-bsp0') } finally { Pop-Location }
    $add = S-Text 'TbAdd'
    $p = Start-App @((Q $zip))
    $texts = Wait-Text $p $add 10
    Assert (-not $p.HasExited) ("the process exited with code " + $p.ExitCode + " instead of showing the archive")
    Assert (Has-Exact $texts $add) ("no '" + $add[0] + "' toolbar button on screen: " + (Titles $texts))
    Assert (Has-Exact $texts @('inside1.txt')) ("the list does not show inside1.txt; on screen: " + (Titles $texts))
    $win = First-Window $p
    Assert ($win -ne $null) "the main window is not reachable via UI Automation"
    $lists = @(Controls-Of $win $CT::List) + @(Controls-Of $win $CT::DataGrid)
    Assert ($lists.Count -gt 0) "no list control in the main window"
}

# ---------- summary ----------
Kill-App
Stop-ScreenPin
Write-Host ""
Write-Host ("SUMMARY: " + $script:nPass + " passed, " + $script:nFail + " failed, " + $script:nSkip + " skipped")
Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:nFail -gt 0) { exit 1 }
exit 0
