# MP-G2 dialogs GUI test (PowerShell 5.1, pure ASCII). Drives MakePack.exe over MakeKit automation on DISPLAY1
# in a throw-away sandbox: private MAKEPACK_INSTANCE / MAKEPACK_SETTINGS / MAKEPACK_HIVE, files only in
# %TEMP%\makepack-test-<random> (removed at the end), registry only under HKCU\Software\MakePackTest-<random>.
# Screenshots: zig-out\shots\MP-G2-*.bmp (convert with tools\bmp2png.py if wanted).
#   powershell -ExecutionPolicy Bypass -File tools\gui_dialogs.ps1 [-Exe zig-out\bin\MakePack.exe]
param([string]$Exe = '', [string]$Only = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
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
$hiveKey = "Software\MakePackTest-$rand"
$envs = @{
    MAKEPACK_INSTANCE = "MakePack-g2test-$rand"
    MAKEPACK_SETTINGS = (Join-Path $root 'settings.json')
    MAKEPACK_HIVE     = "$hiveKey\"
}
$results = New-Object System.Collections.ArrayList
$pids = New-Object System.Collections.ArrayList

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $line = ('{0} {1} {2}' -f ($(if ($ok) { 'OK  ' } else { 'FAIL' })), $name, $detail)
    Write-Host $line
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
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
    $null = Save-AutoScreenshot $app (Join-Path $shots "MP-G2-$name.bmp")
}

function Item($app, [string]$label) { Wait-AutoItem $app $label 8000 }

function Run-7z([string[]]$a) {
    $p = Start-Process -FilePath $sevenZip -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $root '7z.out')
    $p.ExitCode
}

# ---- sandbox files ------------------------------------------------------------------------------------------
$src = Join-Path $root 'src'
New-Item -ItemType Directory -Force (Join-Path $src 'dir1') | Out-Null
Set-Content -LiteralPath (Join-Path $src 'one.txt') -Value 'hello one, needle inside' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $src 'dir1\two.txt') -Value 'second file' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Value 'not an archive at all' -Encoding ASCII
$a7z = Join-Path $root 'a.7z'
$b7z = Join-Path $root 'b.7z'
$enc = Join-Path $root 'enc.7z'
$enc2 = Join-Path $root 'enc2.7z'
$czip = Join-Path $root 'c.zip'
Push-Location $src
try {
    $null = Run-7z @('a', $a7z, 'one.txt', 'dir1')
    $null = Run-7z @('a', $b7z, 'one.txt')
    $null = Run-7z @('a', '-pSecret1', '-mhe=on', $enc, 'one.txt')
    $null = Run-7z @('a', '-pSecret1', '-mhe=off', $enc2, 'one.txt')
    $null = Run-7z @('a', '-tzip', $czip, 'one.txt', 'dir1')
} finally { Pop-Location }

