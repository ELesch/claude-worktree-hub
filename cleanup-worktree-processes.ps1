<#
.SYNOPSIS
    Completely sweep and kill processes left behind by CLOSED/retired worktree sessions.
.DESCRIPTION
    Run from the hub root. This is the COMPLETE cleanup that retire-worktree.ps1's
    per-folder "CommandLine.Contains(folder)" kill does NOT guarantee: it also catches node build/test
    children that don't carry the folder name, and processes orphaned when a window was closed by hand
    (so retire never ran for them).

    HOW IT DECIDES (source of truth = `git worktree list`):
      OPEN worktrees   -> their whole process trees are KEPT (active sessions).
      CLOSED worktrees -> any process bound to one is an ORPHAN and is killed (with its descendant tree).

    A process is BOUND to worktree W when ANY of these hold:
      * command line contains  \.launchers\<W>.ps1
      * command line contains  "Worktree: <W>"  or  Set-Location '...\<hub>\<W>'
      * command line contains a path  ...\<hub>\<W>\...
      * it descends (process tree) from a process already bound to W
    ORPHAN = bound to a W that is NOT currently open (and not the hub root / a dotfile dir).

    SAFETY:
      * Protects the orchestrator: THIS process + its full ancestor chain + all its descendants are never killed.
      * Protects every OPEN worktree's process tree (bound to a live worktree => never an orphan).
      * Never kills a process it cannot bind to a closed worktree (e.g. your other interactive `claude`
        sessions, MCP servers, unrelated node) -- those are reported under "left running", never killed.
      * DRY RUN by default. Pass -Execute to actually kill. -DryRun is accepted as an explicit no-op alias.

.PARAMETER Execute     Actually kill. Without it, prints what it WOULD kill and changes nothing.
.PARAMETER NoNode      Do not consider node.exe (only sweep pwsh + claude.exe). Default: node included.
.PARAMETER IncludeStrayNode
    Also kill LEAKED long-running test/dev node - the "spawned for testing but never exits" class
    (vitest/jest watch, `next dev|start`, vite, nodemon, webpack serve, `<verifyCmd>`, etc.) whose PARENT
    PROCESS IS DEAD and which binds to no open worktree. Precise + safe: an ACTIVE session's dev server
    stays bound (open window => live ancestor) or has a live parent, and short-lived build workers
    (tsc/eslint/<verifyCmd>/<testCmd>) never match the runner list - so this only reaps genuine
    orphans from a closed window. Opt-in because killing a watcher is irreversible for that run.
.PARAMETER NoSignalCleanup  Skip removing stale ~/.claude/hooks/tab-color-signal-<pid> files for dead PIDs.
.EXAMPLE
    .\cleanup-worktree-processes.ps1                 # preview (dry run)
    .\cleanup-worktree-processes.ps1 -Execute        # do the cleanup
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$DryRun,
    [switch]$NoNode,
    [switch]$IncludeStrayNode,   # also kill LEAKED long-running test/dev node (watch/dev-server) whose
                                 # parent is dead and which binds to no OPEN worktree (see note below)
    [switch]$NoSignalCleanup
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
$doKill = $Execute -and -not $DryRun

# Hub folder name (leaf) - used to match this hub's paths in process command lines.
$hubLeaf = Split-Path $Hub -Leaf

# Long-running runners that DON'T self-exit (the "spawned for testing but never exits" class). Short-lived
# build workers (tsc/eslint/<verifyCmd>/<testCmd>) are deliberately NOT here - they finish on their own.
# The package-manager prefixes (npm/yarn/bun/<pm>) are kept generic so this works across stacks.
$strayNodeRe = '(?i)(vitest(?!\s+run)|jest\b(?!.*--(ci|run))|mocha\s+--watch|--watch\b|nodemon|ts-node-dev|' +
               'next\s+(dev|start)|vite(\s+(dev|preview))?\b|webpack(-dev-server|\s+serve)|' +
               '(npm|yarn|bun|[a-z]+)(\.cjs)?\s+(run\s+)?dev|concurrently)'

# --- 1. OPEN worktrees (source of truth) ------------------------------------------------------
$live = @(& git -C $Hub worktree list --porcelain 2>$null | Where-Object { $_ -like 'worktree *' } |
    ForEach-Object { Split-Path ($_ -replace '^worktree ', '') -Leaf } |
    Where-Object { $_ -and $_ -ne '.bare' })
