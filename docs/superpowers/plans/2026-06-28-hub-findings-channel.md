# Hub-Findings Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated coverage-ledger channel ("hub findings") so worktree agents and the orchestrator can log problems with the hub's *own* operating layer — prompts, `hub.config.json`, helper scripts, memory, and environment assumptions (e.g. pwsh-vs-bash) — and the orchestrator can triage and resolve them, never as a GitHub issue on the target repo.

**Architecture:** A new `hubfinding` SQLite table plus three verbs (`hubfind` / `hub-findings` / `hub-resolve`) added to the existing `review-coverage.ps1`; surfaced via `monitor` and a fifth section in `ledger-to-html.ps1`; agent recognition added to `WORKTREE.md`; triage folded into the merge-time sweep in `CLAUDE.md`. To make the ledger verbs runnable without a fully-configured hub (required for hermetic tests and pre-bootstrap `monitor`), `review-coverage.ps1` and `ledger-to-html.ps1` load `hub-config.ps1` defensively. The tool only *tracks*; the orchestrator makes the real edit/memory-write by hand and then stamps the finding resolved.

**Tech Stack:** PowerShell 7, SQLite (`sqlite3` CLI), Pester 5.7.1 (run from the saved module at `C:\mydev\pester-modules` — see `docs/superpowers/specs/2026-06-28-hub-findings-channel-design.md` and project memory; `Install-Module` does not work on this machine).

**Spec:** `docs/superpowers/specs/2026-06-28-hub-findings-channel-design.md`

---

## File Structure

| File | New/Changed | Responsibility |
|---|---|---|
| `review-coverage.ps1` | changed | defensive config load + `-Db`/`-Target` params; `hubfinding` table in `init`; `hubfind`/`hub-findings`/`hub-resolve` verbs; `monitor` block |
| `review-coverage.Tests.ps1` | new | Pester lifecycle tests against a temp DB |
| `ledger-to-html.ps1` | changed | defensive config load; fifth open-item section (Hub findings) |
| `WORKTREE.md` | changed | new "Hub findings" section + completion-report row + record-to-ledger line (+ renumber §6→§10) |
| `CLAUDE.md` | changed | command list + ledger/tables description + merge-time sweep + rollout note |
| `README.md` | changed (1 line) | mention the channel in the ledger/commands overview |

**Rollout note (call out in Task 8):** the `hubfinding` table is created by `review-coverage.ps1 init` (idempotent). After merging, an existing hub must run `.\review-coverage.ps1 init` once so the table exists; `setup-hub.ps1` already runs `init`, so fresh hubs get it automatically. The optional doctor check for the table is intentionally **out of scope** (YAGNI) for this plan.

**Pester test runner (used in every test step below):**

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```

---

## Task 1: Foundation — `-Db`/`-Target` params + defensive config load

Lets `review-coverage.ps1` run its local-SQLite verbs without `hub.config.json`, and adds the `-Db` (test/override ledger path) and `-Target` (hub-resolve destination) params. Config-dependent verbs still error clearly.

> **Implementation note (deviation applied during build):** `-Db` was renamed to **`-DbPath`**. Under
> `[CmdletBinding()]`, a `-Db` parameter collides with the auto-added `-Debug` common parameter's `db`
> alias (PowerShell raises a `MetadataException` at bind time). Wherever a step below shows `-Db <path>`,
> the built code and the Pester tests use `-DbPath <path>` instead. This param is test/override-only, so
> no user-facing doc references it.

**Files:**
- Modify: `review-coverage.ps1:47-55` (param block tail + config load)
- Create: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `review-coverage.Tests.ps1` with:

```powershell
BeforeAll {
    $script:rc = $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # path to review-coverage.ps1
    function New-TempDb {
        $p = Join-Path $TestDrive ("cov-" + [guid]::NewGuid().ToString('N') + ".db")
        & $script:rc init -Db $p | Out-Null
        return $p
    }
}

