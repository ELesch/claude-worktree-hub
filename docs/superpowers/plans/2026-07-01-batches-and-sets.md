# Batches & Sets (Plan-and-Fire Waves) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted **batch** tier (a named collection of worktree sessions) atop the existing **set** tier (`worktree_issue`), and a `new-batch.ps1` driver that composes a wave from the overlap-aware selector, previews it read-only, and fires the whole fleet in one command — with batch-aware register/monitor, merge rollup, and both HTML surfaces.

**Architecture:** Additive to the SQLite ledger. A new `batch` table + a `worktree.batch` link (idempotent migration). The wave engine `Get-IssueClusterPlan` (today buried in `review-coverage.ps1`) is extracted to a shared `ledger-lib.ps1` dot-sourced by both `review-coverage.ps1` and the new `new-batch.ps1`, plus a pure `ConvertTo-BatchSets` composer. `new-batch.ps1` delegates provisioning to `new-worktree.ps1` and writes to `review-coverage.ps1`, owning only compose/preview/launch glue. Read surfaces (explorer, dashboard, monitor) gain a batch view/column. Spec: `docs/superpowers/specs/2026-07-01-batches-and-sets-design.md`.

**Tech Stack:** PowerShell 7 (pwsh), SQLite via the `sqlite3` CLI, Pester 5.7.1. Windows. No external packages.

---

## Conventions (read once, applies to every task)

**Run the tests** (from the hub root `C:\mydev\claude-worktree-hub`):

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```

Run a single Describe while iterating: add `-FullNameFilter '*batch schema*'` (etc.).

**Test harness facts** (already in `review-coverage.Tests.ps1`):
- `BeforeAll` defines `$script:rc = $PSCommandPath.Replace('.Tests.ps1','.ps1')` and `New-TempDb` (creates `$TestDrive\cov-<guid>.db` via `& $script:rc init -DbPath $p`).
- Tests invoke the script as `& $script:rc <verb> -DbPath $db ...`. **The DB-path param is `-DbPath`** (NOT `-Db`).
- Capture `Write-Host` output with `6>&1`: `$out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"`.
- Seed/assert DB state by shelling `sqlite3` directly: `& sqlite3 $db "INSERT ..."` / `(& sqlite3 -separator '|' $db "SELECT ...") | Should -Be '...'`.
- Booleans asserted as `'1'`/`'0'` via `(col IS NOT NULL)` in SQL. Throw cases: `{ & $script:rc ... } | Should -Throw`.
- Dot-source a lib for direct-function tests: `BeforeAll { . (Join-Path $PSScriptRoot 'ledger-lib.ps1') }`.

**PowerShell / sqlite gotchas** (from CLAUDE.md Lessons — honor in every edit):
- Native `git`/`gh`/`sqlite3` exit codes do NOT trip `$ErrorActionPreference='Stop'`; check `$LASTEXITCODE` where it matters (the existing helpers do).
- A comma-bearing value to a native flag must be ONE quoted token (`--json 'a,b'`).
- SQL string values go through `q` (single-quote escaper). Integers that may be absent go through `NullableInt`.
- New generated files that must be BOM-free (launchers, the `.git` pointer) use `[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))`.

**Commit style:** conventional commits, scoped. End every commit body with:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

**Branch:** all work lands on `feature/batches-and-sets` (already checked out; spec + `ledger-explorer.ps1` already committed there).

**Line numbers are indicative, not authoritative.** They reflect the *pristine* files. **Task 2 deletes ~148 lines** from `review-coverage.ps1` (the extracted functions), so every line anchor in Tasks 4–6 is shifted after that; likewise, accumulating edits within `ledger-explorer.ps1` (Task 10) and `ledger-to-html.ps1` (Task 11) shift later anchors. **Always locate an edit site by the quoted code / case name / variable it names, not by the line number.** Each edit quotes the exact surrounding text to find.

---

## Task 1: `batch` schema + `worktree.batch` migration

