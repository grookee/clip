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
$Vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

if (-not (Test-Path $Vcvars)) { throw "vcvars64.bat not found: $Vcvars" }

# 1. Native shim (does its own vcvars handling internally).
& (Join-Path $PSScriptRoot "build_shim.ps1") -OutDir $OutDir

# 2. Crystal exe. Append the output dir to LIB so Crystal's
#    @[Link("shim")] lookup finds build\shim.lib. (Note: Crystal honors
#    LIB, not LIBRARY_PATH, for .lib lookup on Windows.)
if ($env:LIB -notlike "*$BuildDir*") { $env:LIB = "$env:LIB;$BuildDir" }

$release = if ($NoRelease) { "" } else { "--release" }
# NOTE: no `2>&1` here on purpose - merging native stderr turns Crystal's
# warnings into PowerShell error records, which throw under Stop preference.
& cmd.exe /d /c ('call "' + $Vcvars + '" >nul 2>&1 && crystal build src/kirk.cr -o ' + $OutDir + '\kirk.exe ' + $release)
if ($LASTEXITCODE -ne 0) { throw "crystal build failed" }

# 3. Stage vendor ffmpeg next to kirk.exe (exe-dir lookup) if missing, then
#    headless-patch it (see below).
$vendorBin = Join-Path $Root "vendor\ffmpeg-9.0.1-full_build-shared\bin"
if ((-not (Test-Path (Join-Path $BuildDir "ffmpeg.exe"))) -and (Test-Path $vendorBin)) {
  Copy-Item (Join-Path $vendorBin "*") $BuildDir -Force
  Write-Host "Staged vendor ffmpeg into $BuildDir"
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
  $editbin = Get-ChildItem "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC" -Recurse -Filter editbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "Hostx64\\x64" } |
    Sort-Object FullName -Descending | Select-Object -First 1
  if ($editbin) {
    & $editbin.FullName /SUBSYSTEM:WINDOWS $ffExe | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "editbin failed" }
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
