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

# Set true if Phase 1 actually runs an installer. A winget/choco install updates the
# machine/user PATH but NOT this process's $env:PATH, so freshly-installed tools won't be
# usable until a NEW terminal is opened - we stop after Phase 1 and tell the user to re-run.
$script:installsRan = $false

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
    foreach ($c in $checks) {
        if ($c.Status -eq 'ok') { Write-Note "OK   $($c.Name)"; continue }
        Write-Host ("    NEEDS: {0} - {1}" -f $c.Name, $c.Detail) -ForegroundColor Yellow
        Write-Note "fix: $($c.Fix)"
        # The check's Fix field is human-readable display text, NOT a runnable command.
        # Resolve a real, runnable install command (winget preferred) from the check name.
        $cmd = Resolve-InstallCommand -CheckName $c.Name -HasWinget:(Test-OnPath 'winget') -HasChoco:(Test-OnPath 'choco')
        # gh-auth offers are gated on gh actually being on PATH: if gh was just installed this
        # run it isn't usable yet (PATH is stale), and invoking it would throw under Stop.
        if ($c.Name -eq 'gh authenticated' -and (Test-OnPath 'gh')) {
            if (Confirm-Action "Run 'gh auth login' now?") { if (-not $DryRun) { & gh auth login; & gh auth setup-git } }
        }
        elseif ($c.Name -eq 'gh git credential helper' -and (Test-OnPath 'gh')) {
            if (Confirm-Action "Run 'gh auth setup-git' now?") { if (-not $DryRun) { & gh auth setup-git } }
        }
        elseif ($cmd) {
            if (Confirm-Action "Run '$cmd' now?") {
                if (-not $DryRun) { & cmd /c $cmd; $script:installsRan = $true; if ($LASTEXITCODE -ne 0) { Write-Note "install exited $LASTEXITCODE - install manually: $($c.Fix)" } }
            }
        }
        else { Write-Note "Install it, then re-run setup-hub.ps1.  (hint: $($c.Fix))" }
    }
}

