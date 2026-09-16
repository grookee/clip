# build.ps1 - full kirk build: shim.dll + kirk.exe (+ manifest).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -NoRelease
#
# Steps:
#   1. scripts\build_shim.ps1  -> build\shim.dll + shim.lib (kirk_* exports)
#   2. crystal build (release) -> build\kirk.exe
#      (Crystal locates shim.lib via the MSVC-style LIB env var, and needs
#      link.exe/cl.exe from vcvars64 on PATH.)
#   3. mt.exe embeds native\kirk.manifest (PerMonitorV2) into kirk.exe.

param(
  [string]$OutDir = "build",
  [switch]$NoRelease
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $Root $OutDir
# Locate vcvars64.bat: $env:VCVARS_PATH wins, then vswhere, then the usual
# 2022 edition paths. GitHub's windows-latest runner ships Enterprise, not
# BuildTools, so a hardcoded path breaks CI.
function Find-Vcvars {
  if ($env:VCVARS_PATH -and (Test-Path $env:VCVARS_PATH)) { return $env:VCVARS_PATH }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path $vswhere) {
    $found = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'VC\Auxiliary\Build\vcvars64.bat' 2>$null |
      Select-Object -First 1
    if ($found -and (Test-Path $found)) { return $found }
  }
  foreach ($edition in @('BuildTools', 'Enterprise', 'Professional', 'Community')) {
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
      $candidate = Join-Path $pf "Microsoft Visual Studio\2022\$edition\VC\Auxiliary\Build\vcvars64.bat"
      if (Test-Path $candidate) { return $candidate }
    }
  }
  throw 'vcvars64.bat not found (set $env:VCVARS_PATH to override)'
}

$Vcvars = Find-Vcvars

# 1. Native shim (does its own vcvars handling internally).
& (Join-Path $PSScriptRoot "build_shim.ps1") -OutDir $OutDir

# 1b. App icon resource for kirk.exe (title bar, taskbar, Alt-Tab, tray all
# load icon id 1 from the exe). assets/logo.ico is the one true mark; the
# generated fallback below only exists so a missing file still builds.
$iconRes = $null
try {
  $icoPath = Join-Path $BuildDir "kirk.ico"
  $logoSrc = Join-Path $Root "assets\logo.ico"
  if (Test-Path $logoSrc) {
    Copy-Item $logoSrc $icoPath -Force
    Write-Host "Icon: using assets/logo.ico"
  } else {
    Write-Warning "assets/logo.ico missing - generating a fallback mark."
    Add-Type -AssemblyName System.Drawing
    # NOTE: plain foreach, not a pipeline - pipelines unroll byte[] into the
    # output stream and corrupt the icon entries.
    $iconPngs = @()
    foreach ($size in @(16, 32, 48, 256)) {
      $bmp = New-Object System.Drawing.Bitmap($size, $size)
      try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
          $g.Clear([System.Drawing.Color]::FromArgb(0x1d, 0x20, 0x21))
          $font = New-Object System.Drawing.Font("Segoe UI", ($size * 0.55), [System.Drawing.FontStyle]::Bold)
          try {
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xfe, 0x80, 0x19))
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString("K", $font, $brush, [System.Drawing.RectangleF]::new(0, 0, $size, $size), $sf)
          } finally { $brush.Dispose() }
        } finally { $g.Dispose(); $font.Dispose() }
        $ms = New-Object System.IO.MemoryStream
        try { $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $iconPngs += ,$ms.ToArray() }
        finally { $ms.Dispose() }
      } finally { $bmp.Dispose() }
    }
    $fs = [IO.File]::Create($icoPath)
    try {
      $bw = New-Object System.IO.BinaryWriter($fs)
      $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$iconPngs.Count)
      $offset = 6 + 16 * $iconPngs.Count
      $idx = 0
      $iconSizes = @(16, 32, 48, 256)
      foreach ($png in $iconPngs) {
        $w = $iconSizes[$idx]; $idx++
        if ($w -ge 256) { $wb = 0 } else { $wb = $w }
        $bw.Write([Byte]$wb); $bw.Write([Byte]$wb)
        $bw.Write([Byte]0); $bw.Write([Byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]$offset)
        $offset += $png.Length
      }
      foreach ($png in $iconPngs) { $bw.Write($png) }
      $bw.Flush()
    } finally { $fs.Close() }
  }
  $rcPath = Join-Path $BuildDir "kirk.rc"
  [IO.File]::WriteAllText($rcPath, '1 ICON "' + $icoPath.Replace('\', '\\') + '"')
  $kitsRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
  $rcExe = Get-ChildItem $kitsRoot -Recurse -Filter rc.exe -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
  if ($rcExe) {
    $resPath = Join-Path $BuildDir "kirk.res"
    & $rcExe.FullName /nologo /fo $resPath $rcPath 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "rc.exe failed" }
    $iconRes = $resPath
    Write-Host "Icon resource: $resPath"
  } else {
    Write-Warning "rc.exe not found under $kitsRoot - kirk.exe will have no icon resource."
  }
} catch {
  Write-Warning "Icon resource build failed ($($_.Exception.Message)) - continuing without an exe icon."
  $iconRes = $null
}

