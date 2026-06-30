# Issue Grouping (Overlap Clusters) — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a proposed `issue clusters` wave into one provisioned worktree → one PR closing several issues — adding multi-issue provisioning, a `worktree_issue` membership link, a grouped seed prompt, grouped merge/resolve, and the three Phase-1 sibling-precision fixes.

**Architecture:** Approach A — ad-hoc `new-worktree.ps1 -Issues 12,15,19`; the cluster stays ephemeral. A thin `worktree_issue(worktree, issue_number)` join table links a worktree to all its issues; one membership definition (`{worktree.issue} ∪ {worktree_issue}`) is read by the four in-flight/eligibility paths (`clusters` + `next`) and `monitor`. Single-issue worktrees write no join rows, so everything is backward compatible with no data migration.

**Tech Stack:** PowerShell 7 + SQLite (`sqlite3` CLI); Pester 5.7.1 (from `C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1`); `gh` CLI; git worktrees. Repo is the claude-worktree-hub dev repo itself — edit `review-coverage.ps1` / `review-coverage.Tests.ps1` / `hub-lib.ps1` / `new-worktree.ps1` / `WORKTREE.md` / `CLAUDE.md` directly (ignore the "hub root is bare, don't edit here" note — that applies to OTHER orchestrated repos).

**Spec:** `docs/superpowers/specs/2026-06-29-issue-grouping-phase2-design.md`

---

## Conventions every task follows

- **Run Pester** with the saved module (standard `Install-Module` does NOT work on this machine):
  ```powershell
  Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1
  Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*<describe substring>*'
  ```
  `Write-Host` output is captured in tests with `6>&1`. Each `It` calls `New-TempDb` (defined in the file's
  `BeforeAll`: creates a temp db under `$TestDrive` and runs `init`). `$script:rc` is the path to
  `review-coverage.ps1`.
- **sqlite/PowerShell plumbing:** native `sqlite3`/`git`/`gh` exit codes do NOT trip
  `$ErrorActionPreference='Stop'` — use the script's `Exec`/`Query`/`Scalar` helpers (they check
  `$LASTEXITCODE`) and the `q` single-quote escaper; reads are `& sqlite3 $db "…"` (plain) or
  `& sqlite3 -separator '|' $db "…"`. A comma-bearing native-flag value must be ONE quoted token.
- **Match plan code verbatim** — production-code blocks below are canonical. Add/strengthen tests freely;
  do not add production behavior beyond what a step specifies.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `review-coverage.ps1` | ledger CLI: schema, `register`, membership-aware `clusters`/`next`/`monitor`, sibling matcher | 1, 2, 3, 6 |
| `review-coverage.Tests.ps1` | Pester coverage | 1, 2, 3, 4, 5 |
| `hub-lib.ps1` | shared helpers: `Save-IssueBundle` (now `-FileName`), `Save-IssuesIndex`, `Get-ClusterName`, `Get-UnapprovedIssues` | 4, 5 |
| `new-worktree.ps1` | provisioning: new `-Issues` grouped mode | 5 |
| `WORKTREE.md` | standing rules: a "Grouped waves" subsection | 6 |
| `CLAUDE.md` | hub docs: grouped solver prompt, `-Issues` provisioning, `register -Issues`, grouped merge | 6 |

---

## Task 1: `worktree_issue` schema + `register -Issues`

**Files:**
- Modify: `review-coverage.ps1` (init schema block; param block; `register` verb)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append this `Describe` block to the end of `review-coverage.Tests.ps1` (after the closing `}` of the
`'issue clusters'` describe, line ~381):

```powershell
Describe 'worktree_issue (grouped-wave membership)' {
    It 'init creates the worktree_issue table and is idempotent' {
        $db = New-TempDb
        & $script:rc init -DbPath $db | Out-Null    # re-run init on an already-init'd db
        (& sqlite3 $db "SELECT name FROM sqlite_master WHERE type='table' AND name='worktree_issue';") | Should -Be 'worktree_issue'
    }
    It 'register -Issues records the lowest as primary and one worktree_issue row per member' {
        $db = New-TempDb
        & $script:rc register -Worktree 'cluster-12-x' -WType solver -Issues 15,12,19 -Branch 'fix/cluster-12-x' -DbPath $db | Out-Null
        (& sqlite3 $db "SELECT issue FROM worktree WHERE name='cluster-12-x';") | Should -Be '12'
        (& sqlite3 $db "SELECT group_concat(issue_number) FROM (SELECT issue_number FROM worktree_issue WHERE worktree='cluster-12-x' ORDER BY issue_number);") | Should -Be '12,15,19'
    }
    It 'register -Issue (single) writes no worktree_issue rows' {
        $db = New-TempDb
        & $script:rc register -Worktree 'issue-42-y' -WType solver -Issue 42 -Branch 'fix/issue-42-y' -DbPath $db | Out-Null
        (& sqlite3 $db "SELECT count(*) FROM worktree_issue WHERE worktree='issue-42-y';") | Should -Be '0'
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*worktree_issue*'`
Expected: FAIL (no `worktree_issue` table; `register` ignores `-Issues`).

- [ ] **Step 3: Add the `worktree_issue` table to the `init` schema block**

In `review-coverage.ps1`, find (in the `Exec @'…'@` schema block):

```
CREATE TABLE IF NOT EXISTS issue_link(
  id INTEGER PRIMARY KEY, issue_number INTEGER NOT NULL, related_number INTEGER NOT NULL,
  kind TEXT NOT NULL, note TEXT, created_at TEXT DEFAULT (datetime('now')));
```

Add immediately after it:

```
CREATE TABLE IF NOT EXISTS worktree_issue(
  id INTEGER PRIMARY KEY, worktree TEXT NOT NULL, issue_number INTEGER NOT NULL,
  UNIQUE(worktree, issue_number));
```

Then find:

```
CREATE INDEX IF NOT EXISTS ix_issue_target_path ON issue_target(path);
```

Add immediately after it:

```
CREATE INDEX IF NOT EXISTS ix_worktree_issue_wt ON worktree_issue(worktree);
CREATE INDEX IF NOT EXISTS ix_worktree_issue_issue ON worktree_issue(issue_number);
```

- [ ] **Step 4: Add the `-Issues` param**

