# claude-worktree-hub — Multi-Agent Worktree Hub

> **New here? See `README.md`, then run `.\init-hub.ps1`.**

> **This directory (the hub root) is an orchestration HUB, not a working copy.**
> It holds a colocated **bare** git repository plus one isolated worktree per task.
> Each worktree is meant to host its own independent Claude Code session so multiple
> agents can work the repo (configured in `hub.config.json`) in parallel without colliding on files,
> hot-reloads, or git locks.
>
> **Do not run app/build/test commands or edit source from the hub root.** The hub root
> has no working tree — `git status` here will error (`this operation must be run in a
> work tree`). That is expected. All real work happens inside a worktree subfolder
> (`main\`, `agent-*\`, …), each of which has its own project-level `CLAUDE.md`.

## Repository

All repo-specific values come from `hub.config.json` (git-ignored; copied from `hub.config.example.json` during `.\init-hub.ps1`).

| | |
|---|---|
| GitHub | `<owner/repo>` (from `hub.config.json` → `repo`) |
| Clone URL | `<cloneUrl>` (from config) |
| Default branch | `<defaultBranch>` (from config; default `main`) |
| Stack | your project's stack |
| Package manager | `<packageManager>` (from config; default `pnpm`) |
| Auth | git uses the `gh` CLI credential helper. Set up via `gh auth setup-git`. |

## Directory structure

```text
<hub root>\                  <- the hub (bare repo + worktrees live here)
├── .bare\                   <- the actual git repository data (bare clone)
├── .git                     <- pointer file: contains "gitdir: ./.bare"
├── .launchers\              <- generated per-worktree window launchers (re-runnable)
├── .issue-images\           <- issue screenshots downloaded with gh auth (untracked)
├── .review\                 <- coverage.db (SQLite ledger: topics, findings, activity; untracked)
├── CLAUDE.md                <- this file (hub orchestration doc + registry)
├── WORKTREE.md              <- canonical STANDING RULES copied into every worktree + @-mentioned in its seed prompt
├── hub.config.example.json  <- config template (tracked); copy to hub.config.json and edit
├── hub.config.json          <- your config (git-ignored); loaded by hub-config.ps1
├── hub-config.ps1           <- config loader: sets $Hub + $HubConfig, exposes Get-LaunchFlags
├── claude-launch.ps1        <- bundled session wrapper (delegates to personal tab-color hook if present)
├── init-hub.ps1             <- bootstrap: bare clone + .git pointer + base worktree + config gen
├── new-worktree.ps1         <- helper: provision a worktree (use -Issue <N> for issue work)
├── remove-worktree.ps1      <- helper: tear a worktree down (worktree + branch only; leaves window + folder)
├── retire-worktree.ps1      <- helper: FULLY retire finished worktree(s) (kill terminal + remove + rm -rf + branch + prune)
├── cleanup-worktree-processes.ps1 <- helper: COMPLETE sweep of processes left by CLOSED worktrees (dry-run default; -Execute)
├── format-report.ps1        <- helper: render the completion / merge report as an aligned Unicode box table
├── fetch-issue-images.ps1   <- helper: download a private issue's images for an agent to Read
├── spawn-child.ps1          <- helper: a complex worktree creates + launches a CHILD worktree (depth-capped)
├── handoff.ps1              <- helper: after the gate, hand a planner off to a FRESH executor session (resets context)
├── new-recon.ps1            <- helper: create + launch a READ-ONLY recon (discovery) worktree (proposes/files issues)
├── launch-recon-fleet.ps1   <- helper: launch a FLEET of recon worktrees (one per surface) for a token burst
├── review-coverage.ps1      <- helper: SQLite coverage ledger (topics/findings/activity) + scheduler
├── ledger-to-html.ps1       <- helper: render the OPEN ledger items (issues/findings/recs/worktrees) to ONE self-contained HTML dashboard + open in Chrome
├── hub-lib.ps1              <- shared functions for the helpers (issue bundle, slug, images)
├── main\                    <- base worktree, tracks the default branch
├── agent-*\                 <- one isolated worktree per parallel task (created on demand)
├── issue-<N>-*\             <- issue worktree; also contains ISSUE.md + issue-assets\ (git-excluded)
├── recon-<surface>\         <- read-only recon (discovery) worktree; proposes issues, files on approval
└── <parent>--<piece>\       <- child worktree spawned by a complex parent (branch off parent)
```

How the plumbing works: the bare repo in `.bare\` stores all history. The `.git`
**file** (not a folder) at the hub root redirects any git command run from the hub to
`.bare\`. Each worktree folder has its own `.git` file pointing at
`.bare\worktrees\<name>`. The fetch refspec is configured normally
(`+refs/heads/*:refs/remotes/origin/*`) so `git fetch` / `git pull` behave like a
regular clone from inside any worktree.

## Worktree types

The pipeline: **recon/user files issue → `issue sync` → `issue review` (auto-scope) → you approve → `issue
next` (non-overlapping wave) → solver (issue → PR) → verify → gate → merge → migrate.** Human checkpoints at
issue-approval and merge; autonomous burn in between. **Every issue — recon-found OR user-filed — must be
ledger-`approved` before it gets a worktree** (the gate is enforced in `new-worktree.ps1`; see
[Issue lane](#issue-lane-github-issue--ledger--review--overlap-aware-deploy)).

- **Solver** (`issue-<N>-*`, `agent-*`) — picks up a GitHub issue or task and implements it → PR. Simple
  ones are autonomous; complex ones use the gated workflow. Created by `new-worktree.ps1`.
- **Recon / discovery** (`recon-<surface>`) — **read-only**. Deeply reviews ONE *surface* and PROPOSES
  GitHub issues; it changes no code and opens no PRs. Created by `new-recon.ps1 -Surface <surface>`; it
  gates with a `candidate-issues.md` list and files only the ones you approve (label `needs-triage,recon`).
  Surfaces: `app`, `module:<path>`, `database`, `logs`, `platform`, `security`, `performance`, `a11y`,
  `deps`, `tests`. **Token burst:** `launch-recon-fleet.ps1 -Surfaces a,b,c,…` spins up one deep recon
  (each `--effort max` + subagent fan-out) per surface at once — spend = fleet width × subagent depth.
- **Review** (`review-*`) — produces a findings *document* PR (a written audit) rather than a backlog of
  issues. Use when you want a report.

**Why recon is read-only (hard lesson):** discovery agents allowed to remediate will flood unreviewed
PRs — it happened in practice when "read-only" review agents opened ~9 DB/security PRs of their own. Recon
writes only to the coverage **ledger** (below) — never app code, branches, PRs, or even GitHub issues —
so *finding* problems never silently turns into *changing* code.

## Continuous review coverage (SQLite ledger)

`review-coverage.ps1` keeps a hub-local SQLite DB (`.review\coverage.db`) that turns recon from ad-hoc
bursts into a managed, **continuous** coverage program — and doubles as the **all-worktree activity
view** (worktrees log their lifecycle there, which is how you "see" what every session is doing without
reading its window).

Tables: **inventory** (modules/resources/surfaces, scanned from the repo) · **topic** (a coverage cell =
subject × lens, with priority + cadence + last_run) · **run** (history) · **finding** (what recon reviewers
record — staged candidate issues; lifecycle **proposed → verified → filed → completed**, carrying
`verdict`/`confidence`/`scope`/`fixed_by`/`verify_notes`/`orig_severity` + `created_at`/`verified_at`/`completed_at`
dates and a `github_issue` link) · **finding_link** (related/dependency edges between findings: `related` /
`duplicate-of` / `depends-on` / `blocks`) · **activity** (lifecycle event feed from every worktree) · **worktree**
(ONE row per worktree, status updated as it progresses = the live monitor) · **recommendation** (out-of-scope
follow-ups a SOLVER found while fixing its issue: proposed → filed as a GH issue / dismissed; same verify fields).

**Monitoring every worktree:** the orchestrator `register`s each worktree at launch; the agent reports
`progress` (working → spec-gate → pr-open, or blocked) and `recommend`s any out-of-scope issues it found; then
`review-coverage.ps1 monitor` is the one-screen view of who's working / waiting / done plus the pending
follow-up backlog — so you watch all worktrees without reading their windows.

The loop: **`run` picks the due topics (priority × staleness) → launches recon → recon writes findings +
activity to the ledger → `verify` each finding (still-valid / already-fixed / out-of-scope; recalibrate
severity + scope; link related/dependent findings) → you triage the verified-still-valid → `promote` files
approved findings as GitHub issues → solver worktrees fix them → `resolve` stamps completion at merge.**
No per-window gate; the human checkpoint is one triage view over the DB. **Always `verify` before `promote`** —
verification reads the *current* code + merged PRs, so it catches findings already fixed or out of scope
before they become noise in the issue tracker. Verification is itself a read-only
fan-out (one subagent per finding); it writes only verdicts/links to the ledger, never code or GitHub.

```powershell
.\review-coverage.ps1 init ; .\review-coverage.ps1 seed     # one-time: schema + scan repo -> topics
.\review-coverage.ps1 due  -N 8                              # what's due now (priority x staleness)
.\review-coverage.ps1 run  -N 3                              # launch recon for the top-3 due topics
.\review-coverage.ps1 report                                 # coverage %, oldest unreviewed, by area
.\review-coverage.ps1 status                                 # recent activity across ALL worktrees
.\review-coverage.ps1 findings -Unverified                   # the verify QUEUE (proposed findings not yet verified)
.\review-coverage.ps1 verify -Id 81 -Verdict still-valid -Severity High -Scope '<files+effort>' -Note '<evidence>' [-Related '93' -DependsOn '..' -FixedBy 'PR #N' -Confidence high -Dismiss]
.\review-coverage.ps1 findings ; .\review-coverage.ps1 promote -Id 5   # recon triage (verified) -> file as a GH issue
.\review-coverage.ps1 resolve -Id 81 -Issue 701              # stamp completed_at + status=completed when the fix merges
.\review-coverage.ps1 monitor                                # live status of EVERY worktree + pending follow-ups
.\ledger-to-html.ps1                                         # render ALL open items -> ONE self-contained HTML dashboard + open in Chrome (-NoOpen to just write it)
.\review-coverage.ps1 recommendations ; .\review-coverage.ps1 file-rec -Id 3   # solver follow-up triage -> GH issue
# --- issue lane (ALL GH issues -> ledger -> review -> approve -> overlap-aware deploy) ---
.\review-coverage.ps1 issue sync                             # pull every OPEN GH issue into the ledger (origin: user|recon|recommendation)
.\review-coverage.ps1 issue unreviewed                       # the review QUEUE (synced, not yet reviewed) -> drives the fan-out
.\review-coverage.ps1 issue record-review -Id 42 -Targets 'src/lib/page-queries.ts' -Severity Medium -Track simple -Verdict still-valid [-Reads '..' -Effort M -Note '..' -Related '7' -DependsOn '..']
.\review-coverage.ps1 issue list [-Status reviewed]          # triage table: origin, sev, track, #owned-paths, overlap count
.\review-coverage.ps1 issue show -Id 7                       # full review detail: owned/read paths + overlapping issues + links
.\review-coverage.ps1 issue approve -Id 42                   # human checkpoint: reviewed -> approved (clears the worktree gate)
.\review-coverage.ps1 issue next -N 8                        # the OVERLAP-AWARE selector: highest-priority approved wave, file-disjoint
```
Worktree-facing (recon agents call): `activity -Worktree w -WType recon -Event started`,
`finding -Worktree w -Topic t -Title … -Severity … …`, `complete -Topic t -Worktree w`.
Solver/orchestrator-facing (worktree monitoring): orchestrator `register -Worktree w -WType solver -Issue N
-Branch b` at launch; solver `progress -Worktree w -Status <working|spec-gate|pr-open|blocked|…> [-Pr M]` and
`recommend -Worktree w -Issue N -Title … [-Area … -Severity … -Detail …]`; orchestrator `progress -Status
merged` then `retired` at merge, and `file-rec -Id n` / `dismiss-rec -Id n` to triage the recommendations.

**Continuous cadence:** a scheduled task firing `.\review-coverage.ps1 run -N k` at a regular rate = rolling
coverage where the riskiest/stalest cells are always reviewed first; recon auto-records to the ledger, so
nothing piles up at a window and you triage async.

### Issue lane: GitHub issue → ledger → review → overlap-aware deploy

Recon findings are not the only source of work — issues also arrive **directly** (you file them) or as
**solver follow-ups** (`file-rec`). To make the ledger the **complete backlog of record** and turn the
"will these worktrees collide?" question into a *query* (instead of an ad-hoc subagent analysis every wave),
every open GitHub issue flows through the same review discipline before it earns a worktree:

1. **`issue sync`** — upserts every open GH issue into the `issue` table (caches number/title/labels/author,
   derives `origin` = user | recon | recommendation, back-links a finding/rec it came from, carries that
   severity as a hint). Closed issues are marked `closed`.
2. **Review fan-out (orchestrator-driven)** — `issue unreviewed` is the queue; the **orchestrator dispatches
   one read-only subagent per unreviewed issue** (NEVER a headless `claude` — Critical rule #7; these are
   in-session `Agent` subagents, subscription-covered, exactly how a batch's scope is mapped). Each reads the
   issue + codebase and calls **`issue record-review -Id N -Targets '<owned files>' -Severity .. -Track
   simple|complex -Verdict still-valid [-Reads .. -Related .. -DependsOn ..]`**, which records **structured
   owned/read paths** in `issue_target`, the review fields, and overlap edges in `issue_link`, setting
   `review_status='reviewed'`. Subagents write ONLY to the ledger (no code, no GitHub, no PRs).
3. **You approve** — `issue list -Status reviewed` → `issue approve -Id N` (or `issue dismiss`). This is the
   **human checkpoint**; `approved` is what the worktree gate requires.
4. **`issue next -N k`** — the **overlap-aware selector**: from `approved` issues (user-origin first, then by
   severity), greedily pick the highest-priority wave whose **owned paths don't collide** with an
   already-picked issue OR any **active** worktree's owned paths (active worktree paths come from
   `worktree.issue → issue_target`). It prints the wave + a "deferred (overlap → file)" list. Selector only —
   you then provision with `new-worktree.ps1` / the batch driver.

**The hard gate:** `new-worktree.ps1 -Issue N` refuses to provision unless `issue.review_status='approved'`,
printing the remediation commands; `-SkipReview` overrides (emergencies only). `monitor` shows each active
worktree's owned-path count so file ownership across in-flight work is visible at a glance. The recon
`finding → verify → promote` path still feeds in — a promoted finding becomes a `synced` issue with its
scope/severity carried over. Design doc: `.review\design-issue-ledger-pipeline.md`.

**Overlap semantics:** two issues *conflict* when both **own** the same path (blocks co-scheduling);
different files in the same directory is a *soft* note (shown, non-blocking) — the judgement call stays yours.

---

## Provisioning a new agent worktree

**Always run worktree management from the hub root**, so paths resolve correctly. The helper script does
this for you and also copies env files and (optionally) installs dependencies — the two steps that are easy
to forget because worktrees are physically separate folders.

### Preferred: the helper script

> **Review gate:** `new-worktree.ps1 -Issue N` refuses to provision unless the issue is
> **`review_status='approved'`** in the ledger (run `issue sync` → review fan-out → `issue approve` first;
> see [Issue lane](#issue-lane-github-issue--ledger--review--overlap-aware-deploy)). Bypass with `-SkipReview`
> only in emergencies. Non-issue worktrees (`-Name` only) are unaffected.

```powershell
# Work a GitHub issue (PREFERRED for issues): auto-names the worktree + branch from the
# issue title AND drops the issue's full resources into the worktree (ISSUE.md = text +
# comments + metadata; issue-assets\ = screenshots downloaded with gh auth):
.\new-worktree.ps1 -Issue 42 -Install        # requires the issue to be ledger-approved (gate)

# New task on a brand-new branch (branches off latest origin/<defaultBranch>), copy env, install deps:
.\new-worktree.ps1 -Name agent-my-task -Install

# New branch off a specific base:
.\new-worktree.ps1 -Name agent-my-fix -Branch fix/my-fix -BaseBranch main -Install

# Check OUT an existing remote branch into a worktree instead of creating one:
.\new-worktree.ps1 -Name wt-my-branch -Branch my-feature-branch -Existing -Install
```

`-Name` is the folder name (and, for new branches, the default branch suffix). The
script fetches origin, creates/checks out the branch, copies env files from the base worktree if
present (files listed in `hub.config.json` → `envFiles`), and runs `<installCmd>` (e.g. `pnpm install`)
when `-Install` is passed. It prints the next step.

### Issue worktrees (the issue's full resources come with it)

Pass `-Issue <N>` (or just name the worktree `issue-<N>-…` and the number is auto-detected).
On top of the normal steps, the script writes the issue's complete brief into the worktree:

- **`ISSUE.md`** — title, body, comments, labels, assignees, state, URL, with any image
  links rewritten to local paths.
- **`issue-assets\`** — every screenshot, downloaded **authenticated** via `gh`
  (private-repo attachment URLs 404 on a plain fetch — see Lessons).

Both are git-excluded through `.bare/info/exclude`, so they never get committed in any
worktree. The seed prompt **`@`-mentions `@ISSUE.md`** (alongside `@WORKTREE.md`) so the brief is
**force-included** in the agent's context at launch — the self-contained brief, screenshots included,
with no network/auth steps required (don't rely on the agent choosing to open it).

### Equivalent raw git (if you prefer to do it by hand)

```powershell
# from the hub root
git worktree add -b feature/<task> agent-<task> origin/main   # new branch
git worktree add wt-<branch> <existing-branch>                # existing branch
Copy-Item main\.env agent-<task>\.env -ErrorAction SilentlyContinue
cd agent-<task>; pnpm install   # replace with your installCmd from config
```

### Then launch the agent

Sessions here start through the **bundled launcher** `claude-launch.ps1`, which delegates to a personal
tab-color hook if present (paints the Windows Terminal tab by session state: idle / working / waiting)
and otherwise runs `claude` directly. It takes `[ValueFromRemainingArguments]` and passes all args
straight through. Standard invocation (**auto permission mode** + **max effort** — always use these for
new worktree sessions; configured via `hub.config.json` → `launch.*` and read by `Get-LaunchFlags`):

```powershell
cd <hub root>\agent-<task>
& ..\claude-launch.ps1 --permission-mode auto --effort max
```

**Why `--permission-mode auto` (not `--dangerously-skip-permissions`).** Auto mode runs a classifier
that auto-ALLOWS the routine solver workflow (install declared deps, edit files in project scope, run
tests, push to the session's own feature branch, open the PR the task asked for) while it **soft-denies**
the genuinely dangerous things — production deploys / DB migrations, force-push, pushing to the default
branch, `rm -rf` of pre-existing files, editing `.claude/*` config — and **hard-denies** data exfiltration.
A soft/hard-deny surfaces an approval **prompt in that worktree's window** (the wrapper is interactive), so
the session still runs unattended for normal work but you get real guardrails on the destructive edge —
strictly safer than bypassing every check. Inspect/tune the rules with `claude auto-mode defaults|config`.

Add `--name <label>` and an initial prompt as usual — they forward to `claude`. The generated
`.launchers\*.ps1` already invoke Claude this way. That session is fully isolated to its folder.

**Register it on the monitor.** Right after launching each worktree, add it to the SQLite ledger so
`.\review-coverage.ps1 monitor` tracks it from the start (the session then updates its own status):
```powershell
& .\review-coverage.ps1 register -Worktree <folder> -WType solver -Issue <N> -Branch <branch>
```

### Seeding the agent's task prompt — two tracks

**Simple worktrees** (small, contained fix, clear acceptance — most issue picks): **autonomous**.
Prompt = `@WORKTREE.md` + `@ISSUE.md` (force-included) → `<installCmd>` (e.g. `pnpm install`) → implement per repo conventions →
`<verifyCmd>` (e.g. `pnpm verify`) + tests → commit, push, open a PR (don't merge). No gate.

**Force-include context with `@`-mentions, don't ask the agent to "read" it.** Every solver/child worktree
carries two git-excluded files that `new-worktree.ps1` / `spawn-child.ps1` drop in at creation: **`WORKTREE.md`**
(the canonical standing rules — copied from the hub-root `WORKTREE.md`) and, for issue worktrees, **`ISSUE.md`**
(the full brief). Seed prompts begin with the literal `@`-mentions `@WORKTREE.md` and `@ISSUE.md` so their
contents are **forced into the agent's context** rather than relying on the agent to open them. This keeps the
per-issue prompt **thin** — identity (`#<N>`/`<FOLDER>`/`<BRANCH>`) + issue-specific guidance + "follow
WORKTREE.md" — while all the durable rules live in one editable file. **Edit `<hub root>\WORKTREE.md`**
to change the rules for every future worktree (it covers the quality bar, the workflow, the report + ledger
format, the env note, the hard constraints, and the **merge→migrate** rule).

**Seed-prompt standards (BOTH tracks — always include).** Every solver prompt must hold the agent to the
standard of a **professional app-development team**: research/understand the root cause before writing code,
follow the repo's existing patterns and conventions, write clean maintainable code, and prove it works with
tests + verification. It must **explicitly forbid covering up, hiding, or papering over** errors, failures,
or problems — the agent surfaces them honestly (failing tests, build breaks, flawed assumptions, unclear
requirements, real root causes) and fixes the *cause*, not the symptom; if it can't fully solve it, say so
plainly. When the gate calls for design docs, require a **proper** SPEC.md + PLAN.md (problem, approach,
files, risks, test strategy) — never "short".

The **canonical autonomous (simple-track) solver prompt** — fill `<N>`/`<FOLDER>`/`<BRANCH>` and the
issue-specific guidance:

```text
@WORKTREE.md
@ISSUE.md

You are the autonomous solver for GitHub issue #<N> (repo <owner/repo>).
Worktree: <FOLDER>   Branch: <BRANCH>

WORKTREE.md (above) is your operating manual — follow it. ISSUE.md (above) is your brief.
Where WORKTREE.md shows <FOLDER>/<BRANCH>/<N>/<M>, use this worktree's values (<M> = the PR you open).

Issue-specific steer: <issue-specific guidance>

Begin.
```

**Complex worktrees** (multi-file / architectural / new subsystem / ambiguous or open-ended): use the
**gated workflow** in the next section. Their prompt is **prepended with the `complexPromptPreamble`** from
`hub.config.json` (default `/superpowers:using-superpowers` — requires the superpowers plugin; set to `""` to
omit) and tells the agent to plan-then-gate before building.

```powershell
$prompt = @'
/superpowers:using-superpowers   # or your hub.config.json complexPromptPreamble

You are an autonomous coding agent in a dedicated worktree for <owner/repo>.
Follow the Complex worktree workflow: research -> write SPEC.md + PLAN.md -> present your key
decisions and STOP for my approval -> then implement with subagents (and child worktrees only for
large independent pieces). ...rest of the brief...
'@
```

## Complex worktree workflow (research → spec → plan → gate → execute)

Complex worktrees run three phases; simple ones skip straight to implement → PR.

1. **Discovery** — research the relevant code; write **`SPEC.md`** (problem, requirements,
   constraints, acceptance criteria) and **`PLAN.md`** (approach, files to touch, risks, test
   strategy, and — for big work — a proposed breakdown into pieces).
2. **Gate** — present the key decisions and **STOP for the user to verify or correct** before any
   implementation. Commit `SPEC.md`/`PLAN.md` so they're reviewable; wait in the window for "go" or
   changes. (Auto mode only prompts on *dangerous* actions, and most planning/implementation steps are
   auto-allowed, so this gate is a *behavioral* pause — the prompt must explicitly tell the agent to stop
   and wait here; don't rely on a permission prompt to enforce it.)
3. **Execution** (only after approval) — implement. Use **in-process subagents** for parallel work
   (the default). For genuinely large, **independent**, separately-reviewable pieces, spin up
   **child worktrees** (below).

**Decomposition — subagents first, child worktrees as the exception.** Subagents are cheap and
in-process; reach for a child worktree only when a piece is big and independent enough to deserve its
own branch/session/PR, and only after the user approved the breakdown at the gate.

Child worktrees are created **and launched** with **`spawn-child.ps1`** (run from inside the parent;
the parent passes its own folder name as `-Parent`):

```powershell
& <hub root>\spawn-child.ps1 -Parent <my-folder> -Name <piece> -Title "<tab>" `
    -Task "<the piece's brief / which PLAN.md section>" [-Complex] [-NoLaunch]
```

It branches the child off the **parent's** branch (so the parent integrates it), names it
`<parent>--<piece>`, copies env from the base worktree, writes a launcher, and opens the window (the parent
**auto-launches** children). `-Complex` gives the child the gated workflow too; otherwise the child
is a simple autonomous piece.

**Guardrails (prevent runaway recursion / sprawl):**
- **Depth cap** — `spawn-child.ps1` refuses past `-MaxDepth` (default 2; depth = count of `--` in the
  name). Beyond it, use subagents.
- **Gate first** — only decompose into child worktrees *after* the breakdown was approved.
- **Subagents are the default** — most parallelism should never create a worktree.
- Agent-spawned children appear in `git worktree list` (the source of truth); the registry table is
  best-effort — reconcile from `git worktree list` when in doubt.

**Integration (child → parent → default branch):**
- Each child opens its PR with **base = the parent branch** (`gh pr create --base <parentBranch>`),
  not the default branch. `spawn-child.ps1` pushes the parent branch to origin so that base exists.
- The **parent assembles** — it merges the child PRs into its branch, reconciles, and opens the
  **single PR to the default branch**. Children never PR straight to the default branch.
- **Spawn from a clean parent.** Children branch off the parent's committed *tip*, so the parent must
  commit a baseline first — `spawn-child.ps1` **refuses a dirty parent** (override `-AllowDirtyParent`)
  and pushes the parent branch. Otherwise children build on a stale base.
- **File-disjoint pieces.** `PLAN.md` must assign file ownership per piece so two children don't edit
  the same files (else you get merge conflicts on assembly).

**More guardrails in `spawn-child.ps1`:** a **siblings cap** (`-MaxChildren`, default 6) on top of the
depth cap (prefer subagents past it); and `gc.auto = 0` is set on `.bare` so background gc can't fire
mid-commit across worktrees.

**Tearing down a complex tree:** close the parent **and every child window first** (CWD locks), then
remove the whole subtree — children are discoverable by the `<parent>--*` prefix: `git worktree remove
--force` each → Git Bash `rm -rf <parent>--*` → `git branch -D` the child branches → `git worktree prune`.

### Canonical complex seed prompt (makes the agent a "mini-me" orchestrator)

Use this (fill the placeholders) as the launcher prompt for any complex worktree — it tells the agent
*when* and *how* to decompose, with its own folder as `-Parent`, so it operates like this hub:

```text
/superpowers:using-superpowers   # or your hub.config.json complexPromptPreamble

@WORKTREE.md
@ISSUE.md

You are the lead engineer in a dedicated git worktree for <owner/repo>.
Worktree folder: <FOLDER>      (pass this as -Parent when spawning children)
Branch:          <BRANCH>      (every commit here lands on this branch)
Task: <summary; ISSUE.md is force-included above if this is an issue worktree - drop the @ISSUE.md line if not>

WORKTREE.md (above) is your operating manual — follow it. ISSUE.md (above) is your brief. Where WORKTREE.md
shows <FOLDER>/<BRANCH>/<N>/<M>, use this worktree's values. The steps below are the COMPLEX/gated specifics
on top of WORKTREE.md; the one rule to internalize is **STOP at the gate (step 3) before writing any code**.

Follow the gated COMPLEX workflow:
1. RESEARCH the relevant code (use subagents to explore in parallel).
2. Write SPEC.md (problem, requirements, constraints, acceptance) and PLAN.md (approach, the files
   each piece OWNS, risks, tests, and a proposed breakdown into independent pieces).
3. GATE: present your key decisions + the breakdown, then STOP and wait for my approval/correction
   before writing any implementation code. Mark the gate on the hub monitor so I see you're waiting:
       & <hub root>\review-coverage.ps1 progress -Worktree <FOLDER> -Status spec-gate
   (set -Status working at the start of step 1, and again after I approve.)
4. After approval, EXECUTE:
   - Use in-process SUBAGENTS for parallel work - this is the default.
   - For a genuinely large, independent, file-disjoint piece, create a CHILD worktree (started
     properly for you - wrapper, tab, seeded prompt):
         & <hub root>\spawn-child.ps1 -Parent <FOLDER> -Name <piece> -Title "<tab>" -Task "<brief>" [-Complex]
     Use -Complex only if the piece needs its own design gate; else leave it autonomous. Commit a
     clean baseline BEFORE spawning (the helper refuses a dirty parent and pushes your branch).
   - Children PR into YOUR branch (<BRANCH>); you merge/reconcile them, then open the SINGLE PR to the default branch.
5. Validate with <verifyCmd> (e.g. pnpm verify) + tests; open your PR to the default branch; do NOT merge.
6. FINISH with a COMPLETION REPORT as your LAST output, via the shared box-table tool (same format every
   worktree uses; fill every field honestly - ✅/❌/⚠️):
       & <hub root>\format-report.ps1 -Title 'Issue #<N> "<short title>" - completion' -Rows `
         'Issue|#<N> - <one-line what was asked>',
         'Approach|<one line: the design you gated + built>',
         'Pieces|<subagents / child worktrees used, if any>',
         'Changes|<N> file(s): <key areas touched>',
         'Tests|<added/updated N> - <✅ pass / ❌ fail>',
         'Verify|<✅/❌> typecheck · <✅/❌> lint  (<verifyCmd>)',
         'Migration(s)|none  (OR: <file.sql> - review-only, NOT applied to prod)',
         'PR|#<M> <url>  (base <defaultBranch>, NOT merged)',
         'Status|✅ pushed · ✅ PR opened · ⏳ awaiting your review/merge',
         'Recommended follow-ups|<N found — see table below  /  none>'
   Then list any OUT-OF-SCOPE problems/improvements you found but did NOT fix as RECOMMENDED FOLLOW-UP ISSUES,
   as a SECOND box table, AND append them to your PR body under "## Recommended follow-up issues (out of scope)"
   so the user can choose to file them:
       & <hub root>\format-report.ps1 -Header1 'Recommended issue' -Header2 'Why out of scope · area · severity' -Rows `
         '<proposed title>|<what + where, why it matters, why out of scope for #<N>>', '<...>'
   Real follow-ups only — be specific. If none, say "Recommended follow-ups: none."
7. RECORD TO THE HUB LEDGER (system of record for monitoring + triage):
       & <hub root>\review-coverage.ps1 progress -Worktree <FOLDER> -Status pr-open -Pr <M>
       & <hub root>\review-coverage.ps1 recommend -Worktree <FOLDER> -Issue <N> -Title '<title>' -Area '<area>' -Severity '<Low|Medium|High>' -Detail '<what + where + why>'   (one per follow-up)
Prefer subagents over child worktrees; respect the depth (2) and siblings (6) caps.
NEVER apply a database migration to production, and NEVER run a headless `claude --print` session.
```

### Optional: hand off to a fresh executor session (reset context, cut tokens)

A complex *planning* session accumulates heavy context (research + the gate discussion). After the
gate, the planner can **hand off to a fresh execution session** so implementation starts with an empty
context window (just the committed plan) — resetting context and reducing token usage. Note that
**subagents already keep the executor lean** (they run in their own fresh contexts and return only
summaries); the handoff additionally drops the *planner's* accumulated context.

```powershell
& <hub root>\handoff.ps1 -Worktree <my-folder>     # after the gate, once SPEC.md/PLAN.md are committed
```

`handoff.ps1` requires `SPEC.md` + `PLAN.md` to exist and the worktree to be **clean/committed** (the
executor reads the *committed* plan, so fold the gate corrections in first); it launches a fresh
executor in the same worktree/branch (seeded "read SPEC.md/PLAN.md → implement via subagents → PR"),
then **closes the planner window only after confirming the executor is up** (a detached watcher;
fail-safe — if the executor never starts, the planner is left open). `-NoClose` hands off but keeps the
planner open; `-DryRun` generates the launchers without launching. This is the clean **Phase 1 (plan) →
Phase 2 (execute)** process boundary.

## Listing & removing

```powershell
git worktree list                       # show all active worktrees (run anywhere in the repo)

# PREFERRED for a FINISHED worktree — full Windows-safe teardown (kill terminal + remove + rm -rf + branch + prune):
.\retire-worktree.ps1 -Name issue-<N>-<slug> -VerifyMerged -DeleteBranch
.\retire-worktree.ps1 -Name recon-* -DeleteBranch          # batch; -Name accepts wildcards
.\retire-worktree.ps1 -Name issue-<N>-<slug> -DryRun       # preview what it would kill/remove (changes nothing)

# Partial teardown (worktree + branch ONLY — leaves the terminal window open AND the node_modules folder on disk):
.\remove-worktree.ps1 -Name agent-<task> -DeleteBranch

# raw equivalent:
git worktree remove agent-<task>
git worktree prune                      # clean up stale metadata if a folder was deleted manually
```

**Retiring a finished worktree + its terminal.** Use `retire-worktree.ps1` — it does the full teardown:
- It **kills the worktree's terminal session** (the launcher pwsh window + its `claude.exe` child, matched by
  the folder name in the process command line, always excluding the orchestrator's own PID + parent). Windowed
  sessions are interactive and do NOT auto-close when their work is done, so a finished worktree leaves a
  lingering window that holds a CWD lock and blocks deletion — killing it releases the lock.
- Then `worktree remove --force` → Git Bash `rm -rf` (git's own remove unregisters but leaves the
  `node_modules` folder on disk — see Lessons) → optional branch delete → `prune`.
- **Safety:** refuses a worktree with **uncommitted changes** unless `-Force` (a dirty tree usually means the
  session is still working); never touches the default branch; `-DryRun` previews and changes nothing; `-VerifyMerged`
  requires a **merged PR** first. Prefer `-VerifyMerged`: **squash-merged** PRs show as "ahead" in git
  ancestry, so the PR's GitHub merge status (`gh pr list --head <branch> --state merged`) is the authoritative
  "is it actually merged" check — NOT `git merge-base --is-ancestor`.

Only retire a worktree after its work is committed and pushed (open/merge the PR first); the clean-tree and
`-VerifyMerged` guards enforce this.

**Cleaning up processes left by CLOSED worktrees.** `retire-worktree.ps1` kills a worktree's session as part
of teardown, but it matches processes only by the folder name in the command line — so it can MISS `node`
build/test children (`tsc`/`eslint`/build runners) that don't carry the path, and it never runs at all for a
window you closed by hand. Use **`cleanup-worktree-processes.ps1`** for a guaranteed-complete sweep:

```powershell
.\cleanup-worktree-processes.ps1            # DRY RUN (default): show orphans + stale signal files, change nothing
.\cleanup-worktree-processes.ps1 -Execute   # kill every process bound to a CLOSED worktree (whole tree) + clear stale files
.\cleanup-worktree-processes.ps1 -IncludeStrayNode -Execute   # ALSO reap leaked never-exiting test/dev node (see below)
```

**Never-exiting test/dev node — purely a CLEANUP concern.** Test/dev runners (`vitest`/`jest` watch,
dev servers, nodemon, …) don't self-exit; when an agent leaves one running and its window is closed it
orphans. This is handled ONLY here, by `-IncludeStrayNode` — it reaps a `node` running a known
non-self-exiting runner whose **parent process is dead** and which binds to no open worktree. It does NOT
touch short-lived build workers (`tsc`/`eslint`/verify/typecheck — they finish on their own) or any
live session's dev server (bound while its window is open).

It stays **opt-in (not default)** for one reason: a *stray* node has no worktree fingerprint left, and
this machine may run other Node projects, so a blanket default-kill of "orphaned watcher node" could hit an
unrelated project's dev server. Passing `-IncludeStrayNode` is you asserting "reap the strays" — consistent
with the tool's rule of never killing what it can't prove is ours.

It treats `git worktree list` as the source of truth for what's OPEN, binds each `pwsh`/`claude`/`node` to a
worktree (by launcher path, `Worktree:`/`Set-Location` token, `…\<hub>\<wt>\…` path, OR inheritance from any
ancestor that named one), and kills only those bound to a worktree that is **not open** — killing the whole
descendant tree. It **always protects** the orchestrator (this session + its full ancestor/descendant chain)
and every OPEN worktree's tree, and it **never kills what it can't prove** is a closed-worktree process
(your other interactive `claude` sessions, MCP servers, unrelated `node`) — those are listed under "left
running" for manual review. It also removes stale `~/.claude/hooks/tab-color-signal-<pid>` files for dead PIDs.

---

## Merging a finished PR (merge → migrate)

> **When asked to merge a finished PR, ALSO apply its database migration(s) at that time** (if your
> hub configures a database — see `hub.config.json` → `database.enabled`). Merging does **not**
> auto-apply migrations — the SQL lands in the migrations directory but the schema change never runs on
> the DB. The merge request itself is the authorization to apply (solver agents are told to *never* apply
> migrations because they run pre-merge; application is this merge/migrate step only).

Steps when merging a finished PR:

1. **Merge** the PR (`gh pr merge <N> --squash --delete-branch`, or as the user directs).
2. **Print the MERGE REPORT** — the final step, in the **same box-table format** the worktree used at
   completion, so each issue reads end-to-end. **Every issue's merge ends with this report.** Render it with
   the shared tool, pulling real values (don't hand-wave a field) from
   `gh pr view <N> --json state,mergeStateStatus,mergeCommit,headRefName,closingIssuesReferences,statusCheckRollup`:
       & .\format-report.ps1 -Title 'Issue #<N> "<title>" - merge & migrate' -Rows `
         'PR|#<M> <title>',
         'CI/build gate|<✅ pass / ❌ fail> ("<deployment/check status>") - checked before merging',
         'Mergeable state|<✅ MERGEABLE / CLEAN  or the real gh mergeStateStatus>',
         'Merge|✅ Squash-merged as <shortSHA>, confirmed on origin/<defaultBranch>',
         'Remote branch|<✅ deleted / kept>',
         'Issue #<N>|<✅ auto-closed (COMPLETED) via "Fixes #<N>"  /  closed manually>',
         'Migrations|<✅ none in this PR - nothing to apply  /  ✅ applied <file(s)> (verified)>',
         'Worktree|<✅ retired (window + folder + branch removed, pruned) / left active>'
   Use ✅ pass · ❌ fail · ⚠️ caveat, honestly (a red CI check or a non-CLEAN mergeable state shows as
   ❌/⚠️ with the reason, never glossed). If you merge several PRs at once, print one report per PR.
3. **Update the monitor + offer the recommended follow-ups.** Mark the worktree done in the ledger —
   `.\review-coverage.ps1 progress -Worktree <folder> -Status merged` (then `-Status retired` once you retire it).
   List the worktree's recommendations from the ledger (the system of record): `.\review-coverage.ps1
   recommendations` — fall back to the PR's "## Recommended follow-up issues (out of scope)" section only for
   sessions that pre-date the ledger. **Present them and ask which to file — NEVER auto-create.** File each
   approved one with `.\review-coverage.ps1 file-rec -Id <n>` (creates the GH issue, labels `needs-triage`, marks
   it filed); `dismiss-rec -Id <n>` the rest. Report the outcome as a small box table (proposed title | ✅ filed
   as #<new> / ⏭️ dismissed). This is how discovered-but-unfixed work becomes tracked backlog, not lost.
4. **Sweep the standing follow-up backlog so it can't rot (verify-before-stale).** Don't stop at the just-merged
   worktree's own recommendations — at each close, also glance at the WHOLE pending backlog and keep it fresh:
   `.\review-coverage.ps1 findings -Unverified` (recon findings not yet verified) + `.\review-coverage.ps1
   recommendations` (proposed solver follow-ups, `-N` high enough to see them all — the default is 8).
   **Verify anything that has gone unreviewed against the CURRENT code now** — `verify -Id <n> -Verdict
   <still-valid|already-fixed|partially-fixed|out-of-scope> -Severity .. -Note ..` for a finding (same fields on a
   rec). Follow-ups go stale FAST: every merge silently fixes or moots some of them, so a batch left even a few
   days untriaged is routinely ~10% already-fixed/out-of-scope noise. For a big backlog, verification is a cheap
   **read-only fan-out** (one in-session `Agent` subagent per surface/topic, NOT headless `claude`; each reads
   current code/DB and writes only verdicts to the ledger). Then promote the still-valid ones you want worked and
   dismiss the rest (as in step 3). **Never let findings/recs accumulate unreviewed across many merges** —
   reviewing a little at each close is what stops the pile-up.

### If `database.enabled` (e.g. Supabase): database migration steps

When `hub.config.json` → `database.enabled` is `true`, include these steps between merge and the merge report:

1. **Find the new migration(s)** the PR added under the migrations directory (e.g. `supabase/migrations/`
   — the `<timestamp>_*.sql` files not yet applied on the remote database; compare against the provider's
   migration list, e.g. via the Supabase MCP `list_migrations`).
2. **Read the SQL first.** If it is **destructive** (DROP TABLE/COLUMN, data deletion, irreversible) or
   touches anything **outside your project's own schema** (the database may be shared across apps), surface
   it and confirm before applying — judgment still applies.
3. **Apply** each new migration to the production database via your provider's tool. For Supabase, use
   the Supabase MCP **`apply_migration`** (name = the migration filename, query = its SQL). `supabase db push`
   is the CLI equivalent if the CLI is set up; the MCP path needs no CLI.
4. **Verify** it took (e.g. `list_migrations` / `list_tables` / a read-only catalog `execute_sql`).
5. Include the migration result in the merge report's `Migrations` field.

**Reminders:** if your database instance is **shared** across multiple apps, apply only migrations that
belong to your project's own schema. If no migration files changed in the PR, there is nothing to apply —
just merge. The `<verifyCmd>` (e.g. `pnpm verify`)'s migration-check step is a **collision check, not an apply**.

---

## Critical rules for agent worktrees

1. **Dependencies are per-folder.** Each worktree is a separate physical directory, so
   `node_modules` is NOT shared. The first command in any new worktree is `<installCmd>`
   (e.g. `pnpm install`). The `-Install` flag on `new-worktree.ps1` does this for you.
2. **`.env` is per-folder and git-ignored.** Real secrets live only on disk, never in
   git (`.env` and `.env.*` are gitignored; only `*.example` files are tracked). Seed a
   new worktree by copying env files from the base worktree (configured in `hub.config.json` → `envFiles`).
   **The base worktree (`<baseWorktree>`) is the canonical source of secrets for this hub** — create
   the env files once there from the example files and the helper script will propagate them.
3. **One branch per worktree.** A branch can only be checked out in one worktree at a
   time — that isolation is the whole point. Don't try to check out the default branch in two places.
4. **Don't edit code from the hub root.** Work inside a worktree.
5. **Pushing & PRs happen from inside the worktree** (auth is already configured):
   `git push -u origin <branch>` then `gh pr create`.
6. **Worktrees carry their rules + brief as `@`-mentioned files.** Every worktree gets a git-excluded
   **`WORKTREE.md`** (standing rules, copied from the hub root) and — for issue worktrees — **`ISSUE.md`**
   (full issue text, comments, screenshots in `issue-assets\`). Seed prompts **`@`-mention** both
   (`@WORKTREE.md @ISSUE.md`) to force them into context. All are git-excluded; don't commit them.
7. **🚫 NEVER run headless Claude (`claude --print` / `claude -p`) — it costs real money.**
   Non-interactive Claude is billed as **API usage OUTSIDE the user's Claude subscription**, so
   every `claude --print` invocation — single, looped, or as a background task — is an
   out-of-pocket charge. Interactive sessions opened through the **windowed wrapper**
   (`claude-launch.ps1`, launched with `Start-Process pwsh`) are covered by the subscription.
   **Rule:** launch ALL sessions — solver, recon, review, children, handoffs — only via the
   windowed wrapper. Do NOT use `claude --print` for "windowless"/headless recon,
   notification-driven loops, or any other orchestration. Accept window pile-up as the price of
   staying on-subscription. There is **no supported headless path** — `new-recon.ps1` had its
   `-Headless` flag removed for this reason; do not reintroduce one.

## Useful project scripts (run inside a worktree)

Commands come from `hub.config.json`. Examples using the pnpm defaults:

```text
pnpm dev          # dev server  (your installCmd / dev runner)
pnpm build        # production build
pnpm test         # test runner  (your testCmd)
pnpm typecheck    # tsc --noEmit (or equivalent)
pnpm lint         # linter
pnpm verify       # typecheck + lint  (your verifyCmd — good pre-PR gate)
```

Replace `pnpm` with your configured `packageManager` / `installCmd` / `verifyCmd` / `testCmd`.

## Naming conventions

- Worktree folder: `agent-<task>` for new work, `wt-<branch>` when parking an existing branch.
- Issue worktree: `issue-<N>-<slug>` with branch `fix/issue-<N>-<slug>` — created automatically
  by `new-worktree.ps1 -Issue <N>` (slug derived from the issue title).
- New branch for a worktree: `feature/<task>` or `fix/<task>` (default `feature/<Name minus the agent- prefix>`).
- Keep folder name and branch related so `git worktree list` is self-explanatory.
- Session tab name (`claude --name`): `#<N> <1-2 words>` (e.g. `#42 Auth`) so Windows
  Terminal tabs are scannable at a glance. The generated `.launchers\*.ps1` set this.

---

## Worktree registry (keep current)

The managing session updates this table when a worktree is added or removed.

| Worktree folder | Branch | Purpose | Status | Created |
|---|---|---|---|---|
| `main` | `main` | Base / canonical worktree; source of `.env` for new worktrees | active | <date> |

---

## Notes for the managing session

- The hub root is intentionally a bare repo: never `git init` here or convert it.
- If `git worktree list` shows a worktree whose folder was deleted by hand, run
  `git worktree prune`.
- When you (the orchestrator) create or remove a worktree, **update the registry table above**.
- Helper scripts are `.ps1`; run them from the hub root.
- Hub configuration lives in `hub.config.json` (git-ignored). Edit it to change repo, commands, or
  database settings. Use `hub.config.example.json` as the template.

## Lessons learned & gotchas

Hard-won specifics from setting up and exercising this hub. Read these before touching the plumbing
or the helper scripts — each one cost a debugging cycle.

- **🚫 NEVER run headless Claude (`claude --print` / `claude -p`) — it bills outside the
  subscription (real money).** We tried a "headless recon" pattern: running `claude --print` as
  background tasks so recon ran windowless and notification-driven (no terminal pile-up). It
  works technically, but non-interactive Claude is metered as **API usage, separate from the
  Claude subscription** — i.e. an out-of-pocket charge per run. Only the windowed wrapper
  (`claude-launch.ps1` via `Start-Process pwsh`) is subscription-covered. Launch EVERY session
  (solver / recon / review / child / handoff) through the windowed wrapper; never `claude
  --print`. The `-Headless` flag was removed from `new-recon.ps1` — do not reintroduce a
  headless path. See Critical rule #7. (Cost > tidiness: tolerate window pile-up instead.)
- **The `.git` pointer must be BOM-free UTF-8 with LF endings.** PowerShell's
  `echo "gitdir: ./.bare" > .git` and `Set-Content` (without `-Encoding utf8`) write a
  UTF-16/BOM file that git silently fails to parse — the whole hub then looks like "not a
  git repository." Recreate it only with a writer that emits raw UTF-8/LF: a single line
  `gitdir: ./.bare`. `init-hub.ps1` handles this correctly with `[System.IO.File]::WriteAllText`.
- **A bare clone sets up NO upstream tracking.** The base worktree and every fresh worktree start with
  no `@{upstream}`, so `git pull` says "no tracking information" and `git status` shows no
  ahead/behind. Fixed for the base via `git branch --set-upstream-to=origin/<defaultBranch> <defaultBranch>`;
  `new-worktree.ps1` now does this for every worktree it creates. If you ever add one by
  hand, run `git branch --set-upstream-to=origin/<branch>` inside it.
- **A bare clone creates LOCAL heads for every remote branch**, so `git branch` lists
  branches nobody created here — that's expected, not corruption. Those heads are frozen at
  clone time and can go stale; `new-worktree.ps1 -Existing` fast-forwards the local ref from
  origin (`git fetch origin <br>:<br>`) before checkout so you never start from a stale commit.
- **Removing a worktree that holds a feature branch usually needs `-Force`.**
  `remove-worktree.ps1 -DeleteBranch` uses safe `git branch -d`, which refuses to delete a
  branch with commits not in the default branch (most feature branches) to protect unpushed work.
  After the branch is merged/pushed, use `-DeleteBranch -Force`.
- **Editing the `.ps1` helpers (PowerShell quirks):** native git exit codes do NOT trip
  `$ErrorActionPreference = 'Stop'` — check `$LASTEXITCODE` (the scripts wrap git in an
  `Invoke-Git` helper for exactly this). You cannot sequence statements with `;` inside
  an `if (...)` condition — it's a parse error; compute the boolean on a preceding line.
  And a comma-separated value to a native flag must be ONE quoted token
  (`gh ... --json 'body,comments'`, never `--json body, comments` — the space makes
  PowerShell pass two args and the command fails).
- **Private-repo issue screenshots need an authenticated fetch.** `gh issue view` returns the
  issue text and image *URLs*, but not the bytes — and those `github.com/user-attachments/assets/…`
  URLs return **404 to any unauthenticated request**, so an agent's plain web fetch can't see
  them. Verified: fetching the same URL with `gh auth token` (Bearer) 302-redirects to the
  signed CDN URL and returns the image. Use **`fetch-issue-images.ps1 -Issue <N>`** to download
  an issue's images (saved under `.issue-images\`, outside any worktree) and have the agent
  `Read` the local files. **`new-worktree.ps1 -Issue <N>` now does all of this automatically**
  at creation — it writes `ISSUE.md` + `issue-assets\` into the worktree — so
  `fetch-issue-images.ps1` is mainly for ad-hoc use or non-issue worktrees.
- **Removing a worktree on Windows is finicky — finish the folder delete with Git Bash `rm -rf`.**
  Two failure modes: (a) if the session **window is still open**, the live process holds the
  worktree as its current directory, so deletion fails — close the window first. (b) Even with the
  window closed, `git worktree remove --force` typically **unregisters** the worktree (it vanishes
  from `git worktree list`) but returns non-zero and **leaves the whole folder on disk** (a
  `node_modules` quirk). Reliable sequence: `git worktree remove --force <name>` (ignore its exit
  code) → Git Bash **`rm -rf <folder>`** (works where git's own delete didn't) → `git branch -D
  <branch>` → `git worktree prune`. Also: the PowerShell sandbox safety-guard false-positives on
  `Remove-Item` when the same command contains regex like `[^\]]` (it misreads `\]` as a path and
  blocks the whole command) — use Git Bash `rm -rf` for bulk folder deletes to avoid that.
  "Issue merged" does NOT mean the window is closed.
