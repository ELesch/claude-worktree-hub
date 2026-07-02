<#
.SYNOPSIS
    Plan-and-fire a BATCH: compose an overlap-aware wave from the ledger, preview it, and (with -Fire)
    provision + launch the whole fleet of worktree sessions in one command.
.DESCRIPTION
    Default run = read-only PREVIEW (no writes, no windows) — safe for the orchestrator to run and show.
    Edit the wave with -Exclude / -Only / -MaxSets (+ -MaxIssues/-MaxFiles caps), then -Fire to launch.
    A set = one worktree: a single approved issue, or a file-overlapping cluster (-> new-worktree.ps1 -Issues).
    Delegates provisioning to new-worktree.ps1 and ledger writes to review-coverage.ps1.
.EXAMPLE
    .\new-batch.ps1                      # preview the next wave
    .\new-batch.ps1 -Exclude 105 -MaxSets 4   # edit the wave
    .\new-batch.ps1 -Fire -Yes           # provision + launch the fleet (scripted)
#>
[CmdletBinding()]
param(
    [string]$Label,                     # optional batch label
    [int[]]$Only, [int[]]$Exclude,      # edit the wave: restrict to / drop these issue numbers
    [int]$MaxSets = 6,                  # cap the fleet width (excess sets -> deferred)
    [int]$MaxIssues = 4, [int]$MaxFiles = 8,   # engine cluster caps (passed to Get-IssueClusterPlan)
    [int]$Id,                           # explicit batch id (else auto = MAX(id)+1)
    [switch]$Fire,                      # provision + launch (default = preview only)
    [switch]$Yes,                       # skip the interactive confirm (scripted fire)
    [switch]$NoLaunch,                  # provision + register but do not open windows
    [switch]$SkipReview,                # bypass the approved-gate (emergencies only)
    [string]$Repo, [string]$DbPath
)
$ErrorActionPreference = 'Stop'
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') } catch { $Hub = $PSScriptRoot; $HubConfig = $null }
. (Join-Path $PSScriptRoot 'ledger-lib.ps1')   # Get-IssueClusterPlan, ConvertTo-BatchSets, Get-BatchFirePlan
. (Join-Path $PSScriptRoot 'hub-lib.ps1')       # ConvertTo-Slug, Get-ClusterName, Get-UnapprovedIssues
if (-not $Repo -and $HubConfig) { $Repo = $HubConfig.repo }
$db = if ($DbPath) { $DbPath } else { Join-Path $Hub '.review\coverage.db' }
if (-not (Test-Path $db)) { throw "ledger DB not found: $db  (run review-coverage.ps1 init first)" }

# ---- compose the wave (read-only) ----
$plan = Get-IssueClusterPlan $db $MaxIssues $MaxFiles
$comp = ConvertTo-BatchSets -Plan $plan -Only $Only -Exclude $Exclude -MaxSets $MaxSets
$sets = @($comp.Sets)
$batchId = if ($Id) { $Id } else { [int](& sqlite3 $db "SELECT COALESCE(MAX(id),0)+1 FROM batch;") }

# ledger-title-derived name (offline; used by BOTH preview and fire so names match exactly)
function Resolve-SetName($set) {
    $t = if ($plan.Meta.ContainsKey($set.Lowest)) { $plan.Meta[$set.Lowest].Title } else { '' }
    $name = if ($set.Kind -eq 'cluster') { Get-ClusterName -Lowest $set.Lowest -Title $t } else { "issue-$($set.Lowest)-$(ConvertTo-Slug $t)" }
    [pscustomobject]@{ Name = $name; Branch = "fix/$name" }
}

