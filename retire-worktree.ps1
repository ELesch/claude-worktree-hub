<#
.SYNOPSIS
    Fully RETIRE one or more finished agent worktrees: close the terminal session, remove the worktree,
    delete the leftover folder, optionally delete the branch, and prune - the complete Windows-safe teardown
    that remove-worktree.ps1 does NOT do (it leaves the window open and the node_modules folder on disk).
.DESCRIPTION
    Run from the hub root. For each named worktree this does, in order:
      1. KILL its terminal session - the launcher pwsh window + its claude.exe child, matched by the
         worktree folder name in the process command line - releasing the CWD lock that blocks deletion.
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
      - The terminal kill matches ONLY processes whose command line contains the worktree folder name and
        ALWAYS excludes THIS process + its parent, so it can never kill the orchestrator session.
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

# This process + its parent must NEVER be killed by the terminal-kill below (don't suicide the orchestrator).
$selfPid   = $PID
$parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$selfPid" -ErrorAction SilentlyContinue).ParentProcessId

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
    $procs = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $selfPid -and $_.ProcessId -ne $parentPid -and
        $_.CommandLine -and $_.CommandLine.Contains($folder)
    })
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
