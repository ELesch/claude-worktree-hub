<#
  hub-checks.ps1 - readiness check library for the claude-worktree-hub.
  The SINGLE source of truth for "what a complete hub requires".
  Pure-ish: no prompts, no mutations. Consumed by hub-doctor.ps1 and setup-hub.ps1.
  Dot-source it:  . "$PSScriptRoot\hub-checks.ps1"
  Public: New-CheckResult, Get-ReadinessVerdict, Get-HubReadiness, plus pure helpers.
#>

# $PSScriptRoot here = the hub root (this file lives at the hub root).
$Hub = $PSScriptRoot

function New-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('prereq', 'hub', 'config', 'ledger', 'env', 'rules', 'info')][string]$Category,
        [Parameter(Mandatory)][ValidateSet('ok', 'warn', 'fail')][string]$Status,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    [pscustomobject]@{ Name = $Name; Category = $Category; Status = $Status; Detail = $Detail; Fix = $Fix }
}

function Get-ReadinessVerdict {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)
    $blockers = @($Results | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.Name })
    $warnings = @($Results | Where-Object { $_.Status -eq 'warn' } | ForEach-Object { $_.Name })
    [pscustomobject]@{ Ready = ($blockers.Count -eq 0); Blockers = $blockers; Warnings = $warnings }
}
