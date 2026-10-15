# Re-saves every C# source as UTF-8 with BOM (csc assumes the ANSI codepage without one).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter *.cs | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
    Write-Output "BOM added: $($_.Name)"
}
