<#
.SYNOPSIS
    Fully RETIRE one or more finished agent worktrees: close the terminal session, remove the worktree,
    delete the leftover folder, optionally delete the branch, and prune - the complete Windows-safe teardown
    that remove-worktree.ps1 does NOT do (it leaves the window open and the node_modules folder on disk).
.DESCRIPTION
    Run from the hub root. For each named worktree this does, in order:
      1. KILL its terminal session - the launcher pwsh window + its claude.exe/node children, bound to the
         worktree by a path-SEGMENT match (+ process-tree descendants) - releasing the CWD lock for deletion.
      2. git worktree remove --force   (on Windows this usually unregisters but leaves the folder).
      3. Git Bash `rm -rf` the leftover folder git left behind (node_modules quirk); Remove-Item fallback.
      4. Optional branch delete (-DeleteBranch).
      5. git worktree prune.
    Batch-capable; -Name accepts wildcards (resolved against the live worktree list).

    SAFETY:
      - Refuses a worktree with UNCOMMITTED changes unless -Force (a dirty tree usually means the session
        is still working - we never silently discard in-progress / unpushed work).
      - Never touches the base/canonical worktree or the bare repo.
      - -DryRun prints exactly what it WOULD kill/remove and changes nothing.
      - -VerifyMerged requires the worktree's PR to be MERGED on GitHub first (gh - squash-merge-aware:
        git ancestry shows squash-merged branches as "ahead", so PR status is the authoritative check).
      - The terminal kill binds processes by a bounded path-SEGMENT match of the worktree folder (NOT a
        bare substring, which prefix-collides, e.g. 'agent' matching 'agent-foo'), plus their process-tree
        descendants, and ALWAYS protects THIS process + its full ancestor chain - so it can never kill the
        orchestrator or a different live worktree's session.
      - Branch delete is safe `-d` by default (refuses unmerged); `-D` only with -Force or -VerifyMerged.
.EXAMPLE
    .\retire-worktree.ps1 -Name issue-564-server-side-rce-via-automation-portal -VerifyMerged -DeleteBranch
.EXAMPLE
    .\retire-worktree.ps1 -Name recon-module-lib-* -DeleteBranch          # batch via wildcard
.EXAMPLE
    .\retire-worktree.ps1 -Name issue-578-next-js-16-2-4-7 -DryRun        # preview only, changes nothing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Name,   # worktree FOLDER name(s); wildcards ok
    [switch]$DeleteBranch,                            # also delete each worktree's local branch
    [switch]$Force,                                   # discard uncommitted changes / force branch delete
    [switch]$VerifyMerged,                            # require a MERGED PR (gh) before retiring
    [string]$Repo,                                    # GitHub repo (owner/repo); defaults to $HubConfig.repo
    [switch]$DryRun                                   # show what would happen; change nothing
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
if (-not $Repo) { $Repo = $HubConfig.repo }

# This process + its FULL ancestor chain must NEVER be killed by the terminal-kill below (don't suicide
# the orchestrator) - important because the kill now expands to process-tree descendants.
$selfPid   = $PID
$parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$selfPid" -ErrorAction SilentlyContinue).ParentProcessId
$parentMap = @{}; foreach ($p in (Get-CimInstance Win32_Process)) { $parentMap[[int]$p.ProcessId] = [int]$p.ParentProcessId }
$protectedPids = @{}; $cur = [int]$selfPid; $hops = 0
while ($cur -and $parentMap.ContainsKey($cur) -and $hops -lt 25) { $protectedPids[$cur] = $true; $cur = $parentMap[$cur]; $hops++ }
if ($parentPid) { $protectedPids[[int]$parentPid] = $true }

# Live worktree folders = source of truth for wildcard expansion + validation.
$liveWts = @(git -C $Hub worktree list --porcelain | Where-Object { $_ -like 'worktree *' } |
    ForEach-Object { Split-Path ($_ -replace '^worktree ', '') -Leaf } |
    Where-Object { $_ -and $_ -ne '.bare' })

$targets = @()
foreach ($n in $Name) {
    $matched = @($liveWts | Where-Object { $_ -like $n })
    if (-not $matched) { Write-Host "!! no live worktree matches '$n' - skipping" -ForegroundColor Yellow; continue }
    $targets += $matched
}
$targets = @($targets | Select-Object -Unique | Where-Object { $_ -ne $HubConfig.baseWorktree })
if (-not $targets) { Write-Host "Nothing to retire." -ForegroundColor Yellow; return }

Write-Host ("=== retire-worktree {0}=== targets: {1}" -f $(if ($DryRun) { '[DRY RUN] ' } else { '' }), ($targets -join ', ')) -ForegroundColor Cyan
$bash = (Get-Command bash -ErrorAction SilentlyContinue).Source

