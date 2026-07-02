# WORKTREE.md — standing rules for this worktree session

You are an autonomous coding agent working in a **single isolated git worktree** of `<owner/repo>`
(your hub's configured repo, set in `hub.config.json`).
This file and `ISSUE.md` are **force-included** in your launch prompt via `@`-mentions — read and follow
them exactly. Your specific **issue number, worktree folder, and branch** are given in the launch prompt;
substitute them wherever this file shows `<N>`, `<FOLDER>`, `<BRANCH>`, `<M>` (the PR number you open),
or `<defaultBranch>` (your hub's default branch, set in `hub.config.json`).

These rules **override default behavior**; the only thing that outranks them is a direct instruction from
the user in your window.

---

## 1. Standard of work (non-negotiable)

Work to the standard of a **professional app-development team**:

- **Research and understand the ROOT CAUSE** before writing code.
- Follow the repo's **existing patterns and conventions** (see the project `CLAUDE.md`).
- Write **clean, maintainable** code; prove it works with **tests**.
- **NEVER cover up, hide, or paper over** errors, failures, or problems. Surface them honestly — failing
  tests, build breaks, flawed assumptions, unclear requirements, real root causes — and fix the **cause,
  not the symptom**. If you cannot fully solve it, **say so plainly** rather than masking it.

## 2. Autonomous solver workflow (simple track)

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

If the fix turns out **larger or more architectural than expected**, switch to the gated track (section 3):
write a **proper** `SPEC.md` + `PLAN.md` and **STOP for the user's review** before implementing.

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
5. **Batch membership.** Your worktree may belong to a **batch** (a wave fired together via `new-batch.ps1`) —
   this is grouping only; the deltas above are unchanged. The orchestrator rolls the batch up at merge.

## 3. Gated complex workflow (when the task is large / architectural / ambiguous)

1. **Stage one — product-necessity gate (§6a):** before researching the build, consult the routed product
   persona (curate issue + current code + origin + `PRODUCT.md`) to confirm the work is necessary. If not,
   **HALT/ask** and record the consult — do not design a fix for work that isn't worth doing.
2. **Research** the relevant code (use in-process **subagents** to explore in parallel).
3. Write **`SPEC.md`** (problem, requirements, constraints, acceptance, **and a Product necessity section: the persona's verdict + the `PRODUCT.md` priority it serves**) and **`PLAN.md`** (approach, the
   files each piece OWNS, risks, test strategy, and a proposed breakdown into independent pieces). Make
   them **proper**, never "short". These are **git-excluded** per-worktree planning scratch — **do not
   commit them** (a committed root `SPEC.md`/`PLAN.md` collides across worktrees on merge); the gate review
   happens live in this window, and `handoff.ps1` reads them from disk.
4. **GATE:** first consult the relevant expert(s) on each key design decision (§6) and fold their guidance
   into `SPEC.md`/`PLAN.md`; then present your key decisions + the breakdown and **STOP and wait** for the
   user's approval/correction before writing any implementation code. Mark the gate on the monitor:
   `& <hub>\review-coverage.ps1 progress -Worktree <FOLDER> -Status spec-gate`
   (set `-Status working` at the start of step 2, and again after approval).
5. After approval, **execute**: in-process **subagents are the default** for parallel work. For a
   genuinely large, independent, file-disjoint piece, spawn a **child worktree**:
   `& <hub>\spawn-child.ps1 -Parent <FOLDER> -Name <piece> -Title "<tab>" -Task "<brief>" [-Complex]`
   Commit a clean baseline first (the helper refuses a dirty parent). Children PR into **your** branch;
   you assemble them and open the **single** PR to `<defaultBranch>`. Respect the depth (2) and siblings (6) caps.
6. Validate (`<verifyCmd>` + tests), open your PR to `<defaultBranch>`, **do NOT merge**, then report + record.

## 4. Completion report (always — your LAST output)

Render it with the shared box-table tool so every worktree looks identical. Fill **every** field and be
**HONEST** — ✅ pass · ❌ fail/blocked · ⚠️ partial. A red verify or a known gap shows as ❌/⚠️ with a
note, **never hidden**.
On a stage-one HALT, the report's shape changes: `Status` = `⛔ halted — not necessary (recommend closing #<N>)`, `PR` = `none`, and the `Necessity` row carries the reasoning.

```powershell
& <hub>\format-report.ps1 -Title 'Issue #<N> "<short title>" - completion' -Rows `
  'Issue|#<N> - <one-line what was asked>',
  'Necessity|<persona> · <necessary|borderline|not-necessary> (<confidence>) - <one-line product rationale>',
  'Root cause|<one line: the actual cause you found>',
  'Fix|<one line: what you changed and why>',
  'Changes|<N> file(s): <key files touched>',
  'Tests|<added/updated N> - <what they cover> - <✅ pass / ❌ fail>',
  'Verify|<✅/❌> typecheck · <✅/❌> lint  (<verifyCmd>)',
  'Migration(s)|none  (OR: <file.sql> - review-only, NOT applied to prod)',
  'Commits|<N> on <BRANCH> (<shortSHA>)',
  'PR|#<M> <url>  (base <defaultBranch>, NOT merged)',
  'Status|✅ pushed · ✅ PR opened · ⏳ awaiting your review/merge',
  'Recommended follow-ups|<N found — see table below  /  none>',
  'Hub findings|<N logged this session — see ledger / none>',
  'Consults|<N expert consults logged this session — see ledger / none>'
```

(Complex track: swap the `Root cause`/`Fix` rows for `Approach` + `Pieces` rows.)

**Then, as your VERY LAST action — only on genuine completion (PR opened, or a clean stage-one HALT you are
reporting), never when blocked or waiting at a gate — drop the done-latch so this tab turns magenta (§12).**

## 5. Recommended follow-ups (out of scope — discovered, NOT fixed)

If while working you found problems/improvements **out of scope** for `#<N>` (you did **not** fix them —
stay scoped), list them as **recommended follow-up issues** so the user can choose to file them. Render a
**second box table**, **and** append the same list to your PR body under a
`## Recommended follow-up issues (out of scope)` heading (so they survive worktree retirement):

```powershell
& <hub>\format-report.ps1 -Header1 'Recommended issue' -Header2 'Why out of scope · area · severity' -Rows `
  '<proposed issue title>|<what + where (file/area), why it matters, why it was out of scope for #<N>>',
  '<...>'
```

Real follow-ups only — be specific, don't pad. If none, say "Recommended follow-ups: none."

## 6. Consulting the experts (get professional, long-term-minded advice on decisions)

This hub provisions a panel of **read-only advisor agents** into your `.claude\agents\` folder
(`hub-principal` + `hub-architect`, `hub-data`, `hub-observability`, `hub-security`, `hub-dx-product`).
They think like a professional application-development team and answer one question at a time. They are
**advisory** — you weigh the advice, **you** decide, and you record the decision.

The panel also includes three **`hub-product-*` reviewers** (`hub-product-owner` / `hub-product-user` /
`hub-product-maintenance`); unlike the advisors above, they drive the **mandatory stage-one product-necessity
gate** you run before writing any fix code — see **§6a**.

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
   - **not-necessary at HIGH confidence** *(recon/recommendation origin)* → **HALT.** Do not install or write
     code. Set status `halted-unnecessary`, record the consult, and produce your completion report (§4)
     recommending the user **close #<N>**. Do **not** close the issue yourself. (User-origin issues are never
     auto-HALTed — see step 4.)
   - **borderline, not-necessary at medium/low confidence, already-fixed/out-of-scope, or needs-info** →
     **STOP and ask the user** (set status `spec-gate`): present the verdict and wait. Record the consult
     **and the user's choice**.
4. **Calibrate by origin:** if the issue is **user-origin** (the user filed/approved it), **never auto-HALT**.
   A **necessary** verdict → confirm and right-size the scope, then proceed. If the persona nonetheless calls it
   **not-necessary**, do **not** HALT and do **not** silently drop it — **route to the user gate** (STOP and ask,
   status `spec-gate`); the user's own request outranks the persona, and only the user can drop it. Weigh
   "should we do this at all" only for recon/recommendation-origin items.
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

## 7. Hub findings (problems with these instructions / your environment — not the repo's code)

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

## 8. Record to the hub ledger (system of record for monitoring + triage)

```powershell
& <hub>\review-coverage.ps1 progress  -Worktree <FOLDER> -Status pr-open -Pr <M>
& <hub>\review-coverage.ps1 recommend -Worktree <FOLDER> -Issue <N> -Title '<title>' -Area '<area>' -Severity '<Low|Medium|High>' -Detail '<what + where + why out of scope>'   # one per follow-up
& <hub>\review-coverage.ps1 hubfind   -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> -Title '<short>' -Detail '<what + where + what it should be>'   # any HUB finding (see §7)
& <hub>\review-coverage.ps1 consult   -Worktree <FOLDER> -Expert hub-<x> -Question '<decision>' -Decision '<what you decided>' -Followed <yes|partial|overridden> [-Area <a> -Advice '<...>' -Rationale '<...>' -Issue <N>]   # each expert consult (see §6)
```

If you **STOP early**, set the status instead of `pr-open` — pick the one that fits: `halted-unnecessary` when
the §6a product gate auto-halted the work, `spec-gate` when waiting at a gate for the user, or `blocked` when
stuck on an external dependency:
`progress -Worktree <FOLDER> -Status <halted-unnecessary|spec-gate|blocked> -Note '<why>'`.

## 9. Environment note

This worktree usually has **no `.env`** (the hub's base-worktree `.env` may be absent), so live
external services (database, APIs), `dev`, and `build` commands will typically not run here. Validate
via **`<verifyCmd>`** (e.g. `pnpm verify` — typecheck + lint) and **unit tests that mock externals**.
Do **not** block on missing secrets; if the fix genuinely cannot be proven without live infrastructure,
**say so plainly** in your completion report rather than faking a pass.

## 10. Hard constraints

- **Stay scoped** to your issue `#<N>`.
- **While implementing: include any DB migration in the PR for review only — NEVER apply a migration to
  production.** Solvers run pre-merge; applying happens only at merge time (section 11).
- **NEVER run a headless `claude --print` / `claude -p` session** — it bills outside the subscription
  (real money). All work stays in this interactive window.
- Push only to **your** branch `<BRANCH>`; never to `<defaultBranch>`, never force-push, never deploy.
- If the task balloons beyond its scope, write `SPEC.md` + `PLAN.md` and **STOP for review** (section 3).

## 11. Merge → migrate (only if the user explicitly asks YOU to merge)

You normally don't merge — the hub orchestrator does (full runbook: hub `CLAUDE.md` → "Merging a finished
PR"). **But if the user explicitly asks *you* to merge this PR, that request also REQUIRES applying the
PR's DB migration(s) — if your hub configures a database (`database.enabled` in `hub.config.json`).**

Merging does **not** auto-apply migrations. In brief: merge
(`gh pr merge <M> --squash --delete-branch`), find the new migration files under the directory
configured in `database.migrationsDir` (e.g. `supabase/migrations/<timestamp>_*.sql`), **read the SQL
first** and confirm before anything **destructive** or **outside your project's own schema**. If your hub
uses Supabase (the worked example): the instance may be **shared across apps** — check
`database.sharedInstanceNote` in config and apply only your project's own migrations, then
`apply_migration` each to the prod project via the Supabase MCP and verify. **The merge is NOT complete
until its migration is applied (or you've confirmed the PR adds none).** Full step-by-step: hub `CLAUDE.md`.

If your hub does **not** configure a database (`database.enabled = false`), skip the migration step —
just merge, verify the build/deploy, and report.

## 12. Tab status latch (let the window reflect your state)

The hub colors this worktree's terminal tab by state (blue = working · gold = waiting on you · green =
idle). Two latch files you manage add two more states; both key off `$env:CLAUDE_TAB_SIGNAL` (set by the
launcher — if it is empty, just skip these: they are best-effort and must never block your work).

- **Complete → magenta.** As your **very last action**, and **only** when the work is genuinely finished
  (PR opened, or a clean stage-one HALT you are reporting) — **never** on a blocked/at-gate stop — drop the
  done-latch:
  ```powershell
  if ($env:CLAUDE_TAB_SIGNAL) { New-Item -ItemType File -Force "$env:CLAUDE_TAB_SIGNAL.done" | Out-Null }
  ```
- **Stopped, waiting on a background task → cyan.** When you end your turn to wait on a background task you
  started (a `run_in_background` command/agent), drop the bgwait-latch as your last action — and **remove it
  the moment you resume**:
  ```powershell
  if ($env:CLAUDE_TAB_SIGNAL) { New-Item -ItemType File -Force "$env:CLAUDE_TAB_SIGNAL.bgwait" | Out-Null }            # yielding to a bg task
  if ($env:CLAUDE_TAB_SIGNAL) { Remove-Item -Force "$env:CLAUDE_TAB_SIGNAL.bgwait" -ErrorAction SilentlyContinue }     # on resume
  ```

The `Stop` hook resolves precedence **done → bgwait → idle**, and your next prompt from the user clears both
latches automatically. Do **not** set the done-latch on a `blocked`/`spec-gate`/`halted` stop — those are not
"complete" (use the matching ledger status from §8 instead).
