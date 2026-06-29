# Issue Grouping (Overlap Clusters) — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `issue clusters` sub-command to `review-coverage.ps1` that *proposes* grouped waves — connected components of approved, simple-track, file-overlapping issues (capped), each with same-area proposed findings/recs surfaced as advisory extras.

**Architecture:** A pure compute helper `Get-IssueClusterPlan -Db -MaxI -MaxF` reads the ledger and returns a structured plan (clusters / singletons / not-grouped / deferred + lookup maps), with **no writes**. A thin `'clusters'` case in the existing `issue` sub-command `switch` renders that plan as colored `Write-Host` output (same family as `issue next`) and writes exactly one `activity` row. No schema change; `issue next` is untouched.

**Tech Stack:** PowerShell 7, SQLite (`sqlite3` CLI), Pester v5.7.1 (saved module at `C:\mydev\pester-modules`).

**Spec:** `docs/superpowers/specs/2026-06-29-issue-grouping-phase1-design.md`

---

## Conventions (read once before starting)

- **Run tests** (full suite, ~75–100s — each `It` inits a fresh temp DB):
  ```powershell
  Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1
  Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
  ```
  Faster iteration on just the new block:
  ```powershell
  Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'
  ```
- **Test pattern** (matches the existing suite): `New-TempDb` (defined in the file's `BeforeAll`) inits a ledger; drive the script with `& $script:rc issue clusters -DbPath $db`; capture `Write-Host` output with `6>&1` then `-join "\`n"`; assert DB state with `& sqlite3 -separator '|' $db "SELECT …"`.
- **PowerShell/sqlite rules** (from CLAUDE.md Lessons): native `sqlite3`/`git`/`gh` exit codes do **not** trip `$ErrorActionPreference='Stop'` — the script's `Exec`/`Scalar` helpers already check `$LASTEXITCODE`; reuse them. The `q` helper escapes single quotes for SQL. Use `& sqlite3 $Db "…"` (plain) for reads, exactly as the `'next'` case does.
- **Branch:** all work is on `feature/issue-grouping-phase1` (already created; the spec is committed there).
- Line numbers below are from the current `review-coverage.ps1`; if they have drifted, locate by the quoted anchor text.

## File Structure

| File | Change |
|------|--------|
| `review-coverage.ps1` | **Modify.** Param block (~L38–46): add `-MaxIssues`/`-MaxFiles`. After `NullableInt` (~L89), before `switch ($Command)`: add `Get-IssueClusterPlan`. Inside the `issue` inner `switch`, after the `'next'` case (~L595): add the `'clusters'` case. Update the `issue` help string (~L597) and the top-level usage (~L611). |
| `review-coverage.Tests.ps1` | **Modify.** Append a `Describe 'issue clusters'` block. |
| `CLAUDE.md` | **Modify.** One-line pointer that `issue clusters` is the grouped-wave companion to `issue next`. |

The compute (`Get-IssueClusterPlan`) and render (`'clusters'` case) are separate units with one responsibility each: compute is pure/read-only and holds all the graph logic; render only formats + writes the single activity row. Tests exercise both through the public command.

---

## Task 1: Wiring — params, render case, stub helper, top-level strings

Establish the command end-to-end with an **empty** compute stub, so the wiring (dispatch, params, render skeleton, the single activity write, read-only invariant) is proven before any algorithm lands. The render case written here is **final** — later tasks only fill in the compute helper, whose richer output the render already handles.

**Files:**
- Modify: `review-coverage.ps1` (param block; new function; new case; two help strings)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'issue clusters' {
    It 'prints the header, writes one activity row, and mutates nothing else (empty ledger)' {
        $db = New-TempDb
        $before = & sqlite3 $db "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM activity);"
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Proposed grouped waves'
        $out | Should -Match 'nothing approved to group'
        (& sqlite3 $db "SELECT event FROM activity WHERE event='clusters';") | Should -Be 'clusters'
        (& sqlite3 $db "SELECT count(*) FROM activity;") | Should -Be '1'
        $before | Should -Be '0/0'   # nothing existed before the run
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: FAIL — `issue clusters` is an unknown sub-command (the inner `switch` hits its `default`, no `clusters` event row).

- [ ] **Step 3: Add the two params**

In the `param(...)` block, find:

```powershell
    [string]$Targets, [string]$Reads, [string]$Effort, [string]$Track,   # issue-review fields
```

Add immediately after it:

```powershell
    [int]$MaxIssues = 4, [int]$MaxFiles = 8,                              # issue clusters: per-cluster caps
```

- [ ] **Step 4: Add the stub compute helper**

Find the line `function NullableInt([int]$v) { if ($v -gt 0) { "$v" } else { 'NULL' } }` (~L89). Insert **after** it (before `switch ($Command)`):

```powershell
# Read-only: compute a grouped-wave PROPOSAL from the ledger (no writes). Returns clusters (file-overlapping
# approved+simple issues, capped), singletons, not-grouped (complex/no-path), and deferrals, plus lookup maps.
function Get-IssueClusterPlan([string]$Db, [int]$MaxI, [int]$MaxF) {
    # Task 1 stub — filled in by Tasks 2 (compute) and 3 (siblings).
    return [pscustomobject]@{
        Clusters = @(); Singletons = @(); NotGrouped = @()
        DeferOverCap = @(); DeferInFlight = @(); Meta = @{}; OwnPaths = @{}
    }
}
```

- [ ] **Step 5: Add the `'clusters'` render case**

In the `issue` inner `switch ($Sub)`, find the end of the `'next'` case (the line `}` that closes it, just before `default { Write-Host "issue sub-commands: …` ~L597). Insert this case **between** them:

```powershell
            'clusters' {
                $maxI = if ($MaxIssues -ge 1) { $MaxIssues } else { 4 }
                $maxF = if ($MaxFiles  -ge 1) { $MaxFiles  } else { 8 }
                if ($PSBoundParameters.ContainsKey('MaxIssues') -and $MaxIssues -lt 1) { Write-Host "(-MaxIssues < 1 ignored; using 4)" -ForegroundColor DarkYellow }
                if ($PSBoundParameters.ContainsKey('MaxFiles')  -and $MaxFiles  -lt 1) { Write-Host "(-MaxFiles < 1 ignored; using 8)"  -ForegroundColor DarkYellow }

                $plan = Get-IssueClusterPlan -Db $db -MaxI $maxI -MaxF $maxF
                $meta = $plan.Meta; $own = $plan.OwnPaths
                $clusters = @($plan.Clusters); $singletons = @($plan.Singletons); $notGrouped = @($plan.NotGrouped)
                $overCap = @($plan.DeferOverCap); $inFlight = @($plan.DeferInFlight)
                $grouped = (@($clusters | ForEach-Object { @($_.Members).Count }) | Measure-Object -Sum).Sum; if (-not $grouped) { $grouped = 0 }
                $deferred = $overCap.Count + $inFlight.Count

                Write-Host "=== Proposed grouped waves (approved · simple-track · file-overlap) ===" -ForegroundColor Cyan
                if (-not $clusters.Count -and -not $singletons.Count -and -not $notGrouped.Count -and -not $deferred) {
                    Write-Host "  (nothing approved to group or schedule - approve simple-track issues first)" -ForegroundColor Yellow
                }
                $ci = 0
                foreach ($cl in $clusters) {
                    $ci++
                    $files = @($cl.Files)
                    $areaDirs = @($files | ForEach-Object { if ($_ -match '[\\/]') { ($_ -replace '[\\/][^\\/]*$', '') } else { '.' } })
                    $area = ($areaDirs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
                    if (-not $area) { $area = '.' }
                    Write-Host ("`nCluster {0} - area: {1}  ({2} issues, {3} files)" -f $ci, $area, @($cl.Members).Count, $files.Count) -ForegroundColor Green
                    foreach ($m in $cl.Members) {
                        Write-Host ("  #{0,-5} [{1,-10}] {2,-7} owns:{3}  {4}" -f $m, $meta[$m].Origin, $meta[$m].Sev, @($own[$m]).Count, $meta[$m].Title) -ForegroundColor Green
                    }
                    Write-Host ("  files: {0}" -f ($files -join ', ')) -ForegroundColor DarkGray
                    $sibs = @($cl.Siblings)
                    if ($sibs.Count) {
                        Write-Host "  advisory siblings (proposed - verify before bundling):" -ForegroundColor DarkGray
                        foreach ($s in @($sibs | Select-Object -First 5)) {
                            Write-Host ("    {0,-7} #{1,-5} {2,-4} [{3}]  {4}" -f $s.Type, $s.Id, $s.Sev, $s.Why, $s.Title) -ForegroundColor DarkGray
                        }
                        if ($sibs.Count -gt 5) { Write-Host ("    +{0} more - see 'findings' / 'recommendations'" -f ($sibs.Count - 5)) -ForegroundColor DarkGray }
                    }
                    Write-Host ("  -> Phase 2 will provision: new-worktree.ps1 -Issues {0}" -f (@($cl.Members) -join ',')) -ForegroundColor DarkCyan
                }
                if ($singletons.Count -or $notGrouped.Count) {
                    Write-Host "`nSingletons (approved, no overlap - use issue next / new-worktree -Issue N):" -ForegroundColor Cyan
                    foreach ($s in $singletons) {
                        Write-Host ("  #{0,-5} [{1,-10}] {2,-7} {3}" -f $s, $meta[$s].Origin, $meta[$s].Sev, $meta[$s].Title) -ForegroundColor Gray
                    }
                    foreach ($s in $notGrouped) {
                        Write-Host ("  #{0,-5} [{1,-10}] {2,-7} {3} {4}" -f $s.Issue, $meta[$s.Issue].Origin, $meta[$s.Issue].Sev, $s.Tag, $meta[$s.Issue].Title) -ForegroundColor Gray
                    }
                }
                if ($deferred) {
                    Write-Host "`nDeferred:" -ForegroundColor Cyan
                    foreach ($d in $overCap)  { Write-Host ("  #{0} - same area as Cluster {1}, exceeds cap; next wave after it merges" -f $d.Issue, $d.Cluster) -ForegroundColor DarkYellow }
                    foreach ($d in $inFlight) { Write-Host ("  #{0} - in-flight area (owned path '{1}' held by an active worktree)" -f $d.Issue, $d.Path) -ForegroundColor DarkYellow }
                }

                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','issue','clusters','$($clusters.Count) clusters, $grouped grouped issues, $deferred deferred');"
            }
```

- [ ] **Step 6: Update the two help strings**

In the `issue` `default` case (~L597), find:

```powershell
            default { Write-Host "issue sub-commands: sync | unreviewed | record-review -Id N -Targets 'a;b' [-Reads 'c' -Severity .. -Effort .. -Track simple|complex -Verdict .. -Note .. -Related '1,2' -DependsOn '3'] | list [-Status s] | show -Id N | approve -Id N | dismiss -Id N | next [-N k]" }
```

Replace with (adds `clusters`):

```powershell
            default { Write-Host "issue sub-commands: sync | unreviewed | record-review -Id N -Targets 'a;b' [-Reads 'c' -Severity .. -Effort .. -Track simple|complex -Verdict .. -Note .. -Related '1,2' -DependsOn '3'] | list [-Status s] | show -Id N | approve -Id N | dismiss -Id N | next [-N k] | clusters [-MaxIssues 4 -MaxFiles 8]" }
```

In the top-level usage block, find the line (~L611):

```powershell
        Write-Host "             issue approve -Id N | issue dismiss -Id N | issue next [-N k]    (review fan-out is orchestrator-driven; gate enforced in new-worktree.ps1)"
```

Replace with:

```powershell
        Write-Host "             issue approve -Id N | issue dismiss -Id N | issue next [-N k] | issue clusters [-MaxIssues 4 -MaxFiles 8]    (review fan-out is orchestrator-driven; gate enforced in new-worktree.ps1)"
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: PASS (1 test).

- [ ] **Step 8: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): scaffold 'issue clusters' command (wiring + read-only activity row)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Compute — eligibility, overlap graph, components, caps

