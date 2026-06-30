<#
.SYNOPSIS
    Provision an isolated worktree for a Claude Code agent in the hub.
.DESCRIPTION
    Run from the hub root. Creates a worktree folder + branch, copies
    .env* from $($HubConfig.baseWorktree)\ (unless -NoEnv), optionally runs the configured
    install command (-Install), and - for issue worktrees - drops the issue's full resources
    into the worktree as ISSUE.md plus an issue-assets\ folder (text, comments, metadata,
    and authenticated screenshot downloads).

    An issue worktree is triggered by -Issue <N>, or auto-detected when -Name looks like
    issue-<N>-... . ISSUE.md and issue-assets\ are git-excluded so they never get committed.
.EXAMPLE
    .\new-worktree.ps1 -Issue 497 -Install
    .\new-worktree.ps1 -Name issue-503-chat-dialog -Install     # issue # auto-detected
    .\new-worktree.ps1 -Name agent-portal-ui -Install           # non-issue task
    .\new-worktree.ps1 -Name wt-portal-ai -Branch portal-ai-authoring -Existing -Install
#>
[CmdletBinding()]
param(
    [string]$Name,                      # worktree folder name (optional if -Issue is given)
    [int]$Issue = 0,                    # GitHub issue number -> pulls the issue's full resources
    [int[]]$Issues,                     # grouped wave: 2+ approved issues -> ONE worktree (cluster-<lowest>-..)
    [string]$Branch,                    # branch to create / check out
    [string]$BaseBranch,               # base for a new branch; defaults to $HubConfig.defaultBranch
    [string]$Repo,                      # repo for issue lookups; defaults to $HubConfig.repo
    [switch]$Existing,                  # check out an existing branch instead of creating one
    [switch]$Install,                   # run the configured install command in the new worktree
    [switch]$NoEnv,                     # skip copying .env* from the base worktree
    [switch]$NoIssueBundle,             # skip fetching issue resources even for an issue worktree
    [switch]$SkipReview                 # bypass the ledger review gate (emergencies only)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
. (Join-Path $Hub 'hub-lib.ps1')
if (-not $Repo) { $Repo = $HubConfig.repo }
if (-not $BaseBranch) { $BaseBranch = $HubConfig.defaultBranch }

# Grouped-wave mode: -Issues 12,15,19 -> one worktree owning all members.
$grouped = @($Issues | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
if ($grouped.Count -eq 1) { throw "Use -Issue <N> for a single issue; -Issues is for a grouped wave of 2+ approved issues." }
if ($grouped.Count -ge 2 -and $Issue -gt 0) { throw "Pass either -Issue (single) or -Issues (grouped wave), not both." }
$isGrouped = $grouped.Count -ge 2
if ($isGrouped -and -not $Name) {
    $lowest = [int]$grouped[0]
    $title = (& gh issue view $lowest --repo $Repo --json title --jq '.title')
    if ($LASTEXITCODE -ne 0) { throw "Couldn't fetch issue #$lowest from $Repo to derive a worktree name." }
    $Name = Get-ClusterName -Lowest $lowest -Title $title
    Write-Host "==> Grouped wave #$($grouped -join ',#') -> worktree '$Name'" -ForegroundColor Cyan
}

function Test-Ref([string]$ref) {
    & git -C $Hub show-ref --verify --quiet $ref
    return ($LASTEXITCODE -eq 0)
}
function Invoke-Git {
    & git -C $Hub @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

# Resolve the issue number: explicit -Issue, or inferred from an 'issue-<N>-...' name.
if (-not $isGrouped -and $Issue -le 0 -and $Name -and $Name -match '^issue-(\d+)') { $Issue = [int]$Matches[1] }

# When only -Issue was given, derive the folder name from the issue title.
if ($Issue -gt 0 -and -not $Name) {
    $title = (& gh issue view $Issue --repo $Repo --json title --jq '.title')
    if ($LASTEXITCODE -ne 0) { throw "Couldn't fetch issue #$Issue from $Repo to derive a worktree name." }
    $Name = "issue-$Issue-$(ConvertTo-Slug $title)"
    Write-Host "==> Issue #$Issue -> worktree '$Name'" -ForegroundColor Cyan
}

if (-not $Name) { throw "Provide -Name <folder> or -Issue <number>." }
$WtPath = Join-Path $Hub $Name
if (Test-Path $WtPath) { throw "Folder '$WtPath' already exists. Pick another -Name or remove it first." }

# --- review gate: an issue worktree requires a ledger-approved issue (override with -SkipReview) ---
if ($Issue -gt 0 -and -not $SkipReview) {
    $covDb = Join-Path $Hub '.review\coverage.db'
    if (Test-Path $covDb) {
        $hasIssueTbl = (& sqlite3 $covDb "SELECT name FROM sqlite_master WHERE type='table' AND name='issue';" 2>$null)
        if ($hasIssueTbl) {
            $rs = (& sqlite3 $covDb "SELECT review_status FROM issue WHERE number=$Issue;" 2>$null)
            if ($rs -ne 'approved') {
                $cur = if ($rs) { $rs } else { 'not synced' }
                throw @"
Issue #$Issue is not ledger-approved (review_status='$cur'). Issues must pass ledger review before a worktree.
Run from the hub root:
    .\review-coverage.ps1 issue sync
    .\review-coverage.ps1 issue unreviewed        # the review queue; the orchestrator fans out review subagents
    .\review-coverage.ps1 issue record-review -Id $Issue -Targets '<files>' -Severity .. -Track simple|complex -Verdict still-valid
    .\review-coverage.ps1 issue approve -Id $Issue
...or pass -SkipReview to bypass the gate (emergencies only).
"@
            }
        }
    }
}

# --- review gate (grouped): EVERY member must be ledger-approved (override with -SkipReview) ---
if ($isGrouped -and -not $SkipReview) {
    $covDb = Join-Path $Hub '.review\coverage.db'
    if (Test-Path $covDb) {
        $hasIssueTbl = (& sqlite3 $covDb "SELECT name FROM sqlite_master WHERE type='table' AND name='issue';" 2>$null)
        if ($hasIssueTbl) {
            $bad = @(Get-UnapprovedIssues -DbPath $covDb -Numbers $grouped)
            if ($bad.Count) {
                $list = ($bad | ForEach-Object { "#$($_.Issue) ($($_.Status))" }) -join ', '
                throw @"
Grouped wave blocked: these members are not ledger-approved: $list
Every member of a grouped wave must pass ledger review first. Run from the hub root:
    .\review-coverage.ps1 issue sync
    .\review-coverage.ps1 issue approve -Id <N>     (for each member)
...or pass -SkipReview to bypass the gate (emergencies only).
"@
            }
        }
    }
}

Write-Host "==> Fetching origin..." -ForegroundColor Cyan
Invoke-Git fetch origin --prune

if ($Existing) {
    $br = if ($Branch) { $Branch } else { $Name }
    $hasRemote = Test-Ref "refs/remotes/origin/$br"
    if ($hasRemote) { & git -C $Hub fetch origin "${br}:${br}" 2>$null }
    if (Test-Ref "refs/heads/$br") {
        Write-Host "==> Checking out existing branch '$br' into '$Name'..." -ForegroundColor Cyan
        Invoke-Git worktree add $Name $br
    }
    elseif ($hasRemote) {
        Write-Host "==> Creating tracking worktree for 'origin/$br' in '$Name'..." -ForegroundColor Cyan
        Invoke-Git worktree add --track -b $br $Name "origin/$br"
    }
    else {
        throw "Branch '$br' not found locally or on origin. Run 'git -C `"$Hub`" branch -a' to inspect."
    }
    if ($hasRemote) { & git -C $WtPath branch --set-upstream-to="origin/$br" $br 2>$null | Out-Null }
}
else {
    $br = if ($Branch) { $Branch } elseif ($Issue -gt 0 -or $isGrouped) { "fix/$Name" } else { "feature/$([regex]::Replace($Name, '^agent-', ''))" }
    if (Test-Ref "refs/heads/$br") { throw "Branch '$br' already exists. Use -Existing to check it out, or pass a different -Branch." }
    $base = if (Test-Ref "refs/remotes/origin/$BaseBranch") { "origin/$BaseBranch" } elseif (Test-Ref "refs/heads/$BaseBranch") { $BaseBranch } else { throw "Base branch '$BaseBranch' not found." }
    Write-Host "==> Creating new branch '$br' from '$base' in '$Name'..." -ForegroundColor Cyan
    Invoke-Git worktree add --no-track -b $br $Name $base
    Write-Host "    (no upstream yet - set it on first push: git push -u origin $br)" -ForegroundColor DarkGray
}

# --- issue bundle: pull the issue's full resources into the worktree ---
if ($Issue -gt 0 -and -not $NoIssueBundle) {
    Write-Host "==> Fetching issue #$Issue resources into the worktree..." -ForegroundColor Cyan
    try {
        $bundle = Save-IssueBundle -Issue $Issue -Dest $WtPath -Repo $Repo
        Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/ISSUE.md', '/issue-assets/')
        $imgCount = ($bundle.Images | Measure-Object).Count
        Write-Host "    ISSUE.md written; $imgCount screenshot(s) in issue-assets\ (git-excluded)" -ForegroundColor Green
    }
    catch {
        Write-Host "    WARNING: couldn't build issue bundle: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- grouped bundle: per-member ISSUE-<n>.md + issue-<n>-assets\, plus an ISSUES.md cover sheet ---
if ($isGrouped -and -not $NoIssueBundle) {
    Write-Host "==> Fetching resources for grouped wave #$($grouped -join ',#')..." -ForegroundColor Cyan
    $covDb = Join-Path $Hub '.review\coverage.db'
    $memberObjs = @()
    foreach ($n in $grouped) {
        try {
            $b = Save-IssueBundle -Issue $n -Dest $WtPath -Repo $Repo -FileName "ISSUE-$n.md" -AssetsSubdir "issue-$n-assets"
            Write-Host "    ISSUE-$n.md written ($(($b.Images | Measure-Object).Count) screenshot(s))" -ForegroundColor Green
            $ti = $b.Title
        }
        catch { Write-Host "    WARNING: couldn't bundle #${n}: $($_.Exception.Message)" -ForegroundColor Yellow; $ti = "#$n" }
        $o = 'user'; $sv = '-'
        if (Test-Path $covDb) {
            $meta = (& sqlite3 -separator '|' $covDb "SELECT COALESCE(origin,'user'), COALESCE(severity,'-') FROM issue WHERE number=$n;")
            if ($meta) { $o, $sv = $meta -split '\|', 2 }
        }
        $memberObjs += [pscustomobject]@{ Number = $n; Title = $ti; Origin = $o; Severity = $sv }
    }
    # shared owned files + advisory siblings from the ledger (best-effort; advisory, decoupled from the clusters matcher)
    $shared = @(); $sibs = @()
    if (Test-Path $covDb) {
        $inList = ($grouped -join ',')
        $shared = @(& sqlite3 $covDb "SELECT path FROM issue_target WHERE ownership='owns' AND issue_number IN ($inList) GROUP BY path HAVING count(DISTINCT issue_number) > 1;" | Where-Object { $_ })
        $bases = @(@(& sqlite3 $covDb "SELECT DISTINCT path FROM issue_target WHERE ownership='owns' AND issue_number IN ($inList);" | Where-Object { $_ }) | ForEach-Object { ($_ -split '[\\/]')[-1] } | Sort-Object -Unique)
        foreach ($tbl in 'finding', 'recommendation') {
            foreach ($r in @(& sqlite3 -separator '|' $covDb "SELECT id, COALESCE(severity,'-'), replace(COALESCE(scope,''),'|','/'), substr(replace(title,'|','/'),1,50) FROM $tbl WHERE status='proposed';")) {
                if (-not $r) { continue }
                $g = $r -split '\|', 4; $scope = $g[2]
                foreach ($base in $bases) {
                    if ($base -and $scope -like "*$([System.Management.Automation.WildcardPattern]::Escape($base))*") {
                        $sibs += [pscustomobject]@{ Type = $tbl; Id = [int]$g[0]; Sev = $g[1]; Why = 'path'; Title = $g[3] }; break
                    }
                }
            }
        }
        $sibs = @($sibs | Sort-Object Type, Id -Unique)
    }
    $areaGuess = if ($shared.Count -and ($shared[0] -match '[\\/]')) { ($shared[0] -replace '[\\/][^\\/]*$', '') } else { '' }
    $idx = Save-IssuesIndex -Dest $WtPath -Members $memberObjs -SharedPaths $shared -Siblings $sibs -Area $areaGuess
    Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/ISSUE-*.md', '/ISSUES.md', '/issue-*-assets/')
    Write-Host "    ISSUES.md cover sheet written ($($memberObjs.Count) members, $($sibs.Count) advisory sibling(s); git-excluded)" -ForegroundColor Green
}

# --- worktree rules: copy canonical WORKTREE.md in + git-exclude it (force-included via @-mention) ---
$wtRules = Join-Path $Hub 'WORKTREE.md'
if (Test-Path $wtRules) {
    Copy-Item $wtRules (Join-Path $WtPath 'WORKTREE.md') -Force
    Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/WORKTREE.md')
    Write-Host "==> WORKTREE.md copied in (git-excluded; @-mention it in the seed prompt)" -ForegroundColor Green
}
else { Write-Host "==> WARNING: hub WORKTREE.md not found - worktree has no standing-rules file to @-mention." -ForegroundColor Yellow }

# --- expert advisors: copy the hub-* consultant agents into the worktree (git-excluded; consulted in-session) ---
$expertCount = Copy-HubExperts -Hub $Hub -WtPath $WtPath
if ($expertCount -gt 0) {
    Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/.claude/agents/hub-*.md')
    Write-Host "==> $expertCount expert advisor(s) copied into .claude\agents\ (git-excluded)" -ForegroundColor Green
}

# --- copy env files from the base worktree (gitignored secrets are per-folder) ---
if (-not $NoEnv) {
    $copied = @()
    foreach ($f in $HubConfig.envFiles) {
        $src = Join-Path $Hub (Join-Path $HubConfig.baseWorktree $f)
        if (Test-Path $src) { Copy-Item $src (Join-Path $WtPath $f) -Force; $copied += $f }
    }
    if ($copied.Count) { Write-Host "==> Copied from $($HubConfig.baseWorktree)\: $($copied -join ', ')" -ForegroundColor Green }
    else { Write-Host "==> No .env files in $($HubConfig.baseWorktree)\ to copy. Create $($HubConfig.baseWorktree)\.env from $($HubConfig.baseWorktree)\.env.example, then re-seed if needed." -ForegroundColor Yellow }
}

# --- dependencies (per-worktree node_modules) ---
if ($Install) {
    $pm = $HubConfig.packageManager
    if ($pm -ne 'none' -and (Get-Command $pm -ErrorAction SilentlyContinue)) {
        Write-Host "==> Running $($HubConfig.installCmd) in '$Name'..." -ForegroundColor Cyan
        Push-Location $WtPath
        try { & cmd /c $HubConfig.installCmd; if ($LASTEXITCODE -ne 0) { Write-Host "$($HubConfig.installCmd) exited $LASTEXITCODE" -ForegroundColor Yellow } }
        finally { Pop-Location }
    }
    else { Write-Host "==> '$pm' not found on PATH; skipping install. Run '$($HubConfig.installCmd)' inside '$Name' manually." -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Worktree ready: $WtPath  (branch: $br)" -ForegroundColor Green
if ($Issue -gt 0 -and -not $NoIssueBundle) {
    Write-Host "Issue #$Issue resources: $WtPath\ISSUE.md  (+ issue-assets\)" -ForegroundColor Green
}
Write-Host "Next:" -ForegroundColor Green
Write-Host "    cd `"$WtPath`"" -ForegroundColor Green
Write-Host "    & `"$Hub\claude-launch.ps1`"" -ForegroundColor Green
Write-Host ""
if ($isGrouped) {
    Write-Host "Grouped wave members: $($grouped -join ', ')  (briefs: ISSUE-<n>.md + ISSUES.md)" -ForegroundColor Green
    Write-Host "Register on the monitor:" -ForegroundColor Green
    Write-Host "    & `"$Hub\review-coverage.ps1`" register -Worktree $Name -WType solver -Issues $($grouped -join ',') -Branch $br" -ForegroundColor Green
}
Write-Host "Remember to add a row to the Worktree registry in CLAUDE.md." -ForegroundColor DarkGray
