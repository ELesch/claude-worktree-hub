# Worktree Expert-Consultation Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every worktree session a panel of consultable domain-expert subagents (`hub-principal` + 5 specialists) that advise on design decisions with professional, long-term judgment, and record every consultation + the decision the worktree made in the SQLite ledger for observability.

**Architecture:** Six read-only advisory agents defined as `.claude/agents/hub-*.md` in the hub repo, copied into each worktree (git-excluded) so the worktree's own session can consult them in-process (subscription-covered, never headless). A new `consult` ledger table + `review-coverage.ps1 consult` verb records each consultation; surfaced via `monitor` and a sixth `ledger-to-html.ps1` dashboard section. `WORKTREE.md` teaches the consult workflow (mandatory at the spec-gate, on-demand otherwise) and `CLAUDE.md` documents triage + the improvement loop. The ledger verbs already load `hub-config.ps1` defensively and accept `-DbPath` (from the hub-findings work), so tests are hermetic with no new foundation. A hub-root `PRODUCT.md` (the user's product brief — scaffolded at setup, updatable via `product.ps1`, git-ignored) is read **live** by a worktree when it consults the product/principal experts.

**Tech Stack:** PowerShell 7, SQLite (`sqlite3` CLI), Pester 5.7.1 (run from the saved module at `C:\mydev\pester-modules`; `Install-Module` does not work on this machine), Claude Code custom subagents (`.claude/agents/*.md`).

**Spec:** `docs/superpowers/specs/2026-06-28-expert-consultation-design.md`

---

## File Structure

| File | New/Changed | Responsibility |
|---|---|---|
| `review-coverage.ps1` | changed | `consult` table in `init`; consult params; `consult` verb; `monitor` block |
| `review-coverage.Tests.ps1` | changed | Pester tests for the table, verb, and monitor (temp-DB, hermetic) |
| `ledger-to-html.ps1` | changed | sixth open-item section (Consults) + console count |
| `.claude/agents/hub-principal.md` … `hub-dx-product.md` | new (6) | the expert system prompts (read-only, opus-pinned) |
| `PRODUCT.example.md` | new | product-brief template (tracked); real `PRODUCT.md` is git-ignored |
| `.gitignore` | changed (1 line) | ignore the generated `PRODUCT.md` |
| `product.ps1` | new | `-Show` / `-Append` the hub-root product brief |
| `product.Tests.ps1` | new | Pester tests for `product.ps1` |
| `setup-hub.ps1` | changed | scaffold `PRODUCT.md` from the template on first run |
| `hub-lib.ps1` | changed | `Copy-HubExperts` (testable provisioning helper) |
| `hub-lib.Tests.ps1` | new | Pester tests for `Copy-HubExperts` |
| `new-worktree.ps1` | changed | call `Copy-HubExperts` + git-exclude the copies |
| `spawn-child.ps1` | changed | call `Copy-HubExperts` for child worktrees |
| `WORKTREE.md` | changed | new "Consulting the experts" section (§6) + report row + record line + ADR note (+ renumber §6→§11) |
| `CLAUDE.md` | changed | command list + tables description + merge-sweep + improvement loop + rollout note |
| `README.md` | changed (1 line) | mention the channel in the ledger-commands overview |

**Rollout note (call out in Task 8):** the `consult` table is created by `review-coverage.ps1 init` (idempotent); existing hubs run `.\review-coverage.ps1 init` once. The expert `.claude/agents/hub-*.md` files only reach **newly-provisioned** worktrees — existing worktrees don't get them retroactively (acceptable; consultation is per-session).

**Pester test runner (used in every test step below):**

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```

**NOTE on anchors:** line numbers drift as tasks land — match the exact TEXT anchors shown, not line numbers. The `consult` verb's test code uses `-DbPath` (the override param added by the hub-findings work).

---

## Task 1: Schema — the `consult` table in `init`

**Files:**
- Modify: `review-coverage.ps1` (the `init` heredoc)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'consult schema' {
    It 'init creates the consult table with the expected columns' {
        $db = New-TempDb
        $cols = (& sqlite3 $db "SELECT name FROM pragma_table_info('consult') ORDER BY name;") -join ','
        $cols | Should -Be 'advice,area,created_at,decision,expert,followed,id,issue,question,rationale,worktree,wtype'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: the new test FAILS (`no such table: consult`); all prior tests still PASS.

- [ ] **Step 3: Add the table + index to the `init` heredoc**

In `review-coverage.ps1`, find this exact line (the last index in the heredoc — UNIQUE):

```
CREATE INDEX IF NOT EXISTS ix_hubfinding_status ON hubfinding(status);
```

and replace it with that line followed by the new table + index:

```
CREATE INDEX IF NOT EXISTS ix_hubfinding_status ON hubfinding(status);
CREATE TABLE IF NOT EXISTS consult(
  id INTEGER PRIMARY KEY, worktree TEXT, wtype TEXT, expert TEXT NOT NULL, area TEXT, issue INTEGER,
  question TEXT NOT NULL, advice TEXT, decision TEXT, followed TEXT, rationale TEXT,
  created_at TEXT DEFAULT (datetime('now')));
CREATE INDEX IF NOT EXISTS ix_consult_expert ON consult(expert);
```

(The `consult` table references itself only; placing the `CREATE TABLE` immediately before its `CREATE INDEX` keeps it valid. It sits at the end of the heredoc, before the closing `'@`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS. The 12 columns sort alphabetically to exactly the asserted list.

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): add consult table to review-coverage init"
```

---

## Task 2: The `consult` verb (record a consultation + decision)

**Files:**
- Modify: `review-coverage.ps1` (param block + a new verb after `hub-resolve`)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'consult verb' {
    It 'records a consultation with expert, area, issue, followed' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-9-x' -Expert hub-architect -Area architecture -Question 'where does the cache layer live?' -Advice 'behind the repository interface' -Decision 'cache in the repository' -Followed yes -Issue 9 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT worktree,expert,area,issue,followed FROM consult WHERE id=1;") | Should -Be 'issue-9-x|hub-architect|architecture|9|yes'
    }
    It 'captures an override with its rationale' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-data -Question 'normalize tags?' -Advice 'separate tags table' -Decision 'inline JSON for now' -Followed overridden -Rationale 'YAGNI; under 100 rows expected' | Out-Null
        (& sqlite3 -separator '|' $db "SELECT followed,rationale FROM consult WHERE id=1;") | Should -Be 'overridden|YAGNI; under 100 rows expected'
    }
    It 'writes an activity row for the live feed' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-security -Question 'sanitize this input?' | Out-Null
        (& sqlite3 $db "SELECT event FROM activity WHERE worktree='w' AND event='consult';") | Should -Be 'consult'
    }
    It 'throws when -Expert is missing' {
        $db = New-TempDb
        { & $script:rc consult -DbPath $db -Worktree 'w' -Question 'q only' } | Should -Throw
    }
    It 'throws when -Question is missing' {
        $db = New-TempDb
        { & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-architect } | Should -Throw
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: the 5 `consult verb` tests FAIL (unknown command falls through to help; no insert, no throw).

- [ ] **Step 3: Add the consult params**

In `review-coverage.ps1`, find this exact param-block line (UNIQUE):

```powershell
    [string]$DbPath,    # override the ledger path (tests / pre-bootstrap); default <hub>\.review\coverage.db
