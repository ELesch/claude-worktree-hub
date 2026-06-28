# Design — claude-worktree-hub first-run setup: wizard + doctor

**Date:** 2026-06-28
**Status:** Approved (design), pending implementation plan
**Topic:** Guarantee a complete, ready-to-work hub on first use — nothing missing or incomplete.

---

## 1. Problem

Setting up the hub for a new repo today takes several manual, easy-to-miss steps that are
**not unified and not verified**:

- `init-hub.ps1` does the bare-repo bootstrap well (bare clone, `.git` pointer, fetch refspec +
  `gc.auto=0`, base worktree + upstream, `hub.config.json` generation), but it **never touches the
  ledger** and its printed "Next:" steps jump from "edit config / add secrets" straight to "create a
  worktree" — omitting ledger setup entirely.
- The **SQLite ledger** (`review-coverage.ps1 init` + `seed`) — which powers the monitor, recon
  coverage, and the issue-review pipeline — is only mentioned in the README quickstart. If skipped, the
  whole monitoring/issue-lane capability silently no-ops or errors at first use.
- **`.env` secrets** in the base worktree are described as a manual step with no scaffolding; a missing
  `.env` only surfaces as a warning later in `new-worktree.ps1`.
- **`installCmd`/`verifyCmd`/`testCmd`** are hardcoded `pnpm` defaults; nothing detects the cloned
  repo's actual package manager, so the defaults silently mismatch non-pnpm projects.
- **External prerequisites** — `sqlite3`, an *authenticated* `gh`, Git Bash, `claude`, PowerShell 7 —
  are unchecked (`init-hub` verifies only `git`/`gh` are on PATH). A missing `sqlite3` or an
  unauthenticated `gh` fails cryptically mid-workflow.
- There is **no single "is my hub ready?" check** to confirm completeness or diagnose gaps.

The recent `6e71bc9` ("first-run dogfooding findings") commit shows first-run robustness is an active
concern; this design closes the remaining gaps systematically.

## 2. Goal & success criteria

A new user can run **one command** and end up with a hub where **no capability is missing or
incomplete**, and can **re-verify readiness at any time**.

Success = after setup, the doctor reports **READY** (zero blockers), meaning: all external
prerequisites present and `gh` authenticated; bare repo + `.git` pointer + base worktree healthy;
`hub.config.json` valid with a real `repo` and project-appropriate commands; ledger initialized and
seeded; `.env` scaffolded; `WORKTREE.md` present.

## 3. Decisions (locked)

| Decision | Choice |
|---|---|
| Deliverable shape | **Bootstrap + doctor**: one command does the whole setup end-to-end, plus a re-runnable readiness check. |
| Blocker-handling UX | **Interactive wizard**: prompt through blockers, offer to run fixes (`gh auth login`, installs), confirm before acting. |
| Architecture | **Approach A**: shared check library + thin wizard + doctor (mirrors the existing `hub-config.ps1` / `hub-lib.ps1` split). |
| Check list | Complete set in §5, including the two *info* checks (Windows Terminal, superpowers). |
| Testing | Lightweight **Pester** unit tests for the pure logic in `hub-checks.ps1`, plus `-DryRun` + one manual first-run pass. |
| Config edits | Wizard **may edit `hub.config.json`** with **per-change confirmation**. |
| Non-interactive escape hatch | Include an optional **`-Yes`** flag (accept defaults) for re-runs/automation. |

### Non-goals (YAGNI)

