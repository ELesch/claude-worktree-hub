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

function Test-ConfigPlaceholder {
    param($Config)
    if (-not $Config -or -not $Config.repo) { return $true }
    return ($Config.repo -eq 'owner/repo')
}

function Test-GitPointer {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }   # missing, or a directory
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return $false   # UTF-8 BOM - git silently fails to parse this
    }
    return ([System.IO.File]::ReadAllText($Path).Trim() -eq 'gitdir: ./.bare')
}

function Get-PackageManagerFromLockfile {
    param([Parameter(Mandatory)][string]$WorktreePath)
    # Ordered so pnpm wins if multiple lockfiles coexist (matches the repo's pnpm default).
    $map = [ordered]@{
        'pnpm-lock.yaml'    = 'pnpm'
        'package-lock.json' = 'npm'
        'yarn.lock'         = 'yarn'
        'bun.lockb'         = 'bun'
    }
    foreach ($file in $map.Keys) {
        if (Test-Path (Join-Path $WorktreePath $file)) { return $map[$file] }
    }
    return $null
}
