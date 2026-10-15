# BOM pass -> single-file publish -> self-test. This is what the installer consumes.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'bom.ps1') | Out-Null
dotnet publish (Join-Path $root 'src\MakePack') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o (Join-Path $root 'dist\publish')
if ($LASTEXITCODE -ne 0) { throw "publish failed ($LASTEXITCODE)" }
$exe = Join-Path $root 'dist\publish\MakePack.exe'
if (-not (Test-Path (Join-Path $root 'dist\publish\7z.dll'))) { throw '7z.dll missing next to the exe' }
& cmd /c "`"$exe`" --selftest"
if ($LASTEXITCODE -ne 0) { throw "self-test failed ($LASTEXITCODE)" }
Write-Output "published: $exe"