if (-not $live) { Write-Host "!! Could not read 'git worktree list' from $Hub - aborting (refusing to guess)." -ForegroundColor Red; return }
$excludedSeg = @('.launchers', '.bare', '.git', '.claude', '.review', '.issue-images', '.vscode', 'node_modules')
Write-Host "OPEN worktrees (kept): $($live -join ', ')" -ForegroundColor Cyan

# --- 2. snapshot every process once -----------------------------------------------------------
$all = Get-CimInstance Win32_Process
$byId = @{}; $childrenOf = @{}
foreach ($p in $all) {
    $id = [int]$p.ProcessId; $pp = [int]$p.ParentProcessId
    $byId[$id] = $p
    if (-not $childrenOf.ContainsKey($pp)) { $childrenOf[$pp] = [System.Collections.ArrayList]::new() }
    [void]$childrenOf[$pp].Add($id)
}
function Get-Descendants([int]$root) {
    $seen = @{}; $stack = [System.Collections.Stack]::new(); $stack.Push($root)
    while ($stack.Count) {
        $cur = $stack.Pop()
        if ($childrenOf.ContainsKey($cur)) {
            foreach ($c in $childrenOf[$cur]) { if (-not $seen.ContainsKey($c)) { $seen[$c] = $true; $stack.Push($c) } }
        }
    }
    return @($seen.Keys)
}

# --- 3. protect the orchestrator (self + ancestors + descendants) -----------------------------
$protected = @{ $PID = $true }
$cur = $PID
for ($i = 0; $i -lt 25 -and $cur -and $byId.ContainsKey($cur); $i++) { $protected[$cur] = $true; $cur = [int]$byId[$cur].ParentProcessId }
foreach ($d in (Get-Descendants $PID)) { $protected[$d] = $true }

# --- 4. bind processes to a worktree by command line ------------------------------------------
function Get-WorktreeRef([string]$cl) {
    if (-not $cl) { return $null }
    if ($cl -match '(?i)\\\.launchers\\([^\\"'' ]+)\.ps1') { return $Matches[1] }
    if ($cl -match '(?i)Worktree:\s*([A-Za-z0-9._-]+)')    { return $Matches[1] }
    # Match paths containing the hub folder name as a path segment (e.g. ...\<hub>\<worktree>\...)
    if ($cl -match ('(?i)' + [regex]::Escape($hubLeaf) + '[\\/]([A-Za-z0-9._-]+)')) {
        $seg = $Matches[1]
        if ($excludedSeg -notcontains $seg) { return $seg }
    }
    return $null
}
$names = if ($NoNode) { @('pwsh.exe', 'claude.exe') } else { @('pwsh.exe', 'claude.exe', 'node.exe') }
$cands = @($all | Where-Object { $names -contains $_.Name })
$attr = @{}
# Seed binding from EVERY process (not just kill candidates) so a node/claude child can inherit the
# worktree from any ancestor that named it - e.g. a shim whose own command line carries
# the hub path (like `.../<hub>/issue-N && <verify>`) even though node's does not.
foreach ($p in $all) { $w = Get-WorktreeRef ([string]$p.CommandLine); if ($w) { $attr[[int]$p.ProcessId] = $w } }
# propagate binding down the tree: a child inherits its nearest bound ancestor
foreach ($p in $cands) {
    $id = [int]$p.ProcessId
    if ($attr.ContainsKey($id)) { continue }
    $a = [int]$p.ParentProcessId; $hops = 0
    while ($a -and $byId.ContainsKey($a) -and $hops -lt 25) {
        if ($attr.ContainsKey($a)) { $attr[$id] = $attr[$a]; break }
        $a = [int]$byId[$a].ParentProcessId; $hops++
    }
}

