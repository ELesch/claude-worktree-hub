# Product-Aware Reviewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three product-aware reviewer personas and a mandatory worktree **stage-one product-necessity gate** so a worktree decides whether a finding/issue is *worth doing* (legitimate · necessary · scoped) before writing any fix code.

**Architecture:** Three read-only `hub-product-*` advisor agents (grounded in `PRODUCT.md`) are provisioned into every worktree by the existing `hub-*` copy glob (no script change). `WORKTREE.md` gains a stage-one gate run via the existing in-process consult mechanism; the verdict is recorded with the existing `consult` verb (`area='product-necessity'`) and a `halted-unnecessary` worktree status, so the existing consult **refinement loop** captures reviewer-vs-human disagreements. All other recording reuses existing verbs/schema — no migration.

**Tech Stack:** Markdown agent definitions (`.claude/agents/hub-*.md`), PowerShell helpers (`review-coverage.ps1`, `hub-lib.ps1`), Pester v5 tests, SQLite ledger (`.review/coverage.db`). Spec: `docs/superpowers/specs/2026-06-29-product-aware-reviewers-design.md`.

**Pester on this machine** (standard install path is broken — module saved elsewhere):
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\<file>.Tests.ps1 -Output Detailed
```

**Branch:** `feature/product-aware-reviewers` (already created; the design spec is committed there).

---

### Task 1: The three reviewer persona agents (+ structural test)

The persona panel is one component (the roster). Test the deliverable structurally (frontmatter + required output sections + that they match the provisioning glob), then create all three files.

**Files:**
- Create: `hub-product-agents.Tests.ps1`
- Create: `.claude/agents/hub-product-owner.md`
- Create: `.claude/agents/hub-product-user.md`
- Create: `.claude/agents/hub-product-maintenance.md`

- [ ] **Step 1: Write the failing test**

Create `hub-product-agents.Tests.ps1`:

```powershell
BeforeAll {
    $script:AgentsDir = Join-Path $PSScriptRoot '.claude/agents'
    $script:Personas  = 'hub-product-owner', 'hub-product-user', 'hub-product-maintenance'
}

