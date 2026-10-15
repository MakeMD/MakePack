# One-time: self-signed code-signing cert CN=MakeMD for the Win11 shell package (shell\package).
# Writes shell\cert\MakePack.pfx (private key, gitignored) + shell\cert\MakePack.cer (public, shipped in the installer)
# and appends the random PFX password to .env as MAKEPACK_PFX_PASSWORD. Nothing is left in any certificate store.
# ponytail: self-signed, so the installer has to trust the .cer (one UAC). A real code-signing cert drops that step - swap the pfx.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dir = Join-Path $root 'shell\cert'
$pfx = Join-Path $dir 'MakePack.pfx'
$envFile = Join-Path $root '.env'
if (Test-Path $pfx) { throw "$pfx already exists. Delete it and MAKEPACK_PFX_PASSWORD in .env to make a new one." }
New-Item -ItemType Directory -Force $dir | Out-Null

$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$plain = -join ($bytes | ForEach-Object { $_.ToString('x2') })   # hex: nothing to quote anywhere
$secure = ConvertTo-SecureString $plain -AsPlainText -Force

# Subject must equal Identity/@Publisher in AppxManifest.xml. EKU 1.3.6.1.5.5.7.3.3 = code signing; 2.5.29.19 = not a CA.
$cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=MakeMD' -KeyUsage DigitalSignature `
    -FriendlyName 'MakePack shell package' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
try {
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secure | Out-Null
    Export-Certificate -Cert $cert -FilePath (Join-Path $dir 'MakePack.cer') | Out-Null
} finally {
    Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey
}

$sep = ''
if ((Test-Path $envFile) -and -not ((Get-Content $envFile -Raw) -match "`n$")) { $sep = "`r`n" }
Add-Content -Path $envFile -Value "${sep}MAKEPACK_PFX_PASSWORD=$plain" -Encoding ASCII
Write-Host "OK  $pfx  (thumbprint $($cert.Thumbprint), valid to $($cert.NotAfter.ToString('yyyy-MM-dd'))); password appended to .env"
