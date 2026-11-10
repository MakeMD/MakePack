# MakePack build: icon -> zig build (ReleaseSafe) -> Win11 shell extension -> Inno Setup. Pure ASCII (PS 5.1).
# Output: dist\app (what the installer ships), dist\shell, dist\MakePack-Setup-<version>.exe.
# -NoSign: the shell package stays unsigned (no PFX / .env needed; for a dry run - such a package does not install).
# ponytail: no msbuild targets, no CI matrix, exe not signed (only the shell package is) - one script, native calls.
param([string]$Version = "2.0.0", [switch]$SkipIcon, [switch]$NoSign)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$zig = Join-Path $env:LOCALAPPDATA 'Programs\zig\0.17.1\zig.exe'
if (-not (Test-Path $zig)) { throw "Zig 0.17.1 not found at $zig" }

# 1. Icon (pipeline owned by someone else - a failure here is not fatal, the committed .ico still works).
$iconScript = Join-Path $root 'icon\build_icon.py'
if ((Test-Path $iconScript) -and (-not $SkipIcon)) {
    Write-Host "[1/4] icon" -ForegroundColor Cyan
    try {
        python $iconScript
        if ($LASTEXITCODE) { throw "python exited $LASTEXITCODE" }
    } catch {
        Write-Warning "icon build failed ($_); keeping existing icon\makepack.ico"
    }
} else {
    Write-Host "[1/4] icon: skipped" -ForegroundColor DarkGray
}

# 2. MakePack.exe + 7z.dll + 7z.sfx, staged into dist\app (no .pdb; the shell DLL comes from step 3).
Write-Host "[2/4] zig build -Doptimize=ReleaseSafe ($Version)" -ForegroundColor Cyan
& $zig build -Doptimize=ReleaseSafe
if ($LASTEXITCODE) { throw "zig build failed (exit $LASTEXITCODE)" }
$app = Join-Path $root 'dist\app'
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
New-Item -ItemType Directory -Force $app | Out-Null
foreach ($f in 'MakePack.exe', '7z.dll', '7z.sfx') { Copy-Item (Join-Path $root "zig-out\bin\$f") $app }

# 3. Win11 top-level context menu: DLL + sparse package into dist\shell (signing needs tools\new_cert.ps1 once).
Write-Host "[3/4] shell extension" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build_shell.ps1') -Version $Version -NoSign:$NoSign

# 4. Compile the installer.
Write-Host "[4/4] ISCC" -ForegroundColor Cyan
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