Fill in `Get-IssueClusterPlan`: select eligible issues (approved · simple · not-in-flight · has owned paths), build the overlap graph (shared owned path **or** `depends-on`), find connected components, and apply the caps (full component → cluster; over-cap → highest-priority subset + deferred remainder). No siblings yet (they stay `@()`).

**Files:**
- Modify: `review-coverage.ps1` (replace the `Get-IssueClusterPlan` body)
- Test: `review-coverage.Tests.ps1` (add cases to the `Describe 'issue clusters'` block)

- [ ] **Step 1: Write the failing tests**

Add these `It` blocks inside `Describe 'issue clusters'`:

```powershell
    It 'groups two simple approved issues that share an owned file into one cluster' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'page n+1','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(15,'cache pages','approved','simple','recon','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/page-queries.ts','owns'),(15,'src/lib/page-queries.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Cluster 1'
        $out | Should -Match '#12'
        $out | Should -Match '#15'
        $out | Should -Match 'new-worktree.ps1 -Issues 12,15'
    }

    It 'keeps file-disjoint simple issues as singletons (no cluster)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(20,'a','approved','simple','user','High'),(21,'b','approved','simple','user','Low');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(20,'src/a.ts','owns'),(21,'src/b.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Not -Match 'Cluster 1'
        $out | Should -Match 'Singletons'
        $out | Should -Match '#20'
        $out | Should -Match '#21'
    }

    It 'does not group a complex issue sharing a file - lists it as a not-grouped singleton' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'simple','approved','simple','user','High'),(20,'big refactor','approved','complex','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(20,'src/lib/x.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Not -Match 'Cluster 1'           # only one simple issue -> nothing to group
        $out | Should -Match '#20.*\[complex\]'
    }

    It 'groups a depends-on pair even with no shared file; ignores a related-only link' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'dep a','approved','simple','user','High'),(31,'dep b','approved','simple','user','High'),(40,'rel a','approved','simple','user','Medium'),(41,'rel b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(30,'src/d1.ts','owns'),(31,'src/d2.ts','owns'),(40,'src/r1.ts','owns'),(41,'src/r2.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_link(issue_number,related_number,kind) VALUES(30,31,'depends-on'),(40,41,'related');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'new-worktree.ps1 -Issues 30,31'   # depends-on grouped
        $out | Should -Not -Match 'Issues 40,41'                # related NOT grouped
    }

    It 'caps an over-large component and defers the remainder' {
        $db = New-TempDb
        # five simple issues all sharing one hot file -> one component of 5; cap 2 -> cluster of 2, 3 deferred
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(50,'a','approved','simple','user','Critical'),(51,'b','approved','simple','user','High'),(52,'c','approved','simple','recon','Medium'),(53,'d','approved','simple','recon','Low'),(54,'e','approved','simple','recon','Low');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(50,'src/hot.ts','owns'),(51,'src/hot.ts','owns'),(52,'src/hot.ts','owns'),(53,'src/hot.ts','owns'),(54,'src/hot.ts','owns');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db -MaxIssues 2 6>&1) -join "`n"
        $out | Should -Match 'new-worktree.ps1 -Issues 50,51'   # top-priority 2 admitted
        $out | Should -Match 'Deferred:'
        $out | Should -Match '#52.*exceeds cap'
    }

    It 'defers an issue whose owned path is held by an active worktree (in-flight area)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'touches api','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(30,'src/api/route.ts','owns'),(27,'src/api/route.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status) VALUES('issue-27-x','solver',27,'working');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Deferred:'
        $out | Should -Match "#30.*in-flight area"
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: the six new tests FAIL (stub returns an empty plan, so nothing groups/defers); the Task 1 test still PASSES.

- [ ] **Step 3: Replace the stub with the full compute helper**

Replace the entire `Get-IssueClusterPlan` function from Task 1 with:

```powershell
# Read-only: compute a grouped-wave PROPOSAL from the ledger (no writes). Returns clusters (file-overlapping
# approved+simple issues, capped), singletons, not-grouped (complex/no-path), and deferrals, plus lookup maps.
function Get-IssueClusterPlan([string]$Db, [int]$MaxI, [int]$MaxF) {
    $activeStatuses = "'registered','working','spec-gate','pr-open','blocked'"
    $sevCase = "CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END"

    # paths owned by an ACTIVE worktree (in-flight) - same semantics as 'issue next'
    $claimed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in @(& sqlite3 $Db "SELECT DISTINCT t.path FROM issue_target t JOIN worktree w ON w.issue=t.issue_number WHERE t.ownership='owns' AND w.status IN ($activeStatuses);")) {
        if ($p) { [void]$claimed.Add($p) }
    }

    # approved issues not already owned by an active worktree, priority-ordered (user-origin, severity, number)
    $rows = @(& sqlite3 -separator '|' $Db "SELECT number, COALESCE(track,''), origin, COALESCE(severity,'-'), substr(replace(title,'|','/'),1,42) FROM issue WHERE review_status='approved' AND number NOT IN (SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($activeStatuses)) ORDER BY (origin='user') DESC, $sevCase, number;")

    $meta = @{}; $ownPaths = @{}; $rank = @{}
    $eligible = [System.Collections.Generic.List[int]]::new()
    $notGrouped = @(); $deferInFlight = @()
    $idx = 0
    foreach ($r in $rows) {
        if (-not $r) { continue }
        $f = $r -split '\|', 5
        $num = [int]$f[0]; $track = $f[1]
        $meta[$num] = [pscustomobject]@{ Origin = $f[2]; Sev = $f[3]; Title = $f[4] }
        $rank[$num] = $idx; $idx++
        if ($track -ne 'simple') { $notGrouped += [pscustomobject]@{ Issue = $num; Tag = '[complex]' }; continue }
        $paths = @(& sqlite3 $Db "SELECT path FROM issue_target WHERE issue_number=$num AND ownership='owns';" | Where-Object { $_ })
        if (-not $paths.Count) { $notGrouped += [pscustomobject]@{ Issue = $num; Tag = '[no owned paths]' }; continue }
        $blocked = $null
        foreach ($p in $paths) { if ($claimed.Contains($p)) { $blocked = $p; break } }
        if ($blocked) { $deferInFlight += [pscustomobject]@{ Issue = $num; Path = $blocked }; continue }
        $ownPaths[$num] = $paths
        [void]$eligible.Add($num)
    }

    # overlap graph over eligible issues: shared owned path OR depends-on (both endpoints eligible)
    $adj = @{}
    foreach ($num in $eligible) { $adj[$num] = [System.Collections.Generic.HashSet[int]]::new() }
    $byPath = @{}
    foreach ($num in $eligible) {
        foreach ($p in $ownPaths[$num]) {
            if (-not $byPath.ContainsKey($p)) { $byPath[$p] = [System.Collections.Generic.List[int]]::new() }
            [void]$byPath[$p].Add($num)
        }
    }
    foreach ($p in $byPath.Keys) {
        $grp = $byPath[$p]
        foreach ($a in $grp) { foreach ($b in $grp) { if ($a -ne $b) { [void]$adj[$a].Add($b) } } }
    }
    $eligSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($n in $eligible) { [void]$eligSet.Add($n) }
    foreach ($num in $eligible) {
        foreach ($dStr in @(& sqlite3 $Db "SELECT related_number FROM issue_link WHERE issue_number=$num AND kind='depends-on';" | Where-Object { $_ })) {
            $d = [int]$dStr
            if ($eligSet.Contains($d)) { [void]$adj[$num].Add($d); [void]$adj[$d].Add($num) }
        }
    }

    # connected components (BFS)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $components = [System.Collections.Generic.List[object]]::new()
    foreach ($num in $eligible) {
        if ($seen.Contains($num)) { continue }
        $comp = [System.Collections.Generic.List[int]]::new()
        $queue = [System.Collections.Generic.Queue[int]]::new()
        $queue.Enqueue($num); [void]$seen.Add($num)
        while ($queue.Count) {
            $cur = $queue.Dequeue(); [void]$comp.Add($cur)
            foreach ($nb in $adj[$cur]) { if (-not $seen.Contains($nb)) { [void]$seen.Add($nb); $queue.Enqueue($nb) } }
        }
        [void]$components.Add($comp)
    }

    # caps -> clusters / singletons / over-cap deferrals
    $ordered = @($components | Sort-Object { ($_ | ForEach-Object { $rank[$_] } | Measure-Object -Minimum).Minimum })
    $clusters = [System.Collections.Generic.List[object]]::new()
    $singletons = @(); $deferOverCap = @()
    foreach ($comp in $ordered) {
        $members = @($comp | Sort-Object { $rank[$_] })
        if ($members.Count -le 1) { $singletons += [int]$members[0]; continue }
        $union = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { foreach ($p in $ownPaths[$m]) { [void]$union.Add($p) } }
        if ($members.Count -le $MaxI -and $union.Count -le $MaxF) {
            [void]$clusters.Add([pscustomobject]@{ Members = $members; Files = @($union); Siblings = @() }); continue
        }
        # over a cap: greedily admit highest-priority members within both caps; defer the rest
        $pick = [System.Collections.Generic.List[int]]::new()
        $pf = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) {
            if ($pick.Count -ge $MaxI) { break }
            $t = [System.Collections.Generic.HashSet[string]]::new($pf)
            foreach ($p in $ownPaths[$m]) { [void]$t.Add($p) }
            if ($t.Count -le $MaxF) { [void]$pick.Add($m); $pf = $t }
        }
        if (-not $pick.Count) { [void]$pick.Add($members[0]); foreach ($p in $ownPaths[$members[0]]) { [void]$pf.Add($p) } }
        [void]$clusters.Add([pscustomobject]@{ Members = @($pick); Files = @($pf); Siblings = @() })
        $ci = $clusters.Count
        foreach ($m in $members) { if (-not $pick.Contains($m)) { $deferOverCap += [pscustomobject]@{ Issue = $m; Cluster = $ci } } }
    }

    return [pscustomobject]@{
        Clusters = $clusters; Singletons = $singletons; NotGrouped = $notGrouped
        DeferOverCap = $deferOverCap; DeferInFlight = $deferInFlight
        Meta = $meta; OwnPaths = $ownPaths
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: PASS (7 tests: Task 1 + the six new ones).

- [ ] **Step 5: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): cluster approved simple issues by file overlap + depends-on (capped)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Advisory siblings

Extend `Get-IssueClusterPlan` so each cluster carries `Siblings`: open (`status='proposed'`) findings/recs matched to the cluster by **scope-path** (strong) or **area token** (weak). Advisory only — already rendered by the Task 1 case.

**Files:**
- Modify: `review-coverage.ps1` (add the sibling-matching block to `Get-IssueClusterPlan`, before `return`)
- Test: `review-coverage.Tests.ps1` (add cases)

- [ ] **Step 1: Write the failing tests**

Add inside `Describe 'issue clusters'`:

```powershell
    It 'attaches a proposed finding whose scope mentions a cluster file (path match)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/page-queries.ts','owns'),(15,'src/lib/page-queries.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('missing index hint','Medium','proposed','needs an index in src/lib/page-queries.ts','app/db');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'advisory siblings'
        $out | Should -Match 'finding #1.*\[path\]'
    }

    It 'attaches a proposed recommendation by area token and excludes filed/dismissed rows' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity,labels) VALUES(12,'a','approved','simple','user','High',''),(15,'b','approved','simple','user','Medium','');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/cache.ts','owns'),(15,'src/lib/cache.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('extract helper','Low','proposed','src/lib');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('already filed','High','filed','src/lib');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'rec     #1.*\[area\]'
        $out | Should -Not -Match 'already filed'
    }

    It 'shows no advisory siblings when nothing matches' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(15,'src/lib/x.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('unrelated','High','proposed','src/auth/login.ts','app/auth');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Cluster 1'
        $out | Should -Not -Match 'advisory siblings'
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: the two match tests FAIL (no `advisory siblings` rendered — `Siblings` is still `@()`); the "no siblings" test PASSES already (vacuously). All earlier tests still PASS.

- [ ] **Step 3: Add the sibling-matching block**

In `Get-IssueClusterPlan`, find:

```powershell
    return [pscustomobject]@{
        Clusters = $clusters; Singletons = $singletons; NotGrouped = $notGrouped
```

Insert this block **immediately before** that `return`:

```powershell
    # advisory siblings: open (proposed) findings/recs matched to a cluster by scope-path (strong) or area (weak)
    $sib = @()
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), COALESCE(scope,''), COALESCE(topic,''), substr(replace(title,'|','/'),1,40) FROM finding WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'finding'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), COALESCE(scope,''), COALESCE(area,''), substr(replace(title,'|','/'),1,40) FROM recommendation WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'rec'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    $sevRank = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3 }
    foreach ($cl in $clusters) {
        $pathNeedles = @(); $dirs = @()
        foreach ($p in $cl.Files) {
            $pathNeedles += $p
            $pathNeedles += (($p -split '[\\/]')[-1])                       # basename
            if ($p -match '[\\/]') { $dirs += ($p -replace '[\\/][^\\/]*$', '') }   # containing dir
        }
        $labelTokens = @()
        foreach ($m in $cl.Members) {
            $lab = (& sqlite3 $Db "SELECT COALESCE(labels,'') FROM issue WHERE number=$m;")
            $labelTokens += @($lab -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $areaNeedles = @(@($dirs + $labelTokens) | Where-Object { $_ } | Sort-Object -Unique)
        $matched = @()
        foreach ($s in $sib) {
            $isPath = $false
            foreach ($n in $pathNeedles) { if ($n -and $s.Scope -like "*$n*") { $isPath = $true; break } }
            $isArea = $false
            if (-not $isPath -and $s.Area) { foreach ($n in $areaNeedles) { if ($n -and $s.Area -like "*$n*") { $isArea = $true; break } } }
            if ($isPath -or $isArea) { $matched += [pscustomobject]@{ Type = $s.Type; Id = $s.Id; Sev = $s.Sev; Title = $s.Title; Why = $(if ($isPath) { 'path' } else { 'area' }) } }
        }
        $cl.Siblings = @($matched | Sort-Object @{ e = { if ($sevRank.ContainsKey($_.Sev)) { $sevRank[$_.Sev] } else { 4 } } }, Id)
    }

```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): surface same-area proposed findings/recs as advisory siblings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Read-only invariant, docs, full-suite verification

