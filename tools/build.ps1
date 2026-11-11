# MakePack build: zig build (ReleaseSafe) -> Win11 shell extension -> Inno Setup. Pure ASCII (PS 5.1).
# App icon: icon\makepack.ico, built by MakeKit\tools\app_icons.py (committed).
# Output: dist\app (what the installer ships), dist\shell, dist\MakePack-Setup-<version>.exe.
# -NoSign: the shell package stays unsigned (no PFX / .env needed; for a dry run - such a package does not install).
# ponytail: no msbuild targets, no CI matrix, exe not signed (only the shell package is) - one script, native calls.
# -Version defaults to build.zig.zon's .version (the one place it is kept) and must match it.
param([string]$Version = '', [switch]$NoSign)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { throw "Zig 0.17.1 not found at $zig" }
$zon = [regex]::Match((Get-Content (Join-Path $root 'build.zig.zon') -Raw), '\.version\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $Version) { $Version = $zon }
if ($Version -ne $zon) { throw "-Version $Version differs from build.zig.zon .version $zon (the exe reports that one)" }

# 1. MakePack.exe + MakeUpdate.exe + 7z.dll + 7z.sfx, staged into dist\app (no .pdb; the shell DLL comes from step 3).
Write-Host "[1/3] zig build -Doptimize=ReleaseSafe ($Version)" -ForegroundColor Cyan
& $zig build -Doptimize=ReleaseSafe
if ($LASTEXITCODE) { throw "zig build failed (exit $LASTEXITCODE)" }
$app = Join-Path $root 'dist\app'
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
New-Item -ItemType Directory -Force $app | Out-Null
foreach ($f in 'MakePack.exe', 'MakeUpdate.exe', '7z.dll', '7z.sfx') { Copy-Item (Join-Path $root "zig-out\bin\$f") $app }

# 2. Win11 top-level context menu: DLL + sparse package into dist\shell (signing needs tools\new_cert.ps1 once).
Write-Host "[2/3] shell extension" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build_shell.ps1') -Version $Version -NoSign:$NoSign

# 3. Compile the installer.
Write-Host "[3/3] ISCC" -ForegroundColor Cyan
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6 (https://jrsoftware.org/isdl.php) into %LOCALAPPDATA%\Programs\Inno Setup 6 or Program Files (x86)\Inno Setup 6."
}
& $iscc "/DMyAppVersion=$Version" "installer\MakePack.iss"
if ($LASTEXITCODE) { throw "ISCC failed (exit $LASTEXITCODE)" }

$setup = Join-Path $root "dist\MakePack-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "expected $setup, not found" }
$mb = [math]::Round((Get-Item $setup).Length / 1MB, 2)
Write-Host "OK  $setup  ($mb MB)$(if ($NoSign) { ' - shell package NOT signed' })" -ForegroundColor Green