In the `param(...)` block, find:

```powershell
    [int]$Issue, [string]$Branch, [int]$Pr, [string]$Area, [string]$Note,
```

Replace with (adds `[int[]]$Issues`):

```powershell
    [int]$Issue, [int[]]$Issues, [string]$Branch, [int]$Pr, [string]$Area, [string]$Note,   # -Issues: grouped-wave membership (register)
```

- [ ] **Step 5: Teach `register` to write the membership**

Find the whole `'register'` case:

```powershell
    'register' {
        if (-not $Worktree) { throw "register requires -Worktree" }
        $wt = q $Worktree; $wt2 = q $WType
        Exec "INSERT INTO worktree(name,wtype,issue,branch,status,note,updated_at) VALUES('$wt','$wt2',$(NullableInt $Issue),'$(q $Branch)','registered','$(q $Note)',datetime('now')) ON CONFLICT(name) DO UPDATE SET wtype=excluded.wtype, issue=excluded.issue, branch=excluded.branch, updated_at=datetime('now');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','$wt2','registered','$(q $Branch)');"
        Write-Host "registered worktree '$Worktree' (issue $Issue)." -ForegroundColor Green
    }
```

Replace with:

```powershell
    'register' {
        if (-not $Worktree) { throw "register requires -Worktree" }
        $wt = q $Worktree; $wt2 = q $WType
        # Grouped wave: -Issues 12,15,19 records the lowest member as worktree.issue (display/back-compat)
        # plus one worktree_issue row per member (the full membership). Single -Issue is unchanged (no join rows).
        $members = @($Issues | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
        $primary = if ($members.Count) { [int]$members[0] } else { $Issue }
        Exec "INSERT INTO worktree(name,wtype,issue,branch,status,note,updated_at) VALUES('$wt','$wt2',$(NullableInt $primary),'$(q $Branch)','registered','$(q $Note)',datetime('now')) ON CONFLICT(name) DO UPDATE SET wtype=excluded.wtype, issue=excluded.issue, branch=excluded.branch, updated_at=datetime('now');"
        foreach ($m in $members) { Exec "INSERT OR IGNORE INTO worktree_issue(worktree,issue_number) VALUES('$wt',$m);" }
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','$wt2','registered','$(q $Branch)');"
        $label = if ($members.Count -gt 1) { "issues $($members -join ',')" } else { "issue $primary" }
        Write-Host "registered worktree '$Worktree' ($label)." -ForegroundColor Green
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*worktree_issue*'`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): worktree_issue join table + register -Issues (grouped-wave membership)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Unified membership (clusters + next + monitor)

Rewire every "issues/paths owned by an ACTIVE worktree" read to the membership union
`{worktree.issue} ∪ {worktree_issue}`, via one shared helper.

**Files:**
- Modify: `review-coverage.ps1` (new `ActiveMemberIssuesSql` helper; `Get-IssueClusterPlan` claimed + eligibility; `issue next` claimed + candidates; `monitor` owns + issue display)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'grouped-wave in-flight (membership union)' {
    It 'clusters defers an approved issue colliding on a NON-primary member of an active grouped worktree' {
        $db = New-TempDb
        # active grouped worktree owns {12,15,19}; member 19 owns src/c.ts. New approved issue 30 also owns src/c.ts.
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'collides on c','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(19,'src/c.ts','owns'),(30,'src/c.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status) VALUES('cluster-12-x','solver',12,'working');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree_issue(worktree,issue_number) VALUES('cluster-12-x',12),('cluster-12-x',15),('cluster-12-x',19);" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match '#30.*in-flight area'
    }
    It 'issue next defers the same collision via the membership union' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(30,'collides on c','approved','simple','user','High');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(19,'src/c.ts','owns'),(30,'src/c.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status) VALUES('cluster-12-x','solver',12,'working');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree_issue(worktree,issue_number) VALUES('cluster-12-x',12),('cluster-12-x',15),('cluster-12-x',19);" | Out-Null
        $out = (& $script:rc issue next -DbPath $db 6>&1) -join "`n"
        $out | Should -Match '#30 -> collides on src/c.ts'
    }
    It 'monitor shows a grouped worktree with a (+k) issue tag' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/a.ts','owns'),(15,'src/b.ts','owns'),(19,'src/c.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree(name,wtype,issue,status) VALUES('cluster-12-x','solver',12,'working');" | Out-Null
        & sqlite3 $db "INSERT INTO worktree_issue(worktree,issue_number) VALUES('cluster-12-x',12),('cluster-12-x',15),('cluster-12-x',19);" | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match '12 \(\+2\)'
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*membership union*'`
Expected: FAIL (member 19's path isn't seen as claimed; monitor has no `(+k)`).

- [ ] **Step 3: Add the shared membership-subquery helper**

In `review-coverage.ps1`, find:

```powershell
function NullableInt([int]$v) { if ($v -gt 0) { "$v" } else { 'NULL' } }
```

Add immediately after it:

```powershell
# Issue numbers owned by an ACTIVE worktree: the single worktree.issue UNION the worktree_issue
# join rows (grouped waves). The one in-flight/eligibility definition shared by clusters + next.
function ActiveMemberIssuesSql([string]$ActiveStatuses) {
    "SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($ActiveStatuses) " +
    "UNION SELECT wi.issue_number FROM worktree_issue wi JOIN worktree w ON w.name=wi.worktree WHERE w.status IN ($ActiveStatuses)"
}
```

- [ ] **Step 4: Rewire `Get-IssueClusterPlan` (claimed paths + eligibility)**

Find:

```powershell
    foreach ($p in @(& sqlite3 $Db "SELECT DISTINCT t.path FROM issue_target t JOIN worktree w ON w.issue=t.issue_number WHERE t.ownership='owns' AND w.status IN ($activeStatuses);")) {
```

Replace with:

```powershell
    foreach ($p in @(& sqlite3 $Db "SELECT DISTINCT path FROM issue_target WHERE ownership='owns' AND issue_number IN ($(ActiveMemberIssuesSql $activeStatuses));")) {
```

Then find:

