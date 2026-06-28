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

# --- thin probe wrappers (mock these in tests; they isolate all side effects) ---

function Test-OnPath {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-GhAuth {
    & gh auth status *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GhCredentialHelper {
    # gh auth setup-git writes a credential.<host>.helper that invokes gh. Best-effort detection.
    $cfg = (& git config --get-regexp '^credential.*\.helper$' 2>$null)
    return [bool]($cfg -match 'gh')
}

function Test-BareRepo {
    param([Parameter(Mandatory)][string]$HubRoot)
    $r = (& git -C (Join-Path $HubRoot '.bare') rev-parse --is-bare-repository 2>$null)
    return ($r -eq 'true')
}

function Test-HubGitConfig {
    param([Parameter(Mandatory)][string]$HubRoot)
    $fetch = (& git -C $HubRoot config --get-all remote.origin.fetch 2>$null)
    $gc = (& git -C $HubRoot config --get gc.auto 2>$null)
    return (($fetch -match '\+refs/heads/\*') -and ($gc -eq '0'))
}

function Test-BaseWorktree {
    param([Parameter(Mandatory)][string]$HubRoot, $Config)
    $base = if ($Config -and $Config.baseWorktree) { $Config.baseWorktree } else { 'main' }
    $wt = Join-Path $HubRoot $base
    if (-not (Test-Path $wt)) { return $false }
    $up = (& git -C $wt rev-parse --abbrev-ref '@{upstream}' 2>$null)
    return [bool](($LASTEXITCODE -eq 0) -and $up)
}

function Test-LedgerSchema {
    param([Parameter(Mandatory)][string]$HubRoot)
    $db = Join-Path $HubRoot '.review\coverage.db'
    if (-not (Test-Path $db)) { return $false }
    $n = (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('topic','issue','finding','worktree');" 2>$null)
    return ($n -eq '4')
}

function Test-LedgerSeeded {
    param([Parameter(Mandatory)][string]$HubRoot)
    $db = Join-Path $HubRoot '.review\coverage.db'
    if (-not (Test-Path $db)) { return $false }
    $n = (& sqlite3 $db "SELECT count(*) FROM topic;" 2>$null)
    return ([int]$n -gt 0)
}

function Get-MissingEnvFiles {
    param([Parameter(Mandatory)][string]$HubRoot, $Config)
    $base = if ($Config -and $Config.baseWorktree) { $Config.baseWorktree } else { 'main' }
    $files = if ($Config -and $Config.envFiles) { $Config.envFiles } else { @('.env') }
    $baseDir = Join-Path $HubRoot $base
    return @($files | Where-Object { -not (Test-Path (Join-Path $baseDir $_)) })
}