# Build the canonical seed prompt for a set (solver for a single issue, grouped-wave for a cluster),
# @-mentioning WORKTREE.md + the brief(s) new-worktree.ps1 wrote so they are forced into context.
function New-SeedPrompt($Fire, $Repo, $BatchId) {
    if ($Fire.Kind -eq 'cluster') {
        $head = (@('@WORKTREE.md', '@ISSUES.md') + @($Fire.Members | ForEach-Object { "@ISSUE-$_.md" })) -join "`n"
        $ml = ($Fire.Members -join ',#'); $fixes = (($Fire.Members | ForEach-Object { "Fixes #$_" }) -join ' / ')
        return @"
$head

You are the autonomous solver for a GROUPED WAVE of GitHub issues #$ml (repo $Repo) - same area.
Worktree: $($Fire.Name)   Branch: $($Fire.Branch)   Batch: $BatchId

WORKTREE.md is your operating manual - follow it, especially the grouped-wave rules. ISSUES.md is the wave
cover sheet; each ISSUE-<n>.md is a member brief (all force-included above). You own ALL these issues in this
one worktree: implement each on this branch, then open ONE PR whose body has one Fixes line per member
($fixes) so they auto-close on merge. Do NOT merge.

Stage one (before any code): run the stage-one product-necessity gate (WORKTREE.md) ONCE for the wave, routed
to hub-product-owner, judging EACH member; drop/ask about any member flagged not-necessary (do not halt the
whole wave). Research root causes, follow repo conventions, prove it with tests + the verify command, and
surface problems honestly - never paper over failures.

Begin.
"@
    }
    $n = $Fire.Lowest
    return @"
@WORKTREE.md
@ISSUE.md

You are the autonomous solver for GitHub issue #$n (repo $Repo).
Worktree: $($Fire.Name)   Branch: $($Fire.Branch)   Batch: $BatchId

WORKTREE.md (above) is your operating manual - follow it. ISSUE.md (above) is your brief. Where WORKTREE.md
shows <FOLDER>/<BRANCH>/<N>/<M>, use this worktree's values (<M> = the PR you open).

Stage one (before any code): run the stage-one product-necessity gate in WORKTREE.md - consult
hub-product-owner (curating the issue + current code + origin + PRODUCT.md) to confirm this is real,
necessary, and right-sized. HALT or ask per that section if it isn't. Research the root cause, follow repo
conventions, prove it with tests + the verify command, and surface problems honestly - never paper over
failures. Push and open a PR; do NOT merge.

Begin.
"@
}

# ---- preview ----
Write-Host "=== Batch $batchId preview ($($sets.Count) set(s)$(if ($Label) { " - $Label" })) ===" -ForegroundColor Cyan
if (-not $sets.Count) { Write-Host "  no eligible approved wave (nothing to fire)." -ForegroundColor Yellow }
$i = 0
foreach ($s in $sets) {
    $i++; $nm = Resolve-SetName $s
    $kind = if ($s.Kind -eq 'cluster') { "cluster x$($s.Members.Count)" } else { 'single' }
    Write-Host ("  [{0}] {1}  ({2})  {3}" -f $i, $nm.Name, $kind, $nm.Branch) -ForegroundColor Green
    foreach ($m in $s.Members) {
        $meta = if ($plan.Meta.ContainsKey($m)) { $plan.Meta[$m] } else { [pscustomobject]@{ Origin = '?'; Sev = '-'; Title = '' } }
        Write-Host ("       #{0} [{1}/{2}] {3}" -f $m, $meta.Origin, $meta.Sev, $meta.Title) -ForegroundColor Gray
    }
    if ($s.Files.Count) { Write-Host ("       owns: {0}" -f ($s.Files -join ', ')) -ForegroundColor DarkGray }
    if ($s.Siblings.Count) { Write-Host ("       siblings: {0}" -f (($s.Siblings | ForEach-Object { "$($_.Type)#$($_.Id)" }) -join ', ')) -ForegroundColor DarkGray }
}
if ($comp.Deferred.Count) {
    Write-Host "`n-- deferred (over -MaxSets $MaxSets) --" -ForegroundColor DarkYellow
    foreach ($d in $comp.Deferred) { Write-Host ("   #{0}{1}" -f $d.Lowest, $(if ($d.Members.Count -gt 1) { " (+$($d.Members.Count - 1))" })) -ForegroundColor DarkYellow }
}
Write-Host ""
if (-not $Fire) {
    Write-Host "(preview only - nothing provisioned. Re-run with -Fire to launch; -Exclude/-Only/-MaxSets to edit.)" -ForegroundColor Cyan
    return
}

# ==== FIRE ====
if (-not $sets.Count) { throw "nothing to fire (no eligible approved wave)." }
if (-not $Yes) {
    if (-not [Environment]::UserInteractive) { throw "non-interactive: pass -Yes to fire batch $batchId ($($sets.Count) set(s))." }
    if ((Read-Host "Fire batch $batchId of $($sets.Count) set(s)? [y/N]") -ne 'y') { Write-Host "aborted." -ForegroundColor Yellow; return }
}

