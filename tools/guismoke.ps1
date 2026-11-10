# GUI smoke of the main window over MakeKit automation: start MakePack (-Exe, default zig-out\bin\MakePack.exe) with
# -Arg, then for each -Steps entry send its keys through the automation pipe and save <Out>_<n>.png (the window's
# back buffer) and <Out>_<n>.txt (window names + item labels). Quits it at the end.
# Keys: space-separated chords, '' = none. A chord is [ctrl+][alt+][shift+]key, optional *count:
#   'ctrl+t'   'down*5 enter'   'alt+left'   'f2'   'num+'
# Nothing goes through SendInput: the app runs with MAKEKIT_AUTOMATION=1 (it ignores the real mouse and keyboard)
# on \\.\DISPLAY<Screen>, so it is safe while the user works. Do not use Enter on files here: it opens them in the
# user's apps. Sandbox: private MAKEPACK_INSTANCE, MAKEPACK_SETTINGS=<Out>_settings.json, MAKEPACK_REGROOT=a
# throw-away HKCU\Software\MakePackTest-<random> (deleted at the end).
# Usage: tools\guismoke.ps1 -Out C:\tmp\mp -Arg C:\some\folder -Steps '', 'ctrl+t', 'down*3'
# Pure ASCII (PS 5.1).
param([Parameter(Mandatory)][string]$Out, [string]$Arg = '', [string[]]$Steps = @(''), [string]$Exe = '',
      [ValidateRange(1, 9)][int]$Screen = 1, [int]$WaitMs = 1200)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
Add-Type -AssemblyName System.Drawing

# Old SendInput names -> ImGuiKey names (the automation 'key' command).
$names = @{ enter = 'Enter'; esc = 'Escape'; back = 'Backspace'; tab = 'Tab'; space = 'Space'; del = 'Delete'; ins = 'Insert'
            home = 'Home'; end = 'End'; pgup = 'PageUp'; pgdn = 'PageDown'; left = 'LeftArrow'; up = 'UpArrow'
            right = 'RightArrow'; down = 'DownArrow'; 'num+' = 'KeypadAdd'; 'num-' = 'KeypadSubtract'
            'num*' = 'KeypadMultiply'; backslash = 'Backslash' }
function Chord([string]$c) {
    $parts = $c.ToLowerInvariant() -split '\+(?=.)'
    $key = $parts[-1]
    if ($names.ContainsKey($key)) { $key = $names[$key] } elseif ($key -match '^f\d+$' -or $key.Length -eq 1) { $key = $key.ToUpperInvariant() }
    else { throw "unknown key '$key'" }
    (@($parts | Select-Object -First ($parts.Count - 1)) + $key) -join '+'
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'zig-out\bin\MakePack.exe' }
$rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
$reg = "Software\MakePackTest-$rand"
$envs = @{ MAKEPACK_INSTANCE = "MakePack-guismoke-$rand"; MAKEPACK_SETTINGS = "$Out`_settings.json"; MAKEPACK_REGROOT = $reg
           MAKEKIT_DISPLAY = "\\.\DISPLAY$Screen" }
$app = Start-AutoApp -Exe $Exe -Args $(if ($Arg) { @($Arg) } else { @() }) -Env $envs
try {
    $null = Wait-AutoItem $app '###status' 15000
    $n = 0
    foreach ($step in $Steps) {
        foreach ($chord in ($step -split ' ' | Where-Object { $_ })) {
            $count = 1
            if ($chord -match '^(.*)\*(\d+)$') { $chord = $Matches[1]; $count = [int]$Matches[2] }
            for ($i = 0; $i -lt $count; $i++) { Invoke-AutoKey $app (Chord $chord); $null = Invoke-AutoFrames $app 2 }
        }
        Start-Sleep -Milliseconds $WaitMs
        $null = Invoke-AutoFrames $app 3
        $bmp = Save-AutoScreenshot $app "$Out`_$n.bmp"
        $img = [System.Drawing.Image]::FromFile($bmp)
        try { $img.Save("$Out`_$n.png", [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
        Remove-Item -LiteralPath $bmp
        $lines = @(Get-AutoItems $app -Windows | ForEach-Object { 'window ' + $_.name }) +
                 @(Get-AutoItems $app | ForEach-Object { '{0}  [{1}{2}{3}]' -f $_.label, $(if ($_.visible) { 'v' } else { '-' }), $(if ($_.disabled) { 'd' } else { '' }), $(if ($_.checked) { 'x' } else { '' }) })
        [IO.File]::WriteAllLines("$Out`_$n.txt", [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "step $n '$step' -> $Out`_$n.png"
        $n++
    }
}
finally {
    $null = Stop-AutoApp $app
    Remove-Item -LiteralPath "HKCU:\$reg" -Recurse -Force -ErrorAction SilentlyContinue
}
