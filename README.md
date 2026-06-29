# claude-worktree-hub

A Windows/PowerShell hub for running **many Claude Code agent sessions in parallel** against a single
GitHub repo. Each session gets an isolated git worktree so agents never collide on files, hot-reloads,
or git locks. A SQLite ledger tracks every worktree's lifecycle, schedules automated code-review recon,
and enforces an overlap-aware issue-dispatch pipeline from GitHub issue → scope review → approved wave →
solver PR → merge.

---

## What it is

`claude-worktree-hub` lets you run a fleet of autonomous Claude Code solver agents simultaneously — each
one owns its own branch, its own `node_modules`, and its own terminal session. A shared SQLite monitor
(`review-coverage.ps1 monitor`) shows every active session's status without you reading their windows.
Between issues, **recon worktrees** do read-only security/performance/a11y discovery and stage candidate
issues into the ledger for your review before anything gets filed or fixed.

The pipeline looks like this:

```
recon discovers findings
    → verify findings against current code
    → promote approved findings as GitHub issues
    → issue sync pulls all open issues into the ledger
    → subagent review fan-out scopes each issue (files owned, severity, track)
    → you approve
    → issue next picks the highest-priority non-overlapping wave
    → new-worktree.ps1 spins up a solver per issue
    → solver implements → PR (simple) or spec-gate → execute → PR (complex)
    → you merge → optional DB migration applied
```

Human checkpoints: issue approval and merge. Everything in between is autonomous.

---

## How it works

The hub uses a **colocated bare repo**: a bare clone lives in `.bare\`, a redirect file `.git` (one
line: `gitdir: ./.bare`) points at it, and every worktree folder has its own `.git` file pointing at
`.bare\worktrees\<name>`. This means `git fetch`/`git pull` behave normally from inside any worktree,
but the hub root itself has no working tree (which is intentional — you never edit source there).

```text
<hub root>\                  <- the hub (bare repo + worktrees live here)
├── .bare\                   <- the actual git repository data (bare clone)
├── .git                     <- pointer file: contains "gitdir: ./.bare"
├── .launchers\              <- generated per-worktree window launchers (re-runnable)
├── .issue-images\           <- issue screenshots downloaded with gh auth (untracked)
├── .review\                 <- coverage.db (SQLite ledger: topics, findings, activity; untracked)
├── CLAUDE.md                <- hub orchestration doc + worktree registry
├── WORKTREE.md              <- standing rules copied into every worktree + @-mentioned in its seed prompt
├── hub.config.example.json  <- config template (tracked); copy to hub.config.json and edit
├── hub.config.json          <- your config (git-ignored)
├── hub-config.ps1           <- config loader: sets $Hub + $HubConfig, exposes Get-LaunchFlags
├── claude-launch.ps1        <- bundled session wrapper (delegates to personal tab-color hook if present)
├── init-hub.ps1             <- bootstrap: bare clone + .git pointer + base worktree + config gen
├── setup-hub.ps1            <- interactive first-run wizard (bootstrap + config + ledger + env + prereqs)
├── hub-doctor.ps1           <- non-interactive readiness report (exit 0 ready / 1 blockers)
├── hub-checks.ps1           <- shared readiness-check library (single source of truth for "ready")
├── new-worktree.ps1         <- provision a worktree (use -Issue <N> for issue work)
├── remove-worktree.ps1      <- tear a worktree down (worktree + branch only)
├── retire-worktree.ps1      <- FULLY retire a finished worktree (kill terminal + remove + rm -rf + prune)
├── cleanup-worktree-processes.ps1 <- sweep orphaned processes from closed worktrees
├── format-report.ps1        <- render completion/merge reports as aligned Unicode box tables
├── fetch-issue-images.ps1   <- download private-repo issue screenshots for agents to read
├── spawn-child.ps1          <- complex worktrees create depth-capped child worktrees
├── handoff.ps1              <- hand a planner off to a fresh executor session (resets context)
├── new-recon.ps1            <- create + launch a read-only recon (discovery) worktree
├── launch-recon-fleet.ps1   <- launch a fleet of recon worktrees in one token burst
├── review-coverage.ps1      <- SQLite ledger: topics, findings, issue pipeline, monitor
├── ledger-to-html.ps1       <- render all open ledger items to a self-contained HTML dashboard
├── hub-lib.ps1              <- shared functions (issue bundle, slug, image download)
├── main\                    <- base worktree, tracks the default branch
├── agent-*\                 <- one isolated worktree per parallel task (created on demand)
├── issue-<N>-*\             <- issue worktree; contains ISSUE.md + issue-assets\
├── recon-<surface>\         <- read-only recon worktree; proposes issues, files on approval
└── <parent>--<piece>\       <- child worktree spawned by a complex parent (branches off parent)
```

---

## Prerequisites

| Tool | Notes |
|---|---|
| Windows | PowerShell 7 (`pwsh`) required; scripts use PS7 features |
| `git` | Any recent version |
| `gh` (GitHub CLI) | Must be authenticated: `gh auth login` + `gh auth setup-git` |
| `sqlite3` | On PATH; used by `review-coverage.ps1` for the ledger |
| Git Bash | For `rm -rf` teardown (Windows `Remove-Item` leaves `node_modules` behind) |
| Claude Code | `claude` on PATH; the agent sessions run here |
| Windows Terminal | Optional but recommended — `claude-launch.ps1` sets tab colors when your personal `claude-color.ps1` hook is present |
| `superpowers` plugin | Optional — required only if you keep `complexPromptPreamble` set to `/superpowers:using-superpowers` in your config |
| `Pester` v5 | Test-only; `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser` to run `hub-checks.Tests.ps1` |

---

## Quickstart

```powershell
# 1. Clone this hub template
git clone https://github.com/<you>/claude-worktree-hub.git
cd claude-worktree-hub

