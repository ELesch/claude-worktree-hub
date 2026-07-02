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

# ==== FIRE: implemented in Task 9 (appended below this line) ====
throw "fire not yet implemented"   # replaced in Task 9
