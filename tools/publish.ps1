# MakePack release: tools\build.ps1 (signed shell package) -> dist\SHA256SUMS.txt -> the `gh release create` command.
# Dry run by default: builds, hashes and PRINTS the command. -Publish also runs it (gh must be logged in).
# Release assets = what MakeUpdate.exe expects (MakeKit docs K11): MakePack-Setup-X.Y.Z.exe + SHA256SUMS.txt
# ("<sha256>  <file>" lines), tag vX.Y.Z, not a draft / pre-release. X.Y.Z = build.zig.zon's .version.
# MakePack has no portable zip: the setup is the only binary asset.
#   powershell -ExecutionPolicy Bypass -File tools\publish.ps1 [-Publish] [-NotesFile notes.md]
# Pure ASCII (PS 5.1).
param([switch]$Publish, [string]$NotesFile = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = [regex]::Match((Get-Content (Join-Path $root 'build.zig.zon') -Raw), '\.version\s*=\s*"([^"]+)"').Groups[1].Value
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "build.zig.zon .version '$version' is not x.y.z" }

# A release always ships the signed Win11 menu package: no PFX or no password = stop here (never a silent -NoSign).
$pfx = Join-Path $root 'shell\cert\MakePack.pfx'
$pw = Get-Content (Join-Path $root '.env') -ErrorAction SilentlyContinue | Where-Object { $_ -match '^MAKEPACK_PFX_PASSWORD=.' }
if (-not (Test-Path $pfx) -or -not $pw) {
    Write-Host "Cannot publish: signing needs $pfx (tools\new_cert.ps1) and MAKEPACK_PFX_PASSWORD in .env." -ForegroundColor Red
    exit 1
}

& (Join-Path $PSScriptRoot 'build.ps1')   # throws on any failure; checks -Version = build.zig.zon

$name = "MakePack-Setup-$version.exe"
$setup = Join-Path $root "dist\$name"
$sums = Join-Path $root 'dist\SHA256SUMS.txt'
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($sums, "$hash  $name`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "SHA256SUMS.txt: $hash  $name"

$gh = @('release', 'create', "v$version", $setup, $sums, '--repo', 'MakeMD/MakePack', '--title', "MakePack $version")
$gh += $(if ($NotesFile) { @('--notes-file', (Resolve-Path -LiteralPath $NotesFile).Path) } else { @('--generate-notes') })
$shown = ($gh | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } }) -join ' '
if (-not $Publish) {
    Write-Host "Dry run. To publish:" -ForegroundColor Yellow
    Write-Host "gh $shown"
    return
}
& gh @gh
if ($LASTEXITCODE) { throw "gh release create failed (exit $LASTEXITCODE)" }
Write-Host "Published v$version" -ForegroundColor Green
