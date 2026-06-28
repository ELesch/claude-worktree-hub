<#
.SYNOPSIS
  Report whether the hub is fully initialized and ready to work. Read-only.
.DESCRIPTION
  Runs every readiness check (hub-checks.ps1) and prints a grouped, color-coded
  report. Exit code 0 when there are no blockers, 1 otherwise (scriptable).
.EXAMPLE
  .\hub-doctor.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-checks.ps1')

# Load config defensively: an un-bootstrapped hub has no hub.config.json, and
# hub-config.ps1 THROWS in that case - which must not crash the doctor.
$cfg = $null
try {
    . (Join-Path $PSScriptRoot 'hub-config.ps1')
    $cfg = $HubConfig
}
catch { $cfg = $null }

$results = Get-HubReadiness -Config $cfg -HubRoot $PSScriptRoot
$verdict = Get-ReadinessVerdict -Results $results

$glyph = @{ ok = 'OK  '; warn = 'WARN'; fail = 'FAIL' }
$color = @{ ok = 'Green'; warn = 'Yellow'; fail = 'Red' }
$catTitle = [ordered]@{
    prereq = 'Prerequisites'; hub = 'Hub artifacts'; config = 'Configuration'
    ledger = 'Ledger'; env = 'Secrets / env'; rules = 'Worktree rules'; info = 'Optional'
}

Write-Host ''
Write-Host '=== Hub readiness ===' -ForegroundColor Cyan
foreach ($cat in $catTitle.Keys) {
    $group = @($results | Where-Object { $_.Category -eq $cat })
    if (-not $group) { continue }
    Write-Host ''
    Write-Host $catTitle[$cat] -ForegroundColor Cyan
    foreach ($c in $group) {
        Write-Host ("  [{0}] {1}" -f $glyph[$c.Status], $c.Name) -ForegroundColor $color[$c.Status] -NoNewline
        if ($c.Detail) { Write-Host ("  - {0}" -f $c.Detail) -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
        if ($c.Status -ne 'ok' -and $c.Fix) {
            Write-Host ("        fix: {0}" -f $c.Fix) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
if ($verdict.Ready) {
    Write-Host 'HUB READY - no blockers.' -ForegroundColor Green
    if ($verdict.Warnings.Count) { Write-Host ("  ({0} warning(s) - review above)" -f $verdict.Warnings.Count) -ForegroundColor Yellow }
    exit 0
}
else {
    Write-Host ("NOT READY - {0} blocker(s): {1}" -f $verdict.Blockers.Count, ($verdict.Blockers -join ', ')) -ForegroundColor Red
    Write-Host 'Run .\setup-hub.ps1 to fix interactively.' -ForegroundColor Yellow
    exit 1
}