```

and insert a new line immediately AFTER it:

```powershell
    [string]$DbPath,    # override the ledger path (tests / pre-bootstrap); default <hub>\.review\coverage.db
    [string]$Expert, [string]$Question, [string]$Advice, [string]$Decision, [string]$Followed, [string]$Rationale,   # consult fields (-Followed: yes|partial|overridden)
```

- [ ] **Step 4: Implement the `consult` verb**

In `review-coverage.ps1`, find the END of the `hub-resolve` verb (TEXT anchor — these three lines are UNIQUE):

```powershell
            Write-Host "hub finding #$Id resolved (fixed in $Target)." -ForegroundColor Green
        }
    }
```

and replace them with the same three lines followed by the new verb:

```powershell
            Write-Host "hub finding #$Id resolved (fixed in $Target)." -ForegroundColor Green
        }
    }

    # ---- expert consultation: a worktree records the advice it got from a hub-* expert + the decision it made ----
    'consult' {
        if (-not $Worktree -or -not $Expert -or -not $Question) { throw "consult requires -Worktree, -Expert (hub-<x>), and -Question; use -Area, -Advice, -Decision, -Followed <yes|partial|overridden>, -Rationale, -Issue" }
        $wt = q $Worktree
        $wty = "$(Scalar "SELECT COALESCE((SELECT wtype FROM worktree WHERE name='$wt'),'solver');")".Trim()
        Exec "INSERT INTO consult(worktree,wtype,expert,area,issue,question,advice,decision,followed,rationale) VALUES('$wt','$wty','$(q $Expert)','$(q $Area)',$(NullableInt $Issue),'$(q $Question)','$(q $Advice)','$(q $Decision)','$(q $Followed)','$(q $Rationale)');"
        Exec "INSERT INTO activity(worktree,wtype,event,detail) VALUES('$wt','$wty','consult','$(q $Expert): $(q $Question)');"
        Write-Host "consult recorded: $Expert ($(if ($Followed) { $Followed } else { 'noted' }))" -ForegroundColor Green
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS (all `consult verb` tests). `$wty` falls back to `solver` for an unregistered worktree; `$(q ...)` escapes every user value; `$Id` is `[int]` (the `-Issue` value is emitted via `NullableInt`).

- [ ] **Step 6: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): add consult verb to record expert consultations + decisions"
```

---

## Task 3: Surface recent consults in `monitor`

**Files:**
- Modify: `review-coverage.ps1` (inside the `monitor` verb)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'monitor shows consults' {
    It 'includes the recent-consults section and a logged expert' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-observability -Question 'what to log on retry?' -Followed yes | Out-Null
        $out = (& $script:rc monitor -DbPath $db 6>&1) -join "`n"
        $out | Should -Match 'Recent consults'
        $out | Should -Match 'hub-observability'
    }
}
```

(The `6>&1` captures `Write-Host` — the section header — into `$out`; the row text comes from `Query` on stdout.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: FAIL (`monitor` does not yet print a consults section).

- [ ] **Step 3: Add the monitor block**

In `review-coverage.ps1`, find the last two lines of the `monitor` verb (TEXT anchor — the hub-findings Query then the block's closing `}`; UNIQUE):

```powershell
        Query "SELECT id, source, category AS cat, severity AS sev, substr(title,1,55) AS title FROM hubfinding WHERE status='open' ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
    }