Describe 'review-coverage foundation (runs without hub.config.json)' {
    It 'init -Db creates the ledger schema without a configured hub' {
        $db = New-TempDb
        (& sqlite3 $db "SELECT name FROM sqlite_master WHERE type='table' AND name='finding';") | Should -Be 'finding'
    }
    It 'monitor -Db runs without a configured hub (does not throw)' {
        $db = New-TempDb
        { & $script:rc monitor -Db $db | Out-Null } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: FAIL. Without `-Db` the param binding errors, and the hard `. hub-config.ps1` throws "No hub.config.json found" because this checkout has no config.

- [ ] **Step 3: Add the `-Target` and `-Db` params**

In `review-coverage.ps1`, replace the param-block tail (lines 47-48):

```powershell
    [string]$Repo,
    [switch]$DryRun
)
```

with:

```powershell
    [string]$Repo,
    [string]$Target,    # hub-resolve: where the fix landed (prompt|config|script|memory). NB: distinct from -Targets (issue owned-paths).
    [string]$Db,        # override the ledger path (tests / pre-bootstrap); default <hub>\.review\coverage.db
    [switch]$DryRun
)
```

- [ ] **Step 4: Make the config load defensive + add the `-Db` branch**

Replace lines 50-55:

```powershell
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig
if (-not $Repo) { $Repo = $HubConfig.repo }
$reviewDir = Join-Path $Hub '.review'
if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null }
$db = Join-Path $reviewDir 'coverage.db'
```

with:

```powershell
$ErrorActionPreference = 'Stop'
# Ledger/monitor verbs are local SQLite and must work even before the hub is configured
# (no hub.config.json yet — tests, or `monitor` on a half-set-up hub). Only the GitHub/
# base-worktree verbs (seed / promote / file-rec / issue sync) actually need config.
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') }   # sets $Hub + $HubConfig
catch { $Hub = $PSScriptRoot; $HubConfig = $null; $configError = $_ }
if (-not $Repo -and $HubConfig) { $Repo = $HubConfig.repo }
if (-not $HubConfig -and (($Command -in @('seed', 'promote', 'file-rec')) -or ($Command -eq 'issue' -and $Sub -eq 'sync'))) {
    throw $configError
}
$db = if ($Db) { $Db } else {
    $reviewDir = Join-Path $Hub '.review'
    if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null }
    Join-Path $reviewDir 'coverage.db'
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: PASS (2 tests). `init -Db` creates the schema and `monitor -Db` runs, both with no config present.

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): defensive config load + -Db/-Target params for review-coverage"
```

---

## Task 2: Schema — the `hubfinding` table in `init`

**Files:**
- Modify: `review-coverage.ps1:128` and `:135` (inside the `init` heredoc)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1` (before the final closing brace if any — these are top-level `Describe` blocks, so just append at end of file):

```powershell
Describe 'hubfinding schema' {
    It 'init creates the hubfinding table with the expected columns' {
        $db = New-TempDb
        $cols = (& sqlite3 $db "SELECT name FROM pragma_table_info('hubfinding') ORDER BY name;") -join ','
        $cols | Should -Be 'category,created_at,detail,id,resolution,resolved_at,severity,source,status,target,title,wtype'
    }
    It 'hubfinding.status defaults to open' {
        $db = New-TempDb
        & sqlite3 $db "INSERT INTO hubfinding(title) VALUES('x');" | Out-Null
        (& sqlite3 $db "SELECT status FROM hubfinding WHERE id=1;") | Should -Be 'open'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: the two new tests FAIL (`no such table: hubfinding`).

- [ ] **Step 3: Add the table to the `init` heredoc**

In `review-coverage.ps1`, find this line (line 128):

```
CREATE INDEX IF NOT EXISTS ix_activity_at ON activity(at);
```

and replace it with:

```
CREATE TABLE IF NOT EXISTS hubfinding(
  id INTEGER PRIMARY KEY, source TEXT, wtype TEXT, category TEXT, title TEXT NOT NULL, detail TEXT,
  severity TEXT, status TEXT DEFAULT 'open', target TEXT, resolution TEXT,
  created_at TEXT DEFAULT (datetime('now')), resolved_at TEXT);
CREATE INDEX IF NOT EXISTS ix_activity_at ON activity(at);
```

- [ ] **Step 4: Add the status index**

Find this line (line 135):

```
CREATE INDEX IF NOT EXISTS ix_issue_target_path ON issue_target(path);
```

and replace it with:

```
CREATE INDEX IF NOT EXISTS ix_issue_target_path ON issue_target(path);
CREATE INDEX IF NOT EXISTS ix_hubfinding_status ON hubfinding(status);
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS (all 4 tests so far).

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): add hubfinding table to review-coverage init"
```

---

## Task 3: The `hubfind` verb (log a hub finding)

**Files:**
- Modify: `review-coverage.ps1:351` (insert after the `dismiss-rec` verb)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'hubfind' {
    It 'records an open finding with source, category, severity' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'issue-9-x' -Category env -Title 'assumed bash' -Detail 'ran rm -rf' -Severity High | Out-Null
        (& sqlite3 -separator '|' $db "SELECT source,category,severity,status FROM hubfinding WHERE id=1;") | Should -Be 'issue-9-x|env|High|open'
    }
    It 'defaults severity to Medium and source wtype to solver for an unknown worktree' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'agent-z' -Category tool -Title 'missing tool' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT severity,wtype FROM hubfinding WHERE id=1;") | Should -Be 'Medium|solver'
    }
    It "tags wtype 'orchestrator' when the source is orchestrator" {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree orchestrator -Category prompt -Title 'unclear rule' | Out-Null
        (& sqlite3 $db "SELECT wtype FROM hubfinding WHERE id=1;") | Should -Be 'orchestrator'
    }
    It 'throws when -Title is missing' {
        $db = New-TempDb
        { & $script:rc hubfind -Db $db -Worktree 'w' -Category env } | Should -Throw
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: the `hubfind` tests FAIL (the `switch` has no `hubfind` branch, so it falls through with no insert; the throw test also fails).

- [ ] **Step 3: Implement the `hubfind` verb**

In `review-coverage.ps1`, find the `dismiss-rec` line (line 351):

```powershell
    'dismiss-rec' { if (-not $Id) { throw "dismiss-rec requires -Id" }; Exec "UPDATE recommendation SET status='dismissed' WHERE id=$Id;"; Write-Host "recommendation #$Id dismissed." -ForegroundColor Yellow }
```

and insert immediately AFTER it:

```powershell

    # ---- hub findings: problems with the hub's OWN operating layer (prompts/config/scripts/memory/env) ----
    'hubfind' {
        if (-not $Worktree -or -not $Title) { throw "hubfind requires -Worktree (folder or 'orchestrator') and -Title; use -Category <env|tool|prompt|config|memory|other>, -Detail, -Severity" }
        $wt = q $Worktree
        $defWty = if ($Worktree -eq 'orchestrator') { 'orchestrator' } else { 'solver' }
        Exec "INSERT INTO hubfinding(source,wtype,category,title,detail,severity) VALUES('$wt',COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'$defWty'),'$(q $Category)','$(q $Title)','$(q $Detail)','$(q $Severity)');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','hub','hubfind','$(q $Title)');"
        Write-Host "hub finding recorded: $Title" -ForegroundColor Green
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS (all `hubfind` tests). `-Severity` defaults to `Medium` (param default at line 41); `wtype` falls back to `solver`/`orchestrator` because the source isn't a registered worktree.

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): add hubfind verb to log hub findings"
```

---

## Task 4: The `hub-findings` (list) and `hub-resolve` (close) verbs

**Files:**
- Modify: `review-coverage.ps1` (insert after the `hubfind` verb from Task 3)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'hub-resolve' {
    It 'stamps resolved with target, note, and resolved_at' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category config -Title 'wrong pm' | Out-Null
        & $script:rc hub-resolve -Db $db -Id 1 -Target config -Note 'set packageManager=npm' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT status,target,resolution,(resolved_at IS NOT NULL) FROM hubfinding WHERE id=1;") |
            Should -Be 'resolved|config|set packageManager=npm|1'
    }
    It 'marks dismissed without requiring -Target' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category other -Title 'noise' | Out-Null
        & $script:rc hub-resolve -Db $db -Id 1 -Dismiss -Note 'not a real problem' | Out-Null
        (& sqlite3 $db "SELECT status FROM hubfinding WHERE id=1;") | Should -Be 'dismissed'
    }
    It 'throws when neither -Target nor -Dismiss is given' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category env -Title 'x' | Out-Null
        { & $script:rc hub-resolve -Db $db -Id 1 } | Should -Throw
    }
    It 'throws when -Id is missing' {
        $db = New-TempDb
        { & $script:rc hub-resolve -Db $db -Target prompt } | Should -Throw
    }
}

Describe 'hub-findings' {
    It 'lists only open by default and includes resolved/dismissed with -All' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category env -Title 'open one' | Out-Null
        & $script:rc hubfind -Db $db -Worktree 'w' -Category env -Title 'to dismiss' | Out-Null
        & $script:rc hub-resolve -Db $db -Id 2 -Dismiss | Out-Null
        $open = (& $script:rc hub-findings -Db $db) -join "`n"
        $open | Should -Match 'open one'
        $open | Should -Not -Match 'to dismiss'
        $all = (& $script:rc hub-findings -Db $db -All) -join "`n"
        $all | Should -Match 'to dismiss'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: the `hub-resolve` and `hub-findings` tests FAIL (no such verbs yet).

- [ ] **Step 3: Implement both verbs**

In `review-coverage.ps1`, immediately AFTER the `hubfind` verb you added in Task 3, insert:

```powershell

    'hub-findings' {
        $where = if ($All) { '1=1' } else { "status='open'" }
        Query "SELECT id, source, category AS cat, severity AS sev, status, COALESCE(target,'') AS target, substr(title,1,55) AS title FROM hubfinding WHERE $where ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
    }

    'hub-resolve' {
        if (-not $Id) { throw "hub-resolve requires -Id <hub finding id>" }
        if ($Dismiss) {
            Exec "UPDATE hubfinding SET status='dismissed', resolution='$(q $Note)', resolved_at=datetime('now') WHERE id=$Id;"
            Write-Host "hub finding #$Id dismissed." -ForegroundColor Yellow
        }
        else {
            if (-not $Target) { throw "hub-resolve requires -Target <prompt|config|script|memory> (or use -Dismiss)" }
            Exec "UPDATE hubfinding SET status='resolved', target='$(q $Target)', resolution='$(q $Note)', resolved_at=datetime('now') WHERE id=$Id;"
            Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('orchestrator','hub','hub-resolve','#$Id -> $(q $Target)');"
            Write-Host "hub finding #$Id resolved (fixed in $Target)." -ForegroundColor Green
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): add hub-findings (list) and hub-resolve (close) verbs"
```

---

## Task 5: Surface open hub findings in `monitor`

**Files:**
- Modify: `review-coverage.ps1:331` (inside the `monitor` verb)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'monitor shows hub findings' {
    It 'includes the open hub-findings section and an open title' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category env -Title 'pwsh-not-bash' | Out-Null
        $out = (& $script:rc monitor -Db $db) -join "`n"
        $out | Should -Match 'Open hub findings'
        $out | Should -Match 'pwsh-not-bash'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: FAIL (`monitor` does not yet print the hub-findings section).

- [ ] **Step 3: Add the monitor block**

In `review-coverage.ps1`, find the last line of the `monitor` verb (line 331):

```powershell
        Query "SELECT id, COALESCE(source_issue,'') AS src, severity AS sev, substr(title,1,55) AS title, worktree FROM recommendation WHERE status='proposed' ORDER BY id LIMIT $N;"
```

and insert immediately AFTER it (still inside the `'monitor' { ... }` block, before its closing `}`):

```powershell
        Write-Host "`n=== Open hub findings (prompt / env / config problems) ===" -ForegroundColor Cyan
        Query "SELECT id, source, category AS cat, severity AS sev, substr(title,1,55) AS title FROM hubfinding WHERE status='open' ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): show open hub findings in monitor"
```

---

## Task 6: Fifth dashboard section in `ledger-to-html.ps1`

Adds a defensive config load (so the dashboard renders pre-bootstrap and is smoke-testable) and a "Hub findings" section to the HTML.

**Files:**
- Modify: `ledger-to-html.ps1` — `.DESCRIPTION` (lines 8-13), config load (lines 42-45), query block (after line 98), `$dataJson` (lines 114-119), `SECTIONS` JS (after line 253)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing smoke test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'ledger-to-html includes hub findings' {
    It 'renders a Hub findings section with an open finding (no hub.config.json needed)' {
        $db = New-TempDb
        & $script:rc hubfind -Db $db -Worktree 'w' -Category prompt -Title 'stale rule about pnpm' | Out-Null
        $html = Join-Path $TestDrive 'ledger.html'
        $renderer = $script:rc.Replace('review-coverage.ps1', 'ledger-to-html.ps1')
        & $renderer -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $text = Get-Content $html -Raw
        $text | Should -Match 'Hub findings'
        $text | Should -Match 'stale rule about pnpm'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: FAIL — `ledger-to-html.ps1` throws on the missing `hub.config.json` (hard load), and even with config it has no Hub findings section.

- [ ] **Step 3: Make the config load defensive**

In `ledger-to-html.ps1`, replace lines 42-45:

```powershell
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hub-config.ps1')   # sets $Hub + $HubConfig

if (-not $Repo) { $Repo = $HubConfig.repo }
```

with:

```powershell
$ErrorActionPreference = 'Stop'
try { . (Join-Path $PSScriptRoot 'hub-config.ps1') }   # sets $Hub + $HubConfig
catch { $Hub = $PSScriptRoot; $HubConfig = $null }

if (-not $Repo) { $Repo = if ($HubConfig) { $HubConfig.repo } else { 'owner/repo' } }
```

- [ ] **Step 4: Add the `$qHubFindings` query**

Find the end of the `$qRecs` block (line 98, the closing `"@`):

```powershell
ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
  id;
"@

$qWorktrees = Get-Json @"
```

and insert the new query BETWEEN `$qRecs`'s closing `"@` and `$qWorktrees` so it reads:

```powershell
ORDER BY CASE severity WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 WHEN 'Low' THEN 3 ELSE 4 END,
  id;
"@

$qHubFindings = Get-Json @"
SELECT id, COALESCE(source,'') AS source, COALESCE(category,'') AS category,
  COALESCE(severity,'') AS severity, title, COALESCE(detail,'') AS detail,
  substr(COALESCE(created_at,''),1,10) AS created
FROM hubfinding
WHERE status='open'
ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 WHEN 'Low' THEN 2 ELSE 3 END,
  id;
"@

$qWorktrees = Get-Json @"
```

- [ ] **Step 5: Add it to the `$dataJson` assembly**

Replace lines 114-119:

```powershell
$dataJson = "{`n" + (@(
        '"issues": ' + $qIssues
        '"findings": ' + $qFindings
        '"recommendations": ' + $qRecs
        '"worktrees": ' + $qWorktrees
    ) -join ",`n") + "`n}"
```

with:

```powershell
$dataJson = "{`n" + (@(
        '"issues": ' + $qIssues
        '"findings": ' + $qFindings
        '"recommendations": ' + $qRecs
        '"hubFindings": ' + $qHubFindings
        '"worktrees": ' + $qWorktrees
    ) -join ",`n") + "`n}"
```

- [ ] **Step 6: Add the `SECTIONS` entry in the JS template**

Find the end of the `recommendations` section config and the start of the `worktrees` one (lines 253-254):

```javascript
  ]},
  { id:'worktrees', title:'Worktrees', desc:'status ≠ retired (live monitor)', rows:DATA.worktrees, cols:[
```

Note there are several `]},` lines; the correct one is the line immediately BEFORE `{ id:'worktrees', ...`. Replace those two lines with:

```javascript
  ]},
  { id:'hubFindings', title:'Hub findings', desc:'prompt / env / config problems (open)', rows:DATA.hubFindings, cols:[
    {k:'id',label:'ID',type:'num'},
    {k:'source',label:'Source'},
    {k:'category',label:'Category'},
    {k:'severity',label:'Sev',type:'severity'},
    {k:'title',label:'Title',type:'title'},
    {k:'detail',label:'Detail',type:'long'},
    {k:'created',label:'Created'},
  ]},
  { id:'worktrees', title:'Worktrees', desc:'status ≠ retired (live monitor)', rows:DATA.worktrees, cols:[
```

- [ ] **Step 7: Update the `.DESCRIPTION` comment**

Find (lines 11-13):

```
    * Recommendations — status = 'proposed'  (out-of-scope solver follow-ups)
    * Worktrees       — status != 'retired'  (the live monitor view)
```

and replace with:

```
    * Recommendations — status = 'proposed'  (out-of-scope solver follow-ups)
    * Hub findings    — status = 'open'  (problems with the hub's own prompts/config/scripts/env)
    * Worktrees       — status != 'retired'  (the live monitor view)
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS — the rendered HTML contains both `Hub findings` (the section title) and `stale rule about pnpm` (the row).

- [ ] **Step 9: Commit**

```powershell
git add ledger-to-html.ps1 review-coverage.Tests.ps1
git commit -m "feat(dashboard): add Hub findings section to ledger-to-html"
```

---

## Task 7: Agent recognition in `WORKTREE.md`

Adds the agent-facing "Hub findings" section, a completion-report row, and a record-to-ledger line. Inserting a new §6 shifts the later sections, so renumber §6→§10 and fix the two internal cross-references. (Docs task — no Pester; verify with `git diff` and a grep.)

**Files:**
- Modify: `WORKTREE.md`

- [ ] **Step 1: Add the completion-report row (§4)**

Find (lines 80-81):

```
  'Status|✅ pushed · ✅ PR opened · ⏳ awaiting your review/merge',
  'Recommended follow-ups|<N found — see table below  /  none>'
```

Replace with:

```
  'Status|✅ pushed · ✅ PR opened · ⏳ awaiting your review/merge',
  'Recommended follow-ups|<N found — see table below  /  none>',
  'Hub findings|<N logged this session — see ledger / none>'
```

- [ ] **Step 2: Insert the new §6 section**

Find the start of the current §6 (line 101):

```
## 6. Record to the hub ledger (system of record for monitoring + triage)
```

Replace it with the new section followed by the renumbered header:

````
## 6. Hub findings (problems with these instructions / your environment — not the repo's code)

If a problem is with **how this hub is operating you** rather than with the repo you were sent to fix —
a command or tool that isn't what the prompt implied, the **wrong terminal assumption** (this hub is
PowerShell, not bash), a wrong configured value, or an unclear/stale standing instruction — that is a
**hub finding**, not a code issue. You **cannot** fix the hub from here and you must **not** paper over
it (§1). Log it so the orchestrator fixes the real artifact for every future worktree, then carry on
with your task using the correct approach:

```powershell
& <hub>\review-coverage.ps1 hubfind -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> `
    -Title '<short>' -Detail '<what happened, where, and what it should be>' [-Severity <Low|Medium|High>]
```

This is the hub-level sibling of §5 (Recommended follow-ups): §5 is for out-of-scope problems in the
**repo**; this is for problems in the **hub's own** prompts/config/scripts/environment.

## 7. Record to the hub ledger (system of record for monitoring + triage)
````

- [ ] **Step 3: Add the `hubfind` line to the record-to-ledger block (now §7)**

Find (lines 104-105, the code block inside the now-§7 section):

```
& <hub>\review-coverage.ps1 progress  -Worktree <FOLDER> -Status pr-open -Pr <M>
& <hub>\review-coverage.ps1 recommend -Worktree <FOLDER> -Issue <N> -Title '<title>' -Area '<area>' -Severity '<Low|Medium|High>' -Detail '<what + where + why out of scope>'   # one per follow-up
```

Replace with:

```
& <hub>\review-coverage.ps1 progress  -Worktree <FOLDER> -Status pr-open -Pr <M>
& <hub>\review-coverage.ps1 recommend -Worktree <FOLDER> -Issue <N> -Title '<title>' -Area '<area>' -Severity '<Low|Medium|High>' -Detail '<what + where + why out of scope>'   # one per follow-up
& <hub>\review-coverage.ps1 hubfind   -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> -Title '<short>' -Detail '<what + where + what it should be>'   # any HUB finding (see §6)
```

- [ ] **Step 4: Renumber the remaining section headers**

Apply these exact header replacements:

- `## 7. Environment note` → `## 8. Environment note`
- `## 8. Hard constraints` → `## 9. Hard constraints`
- `## 9. Merge → migrate (only if the user explicitly asks YOU to merge)` → `## 10. Merge → migrate (only if the user explicitly asks YOU to merge)`

- [ ] **Step 5: Fix the two internal cross-references**

- Line 41: `7. **Record to the hub ledger** (section 6).` → `7. **Record to the hub ledger** (section 7).`
- In §9 (Hard constraints), the migration bullet: `applying happens only at merge time (section 9).` → `applying happens only at merge time (section 10).`

(The `(section 4)` and `(section 3)` references are unchanged — those sections did not move.)

- [ ] **Step 6: Verify numbering + references are consistent**

Run:
```powershell
Select-String -Path .\WORKTREE.md -Pattern '^## \d+\.', '\(section \d+\)'
```
Expected: headers read `## 1.` … `## 10.` with no gaps or duplicates; the only `(section N)` references are `(section 4)`, `(section 7)`, `(section 3)`, `(section 10)`, `(section 3)`. Confirm no stray `(section 6)` or `(section 9)` remain.

- [ ] **Step 7: Commit**

```powershell
git add WORKTREE.md
git commit -m "docs(worktree): teach agents to log hub findings (+ renumber sections)"
```

---

## Task 8: Orchestrator docs in `CLAUDE.md`

Adds the verbs to the command list, the `hubfinding` clause to the ledger/tables description, hub-findings triage to the merge-time sweep, and the rollout note. (Docs task. `CLAUDE.md` is large; **Read each region before editing** to confirm the anchor matches on disk.)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the verbs to the `review-coverage.ps1` command block**

Find this line in the review-coverage command block:

```
.\review-coverage.ps1 recommendations ; .\review-coverage.ps1 file-rec -Id 3   # solver follow-up triage -> GH issue
```

Insert immediately AFTER it:

```
# --- hub findings (problems with the hub's OWN prompts/config/scripts/memory/env) ---
.\review-coverage.ps1 hubfind -Worktree <folder|orchestrator> -Category <env|tool|prompt|config|memory|other> -Title '..' -Detail '..' [-Severity ..]   # log one (any worktree or the orchestrator)
.\review-coverage.ps1 hub-findings [-All]                    # triage list (open by default)
.\review-coverage.ps1 hub-resolve -Id 4 -Target <prompt|config|script|memory> -Note '<what changed>'   # close after editing the real artifact (or -Dismiss)
```

- [ ] **Step 2: Add the `hubfinding` clause to the "Tables:" description**

Find the `recommendation` clause at the end of the "Tables:" paragraph (it ends with):

```
**recommendation** (out-of-scope follow-ups a SOLVER found while fixing its issue: proposed → filed as a GH issue / dismissed; same verify fields).
```

Replace with (append the new clause):

```
**recommendation** (out-of-scope follow-ups a SOLVER found while fixing its issue: proposed → filed as a GH issue / dismissed; same verify fields) · **hubfinding** (problems with the hub's OWN operating layer — prompts/config/scripts/memory/env — logged by any worktree or the orchestrator; lifecycle open → resolved/dismissed, fixed by editing a hub artifact, **never** a GH issue).
```

- [ ] **Step 3: Fold hub-findings triage into the merge-time sweep (step 4)**

In the "Merging a finished PR" → step 4 ("Sweep the standing follow-up backlog so it can't rot"), find the sentence listing the sweep commands:

```
`.\review-coverage.ps1 findings -Unverified` (recon findings not yet verified) + `.\review-coverage.ps1
   recommendations` (proposed solver follow-ups, `-N` high enough to see them all — the default is 8).
```

Replace with:

```
`.\review-coverage.ps1 findings -Unverified` (recon findings not yet verified) + `.\review-coverage.ps1
   recommendations` (proposed solver follow-ups, `-N` high enough to see them all — the default is 8) +
   `.\review-coverage.ps1 hub-findings` (open problems with the hub's own prompts/config/scripts/env).
   For each open hub finding, fix the real artifact — edit `WORKTREE.md`/`CLAUDE.md`/`hub.config.json`/the
   helper script, or write a memory file — then `hub-resolve -Id <n> -Target <prompt|config|script|memory>
   -Note '<what changed>'` (or `-Dismiss`).
```

- [ ] **Step 4: Add the rollout note to the ledger section**

Find the line introducing the one-time ledger setup:

```powershell
.\review-coverage.ps1 init ; .\review-coverage.ps1 seed     # one-time: schema + scan repo -> topics  (setup-hub.ps1 runs these automatically)
```

Immediately AFTER that code line (inside the same fenced block), add:

```powershell
# existing hub upgrading to the hub-findings channel? re-run init once (idempotent) to add the hubfinding table:
.\review-coverage.ps1 init
```

- [ ] **Step 5: Verify the edits**

Run:
```powershell
Select-String -Path .\CLAUDE.md -Pattern 'hubfind', 'hub-findings', 'hub-resolve', 'hubfinding'
```
Expected: matches in the command block, the Tables description, the merge-sweep step, and the rollout note.

- [ ] **Step 6: Commit**

```powershell
git add CLAUDE.md
git commit -m "docs(hub): document the hub-findings channel (commands, ledger, merge sweep, rollout)"
```

---

## Task 9: One-line mention in `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the ledger/commands overview**

Read the section of `README.md` that lists the review-coverage ledger capabilities (search for `review-coverage` or "ledger"):

```powershell
Select-String -Path .\README.md -Pattern 'review-coverage|ledger' -Context 0,1
```

- [ ] **Step 2: Add the one-liner**

In that overview, add a single bullet/sentence (match the surrounding list style; place it after the recommendations/monitor mention):

```
- **Hub findings** — worktree agents and the orchestrator log problems with the hub's *own* prompts, config, scripts, memory, or environment (e.g. pwsh-vs-bash) via `review-coverage.ps1 hubfind`; triage with `hub-findings` and close with `hub-resolve` (never a GitHub issue on the target repo).
```

- [ ] **Step 3: Commit**

```powershell
git add README.md
git commit -m "docs(readme): mention the hub-findings ledger channel"
```

---

## Final verification

- [ ] **Step 1: Run the full test suite**

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: all `review-coverage.Tests.ps1` tests PASS; `hub-checks.Tests.ps1` still PASS (no regression — this plan does not touch `hub-checks.ps1`).

- [ ] **Step 2: Manual end-to-end smoke (real ledger)**

```powershell
.\review-coverage.ps1 init
.\review-coverage.ps1 hubfind -Worktree orchestrator -Category env -Title 'smoke test finding' -Severity Low
.\review-coverage.ps1 hub-findings
.\review-coverage.ps1 monitor          # confirm the "Open hub findings" section lists it
.\ledger-to-html.ps1 -NoOpen           # confirm it renders without error
.\review-coverage.ps1 hub-resolve -Id 1 -Target prompt -Note 'smoke test resolution'
.\review-coverage.ps1 hub-findings     # confirm it's gone from the open list
```
Expected: the finding appears in `hub-findings`/`monitor`, the dashboard renders, and `hub-resolve` clears it from the open list. (This requires a `hub.config.json` present, or it exercises the same defensive path as the tests.)

> If the smoke test created a real `.review\coverage.db` in a checkout that had none, and you don't want to keep it, remove the row: `.\review-coverage.ps1 hub-resolve -Id 1 -Dismiss` already took it out of the open view; delete the smoke DB only if it was created solely for this check.

---

## Self-Review (completed during planning)

- **Spec coverage:** schema (Task 2) · verbs hubfind/hub-findings/hub-resolve (Tasks 3-4) · `-Target` param + sources incl. orchestrator (Tasks 1,3) · monitor (Task 5) · dashboard 5th section (Task 6) · WORKTREE.md recognition + report row + record line (Task 7) · CLAUDE.md command list + tables desc + merge sweep (Task 8) · README (Task 9) · Pester tests (every code task). The spec's *optional* doctor check (#16) is deliberately deferred (YAGNI) — see the rollout note.
- **Placeholder scan:** no TBD/TODO; every code/test step shows complete code and exact expected output. `<FOLDER>`/`<N>`/`<hub>` are the hub's intentional doc templating, consistent with the existing files.
- **Type/name consistency:** verbs `hubfind`/`hub-findings`/`hub-resolve`, table `hubfinding`, columns `source/wtype/category/title/detail/severity/status/target/resolution/created_at/resolved_at`, params `-Db`/`-Target`, JSON key `hubFindings`, and JS section `id:'hubFindings'` are used identically across all tasks.
