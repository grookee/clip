# build_msix.ps1 - stage the kirk payload and pack a signed MSIX installer.
#
# Usage (local, unsigned pack to validate the manifest):
#   powershell -ExecutionPolicy Bypass -File scripts\build_msix.ps1
# Usage (test-signed, sideloadable after trusting the .cer):
#   powershell -ExecutionPolicy Bypass -File scripts\build_msix.ps1 -SignThumbprint <thumbprint>
# Usage (release cert):
#   powershell -ExecutionPolicy Bypass -File scripts\build_msix.ps1 -Version 0.2.0.0 -PfxPath .\kirk.pfx -PfxPassword $env:PFX_PASSWORD
#
# Inputs:
#   build/ must already exist (run scripts\build.ps1 first).
#   Tile art is generated at pack time (gruvbox bg + orange K), so no
#   binary assets are committed to the repo.
# Signing:
#   The manifest Publisher MUST equal the signing cert subject, hence both
#   default to CN=kirk. Pass -Publisher + a matching cert for real releases.

param(
  [string]$OutDir = "dist",
  [string]$BuildDir = "build",
  [string]$Version = "",
  [string]$Publisher = "CN=kirk",
  [string]$SignThumbprint = "",
  [string]$PfxPath = "",
  [string]$PfxPassword = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Stage = Join-Path (Join-Path $Root $OutDir) "msix_stage"
$Assets = Join-Path $Stage "Assets"

# 1. Version: explicit -Version wins, else shard.yml x.y.z becomes x.y.z.0.
if (-not $Version) {
  $m = Select-String -Path (Join-Path $Root "shard.yml") -Pattern "^version:\s*(.+)$" |
    Select-Object -First 1
  if (-not $m) { throw "could not read version from shard.yml (pass -Version)" }
  $Version = $m.Matches[0].Groups[1].Value.Trim() + ".0"
}
if ($Version -notmatch "^\d+\.\d+\.\d+\.\d+$") { throw "Version must be 4-part numeric (got $Version)" }

# 2. Stage the runtime: exe + shim + ffmpeg, all staged DLLs (Crystal runtime
#    + FFmpeg shared libs). ffplay/ffprobe, symbols and logs stay out.
$binDir = Join-Path $Root $BuildDir
foreach ($f in @("kirk.exe", "shim.dll", "ffmpeg.exe")) {
  if (-not (Test-Path (Join-Path $binDir $f))) { throw "missing payload file: $binDir\$f (run scripts\build.ps1 first)" }
}
New-Item -ItemType Directory -Force -Path $Assets | Out-Null
Copy-Item (Join-Path $binDir "kirk.exe") $Stage -Force
Copy-Item (Join-Path $binDir "shim.dll") $Stage -Force
Copy-Item (Join-Path $binDir "ffmpeg.exe") $Stage -Force
Copy-Item (Join-Path $binDir "*.dll") $Stage -Force

# 3. Tile art, generated so the repo stays binary-free.
Add-Type -AssemblyName System.Drawing
function New-Tile([int]$size, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.Clear([System.Drawing.Color]::FromArgb(0x1d, 0x20, 0x21)) # gruvbox bg0_h
      $font = New-Object System.Drawing.Font("Segoe UI", ($size * 0.55), [System.Drawing.FontStyle]::Bold)
      try {
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xfe, 0x80, 0x19)) # gruvbox orange
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString("K", $font, $brush, [System.Drawing.RectangleF]::new(0, 0, $size, $size), $sf)
      } finally { $brush.Dispose() }
    } finally { $g.Dispose(); $font.Dispose() }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $bmp.Dispose() }
}
New-Tile 50 (Join-Path $Assets "StoreLogo.png")
New-Tile 44 (Join-Path $Assets "Square44x44Logo.png")
New-Tile 150 (Join-Path $Assets "Square150x150Logo.png")

# 4. Manifest: full-trust desktop-bridge app (no UWP sandbox).
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:mp="http://schemas.microsoft.com/appx/2014/phone/manifest" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap">
  <Identity Name="kirk" Publisher="$Publisher" Version="$Version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>kirk - Keep It Recorded</DisplayName>
    <PublisherDisplayName>kirk</PublisherDisplayName>
    <Description>Privacy-first gameplay clipping: replay buffer, hotkeys and local voice commands.</Description>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
  <Applications>
    <Application Id="kirk" Executable="kirk.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="kirk" Description="Keep It Recorded, Kirk" BackgroundColor="#1d2021" Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png" />
    </Application>
  </Applications>
</Package>
"@
$manifestPath = Join-Path $Stage "AppxManifest.xml"
$manifest | Set-Content -Path $manifestPath -Encoding UTF8

# 5. Pack with the newest Windows SDK on the machine.
$kits = "C:\Program Files (x86)\Windows Kits\10\bin"
function Find-SdkTool([string]$name) {
  $tool = Get-ChildItem $kits -Recurse -Filter $name -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\x64\\" } |
    Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $tool) { throw "$name not found under $kits (install the Windows SDK)" }
  return $tool.FullName
}
$makeappx = Find-SdkTool "makeappx.exe"
$msix = Join-Path (Join-Path $Root $OutDir) "kirk-$Version.msix"
& $makeappx pack /o /d $Stage /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed" }
Write-Host "Packed: $msix"

# 6. Optional signing (unsigned .msix installs nowhere; test-signed installs
#    after trusting the emitted .cer; a real cert removes the warning).
if ($PfxPath) {
  $sec = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
  $cert = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation "Cert:\CurrentUser\My" -Password $sec
  $SignThumbprint = $cert.Thumbprint
}
if ($SignThumbprint) {
  $signtool = Find-SdkTool "signtool.exe"
  & $signtool sign /fd SHA256 /sha1 $SignThumbprint $msix | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "signtool failed" }
  $cer = $msix -replace "\.msix$", ".cer"
  $cert = Get-ChildItem "Cert:\CurrentUser\My\$SignThumbprint"
  Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
  Write-Host "Signed: $msix"
  Write-Host "Trust cert for sideloading: $cer"
}
