param(
  [string]$OutDir = "build"
)

$ErrorActionPreference = "Stop"

$Vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$Native = Join-Path $PSScriptRoot "..\native"
$Root   = Join-Path $PSScriptRoot ".."

if (-not (Test-Path $Vcvars)) { throw "vcvars64.bat not found: $Vcvars" }

$fullOut = Join-Path $Root $OutDir
New-Item -ItemType Directory -Force -Path $fullOut | Out-Null

# Each entry: source path + language flag (/TC for C, /TP for C++)
$srcFiles = @(
  @{ Path = (Join-Path $Native "src\shim.c");       Lang = "/TC" },
  @{ Path = (Join-Path $Native "src\shim_voice.cpp"); Lang = "/TP" },
  @{ Path = (Join-Path $Native "src\shim_ui.cpp");    Lang = "/TP" }
)

$defs  = "/D_WIN32 /D_WIN32_WINNT=0x0A00 /DWINVER=0x0A00"
$incs  = "/I`"$Native\include`""

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
