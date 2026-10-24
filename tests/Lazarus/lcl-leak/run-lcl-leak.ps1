<#
  run-lcl-leak.ps1 - build (optional) + run the LCL memory-leak test and compare
  the two heaptrc dumps.  Windows / Lazarus 4.8 / FPC 3.2.2.

  The RUN is fully scripted; the BUILD of an LCL app needs a project file, so:
    - build once in the Lazarus IDE (see README), then run this script, OR
    - pass -Lazbuild <path\lazbuild.exe> and it builds the .lpi first.

  Defaults target Lazarus 4.8 (the #576 environment): lazbuild beside
  lazarus.exe, driven with the matching --pcp config so it uses FPC 3.2.2 and
  the packages registered in that config.

  Usage (from this folder):
    powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1
    powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1 -NoBuild
    powershell -ExecutionPolicy Bypass -File .\run-lcl-leak.ps1 -Lazbuild "C:\Lazarus\Lazarus_3_2\lazbuild.exe" -Pcp "C:\lazarus\cfg_3_2"

  It runs three passes and prints a verdict:
    --nostop    -> issue.log   (the bug: server never stopped before close)
    (no args)   -> fixed.log   (the fix: THorse.StopListen before close)
    --cycles N  -> cycles.log  (the fix under repetition)
#>
param(
  [string]$Exe      = ".\HorseMormotLclLeakTest.exe",
  [string]$Lazbuild = "C:\Lazarus\Lazarus_4_8\lazbuild.exe",
  [string]$Pcp      = "C:\lazarus\cfg_4_8",
  [string]$Lpi      = ".\HorseMormotLclLeakTest.lpi",
  [int]   $Measure  = 2000,
  [int]   $Cycles   = 20,
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not $NoBuild) {
  if (Test-Path $Lazbuild) {
    if ($Pcp -ne "") {
      Write-Host "Building: $Lazbuild --pcp=$Pcp $Lpi"
      & $Lazbuild "--pcp=$Pcp" $Lpi
    } else {
      Write-Host "Building: $Lazbuild $Lpi"
      & $Lazbuild $Lpi
    }
    if ($LASTEXITCODE -ne 0) { throw "lazbuild failed (exit $LASTEXITCODE) - build in the IDE instead (see README)" }
  }
  elseif (-not (Test-Path $Exe)) {
    throw "lazbuild not found at '$Lazbuild' and no prebuilt '$Exe'. Build in the IDE, or pass -Lazbuild/-Pcp, or -NoBuild with a prebuilt exe."
  }
}

if (-not (Test-Path $Exe)) {
  throw "Executable not found: $Exe`nBuild it in the Lazarus IDE with 'Use Heaptrc unit (-gh)' enabled, or pass -Lazbuild."
}

function Invoke-Pass {
  param([string]$Label, [string]$Log, [string[]]$AppArgs)
  if (Test-Path $Log) { Remove-Item $Log -Force }
  $env:HEAPTRC = "log=$Log"
  Write-Host "=== $Label :  $Exe $($AppArgs -join ' ') ==="
  $p = Start-Process -FilePath $Exe -ArgumentList $AppArgs -WorkingDirectory $PSScriptRoot -Wait -PassThru
  $code = $p.ExitCode
  $blocks = $null; $bytes = $null; $crashed = $false; $note = ""
  if (-not (Test-Path $Log)) {
    $crashed = $true; $note = "no heaptrc log (built without -gh?)"
  }
  else {
    $line = Select-String -Path $Log -Pattern 'unfreed memory blocks' | Select-Object -Last 1
    if ($null -eq $line) {
      # heaptrc did not finish its summary - the process died mid-dump, which is
      # the --nostop symptom: abandoned server threads corrupt the exit heap walk.
      $crashed = $true
      $alloc = Select-String -Path $Log -Pattern 'memory blocks allocated' | Select-Object -Last 1
      if ($alloc) { $note = "dump truncated at: " + $alloc.Line.Trim() + "  (crashed mid-dump)" }
      else        { $note = "no heaptrc summary (crashed on exit)" }
    }
    else {
      Write-Host ("    " + $line.Line.Trim())
      if ($line.Line -match '(\d+)\s+unfreed memory blocks\s*:\s*(\d+)') {
        $blocks = [int]$Matches[1]; $bytes = [int]$Matches[2]
      }
    }
  }
  if ($crashed) { Write-Host ("    CRASH/NO-DUMP (exit $code): " + $note) }
  [pscustomobject]@{ Label=$Label; Log=$Log; Blocks=$blocks; Bytes=$bytes; Exit=$code; Crashed=$crashed; Note=$note }
}

# Clean pass FIRST, so we capture the baseline even if the abandoned-server pass
# crashes the heaptrc dump.
$fixed  = Invoke-Pass "FIXED  (StopListen)"     "fixed.log"  @("--measure","$Measure")
$cycRes = Invoke-Pass "CYCLES ($Cycles x stop)" "cycles.log" @("--cycles","$Cycles","--measure","$Measure")
$issue  = Invoke-Pass "ISSUE  (--nostop)"       "issue.log"  @("--nostop","--measure","$Measure")

function Show {
  param($r)
  if ($r.Crashed) { "{0,-22} {1,10}   ({2})" -f $r.Label, "CRASH", $r.Log }
  else            { "{0,-22} {1,10} blocks {2,12} bytes   ({3})" -f $r.Label, $r.Blocks, $r.Bytes, $r.Log }
}
Write-Host ""
Write-Host "--- heaptrc at exit ------------------------------------------------"
Show $fixed
Show $cycRes
Show $issue
Write-Host "--------------------------------------------------------------------"

if ($fixed.Crashed) {
  Write-Host "VERDICT: the FIXED (StopListen) pass itself crashed / produced no dump."
  Write-Host "  That is a deeper problem than the forgot-to-stop case - inspect fixed.log and"
  Write-Host "  send it with the horse-provider-mormot / mORMot2 commit SHAs."
}
elseif (($null -ne $fixed.Blocks) -and ($fixed.Blocks -le 8)) {
  Write-Host ("VERDICT: FIXED is CLEAN ({0} unfreed blocks) - StopListen before close resolves it." -f $fixed.Blocks)
  if ((-not $cycRes.Crashed) -and ($null -ne $cycRes.Blocks) -and ($cycRes.Blocks -le ($fixed.Blocks + 8))) {
    Write-Host ("  Repeated start/stop is clean too ($Cycles cycles -> {0} blocks, no accumulation)." -f $cycRes.Blocks)
  }
  if ($issue.Crashed) {
    Write-Host "  ISSUE (--nostop) CRASHED/truncated the heaptrc dump - the abandoned server's"
    Write-Host "  threads corrupt the exit heap walk. This is the #576 symptom on an UN-HARDENED"
    Write-Host "  provider. With FIX-MORMOT-SHUTDOWN-1 (provider finalization) applied, re-run:"
    Write-Host "  ISSUE should now exit cleanly too (the safety net stops the server at exit)."
  }
  elseif (($null -ne $issue.Blocks) -and ($issue.Blocks -le ($fixed.Blocks + 8))) {
    Write-Host "  ISSUE (--nostop) is also clean -> FIX-MORMOT-SHUTDOWN-1 is in effect: a forgot-"
    Write-Host "  to-stop close now shuts the server down at finalization. Both paths safe."
  }
  else {
    Write-Host ("  ISSUE (--nostop) retained {0} blocks vs FIXED {1} - the forgot-to-stop leak." -f $issue.Blocks, $fixed.Blocks)
  }
}
else {
  Write-Host "VERDICT: FIXED did not come back clean - read fixed.log 'Call trace' entries."
}