# 2. Crystal exe. Append the output dir to LIB so Crystal's
#    @[Link("shim")] lookup finds build\shim.lib. (Note: Crystal honors
#    LIB, not LIBRARY_PATH, for .lib lookup on Windows.)
if ($env:LIB -notlike "*$BuildDir*") { $env:LIB = "$env:LIB;$BuildDir" }

$release = if ($NoRelease) { "" } else { "--release" }
$iconFlags = if ($iconRes) { ' --link-flags "' + $iconRes + '"' } else { "" }
# NOTE: no `2>&1` here on purpose - merging native stderr turns Crystal's
# warnings into PowerShell error records, which throw under Stop preference.
& cmd.exe /d /c ('call "' + $Vcvars + '" >nul 2>&1 && crystal build src/kirk.cr -o ' + $OutDir + '\kirk.exe ' + $release + $iconFlags)
if ($LASTEXITCODE -ne 0) { throw "crystal build failed" }

# 3. Stage vendor ffmpeg next to kirk.exe (exe-dir lookup) if missing, then
#    headless-patch it (see below).
# Any ffmpeg-*-shared drop (the versioned dir name moves with upstream
# releases; vendor/ itself is gitignored and fetched by CI).
$vendorBin = Get-ChildItem (Join-Path $Root 'vendor') -Directory -Filter 'ffmpeg-*' -ErrorAction SilentlyContinue |
  ForEach-Object { Join-Path $_.FullName 'bin' } |
  Where-Object { Test-Path $_ } |
  Select-Object -First 1
if ($vendorBin -and (-not (Test-Path (Join-Path $BuildDir "ffmpeg.exe")))) {
  Copy-Item (Join-Path $vendorBin "*") $BuildDir -Force
  Write-Host "Staged vendor ffmpeg into $BuildDir"
}

# 3b. Stage the clip-saved chime next to kirk.exe (exe-dir lookup) when
#     present in the repo. Missing file = silent feedback, never a failure.
$chimeSrc = Join-Path $Root "assets\clip.wav"
$chimeDst = Join-Path $BuildDir "clip.wav"
if (Test-Path $chimeSrc) {
  Copy-Item $chimeSrc $chimeDst -Force
  Write-Host "Staged clip chime into $BuildDir"
} else {
  Write-Warning "No $chimeSrc - clip-save sound will be silent."
}

# 4. Headless ffmpeg: flip build\ffmpeg.exe from CONSOLE to WINDOWS subsystem
#    (editbin) so clip work never allocates a console window. Crystal's
#    Process passes no CREATE_NO_WINDOW, so every console-subsystem child
#    pops a visible window: a brief focus-stealing flash for remux, and a
#    permanent window for the rolling capture. As a WINDOWS-subsystem image
#    ffmpeg can never own a console; its stdio still flows through our
#    file/pipe redirects. Vendor original under vendor\ is left untouched.
$ffExe = Join-Path $BuildDir "ffmpeg.exe"
if (Test-Path $ffExe) {
  # editbin lives under the same VS install that provided vcvars.
  $vcDir = Split-Path (Split-Path (Split-Path $Vcvars -Parent) -Parent) -Parent
  $editbin = Get-ChildItem (Join-Path $vcDir 'Tools\MSVC') -Recurse -Filter editbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "Hostx64\\x64" } |
    Sort-Object FullName -Descending | Select-Object -First 1
  if ($editbin) {
    # Capture editbin output: a bare "editbin failed" hides the reason, which
    # is almost always a locked ffmpeg.exe (kirk capture still running from a
    # previous dev session - Windows locks running images for writes).
    $ebOut = & $editbin.FullName /SUBSYSTEM:WINDOWS $ffExe 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
      $lockers = @(Get-Process ffmpeg -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path -ieq $ffExe) { $_.Id } } catch { }
      })
      if ($lockers.Count -gt 0) {
        throw ("editbin failed (exit $LASTEXITCODE): $ffExe is locked by running ffmpeg PID(s) " +
          "$($lockers -join ', ') (kirk capture still running?). Stop kirk / kill them, then re-run this script.`n$ebOut")
      }
      throw "editbin failed (exit $LASTEXITCODE).`n$ebOut"
    }
    Write-Host "Headless ffmpeg: $($editbin.FullName)"
  } else {
    Write-Warning "editbin.exe not found - ffmpeg will keep popping console windows."
  }
} else {
  Write-Warning "No $ffExe (vendor ffmpeg not staged) - skipping headless patch."
}

# 5. Embed the PerMonitorV2 manifest (SDK mt.exe, newest kit first).
$kits = "C:\Program Files (x86)\Windows Kits\10\bin"
$mt = Get-ChildItem $kits -Recurse -Filter mt.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match "\\x64\\" } |
  Sort-Object FullName -Descending | Select-Object -First 1
if ($mt) {
  # Keep ";#1" inside a quoted string so PowerShell doesn't split on ';'.
  $outRes = (Join-Path $BuildDir "kirk.exe") + ";#1"
  & $mt.FullName -manifest (Join-Path $Root "native\kirk.manifest") "-outputresource:$outRes"
  if ($LASTEXITCODE -ne 0) { throw "mt.exe failed" }
  Write-Host "Manifest embedded: $($mt.FullName)"
} else {
  Write-Warning "mt.exe not found under $kits - skipping manifest embed (EXE will run without PerMonitorV2 declaration)."
}

Write-Host "`nBuilt: $BuildDir\kirk.exe"