```powershell
    $rows = @(& sqlite3 -separator '|' $Db "SELECT number, COALESCE(track,''), origin, COALESCE(severity,'-'), substr(replace(title,'|','/'),1,42) FROM issue WHERE review_status='approved' AND number NOT IN (SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($activeStatuses)) ORDER BY (origin='user') DESC, $sevCase, number;")
```

Replace with:

```powershell
    $rows = @(& sqlite3 -separator '|' $Db "SELECT number, COALESCE(track,''), origin, COALESCE(severity,'-'), substr(replace(title,'|','/'),1,42) FROM issue WHERE review_status='approved' AND number NOT IN ($(ActiveMemberIssuesSql $activeStatuses)) ORDER BY (origin='user') DESC, $sevCase, number;")
```

- [ ] **Step 5: Rewire `issue next` (claimed paths + candidates)**

Find:

```powershell
                $activePaths = @(& sqlite3 $db "SELECT DISTINCT t.path FROM issue_target t JOIN worktree w ON w.issue=t.issue_number WHERE t.ownership='owns' AND w.status IN ($activeStatuses);")
```

Replace with:

```powershell
                $activePaths = @(& sqlite3 $db "SELECT DISTINCT path FROM issue_target WHERE ownership='owns' AND issue_number IN ($(ActiveMemberIssuesSql $activeStatuses));")
```

Then find:

```powershell
                $cands = @(& sqlite3 $db "SELECT number FROM issue WHERE review_status='approved' AND number NOT IN (SELECT issue FROM worktree WHERE issue IS NOT NULL AND status IN ($activeStatuses)) ORDER BY (origin='user') DESC, CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END, number;")
```

Replace with:

```powershell
                $cands = @(& sqlite3 $db "SELECT number FROM issue WHERE review_status='approved' AND number NOT IN ($(ActiveMemberIssuesSql $activeStatuses)) ORDER BY (origin='user') DESC, CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END, number;")
```

- [ ] **Step 6: Rewire `monitor` (owns-count over membership + `(+k)` issue display)**

Find:

```powershell
        Query @"
SELECT name, wtype AS type, COALESCE(issue,'') AS issue, COALESCE(pr,'') AS pr, status,
  CAST((julianday('now')-julianday(updated_at))*1440 AS INT) AS upd_min,
  (SELECT count(*) FROM issue_target t WHERE t.issue_number=worktree.issue AND t.ownership='owns') AS owns,
  (SELECT count(*) FROM recommendation r WHERE r.worktree=worktree.name AND r.status='proposed') AS recs
FROM worktree
```

Replace with:

```powershell
        Query @"
SELECT name, wtype AS type,
  CASE WHEN (SELECT count(*) FROM worktree_issue wi WHERE wi.worktree=worktree.name) > 1
       THEN COALESCE(CAST(issue AS TEXT),'') || ' (+' || ((SELECT count(*) FROM worktree_issue wi WHERE wi.worktree=worktree.name)-1) || ')'
       ELSE COALESCE(CAST(issue AS TEXT),'') END AS issue,
  COALESCE(pr,'') AS pr, status,
  CAST((julianday('now')-julianday(updated_at))*1440 AS INT) AS upd_min,
  (SELECT count(DISTINCT t.path) FROM issue_target t WHERE t.ownership='owns' AND t.issue_number IN (
     SELECT worktree.issue UNION SELECT wi.issue_number FROM worktree_issue wi WHERE wi.worktree=worktree.name)) AS owns,
  (SELECT count(*) FROM recommendation r WHERE r.worktree=worktree.name AND r.status='proposed') AS recs
FROM worktree
```

- [ ] **Step 7: Run the new tests AND the existing clusters/next/monitor tests (no regression)**

```powershell
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*membership union*'
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'
```
Expected: PASS — the 3 new membership tests, and all existing `issue clusters` tests still green (single-issue
worktrees have no `worktree_issue` rows, so the union reduces to the old behavior).

- [ ] **Step 8: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): membership-aware in-flight across clusters/next/monitor (worktree_issue union)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Sibling-precision hardening (the 3 Phase-1 matcher fixes)

