<#
.SYNOPSIS
  Interactive first-run setup for the claude-worktree-hub. Idempotent: re-run anytime
  to resume/repair. Does everything it can; offers fixes for the rest; ends by running
  the doctor.
.DESCRIPTION
  Phases: (1) preflight prerequisites, (2) bare-repo bootstrap, (3) config confirmation,
  (4) env scaffold, (5) ledger init+seed, (6) final readiness report.
.EXAMPLE
  .\setup-hub.ps1
  .\setup-hub.ps1 -CloneUrl https://github.com/acme/widgets.git
  .\setup-hub.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$CloneUrl,       # used for the bootstrap phase on a fresh hub
    [switch]$DryRun,         # show intended actions, change nothing
    [switch]$Yes             # accept the safe default for every prompt (non-interactive)
)
$ErrorActionPreference = 'Stop'
$Hub = $PSScriptRoot
. (Join-Path $Hub 'hub-checks.ps1')

function Write-Phase { param([string]$Title) Write-Host "`n==> $Title" -ForegroundColor Cyan }
function Write-Note  { param([string]$Msg)   Write-Host "    $Msg" -ForegroundColor DarkGray }

function Confirm-Action {
    <# Y/n prompt. -Yes auto-accepts; -DryRun reports and declines (no side effects). #>
    param([Parameter(Mandatory)][string]$Prompt, [switch]$DefaultNo)
    if ($DryRun) { Write-Note "(dry-run) would offer: $Prompt"; return $false }
    if ($Yes)    { return -not $DefaultNo }
    $suffix = if ($DefaultNo) { '[y/N]' } else { '[Y/n]' }
    $ans = Read-Host "    $Prompt $suffix"
    if (-not $ans) { return (-not $DefaultNo) }
    return ($ans -match '^(y|yes)$')
}

function Get-ConfigSafe {
    # Returns the parsed config or $null (never throws) so phases work pre-bootstrap.
    try { . (Join-Path $Hub 'hub-config.ps1'); return $HubConfig } catch { return $null }
}

# ---------------- Phase 1: prerequisites ----------------
function Invoke-PreflightPhase {
    Write-Phase 'Phase 1/6 - Prerequisites'
    $cfg = Get-ConfigSafe
    $checks = @(Get-HubReadiness -Config $cfg -HubRoot $Hub | Where-Object { $_.Category -eq 'prereq' })
    $hasInstaller = (Test-OnPath -Name 'winget') -or (Test-OnPath -Name 'choco')
    foreach ($c in $checks) {
        if ($c.Status -eq 'ok') { Write-Note "OK   $($c.Name)"; continue }
        Write-Host ("    NEEDS: {0} - {1}" -f $c.Name, $c.Detail) -ForegroundColor Yellow
        Write-Note "fix: $($c.Fix)"
        if ($c.Name -eq 'gh authenticated') {
            if (Confirm-Action "Run 'gh auth login' now?") {
                if (-not $DryRun) { & gh auth login; & gh auth setup-git }
            }
        }
        elseif ($c.Fix -match '^(winget|choco) ' -and $hasInstaller) {
            if (Confirm-Action "Run '$($c.Fix)' now?") {
                if (-not $DryRun) { & cmd /c $c.Fix }
            }
        }
        else {
            Write-Note 'Install it, then re-run setup-hub.ps1.'
        }
    }
}

# ---------------- Phase 2: bare-repo bootstrap ----------------
function Invoke-BootstrapPhase {
    Write-Phase 'Phase 2/6 - Bare-repo bootstrap'
    if (Test-BareRepo -HubRoot $Hub) { Write-Note 'Already bootstrapped (.bare present). Skipping.'; return }
    $url = $CloneUrl
    if (-not $url) {
        if ($DryRun) { Write-Note '(dry-run) would prompt for a clone URL and run init-hub.ps1'; return }
        if ($Yes) { throw 'No -CloneUrl provided and -Yes set; cannot bootstrap non-interactively. Re-run with -CloneUrl.' }
        $url = Read-Host '    Target repo clone URL (https://github.com/<owner>/<repo>.git)'
    }
    if (-not $url) { Write-Note 'No clone URL given; skipping bootstrap.'; return }
    Write-Note "Running init-hub.ps1 -CloneUrl $url"
    if (-not $DryRun) { & (Join-Path $Hub 'init-hub.ps1') -CloneUrl $url }
}

# ---------------- Phase 3: config confirmation ----------------
function Invoke-ConfigPhase {
    Write-Phase 'Phase 3/6 - Configuration'
    $cfgPath = Join-Path $Hub 'hub.config.json'
    if (-not (Test-Path $cfgPath)) { Write-Note 'No hub.config.json yet (bootstrap did not run). Skipping.'; return }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $dirty = $false

    if (Test-ConfigPlaceholder -Config $cfg) {
        if ($DryRun) { Write-Note '(dry-run) would prompt for the repo slug' }
        elseif (-not $Yes) {
            $repo = Read-Host "    'repo' is unset/placeholder. Enter owner/repo"
            if ($repo) { $cfg.repo = $repo; $dirty = $true }
        }
    }

    $baseDir = Join-Path $Hub $cfg.baseWorktree
    $detected = Get-PackageManagerFromLockfile -WorktreePath $baseDir
    if ($detected -and $detected -ne $cfg.packageManager) {
        Write-Host ("    Lockfile suggests '{0}' but config uses '{1}'." -f $detected, $cfg.packageManager) -ForegroundColor Yellow
        if (Confirm-Action "Update installCmd/verifyCmd/testCmd to '$detected'?") {
            $cfg.packageManager = $detected
            $cfg.installCmd = "$detected install"
            $cfg.verifyCmd = "$detected run verify"
            $cfg.testCmd = "$detected test"
            $dirty = $true
        }
    }

    if ($dirty -and -not $DryRun) {
        ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgPath -Encoding utf8
        Write-Note 'hub.config.json updated.'
    }
    elseif (-not $dirty) { Write-Note 'Config looks good; no changes.' }
}

# ---------------- main ----------------
if ($DryRun) { Write-Host 'DRY RUN - no changes will be made.' -ForegroundColor Yellow }
Invoke-PreflightPhase
Invoke-BootstrapPhase
Invoke-ConfigPhase
Invoke-EnvPhase
Invoke-LedgerPhase
Invoke-ReadinessPhase