# safety re-check: every member still approved (guards a status change since preview)
$allMembers = @($sets | ForEach-Object { $_.Members } | ForEach-Object { $_ } | Sort-Object -Unique)
if (-not $SkipReview) {
    $bad = @(Get-UnapprovedIssues -DbPath $db -Numbers $allMembers)
    if ($bad.Count) { throw "not approved: $(($bad | ForEach-Object { '#' + $_.Issue }) -join ', '). Run: review-coverage.ps1 issue approve -Id N  (or pass -SkipReview)." }
}

$rc = Join-Path $Hub 'review-coverage.ps1'
$nw = Join-Path $Hub 'new-worktree.ps1'
$launchersDir = Join-Path $Hub '.launchers'
if (-not (Test-Path $launchersDir)) { New-Item -ItemType Directory -Force -Path $launchersDir | Out-Null }
$flags = if (Get-Command Get-LaunchFlags -ErrorAction SilentlyContinue) { Get-LaunchFlags } else { '--permission-mode auto --effort max' }

# create the batch row
$batchArgs = @('batch', 'set', '-Id', "$batchId", '-Status', 'in-process'); if ($Label) { $batchArgs += @('-Title', $Label) }
& $rc @batchArgs | Out-Null

# resolve names, build the fire plan (splat-ready)
$nameMap = @{}; foreach ($s in $sets) { $r = Resolve-SetName $s; $nameMap[$s.Lowest] = @{ Name = $r.Name; Branch = $r.Branch } }
$firePlan = Get-BatchFirePlan -Sets $sets -NameMap $nameMap -BatchId $batchId

$fired = 0
foreach ($fp in $firePlan) {
    Write-Host "`n>>> set $($fp.Name)  [#$($fp.Members -join ' #')]" -ForegroundColor Cyan
    $prov = $fp.Provision.Clone(); if ($SkipReview) { $prov.SkipReview = $true }
    & $nw @prov
    if ($LASTEXITCODE) { Write-Host "  provisioning FAILED - skipping $($fp.Name)." -ForegroundColor Red; continue }
    $reg = $fp.Register
    & $rc register @reg | Out-Null
    # seed prompt + launcher (BOM-free per Lessons; follows spawn-child.ps1's spacing rules)
    $tab = if ($fp.Kind -eq 'cluster') { "#$($fp.Lowest)+$($fp.Members.Count - 1) b$batchId" } else { "#$($fp.Lowest) b$batchId" }
    $promptBody = New-SeedPrompt -Fire $fp -Repo $Repo -BatchId $batchId
    $wtPath = Join-Path $Hub $fp.Name
    $launcherPath = Join-Path $launchersDir "$($fp.Name).ps1"
    $launcherContent = @"
# Batch $batchId launcher for '$($fp.Name)' - generated by new-batch.ps1. Re-runnable.
`$Host.UI.RawUI.WindowTitle = '$tab'
Set-Location '$wtPath'
`$prompt = @'
$promptBody
'@
& "$Hub\claude-launch.ps1" $flags --name '$tab' `$prompt
"@
    [System.IO.File]::WriteAllText($launcherPath, $launcherContent, (New-Object System.Text.UTF8Encoding($false)))
    if ($NoLaunch) { Write-Host "  (-NoLaunch) launcher: $launcherPath" -ForegroundColor DarkGray }
    else { Start-Process -FilePath 'pwsh' -ArgumentList '-NoExit', '-File', $launcherPath | Out-Null; Write-Host "  launched '$tab'." -ForegroundColor Green }
    $fired++
}

Write-Host "`n=== batch $batchId fired: $fired/$($sets.Count) set(s) ===" -ForegroundColor Green
if ($comp.Deferred.Count) { Write-Host "deferred to a next batch: $(($comp.Deferred | ForEach-Object { '#' + $_.Lowest }) -join ', ')" -ForegroundColor DarkYellow }
Write-Host "watch:            & `"$Hub\review-coverage.ps1`" monitor" -ForegroundColor DarkGray
Write-Host "roll up at merge: & `"$Hub\review-coverage.ps1`" batch show -Id $batchId" -ForegroundColor DarkGray
