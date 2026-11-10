# Win11 top-level context menu: zig build (DLL + test harness) -> harness -> makeappx -> signtool.
# Output: dist\shell\MakePackShell.dll + dist\shell\MakePackShell.msix. Needs tools\new_cert.ps1 run once.
# -NoSign stops after makeappx (unsigned msix; a machine without the certificate, or a dry run).
# ponytail: does not touch dist\app; build.ps1 calls it between zig build and ISCC.
param([string]$Version = "1.0.0", [switch]$NoSign)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$shell = Join-Path $root 'shell'
$build = Join-Path $shell 'build'
$out = Join-Path $root 'dist\shell'
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { throw "Zig 0.17.1 not found at $zig" }
$kit = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\makeappx.exe" |
    Sort-Object FullName | Select-Object -Last 1 | Split-Path
if (-not $kit) { throw "Windows SDK (makeappx.exe) not found" }
New-Item -ItemType Directory -Force $out | Out-Null

# Package logos, rendered from the app icon once (committed; delete shell\package\Assets to redo).
$assets = Join-Path $shell 'package\Assets'
if (-not (Test-Path (Join-Path $assets 'StoreLogo.png'))) {
    New-Item -ItemType Directory -Force $assets | Out-Null
    $py = "import sys; sys.path.insert(0, r'$root\icon'); from build_icon import render; " +
          "f = render(r'$root\icon\makepack.svg', [150, 50, 44]); " +
          "[f[s].save(rf'$assets\{n}.png') for s, n in [(150, 'Square150x150Logo'), (50, 'StoreLogo'), (44, 'Square44x44Logo')]]"
    python -c $py
    if ($LASTEXITCODE) { throw "logo render failed (exit $LASTEXITCODE)" }
}

# 1+2. DLL + harness: test-shell builds MakePackShell.dll, harness.exe and fake_makepack.exe and drives the DLL like
# Explorer would (menu states + command lines against the fake MakePack.exe, in a throw-away HKCU key and temp
# folder); `shell` installs the same DLL into zig-out\bin without building MakePack.exe.
Push-Location $root
try {
    & $zig build test-shell shell -Doptimize=ReleaseSafe
    if ($LASTEXITCODE) { throw "zig build test-shell failed (exit $LASTEXITCODE): build error or failed harness check(s)" }
} finally { Pop-Location }
$dll = Join-Path $root 'zig-out\bin\MakePackShell.dll'
Copy-Item $dll $out -Force

# 3. Pack: manifest + logos only (/nv: the exe and DLL live in the external location, not in the package).
$v = [version]$Version
$stage = Join-Path $build 'package'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item (Join-Path $shell 'package') $stage -Recurse
$manifest = Join-Path $stage 'AppxManifest.xml'
$xml = (Get-Content $manifest -Raw) -replace '(<Identity [^>]*Version=")[^"]*"', ('${1}' + "$($v.Major).$($v.Minor).$([math]::Max($v.Build, 0)).0" + '"')
[IO.File]::WriteAllText($manifest, $xml)
$msix = Join-Path $out 'MakePackShell.msix'
& "$kit\makeappx.exe" pack /o /d $stage /p $msix /nv
if ($LASTEXITCODE) { throw "makeappx failed (exit $LASTEXITCODE)" }
if ($NoSign) { Write-Host "OK  $msix (NOT signed)" -ForegroundColor Yellow; return }

# 4. Sign. The password is read from .env here - never a script argument, never printed.
# ponytail: signtool only takes it via /p, so it is visible in signtool's own process command line while it runs.
$pfx = Join-Path $shell 'cert\MakePack.pfx'
$envFile = Join-Path $root '.env'
if (-not (Test-Path $pfx)) { throw "$pfx missing - run tools\new_cert.ps1 once" }
$line = Get-Content $envFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^MAKEPACK_PFX_PASSWORD=' } | Select-Object -Last 1
if (-not $line) { throw "MAKEPACK_PFX_PASSWORD missing in .env" }
& "$kit\signtool.exe" sign /q /fd SHA256 /f $pfx /p ($line -replace '^MAKEPACK_PFX_PASSWORD=', '') $msix
if ($LASTEXITCODE) { throw "signtool failed (exit $LASTEXITCODE)" }
Write-Host "OK  $msix" -ForegroundColor Green