Describe 'product-aware reviewer personas' {
    It 'has all three persona agent files' {
        foreach ($p in $Personas) {
            (Test-Path (Join-Path $AgentsDir "$p.md")) | Should -BeTrue -Because "$p.md must exist"
        }
    }

    It 'each persona has valid read-only frontmatter (name, tools, opus, description)' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match "(?m)^name:\s*$p\s*$"
            $c | Should -Match "(?m)^tools:\s*Read,\s*Grep,\s*Glob\s*$"
            $c | Should -Match "(?m)^model:\s*opus\s*$"
            $c | Should -Match "(?m)^description:\s*\S"
        }
    }

    It 'each persona prompt has the required review output structure' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match '\*\*Legitimacy:\*\*'
            $c | Should -Match '\*\*Necessity:\*\*'
            $c | Should -Match '\*\*Scope/effort:\*\*'
            $c | Should -Match '\*\*Recommendation:\*\*'
            $c | Should -Match '\*\*Also consult:\*\*'
        }
    }

    It 'each persona grounds in PRODUCT.md and calibrates by issue origin' {
        foreach ($p in $Personas) {
            $c = Get-Content (Join-Path $AgentsDir "$p.md") -Raw
            $c | Should -Match 'PRODUCT\.md'
            $c | Should -Match '(?i)origin'
        }
    }

    It 'personas match the hub-*.md provisioning glob (so worktrees receive them)' {
        $globbed = @(Get-ChildItem -Path $AgentsDir -Filter 'hub-*.md' -File).Name
        foreach ($p in $Personas) { $globbed | Should -Contain "$p.md" }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\hub-product-agents.Tests.ps1 -Output Detailed
```
Expected: FAIL — "has all three persona agent files" (the files do not exist yet).

- [ ] **Step 3: Create `.claude/agents/hub-product-owner.md`**

```markdown
---
name: hub-product-owner
description: Review a finding/issue for product necessity from the app-owner / business-value view — does it advance a PRODUCT.md priority or the roadmap, or is it a distraction / gold-plating a non-goal? The default product reviewer (stage-one necessity gate).
tools: Read, Grep, Glob
model: opus
---
You are the product owner / app developer for this application, reviewing ONE specific finding or issue to decide whether it is worth doing. You think about the product's motives, desires, and needs — the roadmap and the priorities in PRODUCT.md — not just whether the code is technically wrong.

Review-only and advisory: you never edit code, run anything, or write to any ledger. Reason about the context the worktree gives you (the item, the relevant current code/evidence, the draft scope, the item's origin, and the product brief) — do not go hunting for files.

Ground every judgment in the PRODUCT.md brief the worktree provides (vision, target users, priorities, non-goals). Name the specific priority this serves, or the non-goal it gold-plates. If no brief is provided, say so and flag that product intent is unstated — do not invent it; lean toward "proceed" for user-filed items and surface the gap.

Calibrate by the item's ORIGIN (given to you):
- user — the human filed and approved this; confirm it and right-size the scope. Recommend dismiss only if it is clearly already-done or self-contradictory; never override the user's explicit request on taste alone.
- recon / recommendation — genuinely weigh whether this is worth doing at all for the product.

Weigh: does this move a stated priority or unblock the roadmap; is the value proportionate to the change scope; is the common/important case served, or is this effort on a rare or non-goal path; what is the opportunity cost versus the rest of the backlog.

Respond in EXACTLY this structure:
- **Legitimacy:** still-valid | already-fixed | partially-fixed | out-of-scope | needs-info — judged from the evidence given (say so if you cannot tell).
- **Necessity:** necessary | borderline | not-necessary — **confidence:** high | medium | low — grounded in PRODUCT.md (name the priority or the non-goal).
- **Scope/effort:** the files/areas + rough size the fix needs, and whether it is proportionate to the value.
- **Recommendation:** proceed | dismiss | defer — one line, tied to the product brief.
- **Also consult:** hub-product-user / hub-product-maintenance if necessity hinges on that lens, or "none."

Be honest about uncertainty — "it depends on X; if X then A else B" beats false confidence.
```

- [ ] **Step 4: Create `.claude/agents/hub-product-user.md`**

```markdown
---
name: hub-product-user
description: Review a finding/issue for product necessity from the END-USER's view — would a real user notice, care, or be blocked? Use for UX, a11y, error messages, user-facing behavior/copy, onboarding.
tools: Read, Grep, Glob
model: opus
---
You are an advocate for the people who actually USE this application, reviewing ONE specific finding or issue to decide whether it is worth doing for them. Optimize for real user task success, clarity, and trust.

Review-only and advisory: you never edit code, run anything, or write to any ledger. Reason about the context the worktree gives you (the item, the relevant current code/evidence, the draft scope, the item's origin, and the product brief) — do not go hunting for files.

Ground every judgment in the PRODUCT.md brief the worktree provides (especially target users and what success looks like for them). If no brief is provided, say so and reason from general user-experience principles rather than inventing product intent.

Calibrate by the item's ORIGIN (given to you):
- user — the human filed and approved this; confirm and right-size the scope; recommend dismiss only if clearly already-done.
- recon / recommendation — weigh whether a real user would ever notice or be helped.

Weigh: would a real user hit this and be blocked, confused, or lose trust; is it on a path users actually take, or an internal/admin surface no user sees; does it affect the common case or a rare edge; is the user-visible benefit proportionate to the change scope. Internal-only polish that no user perceives is usually NOT necessary.

Respond in EXACTLY this structure:
- **Legitimacy:** still-valid | already-fixed | partially-fixed | out-of-scope | needs-info — judged from the evidence given.
- **Necessity:** necessary | borderline | not-necessary — **confidence:** high | medium | low — grounded in user impact per PRODUCT.md.
- **Scope/effort:** the files/areas + rough size, and whether it is proportionate to the user benefit.
- **Recommendation:** proceed | dismiss | defer — one line, centered on the user.
- **Also consult:** hub-product-owner / hub-product-maintenance if the call hinges on business value or maintenance cost, or "none."

Be honest about uncertainty.
```

- [ ] **Step 5: Create `.claude/agents/hub-product-maintenance.md`**

```markdown
---
name: hub-product-maintenance
description: Review a finding/issue for product necessity from the SUPPORT & MAINTENANCE-cost view — cost of inaction (tickets, on-call, tech-debt interest) vs. the fix's scope? Use for perf, refactor, tech-debt, deps, observability, tests, internal tooling.
tools: Read, Grep, Glob
model: opus
---
You are a support- and maintenance-minded engineer reviewing ONE specific finding or issue to decide whether it is worth doing, by weighing the cost of NOT doing it against the cost of doing it.

Review-only and advisory: you never edit code, run anything, or write to any ledger. Reason about the context the worktree gives you (the item, the relevant current code/evidence, the draft scope, the item's origin, and the product brief) — do not go hunting for files.

Ground your judgment in the PRODUCT.md brief the worktree provides (priorities, constraints, what the team can afford to maintain). If no brief is provided, say so and reason generally.

Calibrate by the item's ORIGIN (given to you):
- user — confirm and right-size the scope; recommend dismiss only if clearly already-done.
- recon / recommendation — weigh inaction cost vs. fix scope honestly.

Weigh: the cost of INACTION — support tickets, on-call/incident risk, data corruption, compounding tech-debt interest, blocked future work — versus the scope and risk of the fix; whether a smaller change captures most of the value; whether this is load-bearing or a rarely-hit path. A real but low-traffic, low-risk issue with a large fix is often NOT worth it now (defer); a small fix that removes recurring pain usually is.

Respond in EXACTLY this structure:
- **Legitimacy:** still-valid | already-fixed | partially-fixed | out-of-scope | needs-info — judged from the evidence given.
- **Necessity:** necessary | borderline | not-necessary — **confidence:** high | medium | low — cost-of-inaction vs. scope.
- **Scope/effort:** the files/areas + rough size, and whether it is proportionate to the inaction cost.
- **Recommendation:** proceed | dismiss | defer — one line.
- **Also consult:** hub-product-owner / hub-product-user if the call hinges on business value or user impact, or "none."

Be honest about uncertainty.
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```powershell
Invoke-Pester -Path .\hub-product-agents.Tests.ps1 -Output Detailed
```
Expected: PASS (all 5 `It` blocks green).

- [ ] **Step 7: Commit**

```powershell
git add hub-product-agents.Tests.ps1 .claude/agents/hub-product-owner.md .claude/agents/hub-product-user.md .claude/agents/hub-product-maintenance.md
git commit -m "feat: add product-aware reviewer personas (owner/user/maintenance)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Recording-convention guard tests

The `consult` and `progress` verbs already accept arbitrary `-Expert`/`-Area`/`-Status` strings, so no script change is needed. These tests **lock in the `product-necessity` convention** (the refinement loop queries it) and the `halted-unnecessary` status, guarding against a future regression that adds an allow-list. They pass on first run.

**Files:**
- Modify: `review-coverage.Tests.ps1` (append two new `Describe` blocks at end of file)

- [ ] **Step 1: Write the tests**

Append to `review-coverage.Tests.ps1` (uses the file's existing `BeforeAll` helpers `$script:rc` and `New-TempDb`):

```powershell
Describe 'product-necessity consult convention' {
    It 'records a hub-product persona review under area=product-necessity' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-42-x' -Expert hub-product-owner -Area product-necessity `
            -Question 'Is #42 necessary for the product?' -Advice 'necessary, high' -Decision 'proceed' -Followed yes -Issue 42 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT expert,area,followed,issue FROM consult WHERE id=1;") |
            Should -Be 'hub-product-owner|product-necessity|yes|42'
    }
    It 'captures a human override of a not-necessary verdict (the refinement signal)' {
        $db = New-TempDb
        & $script:rc consult -DbPath $db -Worktree 'issue-7-x' -Expert hub-product-owner -Area product-necessity `
            -Question 'Is #7 necessary?' -Advice 'not-necessary, high' -Decision 'user chose proceed' `
            -Followed overridden -Rationale 'user wants it for a launch demo' -Issue 7 | Out-Null
        (& sqlite3 -separator '|' $db "SELECT followed,rationale FROM consult WHERE id=1;") |
            Should -Be 'overridden|user wants it for a launch demo'
    }
}

Describe 'halted-unnecessary worktree status' {
    It 'progress records halted-unnecessary and it surfaces in monitor' {
        $db = New-TempDb
        & $script:rc progress -DbPath $db -Worktree 'issue-42-x' -Status halted-unnecessary -Note 'not necessary (recommend close)' | Out-Null
        (& sqlite3 $db "SELECT status FROM worktree WHERE name='issue-42-x';") | Should -Be 'halted-unnecessary'
        (& $script:rc monitor -DbPath $db | Out-String) | Should -Match 'halted-unnecessary'
    }
}
```

- [ ] **Step 2: Run the tests**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path .\review-coverage.Tests.ps1 -Output Detailed
```
Expected: PASS (the new blocks green; all pre-existing tests still green). If the new blocks FAIL, a verb regressed — fix the verb, do not weaken the test.

- [ ] **Step 3: Commit**

```powershell
git add review-coverage.Tests.ps1
git commit -m "test: guard product-necessity consult + halted-unnecessary status conventions" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `WORKTREE.md` — the stage-one necessity gate

Add the gate mechanics as a **subsection of `## 6. Consulting the experts`** (the personas are consult agents). This needs **NO section renumbering**, so every existing `(section N)`/`(§N)` cross-reference stays valid. Then wire the gate as the first action in both tracks (§2, §3) and add a **Necessity** row to the completion report (§4).

**Files:**
- Modify: `WORKTREE.md`

- [ ] **Step 1: Add the gate mechanics as a §6 subsection**

At the **end of `## 6. Consulting the experts`** (immediately after its last line `...note "experts unavailable" and reason carefully yourself rather than blocking.` and before `## 7. Hub findings ...`), append:

```markdown
### 6a. Product-necessity reviewers — the stage-one gate (run FIRST, before any fix code)

Three read-only **product-reviewer personas** are also provisioned into your `.claude\agents\`:

- `hub-product-owner` *(default)* — does this advance a `PRODUCT.md` priority / the roadmap, or gold-plate a non-goal?
- `hub-product-user` — would a real user of this app notice, care, or be blocked?
- `hub-product-maintenance` — cost of inaction (tickets, on-call, tech-debt interest) vs. the fix's scope?

**This gate is mandatory and runs before you install or write any code** (it is step 2 of §2 / step 1 of §3):

1. From `@ISSUE.md` + the relevant **current code**, establish the facts: is the problem still real, and the rough scope.
2. Read `<hub>\PRODUCT.md` live, then **consult the routed persona in-process** (the `Agent`/Task tool with
   `subagent_type: hub-product-<x>`, or `@hub-product-<x>`; default `hub-product-owner` unless your launch
   prompt names another). **Curate the request:** paste in the issue, the relevant code/evidence, your draft
   scope, the issue's **origin** (user / recon / recommendation), and the relevant `PRODUCT.md` parts — do
   NOT rely on the persona reading your files. It returns: legitimacy · necessity (+confidence) · scope · recommendation.
3. Act on the verdict:
   - **necessary** → proceed with your track.
   - **not-necessary at HIGH confidence** → **HALT.** Do not install or write code. Set status
     `halted-unnecessary`, record the consult, and produce your completion report (§4) recommending the user
     **close #<N>**. Do **not** close the issue yourself.
   - **borderline, not-necessary at medium/low confidence, already-fixed/out-of-scope, or needs-info** →
     **STOP and ask the user** (set status `spec-gate`): present the verdict and wait. Record the consult
     **and the user's choice**.
4. **Calibrate by origin:** if the issue is **user-origin** (the user filed/approved it), never auto-HALT —
   confirm and right-size the scope; only the user can drop their own request. Weigh "should we do this at
   all" only for recon/recommendation-origin items.
5. **Record it** (system of record + refinement loop) — and, when you proceed, also summarize the verdict in
   your PR's `## Design decisions` section like any other consult:
   ```powershell
   & <hub>\review-coverage.ps1 consult -Worktree <FOLDER> -Expert hub-product-<x> -Area product-necessity `
       -Issue <N> -Question '<the necessity call>' -Advice '<verdict: legitimacy · necessity+confidence · scope · rec>' `
       -Decision '<proceed | halted — not necessary | gated → user chose X>' `
       -Followed <yes|partial|overridden> -Rationale '<why — REQUIRED on override>'
   ```

If the persona files are absent (older worktree), note "product reviewers unavailable", reason from
`PRODUCT.md` yourself, and proceed — don't block.
```

- [ ] **Step 2: Wire the gate into the simple track (§2)**

Replace the numbered step list of `## 2. Autonomous solver workflow (simple track)` (current steps `1.`–`7.`) with this list — the gate is the new step 2, and install moves after it so a HALT wastes no work:

```markdown
1. Read **`@ISSUE.md`** (force-included) — the full issue: body, comments, and any screenshots in
   `issue-assets\`. It is your complete, self-contained brief.
2. **Stage one — product-necessity gate (§6a). Before installing or coding,** read the relevant current code
   + `<hub>\PRODUCT.md` and consult the routed product persona. **Proceed only if necessary**; otherwise
   **HALT** or **ask the user** per §6a, and record the consult.
3. Run `<installCmd>` (e.g. `pnpm install` — fresh worktree has no `node_modules`), then mark yourself
   working on the monitor:
   `& <hub>\review-coverage.ps1 progress -Worktree <FOLDER> -Status working`
4. Investigate the **root cause**, then implement the fix following repo conventions. (Issue-specific
   guidance is in the launch prompt.)
5. Validate with `<verifyCmd>` (e.g. `pnpm verify` — typecheck + lint) and **run/add tests that genuinely
   cover the fix**.
6. Commit, `git push -u origin <BRANCH>`, then open a PR (`gh pr create`, base `<defaultBranch>`). Use a conventional
   title (`fix(#<N>): …` / `feat(#<N>): …`) and put **`Fixes #<N>`** in the PR body so the issue auto-closes
   on merge. **DO NOT merge.**
7. Finish with the **completion report** (section 4) as your **last output**.
8. **Record to the hub ledger** (section 8).
```

- [ ] **Step 3: Wire the gate into the complex track (§3)**

In `## 3. Gated complex workflow`, replace the current step `1.` (`1. **Research** the relevant code ...`) with these **two** steps:

```markdown
1. **Stage one — product-necessity gate (§6a):** before researching the build, consult the routed product
   persona (curate issue + current code + origin + `PRODUCT.md`) to confirm the work is necessary. If not,
   **HALT/ask** and record the consult — do not design a fix for work that isn't worth doing.
2. **Research** the relevant code (use in-process **subagents** to explore in parallel).
```

Then bump the remaining step numbers of §3 by one (old `2.`→`3.`, `3.`→`4.`, `4.`→`5.`, `5.`→`6.`); the
`(§6)` reference inside them is a top-level cross-ref and stays unchanged. In the `SPEC.md` description (the
step that now reads `Write **`SPEC.md`** (problem, requirements, constraints, acceptance)`), change that
parenthetical to `(problem, requirements, constraints, acceptance, **and a Product necessity section: the persona's verdict + the `PRODUCT.md` priority it serves**)`.

- [ ] **Step 4: Add the Necessity row to the completion report (§4)**

In `## 4. Completion report`, insert this row **immediately after** the `'Issue|#<N> - <one-line what was asked>',` line in the `format-report.ps1 -Rows` list:

```
  'Necessity|<persona> · <necessary|borderline|not-necessary> (<confidence>) - <one-line product rationale>',
```

And append this sentence to that section's intro paragraph (after "...never hidden."):

```
On a stage-one HALT, the report's shape changes: `Status` = `⛔ halted — not necessary (recommend closing #<N>)`, `PR` = `none`, and the `Necessity` row carries the reasoning.
```

- [ ] **Step 5: Verify the edits landed and top-level numbering is UNCHANGED**

Run:
```powershell
Select-String -Path .\WORKTREE.md -Pattern '^## \d+\.|^### 6a\.' | ForEach-Object { $_.Line }
```
Expected: top-level headers still `## 1.` through `## 11.` (unchanged), plus a new `### 6a. Product-necessity reviewers ...`. Then:
```powershell
Select-String -Path .\WORKTREE.md -Pattern 'product-necessity gate|hub-product-owner|Necessity\|'
```
Expected: matches in §2, §3, §6a, and the completion report. Spot-read §2, §3, and §6a for coherence.

- [ ] **Step 6: Commit**

```powershell
git add WORKTREE.md
git commit -m "feat(worktree): add mandatory stage-one product-necessity gate" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `CLAUDE.md` — orchestrator routing, seed prompts, refinement loop

Tell the orchestrator how to route a persona when seeding, add the stage-one line to both canonical seed prompts, and extend the improvement loop to cover the product personas.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the routing subsection**

In the `### Seeding the agent's task prompt — two tracks` area, **after** the paragraph that begins `**Seed-prompt standards (BOTH tracks — always include).**` (ends `...never "short".`), insert:

```markdown
**Product-necessity gate (stage one) — pick the persona to route.** Every solver runs the stage-one
product-necessity gate in `WORKTREE.md` (§6a) before coding. When seeding, name the routed persona in the
prompt (default `hub-product-owner`), chosen from the item's labels/area:

| Issue is about… | Route to |
|---|---|
| UX, a11y, error messages, user-facing behavior/copy, onboarding | `hub-product-user` |
| feature scope, priority, roadmap fit, "should we even build this" | `hub-product-owner` (default) |
| perf, refactor, tech-debt, deps, observability, tests, internal tooling | `hub-product-maintenance` |

The persona's "Also consult" line lets it pull in a sibling lens; one persona per item is the default.
User-origin issues are confirmed/right-sized, never auto-halted (the user's request outranks the persona).
```

- [ ] **Step 2: Add the stage-one line to the simple canonical prompt**

In the `canonical autonomous (simple-track) solver prompt` code block, insert a line **immediately before** the `Issue-specific steer: <issue-specific guidance>` line:

```
Stage one (before any code): run the stage-one product-necessity gate in WORKTREE.md — consult <ROUTED PERSONA, default hub-product-owner>, curating the issue + current code + origin + PRODUCT.md, to confirm this is real, necessary, and right-sized. HALT or ask me per that section if it isn't.
```

- [ ] **Step 3: Add the stage-one step to the complex canonical prompt**

In the `canonical complex seed prompt`, insert this new bullet **immediately before** its `1. RESEARCH the relevant code ...` line:

```
0. STAGE ONE — product-necessity gate (WORKTREE.md §6a): before researching the build, consult <ROUTED PERSONA, default hub-product-owner> (curate issue + current code + origin + PRODUCT.md) to confirm the work is necessary. If not necessary, HALT/ask me and record the consult — do not design a fix for work that isn't worth doing.
```

And in its `2. Write SPEC.md ... and PLAN.md ...` step, extend the `SPEC.md` parenthetical to read `(problem, requirements, constraints, acceptance, and a Product necessity section: the persona's verdict + the PRODUCT.md priority it serves)`.

- [ ] **Step 4: Extend the improvement loop**

Find the sentence in the merge-sweep / improvement-loop area ending `...use it to sharpen the `.claude\agents\hub-*.md` expert prompts.` and append:

```
This includes the `hub-product-*` reviewer personas: filter to `area='product-necessity'` consults and treat `followed='overridden'` necessity calls (you kept what a persona called unnecessary, or vice-versa) as the signal to sharpen the personas or `PRODUCT.md`.
```

- [ ] **Step 5: Verify the edits landed**

Run:
```powershell
Select-String -Path .\CLAUDE.md -Pattern 'product-necessity gate|hub-product-owner|hub-product-user|hub-product-maintenance' | Measure-Object | ForEach-Object Count
```
Expected: a count of **5 or more** (routing table rows + the two prompt lines + the improvement loop). Spot-read each insertion in context.

- [ ] **Step 6: Commit**

```powershell
git add CLAUDE.md
git commit -m "docs(hub): route product-necessity personas in seed prompts + improvement loop" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full verification, spec-coverage check, and PR

- [ ] **Step 1: Run the full Pester suite**

Run:
```powershell
Import-Module C:\mydev\pester-modules\Pester\5.7.1\Pester.psd1 -Force
Invoke-Pester -Path . -Output Detailed
```
Expected: PASS — all suites green (new `hub-product-agents.Tests.ps1` + the appended `review-coverage.Tests.ps1` blocks + all pre-existing tests). Fix any regression before proceeding.

- [ ] **Step 2: Spec-coverage check**

Re-read `docs/superpowers/specs/2026-06-29-product-aware-reviewers-design.md` and confirm each unit maps to a task: personas (Task 1) · provisioning-no-change + glob assertion (Task 1 test) · stage-one gate + completion report (Task 3) · routing (Task 4) · recording reuse (Task 2 + the §6a record command in Task 3) · refinement loop (Task 4). Note any gap and add a task for it.

- [ ] **Step 3: Push and open the PR**

```powershell
git push -u origin feature/product-aware-reviewers
gh pr create --base main --title "feat: product-aware reviewers (worktree stage-one necessity gate)" --body "Implements docs/superpowers/specs/2026-06-29-product-aware-reviewers-design.md: three hub-product-* reviewer personas + a mandatory stage-one product-necessity gate in WORKTREE.md, recorded via the existing consult ledger (area=product-necessity) and a halted-unnecessary status. No schema change.

## Design decisions
- Reviewer does it all (legitimacy + necessity + scope) at worktree stage one; the worktree curates code evidence (works around the worktree-subagent file-resolution bug).
- Auto-HALT only on high-confidence not-necessary; borderline gates to the human; user-origin issues are never auto-halted.
- Recording + refinement reuse the consult channel; no new tables.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
Expected: PR created against `main`. Do **not** merge — leave it for the user's review.

---

## Notes / out of scope (do not implement)

- **No `review-coverage.ps1` change.** `monitor`'s `ORDER BY` puts `halted-unnecessary` in the default
  bucket; promoting it in the sort is a deferred nicety, not in scope (the spec keeps the script untouched).
- **No structured `necessity` column** in v1 — the free-text `advice` + `area='product-necessity'` +
  `followed` are enough for the refinement query (spec "Open questions").
- **No fan-out pre-screen.** Necessity lives only at worktree stage one (spec decision).
