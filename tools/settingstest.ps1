# Live GUI check of the settings store over MakeKit automation: remembered options, save on Create, the Settings
# dialog from the main window, the Advanced block per format.
# Usage: tools\settingstest.ps1 [-Exe <path>] [-Shot <file.png>] [-Screen <n>]. Pure ASCII (PS 5.1).
# Sandbox: MAKEPACK_SETTINGS in a temp folder (the user's settings.json is never read or written), private
# MAKEPACK_INSTANCE, MAKEPACK_REGROOT=HKCU\Software\MakePackTest-<random> (deleted), MAKEKIT_AUTOMATION=1 (no real
# input), windows on \\.\DISPLAY<Screen>; kills only the processes it started.
param([string]$Exe = "$PSScriptRoot\..\zig-out\bin\MakePack.exe", [string]$Shot = "", [ValidateRange(1, 9)][int]$Screen = 1)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
Add-Type -AssemblyName System.Drawing

$rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $env:TEMP ('makepack-test-' + $rand)
$outDir = Join-Path $work 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$src = Join-Path $work 'data.txt'
Set-Content $src ('hello ' * 1000)
$cfg = Join-Path $work 'settings.json'
$reg = "Software\MakePackTest-$rand"
$envs = @{ MAKEPACK_INSTANCE = "MakePack-settingstest-$rand"; MAKEPACK_SETTINGS = $cfg; MAKEPACK_REGROOT = $reg
           MAKEKIT_DISPLAY = "\\.\DISPLAY$Screen" }
$apps = New-Object System.Collections.ArrayList

function Start-Mp([string[]]$A) { $app = Start-AutoApp -Exe $Exe -Args $A -Env $envs; [void]$apps.Add($app); $app }
function Label($app, [string]$id) {
    $it = @(Get-AutoItems $app | Where-Object { $_.label.EndsWith($id) }) | Select-Object -First 1
    if (-not $it) { throw "no $id on screen" }
    $it
}
function Text-Of($it) { $l = $it.label; $l.Substring(0, $l.IndexOf('##')) }
function Wait-Exit($app, [int]$ms = 30000) { if (-not $app.Process.WaitForExit($ms)) { throw 'the app did not exit' }; $app.Process.ExitCode }
function Json([string]$s) { [IO.File]::WriteAllText($cfg, $s) }
function Esc([string]$p) { $p -replace '\\', '\\' }

try {
    # 1. Seeded settings are picked up by a fresh process.
    Json ('{ "Format": "Zip", "Level": "Ultra", "ArchiveFolder": "' + (Esc $outDir) + '" }')
    $app = Start-Mp @('a', $src)
    $null = Wait-AutoItem $app '##compress_create' 15000
    $fmt = Text-Of (Label $app '##compress_format'); $lvl = Text-Of (Label $app '##compress_level')
    Write-Host "format=$fmt level=$lvl"
    if ($fmt -ne 'zip') { throw "format not restored: $fmt" }

    # 2. Create saves the choice: the process already holds the settings in memory, so the file must come back.
    # The archive path box is not readable over automation: the archive folder shows in where data.zip lands.
    Remove-Item $cfg
    Invoke-AutoClick $app '##compress_create'
    $null = Wait-Exit $app
    if (-not (Test-Path (Join-Path $outDir 'data.zip'))) { throw 'data.zip was not created in the archive folder' }
    $saved = Get-Content $cfg -Raw
    Write-Host "saved: $($saved -replace '\s+', ' ')"
    if ($saved -notmatch '"Format": "Zip"' -or $saved -notmatch '"Level": "Ultra"') { throw 'choice not saved after Create' }

    # 3. Options > Settings on the main window opens the dialog; its OK writes back the folder it loaded.
    $app = Start-Mp @()
    $null = Wait-AutoItem $app '###moptions' 15000
    Invoke-AutoClick $app '###moptions'
    Invoke-AutoClick $app '###m_settings'
    $null = Wait-AutoItem $app '##settings_ok' 10000
    $win = @(Get-AutoItems $app -Windows | Where-Object { $_.name -like '*###settings*' }) | Select-Object -First 1
    if (-not $win) { throw 'settings dialog did not open' }
    Write-Host "settings dialog '$($win.name)'"
    if ($Shot) { $bmp = Save-AutoScreenshot $app ($Shot + '.bmp'); $img = [System.Drawing.Image]::FromFile($bmp); try { $img.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }; Remove-Item $bmp }
    Invoke-AutoClick $app '##settings_ok'
    $null = Invoke-AutoFrames $app 3
    $folder = (Get-Content $cfg -Raw | ConvertFrom-Json).ArchiveFolder
    if ($folder -ne $outDir) { throw "settings dialog kept '$folder'" }
    $null = Stop-AutoApp $app

    # 4. Advanced block: remembered values come back, only what the format takes is enabled, and Create uses them.
    $outDir2 = Join-Path $work 'out2'
    New-Item -ItemType Directory -Force $outDir2 | Out-Null
    function Open-Advanced([string]$format) {
        Json ('{ "Format": "' + $format + '", "Level": "Normal", "ShowAdvanced": true, "Method": "Lzma", "Dictionary": 4194304,' +
              ' "Solid": "off", "Threads": 1, "Filter": "off", "ArchiveFolder": "' + (Esc $outDir2) + '" }')
        $a = Start-Mp @('a', $src)
        $null = Wait-AutoItem $a '##compress_create' 15000
        $state = (@('method', 'dictionary', 'solid', 'threads', 'filter') | ForEach-Object {
            $it = Label $a ('##compress_' + $_)
            (Text-Of $it) + '=' + $(if ($it.disabled) { 'off' } else { 'on' }) }) -join ' | '
        Write-Host "$format -> $state"
        @($a, $state)
    }
    $a, $state = Open-Advanced 'SevenZip'
    if ($state -notmatch '^LZMA=on \| 4 MB=on \| \S+=on \| 1=on \| \S+=on$') { throw "7z advanced block: $state" }
    $null = Stop-AutoApp $a

    $a, $state = Open-Advanced 'Tar'
    if ($state -notmatch '=off \| .*=off \| .*=off \| .*=off \| .*=off$') { throw "tar advanced block: $state" }
    $null = Stop-AutoApp $a

    $a, $state = Open-Advanced 'Zip'
    if ($state -notmatch '^LZMA=on \| 4 MB=on \| \S+=off \| 1=on \| \S+=off$') { throw "zip advanced block: $state" }
    Invoke-AutoClick $a '##compress_create'
    $null = Wait-Exit $a
    $zip = Join-Path $outDir2 'data.zip'
    $method = & (Join-Path $PSScriptRoot '..\third_party\7zip\7z.exe') l -slt $zip | Select-String '^Method = ' | Select-Object -First 1
    Write-Host "created zip: $method"
    if ("$method" -notmatch 'LZMA') { throw "zip was not written with LZMA: $method" }
    'PASS'
}
finally {
    foreach ($x in $apps) { if (-not $x.Process.HasExited) { Stop-Process -Id $x.Process.Id -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Milliseconds 300
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "HKCU:\$reg" -Recurse -Force -ErrorAction SilentlyContinue
}