# 2. Run the setup wizard - idempotent; does bootstrap, config, ledger, env scaffold,
#    and prerequisite checks, then prints a readiness report. Re-run anytime.
.\setup-hub.ps1 -CloneUrl https://github.com/<owner>/<repo>.git

# 3. Confirm readiness at any time
.\hub-doctor.ps1

# 4. Provision a solver worktree for a GitHub issue and launch it
.\new-worktree.ps1 -Issue 123 -Install
cd issue-123-<slug>
& ..\claude-launch.ps1 --permission-mode auto --effort max --name "#123 my issue"
```

The underlying scripts (`.\init-hub.ps1`, then `.\review-coverage.ps1 init` + `seed`) still work independently; `setup-hub.ps1` just runs them in sequence.

---

## Configuration

All hub-specific values live in `hub.config.json` (git-ignored; generated from `hub.config.example.json` by `.\setup-hub.ps1`, which calls `init-hub.ps1`). Edit it after bootstrapping.

| Field | Type | Default | What it controls |
|---|---|---|---|
| `repo` | string | *(required)* | `owner/repo` slug — passed to `gh` for issue lookups, PR creation, and recon |
| `cloneUrl` | string | *(required)* | HTTPS clone URL used by `.\setup-hub.ps1 -CloneUrl` (passed to `init-hub.ps1`) |
| `defaultBranch` | string | `"main"` | The repo's default branch; solvers base PRs off this; `retire-worktree.ps1` protects it |
| `baseWorktree` | string | `"main"` | Folder name of the base worktree (created during setup via `init-hub.ps1`); source of `.env` files copied to new worktrees |
| `packageManager` | string | `"pnpm"` | Package manager name (used to detect it on PATH and in messages) |
| `installCmd` | string | `"pnpm install"` | Command to install dependencies in a fresh worktree (`-Install` flag) |
| `verifyCmd` | string | `"pnpm run verify"` | Command agents run to validate before opening a PR (typecheck + lint) |
| `testCmd` | string | `"pnpm test"` | Command to run the test suite |
| `envFiles` | string[] | `[".env", ".env.test", ".env.local"]` | List of env files copied from `baseWorktree\` into each new worktree |
| `launch.permissionMode` | string | `"auto"` | Claude permission mode applied to **every** session this hub launches (solver, recon, executor, child). `"auto"` (classifier-gated — **recommended**: soft-denies the dangerous edge like prod deploys, DB migrations, force-push, push-to-default, `rm -rf`) → `--permission-mode auto`. `"bypass"` → `--dangerously-skip-permissions`, which disables **all** prompts for these unattended autonomous agents — **not recommended**; use only for a manual interactive session, if at all. See "Why `--permission-mode auto`" in CLAUDE.md. |
| `launch.effort` | string | `"max"` | Claude effort level passed as `--effort <value>` to every session |
| `launch.tabColor` | boolean | `true` | Whether `claude-launch.ps1` delegates to your personal `claude-color.ps1` hook for Windows Terminal tab coloring |
| `complexPromptPreamble` | string | `"/superpowers:using-superpowers"` | Text prepended to gated-workflow seed prompts; set to `""` to disable (omit if you don't use the superpowers plugin) |
| `database.enabled` | boolean | `false` | Whether this hub manages database migrations; controls conditional merge→migrate guidance in `WORKTREE.md` |
| `database.provider` | string | `"supabase"` | Database provider name (informational; used in guidance text) |
| `database.migrationsDir` | string | `"supabase/migrations"` | Relative path in the repo where migration files live |
| `database.schema` | string | `"public"` | Schema name for the project's tables (used in migration review guidance) |
| `database.sharedInstanceNote` | string | `""` | Free-text warning shown in merge→migrate guidance when the DB instance is shared with other apps; leave blank if your instance is dedicated |

---

## The workflow

### Simple track (autonomous solver)

Most issues: `new-worktree.ps1 -Issue <N> -Install` → launch agent with the seed prompt → agent
implements → runs `<verifyCmd>` + tests → commits + pushes → opens a PR → prints a completion report
→ records to the ledger. You review the PR, merge, and retire the worktree.

### Complex / gated track

Large or architectural issues get a **human gate**. The agent researches the code, writes `SPEC.md` +
`PLAN.md`, presents the key decisions, and **stops** (`spec-gate` status on the monitor) until you
approve. After approval it executes — using in-process subagents for parallel work, or depth-capped
child worktrees for genuinely large independent pieces. One PR to `main`.

### Ledger commands

```powershell
.\review-coverage.ps1 init                             # schema + tables (one-time)
.\review-coverage.ps1 seed                             # generic topic set (customize for your project)
.\review-coverage.ps1 monitor                          # live status of every worktree
.\review-coverage.ps1 issue sync                       # pull all open GH issues into the ledger
.\review-coverage.ps1 issue unreviewed                 # queue of issues needing scope review
.\review-coverage.ps1 issue approve -Id <N>            # human checkpoint → clears the worktree gate
.\review-coverage.ps1 issue next -N 8                  # overlap-aware wave selector (file-disjoint)
.\review-coverage.ps1 findings                         # recon finding triage
.\review-coverage.ps1 recommendations                  # solver follow-up backlog
.\review-coverage.ps1 hub-findings                     # hub-layer problems (prompt/config/script/env): hubfind logs, hub-resolve closes
.\review-coverage.ps1 consult                          # record an expert consultation + the decision a worktree made (advisory; observable)
.\ledger-to-html.ps1                                   # render all open items to an HTML dashboard
```

### Merging + optional DB migration

```powershell
gh pr merge <N> --squash --delete-branch
# If database.enabled: find new migration files, read them, apply via your provider's tooling, verify.
# Print the merge report:
.\format-report.ps1 -Title 'Issue #<N> "<title>" - merge & migrate' -Rows 'PR|#<M> ...', ...
# Retire the worktree:
.\retire-worktree.ps1 -Name issue-<N>-<slug> -VerifyMerged -DeleteBranch
```

See `CLAUDE.md` → "Merging a finished PR" for the full step-by-step runbook.

---

## ⚠️ Cost rule — NEVER run headless Claude

**`claude --print` / `claude -p` bills as API usage OUTSIDE your Claude subscription — it is an
out-of-pocket charge per invocation, separate from your plan.** Interactive sessions opened via
`claude-launch.ps1` (or the `claude` CLI directly in a terminal) are subscription-covered.

**Rule: launch EVERY session — solver, recon, review, child, handoff — only as an interactive windowed
session.** Never use `claude --print` for "windowless" recon, notification loops, or any other
orchestration. Accept window pile-up as the cost of staying on-subscription. There is no supported
headless path in this hub.

---

## Credits

Generalized from a private production project. MIT License — see `LICENSE`.