try {
    # ---- 1. extract dialog (x <archive>), smart subfolder default, OK -> extracted --------------------------
    if ($Only -eq '' -or $Only -eq 'extract') {
        $app = Start-Mp @('x', $a7z)
        $sub = Item $app '##extract_sub'
        Check 'extract: dialog shown, subfolder ticked (2 top-level names)' ([bool]$sub.checked)
        Shot $app 'extract'
        Invoke-AutoClick $app '##extract_ok'
        $code = Wait-Exit $app
        Check 'extract: exit 0' ($code -eq 0) "code=$code"
        Check 'extract: files in a\' ((Test-Path (Join-Path $root 'a\one.txt')) -and (Test-Path (Join-Path $root 'a\dir1\two.txt')))
    }

    # ---- 2. encrypted headers: password prompt, wrong -> re-ask, right -> extract dialog, Cancel -> 255 ------
    if ($Only -eq '' -or $Only -eq 'password') {
        $app = Start-Mp @('x', $enc)
        $p1 = Item $app '##password_prompt'
        Shot $app 'password'
        Invoke-AutoClick $app '##password_input'
        Invoke-AutoType $app 'wrong'
        Invoke-AutoClick $app '##password_ok'
        Start-Sleep -Milliseconds 300
        $deadline = (Get-Date).AddSeconds(8); $p2 = $null
        while ((Get-Date) -lt $deadline) {
            $p2 = @(Get-AutoItems $app | Where-Object { $_.label -like '*##password_prompt' }) | Select-Object -First 1
            if ($p2 -and $p2.label -ne $p1.label) { break }
            Start-Sleep -Milliseconds 200
        }
        Check 'password: wrong password re-asks with its own text' ($p2 -and $p2.label -ne $p1.label) $(if ($p2) { $p2.label } else { '' })
        Shot $app 'password-retry'
        Invoke-AutoClick $app '##password_input'
        Invoke-AutoType $app 'Secret1'
        Invoke-AutoClick $app '##password_ok'
        $null = Item $app '##extract_cancel'
        Invoke-AutoClick $app '##extract_cancel'
        $code = Wait-Exit $app
        Check 'password: cancel in the extract dialog = exit 255' ($code -eq 255) "code=$code"
    }

    # ---- 2b. bodies encrypted, file list not: EnsurePassword before the job (x --sub, no dialog) ---------------
    if ($Only -eq '' -or $Only -eq 'ensure') {
        $app = Start-Mp @('x', $enc2, '--sub')
        $null = Item $app '##password_input'
        Invoke-AutoClick $app '##password_input'
        Invoke-AutoType $app 'Secret1'
        Invoke-AutoClick $app '##password_ok'
        $code = Wait-Exit $app
        Check 'ensure: password asked before extracting, exit 0' (($code -eq 0) -and (Test-Path (Join-Path $root 'enc2\one.txt'))) "code=$code"
    }

    # ---- 2c. cli t -p: PasswordForm.Ask in its own window before any GUI --------------------------------------
    if ($Only -eq '' -or $Only -eq 'cli') {
        $app = Start-Mp @('t', '-p', $enc)
        $null = Item $app '##password_input'
        Shot $app 'cli-password'
        Invoke-AutoClick $app '##password_input'
        Invoke-AutoType $app 'Secret1'
        Invoke-AutoClick $app '##password_ok'
        $code = Wait-Exit $app
        Check 'cli: t -p asks in its own window, exit 0' ($code -eq 0) "code=$code"
        $app = Start-Mp @('t', '-p', $enc)
        $null = Item $app '##password_cancel'
        Invoke-AutoClick $app '##password_cancel'
        $code = Wait-Exit $app
        Check 'cli: t -p cancelled = exit 255' ($code -eq 255) "code=$code"
    }

    # ---- 3. not an archive: its own alert, exit 2 --------------------------------------------------------------
    if ($Only -eq '' -or $Only -eq 'notarchive') {
        $app = Start-Mp @('x', (Join-Path $root 'notes.txt'))
        $t = Item $app '##msg_text'
        Check 'not an archive: one alert' ($t -ne $null) $t.label
        Shot $app 'notarchive'
        Invoke-AutoClick $app '##msg_ok'
        $code = Wait-Exit $app
        Check 'not an archive: exit 2' ($code -eq 2) "code=$code"
    }

    # ---- 4. the queue: conflict prompt, a second invocation queued (n/N), Cancel drops the rest -> 255 --------
    if ($Only -eq '' -or $Only -eq 'queue') {
        $here = Join-Path $root 'q'
        New-Item -ItemType Directory -Force $here | Out-Null
        Copy-Item $a7z (Join-Path $here 'a.7z'); Copy-Item $b7z (Join-Path $here 'b.7z')
        $qa = Join-Path $here 'a.7z'; $qb = Join-Path $here 'b.7z'
        $app = Start-Mp @('x', $qa, '--here')
        $code = Wait-Exit $app
        Check 'queue: first --here run exit 0' ($code -eq 0) "code=$code"
        $app = Start-Mp @('x', $qa, '--here')
        $null = Item $app '##conflict_overwrite'
        # a second invocation in the same session: forwarded, queued behind the running job
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = "x `"$qb`" --here"
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['MAKEKIT_DISPLAY'] = '\\.\DISPLAY1'
        foreach ($k in $envs.Keys) { $psi.EnvironmentVariables[$k] = [string]$envs[$k] }
        $p2 = [System.Diagnostics.Process]::Start($psi)
        [void]$pids.Add($p2.Id)
        $fwd = $p2.WaitForExit(10000)
        Check 'queue: second process forwards and exits 0' ($fwd -and $p2.ExitCode -eq 0) "exit=$(if ($fwd) { $p2.ExitCode } else { 'running' })"
        Shot $app 'conflict'
        Invoke-AutoClick $app '##conflict_all'
        Invoke-AutoClick $app '##conflict_skip'
        # job 2/2 meets one.txt again -> conflict; its progress window is titled n/N
        $null = Item $app '##conflict_cancel'
        $wins = @(Get-AutoItems $app -Windows | ForEach-Object { $_.name })
        $q = @($wins | Where-Object { $_ -like '*2/2*' })
        Check 'queue: second invocation queued, progress titled 2/2' ($q.Count -gt 0) ($wins -join ' | ')
        Shot $app 'queue'
        Invoke-AutoClick $app '##conflict_cancel'
        if (-not $app.Process.WaitForExit(5000)) {
            $null = Invoke-AutoFrames $app 3
            Write-Host ('after cancel: ' + ((@(Get-AutoItems $app -Windows | ForEach-Object { $_.name })) -join ' | '))
            Write-Host ('items: ' + ((@(Get-AutoItems $app | ForEach-Object { $_.label })) -join ' | '))
            Shot $app 'queue-after-cancel'
        }
        $code = Wait-Exit $app
        Check 'queue: cancel = exit 255' ($code -eq 255) "code=$code"
    }

    # ---- 5. compress dialog (a <paths>): password mismatch, bad volume size, advanced, profile, Create -------
    if ($Only -eq '' -or $Only -eq 'compress') {
        $app = Start-Mp @('a', (Join-Path $src 'one.txt'), (Join-Path $src 'dir1'))
        $null = Item $app '##compress_create'
        Invoke-AutoClick $app '##compress_password'; Invoke-AutoType $app 'abc'
        Invoke-AutoClick $app '##compress_confirm'; Invoke-AutoType $app 'abd'
        Invoke-AutoClick $app '##compress_create'
        $t = Item $app '##msg_text'
        Check 'compress: passwords differ = its own alert' ($t -ne $null) $t.label
        Shot $app 'compress-pwdiff'
        Invoke-AutoClick $app '##msg_ok'
        Invoke-AutoClick $app '##compress_show_password'
        $c = Item $app '##compress_confirm'
        Check 'compress: Show password disables Confirm' ([bool]$c.disabled)
        Invoke-AutoClick $app '##compress_volumes'; Invoke-AutoType $app '10k'
        $null = Item $app '##compress_volume_error'
        $cr = Item $app '##compress_create'
        Check 'compress: volume < 64 KB flagged, Create disabled' ([bool]$cr.disabled)
        Invoke-AutoClick $app '##compress_volumes'; Invoke-AutoKey $app 'ctrl+A'; Invoke-AutoKey $app 'Backspace'
        Invoke-AutoClick $app '##compress_advanced'
        $null = Item $app '##compress_method'
        Invoke-AutoClick $app '##compress_level'; Invoke-AutoClick $app '##compress_level_5'
        Invoke-AutoClick $app '##compress_method'
        $null = Item $app '##compress_method_1'
        Shot $app 'compress-method-list'
        Invoke-AutoClick $app '##compress_method_1'
        $lv = Item $app '##compress_level'
        Check 'compress: drop-down picks a level' ($lv.label -notlike '*##compress_level_*') $lv.label
        Shot $app 'compress'
        # save a profile (default + in menu)
        Invoke-AutoClick $app '##compress_save_profile'
        $null = Item $app '##name_input'
        Invoke-AutoClick $app '##name_input'; Invoke-AutoType $app 'G2test'
        Invoke-AutoClick $app '##name_default'
        Shot $app 'name-profile'
        Invoke-AutoClick $app '##name_ok'
        $null = Invoke-AutoFrames $app 3
        Invoke-AutoClick $app '##compress_create'
        $code = Wait-Exit $app 30000
        $out = Join-Path $src 'src.7z' # named after the inputs' shared folder, inside it (Engine.DefaultArchivePath)
        Check 'compress: exit 0, src.7z made' (($code -eq 0) -and (Test-Path $out)) "code=$code"
        if (Test-Path $out) {
            $tc = Run-7z @('t', '-pabc', $out)
            Check 'compress: 7z.exe tests it with the password' ($tc -eq 0) "7z t=$tc"
        }
        $js = Get-Content -Raw (Join-Path $root 'settings.json') | ConvertFrom-Json
        $prof = @($js.Profiles | Where-Object { $_.Name -eq 'G2test' })
        Check 'compress: profile saved as default' (($prof.Count -eq 1) -and $prof[0].IsDefault)
        Check 'compress: remembered Ultra + LZMA' (($js.Level -eq 'Ultra') -and ($js.Method -eq 'Lzma')) "Level=$($js.Level) Method=$($js.Method)"
    }

    # ---- 5b. a --quick (Explorer's "Add to name.7z"): gathered 400 ms, no dialog, progress only ---------------
    if ($Only -eq '' -or $Only -eq 'quick') {
        $qdir = Join-Path $root 'quick'
        New-Item -ItemType Directory -Force $qdir | Out-Null
        Copy-Item (Join-Path $src 'one.txt') (Join-Path $qdir 'one.txt')
        $app = Start-Mp @('a', '--quick', (Join-Path $qdir 'one.txt'))
        $code = Wait-Exit $app 30000
        Check 'quick: one.7z made without a dialog, exit 0' (($code -eq 0) -and (Test-Path (Join-Path $qdir 'one.7z'))) "code=$code"
        $app = Start-Mp @('a', '--quick', (Join-Path $qdir 'one.txt'))
        $t = Item $app '##msg_text'
        Shot $app 'quick-overwrite'
        Invoke-AutoClick $app '##msg_no'
        $code = Wait-Exit $app
        Check 'quick: overwrite question, No = exit 1' ($code -eq 1) "code=$code; $($t.label)"
    }

    # ---- 6. settings (standalone): profile list, In menu, OK writes settings.json --------------------------
    if ($Only -eq '' -or $Only -eq 'settings') {
        $app = Start-Mp @('--settings')
        $null = Item $app '##settings_ok'
        $p0 = @(Get-AutoItems $app | Where-Object { $_.label -like '*##settings_p0' })
        Check 'settings: profile listed' ($p0.Count -eq 1) $(if ($p0.Count) { $p0[0].label } else { '' })
        if ($p0.Count) { Invoke-AutoClick $app '##settings_p0'; Invoke-AutoClick $app '##settings_in_menu' }
        Shot $app 'settings'
        Invoke-AutoClick $app '##settings_ok'
        $code = Wait-Exit $app
        Check 'settings: exit 0' ($code -eq 0) "code=$code"
        $js = Get-Content -Raw (Join-Path $root 'settings.json') | ConvertFrom-Json
        $prof = @($js.Profiles | Where-Object { $_.Name -eq 'G2test' })
        Check 'settings: In menu saved' (($prof.Count -eq 1) -and $prof[0].InMenu)
    }

    # ---- 7. associations (standalone) under the injected hive ----------------------------------------------
    if ($Only -eq '' -or $Only -eq 'assoc') {
        $app = Start-Mp @('--assoc')
        $null = Item $app '##assoc_ok'
        Shot $app 'assoc'
        Invoke-AutoClick $app '##assoc_none'
        Invoke-AutoClick $app '##assoc_7z'
        Invoke-AutoClick $app '##assoc_ok'
        $code = Wait-Exit $app
        Check 'assoc: exit 0' ($code -eq 0) "code=$code"
        $v = (Get-ItemProperty -LiteralPath "HKCU:\$hiveKey\Software\Classes\.7z" -ErrorAction SilentlyContinue).'(default)'
        Check 'assoc: .7z registered under the test hive only' ($v -eq 'MakePack.Archive') "value=$v"
    }

    # ---- 8. convert (dispatch convert <zip>) -> summary --------------------------------------------------------
    if ($Only -eq '' -or $Only -eq 'convert') {
        $app = Start-Mp @('convert', $czip)
        $null = Item $app '##convert_go'
        Shot $app 'convert'
        Invoke-AutoClick $app '##convert_go'
        $t = Item $app '##msg_text'
        Shot $app 'convert-summary'
        Invoke-AutoClick $app '##msg_ok'
        $code = Wait-Exit $app
        Check 'convert: exit 0, c.7z made' (($code -eq 0) -and (Test-Path (Join-Path $root 'c.7z'))) "code=$code; $($t.label)"
    }

    # ---- 9. main-window dialogs: info, test, find + viewer, favorites, settings --------------------------------
    if ($Only -eq '' -or $Only -eq 'main') {
        $app = Start-Mp @($a7z)
        $null = Item $app '###mcommands'
        $null = Invoke-AutoFrames $app 5
        Invoke-AutoClick $app '###mtools'; Invoke-AutoClick $app '###m_info'
        $null = Item $app '##info_close'
        $k = @(Get-AutoItems $app | Where-Object { $_.label -like '*##info_v*' })
        Check 'info: rows shown' ($k.Count -gt 3) "$($k.Count) rows"
        Shot $app 'info'
        Invoke-AutoClick $app '##info_close'
        Invoke-AutoClick $app '###mcommands'; Invoke-AutoClick $app '###m_test'
        $t = Item $app '##msg_text'
        Check 'test: result alert' ($t -ne $null) $t.label
        Shot $app 'test'
        Invoke-AutoClick $app '##msg_ok'
        Invoke-AutoClick $app '###mtools'; Invoke-AutoClick $app '###m_find'
        $null = Item $app '##find_go'
        Invoke-AutoClick $app '##find_text'; Invoke-AutoType $app 'needle'
        Invoke-AutoClick $app '##find_go'
        $r0 = Item $app '##find_r0'
        Check 'find: text found inside the archive' ($r0 -ne $null) $r0.label
        Shot $app 'find'
        Invoke-AutoClick $app '##find_r0'
        Invoke-AutoClick $app '##find_view'
        $null = Item $app '##viewer_text'
        $vw = @(Get-AutoItems $app -Windows | Where-Object { $_.name -like '*###viewer*' })
        Check 'viewer: opened on the found entry' ($vw.Count -gt 0) $(if ($vw.Count) { $vw[0].name } else { '' })
        Invoke-AutoClick $app '##viewer_text'
        Invoke-AutoKey $app 'ctrl+F'
        $null = Item $app '##viewer_find_text'
        Invoke-AutoClick $app '##viewer_find_text'; Invoke-AutoType $app 'zzz-missing'
        Invoke-AutoClick $app '##viewer_find_go'
        $nf = Item $app '##msg_text'
        Check 'viewer: not found = info alert' ($nf -ne $null) $nf.label
        Invoke-AutoClick $app '##msg_ok'
        Shot $app 'viewer'
        Invoke-AutoClick $app '##viewer_text'
        Invoke-AutoKey $app 'Escape'
        Invoke-AutoClick $app '##find_close'
        Invoke-AutoClick $app '###mfavorites'; Invoke-AutoClick $app '###m_orgfav'
        $null = Item $app '##favorites_ok'
        Shot $app 'favorites'
        Invoke-AutoClick $app '##favorites_cancel'
        Invoke-AutoClick $app '###moptions'; Invoke-AutoClick $app '###m_settings'
        $null = Item $app '##settings_cancel'
        Shot $app 'settings-main'
        Invoke-AutoClick $app '##settings_cancel'
        $code = Stop-AutoApp $app
        Check 'main: quit' ($code -eq 0) "code=$code"
    }
} catch {
    Check 'script' $false ($_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
    foreach ($id in $pids) { try { $p = Get-Process -Id $id -ErrorAction Stop; if ($p.Path -eq $Exe) { Stop-Process -Id $id -Force } } catch { } }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "HKCU:\$hiveKey" -Recurse -Force -ErrorAction SilentlyContinue
}
$bad = @($results | Where-Object { -not $_.Ok })
Write-Host ('{0} checks, {1} failed; sandbox removed: {2}; test key removed: {3}' -f $results.Count, $bad.Count, (-not (Test-Path $root)), (-not (Test-Path "HKCU:\$hiveKey")))
if ($bad.Count -eq 0) { Write-Host 'GUI DIALOGS OK'; exit 0 } else { exit 1 }