Lock in the read-only guarantee with a dedicated test, document the command, and confirm the whole suite is green.

**Files:**
- Test: `review-coverage.Tests.ps1` (add the invariant test)
- Modify: `CLAUDE.md` (one-line pointer)

- [ ] **Step 1: Write the read-only invariant test**

Add inside `Describe 'issue clusters'`:

```powershell
    It 'mutates only the activity table (read-only over the backlog)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium'),(20,'c','approved','complex','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/x.ts','owns'),(15,'src/lib/x.ts','owns'),(20,'src/lib/x.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('f','Medium','proposed','src/lib/x.ts','app/db');" | Out-Null
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,area) VALUES('r','Low','proposed','src/lib');" | Out-Null
        $sig = "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM issue_target)||'/'||(SELECT count(*) FROM finding)||'/'||(SELECT count(*) FROM recommendation)||'/'||(SELECT count(*) FROM worktree)||'|'||COALESCE((SELECT group_concat(status) FROM finding),'')||'|'||COALESCE((SELECT group_concat(status) FROM recommendation),'');"
        $before = & sqlite3 $db $sig
        & $script:rc issue clusters -DbPath $db 6>&1 | Out-Null
        $after = & sqlite3 $db $sig
        $after | Should -Be $before                                   # backlog rows + statuses unchanged
        (& sqlite3 $db "SELECT count(*) FROM activity WHERE event='clusters';") | Should -Be '1'
    }
```

