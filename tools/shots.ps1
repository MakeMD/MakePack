# Theme screenshot tour over MakeKit automation: main window (disk + tree, archive + tree, encrypted archive),
# Favorites menu, Compress, Extract, Settings, Assoc, Info, Viewer, Find, the progress dialog and an error alert
# -> <Out>\<Prefix>-<name>.png (the window's back buffer). Read them after a theme / icon change.
# Sandbox as tools\guismoke.ps1: private MAKEPACK_INSTANCE, MAKEPACK_SETTINGS in the fixture folder,
# MAKEPACK_REGROOT = throw-away HKCU\Software\MakePackTest-<random>, MAKEKIT_AUTOMATION=1 (no SendInput),
# fixtures in %TEMP%\makepack-shots-<random> (removed at the end); only the process it started is stopped.
# Usage: tools\shots.ps1 [-Out zig-out\shots] [-Prefix carbon] [-Screen 1]. Pure ASCII (PS 5.1).
param([string]$Out = "$PSScriptRoot\..\zig-out\shots", [string]$Prefix = 'carbon',
      [string]$Exe = "$PSScriptRoot\..\zig-out\bin\MakePack.exe", [ValidateRange(1, 9)][int]$Screen = 1)

$ErrorActionPreference = 'Stop'
$env:MAKEKIT_NO_UPDATE = '1'   # no update check from any test process (MakeKit K11)
. (Join-Path $PSScriptRoot '..\..\MakeKit\tools\imgui-auto.ps1')
Set-StrictMode -Off
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
$rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
$tmp = Join-Path $env:TEMP "makepack-shots-$rand"
$reg = "Software\MakePackTest-$rand"
$Out = [IO.Path]::GetFullPath($Out)
$null = New-Item -ItemType Directory -Force $Out, "$tmp\payload\docs", "$tmp\big"

# Fixtures: a folder, a plain and a header-readable encrypted 7z of it, 30 MB of letters (slow enough to show progress).
Set-Content "$tmp\payload\readme.txt" ("Carbon Mint theme check.`r`n" * 40) -Encoding ASCII
Set-Content "$tmp\payload\docs\notes.txt" 'notes' -Encoding ASCII
[IO.File]::WriteAllBytes("$tmp\payload\data.bin", [byte[]](0..255))
foreach ($i in 1..10) { [Mp.Gen]::Letters("$tmp\big\blob$i.txt", 3MB, $i) }
Push-Location "$tmp\payload"
try {
    & $SevenZ a "$tmp\plain.7z" * -bso0 -bsp0
    & $SevenZ a -pSecret -mhe=off "$tmp\locked.7z" * -bso0 -bsp0
} finally { Pop-Location }

$envs = @{ MAKEPACK_INSTANCE = "MakePack-shots-$rand"; MAKEPACK_SETTINGS = "$tmp\settings.json"; MAKEPACK_REGROOT = $reg
           MAKEKIT_DISPLAY = "\\.\DISPLAY$Screen" }

function Shot([string]$name) {
    Start-Sleep -Milliseconds 400
    $null = Invoke-AutoFrames $app 4
    $f = Save-AutoScreenshot $app (Join-Path $Out "$Prefix-$name.png") -Png
    Write-Host "shot $f"
}
function Esc { Invoke-AutoKey $app 'Escape'; $null = Invoke-AutoFrames $app 3 }
function Go([string]$path) {
    Invoke-AutoClick $app '##address'
    Invoke-AutoKey $app 'ctrl+A'
    Invoke-AutoType $app $path
    Invoke-AutoKey $app 'Enter'
    $null = Invoke-AutoFrames $app 4
}
function Pick([string]$name) { Invoke-AutoClick $app "$name###r" -At '30'; $null = Invoke-AutoFrames $app 2 }
function Tool([string]$t) { Invoke-AutoClick $app "###tb_$t"; $null = Invoke-AutoFrames $app 3 }

$app = Start-AutoApp -Exe $Exe -Args @($tmp) -Env $envs
try {
    $null = Wait-AutoItem $app '###status' 15000
    Invoke-AutoKey $app 'ctrl+T'                    # folder tree on
    Pick 'plain.7z'
    Shot 'main-disk'
    Invoke-AutoClick $app '###mfavorites'; Shot 'menu-favorites'; Esc

    Go "$tmp\payload"
    Pick 'readme.txt'
    Tool 'add'; $null = Wait-AutoItem $app '##compress_create' 10000; Shot 'compress'; Invoke-AutoClick $app '##compress_cancel'; Esc

    Go "$tmp\plain.7z"
    $null = Wait-AutoItem $app 'readme.txt###r' 10000
    Pick 'readme.txt'
    Shot 'main-archive'
    Shot 'overview' # the main screen, for the user
    Tool 'extract'; Shot 'extract'; Esc
    Tool 'info'; Shot 'info'; Esc
    Tool 'view'; Shot 'viewer'; Esc
    Tool 'find'; Shot 'find'; Esc
    Invoke-AutoKey $app 'ctrl+S'; $null = Invoke-AutoFrames $app 3; Shot 'settings'; Esc
    Invoke-AutoClick $app '###moptions'; Invoke-AutoClick $app '###m_assoc'; Shot 'assoc'; Esc
    Invoke-AutoClick $app '###mhelp'; Invoke-AutoClick $app '###m_about'; Shot 'about'; Esc
    Tool 'delete'; Shot 'confirm'; Esc

    Go "$tmp\locked.7z"
    $null = Wait-AutoItem $app 'readme.txt###r' 10000
    Shot 'main-encrypted'

    Go "$tmp\no such folder\nothing"
    $null = Wait-AutoItem $app '##msg_ok' 10000; Shot 'alert-error'; Invoke-AutoClick $app '##msg_ok'

    Go $tmp
    Pick 'big'
    Tool 'add'; $null = Wait-AutoItem $app '##compress_create' 10000; Invoke-AutoClick $app '##compress_create'
    $null = Wait-AutoItem $app '##progress_cancel' 30000
    Start-Sleep -Seconds 2
    Shot 'progress'
    Invoke-AutoClick $app '##progress_cancel'
    Start-Sleep -Seconds 2
}
finally {
    $null = Stop-AutoApp $app
    Remove-Item -LiteralPath "HKCU:\$reg" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