**Files:**
- Modify: `review-coverage.ps1` (`Get-IssueClusterPlan` advisory-sibling block)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'issue clusters sibling-precision hardening' {
    It 'matches a needle containing [ ] literally (no wildcard char-class)' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/app/[id].tsx','owns'),(15,'src/app/[id].tsx','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('dynamic route bug','Medium','proposed','fix src/app/[id].tsx render','app/route');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'finding #1.*\[path\]'   # [id].tsx matched literally, not as a char class
    }
    It 'does not corrupt parsing when a finding scope contains a pipe' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/q.ts','owns'),(15,'src/lib/q.ts','owns');" | Out-Null
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('piped scope','Medium','proposed','a|b in src/lib/q.ts','app/db');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'finding #1.*\[path\]'   # the pipe in scope did not shift the |-split parse
    }
    It 'demotes a generic basename to [path:base] but keeps a specific basename as [path]' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status,track,origin,severity) VALUES(12,'a','approved','simple','user','High'),(15,'b','approved','simple','user','Medium');" | Out-Null
        # 12 & 15 share src/lib/shared.ts -> one cluster; files include the generic index.ts and the specific page-queries.ts
        & sqlite3 $db "INSERT INTO issue_target(issue_number,path,ownership) VALUES(12,'src/lib/shared.ts','owns'),(12,'src/lib/index.ts','owns'),(15,'src/lib/shared.ts','owns'),(15,'src/lib/page-queries.ts','owns');" | Out-Null
        # finding mentions only the generic basename 'index.ts' (no dir) -> weak
        & sqlite3 $db "INSERT INTO finding(title,severity,status,scope,topic) VALUES('generic','Low','proposed','something in index.ts somewhere','x');" | Out-Null
        # rec mentions the specific basename 'page-queries.ts' -> strong
        & sqlite3 $db "INSERT INTO recommendation(title,severity,status,scope) VALUES('specific','Low','proposed','page-queries.ts needs work');" | Out-Null
        $out = (& $script:rc issue clusters -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'finding #1.*\[path:base\]'
        $out | Should -Match 'rec     #1.*\[path\]'
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*sibling-precision*'`
Expected: FAIL (`[id]` mis-parses as a char class; pipe shifts the split; `index.ts` shows `[path]` not
`[path:base]`).

- [ ] **Step 3: Sanitize the pipe-delimited sibling SELECTs (fix #2)**

In `Get-IssueClusterPlan`, find:

```powershell
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), COALESCE(scope,''), COALESCE(topic,''), substr(replace(title,'|','/'),1,40) FROM finding WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'finding'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), COALESCE(scope,''), COALESCE(area,''), substr(replace(title,'|','/'),1,40) FROM recommendation WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'rec'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
```

Replace with (wrap `scope`/`topic`/`area` in `replace(...,'|','/')` like `title` already is):

```powershell
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), replace(COALESCE(scope,''),'|','/'), replace(COALESCE(topic,''),'|','/'), substr(replace(title,'|','/'),1,40) FROM finding WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'finding'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
    foreach ($r in @(& sqlite3 -separator '|' $Db "SELECT id, COALESCE(severity,'-'), replace(COALESCE(scope,''),'|','/'), replace(COALESCE(area,''),'|','/'), substr(replace(title,'|','/'),1,40) FROM recommendation WHERE status='proposed';")) {
        if ($r) { $g = $r -split '\|', 5; $sib += [pscustomobject]@{ Type = 'rec'; Id = [int]$g[0]; Sev = $g[1]; Scope = $g[2]; Area = $g[3]; Title = $g[4] } }
    }
```

- [ ] **Step 4: Build strong/weak needles (fix #3) and escape on match (fix #1)**

In `Get-IssueClusterPlan`, find:

```powershell
        $pathNeedles = @(); $dirs = @()
        foreach ($p in $cl.Files) {
            $pathNeedles += $p
            $pathNeedles += (($p -split '[\\/]')[-1])                       # basename
            if ($p -match '[\\/]') { $dirs += ($p -replace '[\\/][^\\/]*$', '') }   # containing dir
        }
```

Replace with:

```powershell
        # generic basenames are too common to be a STRONG path signal on their own -> demote to weak [path:base]
        $genericBase = @('index.ts','index.tsx','index.js','index.jsx','types.ts','utils.ts','helpers.ts','constants.ts','config.ts','mod.ts','main.ts','__init__.py')
        $strongNeedles = @(); $weakNeedles = @(); $dirs = @()
        foreach ($p in $cl.Files) {
            $strongNeedles += $p                                            # full path: always strong
            $base = ($p -split '[\\/]')[-1]
            if ($genericBase -contains $base.ToLowerInvariant()) { $weakNeedles += $base } else { $strongNeedles += $base }
            if ($p -match '[\\/]') { $dirs += ($p -replace '[\\/][^\\/]*$', '') }   # containing dir
        }
```

Then find:

```powershell
        $matched = @()
        foreach ($s in $sib) {
            $isPath = $false
            foreach ($n in $pathNeedles) { if ($n -and $s.Scope -like "*$n*") { $isPath = $true; break } }
            $isArea = $false
            if (-not $isPath -and $s.Area) { foreach ($n in $areaNeedles) { if ($n -and $s.Area -like "*$n*") { $isArea = $true; break } } }
            if ($isPath -or $isArea) { $matched += [pscustomobject]@{ Type = $s.Type; Id = $s.Id; Sev = $s.Sev; Title = $s.Title; Why = $(if ($isPath) { 'path' } else { 'area' }) } }
        }
        $cl.Siblings = @($matched | Sort-Object @{ e = { if ($sevRank.ContainsKey($_.Sev)) { $sevRank[$_.Sev] } else { 4 } } }, Id)
```

Replace with (three tiers; every needle escaped so `[`…`]` matches literally; severity stays the primary
sort so the existing "top-5 by severity" cap is preserved, with `path:base` demoted within a severity):

```powershell
        $matched = @()
        foreach ($s in $sib) {
            $why = $null
            foreach ($n in $strongNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Scope -like "*$en*") { $why = 'path'; break } } }
            if (-not $why) { foreach ($n in $weakNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Scope -like "*$en*") { $why = 'path:base'; break } } } }
            if (-not $why -and $s.Area) { foreach ($n in $areaNeedles) { if ($n) { $en = [System.Management.Automation.WildcardPattern]::Escape($n); if ($s.Area -like "*$en*") { $why = 'area'; break } } } }
            if ($why) { $matched += [pscustomobject]@{ Type = $s.Type; Id = $s.Id; Sev = $s.Sev; Title = $s.Title; Why = $why } }
        }
        $whyRank = @{ 'path' = 0; 'area' = 1; 'path:base' = 2 }
        $cl.Siblings = @($matched | Sort-Object `
            @{ e = { if ($sevRank.ContainsKey($_.Sev)) { $sevRank[$_.Sev] } else { 4 } } }, `
            @{ e = { $whyRank[$_.Why] } }, Id)
```

- [ ] **Step 5: Strengthen the existing read-only invariant test (optional fix #4)**

In `review-coverage.Tests.ps1`, find the line inside the `'mutates only the activity table (read-only over the
backlog)'` test:

```powershell
        $sig = "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM issue_target)||'/'||(SELECT count(*) FROM finding)||'/'||(SELECT count(*) FROM recommendation)||'/'||(SELECT count(*) FROM worktree)||'|'||COALESCE((SELECT group_concat(status) FROM finding),'')||'|'||COALESCE((SELECT group_concat(status) FROM recommendation),'');"
```

Replace with (adds `worktree_issue` count + the issues' `review_status` snapshot):

```powershell
        $sig = "SELECT (SELECT count(*) FROM issue)||'/'||(SELECT count(*) FROM issue_target)||'/'||(SELECT count(*) FROM finding)||'/'||(SELECT count(*) FROM recommendation)||'/'||(SELECT count(*) FROM worktree)||'/'||(SELECT count(*) FROM worktree_issue)||'|'||COALESCE((SELECT group_concat(status) FROM finding),'')||'|'||COALESCE((SELECT group_concat(status) FROM recommendation),'')||'|'||COALESCE((SELECT group_concat(review_status) FROM issue),'');"
```

- [ ] **Step 6: Run the new tests AND the existing sibling tests (no regression)**

```powershell
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*sibling-precision*'
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'
```
Expected: PASS — the 3 new precision tests; the existing path/area sibling tests stay green (their fixtures use
specific basenames like `page-queries.ts`/`cache.ts`/`store.ts`, which remain STRONG `[path]`/`[area]`).

- [ ] **Step 7: Commit**

```bash
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "fix(ledger): harden clusters sibling matcher (wildcard escape, pipe-safe fields, generic-basename demotion)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Grouped briefs — `Save-IssueBundle -FileName` + `Save-IssuesIndex`

**Files:**
- Modify: `hub-lib.ps1` (add `-FileName` to `Save-IssueBundle`; add `Save-IssuesIndex`)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'Save-IssuesIndex (grouped-wave cover sheet)' {
    BeforeAll { . (Join-Path $PSScriptRoot 'hub-lib.ps1') }
    It 'writes ISSUES.md listing members, shared files, advisory siblings, and the one-PR rule' {
        $dest = Join-Path $TestDrive ("wt-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $members = @(
            [pscustomobject]@{ Number = 12; Title = 'page n+1'; Origin = 'user'; Severity = 'High' },
            [pscustomobject]@{ Number = 15; Title = 'cache pages'; Origin = 'recon'; Severity = 'Medium' }
        )
        $sibs = @([pscustomobject]@{ Type = 'finding'; Id = 81; Sev = 'Medium'; Why = 'path'; Title = 'missing index' })
        $p = Save-IssuesIndex -Dest $dest -Members $members -SharedPaths @('src/lib/page-queries.ts') -Siblings $sibs -Area 'src/lib'
        Test-Path $p | Should -BeTrue
        $txt = Get-Content $p -Raw
        $txt | Should -Match 'issues #12, #15'
        $txt | Should -Match 'ISSUE-12\.md'
        $txt | Should -Match 'src/lib/page-queries\.ts'
        $txt | Should -Match 'finding #81'
        $txt | Should -Match 'Fixes #<n>'
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Save-IssuesIndex*'`
Expected: FAIL (`Save-IssuesIndex` is not defined).

- [ ] **Step 3: Add `-FileName` to `Save-IssueBundle`**

In `hub-lib.ps1`, find the `Save-IssueBundle` param block:

```powershell
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Dest,
        [string]$Repo,   # defaults to $HubConfig.repo when called from a hub script
        [string]$AssetsSubdir = "issue-assets"
    )
```

Replace with:

```powershell
    param(
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][string]$Dest,
        [string]$Repo,   # defaults to $HubConfig.repo when called from a hub script
        [string]$AssetsSubdir = "issue-assets",
        [string]$FileName = "ISSUE.md"   # grouped waves pass ISSUE-<n>.md; single-issue default unchanged
    )
```

Then find:

```powershell
    $issueMd = Join-Path $Dest "ISSUE.md"
```

Replace with:

```powershell
    $issueMd = Join-Path $Dest $FileName
```

- [ ] **Step 4: Add `Save-IssuesIndex`**

In `hub-lib.ps1`, find the end of `Save-IssueBundle` (the closing `}` of the function, right before
`function Copy-HubExperts {`). Insert this new function between them:

```powershell
function Save-IssuesIndex {
    <# Write the grouped-wave cover sheet ISSUES.md into $Dest: the member issues (each with its own
       ISSUE-<n>.md brief), the shared owned paths (why these are one wave), and any advisory siblings to
       fold in opportunistically. Pure (no gh / no $HubConfig) so it is unit-testable. Returns the path. #>
    param(
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][object[]]$Members,   # objects with .Number .Title .Origin .Severity
        [string[]]$SharedPaths = @(),
        [object[]]$Siblings = @(),                   # objects with .Type .Id .Sev .Why .Title
        [string]$Area = ''
    )
    $nl = [Environment]::NewLine
    $lines = New-Object System.Collections.Generic.List[string]
    $nums = @($Members | ForEach-Object { $_.Number })
    $lines.Add("# Grouped wave: issues #" + ($nums -join ', #'))
    $lines.Add("")
    if ($Area) { $lines.Add("- Area: $Area") }
    $lines.Add("- Members: " + $Members.Count)
    $lines.Add("")
    $lines.Add("> Local cover sheet fetched by the worktree hub. Git-excluded; safe to read, do not commit.")
    $lines.Add("> You own ALL of these issues in this one worktree: implement each, then open ONE PR whose")
    $lines.Add("> body carries one ``Fixes #<n>`` line per member. Read each ``ISSUE-<n>.md`` for the full brief.")
    $lines.Add("")
    $lines.Add("## Members")
    $lines.Add("")
    foreach ($m in $Members) {
        $lines.Add("- **#$($m.Number)** [$($m.Origin) - $($m.Severity)] $($m.Title)  (brief: ``ISSUE-$($m.Number).md``)")
    }
    $lines.Add("")
    if ($SharedPaths.Count) {
        $lines.Add("## Shared owned files (why these are one wave)")
        $lines.Add("")
        foreach ($p in $SharedPaths) { $lines.Add("- ``$p``") }
        $lines.Add("")
    }
    if ($Siblings.Count) {
        $lines.Add("## Advisory siblings (proposed findings/recs - verify before bundling; fold in only if cheap & in scope)")
        $lines.Add("")
        foreach ($s in $Siblings) { $lines.Add("- $($s.Type) #$($s.Id) [$($s.Sev)] ($($s.Why)) - $($s.Title)") }
        $lines.Add("")
    }
    $issuesMd = Join-Path $Dest "ISSUES.md"
    [System.IO.File]::WriteAllText($issuesMd, ($lines -join $nl), (New-Object System.Text.UTF8Encoding($false)))
    return $issuesMd
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*Save-IssuesIndex*'`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
git add hub-lib.ps1 review-coverage.Tests.ps1
git commit -m "feat(hub-lib): Save-IssueBundle -FileName + Save-IssuesIndex (grouped-wave briefs)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `new-worktree.ps1 -Issues` provisioning

The provisioning script shells out to `git`/`gh`, so the TDD-able logic is factored into two pure-ish
`hub-lib.ps1` helpers (tested here); the script wiring is verified by review + a manual smoke test.

**Files:**
- Modify: `hub-lib.ps1` (`Get-ClusterName`, `Get-UnapprovedIssues`)
- Modify: `new-worktree.ps1` (`-Issues` param + grouped mode)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing helper tests**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'grouped provisioning helpers' {
    BeforeAll { . (Join-Path $PSScriptRoot 'hub-lib.ps1') }
    It 'Get-ClusterName builds cluster-<lowest>-<slug>' {
        Get-ClusterName -Lowest 12 -Title 'Fix N+1 in page queries' | Should -Be 'cluster-12-fix-n-1-in-page-queries'
    }
    It 'Get-UnapprovedIssues returns only the non-approved members' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status) VALUES(12,'a','approved'),(15,'b','reviewed'),(19,'c','approved');" | Out-Null
        $bad = @(Get-UnapprovedIssues -Db $db -Numbers @(12,15,19))
        $bad.Count | Should -Be 1
        $bad[0].Issue | Should -Be 15
        $bad[0].Status | Should -Be 'reviewed'
    }
    It 'Get-UnapprovedIssues reports an unsynced member as not synced' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO issue(number,title,review_status) VALUES(12,'a','approved');" | Out-Null
        $bad = @(Get-UnapprovedIssues -Db $db -Numbers @(12,99))
        $bad.Count | Should -Be 1
        $bad[0].Issue | Should -Be 99
        $bad[0].Status | Should -Be 'not synced'
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*grouped provisioning helpers*'`
Expected: FAIL (`Get-ClusterName` / `Get-UnapprovedIssues` not defined).

- [ ] **Step 3: Add the two helpers to `hub-lib.ps1`**

In `hub-lib.ps1`, find:

```powershell
function Get-IssueAttachmentUrls {
```

Insert these two functions immediately BEFORE it (so they sit right after `ConvertTo-Slug`, which
`Get-ClusterName` uses):

```powershell
function Get-ClusterName {
    # Folder/branch stem for a grouped wave: cluster-<lowest>-<slug-from-lowest-title>.
    param([Parameter(Mandatory)][int]$Lowest, [string]$Title)
    "cluster-$Lowest-$(ConvertTo-Slug $Title)"
}

function Get-UnapprovedIssues {
    # The members NOT review_status='approved' in the ledger (the grouped provisioning gate).
    # Returns objects with .Issue and .Status ('not synced' when the issue isn't in the ledger).
    param([Parameter(Mandatory)][string]$Db, [Parameter(Mandatory)][int[]]$Numbers)
    $bad = @()
    foreach ($n in $Numbers) {
        $rs = (& sqlite3 $Db "SELECT COALESCE(review_status,'') FROM issue WHERE number=$n;")
        if ($LASTEXITCODE -ne 0) { throw "sqlite3 read failed for issue $n (exit $LASTEXITCODE)" }
        if ($rs -ne 'approved') { $bad += [pscustomobject]@{ Issue = $n; Status = $(if ($rs) { $rs } else { 'not synced' }) } }
    }
    return $bad
}
```

- [ ] **Step 4: Run the helper tests to verify they pass**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*grouped provisioning helpers*'`
Expected: PASS (3 tests).

- [ ] **Step 5: Add the `-Issues` param to `new-worktree.ps1`**

In `new-worktree.ps1`, find:

```powershell
    [int]$Issue = 0,                    # GitHub issue number -> pulls the issue's full resources
```

Add immediately after it:

```powershell
    [int[]]$Issues,                     # grouped wave: 2+ approved issues -> ONE worktree (cluster-<lowest>-..)
```

- [ ] **Step 6: Parse grouped mode + derive the cluster name**

In `new-worktree.ps1`, find:

```powershell
if (-not $Repo) { $Repo = $HubConfig.repo }
if (-not $BaseBranch) { $BaseBranch = $HubConfig.defaultBranch }
```

Add immediately after it:

```powershell
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
```

- [ ] **Step 7: Add the grouped review gate**

In `new-worktree.ps1`, find the end of the single-issue gate (the closing of its `if` block):

```powershell
            }
        }
    }
}

Write-Host "==> Fetching origin..." -ForegroundColor Cyan
```

Replace with (inserts the grouped gate between the single gate and the fetch):

```powershell
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
            $bad = @(Get-UnapprovedIssues -Db $covDb -Numbers $grouped)
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
```

- [ ] **Step 8: Add the grouped bundle (per-member briefs + ISSUES.md)**

In `new-worktree.ps1`, find the end of the single-issue bundle block:

```powershell
    catch {
        Write-Host "    WARNING: couldn't build issue bundle: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- worktree rules: copy canonical WORKTREE.md in + git-exclude it (force-included via @-mention) ---
```

Replace with (inserts the grouped bundle between the single bundle and the WORKTREE.md copy):

```powershell
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
        catch { Write-Host "    WARNING: couldn't bundle #$n: $($_.Exception.Message)" -ForegroundColor Yellow; $ti = "#$n" }
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
```

- [ ] **Step 9: Print the grouped register hint**

In `new-worktree.ps1`, find:

```powershell
Write-Host "Remember to add a row to the Worktree registry in CLAUDE.md." -ForegroundColor DarkGray
```

Add immediately BEFORE it:

```powershell
if ($isGrouped) {
    Write-Host "Grouped wave members: $($grouped -join ', ')  (briefs: ISSUE-<n>.md + ISSUES.md)" -ForegroundColor Green
    Write-Host "Register on the monitor:" -ForegroundColor Green
    Write-Host "    & `"$Hub\review-coverage.ps1`" register -Worktree $Name -WType solver -Issues $($grouped -join ',') -Branch $br" -ForegroundColor Green
}
```

- [ ] **Step 10: Smoke-test the wiring (manual; git/gh integration not unit-tested)**

Run a dry parse check — confirm the script loads and the grouped guards fire without touching git/gh:

```powershell
# 1 issue -> guidance error (not a wave):
try { .\new-worktree.ps1 -Issues 12 } catch { $_.Exception.Message }   # expect: "Use -Issue <N> ... 2+ approved issues."
# both flags -> error:
try { .\new-worktree.ps1 -Issue 5 -Issues 12,15 } catch { $_.Exception.Message }   # expect: "Pass either -Issue ... or -Issues ..., not both."
```
Expected: each prints its guard message and creates no worktree. (Full provisioning — `gh` fetch, `git
worktree add`, the bundle — is exercised live when you next provision a real approved wave; it is covered by
review here, not a unit test.)

- [ ] **Step 11: Commit**

```bash
git add hub-lib.ps1 new-worktree.ps1 review-coverage.Tests.ps1
git commit -m "feat(provisioning): new-worktree.ps1 -Issues (grouped-wave worktree: gate, briefs, ISSUES.md, register hint)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Grouped seed prompt + WORKTREE.md rules + CLAUDE.md docs

Documentation/prompt changes plus a one-line render-hint update. No new unit tests; the gate is re-running
the existing suite (the changed render line keeps the `new-worktree.ps1 -Issues 12,15` substring the tests
match) and review.

**Files:**
- Modify: `review-coverage.ps1` (the `clusters` provision-hint line; `register` help/usage strings)
- Modify: `WORKTREE.md` (a "Grouped waves" subsection)
- Modify: `CLAUDE.md` (grouped solver prompt; `-Issues` provisioning doc; `register -Issues` doc; grouped merge note)

- [ ] **Step 1: Update the `clusters` provision hint (it is real now, not "Phase 2 will")**

In `review-coverage.ps1`, find:

```powershell
                    Write-Host ("  -> Phase 2 will provision: new-worktree.ps1 -Issues {0}" -f (@($cl.Members) -join ',')) -ForegroundColor DarkCyan
```

Replace with:

```powershell
                    Write-Host ("  -> provision: new-worktree.ps1 -Issues {0}" -f (@($cl.Members) -join ',')) -ForegroundColor DarkCyan
```

- [ ] **Step 2: Add `-Issues` to the `register` help/usage strings**

In `review-coverage.ps1`, find (in the comment-help header near the top):

```
      register -Worktree w -WType solver -Issue N -Branch b      (orchestrator: add a worktree to the monitor)
```

Replace with:

```
      register -Worktree w -WType solver -Issue N -Branch b      (orchestrator: add a worktree to the monitor)
      register -Worktree w -WType solver -Issues N,M,.. -Branch b (grouped wave: links all members)
```

Then find (in the `default` usage block):

```powershell
        Write-Host "  worktree : register -Worktree w -WType solver -Issue N -Branch b"
```

Replace with:

```powershell
        Write-Host "  worktree : register -Worktree w -WType solver -Issue N -Branch b   (grouped wave: -Issues N,M,..)"
```

- [ ] **Step 3: Add a "Grouped waves" subsection to `WORKTREE.md`**

In `WORKTREE.md`, find the end of section 2 (the line just before `## 3. Gated complex workflow`):

```
If the fix turns out **larger or more architectural than expected**, switch to the gated track (section 3):
write a **proper** `SPEC.md` + `PLAN.md` and **STOP for the user's review** before implementing.
```

Add immediately after it:

```markdown

### 2a. Grouped waves (when your launch prompt names several issues)

If your launch prompt says you own a **grouped wave** (several issues — e.g. `#12, #15, #19` — in this one
worktree, with `@ISSUES.md` and one `@ISSUE-<n>.md` per member force-included), follow section 2 with these
deltas:

1. **One worktree, one branch, ONE PR.** Implement every member's fix on this branch; open a single PR whose
   body carries **one `Fixes #<n>` line per member** (each on its own line) so GitHub closes them all on merge.
2. **Stage-one product-necessity gate runs ONCE for the wave but judges EACH member** (§6a). Route the
   persona by the wave's dominant area. If the persona flags a member as not-necessary, handle **that member
   individually** per §6a (drop it or ask) — do **not** halt the whole wave; user-origin members are never
   auto-HALTed. *Dropping a member* = don't implement it, omit its `Fixes #<n>` line, and surface it in the
   completion report for the user to close or re-triage — never silently skipped.
3. **Advisory siblings** listed in `ISSUES.md` are `proposed` findings/recs, **not** approved work. Fold one
   in only if it is cheap and in-scope for files you are already touching; note any you address in the PR.
   Otherwise leave them.
4. **Completion report:** use the `Issues|#12,#15,#19 - <area>` form (one row), add a one-line per-member
   acceptance summary, and keep every other field as in section 4.
```

- [ ] **Step 4: Add the grouped solver prompt + `-Issues` provisioning doc to `CLAUDE.md`**

In `CLAUDE.md`, find the canonical autonomous (simple-track) solver prompt's closing fence and the line after
it:

```
Begin.
```
```

**Complex worktrees** (multi-file / architectural / new subsystem / ambiguous or open-ended): use the
```

Insert between the closing ` ``` ` of the `Begin.` block and the `**Complex worktrees**` paragraph:

````markdown

#### Grouped-wave solver prompt (one worktree → one PR closing N issues)

When you provisioned a cluster with `new-worktree.ps1 -Issues 12,15,19`, seed the worktree with this
variant — it `@`-mentions the `ISSUES.md` index plus every member brief, and tells the agent to close all
members in one PR:

```text
@WORKTREE.md
@ISSUES.md
@ISSUE-12.md
@ISSUE-15.md
@ISSUE-19.md

You are the autonomous solver for a GROUPED WAVE of GitHub issues #12, #15, #19 (repo <owner/repo>) — same
area. Worktree: <FOLDER>   Branch: <BRANCH>

WORKTREE.md (above) is your operating manual — follow it, especially §2a "Grouped waves". ISSUES.md is the
wave cover sheet; each ISSUE-<n>.md is that member's full brief (all force-included above).

You own ALL of these issues in this one worktree. Implement each member's fix on this branch, then open ONE
PR whose body has one `Fixes #<n>` line per member (#12, #15, #19) so they all auto-close on merge. DO NOT
merge.

Stage one (before any code): run the stage-one product-necessity gate (WORKTREE.md §6a) ONCE for the wave,
routed to <ROUTED PERSONA, default hub-product-owner>, judging EACH member. Drop or ask about any member the
persona flags as not-necessary (per §2a) — do not halt the whole wave.

Wave-specific steer: <any per-member guidance>

Begin.
```
````

Then find the issue-provisioning example in the "Provisioning a new agent worktree" section:

```powershell
# Work a GitHub issue (PREFERRED for issues): auto-names the worktree + branch from the
# issue title AND drops the issue's full resources into the worktree (ISSUE.md = text +
# comments + metadata; issue-assets\ = screenshots downloaded with gh auth):
.\new-worktree.ps1 -Issue 42 -Install        # requires the issue to be ledger-approved (gate)
```

Add immediately after it:

```powershell
# Work a GROUPED WAVE from an `issue clusters` proposal (one worktree owning several approved issues):
# auto-names cluster-<lowest>-<slug>, gates that EVERY member is approved, writes ISSUE-<n>.md per member +
# an ISSUES.md cover sheet, and prints the matching `register -Issues` command:
.\new-worktree.ps1 -Issues 12,15,19 -Install   # requires ALL members ledger-approved (gate)
```

- [ ] **Step 5: Document `register -Issues` and the grouped merge in `CLAUDE.md`**

In `CLAUDE.md`, find the register line in the "Register it on the monitor" block:

```powershell
& .\review-coverage.ps1 register -Worktree <folder> -WType solver -Issue <N> -Branch <branch>
```

Replace with:

```powershell
& .\review-coverage.ps1 register -Worktree <folder> -WType solver -Issue <N> -Branch <branch>
# grouped wave (one worktree, several issues) — links all members so in-flight/monitor see the full footprint:
& .\review-coverage.ps1 register -Worktree <folder> -WType solver -Issues <N,M,...> -Branch <branch>
```

Then, in the "Merging a finished PR (merge → migrate)" section, find:

```
1. **Merge** the PR (`gh pr merge <N> --squash --delete-branch`, or as the user directs).
```

Add immediately after it:

```markdown
   - **Grouped wave (one PR closing several issues):** the PR body carries one `Fixes #<n>` line per member,
     so the single squash-merge auto-closes **every** member. In the merge report, render the issue row as
     `Issues #12,#15,#19 (all auto-closed via Fixes)`. `progress -Status merged|retired` keys off the
     worktree name, so it covers the whole wave; the next `issue sync` flips the closed members to `closed`.
```

- [ ] **Step 6: Verify no regression + review the docs render**

```powershell
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed -FullNameFilter '*issue clusters*'
```
Expected: PASS (the provision-hint text changed prefix only; the `new-worktree.ps1 -Issues 12,15` substring
the tests assert is unchanged). Eyeball `WORKTREE.md` §2a and the new `CLAUDE.md` blocks for correct
Markdown/fences.

- [ ] **Step 7: Commit**

```bash
git add review-coverage.ps1 WORKTREE.md CLAUDE.md
git commit -m "docs: grouped-wave solver prompt, WORKTREE.md rules, -Issues provisioning + grouped merge

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full-suite verification

**Files:** none (verification only)

- [ ] **Step 1: Run the FULL Pester suite**

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: PASS — all existing tests (45 at the start of Phase 2) **plus** the new ones from this plan
(Task 1: 3, Task 2: 3, Task 3: 3, Task 4: 1, Task 5: 3 = 13 new → ~58 total), **0 failed, 0 skipped**.

- [ ] **Step 2: If anything fails, fix the cause (never paper over)**

Read the failure, fix the root cause in the relevant task's code, re-run. Do not delete or weaken a failing
assertion to make it pass.

- [ ] **Step 3: Final commit (only if Step 2 required a fix)**

```bash
git add -A
git commit -m "test(ledger): green full suite for issue grouping Phase 2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (performed against the spec)

**1. Spec coverage** — every spec section maps to a task:
- §1 `worktree_issue` schema → Task 1 (table + indexes + idempotency test).
- §2 Unified membership (4 read-paths + monitor) → Task 2 (`ActiveMemberIssuesSql` + clusters/next/monitor rewire + union/`(+k)` tests).
- §3 `register -Issues` → Task 1 (param + verb + tests).
- §4 `-Issues` provisioning (parse, all-approved gate, advisory overlap/in-flight, naming, register hint) → Task 5 (helpers + script wiring; gate via `Get-UnapprovedIssues`, naming via `Get-ClusterName`).
- §5 Grouped briefs (`Save-IssueBundle -FileName`, per-member `ISSUE-<n>.md`, `ISSUES.md`, git-excludes) → Task 4 (helpers) + Task 5 (per-member calls + excludes).
- §6 Grouped seed + WORKTREE.md rules → Task 6 (prompt + §2a).
- §7 Grouped merge/resolve → Task 6 (CLAUDE.md merge note).
- §8 Sibling-precision hardening (3 fixes + optional invariant test) → Task 3.
- §9 Tests → Tasks 1–5 each carry their tests; Task 7 gates the full suite.

**2. Placeholder scan** — no TBD/TODO; every code step shows complete code; the `<owner/repo>` /
`<FOLDER>` / `<N>` tokens inside the seed-prompt and merge-doc blocks are intentional template
placeholders the orchestrator fills (matching the existing Phase-1 prompts), not plan gaps.

**3. Type/identifier consistency** — helper names are used identically where defined and called:
`ActiveMemberIssuesSql` (Task 2, called in `Get-IssueClusterPlan` + `issue next`); `Save-IssuesIndex` (Task 4,
called in Task 5) with the property contract `.Number/.Title/.Origin/.Severity` (members) and
`.Type/.Id/.Sev/.Why/.Title` (siblings) produced by Task 5's `$memberObjs`/`$sibs`; `Get-ClusterName`
(`-Lowest`,`-Title`) and `Get-UnapprovedIssues` (`-Db`,`-Numbers`; returns `.Issue`,`.Status`) defined in
Task 5 Step 3 and consumed in Steps 6–7. The `worktree_issue(worktree, issue_number)` columns are referenced
consistently across schema (Task 1), the membership union (Task 2), `register` (Task 1), and `monitor` (Task 2).
`Save-IssueBundle -FileName`/`-AssetsSubdir` (Task 4) match the per-member call in Task 5 Step 8.

**4. Deliberate scope notes (per spec):** the cluster stays ephemeral (no `cluster` table); `issue next`
keeps its disjoint-singleton behavior; new-worktree's git/gh provisioning is verified by review + a manual
smoke test (its testable logic is the two `hub-lib` helpers); ISSUES.md sibling matching uses a deliberately
simple SQL-side basename match (advisory, decoupled from the precision-hardened `clusters` display matcher).
