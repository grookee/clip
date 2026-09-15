# diag_keyboard.ps1
#
# Reproduces and diagnoses the "hotkeys swallow/block normal typing" issue
# during development WITHOUT relying on screenshots.
#
# How it works:
#   1. Optionally launches build\kirk.exe (global hotkeys active).
#   2. Opens a real editable target (Notepad's "Edit" control, or a WinForms
#      harness TextBox when the Store version of Notepad is installed).
#   3. Sends a battery of printable keys one at a time via SendKeys.
#   4. Reads back the received text after every key and reports exactly which
#      keys were dropped/swallowed together with the received payload.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\diag_keyboard.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\diag_keyboard.ps1 -LaunchKirk
#   powershell -ExecutionPolicy Bypass -File scripts\diag_keyboard.ps1 -SkipKirk
#
# Exit code 0 = every key arrived. Exit code 1 = one or more keys were lost.

param(
  [switch]$LaunchKirk,
  [switch]$SkipKirk,
  [string]$Exe = "",
  [string]$Notepad = "notepad.exe"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$scriptStart = Get-Date

$Root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $Root "build\kirk.exe" }
$LogPath = Join-Path $Root "build\keyboard-diag.log"

# Keys to send, in order. SendKeys treats ^ % ~ () {} + specially for letters,
# so spread them out: each entry here is sent alone (one keystroke).
$Keys = @(
  'a','b','c','d','e','f','g','h','i','j','k','l','m',
  'n','o','p','q','r','s','t','u','v','w','x','y','z',
  '0','1','2','3','4','5','6','7','8','9',' '
)

$results = @()

# --- 1. Optional kirk ---
$cc = $null
if ($LaunchKirk -and -not $SkipKirk) {
  if (-not (Test-Path $Exe)) { throw "kirk not found at $Exe - run scripts\build_shim.ps1 first." }
  Write-Host "Starting kirk: $Exe"
  $cc = Start-Process -FilePath $Exe -PassThru
  Start-Sleep -Milliseconds 800
} elseif ($SkipKirk) {
  Write-Host "Skipping kirk launch (comparing app running vs not running)."
} else {
  Write-Host "kirk NOT launched. Run with -LaunchKirk to test while its hotkeys are active."
}

# --- 2. Build a foreground editable target ---
# Try classic Notepad first (an "Edit" child control we can read with WM_GETTEXT).
# Fall back to a WinForms harness when the Store version of Notepad is present.
function Get-Target {
  $np = $null
  try { $np = Start-Process -FilePath $Notepad -PassThru -ErrorAction Stop } catch { }

  if ($np) {
    $mwh = [IntPtr]::Zero
    $started = Get-Date
    while ((Get-Date) - $started -lt [TimeSpan]::FromSeconds(8)) {
      $h = Get-Process -Id $np.Id -ErrorAction SilentlyContinue
      if ($null -ne $h) {
        $null = $h.Refresh()
        if ($h.MainWindowHandle -ne 0) { $mwh = $h.MainWindowHandle; break }
      }
      Start-Sleep -Milliseconds 150
    }
    if ($mwh) {
      # WM_GETTEXT via P/Invoke on the child "Edit"
      Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NativeEdit {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string className, string windowName);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr h);
  public static string Read(IntPtr edit) { var sb = new StringBuilder(65536); GetWindowText(edit, sb, sb.Capacity); return sb.ToString(); }
}
"@
      [IntPtr]$edit = [NativeEdit]::FindWindowEx($mwh, [IntPtr]::Zero, "Edit", $null)
      if ($edit -ne [IntPtr]::Zero) {
        [NativeEdit]::SetForegroundWindow($mwh) | Out-Null
        $read = { [NativeEdit]::Read($edit) }.GetNewClosure()
        $focus = {
          [NativeEdit]::SetForegroundWindow($mwh) | Out-Null
          Start-Sleep -Milliseconds 120
        }.GetNewClosure()
        return @{ Kind = "Notepad"; Hwnd = $mwh; Read = $read; Focus = $focus }
      }
    }

  try { $np.Kill() } catch { }
    try { $np.Dispose() } catch { }
  }

  # Fallback: WinForms harness
  Write-Host "Classic Notepad 'Edit' child not found - using a WinForms TextBox harness."
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true
  $tb.ScrollBars = 'Vertical'
  $tb.Width = 400; $tb.Height = 300
  $form = New-Object System.Windows.Forms.Form
  $form.Text = "kirk keyboard diagnostic"
  $form.Width = 480; $form.Height = 380
  $form.Controls.Add($tb)
  $form.Show()
  $tb.Select()
  [System.Windows.Forms.SendKeys]::SendWait('')
  $read = { $tb.Text }.GetNewClosure()
  $focus = {
    $form.Activate()
    $tb.Select()
    $waited = 0
    while (-not $form.ContainsFocus -and $waited -lt 100) {
      Start-Sleep -Milliseconds 20
      [System.Windows.Forms.Application]::DoEvents()
      $waited++
    }
  }.GetNewClosure()
  return @{ Kind = "Harness"; Hwnd = [IntPtr]$form.Handle; Read = $read; Focus = $focus }
}

$target = Get-Target
Write-Host "Target: $($target.Kind)"
Start-Sleep -Milliseconds 400
& $target.Focus

# --- 3. Send each key and read back ---
$expected = ""
$received = ""
foreach ($k in $Keys) {
  & $target.Focus
  Start-Sleep -Milliseconds 60
  try {
    [System.Windows.Forms.SendKeys]::SendWait($k)
  } catch { $results += @{ Key = $k; OK = $false; Note = "SendKeys threw: $($_.Exception.Message)" }; continue }
  Start-Sleep -Milliseconds 90
  $received = & $target.Read
  if ($received -ne $expected + $k) {
    $results += @{ Key = $k; OK = $false; Note = "expected '...$k', received tail '...$($received.Substring([Math]::Max(0,$received.Length-[Math]::Min(30,$received.Length))))'" }
  } else {
    $results += @{ Key = $k; OK = $true; Note = "" }
  }
  $expected = $received
}

# --- 4. Report ---
$failed = @($results | Where-Object { -not $_.OK })
$lines = @()
$lines += "kirk running: $([bool]($cc -and ($null -ne (Get-Process -Id $cc.Id -ErrorAction SilentlyContinue))))"
$lines += "Target: $($target.Kind)"
$lines += "Result: $($results.Count - $failed.Count)/$($results.Count) keys received"
foreach ($r in $results) {
  if ($r.OK) { $lines += "  PASS  $($r.Key)" } else { $lines += "  FAIL  $($r.Key)  $($r.Note)" }
}
$lines += ""
$lines += "Final text received: '$(if ($received.Length -gt 80) { $received.Substring(0,80) + '...' } else { $received })'"
$lines | ForEach-Object { Write-Host $_ }
$lines -join "`r`n" | Set-Content -Path $LogPath -Encoding UTF8
Write-Host "Log: $LogPath"

if ($cc) { try { $cc.Kill() } catch { }; try { $cc.Dispose() } catch { } }
# Kill any Notepad we spawned. On Win11 the Store re-launcher delegates to a
# separate UI host process, so the spawned PID is gone while the real window
# survives; catch all Notepad processes started during this run instead.
try {
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Notepad)) -ErrorAction SilentlyContinue |
    Where-Object { try { $_.StartTime -ge $scriptStart } catch { $false } } |
    Stop-Process -Force -ErrorAction SilentlyContinue
} catch { }

if ($failed.Count -gt 0) { exit 1 }
exit 0