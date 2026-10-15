# MakePack build: icon -> dotnet publish -> Win11 shell extension -> Inno Setup.
# ponytail: no msbuild targets, no CI matrix, exe not signed (only the shell package is) - one script, native calls.
param([string]$Version = "1.0.0", [switch]$SkipIcon)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

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

# 2. Publish self-contained single-file exe next to 7z.dll.
Write-Host "[2/4] dotnet publish $Version" -ForegroundColor Cyan
$publish = Join-Path $root 'dist\publish'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish src\MakePack -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:Version=$Version `
    -o $publish
if ($LASTEXITCODE) { throw "dotnet publish failed (exit $LASTEXITCODE)" }

# 3. Win11 top-level context menu: DLL + signed sparse package into dist\shell (needs tools\new_cert.ps1 once).
Write-Host "[3/4] shell extension" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build_shell.ps1') -Version $Version

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
Write-Host "OK  $setup  ($mb MB)" -ForegroundColor Green
