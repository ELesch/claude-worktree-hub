<#
.SYNOPSIS
    Create AND launch a child worktree to break a large, independent piece off a complex worktree.
.DESCRIPTION
    Called by a COMPLEX worktree's agent (after its plan/breakdown was approved at the gate) to
    decompose a genuinely large, independent piece into its own worktree + session. Prefer in-process
    SUBAGENTS for ordinary parallelism; use this only for big separately-reviewable pieces.

    The child branches off the PARENT's branch (so the parent integrates the work), is named
    "<parent>--<name>", copies env from the base worktree, gets a launcher, and (unless -NoLaunch)
    opens a window via the bundled claude-launch.ps1 wrapper. A hard DEPTH CAP (default 2, counted
    by "--" in the parent name) prevents runaway recursion - beyond it, use subagents instead.
.EXAMPLE
    # from inside a parent worktree, the agent runs (its own folder name is the -Parent):
    & <hub root>\spawn-child.ps1 -Parent issue-NNN-foo -Name auth -Title "auth layer" `
        -Task "Implement the auth layer described in PLAN.md section 2 ..." -Complex
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Parent,   # parent worktree FOLDER name
    [Parameter(Mandatory = $true)][string]$Name,     # short child piece name (kebab)
    [Parameter(Mandatory = $true)][string]$Title,    # tab/window title for the child
    [Parameter(Mandatory = $true)][string]$Task,     # the piece's task brief (multi-line ok)
    [switch]$Complex,                                # child is itself complex -> gated workflow + /superpowers
    [switch]$NoLaunch,                               # create only, don't open a window
    [int]$MaxDepth = 2,
    [int]$MaxChildren = 6,                           # siblings-per-parent cap (fan-out backstop)
    [switch]$AllowDirtyParent                        # allow spawning even if the parent has uncommitted work
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
. (Join-Path $Hub 'hub-lib.ps1')

# --- depth guard (recursion backstop) ---
$parentDepth = ([regex]::Matches($Parent, '--')).Count
if (($parentDepth + 1) -gt $MaxDepth) {
    throw "Depth cap reached: parent '$Parent' is at depth $parentDepth (max $MaxDepth). Use in-process subagents for this piece instead of a child worktree."
}

$parentPath = Join-Path $Hub $Parent
if (-not (Test-Path $parentPath)) { throw "Parent worktree '$Parent' not found under the hub." }
$parentBranch = (& git -C $parentPath rev-parse --abbrev-ref HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $parentBranch) { throw "Could not resolve parent branch for '$Parent'." }

# Parent must have a committed baseline - children branch off its committed TIP, not its working tree.
if (-not $AllowDirtyParent) {
    $dirty = ((& git -C $parentPath status --porcelain) | Out-String).Trim()
    if ($dirty) { throw "Parent '$Parent' has uncommitted changes - children would branch off a STALE base. Commit a baseline first, or pass -AllowDirtyParent." }
}

# Siblings cap (fan-out backstop; depth is capped separately by MaxDepth).
$siblings = @(git -C $Hub worktree list | Where-Object { $_ -match [regex]::Escape("$Parent--") }).Count
if ($siblings -ge $MaxChildren) { throw "Siblings cap: '$Parent' already has $siblings child worktree(s) (max $MaxChildren). Use in-process subagents for further parallelism." }

# Integration model (child -> parent): the parent branch must exist on origin so children can PR into it.
& git -C $Hub show-ref --verify --quiet "refs/remotes/origin/$parentBranch"
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> Pushing parent branch '$parentBranch' to origin (so children can PR into it)..." -ForegroundColor Cyan
    & git -C $parentPath push -u origin $parentBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: couldn't push '$parentBranch' - children can't open PRs into it until it is pushed." -ForegroundColor Yellow }
}

$childFolder = "$Parent--$Name"
$childPath = Join-Path $Hub $childFolder
if (Test-Path $childPath) { throw "Child worktree '$childFolder' already exists." }
$childBranch = "$parentBranch-$Name"

Write-Host "==> Creating child '$childFolder' on '$childBranch' (off parent branch '$parentBranch')..." -ForegroundColor Cyan
& git -C $Hub worktree add --no-track -b $childBranch $childFolder $parentBranch
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for child '$childFolder'." }

# copy env from the base worktree (gitignored, per-folder)
foreach ($f in $HubConfig.envFiles) {
    $src = Join-Path $Hub (Join-Path $HubConfig.baseWorktree $f)
    if (Test-Path $src) { Copy-Item $src (Join-Path $childPath $f) -Force }
}

# copy the canonical standing-rules file (force-included via @-mention; the /WORKTREE.md exclude is hub-global)
$wtRules = Join-Path $Hub 'WORKTREE.md'
if (Test-Path $wtRules) { Copy-Item $wtRules (Join-Path $childPath 'WORKTREE.md') -Force }
$expertCount = Copy-HubExperts -Hub $Hub -WtPath $childPath
if ($expertCount -gt 0) { Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/.claude/agents/hub-*.md') }

# --- build the child's seeded prompt ---
if ($Complex) {
    $preamble = if ($HubConfig.complexPromptPreamble) { $HubConfig.complexPromptPreamble + "`n`n" } else { '' }
    $promptBody = @"
${preamble}@WORKTREE.md

Follow the standing rules in WORKTREE.md (force-included above): the quality bar, completion-report format,
hub-ledger recording, env note, and hard constraints. CHILD OVERRIDE: open your PR with base = the parent
branch '$parentBranch' (NOT $($HubConfig.defaultBranch)); the parent integrates the children and opens the single PR to $($HubConfig.defaultBranch).

You are an autonomous coding agent in a dedicated CHILD git worktree for $($HubConfig.repo) - one piece of
a larger task decomposed by the parent worktree '$Parent'.
Worktree: $childPath
Branch:   $childBranch  (branched off the parent; every commit here lands on this branch)

Your assigned piece:
$Task

This piece is COMPLEX, so follow the gated workflow (see CLAUDE.md "Complex worktree workflow"):
1. Research the relevant code; write SPEC.md and PLAN.md for THIS piece.
2. Present your key decisions and STOP for the user's verification/correction BEFORE implementing.
3. After approval: implement using in-process SUBAGENTS for parallel work (the default). For a
   genuinely large, independent, file-disjoint sub-piece - and only after the user approves it - spawn
   a grandchild worktree (it is started properly for you: wrapper, tab, seeded prompt):
       & $Hub\spawn-child.ps1 -Parent $childFolder -Name <piece> -Title "<tab>" -Task "<brief>" [-Complex]
   Commit a clean baseline first (the helper refuses a dirty parent). Grandchildren PR into '$childBranch';
   you assemble them, then PR up to '$parentBranch'. Respect the depth/siblings caps - prefer subagents.
4. $($HubConfig.installCmd) if needed; validate with $($HubConfig.verifyCmd) + tests; commit, push, and open a PR whose BASE is
   the parent branch '$parentBranch'  ->  gh pr create --base $parentBranch   (NOT $($HubConfig.defaultBranch)). Do NOT merge.
NEVER apply a database migration to production, and NEVER run a headless 'claude --print' session.
Begin with research and planning.
"@
}
else {
    $promptBody = @"
@WORKTREE.md

Follow the standing rules in WORKTREE.md (force-included above): the quality bar, completion-report format,
hub-ledger recording, env note, and hard constraints. CHILD OVERRIDE: open your PR with base = the parent
branch '$parentBranch' (NOT $($HubConfig.defaultBranch)); the parent integrates the children and opens the single PR to $($HubConfig.defaultBranch).

You are an autonomous coding agent in a dedicated CHILD git worktree for $($HubConfig.repo) - one piece of
a larger task decomposed by the parent worktree '$Parent'.
Worktree: $childPath
Branch:   $childBranch  (branched off the parent; every commit here lands on this branch)

Your assigned piece:
$Task

1. Run: $($HubConfig.installCmd)   (fresh worktree).
2. Implement per the repo's conventions (project CLAUDE.md), using subagents for parallel work.
3. Validate: $($HubConfig.verifyCmd) (typecheck + lint) + any relevant tests.
4. Commit, push, and open a PR whose BASE is the parent branch '$parentBranch'  ->
   gh pr create --base $parentBranch   (NOT $($HubConfig.defaultBranch)); reference the parent task. Do NOT merge.
5. FINISH with a COMPLETION REPORT as your last output, rendered by the shared box-table tool so every
   worktree matches:  & $Hub\format-report.ps1 -Title '<piece> - completion' -Rows 'Piece|...',
   'Changes|<N> files', 'Verify|<OK/X> typecheck . lint', 'Tests|...', 'PR|#<M> <url> (base $parentBranch, not merged)',
   'Status|pushed + PR opened'   (use the real values; mark pass/fail honestly). Also list any OUT-OF-SCOPE
   problems you found but did NOT fix as recommended follow-ups (second table + a section in your PR body).
   Report to the hub ledger too: & $Hub\review-coverage.ps1 progress -Worktree $childFolder -Status pr-open -Pr <M>
   and (per follow-up) & $Hub\review-coverage.ps1 recommend -Worktree $childFolder -Title '<title>' -Area '<area>' -Severity '<sev>' -Detail '<why>'.
NEVER apply a database migration to production, and NEVER run a headless 'claude --print' session. If the
piece turns out larger or more architectural than expected, write SPEC.md + PLAN.md and STOP for review first.
Begin.
"@
}

# --- write the child launcher (generated .ps1) ---
$launchersDir = Join-Path $Hub '.launchers'
if (-not (Test-Path $launchersDir)) { New-Item -ItemType Directory -Force -Path $launchersDir | Out-Null }
$launcherPath = Join-Path $launchersDir "$childFolder.ps1"

# NOTE: outer @"..."@ terminates only on a line that is exactly "@; the inner @' / '@ are literal text.
$launcherContent = @"
# Child launcher for '$childFolder' (parent: $Parent) - generated by spawn-child.ps1. Re-runnable.
`$Host.UI.RawUI.WindowTitle = '$Title'
Set-Location '$childPath'
`$prompt = @'
$promptBody
'@
& "$Hub\claude-launch.ps1" $(Get-LaunchFlags) --name '$Title' `$prompt
"@
[System.IO.File]::WriteAllText($launcherPath, $launcherContent, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "    child ready: $childPath  (branch: $childBranch)" -ForegroundColor Green
Write-Host "    launcher:    $launcherPath" -ForegroundColor Green

# Register the child on the SQLite monitor so `review-coverage.ps1 monitor` tracks it (best-effort).
try { & (Join-Path $Hub 'review-coverage.ps1') register -Worktree $childFolder -WType child -Branch $childBranch | Out-Null } catch {}

if (-not $NoLaunch) {
    Start-Process -FilePath 'pwsh' -ArgumentList '-NoExit', '-File', $launcherPath | Out-Null
    Write-Host "    launched window '$Title'." -ForegroundColor Green
}
else {
    Write-Host "    (-NoLaunch) start it later with: Start-Process pwsh -ArgumentList '-NoExit','-File','$launcherPath'" -ForegroundColor DarkGray
}
