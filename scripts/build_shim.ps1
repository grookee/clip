param(
  [string]$OutDir = "build"
)

$ErrorActionPreference = "Stop"

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
$Native = Join-Path $PSScriptRoot "..\native"
$Root   = Join-Path $PSScriptRoot ".."

$fullOut = Join-Path $Root $OutDir
New-Item -ItemType Directory -Force -Path $fullOut | Out-Null

# Each entry: source path + language flag (/TC for C, /TP for C++)
$srcFiles = @(
  @{ Path = (Join-Path $Native "src\shim.c");       Lang = "/TC" },
  @{ Path = (Join-Path $Native "src\shim_voice.cpp"); Lang = "/TP" },
  @{ Path = (Join-Path $Native "src\shim_ui.cpp");    Lang = "/TP" }
)

$defs  = "/D_WIN32 /D_WIN32_WINNT=0x0A00 /DWINVER=0x0A00"
$incs  = "/I`"$Native\include`" /I`"$fullOut`""

# Build stamp for the settings dialog footer (version + short commit),
# generated as a header to dodge cmd.exe macro-quoting pitfalls.
# Best-effort: missing shard.yml/git just yields placeholder defines.
$KirkVersion = "?"
try {
  $m = Select-String -LiteralPath (Join-Path $Root "shard.yml") -Pattern "^version:\s*(.+)$" | Select-Object -First 1
  if ($m -and $m.Matches[0].Groups[1].Value.Trim()) { $KirkVersion = $m.Matches[0].Groups[1].Value.Trim().Trim('"', "'") }
} catch { }
$KirkCommit = "unknown"
try {
  $c = & git -C $Root rev-parse --short HEAD 2>$null
  if ($LASTEXITCODE -eq 0 -and $c) { $KirkCommit = ([string]$c).Trim() }
} catch { }
$verHeader = '#pragma once' + "`r`n" + '#define KIRK_VERSION L"' + $KirkVersion.Replace('"', '') + '"' + "`r`n" + '#define KIRK_COMMIT L"' + $KirkCommit.Replace('"', '') + '"' + "`r`n"
[IO.File]::WriteAllText((Join-Path $fullOut "kirk_version.h"), $verHeader)
Write-Host "  version stamp: v$KirkVersion ($KirkCommit)"

$objs = @()
foreach ($s in $srcFiles) {
  $base = [System.IO.Path]::GetFileNameWithoutExtension($s.Path)
  $obj  = Join-Path $fullOut "$base.obj"
  $clCmd = "$($s.Lang) $defs $incs /nologo /O2 /c /Fo`"$obj`" `"$($s.Path)`""
  Write-Host "  cl: $clCmd"
  & cmd.exe /d /c "`"$Vcvars`" >nul 2>&1 && cl.exe $clCmd" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "cl.exe failed for $($s.Path)" }
  $objs += $obj
}

# Link into shim.dll
$objsArg = ($objs | ForEach-Object { "`"$_`"" }) -join " "
$libs    = "ole32.lib oleaut32.lib advapi32.lib sapi.lib uuid.lib mmdevapi.lib dwmapi.lib shell32.lib user32.lib gdi32.lib"
$linkCmd = "link.exe /NOLOGO /DLL /OUT:`"$fullOut\shim.dll`" /IMPLIB:`"$fullOut\shim.lib`" $objsArg $libs"

Write-Host "  link: $linkCmd"
& cmd.exe /d /c "`"$Vcvars`" >nul 2>&1 && $linkCmd" 2>&1
if ($LASTEXITCODE -ne 0) { throw "link.exe failed" }

Write-Host "`nBuilt: $fullOut\shim.dll"

# The PerMonitorV2 manifest (native\kirk.manifest) belongs on
# kirk.exe, not shim.dll: embed it after `crystal build` with:
#   mt.exe -manifest ..\native\kirk.manifest -outputresource:build\kirk.exe;#1
# The dialog also calls kirk_ui_init_dpi() at startup as a runtime fallback.