```

and replace with the same Query line + the new block + the closing `}`:

```powershell
        Query "SELECT id, source, category AS cat, severity AS sev, substr(title,1,55) AS title FROM hubfinding WHERE status='open' ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id LIMIT $N;"
        Write-Host "`n=== Recent consults (expert decisions; overrides flagged) ===" -ForegroundColor Cyan
        Query "SELECT id, worktree, expert, COALESCE(area,'') AS area, COALESCE(followed,'') AS followed, substr(question,1,45) AS question FROM consult ORDER BY id DESC LIMIT $N;"
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add review-coverage.ps1 review-coverage.Tests.ps1
git commit -m "feat(ledger): show recent consults in monitor"
```

---

## Task 4: Sixth dashboard section in `ledger-to-html.ps1`

**Files:**
- Modify: `ledger-to-html.ps1` (query block, `$dataJson`, `SECTIONS` JS, `.DESCRIPTION`, console count)
- Test: `review-coverage.Tests.ps1`

- [ ] **Step 1: Write the failing smoke test**

Append to `review-coverage.Tests.ps1`:

```powershell
Describe 'ledger-to-html includes consults' {
    It 'renders a Consults section with a logged decision (no hub.config.json needed)' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'w' -Expert hub-dx-product -Question 'flag name?' -Decision 'use --dry-run' -Followed yes | Out-Null
        $html = Join-Path $TestDrive 'ledger.html'
        $renderer = $script:rc.Replace('review-coverage.ps1', 'ledger-to-html.ps1')
        & $renderer -Database $db -Out $html -Repo 'acme/widgets' -NoOpen | Out-Null
        $text = Get-Content $html -Raw
        $text | Should -Match 'Consults'
        $text | Should -Match 'flag name\?'
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: FAIL — `ledger-to-html.ps1` has no Consults section yet.

- [ ] **Step 3: Add the `$qConsults` query**

In `ledger-to-html.ps1`, find this exact 4-line anchor (the END of `$qHubFindings` immediately followed by `$qWorktrees` — UNIQUE because of the `$qWorktrees` line):

```powershell
ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 WHEN 'Low' THEN 2 ELSE 3 END,
  id;
"@

$qWorktrees = Get-Json @"
```

and replace it with the new query inserted before `$qWorktrees`:

```powershell
ORDER BY CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 WHEN 'Low' THEN 2 ELSE 3 END,
  id;
"@

$qConsults = Get-Json @"
SELECT id, COALESCE(worktree,'') AS worktree, expert, COALESCE(area,'') AS area,
  COALESCE(issue,'') AS issue, question, COALESCE(decision,'') AS decision,
  COALESCE(followed,'') AS followed, COALESCE(rationale,'') AS rationale,
  substr(COALESCE(created_at,''),1,10) AS created
FROM consult
ORDER BY id DESC;
"@

$qWorktrees = Get-Json @"
```

- [ ] **Step 4: Add it to the `$dataJson` assembly**

Find this exact 2-line anchor:

```powershell
        '"hubFindings": ' + $qHubFindings
        '"worktrees": ' + $qWorktrees
```

and replace with:

```powershell
        '"hubFindings": ' + $qHubFindings
        '"consults": ' + $qConsults
        '"worktrees": ' + $qWorktrees
```

- [ ] **Step 5: Add the `SECTIONS` entry in the JS template**

Find this exact 2-line anchor (the `]},` that closes the hubFindings section, then the worktrees section opener — UNIQUE because of the `worktrees` line):

```javascript
  ]},
  { id:'worktrees', title:'Worktrees', desc:'status ≠ retired (live monitor)', rows:DATA.worktrees, cols:[
```

and replace it with the Consults section inserted before worktrees:

```javascript
  ]},
  { id:'consults', title:'Consults', desc:'expert decisions (advisory; overrides shown)', rows:DATA.consults, cols:[
    {k:'id',label:'ID',type:'num'},
    {k:'worktree',label:'Worktree'},
    {k:'expert',label:'Expert'},
    {k:'area',label:'Area'},
    {k:'issue',label:'Issue',type:'issuelink'},
    {k:'question',label:'Question',type:'title'},
    {k:'decision',label:'Decision',type:'long'},
    {k:'followed',label:'Followed'},
    {k:'rationale',label:'Rationale',type:'long'},
    {k:'created',label:'Created'},
  ]},
  { id:'worktrees', title:'Worktrees', desc:'status ≠ retired (live monitor)', rows:DATA.worktrees, cols:[
```

- [ ] **Step 6: Update the `.DESCRIPTION` comment**

Find this exact 2-line anchor:

```
    * Hub findings    — status = 'open'  (problems with the hub's own prompts/config/scripts/env)
    * Worktrees       — status != 'retired'  (the live monitor view)
```

and replace with:

```
    * Hub findings    — status = 'open'  (problems with the hub's own prompts/config/scripts/env)
    * Consults        — expert decisions (advisory advice + what the worktree decided)
    * Worktrees       — status != 'retired'  (the live monitor view)
```

- [ ] **Step 7: Add the consults count to the console summary**

Find this exact line:

```powershell
$ci = Count-Rows $qIssues; $cf = Count-Rows $qFindings; $cr = Count-Rows $qRecs; $ch = Count-Rows $qHubFindings; $cw = Count-Rows $qWorktrees
```

and replace with (add `$cc`):

```powershell
$ci = Count-Rows $qIssues; $cf = Count-Rows $qFindings; $cr = Count-Rows $qRecs; $ch = Count-Rows $qHubFindings; $cc = Count-Rows $qConsults; $cw = Count-Rows $qWorktrees
```

Then find this exact line:

```powershell
Write-Host ("  issues {0} · findings {1} · recommendations {2} · hub-findings {3} · worktrees {4}" -f $ci, $cf, $cr, $ch, $cw) -ForegroundColor DarkGray
```

and replace with (add `consults`; worktrees moves to `{5}`):

```powershell
Write-Host ("  issues {0} · findings {1} · recommendations {2} · hub-findings {3} · consults {4} · worktrees {5}" -f $ci, $cf, $cr, $ch, $cc, $cw) -ForegroundColor DarkGray
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed`
Expected: PASS — the HTML contains both `Consults` (section title) and `flag name?` (the row).

- [ ] **Step 9: Commit**

```powershell
git add ledger-to-html.ps1 review-coverage.Tests.ps1
git commit -m "feat(dashboard): add Consults section to ledger-to-html"
```

---

## Task 5: Expert agent definitions (6 files)

Creates the six read-only advisory agents in the **hub repo** at `.claude/agents/`. (No Pester — these are prompt files; verify with a frontmatter check and a `Get-ChildItem`.)

**Files:**
- Create: `.claude/agents/hub-principal.md`, `hub-architect.md`, `hub-data.md`, `hub-observability.md`, `hub-security.md`, `hub-dx-product.md`

- [ ] **Step 1: Create `.claude/agents/hub-principal.md`**

```markdown
---
name: hub-principal
description: Default design consultant. Consult for any consequential decision needing whole-team, long-term engineering judgment — "is this the right approach", scope/extensibility/maintainability trade-offs, cross-cutting calls. Routes to specialists when a decision is domain-deep.
tools: Read, Grep, Glob
model: opus
---
You are a principal/staff engineer advising a worktree agent on ONE specific decision. You think like a professional application-development team optimizing for the BEST LONG-TERM RESULT: an application that is manageable, easy to use, complete, and easily extended.

You are advisory only. You never edit code and never write to any ledger — the worktree weighs your advice, decides, and records it.

You are given the decision, the options, and the relevant context in the prompt. Do not go hunting for files unless the prompt points you to a specific path; reason about what you were given. Weigh:
- Long-term maintainability and the cost of changing this later ("what will we regret in six months?").
- Simplicity and YAGNI — the most complete solution is usually the smallest one that fully solves the REAL problem; name any gold-plating.
- Extensibility — does this accommodate the likely next requirement without a rewrite?
- Observability — will we be able to see this working or failing once it ships?
- Fit with the codebase's existing patterns over novelty.

When the decision is product-facing, ground it in the **product brief** the worktree gives you (the hub's `PRODUCT.md`: vision, users, priorities, non-goals). If no brief is provided, note that the product intent is unstated and advise generically.

Respond in EXACTLY this structure:
- **Recommendation:** the call you would make, stated plainly.
- **Why (long-term):** reasoning centered on future impact.
- **Key trade-offs:** what you trade away and why it is worth it.
- **What to avoid:** the tempting-but-wrong options and their failure modes.
- **Also consult:** name any `hub-<specialist>` (architect / data / observability / security / dx-product) whose depth this needs, or "none."

Be honest about uncertainty — "it depends on X; if X then A else B" beats false confidence. If the question is under-specified, say what you would need to know.
```

- [ ] **Step 2: Create `.claude/agents/hub-architect.md`**

```markdown
---
name: hub-architect
description: Consult for system/architecture and API decisions — module and service boundaries, where new code belongs, coupling vs cohesion, data flow, extension points, and avoiding choices that paint the system into a corner.
tools: Read, Grep, Glob
model: opus
---
You are a senior software architect advising a worktree agent on ONE specific structural decision. Optimize for a system that stays easy to change.

Advisory only — never edit code or any ledger. Reason about the context you are given in the prompt.

Weigh: where this responsibility truly belongs; the interface/boundary between this unit and the rest; coupling and hidden dependencies; the seam that lets the likely next feature slot in without a rewrite; whether this is a one-way door (hard to reverse) and whether that is justified now. Prefer the smallest change that fits existing patterns over a speculative abstraction (and prefer a clear abstraction over copy-paste when the third case appears).

Respond in EXACTLY this structure:
- **Recommendation**
- **Why (long-term):** centered on changeability and blast radius.
- **Key trade-offs**
- **What to avoid:** the coupling / over-abstraction traps specific to this decision.
- **Also consult:** `hub-data` / `hub-observability` / etc., or "none."

State any assumption about scale or usage that would change your answer.
```

- [ ] **Step 3: Create `.claude/agents/hub-data.md`**

```markdown
---
name: hub-data
description: Consult for data-layer decisions — schema and migration design, normalization vs denormalization, constraints and integrity, indexing, backward-compatible evolution, and query shape.
tools: Read, Grep, Glob
model: opus
---
You are a senior data engineer advising a worktree agent on ONE specific data decision. Optimize for data that stays correct and a schema that can evolve safely.

Advisory only — never edit code, never run a migration, never write to any ledger. Reason about the context you are given.

Weigh: the right shape (normalized vs embedded) for the actual access patterns; constraints that keep the data honest (NOT NULL, FK, unique, checks); how this migrates forward without breaking existing rows or readers (additive first; destructive changes flagged loudly); indexing for the real queries, not speculation; and whether a choice locks in a shape that is painful to change later.

Respond in EXACTLY this structure:
- **Recommendation**
- **Why (long-term):** centered on integrity and safe evolution.
- **Key trade-offs**
- **What to avoid:** the schema dead-ends / unsafe-migration traps here.
- **Also consult:** `hub-architect` / `hub-security` / etc., or "none."

Note any assumption about row counts / write patterns that changes the answer.
```

- [ ] **Step 4: Create `.claude/agents/hub-observability.md`**

```markdown
---
name: hub-observability
description: Consult for observability decisions — what to log/measure/trace, structured events vs free text, correlation IDs, error surfacing, and capturing activity so it is genuinely useful for future improvement (not noise).
tools: Read, Grep, Glob
model: opus
---
You are a senior observability/SRE-minded engineer advising a worktree agent on ONE specific decision about making the application diagnosable. Optimize for "when this misbehaves in production, can we see why?" and "does the data we capture let us improve the system later?"

Advisory only — never edit code or any ledger. Reason about the context you are given.

Weigh: the signal worth capturing (structured events with stable fields beat free-text logs); the few metrics that actually indicate health; correlation (request/trace/worktree IDs) so events can be joined; surfacing errors honestly instead of swallowing them; and the cost/noise budget — more logging is not better. Tie back to: which future question will this data answer?

Respond in EXACTLY this structure:
- **Recommendation**
- **Why (long-term):** centered on diagnosability + future learning.
- **Key trade-offs**
- **What to avoid:** noise, unstructured logs, swallowed errors, PII in logs.
- **Also consult:** `hub-security` / `hub-data` / etc., or "none."
```

- [ ] **Step 5: Create `.claude/agents/hub-security.md`**

```markdown
---
name: hub-security
description: Consult for security decisions — authentication/authorization, input validation, injection/escaping, secrets handling, data exposure, and safe-by-default choices.
tools: Read, Grep, Glob
model: opus
---
You are a senior application-security engineer advising a worktree agent on ONE specific decision. Optimize for safe-by-default and the smallest attack surface.

Advisory only — never edit code or any ledger. Reason about the context you are given.

Weigh: who is allowed to do this and where that is enforced (authz at the right layer, not the UI); untrusted input boundaries (validate/parametrize/escape — never string-concat into queries or shells); secrets (never in code, logs, or the client); data exposure (least privilege, no over-broad reads/returns); and whether the safe option is also the default. Flag anything that opens a hole even if it is "convenient."

Respond in EXACTLY this structure:
- **Recommendation**
- **Why (long-term):** centered on attack surface + blast radius if breached.
- **Key trade-offs**
- **What to avoid:** the specific footguns (injection, broken authz, leaked secrets) here.
- **Also consult:** `hub-data` / `hub-observability` / etc., or "none."
```

- [ ] **Step 6: Create `.claude/agents/hub-dx-product.md`**

```markdown
---
name: hub-dx-product
description: Consult for the consumer's view — API/UX ergonomics, naming, error messages, defaults, discoverability, and the edge cases real users/callers will actually hit ("is this easy to use?").
tools: Read, Grep, Glob
model: opus
---
You are a senior engineer with strong product/developer-experience instincts advising a worktree agent on ONE specific decision. Optimize for the person on the other side of this interface — a user or a calling developer.

Advisory only — never edit code or any ledger. Reason about the context you are given.

**Ground every recommendation in the product brief the worktree provides** (the hub's `PRODUCT.md`: vision, target users, priorities, non-goals). If no brief is provided, say so and flag that the product intent is unstated — do not invent it.

Weigh: is the happy path obvious and the common case the default; are names accurate and consistent with what exists; do errors tell the caller what went wrong AND what to do; what real-world edge cases (empty, huge, concurrent, malformed, offline) will they hit; and is this discoverable without reading the source. Favor the smallest, clearest surface that still covers the real need.

Respond in EXACTLY this structure:
- **Recommendation**
- **Why (long-term):** centered on the consumer's experience + support cost.
- **Key trade-offs**
- **What to avoid:** confusing names, silent failures, leaky/over-large surfaces.
- **Also consult:** `hub-architect` / `hub-security` / etc., or "none."
```

- [ ] **Step 7: Verify the six files**

Run:
```powershell
Get-ChildItem .\.claude\agents\hub-*.md | ForEach-Object {
    $head = (Get-Content $_.FullName -TotalCount 1)
    $name = (Select-String -Path $_.FullName -Pattern '^name:\s*(\S+)').Matches.Groups[1].Value
    "{0}  name={1}  frontmatter-open={2}" -f $_.Name, $name, ($head -eq '---')
}
```
Expected: 6 files; each prints `frontmatter-open=True` and a `name=hub-…` matching its filename.

- [ ] **Step 8: Commit**

```powershell
git add .claude/agents/hub-principal.md .claude/agents/hub-architect.md .claude/agents/hub-data.md .claude/agents/hub-observability.md .claude/agents/hub-security.md .claude/agents/hub-dx-product.md
git commit -m "feat(experts): add 6 read-only advisory expert agent definitions"
```

---

## Task 6: Product brief — template, git-ignore, `product.ps1`, and setup scaffold

Gives the `hub-dx-product`/`hub-principal` experts the user's product thinking via a living `PRODUCT.md`
at the hub root: a tracked template, a git-ignore for the real file, a `-Show`/`-Append` helper, and a
`setup-hub.ps1` scaffold step. Worktrees read it **live** at consult time (wired in Task 8's WORKTREE.md
edit), so edits land on the next consult with no re-sync.

**Files:**
- Create: `PRODUCT.example.md`, `product.ps1`, `product.Tests.ps1`
- Modify: `.gitignore`, `setup-hub.ps1`

- [ ] **Step 1: Create the product-brief template `PRODUCT.example.md`**

```markdown
# Product Brief

> The product thinking the hub's `hub-dx-product` and `hub-principal` experts ground their advice in.
> Copy this to `PRODUCT.md` (git-ignored) and fill it in. Keep it short and current — edit anytime;
> worktrees read it live on their next consult. `product.ps1 -Append '<note>'` jots a quick dated update.

## Vision
<What is this product, in one or two sentences? What does "great" look like?>

## Target users
<Who is it for? What do they care about? What is their context / skill level?>

## What success looks like
<The outcomes that matter. How will we know it is working?>

## Priorities (in order)
<e.g. 1. correctness  2. ease of use  3. speed  4. breadth — your actual order>

## Non-goals / out of scope
<What we are deliberately NOT doing — so experts do not over-build.>

## Quality & tone bar
<How polished? What voice / UX standard? Any accessibility / performance commitments?>

## Key constraints
<Tech, platform, compliance, deadlines, integrations that bound the solution space.>
```

- [ ] **Step 2: Git-ignore the generated `PRODUCT.md`**

Append to `.gitignore` (so the real brief, like `hub.config.json`, is never committed):

```
# product brief (per-deployment; generated from PRODUCT.example.md)
PRODUCT.md
```

- [ ] **Step 3: Write the failing test for `product.ps1`**

Create `product.Tests.ps1`:

```powershell
BeforeAll { $script:p = $PSCommandPath.Replace('.Tests.ps1', '.ps1') }   # path to product.ps1

Describe 'product.ps1' {
    It '-Append adds a dated note to the brief' {
        $f = Join-Path $TestDrive 'PRODUCT.md'
        Set-Content $f '# Product'
        & $script:p -Append 'prioritize speed for the MVP' -Path $f | Out-Null
        (Get-Content $f -Raw) | Should -Match 'prioritize speed for the MVP'
    }
    It '-Show prints the brief' {
        $f = Join-Path $TestDrive 'PRODUCT2.md'
        Set-Content $f '# Vision: widgets for cats'
        ((& $script:p -Show -Path $f) -join "`n") | Should -Match 'widgets for cats'
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\product.Tests.ps1 -Output Detailed`
Expected: FAIL (`product.ps1` does not exist yet).

- [ ] **Step 5: Create `product.ps1`**

```powershell
<#
.SYNOPSIS
  View or append to the hub's product brief (PRODUCT.md) — the product thinking the hub-dx-product /
  hub-principal expert advisors ground their advice in. Edit PRODUCT.md directly for big changes; use
  -Append for quick, dated notes during development.
.EXAMPLE
  .\product.ps1 -Show
  .\product.ps1 -Append 'we are prioritizing speed over breadth for the MVP'
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [string]$Append,
    [string]$Path        # override the brief path (default <hub>\PRODUCT.md); used by tests
)
$ErrorActionPreference = 'Stop'
if (-not $Path) {
    try { . (Join-Path $PSScriptRoot 'hub-config.ps1'); $hubRoot = $Hub }   # sets $Hub
    catch { $hubRoot = $PSScriptRoot }
    $Path = Join-Path $hubRoot 'PRODUCT.md'
}
if ($Append) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    if (-not (Test-Path $Path)) { Set-Content -Path $Path -Value "# Product Brief`n" }
    Add-Content -Path $Path -Value "- ($stamp) $Append"
    Write-Host "appended to $Path" -ForegroundColor Green
}
elseif ($Show) {
    if (Test-Path $Path) { Get-Content $Path -Raw }
    else { Write-Host "no PRODUCT.md yet at $Path — copy PRODUCT.example.md to PRODUCT.md and fill it in." -ForegroundColor Yellow }
}
else {
    Write-Host "usage: product.ps1 -Show | -Append '<note>' [-Path <PRODUCT.md>]" -ForegroundColor Cyan
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\product.Tests.ps1 -Output Detailed`
Expected: PASS (2 tests). `-Path` points both tests at a temp file; `-Append` stamps the date and appends; `-Show` prints.

- [ ] **Step 7: Scaffold `PRODUCT.md` in `setup-hub.ps1`**

**READ `setup-hub.ps1` first.** Find where it creates `hub.config.json` from `hub.config.example.json`
(the config-scaffolding step). Immediately AFTER that step (where the hub root is known as `$Hub`), add:

```powershell
# --- product brief: scaffold PRODUCT.md from the template (grounds the hub-dx-product/hub-principal experts) ---
$productPath = Join-Path $Hub 'PRODUCT.md'
$productExample = Join-Path $Hub 'PRODUCT.example.md'
if ((Test-Path $productExample) -and -not (Test-Path $productPath)) {
    Copy-Item $productExample $productPath
    Write-Host "==> Created PRODUCT.md (your product brief). Fill it in so the product/principal experts can ground their advice; update it anytime (worktrees read it live)." -ForegroundColor Green
}
elseif (Test-Path $productPath) { Write-Host "==> PRODUCT.md already present." -ForegroundColor DarkGray }
```

If `setup-hub.ps1` uses a different variable for the hub root than `$Hub`, use that variable. Keep the
step idempotent (only create when absent).

- [ ] **Step 8: Verify + commit**

Run:
```powershell
Invoke-Pester -Path .\product.Tests.ps1 -Output Detailed
Select-String -Path .\.gitignore -Pattern '^PRODUCT\.md$'
Select-String -Path .\setup-hub.ps1 -Pattern 'PRODUCT.md'
```
Expected: 2 tests pass; `.gitignore` contains `PRODUCT.md`; `setup-hub.ps1` references `PRODUCT.md`.

```powershell
git add PRODUCT.example.md .gitignore product.ps1 product.Tests.ps1 setup-hub.ps1
git commit -m "feat(product): add PRODUCT.md brief (template, git-ignore, product.ps1, setup scaffold)"
```

---

## Task 7: Provisioning — `Copy-HubExperts` helper + wire into worktree creation

Adds a testable helper that copies the `hub-*` agents into a worktree, then calls it from `new-worktree.ps1` and `spawn-child.ps1` (git-excluding the copies). Copying only `hub-*` leaves any app-owned `.claude/agents/*` untouched.

**Files:**
- Modify: `hub-lib.ps1` (new `Copy-HubExperts` function)
- Create: `hub-lib.Tests.ps1`
- Modify: `new-worktree.ps1`, `spawn-child.ps1`

- [ ] **Step 1: Confirm `hub-lib.ps1` is safe to dot-source**

Run: `Select-String -Path .\hub-lib.ps1 -Pattern '^[^#\s].*' | Select-Object -First 5`
Expected: only `function …` definitions / param blocks at the top level (no work runs on dot-source). If it DOES run work on dot-source, STOP and report — the test in Step 3 dot-sources it.

- [ ] **Step 2: Write the failing test**

Create `hub-lib.Tests.ps1`:

```powershell
BeforeAll {
    . $PSCommandPath.Replace('.Tests.ps1', '.ps1')   # dot-source hub-lib.ps1
}

Describe 'Copy-HubExperts' {
    It 'copies only hub-*.md into <wt>\.claude\agents and returns the count' {
        $hub = Join-Path $TestDrive 'hub'; $wt = Join-Path $TestDrive 'wt'
        $src = Join-Path $hub '.claude\agents'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content (Join-Path $src 'hub-architect.md') 'a'
        Set-Content (Join-Path $src 'hub-data.md') 'b'
        Set-Content (Join-Path $src 'app-own.md') 'c'   # must NOT be copied
        $n = Copy-HubExperts -Hub $hub -WtPath $wt
        $n | Should -Be 2
        (Test-Path (Join-Path $wt '.claude\agents\hub-architect.md')) | Should -BeTrue
        (Test-Path (Join-Path $wt '.claude\agents\app-own.md')) | Should -BeFalse
    }
    It 'returns 0 when the hub has no expert agents' {
        $hub = Join-Path $TestDrive 'hub2'; $wt = Join-Path $TestDrive 'wt2'
        New-Item -ItemType Directory -Force -Path $hub | Out-Null
        (Copy-HubExperts -Hub $hub -WtPath $wt) | Should -Be 0
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `Invoke-Pester -Path .\hub-lib.Tests.ps1 -Output Detailed`
Expected: FAIL (`Copy-HubExperts` is not defined).

- [ ] **Step 4: Add `Copy-HubExperts` to `hub-lib.ps1`**

Append this function to `hub-lib.ps1` (at the end of the file, after the existing functions):

```powershell
function Copy-HubExperts {
    # Copy the hub's hub-*.md advisory agents into a worktree's .claude\agents (creating it).
    # Returns the number copied (0 if the hub has none). Leaves any app-owned agents untouched.
    param([Parameter(Mandatory)][string]$Hub, [Parameter(Mandatory)][string]$WtPath)
    $src = Join-Path $Hub '.claude\agents'
    $agents = @(Get-ChildItem -Path $src -Filter 'hub-*.md' -File -ErrorAction SilentlyContinue)
    if (-not $agents) { return 0 }
    $dest = Join-Path $WtPath '.claude\agents'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($a in $agents) { Copy-Item $a.FullName (Join-Path $dest $a.Name) -Force }
    return $agents.Count
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Invoke-Pester -Path .\hub-lib.Tests.ps1 -Output Detailed`
Expected: PASS (2 tests).

- [ ] **Step 6: Wire it into `new-worktree.ps1`**

In `new-worktree.ps1`, find this exact line (the end of the WORKTREE.md provisioning block — UNIQUE):

```powershell
else { Write-Host "==> WARNING: hub WORKTREE.md not found - worktree has no standing-rules file to @-mention." -ForegroundColor Yellow }
```

and insert immediately AFTER it:

```powershell

# --- expert advisors: copy the hub-* consultant agents into the worktree (git-excluded; consulted in-session) ---
$expertCount = Copy-HubExperts -Hub $Hub -WtPath $WtPath
if ($expertCount -gt 0) {
    Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/.claude/agents/hub-*.md')
    Write-Host "==> $expertCount expert advisor(s) copied into .claude\agents\ (git-excluded)" -ForegroundColor Green
}
```

(`hub-lib.ps1` is already dot-sourced by `new-worktree.ps1`; confirm by checking for an existing `. (Join-Path $PSScriptRoot 'hub-lib.ps1')` near the top — it is the source of `Add-HubExclude`.)

- [ ] **Step 7: Wire it into `spawn-child.ps1`**

In `spawn-child.ps1`, find this exact line (UNIQUE):

```powershell
if (Test-Path $wtRules) { Copy-Item $wtRules (Join-Path $childPath 'WORKTREE.md') -Force }
```

and insert immediately AFTER it:

```powershell
$expertCount = Copy-HubExperts -Hub $Hub -WtPath $childPath
if ($expertCount -gt 0) { Add-HubExclude -CommonGitDir (Join-Path $Hub '.bare') -Patterns @('/.claude/agents/hub-*.md') }
```

(If `spawn-child.ps1` does not already dot-source `hub-lib.ps1`, add `. (Join-Path $PSScriptRoot 'hub-lib.ps1')` near its top, next to where `$Hub` is established — verify before assuming. `Add-HubExclude`/`Copy-HubExperts` both live there.)

- [ ] **Step 8: Verify the wiring**

Run:
```powershell
Select-String -Path .\new-worktree.ps1, .\spawn-child.ps1 -Pattern 'Copy-HubExperts'
Invoke-Pester -Path .\hub-lib.Tests.ps1 -Output Detailed
```
Expected: a `Copy-HubExperts` call in each script; the 2 helper tests still PASS.

- [ ] **Step 9: Commit**

```powershell
git add hub-lib.ps1 hub-lib.Tests.ps1 new-worktree.ps1 spawn-child.ps1
git commit -m "feat(provision): copy hub-* expert agents into each worktree (git-excluded)"
```

---

## Task 8: Agent recognition in `WORKTREE.md`

Adds the agent-facing "Consulting the experts" section (new §6), a completion-report row, a record-to-ledger line, and the PR ADR-note instruction. Inserting a new §6 shifts §6→§11; renumber and fix the two affected cross-references. (Docs task — verify with `git diff` + a grep.)

**Files:**
- Modify: `WORKTREE.md`

- [ ] **Step 1: Add the completion-report row (§4)**

Find this exact 2-line anchor (the last two rows of the §4 report table — the `Hub findings` row currently has NO trailing comma):

```
  'Recommended follow-ups|<N found — see table below  /  none>',
  'Hub findings|<N logged this session — see ledger / none>'
```

Replace with (add a comma to the Hub findings row, then a new final row):

```
  'Recommended follow-ups|<N found — see table below  /  none>',
  'Hub findings|<N logged this session — see ledger / none>',
  'Consults|<N expert consults logged — see ledger / none>'
```

- [ ] **Step 2: Insert the new §6 section (and renumber the old §6 header to §7)**

Find this exact line:

```
## 6. Hub findings (problems with these instructions / your environment — not the repo's code)
```

Replace it with the new §6 section followed by the renumbered §7 header (reproduce the nested ```powershell block verbatim):

````
## 6. Consulting the experts (get professional, long-term-minded advice on decisions)

This hub provisions a panel of **read-only advisor agents** into your `.claude\agents\` folder
(`hub-principal` + `hub-architect`, `hub-data`, `hub-observability`, `hub-security`, `hub-dx-product`).
They think like a professional application-development team and answer one question at a time. They are
**advisory** — you weigh the advice, **you** decide, and you record the decision.

**When to consult:**
- **Mandatory at the spec-gate (complex track, §3):** before you STOP to present `SPEC.md`/`PLAN.md`,
  consult the relevant expert(s) on each key design decision and fold the guidance in.
- **On-demand (both tracks):** at any consequential fork you are unsure about, consult the fitting
  expert instead of guessing. `hub-principal` is the default; pull in a specialist for depth.

**How to consult:** invoke the expert **in-process** (the `Agent`/Task tool with `subagent_type: hub-<x>`,
or `@hub-<x>`). **Curate the question and paste the relevant context** (the decision, the options, the
constraints, the specific code) INTO the request — do not rely on the expert to go find the right files.
This is subscription-covered; **never** launch a headless `claude` for this (§10).

**Product context:** when consulting `hub-dx-product` or `hub-principal`, also read the hub's product brief
at `<hub>\PRODUCT.md` (read it live each time — it is the user's current product thinking) and include the
relevant parts in your request. If it is absent, say so and proceed.

**Record every consultation** so the decision + rationale is observable (see also §8):

```powershell
& <hub>\review-coverage.ps1 consult -Worktree <FOLDER> -Expert hub-<x> -Area <area> `
    -Question '<the decision>' -Advice '<expert recommendation, summarized>' `
    -Decision '<what you decided>' -Followed <yes|partial|overridden> -Rationale '<why — REQUIRED if overridden>' [-Issue <N>]
```

**Also put the decisions in your PR.** Append a short `## Design decisions` section to your PR body —
one line per consult (expert · decision · one-line why) — so the rationale travels with the code for
human reviewers, not only in the hub ledger.

If the expert files are not present (older worktree), note "experts unavailable" and reason carefully
yourself rather than blocking.

## 7. Hub findings (problems with these instructions / your environment — not the repo's code)
````

- [ ] **Step 3: Add the `consult` line to the record-to-ledger block (now §8)**

Find this exact line (the `hubfind` line added by the hub-findings work — UNIQUE):

```
& <hub>\review-coverage.ps1 hubfind   -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> -Title '<short>' -Detail '<what + where + what it should be>'   # any HUB finding (see §6)
```

Replace it with (fix the back-reference §6→§7, and add the consult line):

```
& <hub>\review-coverage.ps1 hubfind   -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> -Title '<short>' -Detail '<what + where + what it should be>'   # any HUB finding (see §7)
& <hub>\review-coverage.ps1 consult   -Worktree <FOLDER> -Expert hub-<x> -Question '<decision>' -Decision '<what you decided>' -Followed <yes|partial|overridden> [-Area <a> -Advice '<...>' -Rationale '<...>' -Issue <N>]   # each expert consult (see §6)
```

- [ ] **Step 4: Renumber the remaining section headers**

Apply these exact header replacements:

- `## 7. Record to the hub ledger (system of record for monitoring + triage)` → `## 8. Record to the hub ledger (system of record for monitoring + triage)`
- `## 8. Environment note` → `## 9. Environment note`
- `## 9. Hard constraints` → `## 10. Hard constraints`
- `## 10. Merge → migrate (only if the user explicitly asks YOU to merge)` → `## 11. Merge → migrate (only if the user explicitly asks YOU to merge)`

- [ ] **Step 5: Fix the two affected cross-references**

- `7. **Record to the hub ledger** (section 7).` → `7. **Record to the hub ledger** (section 8).`
- `applying happens only at merge time (section 10).` → `applying happens only at merge time (section 11).`

(The `(section 4)` and both `(section 3)` references are unchanged — those sections did not move.)

- [ ] **Step 6: Verify numbering + references**

Run:
```powershell
Select-String -Path .\WORKTREE.md -Pattern '^## \d+\.', '\(section \d+\)'
```
Expected: headers read `## 1.` … `## 11.` with no gaps/duplicates; the only `(section N)` references are `(section 4)`, `(section 8)`, `(section 3)`, `(section 11)`, `(section 3)`. Confirm no stray `(section 7)` (as a record-ledger cross-ref) or `(section 10)` (as a merge cross-ref) remain. (Note: the new §6 body legitimately references §3, §8, §10 by `§`-notation — those are fine.)

- [ ] **Step 7: Commit**

```powershell
git add WORKTREE.md
git commit -m "docs(worktree): teach agents to consult the experts (+ renumber sections)"
```

---

## Task 9: Orchestrator docs in `CLAUDE.md`

Adds the `consult` verb to the command list, the `consult` clause to the tables description, a consult glance in the merge-time sweep, the improvement-loop note, and the rollout note. (Docs task. `CLAUDE.md` is large; **Read each region before editing** to confirm the anchor matches on disk.)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the verb to the command block**

Find this exact line (the last hub-findings command line added earlier — UNIQUE):

```
.\review-coverage.ps1 hub-resolve -Id 4 -Target <prompt|config|script|memory> -Note '<what changed>'   # close after editing the real artifact (or -Dismiss)
```

Insert immediately AFTER it:

```
# --- expert consultations (worktrees consult hub-* advisor agents; advisory; recorded for observability) ---
.\review-coverage.ps1 consult -Worktree <folder> -Expert hub-<x> -Question '..' -Decision '..' -Followed <yes|partial|overridden> [-Area .. -Advice '..' -Rationale '..' -Issue N]   # record a consultation + decision
.\product.ps1 -Show ; .\product.ps1 -Append '<product insight>'   # view / update the product brief the hub-dx-product & hub-principal experts ground their advice in
```

- [ ] **Step 2: Add the `consult` clause to the "Tables:" description**

Find the `hubfinding` clause at the end of the "Tables:" paragraph (it ends with — match the exact on-disk text; READ the region first):

```
**never** a GH issue).
```

Replace it with (append the new clause):

```
**never** a GH issue) · **consult** (one row per expert consultation a worktree logged — `expert`/`area`/`question`/`advice`/`decision`/`followed` (yes|partial|overridden)/`rationale`; append-only; the `overridden`+rationale rows are the signal for improving the experts).
```

(If `same verify fields).` / `**never** a GH issue).` is not unique on disk, extend the anchor with the few preceding words shown in the file. READ the paragraph first.)

- [ ] **Step 3: Fold a consult glance into the merge-time sweep (step 4)**

In "Merging a finished PR" → step 4, find this exact line (the hub-findings sweep clause added earlier — READ the region; match on disk):

```
   `.\review-coverage.ps1 hub-findings` (open problems with the hub's own prompts/config/scripts/env).
```

Replace it with (append the consult glance):

```
   `.\review-coverage.ps1 hub-findings` (open problems with the hub's own prompts/config/scripts/env). Also
   glance at the merged worktree's **consults** (`.\review-coverage.ps1 monitor` shows recent ones) —
   especially `overridden` decisions — as part of triage.
```

- [ ] **Step 4: Add the improvement-loop note**

Immediately after the paragraph you edited in Step 3 (still in step 4 of the merge runbook), add this sentence on its own line (match the surrounding indentation — READ the region):

```
   **Improvement loop:** periodically review the consult log (which experts on what, the override rate,
   decisions that later correlated with findings/bugs) and use it to sharpen the `.claude\agents\hub-*.md`
   expert prompts. The data is structured so this is a query, not an archaeology dig.
```

- [ ] **Step 5: Add the rollout note to the ledger section**

Find this exact line (the hub-findings rollout note added earlier — UNIQUE):

```powershell
# existing hub upgrading to the hub-findings channel? re-run init once (idempotent) to add the hubfinding table:
.\review-coverage.ps1 init
```

Replace it with (broaden the note to cover the consult table too):

```powershell
# existing hub upgrading to the hub-findings / consult channels? re-run init once (idempotent) to add the new tables:
.\review-coverage.ps1 init
```

- [ ] **Step 6: Verify the edits**

Run:
```powershell
Select-String -Path .\CLAUDE.md -Pattern 'consult', '\*\*consult\*\*', 'Improvement loop'
```
Expected: matches in the command block, the tables description, the merge-sweep step, and the improvement-loop note.

- [ ] **Step 7: Commit**

```powershell
git add CLAUDE.md
git commit -m "docs(hub): document the expert-consultation channel (commands, table, merge sweep, loop)"
```

---

## Task 10: One-line mention in `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the ledger-commands cheatsheet**

Run: `Select-String -Path .\README.md -Pattern 'hub-findings|review-coverage.ps1 recommendations' -Context 0,2`
The "### Ledger commands" block is a ```powershell cheatsheet of `command   # comment` lines.

- [ ] **Step 2: Add the one-liner**

Find this exact line (the hub-findings cheatsheet line added earlier — UNIQUE):

```
.\review-coverage.ps1 hub-findings                     # hub-layer problems (prompt/config/script/env): hubfind logs, hub-resolve closes
```

Insert immediately AFTER it (align the `#` comment column with the surrounding lines by eye):

```
.\review-coverage.ps1 consult                          # record an expert consultation + the decision a worktree made (advisory; observable)
```

- [ ] **Step 3: Commit**

```powershell
git add README.md
git commit -m "docs(readme): mention the expert-consultation ledger channel"
```

---

## Final verification

- [ ] **Step 1: Run the full test suite**

```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\hub-lib.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\product.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\hub-checks.Tests.ps1 -Output Detailed
```
Expected: all `review-coverage.Tests.ps1`, `hub-lib.Tests.ps1`, and `product.Tests.ps1` tests PASS; `hub-checks.Tests.ps1` still PASS (no regression — this plan does not touch `hub-checks.ps1`).

- [ ] **Step 2: Manual end-to-end smoke (real ledger)**

```powershell
.\review-coverage.ps1 init
.\review-coverage.ps1 consult -Worktree orchestrator -Expert hub-principal -Area general -Question 'smoke: build vs buy?' -Advice 'buy' -Decision 'buy' -Followed yes
.\review-coverage.ps1 monitor          # confirm the "Recent consults" section lists it
.\ledger-to-html.ps1 -NoOpen           # confirm it renders (console summary shows "consults 1")
```
Expected: the consult appears in `monitor`, the dashboard renders. (Remove the smoke DB afterward if this checkout had none: the row is harmless, but `.review\` is git-ignored.)

- [ ] **Step 3: Provisioning E2E (the part Pester can't fully cover)**

If a `hub.config.json` is present, provision a throwaway worktree and confirm the experts land + are git-excluded, then retire it:

```powershell
.\new-worktree.ps1 -Name agent-experts-smoke
Get-ChildItem .\agent-experts-smoke\.claude\agents\hub-*.md    # expect 6 files
git -C .\agent-experts-smoke status --porcelain                # expect NO .claude/agents entries (git-excluded)
.\retire-worktree.ps1 -Name agent-experts-smoke -DeleteBranch -Force
```
Expected: 6 `hub-*.md` in the worktree's `.claude\agents\`; `git status` in the worktree shows them as **ignored** (not untracked). If no hub is configured here, instead rely on `hub-lib.Tests.ps1` (Task 6) + inspection of the wiring.

---

## Self-Review (completed during planning)

- **Spec coverage:** consult table (Task 1) · consult verb incl. advisory/override capture + activity row (Task 2) · monitor (Task 3) · dashboard 6th section (Task 4) · the 6 expert agents incl. read-only/opus/structured prompts + product-brief grounding (Task 5) · product brief: template + git-ignore + `product.ps1` (-Show/-Append) + setup scaffold (Task 6) · per-worktree git-excluded provisioning via a tested `Copy-HubExperts` (Task 7) · WORKTREE.md consult workflow incl. spec-gate-mandatory + on-demand + live-`PRODUCT.md` read + ADR-in-PR + record line + report row (Task 8) · CLAUDE.md commands/tables/merge-sweep/improvement-loop/rollout + product.ps1 (Task 9) · README (Task 10) · Pester for every code task + a provisioning E2E (Final). The spec's deferred items (nested routing, `hub-quality`/standalone, outcome-linking) are intentionally out of scope.
- **Placeholder scan:** no TBD/TODO; every code/test step shows complete code and exact expected output. `<x>`/`<FOLDER>`/`<area>`/`<hub>`/`<N>` are the hub's intentional doc templating, consistent with existing files.
- **Type/name consistency:** table `consult`; columns `worktree/wtype/expert/area/issue/question/advice/decision/followed/rationale/created_at`; verb `consult`; params `-Expert/-Question/-Advice/-Decision/-Followed/-Rationale`; JSON key `consults`; JS section `id:'consults'`; helper `Copy-HubExperts -Hub -WtPath`; agent names `hub-principal/hub-architect/hub-data/hub-observability/hub-security/hub-dx-product` are used identically across all tasks. The `consult` test code uses `-DbPath` (the existing override param). Product-brief names: `PRODUCT.example.md` (template) → `PRODUCT.md` (git-ignored), helper `product.ps1 -Show/-Append/-Path`, read live from `<hub>\PRODUCT.md`.