**Files:**
- Modify: `review-coverage.ps1` — the `init` block (schema heredoc ends ~line 317; migration section ~line 318-323)
- Test: `review-coverage.Tests.ps1` (append a new `Describe`)

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'batch schema' {
    It 'init creates the batch table, worktree.batch column, and its index' {
        $db = New-TempDb
        (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='batch';") | Should -Be '1'
        (& sqlite3 $db "SELECT count(*) FROM pragma_table_info('worktree') WHERE name='batch';") | Should -Be '1'
        (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='ix_worktree_batch';") | Should -Be '1'
    }
    It 'is idempotent (re-init does not error or duplicate the batch table)' {
        $db = New-TempDb
        { & $script:rc init -DbPath $db | Out-Null } | Should -Not -Throw
        (& sqlite3 $db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='batch';") | Should -Be '1'
    }
    It 'migrates a pre-existing worktree table that lacks the batch column' {
        $p = Join-Path $TestDrive ("old-" + [guid]::NewGuid().ToString('N') + ".db")
        & sqlite3 $p "CREATE TABLE worktree(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, wtype TEXT, issue INTEGER, branch TEXT, pr INTEGER, status TEXT DEFAULT 'registered', note TEXT);" | Out-Null
        & sqlite3 $p "INSERT INTO worktree(name,status) VALUES('old-wt','working');" | Out-Null
        & $script:rc init -DbPath $p | Out-Null
        (& sqlite3 $p "SELECT count(*) FROM pragma_table_info('worktree') WHERE name='batch';") | Should -Be '1'
        (& sqlite3 -separator '|' $p "SELECT name,status,COALESCE(batch,'null') FROM worktree WHERE name='old-wt';") | Should -Be 'old-wt|working|null'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*batch schema*'`
Expected: FAIL — no `batch` table / no `batch` column.

- [ ] **Step 3: Add the `batch` table to the schema heredoc**

In `review-coverage.ps1`, in the `init` schema heredoc, immediately AFTER the `consult` table block (ends line 304, the line `  created_at TEXT DEFAULT (datetime('now')));`) and BEFORE the first `CREATE INDEX` (line 305), insert:

```sql
CREATE TABLE IF NOT EXISTS batch(
  id INTEGER PRIMARY KEY,                          -- batch number (auto-assigned by new-batch.ps1; or explicit)
  label TEXT, status TEXT DEFAULT 'in-process',    -- in-process -> merged -> retired | aborted
  notes TEXT,                                      -- plan + results: anchors, migrations carried, what dropped/deferred
  created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
```

Do NOT add `CREATE INDEX ix_worktree_batch` here — the column does not exist yet on a pre-existing DB, so the index must be created in the migration section (Step 4), after the `ALTER`.

- [ ] **Step 4: Add the `worktree.batch` column + index to the migration section**

In `review-coverage.ps1`, immediately AFTER the existing `$verifyCols` migration loop (after line 323's closing `}`) and BEFORE `Write-Host "initialized $db"` (line 324), insert:

```powershell
        # add worktree.batch (grouping link) + index if missing (pre-existing DBs); fresh DBs get it here too
        $wtHave = @((& sqlite3 $db "SELECT name FROM pragma_table_info('worktree');") -split "`r?`n" | ForEach-Object { $_.Trim() })
        if ($wtHave -notcontains 'batch') { Exec "ALTER TABLE worktree ADD COLUMN batch INTEGER;" }
        Exec "CREATE INDEX IF NOT EXISTS ix_worktree_batch ON worktree(batch);"
```

- [ ] **Step 5: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*batch schema*'`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): batch table + worktree.batch idempotent migration

Phase 3 batches & sets: a persisted batch tier (collection of worktree sessions).
CREATE TABLE batch in the init heredoc; ALTER TABLE worktree ADD COLUMN batch +
ix_worktree_batch in the migration section so pre-existing DBs upgrade on re-init.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 2: Extract the wave engine into `ledger-lib.ps1`

Move `q`, `ActiveMemberIssuesSql`, and `Get-IssueClusterPlan` out of `review-coverage.ps1` into a new shared lib that both `review-coverage.ps1` and (later) `new-batch.ps1` dot-source. Behavior-preserving — guarded by the existing `issue clusters`/`issue next` tests plus a new direct-function test.

**Files:**
- Create: `ledger-lib.ps1`
- Modify: `review-coverage.ps1` (delete the moved functions at lines 71-72, 94-97, 99-243; add a dot-source after line 60)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test (direct-function parity)**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'ledger-lib Get-IssueClusterPlan (direct)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'ledger-lib.ps1') }
    It 'clusters two simple approved issues that share an owned file' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','recon','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/x.ts','owns'),(15,'src/x.ts','owns');" | Out-Null
        $plan = Get-IssueClusterPlan $db 4 8
        @($plan.Clusters).Count | Should -Be 1
        ($plan.Clusters[0].Members -join ',') | Should -Be '12,15'
        @($plan.Singletons).Count | Should -Be 0
    }
    It 'returns a singleton for a lone approved simple issue' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'solo','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(30,'src/solo.ts','owns');" | Out-Null
        $plan = Get-IssueClusterPlan $db 4 8
        @($plan.Singletons) | Should -Contain 30
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Get-IssueClusterPlan (direct)*'`
Expected: FAIL — `ledger-lib.ps1` does not exist / `Get-IssueClusterPlan` not found.

- [ ] **Step 3: Create `ledger-lib.ps1`**

Create `ledger-lib.ps1` with this header, then paste the THREE functions **verbatim** from `review-coverage.ps1`: `q` (lines 71-72), `ActiveMemberIssuesSql` (lines 94-97), and `Get-IssueClusterPlan` (lines 99-243). Header:

```powershell
<#
.SYNOPSIS
    Shared ledger helpers for the worktree hub. Dot-sourced by review-coverage.ps1 and new-batch.ps1.
.DESCRIPTION
    Pure/read-only wave-composition logic (no script-scoped state):
      q                    - SQL single-quote escaper
      ActiveMemberIssuesSql- the membership-union SQL (worktree.issue UNION worktree_issue)
      Get-IssueClusterPlan - read-only overlap-aware wave engine (clusters/singletons/deferrals/siblings)
      ConvertTo-BatchSets  - map a wave plan -> ordered sets, applying -Only/-Exclude/-MaxSets (Task 3)
    sqlite3 must be on PATH. No writes; callers own all mutations.
#>
```

(`ConvertTo-BatchSets` is added in Task 3 — leave it out for now.)

- [ ] **Step 4: Delete the moved functions from `review-coverage.ps1` and dot-source the lib**

In `review-coverage.ps1`:
1. DELETE the `q` function (lines 71-72), the `ActiveMemberIssuesSql` function (lines 94-97), and the whole `Get-IssueClusterPlan` function (lines 99-243). **Keep** `Exec`, `Query`, `Scalar`, `NullableInt` (lines 74-93) — they use the script-scoped `$db` and stay.
2. Immediately AFTER the hub-config dot-source block (after line 60's `catch { ... }`), add:

```powershell
. (Join-Path $PSScriptRoot 'ledger-lib.ps1')   # q + ActiveMemberIssuesSql + Get-IssueClusterPlan + ConvertTo-BatchSets
```

- [ ] **Step 5: Run to verify parity — the NEW test AND all existing engine tests pass**

Run:
```powershell
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Get-IssueClusterPlan (direct)*'
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*membership union*'
```
Expected: PASS for all three (the `issue clusters` / `membership union` suites prove `review-coverage.ps1` still drives the extracted engine correctly; the direct test proves the lib is self-contained).

- [ ] **Step 6: Commit**

```powershell
git add ledger-lib.ps1 review-coverage.ps1 review-coverage.Tests.ps1
git commit -m @'
refactor(ledger): extract wave engine to ledger-lib.ps1 (shared, dot-sourced)

Move q + ActiveMemberIssuesSql + Get-IssueClusterPlan verbatim into a new
ledger-lib.ps1 dot-sourced by review-coverage.ps1 (and, next, new-batch.ps1) so
there is ONE implementation of the overlap-aware wave logic. Behavior-preserving;
guarded by the existing issue-clusters/next suites + a new direct-function test.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 3: `ConvertTo-BatchSets` — map a wave plan to ordered sets

The pure composer core: turn a `Get-IssueClusterPlan` result into an ordered list of **sets** (each = one worktree), applying the `-Only`/`-Exclude`/`-MaxSets` edit filters. Clusters first (engine priority order), then singletons.

**Files:**
- Modify: `ledger-lib.ps1` (add one function)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'ConvertTo-BatchSets' {
    BeforeAll { . (Join-Path $PSScriptRoot 'ledger-lib.ps1') }
    function FakePlan($clusters, $singletons) {
        [pscustomobject]@{ Clusters = @($clusters); Singletons = @($singletons)
            NotGrouped = @(); DeferOverCap = @(); DeferInFlight = @(); Meta = @{}; OwnPaths = @{} }
    }
    It 'maps clusters then singletons to sets, in order' {
        $plan = FakePlan @([pscustomobject]@{ Members=@(12,15); Files=@('src/x.ts'); Siblings=@() }) @(20,22)
        $r = ConvertTo-BatchSets -Plan $plan
        @($r.Sets).Count | Should -Be 3
        $r.Sets[0].Kind | Should -Be 'cluster'
        ($r.Sets[0].Members -join ',') | Should -Be '12,15'
        $r.Sets[1].Kind | Should -Be 'single'
        $r.Sets[1].Lowest | Should -Be 20
    }
    It '-Exclude drops issues and demotes a reduced cluster to a single' {
        $plan = FakePlan @([pscustomobject]@{ Members=@(12,15); Files=@(); Siblings=@() }) @(20)
        $r = ConvertTo-BatchSets -Plan $plan -Exclude @(15)
        @($r.Sets).Count | Should -Be 2
        $r.Sets[0].Kind | Should -Be 'single'
        ($r.Sets[0].Members -join ',') | Should -Be '12'
    }
    It '-Only restricts sets to the listed issues' {
        $plan = FakePlan @([pscustomobject]@{ Members=@(12,15); Files=@(); Siblings=@() }) @(20)
        $r = ConvertTo-BatchSets -Plan $plan -Only @(12,20)
        @($r.Sets).Count | Should -Be 2
        ($r.Sets[0].Members -join ',') | Should -Be '12'
        $r.Sets[1].Lowest | Should -Be 20
    }
    It '-MaxSets caps the fired sets and defers the rest (priority order)' {
        $plan = FakePlan @() @(20,22,24)
        $r = ConvertTo-BatchSets -Plan $plan -MaxSets 2
        @($r.Sets).Count | Should -Be 2
        @($r.Deferred).Count | Should -Be 1
        $r.Deferred[0].Lowest | Should -Be 24
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ConvertTo-BatchSets*'`
Expected: FAIL — `ConvertTo-BatchSets` not defined.

- [ ] **Step 3: Implement `ConvertTo-BatchSets` in `ledger-lib.ps1`**

Append to `ledger-lib.ps1` (after `Get-IssueClusterPlan`):

```powershell
# Pure: turn a Get-IssueClusterPlan result into an ordered list of SETS (each = one worktree),
# applying the -Only/-Exclude/-MaxSets edit filters. Clusters first (engine priority), then singletons.
# A set reduced to one member by filtering becomes Kind='single'. Returns { Sets=[..]; Deferred=[..] }.
function ConvertTo-BatchSets {
    param([Parameter(Mandatory)]$Plan, [int[]]$Only, [int[]]$Exclude, [int]$MaxSets = 0)
    $only = @($Only | Where-Object { $_ -gt 0 })
    $excl = @($Exclude | Where-Object { $_ -gt 0 })
    $raw = [System.Collections.Generic.List[object]]::new()
    foreach ($cl in @($Plan.Clusters)) { $raw.Add([pscustomobject]@{ Members = @($cl.Members); Files = @($cl.Files); Siblings = @($cl.Siblings) }) }
    foreach ($n in @($Plan.Singletons)) { $raw.Add([pscustomobject]@{ Members = @([int]$n); Files = @(); Siblings = @() }) }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $raw) {
        $m = @($s.Members)
        if ($only.Count) { $m = @($m | Where-Object { $only -contains $_ }) }
        if ($excl.Count) { $m = @($m | Where-Object { $excl -notcontains $_ }) }
        if (-not $m.Count) { continue }
        $m = @($m | Sort-Object -Unique)
        $out.Add([pscustomobject]@{
            Kind = if ($m.Count -gt 1) { 'cluster' } else { 'single' }
            Members = $m; Lowest = [int]$m[0]; Files = @($s.Files); Siblings = @($s.Siblings)
        })
    }
    $fired = @($out); $deferred = @()
    if ($MaxSets -gt 0 -and $out.Count -gt $MaxSets) {
        $fired = @($out[0..($MaxSets - 1)]); $deferred = @($out[$MaxSets..($out.Count - 1)])
    }
    [pscustomobject]@{ Sets = $fired; Deferred = $deferred }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ConvertTo-BatchSets*'`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```powershell
git add ledger-lib.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): ConvertTo-BatchSets — wave plan -> ordered sets with edit filters

Pure composer: clusters-then-singletons, applying -Only/-Exclude/-MaxSets; a
filter-reduced cluster demotes to a single; returns Sets + Deferred (over -MaxSets).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 4: `batch set | show | list` verb

**Files:**
- Modify: `review-coverage.ps1` (add a `'batch'` case to the main `switch ($Command)`, after the `'monitor'` case which ends line 550)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'batch verb' {
    It 'batch set creates a batch (in-process by default)' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 5 -Title 'auth hardening' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT id,label,status FROM batch WHERE id=5;") | Should -Be '5|auth hardening|in-process'
    }
    It 'batch set -Status updates the lifecycle without touching the label' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 5 -Title 'keep me' | Out-Null
        & $script:rc batch set -DbPath $db -Id 5 -Status merged | Out-Null
        (& sqlite3 -separator '|' $db "SELECT label,status FROM batch WHERE id=5;") | Should -Be 'keep me|merged'
    }
    It 'batch set requires -Id' {
        $db = New-TempDb
        { & $script:rc batch set -DbPath $db -Title 'x' } | Should -Throw
    }
    It 'batch list shows the batch and its set/done counts' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 5 | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,status,batch) VALUES('w1','working',5),('w2','merged',5);" | Out-Null
        $out = (& $script:rc batch list -DbPath $db 6>&1) -join "`n"
        $out | Should -Match '\b5\b'
        (& sqlite3 $db "SELECT (SELECT count(*) FROM worktree WHERE batch=5)||'/'||(SELECT count(*) FROM worktree WHERE batch=5 AND status IN ('merged','retired'));") | Should -Be '2/1'
    }
    It 'batch show lists the member worktrees' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 7 | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,status,batch,issue) VALUES('issue-9-x','working',7,9);" | Out-Null
        $out = (& $script:rc batch show -DbPath $db -Id 7 6>&1) -join "`n"
        $out | Should -Match 'issue-9-x'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*batch verb*'`
Expected: FAIL — no `batch` command (hits the `default`/help branch; `set` does not create a row).

- [ ] **Step 3: Add the `'batch'` case**

In `review-coverage.ps1`, immediately AFTER the `'monitor' { ... }` case (its closing `}` is line 550) and BEFORE `'recommendations'` (line 552), insert:

```powershell
    # ---- batch tracking: a persisted collection of worktree sessions (a fired wave) ----
    'batch' {
        switch ($Sub) {
            'set' {
                if (-not $Id) { throw "batch set requires -Id <batch number>" }
                $cols = @('id'); $vals = @("$Id"); $cset = @("updated_at=datetime('now')")
                if ($Title) { $cols += 'label'; $vals += "'$(q $Title)'"; $cset += 'label=excluded.label' }
                if ($PSBoundParameters.ContainsKey('Status')) { $cols += 'status'; $vals += "'$(q $Status)'"; $cset += 'status=excluded.status' }
                if ($Note) { $cols += 'notes'; $vals += "'$(q $Note)'"; $cset += 'notes=excluded.notes' }
                $cols += 'updated_at'; $vals += "datetime('now')"
                Exec "INSERT INTO batch($($cols -join ',')) VALUES($($vals -join ',')) ON CONFLICT(id) DO UPDATE SET $($cset -join ', ');"
                $st = (& sqlite3 $db "SELECT status FROM batch WHERE id=$Id;")
                Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','batch','$(q $st)','batch $Id');"
                Write-Host "batch $Id recorded ($st)." -ForegroundColor Green
            }
            'show' {
                if (-not $Id) { throw "batch show requires -Id <batch number>" }
                Query "SELECT id, COALESCE(label,'') AS label, status, datetime(updated_at) AS updated FROM batch WHERE id=$Id;"
                Write-Host "`n-- notes --" -ForegroundColor DarkGray
                Query "SELECT COALESCE(notes,'(none)') AS notes FROM batch WHERE id=$Id;"
                Write-Host "`n-- worktrees (sets) in batch $Id --" -ForegroundColor DarkGray
                Query @"
SELECT name,
  CASE WHEN (SELECT count(*) FROM worktree_issue wi WHERE wi.worktree=worktree.name) > 1
       THEN COALESCE(CAST(issue AS TEXT),'') || ' (+' || ((SELECT count(*) FROM worktree_issue wi WHERE wi.worktree=worktree.name)-1) || ')'
       ELSE COALESCE(CAST(issue AS TEXT),'') END AS issues,
  COALESCE(pr,'') AS pr, status
FROM worktree WHERE batch=$Id ORDER BY issue;
"@
            }
            'list' {
                Query @"
SELECT b.id, COALESCE(b.label,'') AS label, b.status,
  (SELECT count(*) FROM worktree w WHERE w.batch=b.id) AS sets,
  (SELECT count(*) FROM worktree w WHERE w.batch=b.id AND w.status IN ('merged','retired')) AS done,
  datetime(b.updated_at) AS updated
FROM batch b ORDER BY b.id DESC LIMIT $N;
"@
            }
            default { Write-Host "batch sub-commands: set -Id N [-Title label -Status in-process|merged|retired|aborted -Note '...'] | show -Id N | list" }
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*batch verb*'`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): batch set|show|list verb

Ledger CRUD for the batch tier, mirroring connect: set upserts + logs activity;
show lists member worktrees with their (+k) wave sizes; list derives sets/done counts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

## Task 5: `register -Batch` (stamp a worktree's batch)

**Files:**
- Modify: `review-coverage.ps1` (param block line 44; the `register` verb's worktree upsert, line 502)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'register -Batch' {
    It 'stamps worktree.batch' {
        $db = New-TempDb
        & $script:rc register -DbPath $db -Worktree 'issue-9-x' -WType solver -Issue 9 -Branch 'fix/issue-9-x' -Batch 5 | Out-Null
        (& sqlite3 $db "SELECT batch FROM worktree WHERE name='issue-9-x';") | Should -Be '5'
    }
    It 'without -Batch leaves batch NULL' {
        $db = New-TempDb
        & $script:rc register -DbPath $db -Worktree 'w' -WType solver -Issue 9 -Branch 'b' | Out-Null
        (& sqlite3 $db "SELECT COALESCE(batch,'null') FROM worktree WHERE name='w';") | Should -Be 'null'
    }
    It 'composes with -Issues (grouped set) and still stamps batch' {
        $db = New-TempDb
        & $script:rc register -DbPath $db -Worktree 'cluster-9-x' -WType solver -Issues 9,11 -Branch 'b' -Batch 5 | Out-Null
        (& sqlite3 $db "SELECT batch FROM worktree WHERE name='cluster-9-x';") | Should -Be '5'
        (& sqlite3 $db "SELECT count(*) FROM worktree_issue WHERE worktree='cluster-9-x';") | Should -Be '2'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*register -Batch*'`
Expected: FAIL — `-Batch` is not a parameter (or is ignored; `batch` stays NULL).

- [ ] **Step 3: Add the `-Batch` parameter**

In `review-coverage.ps1` param block, line 44 currently reads:
```powershell
    [int]$Issue, [int[]]$Issues, [string]$Branch, [int]$Pr, [string]$Area, [string]$Note,   # -Issues: grouped-wave membership (register)
```
Change it to add `[int]$Batch`:
```powershell
    [int]$Issue, [int[]]$Issues, [string]$Branch, [int]$Pr, [int]$Batch, [string]$Area, [string]$Note,   # -Issues: grouped-wave membership; -Batch: batch link (register)
```

- [ ] **Step 4: Make the `register` upsert include batch conditionally**

In the `'register'` case, REPLACE the single worktree-upsert line (line 502):
```powershell
        Exec "INSERT INTO worktree(name,wtype,issue,branch,status,note,updated_at) VALUES('$wt','$wt2',$(NullableInt $primary),'$(q $Branch)','registered','$(q $Note)',datetime('now')) ON CONFLICT(name) DO UPDATE SET wtype=excluded.wtype, issue=excluded.issue, branch=excluded.branch, updated_at=datetime('now');"
```
with (conditional batch column, so a re-register without `-Batch` never wipes an existing batch):
```powershell
        $bCol = if ($Batch -gt 0) { ',batch' } else { '' }
        $bVal = if ($Batch -gt 0) { ",$Batch" } else { '' }
        $bSet = if ($Batch -gt 0) { ', batch=excluded.batch' } else { '' }
        Exec "INSERT INTO worktree(name,wtype,issue,branch,status,note,updated_at$bCol) VALUES('$wt','$wt2',$(NullableInt $primary),'$(q $Branch)','registered','$(q $Note)',datetime('now')$bVal) ON CONFLICT(name) DO UPDATE SET wtype=excluded.wtype, issue=excluded.issue, branch=excluded.branch, updated_at=datetime('now')$bSet;"
```

- [ ] **Step 5: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*register -Batch*'`
Expected: PASS (3 tests). Also re-run `-FullNameFilter '*register*'` if such a suite exists, to confirm no regression.

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): register -Batch stamps worktree.batch

Optional -Batch on register links a worktree (solo or grouped set) to its batch,
conditionally so a re-register without -Batch never clears an existing link.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 6: `monitor` batch awareness (column + Open-batches section)

The monitor's worktree list uses the `Query` passthrough helper; rather than a bespoke grouped renderer, add a `batch` column to each worktree row and an "Open batches" summary section. (Spec §5 is reconciled to this simpler-but-equivalent mechanism in Task 12.)

**Files:**
- Modify: `review-coverage.ps1` (the `'monitor'` case, lines 528-550)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'monitor batch awareness' {
    It 'still lists worktrees (no regression)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status,batch) VALUES('issue-9-x','solver',9,'working',5);" | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'issue-9-x'
    }
    It 'shows an Open batches section listing open batches by label' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 5 -Title 'wave5' | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,status,batch) VALUES('w1','working',5);" | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Batches'
        $out | Should -Match 'wave5'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*monitor batch awareness*'`
Expected: FAIL — no "Batches" section in the output.

- [ ] **Step 3: Add the `batch` column to the worktree query**

In the `'monitor'` case, the worktree query line 535 reads:
```powershell
  COALESCE(pr,'') AS pr, status,
```
Change it to:
```powershell
  COALESCE(pr,'') AS pr, status, COALESCE(batch,'') AS batch,
```

- [ ] **Step 4: Add the Open-batches section**

Immediately AFTER the worktree `Query @"..."@` block closes (line 543, the `"@`) and BEFORE `Write-Host "`n=== Proposed recommendations` (line 544), insert:

```powershell
        Write-Host "`n=== Batches (open: in-process) ===" -ForegroundColor Cyan
        Query @"
SELECT b.id, COALESCE(b.label,'') AS label, b.status,
  (SELECT count(*) FROM worktree w WHERE w.batch=b.id) AS sets,
  (SELECT count(*) FROM worktree w WHERE w.batch=b.id AND w.status IN ('merged','retired')) AS done
FROM batch b WHERE b.status='in-process' ORDER BY b.id DESC LIMIT $N;
"@
```

- [ ] **Step 5: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*monitor*'`
Expected: PASS (the new suite + any pre-existing `monitor` test still green).

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): monitor batch awareness (worktree batch column + Open-batches section)

Adds a batch column to the live worktree list and an "Open batches" summary
(id · label · sets · done) so a fired wave is visible at a glance in monitor.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 7: `Get-BatchFirePlan` — the exact command list the fire step runs

Pure helper (in `ledger-lib.ps1`) mapping composed sets + a resolved name-map + a batch id to the ordered provision/register command arguments. Testing this pins the fire plan without launching anything.

**Files:**
- Modify: `ledger-lib.ps1`
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'Get-BatchFirePlan' {
    BeforeAll { . (Join-Path $PSScriptRoot 'ledger-lib.ps1') }
    It 'builds provision + register args per set (single and cluster)' {
        $sets = @(
            [pscustomobject]@{ Kind = 'single'; Members = @(9); Lowest = 9 },
            [pscustomobject]@{ Kind = 'cluster'; Members = @(12, 15); Lowest = 12 }
        )
        $names = @{ 9 = @{ Name = 'issue-9-x'; Branch = 'fix/issue-9-x' }; 12 = @{ Name = 'cluster-12-y'; Branch = 'fix/cluster-12-y' } }
        $p = Get-BatchFirePlan -Sets $sets -NameMap $names -BatchId 5
        @($p).Count | Should -Be 2
        # single -> -Issue (no -Issues); register carries -Batch
        $p[0].Provision.Name  | Should -Be 'issue-9-x'
        $p[0].Provision.Issue | Should -Be 9
        $p[0].Provision.ContainsKey('Issues') | Should -BeFalse
        $p[0].Register.Issue  | Should -Be 9
        $p[0].Register.Batch  | Should -Be 5
        # cluster -> -Issues array (no -Issue)
        ($p[1].Provision.Issues -join ',') | Should -Be '12,15'
        $p[1].Provision.ContainsKey('Issue') | Should -BeFalse
        ($p[1].Register.Issues -join ',') | Should -Be '12,15'
        $p[1].Register.Batch | Should -Be 5
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Get-BatchFirePlan*'`
Expected: FAIL — `Get-BatchFirePlan` not defined.

- [ ] **Step 3: Implement `Get-BatchFirePlan` in `ledger-lib.ps1`**

Append to `ledger-lib.ps1`:

```powershell
# Pure: given composed sets + a resolved name-map (Lowest -> @{Name;Branch}) + a batch id, return per-set
# SPLAT-READY hashtables the fire step passes directly to new-worktree.ps1 and review-coverage.ps1 register.
# Single -> -Issue (int); cluster -> -Issues (int[]). Register always carries -Batch.
function Get-BatchFirePlan {
    param([Parameter(Mandatory)]$Sets, [Parameter(Mandatory)][hashtable]$NameMap, [int]$BatchId)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($Sets)) {
        $nm = $NameMap[$s.Lowest]; $isCluster = $s.Kind -eq 'cluster'
        $prov = @{ Name = $nm.Name; Install = $true }
        $reg = @{ Worktree = $nm.Name; WType = 'solver'; Branch = $nm.Branch; Batch = $BatchId }
        if ($isCluster) { $prov.Issues = @($s.Members); $reg.Issues = @($s.Members) }
        else { $prov.Issue = [int]$s.Lowest; $reg.Issue = [int]$s.Lowest }
        $out.Add([pscustomobject]@{ Kind = $s.Kind; Name = $nm.Name; Branch = $nm.Branch
                Members = @($s.Members); Lowest = [int]$s.Lowest; Provision = $prov; Register = $reg })
    }
    @($out)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Get-BatchFirePlan*'`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add ledger-lib.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger): Get-BatchFirePlan — pure per-set provision/register command plan

Maps composed sets + resolved names + batch id to the exact new-worktree.ps1 and
register argument lists the fire step will run (single -> -Issue, cluster -> -Issues),
so the fire plan is unit-tested without launching windows.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 8: `new-batch.ps1` — compose + preview (read-only default)

Create the driver. This task delivers the **read-only preview** (the default run); firing is Task 9. Names are derived from the ledger's cached issue title (offline), so preview and fire produce identical worktree names with no `gh` call for naming.

**Files:**
- Create: `new-batch.ps1`
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'new-batch preview (read-only)' {
    BeforeAll { $script:nb = $PSCommandPath.Replace('review-coverage.Tests.ps1', 'new-batch.ps1') }
    It 'previews the approved wave without provisioning or mutating the ledger' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'page n+1','approved','simple','user','High'),(15,'cache pages','approved','simple','recon','Medium'),(30,'solo fix','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/page-queries.ts','owns'),(15,'src/page-queries.ts','owns'),(30,'src/solo.ts','owns');" | Out-Null
        $sig = "SELECT (SELECT count(*) FROM worktree)||'/'||(SELECT count(*) FROM batch)||'/'||(SELECT count(*) FROM worktree_issue);"
        $before = & sqlite3 $db $sig
        $out = (& $script:nb -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Batch 1 preview'
        $out | Should -Match '#12'
        $out | Should -Match '#15'
        $out | Should -Match '#30'
        $out | Should -Match 'preview only'
        (& sqlite3 $db $sig) | Should -Be $before
    }
    It '-Exclude removes an issue from the previewed wave' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','recon','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/x.ts','owns'),(15,'src/x.ts','owns');" | Out-Null
        $out = (& $script:nb -DbPath $db -Exclude 15 6>&1) -join "`n"
        $out | Should -Match '#12'
        $out | Should -Not -Match '#15'
    }
    It 'reports no eligible wave when nothing is approved' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(40,'wip','synced','simple','user','High');" | Out-Null
        $out = (& $script:nb -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'no eligible'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*new-batch preview*'`
Expected: FAIL — `new-batch.ps1` does not exist.

- [ ] **Step 3: Create `new-batch.ps1` (preview path)**

Create `new-batch.ps1`:

```powershell
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*new-batch preview*'`
Expected: PASS (3 tests). (The tests never pass `-Fire`, so the `throw` placeholder is never hit.)

- [ ] **Step 5: Commit**

```powershell
git add new-batch.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(batch): new-batch.ps1 compose + read-only preview

Composes the overlap-aware wave (Get-IssueClusterPlan -> ConvertTo-BatchSets) with
-Only/-Exclude/-MaxSets edit filters and previews each set (worktree name, members,
owned paths, advisory siblings, deferrals) offline, mutating nothing. Fire follows.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

## Task 9: `new-batch.ps1` — fire (gate → provision → register → seed + launch)

Replace the preview's fire placeholder with the real fire path: confirm, re-check the approved gate, create
the batch, and per set provision (`new-worktree.ps1`) → register with `-Batch` → write a seeded launcher →
open the window. Provision/launch is integration-level; the command mapping is already unit-tested via
`Get-BatchFirePlan` (Task 7), and two safe guards are tested here.

**Files:**
- Modify: `new-batch.ps1` (add `New-SeedPrompt`; replace the placeholder)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing guard tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'new-batch fire guards' {
    BeforeAll { $script:nb = $PSCommandPath.Replace('review-coverage.Tests.ps1', 'new-batch.ps1') }
    It 'with -Yes on an empty wave: aborts with "nothing to fire" and creates no batch row' {
        $db = New-TempDb
        { & $script:nb -DbPath $db -Fire -Yes 6>$null } | Should -Throw -ExpectedMessage '*nothing to fire*'
        (& sqlite3 $db "SELECT count(*) FROM batch;") | Should -Be '0'
    }
}
```

(The interactive confirm and the provision/launch path are integration-level — not unit-tested; validated manually in Task 13. `-Yes` skips the `Read-Host`; the empty-wave guard throws before any batch/worktree write. The `-ExpectedMessage` matcher is what makes this a real red→green test — see Step 2.)

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*new-batch fire guards*'`
Expected: FAIL — the Task 8 placeholder throws `fire not yet implemented`, which does NOT match `*nothing to fire*`, so the assertion fails. (This is why the message matcher matters: a bare `Should -Throw` would pass against the placeholder and give a false green.)

- [ ] **Step 3: Add `New-SeedPrompt` to `new-batch.ps1`**

In `new-batch.ps1`, immediately AFTER the `Resolve-SetName` function definition (and before the `# ---- preview ----` line), insert:

```powershell
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
```

- [ ] **Step 4: Replace the fire placeholder**

In `new-batch.ps1`, REPLACE the placeholder block:
```powershell
# ==== FIRE: implemented in Task 9 (appended below this line) ====
throw "fire not yet implemented"   # replaced in Task 9
```
with the real fire path:

```powershell
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
```

- [ ] **Step 5: Run to verify the guard test passes + full new-batch suite green**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*new-batch*'`
Expected: PASS (preview suite from Task 8 + the fire-guard test). The empty-wave `-Fire -Yes` throws `nothing to fire` and leaves `batch` empty.

- [ ] **Step 6: Commit**

```powershell
git add new-batch.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(batch): new-batch.ps1 fire — provision + register + seed + launch the fleet

-Fire creates the batch, then per set: new-worktree.ps1 (-Issue/-Issues), register
-Batch, and a BOM-free seeded launcher (solver / grouped-wave prompt) opened via the
windowed wrapper. Guards: confirm (or -Yes), re-checked approved gate, empty-wave abort,
-NoLaunch, per-set failure isolation. Never headless (Critical rule #7).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

## Task 10: `ledger-explorer.ps1` — Batch entity/view

Re-add the Batch entity (removed last session when cwh had no batch table). Batch `key` = `id`. Its drawer
traverses batch → worktrees → member issues. All anchors below are current line numbers in `ledger-explorer.ps1`.

**Files:**
- Modify: `ledger-explorer.ps1`
- Test: `review-coverage.Tests.ps1` (generation smoke test) + a manual node relationship check

- [ ] **Step 1: Write the failing smoke test**

Append to `review-coverage.Tests.ps1` (confirm the explorer's DB/out/repo params first — they mirror `ledger-to-html.ps1`: `-Database`, `-Out`, `-Repo`, `-NoOpen`):

```powershell
Describe 'ledger-explorer batch view' {
    BeforeAll { $script:expl = $PSCommandPath.Replace('review-coverage.Tests.ps1', 'ledger-explorer.ps1') }
    It 'embeds the batch entity and links a worktree to its batch' {
        $db = New-TempDb
        & $script:rc batch set -DbPath $db -Id 5 -Title 'wave5' | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status,batch) VALUES('issue-9-x','solver',9,'working',5);" | Out-Null
        $html = Join-Path $TestDrive 'expl.html'
        & $script:expl -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $txt = Get-Content $html -Raw
        $txt | Should -Match '"batches"\s*:'          # DATA carries the batch array
        $txt | Should -Match 'wave5'                   # the batch label is embedded
        # the worktree query must now carry batch so the drawer can link up
        $txt | Should -Match '"batch"\s*:\s*"?5'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ledger-explorer batch view*'`
Expected: FAIL — no `batches` in DATA; worktree rows lack `batch`.

- [ ] **Step 3: Add the `$qBatches` query + `batch` on `$qWorktrees`**

(a) Add `COALESCE(batch,'') AS batch,` to `$qWorktrees` (line 118, the line `SELECT name, COALESCE(wtype,'') AS wtype, ...`). Insert `COALESCE(batch,'') AS batch,` right after `COALESCE(pr,'') AS pr,` on line 119 so the worktree rows carry their batch.

(b) Immediately AFTER the `$qWtIssues` line (line 146), add:
```powershell
$qBatches = Get-Json @"
SELECT id, COALESCE(label,'') AS label, status,
  substr(COALESCE(created_at,''),1,16) AS created_at, substr(COALESCE(updated_at,''),1,16) AS updated_at,
  (SELECT count(*) FROM worktree w WHERE w.batch=batch.id) AS sets,
  (SELECT count(*) FROM worktree w WHERE w.batch=batch.id AND w.status IN ('merged','retired')) AS done,
  COALESCE(notes,'') AS notes
FROM batch ORDER BY id DESC;
"@
```

- [ ] **Step 4: Wire `batches` into the data + counts**

(c) In the `$dataJson` assembly (lines 170-188), add a line to the list (after `'"worktree_issues": ' + $qWtIssues`):
```powershell
        '"batches": ' + $qBatches
```
(d) In the `$counts` ordered hashtable (lines 970-977), add after the `worktrees = ...` entry:
```powershell
    batches = Count-Rows $qBatches
```

- [ ] **Step 5: Wire `batches` into the JS index, config, order, and relationship map**

(e) `IX` map (line 429) — add:
```javascript
  batch:new Map(DATA.batches.map(r=>[String(r.id), r])),
```
(f) `ENTITIES` (after the `worktrees` entry, ~line 512) — add (`B_ST` is the shared status-badge shorthand at line 478):
```javascript
  batches: { title:'Batches', icon:'📦', key:'id', rows:DATA.batches,
    open:r=>r.status!=='retired'&&r.status!=='aborted',
    cols:[
      {k:'id',label:'Batch',type:'title'},{k:'label',label:'Label'},{k:'status',label:'Status',...B_ST},
      {k:'sets',label:'Sets',type:'num'},{k:'done',label:'Done',type:'num'},
      {k:'created_at',label:'Created',type:'date'},{k:'updated_at',label:'Updated',type:'date'}],
    facets:['status'] },
```
(g) `ORDER` array (line 551) — insert `'batches'` right after `'worktrees'`:
```javascript
const ORDER = ['issues','findings','recommendations','hubfindings','consults','worktrees','batches','topics','runs','inventory','activity'];
```
(h) Relationship maps (after `consultByWt`, ~line 471) — add:
```javascript
const wtByBatch = new Map(); DATA.worktrees.forEach(w=>{ if(has(w.batch)) (wtByBatch.get(String(w.batch))||wtByBatch.set(String(w.batch),[]).get(String(w.batch))).push(w); });
```

- [ ] **Step 6: Add the `batch(r)` drawer + a Batch chip on the worktree drawer**

(i) In the `DETAIL` object, AFTER the `worktree(r){...}` renderer (ends ~line 812), add:
```javascript
  batch(r){
    const wts=wtByBatch.get(String(r.id))||[];
    const issues=[...new Set(wts.flatMap(w=>{ const m=memberIssuesByWt.get(w.name)||[]; return m.length?m:(has(w.issue)?[String(w.issue)]:[]); }))];
    return { kind:'Batch', title:'batch '+r.id+(has(r.label)?' · '+r.label:''),
      html: fields([
        ['Label',r.label],['Status',badge(r.status,'st'),true],['Sets',r.sets],['Done',r.done],
        ['Created',r.created_at],['Updated',r.updated_at]])
      + longBlock('Notes', r.notes)
      + chipRow('Worktrees (sets)', wts.map(w=>{ const m=memberIssuesByWt.get(w.name)||[];
          return chip('worktree', w.name, w.name+(m.length?' · '+m.length+' issues':(has(w.issue)?' · #'+w.issue:'')), w.status); }).join(''))
      + chipRow('Issues in this batch', issues.map(n=>chip('issue',n,'#'+n+' · '+((IX.issue.get(String(n))||{}).title||'').slice(0,36))).join('')) };
  },
```
(j) In the `worktree(r){...}` renderer, add a Batch chip. After the `chipRow('Recommendations raised', ...)` line, append (before the Activity block `+ (acts.length?...`):
```javascript
      + (has(r.batch)?chipRow('Batch', chip('batch', r.batch, 'batch '+r.batch)):'')
```

- [ ] **Step 7: Wire `batch`/`batches` into the enumeration maps**

(k) `openEntity` `getter` map (line 866) — add `,batch:'batch'` before the closing `}`.
(l) `openEntity` `bucket` map (line 867) — add `,batch:'batch'` before the closing `}`.
(m) `VIEW_TYPE` (line 887) — add `,batches:'batch'` before the closing `}`.
(n) `globalSearch` (after the `worktrees` scan, line 900) — add:
```javascript
    scan('batches','batch',r=>({key:r.id,label:`batch ${r.id} · ${r.status}`}));
```

- [ ] **Step 8: Run the smoke test + regenerate to catch JS errors**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ledger-explorer batch view*'`
Expected: PASS.

Then a manual relationship check (client-rendered — exercise the real JS, don't trust the HTML string). Seed a DB with a batch + a solo and a cluster worktree, generate the HTML, and in node extract `DATA` and assert `wtByBatch` groups correctly:

```powershell
# generate a rich fixture
$db = Join-Path $env:TEMP ("bx-" + [guid]::NewGuid().ToString('N') + ".db")
& .\review-coverage.ps1 init -DbPath $db | Out-Null
& .\review-coverage.ps1 batch set -DbPath $db -Id 5 -Title wave5 | Out-Null
& sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status,batch) VALUES('issue-9-x','solver',9,'working',5),('cluster-12-x','solver',12,'working',5);" | Out-Null
& sqlite3 $db "INSERT INTO worktree_issue(worktree,issue_number) VALUES('cluster-12-x',12),('cluster-12-x',15);" | Out-Null
& .\ledger-explorer.ps1 -Database $db -Out (Join-Path $env:TEMP 'bx.html') -Repo acme/widgets -NoOpen
node -e "const h=require('fs').readFileSync(process.env.TEMP+'/bx.html','utf8');const m=h.match(/const DATA = ([\s\S]*?);\nconst REPO/);const D=JSON.parse(m[1].replace(/<\\\//g,'</'));const wtByBatch=new Map();D.worktrees.forEach(w=>{if(w.batch!=='')((wtByBatch.get(String(w.batch)))||wtByBatch.set(String(w.batch),[]).get(String(w.batch))).push(w)});const g=wtByBatch.get('5')||[];console.log('batch5 worktrees:',g.map(w=>w.name).join(','));if(g.length!==2)process.exit(1);console.log('OK');"
```
Expected: prints `batch5 worktrees: issue-9-x,cluster-12-x` then `OK`.

- [ ] **Step 9: Commit**

```powershell
git add ledger-explorer.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger-explorer): Batch entity/view (batch -> worktrees -> member issues)

Re-add the batch entity (now that cwh has a batch table): $qBatches query, batch on
$qWorktrees, DATA/counts/IX/ENTITIES/ORDER wiring, a wtByBatch relationship map, a
batch(r) drawer traversing to its worktrees + their member issues, a Batch chip on the
worktree drawer, and getter/bucket/VIEW_TYPE/search enumeration entries.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

## Task 11: `ledger-to-html.ps1` — batch column

**Files:**
- Modify: `ledger-to-html.ps1` (`$qWorktrees` line 132; the `cols` array line 313)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'ledger-to-html batch column' {
    BeforeAll { $script:l2h = $PSCommandPath.Replace('review-coverage.Tests.ps1', 'ledger-to-html.ps1') }
    It 'carries batch in the worktrees data and declares the column' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status,batch) VALUES('issue-9-x','solver',9,'working',7);" | Out-Null
        $html = Join-Path $TestDrive 'oi.html'
        & $script:l2h -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $txt = Get-Content $html -Raw
        $txt | Should -Match '"batch"\s*:\s*"?7'
        $txt | Should -Match "\{k:'batch'"
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ledger-to-html batch column*'`
Expected: FAIL.

- [ ] **Step 3: Add batch to the query and the columns**

(a) In `$qWorktrees`, line 132 reads:
```powershell
  COALESCE(branch,'') AS branch, COALESCE(note,'') AS note
```
Change to:
```powershell
  COALESCE(branch,'') AS branch, COALESCE(batch,'') AS batch, COALESCE(note,'') AS note
```
(b) In the worktrees `cols` array, between line 313 (`{k:'branch',label:'Branch'},`) and line 314 (`{k:'note',label:'Note',type:'long'},`), insert:
```javascript
    {k:'batch',label:'Batch'},
```

- [ ] **Step 4: Run to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*ledger-to-html batch column*'`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add ledger-to-html.ps1 review-coverage.Tests.ps1
git commit -m @'
feat(ledger-html): batch column on the worktrees dashboard

Adds COALESCE(batch,'') to the worktree query and a {k:'batch'} column so the
lightweight dashboard shows each worktree's batch (the data-driven renderer picks it up).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 12: Docs — CLAUDE.md, WORKTREE.md, merge rollup, spec reconciliation

Documentation only (reviewed via `git diff`, no unit test). Apply each edit, then read the diff to confirm.

**Files:** `CLAUDE.md`, `WORKTREE.md`, `docs/superpowers/specs/2026-07-01-batches-and-sets-design.md`

- [ ] **Step 1: CLAUDE.md — directory-structure entries**

After the `new-worktree.ps1` line in the directory block, add:
```text
├── new-batch.ps1            <- helper: PLAN-AND-FIRE a batch — compose a wave, preview, fire the fleet (one worktree per set)
```
After the `hub-lib.ps1` line, add:
```text
├── ledger-lib.ps1          <- shared: q + Get-IssueClusterPlan + ConvertTo-BatchSets + Get-BatchFirePlan (dot-sourced by review-coverage.ps1 + new-batch.ps1)
```

- [ ] **Step 2: CLAUDE.md — a "Batches (plan-and-fire waves)" subsection**

Add this subsection immediately AFTER the "### Issue lane: GitHub issue → ledger → review → overlap-aware deploy" section:

```markdown
### Batches (plan-and-fire waves) — Phase 3

A **batch** is a persisted collection of worktree sessions fired as one wave; a **set** is the issues one
worktree owns (a singleton or a `worktree_issue` cluster). Where `issue next`/`issue clusters` only *propose*
a wave, **`new-batch.ps1`** persists and fires it:

- **`.\new-batch.ps1`** — read-only PREVIEW (the default): composes the overlap-aware wave (reusing
  `Get-IssueClusterPlan`) and prints each set → its issues, owned paths, advisory siblings, and deferrals.
  Safe to run and paste back. Edit the wave with **`-Exclude N,…` / `-Only N,…` / `-MaxSets k`** (+ `-MaxIssues`/`-MaxFiles` caps), then re-preview.
- **`.\new-batch.ps1 -Fire`** (interactive confirm) or **`-Fire -Yes`** (scripted) — creates the `batch` row,
  then per set: `new-worktree.ps1 -Issue`/`-Issues` (the approval gate still applies) → `register … -Batch` →
  a seeded launcher opened through the windowed wrapper (solver / grouped-wave prompt). `-NoLaunch` provisions
  without opening windows; `-SkipReview` bypasses the gate (emergencies only). Never headless (Critical rule #7).
- **Track it:** `review-coverage.ps1 monitor` shows an Open-batches section + a batch column; `batch show -Id N`
  lists the batch's worktrees and their member issues; the explorer + dashboard have a Batch view/column.
- **Lifecycle:** `in-process → merged → retired | aborted`, set with `review-coverage.ps1 batch set -Id N -Status …`.
```

- [ ] **Step 3: CLAUDE.md — cheatsheet lines**

In the `review-coverage.ps1` cheatsheet block, after the `issue clusters` line, add:
```text
.\new-batch.ps1                                              # PREVIEW the next plan-and-fire wave (read-only); -Fire [-Yes] to launch; -Exclude/-Only/-MaxSets to edit
.\review-coverage.ps1 batch set -Id N [-Title l -Status in-process|merged|retired|aborted -Note '..'] | batch show -Id N | batch list   # batch tier
.\review-coverage.ps1 register -Worktree w -WType solver -Issue N -Branch b -Batch N   # stamp a worktree's batch (new-batch does this per set)
```

- [ ] **Step 4: CLAUDE.md — merge rollup in the "Merging a finished PR" runbook**

In the merge runbook, after the grouped-wave merge note, add a "Batch rollup" note:
```markdown
**Batch rollup.** If the merged worktree belongs to a **batch** (`worktree.batch` set; `batch show -Id N`),
merge/report each member PR as usual, then when the LAST set of the batch merges, flip the batch:
`.\review-coverage.ps1 batch set -Id N -Status merged` (then `retired` after teardown), and render a batch
box-table with `format-report.ps1` fed by `batch show -Id N` (one row per set: worktree · issues · PR ·
state, plus migrations applied across the batch and any dropped/deferred members).
```

- [ ] **Step 5: WORKTREE.md — one batch note**

In `WORKTREE.md`, near the grouped-wave rules, add one line:
```markdown
- **Batch membership.** Your worktree may belong to a **batch** (a wave fired together via `new-batch.ps1`);
  this is grouping only — the set/grouped-wave rules above are unchanged. The orchestrator rolls the batch up at merge.
```

- [ ] **Step 6: Reconcile the spec's monitor section (§5)**

In `docs/superpowers/specs/2026-07-01-batches-and-sets-design.md`, replace the `## 5. monitor batch grouping` body with the mechanism actually built (column + section, since `monitor` uses the `Query` passthrough):
```markdown
## 5. `monitor` batch awareness

`monitor` gains a `batch` column on each worktree row (`COALESCE(batch,'') AS batch`) and a new "Open batches"
summary section (`id · label · sets · done` for `status='in-process'` batches), so a fired wave is visible at a
glance. Purely presentational; the passthrough `Query` helper is kept (no bespoke grouped renderer for v1).
```

- [ ] **Step 7: Review the diff and commit**

Run: `git --no-pager diff CLAUDE.md WORKTREE.md docs/superpowers/specs/2026-07-01-batches-and-sets-design.md`
Confirm each addition reads correctly and anchors landed in the right sections.

```powershell
git add CLAUDE.md WORKTREE.md docs/superpowers/specs/2026-07-01-batches-and-sets-design.md
git commit -m @'
docs(hub): document the batch tier (CLAUDE.md, WORKTREE.md, merge rollup) + spec reconcile

Batches (plan-and-fire waves) section + cheatsheet + directory entries (new-batch.ps1,
ledger-lib.ps1); a batch-rollup step in the merge runbook; a WORKTREE.md batch-membership
note; and spec §5 reconciled to the built monitor mechanism (column + Open-batches section).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
```

---

## Task 13: Full-suite green + Definition of Done

- [ ] **Step 1: Run the entire Pester suite**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: ALL green — the new suites (`batch schema`, `Get-IssueClusterPlan (direct)`, `ConvertTo-BatchSets`, `batch verb`, `register -Batch`, `monitor batch awareness`, `Get-BatchFirePlan`, `new-batch preview`, `new-batch fire guards`, `ledger-explorer batch view`, `ledger-to-html batch column`) AND every pre-existing suite (proving the `ledger-lib.ps1` extraction and the register/monitor edits regressed nothing).

- [ ] **Step 2: Smoke the driver + both HTML surfaces on a fixture**

```powershell
$db = Join-Path $env:TEMP ("bx-" + [guid]::NewGuid().ToString('N') + ".db")
& .\review-coverage.ps1 init -DbPath $db | Out-Null
& sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'page n+1','approved','simple','user','High'),(15,'cache','approved','simple','recon','Medium'),(30,'solo','approved','simple','user','High');" | Out-Null
& sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/pq.ts','owns'),(15,'src/pq.ts','owns'),(30,'src/s.ts','owns');" | Out-Null
& .\new-batch.ps1 -DbPath $db            # PREVIEW: expect one cluster (12,15) + one single (30); mutates nothing
& .\ledger-explorer.ps1 -Database $db -Out (Join-Path $env:TEMP 'bx-expl.html') -Repo acme/widgets   # eyeball the Batches sidebar view + a batch drawer
& .\ledger-to-html.ps1  -Database $db -Out (Join-Path $env:TEMP 'bx-oi.html')  -Repo acme/widgets     # eyeball the Batch column
```
Expected: preview lists the two sets read-only; both HTML pages open with the Batch view/column present and drawers navigable. (Do NOT `-Fire` here — this dev repo has no target-project config; fire is exercised in a real deployment with `-NoLaunch` first.)

- [ ] **Step 3: Definition of Done**

- [ ] `review-coverage.ps1 init` creates `batch` + migrates `worktree.batch` (idempotent).
- [ ] `Get-IssueClusterPlan` lives in `ledger-lib.ps1`; existing engine tests still pass.
- [ ] `ConvertTo-BatchSets`, `Get-BatchFirePlan`, `batch set|show|list`, `register -Batch`, `monitor` batch awareness — all tested green.
- [ ] `new-batch.ps1` previews read-only by default and fires (provision → register `-Batch` → windowed launch) with confirm/`-Yes`, `-NoLaunch`, gate re-check, and per-set failure isolation.
- [ ] Explorer Batch view + dashboard Batch column render and navigate; validated via node relationship check.
- [ ] CLAUDE.md (section + cheatsheet + dir entries + merge rollup), WORKTREE.md note, and spec §5 updated.
- [ ] Whole Pester suite green; both HTML surfaces regenerate without JS errors.

No commit for Task 13 unless Step 2 surfaces a fix (then commit it with a `fix(...)` message).

---

## Execution

Per the user's instruction, this plan is executed via **superpowers:subagent-driven-development** (fresh subagent per task, two-stage review between tasks). Tasks are dependency-ordered; Task 2 (the `ledger-lib.ps1` extraction) must land before Tasks 3, 7, and 8; Task 1 (schema) is the prerequisite for everything that reads/writes `batch`.

