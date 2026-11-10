# MP-G2 fix verification (PowerShell 5.1, pure ASCII): corrupt 7z header = damaged alert, viewer state items,
# Esc with a drop-down open, the open's progress + Cancel, the queue window id. Same sandbox rules as
# tools\gui_dialogs.ps1: private MAKEPACK_INSTANCE / MAKEPACK_SETTINGS, files in %TEMP%\makepack-test-<random>
# (removed), windows on DISPLAY1 via MakeKit automation, only our own PIDs killed.
# Screenshots: zig-out\shots\fix-MP-G2-*.png
#   powershell -ExecutionPolicy Bypass -File tools\gui_g2fix.ps1 [-Only damaged|viewer|esc|opencancel]
param([string]$Exe = '', [string]$Only = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.Drawing
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo '..\MakeKit\tools\imgui-auto.ps1')
if ($Exe -eq '') { $Exe = Join-Path $repo 'zig-out\bin\MakePack.exe' }
$Exe = (Resolve-Path $Exe).Path
$sevenZip = Join-Path $repo 'third_party\7zip\7z.exe'
$shots = Join-Path $repo 'zig-out\shots'
New-Item -ItemType Directory -Force $shots | Out-Null

$rand = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$root = Join-Path $env:TEMP "makepack-test-$rand"
New-Item -ItemType Directory -Force $root | Out-Null
$envs = @{
    MAKEPACK_INSTANCE = "MakePack-g2fix-$rand"
    MAKEPACK_SETTINGS = (Join-Path $root 'settings.json')
    MAKEPACK_HIVE     = "Software\MakePackTest-$rand\"
}
$results = New-Object System.Collections.ArrayList
$pids = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    Write-Host ('{0} {1} {2}' -f ($(if ($ok) { 'OK  ' } else { 'FAIL' })), $name, $detail)
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = $ok })
}
function Start-Mp([string[]]$ArgList) {
    $app = Start-AutoApp -Exe $Exe -Args $ArgList -Env $envs
    [void]$pids.Add($app.Process.Id)
    $app
}
function Wait-Exit($app, [int]$ms = 20000) {
    if (-not $app.Process.WaitForExit($ms)) { Stop-Process -Id $app.Process.Id -Force -ErrorAction SilentlyContinue; return -1 }
    try { $app.Pipe.Dispose() } catch { }
    $app.Process.ExitCode
}
function Shot($app, [string]$name) {
    $null = Invoke-AutoFrames $app 3
    $bmp = Join-Path $shots "fix-MP-G2-$name.bmp"
    $null = Save-AutoScreenshot $app $bmp
    $img = [System.Drawing.Image]::FromFile($bmp)
    try { $img.Save((Join-Path $shots "fix-MP-G2-$name.png"), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
    Remove-Item -LiteralPath $bmp
}
function Item($app, [string]$label, [int]$ms = 8000) { Wait-AutoItem $app $label $ms }
function Find-Item($app, [string]$suffix) { @(Get-AutoItems $app | Where-Object { $_.label -like "*$suffix" }) | Select-Object -First 1 }
function Run-7z([string[]]$a) {
    $p = Start-Process -FilePath $sevenZip -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root '7z.out') -RedirectStandardError (Join-Path $root '7z.err')
    $p.ExitCode
}

$src = Join-Path $root 'src'
New-Item -ItemType Directory -Force $src | Out-Null
Set-Content -LiteralPath (Join-Path $src 'one.txt') -Value ('hello one ' * 400) -Encoding ASCII
# cp1251 bytes of a Cyrillic word + an ASCII marker
$cyr = [byte[]](0xCF, 0xF0, 0xE8, 0xE2, 0xB3, 0xF2, 0x20) + [System.Text.Encoding]::ASCII.GetBytes("zebra line one`r`nline two`r`n")
[System.IO.File]::WriteAllBytes((Join-Path $src 'cyr.txt'), $cyr)

try {
    # ---- 1. 7z with a corrupt packed header: "damaged" alert, exit 3, no password prompt --------------------
    if ($Only -eq '' -or $Only -eq 'damaged') {
        $good = Join-Path $root 'good.7z'
        $many = Join-Path $root 'many'
        New-Item -ItemType Directory -Force $many | Out-Null
        1..80 | ForEach-Object { Set-Content -LiteralPath (Join-Path $many ('file-number-{0:d3}.txt' -f $_)) -Value "x$_" -Encoding ASCII }
        Push-Location $many; try { $null = Run-7z @('a', $good, '*.txt') } finally { Pop-Location }
        $bytes = [System.IO.File]::ReadAllBytes($good)
        $nho = [BitConverter]::ToUInt64($bytes, 12)
        Check 'damaged: next header is a packed one (0x17)' ($bytes[32 + $nho] -eq 0x17) ('first byte ' + $bytes[32 + $nho])
        $bytes[32 + $nho - 3] = $bytes[32 + $nho - 3] -bxor 0xFF # inside the packed header stream
        $bad = Join-Path $root 'badhdr.7z'
        [System.IO.File]::WriteAllBytes($bad, $bytes)
        $l = Run-7z @('l', $bad)
        Check 'damaged: 7z.exe cannot list it either' ($l -ne 0) "7z l=$l"
        $app = Start-Mp @('x', $bad)
        $t = Item $app '##msg_text'
        $pw = Find-Item $app '##password_input'
        Check 'damaged: its own alert, no password prompt' (($t -ne $null) -and ($pw -eq $null)) $t.label
        Shot $app 'damaged-header'
        Invoke-AutoClick $app '##msg_ok'
        $code = Wait-Exit $app
        Check 'damaged: exit 3' ($code -eq 3) "code=$code"
        # an encrypted header still asks for the password
        $enc = Join-Path $root 'enc.7z'
        Push-Location $src; try { $null = Run-7z @('a', '-pSecret1', '-mhe=on', $enc, 'one.txt') } finally { Pop-Location }
        $app = Start-Mp @('x', $enc)
        $p = Item $app '##password_input'
        Check 'damaged: encrypted headers still ask for a password' ($p -ne $null)
        Invoke-AutoClick $app '##password_input'; Invoke-AutoType $app 'wrong'; Invoke-AutoClick $app '##password_ok'
        Start-Sleep -Milliseconds 500
        $p2 = Item $app '##password_input'
        $m = Find-Item $app '##msg_text'
        Check 'damaged: wrong password re-asks (no damaged alert)' (($p2 -ne $null) -and ($m -eq $null))
        Invoke-AutoClick $app '##password_cancel'
        $code = Wait-Exit $app
        Check 'damaged: password cancel = 255' ($code -eq 255) "code=$code"
    }

    # ---- 2. viewer: state items (encoding, wrap, font, content), encoding switch, Esc with a list open ------
    if ($Only -eq '' -or $Only -eq 'viewer') {
        $va = Join-Path $root 'v.7z'
        Push-Location $src; try { $null = Run-7z @('a', $va, 'one.txt', 'cyr.txt') } finally { Pop-Location }
        $app = Start-Mp @($va)
        $null = Item $app '###mcommands'
        $null = Invoke-AutoFrames $app 5
        Invoke-AutoClick $app '###mtools'; Invoke-AutoClick $app '###m_find'
        $null = Item $app '##find_go'
        Invoke-AutoClick $app '##find_text'; Invoke-AutoType $app 'zebra'
        Invoke-AutoClick $app '##find_go'
        $null = Item $app '##find_r0'
        Invoke-AutoClick $app '##find_r0'
        Invoke-AutoClick $app '##find_view'
        $e = Item $app '##viewer_enc_state'
        Check 'viewer: cp1251 autodetected, readable' ($e.label -eq 'Windows (1251)##viewer_enc_state') $e.label
        $c = Find-Item $app '##viewer_content'
        Check 'viewer: content readable' (($c -ne $null) -and ($c.label -like '*zebra line one*line two*')) $(if ($c) { $c.label } else { '' })
        $c1251 = $c.label
        $f = Find-Item $app '##viewer_font_state'
        Check 'viewer: Consolas 16 by default (ViewerForm)' ($f.label -eq 'Consolas 16##viewer_font_state') $f.label
        Shot $app 'viewer-1251'
        Invoke-AutoClick $app '##viewer_mview'
        $m = Item $app '##viewer_enc0'
        Check 'viewer: menu item checked state reaches the test' ([bool]$m.checked -and [bool]$m.checkable) ("checked=" + $m.checked)
        Invoke-AutoClick $app '##viewer_enc3'
        $null = Invoke-AutoFrames $app 3
        $e = Find-Item $app '##viewer_enc_state'
        $c = Find-Item $app '##viewer_content'
        Check 'viewer: switch to UTF-8 visible in state and content' (($e.label -eq 'UTF-8##viewer_enc_state') -and ($c.label -ne $c1251)) $e.label
        Invoke-AutoClick $app '##viewer_text'
        Invoke-AutoKey $app 'ctrl+W'
        $null = Invoke-AutoFrames $app 2
        $wr = Find-Item $app '##viewer_wrap_state'
        Check 'viewer: Ctrl+W wrap on' ($wr.label -eq 'on##viewer_wrap_state') $wr.label
        Invoke-AutoClick $app '##viewer_mview'; Invoke-AutoClick $app '##viewer_font'
        $null = Item $app '##viewer_font_face'
        Invoke-AutoClick $app '##viewer_font_face'
        $null = Item $app '##viewer_font_face_1'
        Shot $app 'viewer-font'
        Invoke-AutoKey $app 'Escape'
        $null = Invoke-AutoFrames $app 3
        $vt = Find-Item $app '##viewer_text'
        Check 'viewer: Esc with the face list open keeps the viewer' ($vt -ne $null)
        Invoke-AutoClick $app '##viewer_font_face'
        Invoke-AutoClick $app '##viewer_font_face_1'
        Invoke-AutoClick $app '##viewer_font_ok'
        $null = Invoke-AutoFrames $app 3
        $f = Find-Item $app '##viewer_font_state'
        Check 'viewer: face switched to Segoe UI' ($f.label -eq 'Segoe UI 16##viewer_font_state') $f.label
        Invoke-AutoClick $app '##viewer_mview'
        $null = Item $app '##viewer_enc0'
        Invoke-AutoKey $app 'Escape'
        $null = Invoke-AutoFrames $app 3
        Check 'viewer: Esc with the View menu open keeps the viewer' ((Find-Item $app '##viewer_text') -ne $null)
        Shot $app 'viewer-utf8'
        Invoke-AutoClick $app '##viewer_text'
        Invoke-AutoKey $app 'Escape'
        $null = Invoke-AutoFrames $app 3
        Check 'viewer: Esc then closes it' ((Find-Item $app '##viewer_text') -eq $null)
        $code = Stop-AutoApp $app
        Check 'viewer: quit' ($code -eq 0) "code=$code"
    }

    # ---- 3. Esc with a drop-down open closes the list only (extract and compress dialogs) ------------------
    if ($Only -eq '' -or $Only -eq 'esc') {
        $ea = Join-Path $root 'e.7z'
        Push-Location $src; try { $null = Run-7z @('a', $ea, 'one.txt') } finally { Pop-Location }
        $app = Start-Mp @('x', $ea)
        $null = Item $app '##extract_ok'
        Invoke-AutoClick $app '##extract_mode'
        $null = Item $app '##extract_mode_0'
        Shot $app 'esc-extract-list'
        Invoke-AutoKey $app 'Escape'
        $null = Invoke-AutoFrames $app 3
        $alive = -not $app.Process.HasExited
        $ok = if ($alive) { Find-Item $app '##extract_ok' } else { $null }
        $lst = if ($alive) { Find-Item $app '##extract_mode_0' } else { $null }
        Check 'esc: extract dialog stays, list closed' ($alive -and ($ok -ne $null) -and ($lst -eq $null))
        Invoke-AutoKey $app 'Escape'
        $code = Wait-Exit $app
        Check 'esc: second Esc cancels the dialog (255)' ($code -eq 255) "code=$code"
        $app = Start-Mp @('a', (Join-Path $src 'one.txt'))
        $null = Item $app '##compress_create'
        Invoke-AutoClick $app '##compress_format'
        $null = Item $app '##compress_format_1'
        Invoke-AutoKey $app 'Escape'
        $null = Invoke-AutoFrames $app 3
        $alive = -not $app.Process.HasExited
        Check 'esc: compress dialog stays after Esc on the format list' ($alive -and ((Find-Item $app '##compress_create') -ne $null))
        Invoke-AutoKey $app 'Escape'
        $code = Wait-Exit $app
        Check 'esc: then Esc cancels it (C# Add: exit 0)' ($code -eq 0) "code=$code"
    }

    # ---- 4. a slow open (1 GB of zeros as .tar.gz): progress after 300 ms with Cancel; queue window id ------
    if ($Only -eq '' -or $Only -eq 'opencancel') {
        $big = Join-Path $root 'big'
        New-Item -ItemType Directory -Force $big | Out-Null
        $zero = Join-Path $big 'zero.bin'
        $fs = [System.IO.File]::Create($zero); $fs.SetLength(1GB); $fs.Close()
        $tar = Join-Path $root 'big.tar'; $tgz = Join-Path $root 'big.tar.gz'
        Push-Location $big; try { $null = Run-7z @('a', '-ttar', $tar, 'zero.bin') } finally { Pop-Location }
        $null = Run-7z @('a', '-tgzip', '-mx1', $tgz, $tar)
        Remove-Item -LiteralPath $zero, $tar
        Check 'opencancel: big.tar.gz made' (Test-Path $tgz)
        $mpTemp = Join-Path $env:TEMP 'MakePack'
        $tmpBefore = @(Get-ChildItem $mpTemp -Directory -ErrorAction SilentlyContinue).Count

        # no main window (Explorer's "Extract to"): Cancel ends the process at once with 255
        $app = Start-Mp @('x', $tgz, '--sub')
        $c = Item $app '##opening_cancel' 10000
        $st = Find-Item $app '##opening_status'
        Check 'opencancel: progress with Cancel while opening' ($c -ne $null) $(if ($st) { $st.label } else { '' })
        $wins = @(Get-AutoItems $app -Windows | ForEach-Object { $_.name })
        Shot $app 'opening'
        $t0 = Get-Date
        Invoke-AutoClick $app '##opening_cancel'
        $gone = $false
        while (((Get-Date) - $t0).TotalMilliseconds -lt 3000) {
            $app.Process.Refresh()
            if ($app.Process.HasExited -or $app.Process.MainWindowHandle -eq [IntPtr]::Zero) { $gone = $true; break }
            Start-Sleep -Milliseconds 50
        }
        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
        $code = Wait-Exit $app 120000
        $ms2 = [int]((Get-Date) - $t0).TotalMilliseconds
        Check 'opencancel: Cancel = window gone at once, exit 255 once the open ended' ($gone -and ($code -eq 255)) "window gone in $ms ms, exit $code after $ms2 ms; windows: $($wins -join ' | ')"

        # main window, Info on the file (Dialogs.infoFile -> OpenArchive): Cancel leaves the main window usable;
        # the abandoned open ends later and is swept. (Opening it in the main window itself is G1's synchronous
        # engine.open in mw_model.goWith: no progress there.)
        $app = Start-Mp @($root)
        $null = Item $app '###mcommands'
        $null = Item $app 'big.tar.gz###r'
        Invoke-AutoClick $app 'big.tar.gz###r'
        Invoke-AutoClick $app '###mtools'; Invoke-AutoClick $app '###m_info'
        $null = Item $app '##opening_cancel' 10000
        Shot $app 'opening-main'
        Invoke-AutoClick $app '##opening_cancel'
        $null = Invoke-AutoFrames $app 3
        $m = Find-Item $app '###mcommands'
        Check 'opencancel: main window stays after Cancel' ($m -ne $null)
        Start-Sleep -Seconds 8
        $null = Invoke-AutoFrames $app 3
        Check 'opencancel: still alive after the abandoned open ended' (-not $app.Process.HasExited)
        $code = Stop-AutoApp $app
        Check 'opencancel: quit 0' ($code -eq 0) "code=$code"

        # the extract queue's progress window id is queue<n>
        $app = Start-Mp @('x', $tgz, '--sub')
        $null = Item $app '##queue_cancel' 30000
        $wins = @(Get-AutoItems $app -Windows | ForEach-Object { $_.name })
        Check 'queue: progress window id is ###queue<n>' (@($wins | Where-Object { $_ -match '###queue\d+$' }).Count -eq 1) ($wins -join ' | ')
        Shot $app 'queue-progress'
        Invoke-AutoClick $app '##queue_cancel'
        $code = Wait-Exit $app 30000
        Check 'queue: Cancel = 255' ($code -eq 255) "code=$code"
        Start-Sleep -Milliseconds 500
        $tmpAfter = @(Get-ChildItem $mpTemp -Directory -ErrorAction SilentlyContinue).Count
        Check 'opencancel: no temp folder left behind' ($tmpAfter -le $tmpBefore) "before=$tmpBefore after=$tmpAfter"
    }
} catch {
    Check 'script' $false ($_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
    foreach ($id in $pids) { try { $p = Get-Process -Id $id -ErrorAction Stop; if ($p.Path -eq $Exe) { Stop-Process -Id $id -Force } } catch { } }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
$bad = @($results | Where-Object { -not $_.Ok })
Write-Host ('{0} checks, {1} failed; sandbox removed: {2}' -f $results.Count, $bad.Count, (-not (Test-Path $root)))
if ($bad.Count -eq 0) { Write-Host 'G2 FIX OK'; exit 0 } else { exit 1 }