$results = foreach ($folder in $targets) {
    $wtPath = Join-Path $Hub $folder
    $row = [ordered]@{ worktree = $folder; killed = 0; folder = '-'; branch = '-' }
    $branch = $null

    if (Test-Path $wtPath) {
        $branch = (& git -C $wtPath rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { $branch = $null }

        # SAFETY: never retire a worktree with uncommitted work unless -Force (dirty == probably still working).
        $dirty = ((& git -C $wtPath status --porcelain 2>$null) | Out-String).Trim()
        if ($dirty -and -not $Force) {
            Write-Host "!! '$folder' has UNCOMMITTED changes - SKIPPING (commit/push, or pass -Force to discard)." -ForegroundColor Yellow
            $row.folder = 'SKIP (dirty)'; [pscustomobject]$row; continue
        }
    }

    if ($VerifyMerged) {
        if (-not $branch -or $branch -eq 'HEAD') {
            Write-Host "!! '$folder' has no normal branch - can't verify a merged PR; SKIPPING." -ForegroundColor Yellow
            $row.folder = 'SKIP (no branch)'; [pscustomobject]$row; continue
        }
        $mergedCount = (& gh pr list --repo $Repo --head $branch --state merged --json number --jq 'length' 2>$null)
        if ("$mergedCount".Trim() -in @('', '0')) {
            Write-Host "!! '$folder' ($branch) has NO merged PR on $Repo - SKIPPING (-VerifyMerged). Drop -VerifyMerged to override." -ForegroundColor Yellow
            $row.folder = 'SKIP (not merged)'; [pscustomobject]$row; continue
        }
    }

    # --- 1. kill the terminal session (release the CWD lock) ---
    # Bind processes to THIS worktree by a bounded path-SEGMENT match, NOT a bare substring: a substring
    # match (.Contains) prefix-collides - retiring 'agent' would also match (and kill) a live 'agent-foo'
    # session. Mirror cleanup-worktree-processes.ps1's Get-WorktreeRef - the folder must appear as a
    # launcher path (\.launchers\<folder>.ps1), a `Worktree: <folder>` token, or a real path segment
    # (\<folder>\, \<folder>", \<folder><end>). Then expand to DESCENDANTS so the claude.exe/node children
    # (whose own command line lacks the folder, but whose CWD is the worktree so they hold the lock too)
    # are killed via the process tree.
    # Boundary = "not followed by a folder-name char" ([A-Za-z0-9._-]), so 'agent' never matches inside
    # 'agent-foo'; the launcher form <folder>.ps1 is allowed explicitly (its trailing '.' is a name char).
    $esc = [regex]::Escape($folder)
    $boundRe = '(?i)(?:[\\/]' + $esc + '(?:\.ps1|(?![A-Za-z0-9._-])))|(?:Worktree:\s*' + $esc + '(?![A-Za-z0-9._-]))'
    $allProcs = @(Get-CimInstance Win32_Process)
    $byId = @{}; foreach ($p in $allProcs) { $byId[[int]$p.ProcessId] = $p }
    $childrenOf = @{}
    foreach ($p in $allProcs) {
        $pp = [int]$p.ParentProcessId
        if (-not $childrenOf.ContainsKey($pp)) { $childrenOf[$pp] = New-Object System.Collections.Generic.List[int] }
        $childrenOf[$pp].Add([int]$p.ProcessId)
    }
    $boundIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($p in $allProcs) {
        if (-not $p.CommandLine -or $p.CommandLine -notmatch $boundRe) { continue }
        $stack = New-Object System.Collections.Stack; [void]$stack.Push([int]$p.ProcessId)
        while ($stack.Count) {
            $id = [int]$stack.Pop()
            if (-not $boundIds.Add($id)) { continue }   # already visited
            if ($childrenOf.ContainsKey($id)) { foreach ($c in $childrenOf[$id]) { [void]$stack.Push($c) } }
        }
    }
    $procs = @($boundIds | Where-Object { -not $protectedPids.ContainsKey($_) } | ForEach-Object { $byId[$_] })
    $row.killed = $procs.Count
    if ($DryRun) {
        foreach ($p in $procs) { Write-Host "   [dry] kill PID $($p.ProcessId) [$($p.Name)]" -ForegroundColor DarkGray }
        Write-Host "   [dry] remove worktree + folder '$folder'$(if ($DeleteBranch -and $branch) { " + branch '$branch'" })" -ForegroundColor DarkGray
        $row.folder = 'dry-run'; $row.branch = $(if ($DeleteBranch -and $branch) { "would delete $branch" } else { '-' })
        [pscustomobject]$row; continue
    }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($procs.Count) { Start-Sleep -Milliseconds 400 }   # let the OS release file handles before removal

    # --- 2. unregister the worktree (ignore exit code: usually unregisters but leaves the folder on disk) ---
    & git -C $Hub worktree remove --force $folder 2>&1 | Out-Null

    # --- 3. delete the leftover folder git left behind (node_modules quirk) ---
    if (Test-Path $wtPath) {
        if ($bash) {
            $bashPath = '/' + $wtPath.Substring(0, 1).ToLower() + ($wtPath.Substring(2) -replace '\\', '/')
            & $bash -c "rm -rf '$bashPath'" 2>$null
        }
        if (Test-Path $wtPath) { try { Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction Stop } catch {} }
    }
    $row.folder = if (Test-Path $wtPath) { 'LEFTOVER (locked?)' } else { 'removed' }

    # --- 4. optional branch delete (safe -d default; -D only when merge is confirmed/forced) ---
    if ($DeleteBranch -and $branch -and $branch -ne $HubConfig.defaultBranch -and $branch -ne 'HEAD') {
        if ($Force -or $VerifyMerged) { & git -C $Hub branch -D $branch 2>&1 | Out-Null }
        else { & git -C $Hub branch -d $branch 2>&1 | Out-Null }
        $row.branch = if ($LASTEXITCODE -eq 0) { "deleted $branch" } else { "KEPT $branch (unmerged? use -Force)" }
    }

    [pscustomobject]$row
}

if (-not $DryRun) { & git -C $Hub worktree prune 2>&1 | Out-Null }

Write-Host ""
$results | Format-Table -AutoSize
Write-Host ""
if ($DryRun) { Write-Host "DRY RUN - nothing changed. Re-run without -DryRun to retire." -ForegroundColor Yellow }
else { Write-Host "Done. Update the Worktree registry in CLAUDE.md (remove the retired rows)." -ForegroundColor DarkGray }