# --- 5. classify --------------------------------------------------------------------------------
$killSet = @{}     # pid -> worktree   (orphans + their descendant trees)
$leftRunning = [System.Collections.ArrayList]::new()
foreach ($p in $cands) {
    $id = [int]$p.ProcessId
    if ($protected.ContainsKey($id)) { continue }
    if ($attr.ContainsKey($id)) {
        $w = $attr[$id]
        if ($live -contains $w) { continue }          # bound to an OPEN worktree -> keep
        $killSet[$id] = $w
        foreach ($d in (Get-Descendants $id)) { if (-not $protected.ContainsKey($d)) { $killSet[$d] = $w } }
    }
    else {
        # Unbound candidate. By default we NEVER kill these - surface for transparency.
        # EXCEPTION (-IncludeStrayNode): a node.exe running a known never-exiting runner (watch/dev server)
        # whose PARENT IS DEAD is a leaked test/dev process from a CLOSED worktree window. An ACTIVE
        # worktree's dev server stays bound (window open => live ancestor) or has a LIVE parent, so this
        # never touches running sessions or short-lived build workers (those don't match $strayNodeRe).
        $cl = [string]$p.CommandLine
        $parentAlive = $byId.ContainsKey([int]$p.ParentProcessId)
        if ($IncludeStrayNode -and $p.Name -eq 'node.exe' -and -not $parentAlive -and $cl -match $strayNodeRe) {
            $killSet[$id] = '(stray long-running node - parent dead)'
        }
        else {
            [void]$leftRunning.Add([pscustomobject]@{ PID = $id; Name = $p.Name; Cmd = $cl })
        }
    }
}

# --- 6. act -------------------------------------------------------------------------------------
Write-Host ""
if ($killSet.Count -eq 0) {
    Write-Host "No orphaned worktree processes found. Nothing to clean." -ForegroundColor Green
}
else {
    Write-Host ("{0} orphaned process(es) from CLOSED worktrees:" -f $killSet.Count) -ForegroundColor Yellow
    $rows = foreach ($id in $killSet.Keys) {
        $pp = if ($byId.ContainsKey($id)) { $byId[$id].Name } else { '?' }
        [pscustomobject]@{ PID = $id; Name = $pp; ClosedWorktree = $killSet[$id] }
    }
    $rows | Sort-Object ClosedWorktree, Name | Format-Table -AutoSize | Out-String | Write-Host
    if ($doKill) {
        # kill leaves first: order by descendant count ascending
        $ordered = $killSet.Keys | Sort-Object { (Get-Descendants $_).Count }
        foreach ($id in $ordered) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }
        Start-Sleep -Milliseconds 400
        $survivors = @($killSet.Keys | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($survivors) {
            foreach ($id in $survivors) { & taskkill /PID $id /T /F 2>$null | Out-Null }
            Start-Sleep -Milliseconds 200
            $survivors = @($killSet.Keys | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        }
        if ($survivors) { Write-Host ("!! still alive after kill: {0} - may need elevation" -f ($survivors -join ', ')) -ForegroundColor Red }
        else { Write-Host "All orphaned worktree processes terminated." -ForegroundColor Green }
    }
    else { Write-Host "DRY RUN - nothing killed. Re-run with -Execute to terminate the above." -ForegroundColor Yellow }
}

# --- 7. stale tab-color-signal files for dead PIDs --------------------------------------------
if (-not $NoSignalCleanup) {
    $sigDir = Join-Path $env:USERPROFILE '.claude\hooks'
    if (Test-Path $sigDir) {
        $stale = @(Get-ChildItem $sigDir -Filter 'tab-color-signal-*' -ErrorAction SilentlyContinue | Where-Object {
            $sp = ($_.Name -replace 'tab-color-signal-', '')
            $sp -match '^\d+$' -and -not (Get-Process -Id ([int]$sp) -ErrorAction SilentlyContinue)
        })
        if ($stale.Count) {
            Write-Host ("`n{0} stale tab-color-signal file(s) for dead PIDs{1}" -f $stale.Count, $(if ($doKill) { ' - removing' } else { ' (dry run)' })) -ForegroundColor DarkGray
            if ($doKill) { $stale | Remove-Item -Force -ErrorAction SilentlyContinue }
        }
    }
}

# --- 8. transparency: candidates left running (never auto-killed) -----------------------------
if ($leftRunning.Count) {
    Write-Host ("`nLeft running (NOT bound to any closed worktree - review manually if unexpected):") -ForegroundColor DarkGray
    $leftRunning | ForEach-Object {
        $c = $_.Cmd; if ($c.Length -gt 90) { $c = $c.Substring(0, 90) + ' …' }
        Write-Host ("   PID {0,-6} {1,-11} {2}" -f $_.PID, $_.Name, $c) -ForegroundColor DarkGray
    }
}
