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
2. Run `<installCmd>` (e.g. `pnpm install` — fresh worktree has no `node_modules`), then mark yourself
   working on the monitor:
   `& <hub>\review-coverage.ps1 progress -Worktree <FOLDER> -Status working`
3. Investigate the **root cause**, then implement the fix following repo conventions. (Issue-specific
   guidance is in the launch prompt.)
4. Validate with `<verifyCmd>` (e.g. `pnpm verify` — typecheck + lint) and **run/add tests that genuinely
   cover the fix**.
5. Commit, `git push -u origin <BRANCH>`, then open a PR (`gh pr create`, base `<defaultBranch>`). Use a conventional
   title (`fix(#<N>): …` / `feat(#<N>): …`) and put **`Fixes #<N>`** in the PR body so the issue auto-closes
   on merge. **DO NOT merge.**
6. Finish with the **completion report** (section 4) as your **last output**.
7. **Record to the hub ledger** (section 7).

If the fix turns out **larger or more architectural than expected**, switch to the gated track (section 3):
write a **proper** `SPEC.md` + `PLAN.md` and **STOP for the user's review** before implementing.

## 3. Gated complex workflow (when the task is large / architectural / ambiguous)

1. **Research** the relevant code (use in-process **subagents** to explore in parallel).
2. Write **`SPEC.md`** (problem, requirements, constraints, acceptance) and **`PLAN.md`** (approach, the
   files each piece OWNS, risks, test strategy, and a proposed breakdown into independent pieces). Make
   them **proper**, never "short".
3. **GATE:** present your key decisions + the breakdown, then **STOP and wait** for the user's
   approval/correction before writing any implementation code. Mark the gate on the monitor:
   `& <hub>\review-coverage.ps1 progress -Worktree <FOLDER> -Status spec-gate`
   (set `-Status working` at the start of step 1, and again after approval).
4. After approval, **execute**: in-process **subagents are the default** for parallel work. For a
   genuinely large, independent, file-disjoint piece, spawn a **child worktree**:
   `& <hub>\spawn-child.ps1 -Parent <FOLDER> -Name <piece> -Title "<tab>" -Task "<brief>" [-Complex]`
   Commit a clean baseline first (the helper refuses a dirty parent). Children PR into **your** branch;
   you assemble them and open the **single** PR to `<defaultBranch>`. Respect the depth (2) and siblings (6) caps.
5. Validate (`<verifyCmd>` + tests), open your PR to `<defaultBranch>`, **do NOT merge**, then report + record.

## 4. Completion report (always — your LAST output)

Render it with the shared box-table tool so every worktree looks identical. Fill **every** field and be
**HONEST** — ✅ pass · ❌ fail/blocked · ⚠️ partial. A red verify or a known gap shows as ❌/⚠️ with a
note, **never hidden**.

```powershell
& <hub>\format-report.ps1 -Title 'Issue #<N> "<short title>" - completion' -Rows `
  'Issue|#<N> - <one-line what was asked>',
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
  'Hub findings|<N logged this session — see ledger / none>'
```

(Complex track: swap the `Root cause`/`Fix` rows for `Approach` + `Pieces` rows.)

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

```powershell
& <hub>\review-coverage.ps1 progress  -Worktree <FOLDER> -Status pr-open -Pr <M>
& <hub>\review-coverage.ps1 recommend -Worktree <FOLDER> -Issue <N> -Title '<title>' -Area '<area>' -Severity '<Low|Medium|High>' -Detail '<what + where + why out of scope>'   # one per follow-up
& <hub>\review-coverage.ps1 hubfind   -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> -Title '<short>' -Detail '<what + where + what it should be>'   # any HUB finding (see §6)
```

If you **STOP early**, set the status instead of `pr-open`:
`progress -Worktree <FOLDER> -Status blocked -Note '<why>'`.

## 8. Environment note

This worktree usually has **no `.env`** (the hub's base-worktree `.env` may be absent), so live
external services (database, APIs), `dev`, and `build` commands will typically not run here. Validate
via **`<verifyCmd>`** (e.g. `pnpm verify` — typecheck + lint) and **unit tests that mock externals**.
Do **not** block on missing secrets; if the fix genuinely cannot be proven without live infrastructure,
**say so plainly** in your completion report rather than faking a pass.

## 9. Hard constraints

- **Stay scoped** to your issue `#<N>`.
- **While implementing: include any DB migration in the PR for review only — NEVER apply a migration to
  production.** Solvers run pre-merge; applying happens only at merge time (section 10).
- **NEVER run a headless `claude --print` / `claude -p` session** — it bills outside the subscription
  (real money). All work stays in this interactive window.
- Push only to **your** branch `<BRANCH>`; never to `<defaultBranch>`, never force-push, never deploy.
- If the task balloons beyond its scope, write `SPEC.md` + `PLAN.md` and **STOP for review** (section 3).

## 10. Merge → migrate (only if the user explicitly asks YOU to merge)

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
