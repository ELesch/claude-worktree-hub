<#
.SYNOPSIS
    Launch a FLEET of read-only recon worktrees - one per surface - for a large parallel deep review
    (a fast way to spend a lot of tokens on discovery). Each recon gates before filing any issues.
.EXAMPLE
    .\launch-recon-fleet.ps1 -Surfaces database,logs,security,performance,a11y
    .\launch-recon-fleet.ps1 -Surfaces app,deps,tests -NoLaunch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Surfaces,
    [switch]$NoLaunch
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig

Write-Host "==> Recon fleet: $($Surfaces.Count) surface(s) -> $($Surfaces -join ', ')" -ForegroundColor Cyan
foreach ($s in $Surfaces) {
    Write-Host ""
    Write-Host "############## recon: $s ##############" -ForegroundColor Cyan
    if ($NoLaunch) { & "$Hub\new-recon.ps1" -Surface $s -NoLaunch }
    else { & "$Hub\new-recon.ps1" -Surface $s }
}
Write-Host ""
Write-Host "Fleet up. Each 'recon <surface>' window will deep-review, then GATE with a candidate issue list for your approval before filing." -ForegroundColor Green
