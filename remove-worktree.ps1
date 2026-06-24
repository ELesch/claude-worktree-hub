<#
.SYNOPSIS
    Tear down an agent worktree in the hub.
.DESCRIPTION
    Run from the hub root. Removes the worktree folder and its git
    metadata. Optionally deletes the worktree's local branch (-DeleteBranch) and discards
    uncommitted changes (-Force). Only remove a worktree after its work is committed/pushed.
.EXAMPLE
    .\remove-worktree.ps1 -Name agent-portal-ui
    .\remove-worktree.ps1 -Name agent-pdf-fix -DeleteBranch
    .\remove-worktree.ps1 -Name agent-stale -Force -DeleteBranch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$DeleteBranch,   # also delete the local branch that was checked out
    [switch]$Force           # discard uncommitted changes / force branch delete
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
$WtPath = Join-Path $Hub $Name

if ($Name -eq $HubConfig.baseWorktree -and -not $Force) {
    throw "'$($HubConfig.baseWorktree)' is the base/canonical worktree (holds the source .env). Refusing without -Force."
}

# Capture the branch this worktree has checked out, before we remove it.
$branch = $null
if (Test-Path $WtPath) {
    $branch = (& git -C $WtPath rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $branch = $null }
}

if (Test-Path $WtPath) {
    Write-Host "==> Removing worktree '$Name'..." -ForegroundColor Cyan
    if ($Force) { & git -C $Hub worktree remove --force $Name } else { & git -C $Hub worktree remove $Name }
    if ($LASTEXITCODE -ne 0) {
        throw "worktree remove failed (likely uncommitted changes). Re-run with -Force to discard them."
    }
}
else {
    Write-Host "==> Folder '$WtPath' not found; pruning stale worktree metadata..." -ForegroundColor Yellow
    & git -C $Hub worktree prune
}

if ($DeleteBranch -and $branch -and $branch -ne $HubConfig.defaultBranch -and $branch -ne "HEAD") {
    Write-Host "==> Deleting local branch '$branch'..." -ForegroundColor Cyan
    if ($Force) { & git -C $Hub branch -D $branch } else { & git -C $Hub branch -d $branch }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Branch '$branch' not deleted (unmerged?). Re-run with -Force to force-delete." -ForegroundColor Yellow
    }
}

& git -C $Hub worktree prune
Write-Host ""
Write-Host "Done. Current worktrees:" -ForegroundColor Green
& git -C $Hub worktree list
Write-Host ""
Write-Host "Remember to remove '$Name' from the Worktree registry in CLAUDE.md." -ForegroundColor DarkGray
