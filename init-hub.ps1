<#
.SYNOPSIS
  Bootstrap a colocated bare-repo worktree hub for a target GitHub repo.
.DESCRIPTION
  Run from the hub root. Bare-clones the target repo into .bare\, writes the BOM-free/LF
  .git redirect pointer, configures the fetch refspec + gc.auto=0, creates the base
  worktree (default 'main') with upstream tracking, and generates hub.config.json.
.EXAMPLE
  .\init-hub.ps1 -CloneUrl https://github.com/owner/repo.git
  .\init-hub.ps1 -CloneUrl https://github.com/owner/repo.git -Repo owner/repo -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CloneUrl,
    [string]$Repo,                       # owner/repo for gh; derived from CloneUrl if omitted
    [string]$DefaultBranch = 'main',
    [string]$BaseWorktree  = 'main',
    [string]$PackageManager = 'pnpm',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$Hub = $PSScriptRoot

function Step([string]$desc, [scriptblock]$action) {
    Write-Host "==> $desc" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "    (dry-run) $($action.ToString().Trim())" -ForegroundColor DarkGray }
    else { & $action }
}
function Invoke-Git { & git @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" } }

# derive repo slug from the clone URL if not supplied
if (-not $Repo) {
    if ($CloneUrl -match 'github\.com[:/]+([^/]+/[^/]+?)(?:\.git)?/?$') { $Repo = $Matches[1] }
    else { throw "Couldn't derive owner/repo from '$CloneUrl'; pass -Repo explicitly." }
}
Write-Host "Bootstrapping hub for $Repo at $Hub" -ForegroundColor Green

# preflight
foreach ($exe in 'git', 'gh') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$exe not found on PATH." }
}
if (-not $DryRun -and (Test-Path (Join-Path $Hub '.bare'))) { throw ".bare already exists - hub looks initialized. Aborting. (If a previous run half-finished, remove BOTH .bare and .git, then re-run.)" }

Step "Bare-cloning $CloneUrl -> .bare\" { Invoke-Git clone --bare $CloneUrl (Join-Path $Hub '.bare') }

Step "Writing BOM-free/LF .git redirect pointer" {
    # A fresh `git clone` leaves `.git` as a DIRECTORY; [IO.File]::WriteAllText can't overwrite a
    # directory path (it throws "Access to the path ... is denied"). Remove any existing `.git` first
    # - the clone's own dir, or a stale pointer from a half-finished run. The hub root's own git
    # history is meant to be discarded here anyway, and `.gitignore` already ignores `/.git`.
    $dotGit = Join-Path $Hub '.git'
    if (Test-Path $dotGit) { Remove-Item $dotGit -Recurse -Force }
    [System.IO.File]::WriteAllText($dotGit, "gitdir: ./.bare`n", (New-Object System.Text.UTF8Encoding($false)))
}

Step "Configuring fetch refspec + gc.auto=0" {
    Invoke-Git -C $Hub config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    Invoke-Git -C $Hub config gc.auto 0
    Invoke-Git -C $Hub fetch origin --prune
}

Step "Creating base worktree '$BaseWorktree' tracking origin/$DefaultBranch" {
    Invoke-Git -C $Hub worktree add $BaseWorktree "origin/$DefaultBranch"
    & git -C (Join-Path $Hub $BaseWorktree) branch --set-upstream-to="origin/$DefaultBranch" $DefaultBranch 2>$null | Out-Null
}

Step "Generating hub.config.json" {
    $cfgPath = Join-Path $Hub 'hub.config.json'
    if (Test-Path $cfgPath) { Write-Host "    hub.config.json exists; leaving it untouched." -ForegroundColor Yellow; return }
    $tpl = Get-Content (Join-Path $Hub 'hub.config.example.json') -Raw | ConvertFrom-Json
    $tpl.repo = $Repo; $tpl.cloneUrl = $CloneUrl; $tpl.defaultBranch = $DefaultBranch
    $tpl.baseWorktree = $BaseWorktree; $tpl.packageManager = $PackageManager
    $tpl.installCmd = "$PackageManager install"; $tpl.verifyCmd = "$PackageManager run verify"; $tpl.testCmd = "$PackageManager test"
    ($tpl | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgPath -Encoding utf8
}

Write-Host ""
Write-Host "Hub bootstrapped for $Repo." -ForegroundColor Green
Write-Host "Finish setup (idempotent - does config, ledger, env scaffold, prereq checks):" -ForegroundColor Green
Write-Host "  .\setup-hub.ps1" -ForegroundColor Green
Write-Host "Check readiness anytime:" -ForegroundColor Green
Write-Host "  .\hub-doctor.ps1" -ForegroundColor Green