- No auto-installing of missing tools without explicit confirmation; no silent edits to config.
- No JSON/machine output mode for the doctor (can add later if needed).
- No changes to the agent/solver workflow, the issue pipeline, or any runtime hub behavior.
- The wizard is for humans at setup time — it does **not** launch agent sessions and never runs
  headless `claude` (Critical rule #7 / the cost rule is unaffected).

## 4. Components

Three new files at the hub root, following the codebase's small-focused-script convention. Each
dot-sources `hub-config.ps1` defensively (see the subtlety in §5).

- **`hub-checks.ps1`** — the readiness check library. **No side effects, no prompts.** Exposes
  `Get-HubReadiness [-Config <cfg>]` returning an ordered array of result objects:
  `@{ Name; Category; Status = 'ok'|'warn'|'fail'; Detail; Fix }`. This is the **single authoritative
  definition of "complete"** — consumed by both the wizard and the doctor so they can never disagree.
  Also houses the pure helpers (`Get-PackageManagerFromLockfile`, `Test-GitPointer`,
  `Test-ConfigPlaceholder`, status classification) that the Pester tests target.
- **`setup-hub.ps1`** — the interactive wizard (§6). The single command a new user runs. Params:
  `-CloneUrl`, `-DryRun`, `-Yes`.
- **`hub-doctor.ps1`** — non-interactive readiness report (§7). Standalone, and called by the wizard
  as its final confirmation. Exit 0 when no blockers, 1 otherwise.

`init-hub.ps1` is **unchanged** — it remains the mechanical bare-repo core that the wizard invokes.

## 5. The readiness checks (definition of "complete")

Classification: **blocker** (fail = hub can't work) · **warn** (should fix / may be intentional) ·
**info** (cosmetic/optional).

| # | Check | Class | Fix offered |
|---|---|---|---|
| 1 | PowerShell 7+ (`$PSVersionTable.PSVersion.Major -ge 7`) | blocker | install PowerShell 7 |
| 2 | `git` on PATH | blocker | install Git |
| 3 | `gh` on PATH | blocker | install GitHub CLI |
| 4 | `gh` authenticated (`gh auth status` exit 0) | blocker | `gh auth login` |
| 5 | `gh` git credential helper configured (`gh auth setup-git`) | warn | `gh auth setup-git` |
| 6 | `sqlite3` on PATH | blocker | `choco install sqlite` / winget |
| 7 | Git Bash (`bash`) on PATH | blocker | install Git for Windows |
| 8 | `claude` on PATH | blocker | install Claude Code |
| 9 | package manager present (`$HubConfig.packageManager`, unless `none`) | warn | install it / `corepack enable` |
| 10 | `.bare` is a valid bare repo (`git -C .bare rev-parse --is-bare-repository`) | blocker | `init-hub.ps1` |
| 11 | `.git` pointer is BOM-free `gitdir: ./.bare` (the first-run bug class) | blocker | `init-hub.ps1` rewrites it |
| 12 | fetch refspec `+refs/heads/*:...` + `gc.auto=0` set | warn | `init-hub.ps1` |
| 13 | base worktree exists + tracks `origin/<defaultBranch>` | blocker | `init-hub.ps1` / set-upstream |
| 14 | `hub.config.json` valid JSON, `repo` set & **not the `owner/repo` placeholder** | blocker | edit config (wizard prompts) |
| 15 | config cmds match project (lockfile-detected PM vs config; `verify`/`test` scripts exist) | warn | wizard offers to update |
| 16 | ledger `coverage.db` exists with expected tables | blocker | `review-coverage.ps1 init` |
| 17 | ledger seeded (topic table non-empty) | warn | `review-coverage.ps1 seed` |
| 18 | `.env` scaffolded in base worktree (file or matching `.example` present per `envFiles`) | warn | wizard copies `.example`→target |
| 19 | `WORKTREE.md` present at hub root | blocker | restore from git |
| 20 | Windows Terminal present (tab coloring) | info | optional |
| 21 | superpowers plugin (only if `complexPromptPreamble` references it) | info | optional / clear the preamble |

**Check notes (resolve two ambiguities):**

- **#5 detection** — "credential helper configured" is determined by inspecting `gh auth status` output
  (it reports git-protocol configuration) and/or `git config --get-all credential.helper` for the gh
  helper. A clean signal from either satisfies the check.
- **#15 applicability** — this check is **lockfile/Node-aware**: it runs only when a lockfile or
  `package.json` is present in the base worktree. On a non-Node project (no lockfile/`package.json`), it
  is **not applicable** and reports `ok` (n/a) rather than warning. When `packageManager` is `none`, both
  #9 and #15 report `ok` (n/a).

### Key implementation subtlety — checks must run on an un-bootstrapped hub

`hub-config.ps1`'s `Get-HubConfig` **throws** when `hub.config.json` is absent. The checks must work on a
hub that has not been bootstrapped at all. Therefore:

- `hub-checks.ps1` does **not** assume a successful config load. The wizard/doctor attempt the load in a
  `try/catch`; on failure they pass `$null` for the config.
- Config-dependent checks (9, 14–18) degrade to a clean `fail` ("not bootstrapped yet — run setup") when
  config is absent, instead of crashing.
- `$Hub` is derived from `$PSScriptRoot` (works regardless of config), so path-based checks
  (10, 11, 12, 13, 19) always run.

## 6. Wizard flow (`setup-hub.ps1`)

Every phase **checks first and acts only on what's missing**, so the wizard is **idempotent — re-run
anytime to resume/repair**. `-DryRun` prints intended actions without performing them; `-Yes` accepts
the safe default for every prompt.

1. **Preflight prerequisites** — run checks 1–9. For each missing tool: explain why it matters; if
   `winget`/`choco` is available, offer to run the install (`[Y/n]`); otherwise print the manual install
   command. For an unauthenticated `gh`: offer to run `gh auth login` then `gh auth setup-git`. Re-check
   until satisfied or the user skips.
2. **Bare-repo bootstrap** — if `.bare` is absent, prompt for the clone URL (or use `-CloneUrl`) and call
   `init-hub.ps1`; if `.bare` is present, skip (avoids init-hub's "`.bare` already exists" abort). init-hub
   keeps doing the mechanical work.
3. **Config confirmation** — detect the package manager from the base worktree's lockfile
   (`pnpm-lock.yaml`→pnpm, `package-lock.json`→npm, `yarn.lock`→yarn, `bun.lockb`→bun). If it differs from
   config, show detected-vs-configured and offer to update `installCmd`/`verifyCmd`/`testCmd`. Prompt if
   `repo` is still the `owner/repo` placeholder. Warn if `package.json` lacks `verify`/`test` scripts.
   Write back confirmed changes to `hub.config.json` (per-change confirmation; honors `-Yes`).
4. **Env scaffold** — for each `envFiles` entry missing but with a matching `.example` in the base
   worktree, offer to copy `.example`→target so the file exists to fill. Never auto-fills secret values;
   reminds the user to populate them.
5. **Ledger** — if `coverage.db` is missing/unseeded, run `review-coverage.ps1 init` then `seed`
   (safe + idempotent, so done automatically without a prompt).
6. **Final readiness** — invoke `hub-doctor.ps1`; print **READY ✅** / **NOT READY ❌** plus any remaining
   manual items and their fix commands.

## 7. Doctor (`hub-doctor.ps1`)

- Calls `Get-HubReadiness` (loading config defensively) and prints results **grouped by category**,
  color-coded: ✅ ok · ⚠️ warn · ❌ fail — each with its `Detail` and `Fix`.
- Prints an overall verdict: **HUB READY ✅** (no blockers) or **NOT READY ❌ — N blocker(s)** with the
  blocking items listed.
- **Exit code:** `0` when there are no `fail` (blocker) results, `1` otherwise — making it scriptable and
  letting the wizard branch on it.
- Read-only by nature (no `-DryRun` needed).

## 8. Error handling

- Native commands are checked via `Get-Command` and `$LASTEXITCODE`, reusing the existing `Invoke-Git`
  pattern (native git exit codes don't trip `$ErrorActionPreference='Stop'`).
- Every wizard action is guarded and re-runnable; the wizard never leaves the hub in a worse state than
  it found it.
- Install/auth fixes run **only** on explicit confirmation (or `-Yes`).
- Interactive prompts use `Read-Host` with safe defaults; `-Yes` selects the default for all.
- PowerShell quirks observed in the repo are respected: no `;` inside `if(...)` conditions; comma-bearing
  native-flag values passed as a single quoted token.

## 9. Testing strategy

- **Pester unit tests** (`hub-checks.Tests.ps1`) for the pure logic — `Get-PackageManagerFromLockfile`
  (each lockfile → PM), `Test-ConfigPlaceholder`, `Test-GitPointer` (BOM/LF/`gitdir` validation), and
  status classification — mockable without a real hub. This introduces Pester as a dev dependency
  (documented in README prerequisites as test-only).
- **`-DryRun`** for `setup-hub.ps1` to exercise the phase logic without side effects.
- **One manual first-run pass** against a throwaway target repo to validate end-to-end (bootstrap →
  ledger → doctor READY).

## 10. Documentation updates

- **README**: Quickstart collapses to "run `.\setup-hub.ps1`" (the existing manual steps retained as the
  under-the-hood reference); add `hub-doctor.ps1` to the file map and ledger/commands; note Pester as a
  test-only prerequisite.
- **CLAUDE.md**: update the setup narrative and the directory-structure file listing to include
  `hub-checks.ps1`, `setup-hub.ps1`, `hub-doctor.ps1`; note that `init-hub.ps1` is now wrapped by the
  wizard and that first-run = one command.
- **`init-hub.ps1`** "Next:" output: point at `setup-hub.ps1` / `hub-doctor.ps1` rather than listing
  partial manual steps (init-hub remains directly callable for the mechanical path).

## 11. File-ownership summary (for the implementation plan)

| File | New/Changed | Responsibility |
|---|---|---|
| `hub-checks.ps1` | new | readiness check library + pure helpers (`Get-HubReadiness`) |
| `setup-hub.ps1` | new | interactive wizard (phases 1–6) |
| `hub-doctor.ps1` | new | non-interactive readiness report + exit code |
| `hub-checks.Tests.ps1` | new | Pester unit tests for pure logic |
| `init-hub.ps1` | changed (minimal) | "Next:" output points at the wizard/doctor |
| `README.md` | changed | Quickstart → one command; file map; Pester note |
| `CLAUDE.md` | changed | setup narrative + file listing |