- [ ] **Step 2: Run it to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'`
Expected: PASS (11 tests). (No production-code change needed — the helper is already read-only; this test guards against regressions.)

- [ ] **Step 3: Document the command in CLAUDE.md**

In `CLAUDE.md`, find the issue-lane command line:

```
.\review-coverage.ps1 issue next -N 8                            # the OVERLAP-AWARE selector: highest-priority approved wave, file-disjoint
```

Add immediately after it:

```
.\review-coverage.ps1 issue clusters [-MaxIssues 4 -MaxFiles 8]  # GROUPED-WAVE proposal: bundle approved simple issues that overlap on owned files (capped) + advisory same-area proposed findings/recs (read-only; companion to 'next')
```

- [ ] **Step 4: Run the FULL suite to verify nothing regressed**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: PASS — 42 tests (31 existing + 11 new), 0 failed.

- [ ] **Step 5: Commit**

```bash
git add review-coverage.Tests.ps1 CLAUDE.md
git commit -m "test(ledger): read-only invariant for issue clusters + document the command

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (performed against the spec)

**1. Spec coverage** — every spec section maps to a task:
- Contract / read-only / `issue next` untouched → Task 1 (case + activity-only write) + Task 4 (invariant test).
- Eligibility (approved · simple · not-in-flight · has paths) → Task 2 compute + tests (complex/in-flight cases).
- Clustering edges (shared path + `depends-on`; `related` excluded) → Task 2 compute + depends-on/related test.
- Caps + over-cap deferral → Task 2 compute + cap test.
- Advisory siblings (path/area, proposed-only) → Task 3 compute + match/exclusion tests.
- No schema change; one `activity` row → Task 1 + Task 4 invariant.
- Output sections (clusters/singletons/deferred) + `-MaxIssues`/`-MaxFiles` → Task 1 render + params.
- Docs note → Task 4.
- *Deliberately deferred to Phase 2 (per spec):* multi-issue provisioning, grouped seed, grouped merge, persisting clusters, the cross-wave `depends-on`-to-non-eligible advisory note (the spec lists this as advisory/future; not implemented in Phase 1 to keep the selector focused — call out if you want it added).

**2. Placeholder scan** — no TBD/TODO; every code step shows complete code; every test shows real fixtures + assertions.

**3. Type/identifier consistency** — the plan returned by `Get-IssueClusterPlan` uses the same property names (`Clusters`, `Singletons`, `NotGrouped`, `DeferOverCap`, `DeferInFlight`, `Meta`, `OwnPaths`; cluster `.Members`/`.Files`/`.Siblings`; sibling `.Type`/`.Id`/`.Sev`/`.Title`/`.Why`) consumed by the Task 1 render case. The render case is written final in Task 1 and only ever reads fields the compute fills in Tasks 2–3. `-MaxIssues`/`-MaxFiles` names match between param block, render case, and `-MaxI`/`-MaxF` helper params.

> One intentional Phase-1 scope cut surfaced in review: the spec's *advisory* "depends-on → non-eligible issue" cross-wave note is **not** implemented (it's listed under the spec's advisory/future items). Flagging here so it's a conscious omission, not a gap.