# ---------------- Phase 2: bare-repo bootstrap ----------------
function Invoke-BootstrapPhase {
    Write-Phase 'Phase 2/6 - Bare-repo bootstrap'
    if (Test-BareRepo -HubRoot $Hub) { Write-Note 'Already bootstrapped (.bare present). Skipping.'; return }
    # Preflight: init-hub.ps1 hard-throws if git/gh aren't on PATH (its own preflight). Replace
    # that raw exception with a clean note + skip; Phase 6's doctor still reports the missing
    # tool as a blocker, so the honest NOT-READY verdict is preserved - nothing is hidden.
    foreach ($tool in 'git', 'gh') {
        if (-not (Test-OnPath -Name $tool)) {
            Write-Note "Cannot bootstrap yet: '$tool' is not on PATH. Install it (see Phase 1) and re-run .\setup-hub.ps1."
            return
        }
    }
    $url = $CloneUrl
    if (-not $url) {
        if ($DryRun) { Write-Note '(dry-run) would prompt for a clone URL and run init-hub.ps1'; return }
        if ($Yes) { throw 'No -CloneUrl provided and -Yes set; cannot bootstrap non-interactively. Re-run with -CloneUrl.' }
        $url = Read-Host '    Target repo clone URL (https://github.com/<owner>/<repo>.git)'
    }
    if (-not $url) { Write-Note 'No clone URL given; skipping bootstrap.'; return }
    Write-Note ("{0}Running init-hub.ps1 -CloneUrl {1}" -f $(if($DryRun){'(dry-run) would: '}else{''}), $url)
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

    # Read raw above for write-back, but a sparse hand-edited config may omit baseWorktree;
    # default it locally (matches hub-config.ps1) so Join-Path can't throw on a $null child.
    $baseWt = if ($cfg.baseWorktree) { $cfg.baseWorktree } else { 'main' }
    $baseDir = Join-Path $Hub $baseWt
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

# ---------------- Phase 4: env scaffold ----------------
function Invoke-EnvPhase {
    Write-Phase 'Phase 4/6 - Secrets / env scaffold'
    $cfg = Get-ConfigSafe
    if (-not $cfg) { Write-Note 'No config; skipping env scaffold.'; return }
    $baseDir = Join-Path $Hub $cfg.baseWorktree
    $missing = Get-MissingEnvFiles -HubRoot $Hub -Config $cfg
    if (-not $missing) { Write-Note 'All configured env files present.'; return }
    foreach ($f in $missing) {
        $example = Join-Path $baseDir "$f.example"
        if (Test-Path $example) {
            if (Confirm-Action "Copy $f.example -> $f in $($cfg.baseWorktree)\ (you fill in secrets)?") {
                if (-not $DryRun) { Copy-Item $example (Join-Path $baseDir $f) -Force }
                Write-Note "Created $($cfg.baseWorktree)\$f - edit it to add real secret values."
            }
        }
        else {
            Write-Note "Missing $f and no $f.example to copy. Create $($cfg.baseWorktree)\$f manually if your app needs it."
        }
    }
}

# ---------------- Phase 5: ledger ----------------
function Invoke-LedgerPhase {
    Write-Phase 'Phase 5/6 - Ledger (SQLite)'
    if (-not (Test-OnPath -Name 'sqlite3')) { Write-Note 'sqlite3 not on PATH; cannot init the ledger yet. Fix prereqs then re-run.'; return }
    $rc = Join-Path $Hub 'review-coverage.ps1'
    if (-not (Test-LedgerSchema -HubRoot $Hub)) {
        Write-Note ("{0}Initializing ledger schema (review-coverage.ps1 init)..." -f $(if($DryRun){'(dry-run) would: '}else{''}))
        if (-not $DryRun) { & $rc init }
    }
    else { Write-Note 'Ledger schema already present.' }
    if (-not (Test-LedgerSeeded -HubRoot $Hub)) {
        Write-Note ("{0}Seeding starter topics (review-coverage.ps1 seed)..." -f $(if($DryRun){'(dry-run) would: '}else{''}))
        if (-not $DryRun) { & $rc seed }
    }
    else { Write-Note 'Ledger already seeded.' }
}

# ---------------- Phase 6: final readiness ----------------
function Invoke-ReadinessPhase {
    # Returns the doctor's exit code (0 ready / 1 blockers); 0 under -DryRun.
    Write-Phase 'Phase 6/6 - Readiness report'
    if ($DryRun) { Write-Note '(dry-run) would run hub-doctor.ps1 for the final verdict.'; return 0 }
    & (Join-Path $Hub 'hub-doctor.ps1')
    $doctorExit = $LASTEXITCODE
    if ($doctorExit -eq 0) { Write-Host "`nSetup complete - hub is READY." -ForegroundColor Green }
    else { Write-Host "`nSetup ran, but blockers remain (see above). Fix them and re-run .\setup-hub.ps1." -ForegroundColor Yellow }
    return $doctorExit
}

# ---------------- main ----------------
if ($DryRun) { Write-Host 'DRY RUN - no changes will be made.' -ForegroundColor Yellow }
Invoke-PreflightPhase
if ($script:installsRan) {
    Write-Host "`nInstalled tools won't be on PATH until you open a NEW terminal." -ForegroundColor Yellow
    Write-Host "Open a fresh terminal and re-run .\setup-hub.ps1 to continue (it resumes where it left off)." -ForegroundColor Yellow
    exit 0
}
Invoke-BootstrapPhase
Invoke-ConfigPhase
# --- product brief: scaffold PRODUCT.md from the template (grounds the hub-dx-product/hub-principal experts) ---
$productPath = Join-Path $Hub 'PRODUCT.md'
$productExample = Join-Path $Hub 'PRODUCT.example.md'
if ((Test-Path $productExample) -and -not (Test-Path $productPath)) {
    Write-Note ("{0}Creating PRODUCT.md from PRODUCT.example.md (fill it in so the product/principal experts can ground their advice; worktrees read it live)..." -f $(if($DryRun){'(dry-run) would: '}else{''}))
    if (-not $DryRun) { Copy-Item $productExample $productPath }
}
elseif (Test-Path $productPath) { Write-Note "PRODUCT.md already present." }
Invoke-EnvPhase
Invoke-LedgerPhase
# Capture the doctor's verdict and make the wizard's exit code intentional, so a residual
# $LASTEXITCODE from an earlier probe (e.g. git -C .bare on a hub with no .bare) can't leak.
$doctorExit = Invoke-ReadinessPhase
if ($DryRun) { exit 0 } else { exit $doctorExit }
