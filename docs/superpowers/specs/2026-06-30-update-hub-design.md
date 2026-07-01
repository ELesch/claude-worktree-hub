# Hub self-update (`update-hub.ps1`) — Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

**Scope:** Add one command that refreshes a hub *deployment's* tracked tooling files from the pristine
source clone of `ELesch/claude-worktree-hub`, plus a short `## Updating the hub itself` section in
`CLAUDE.md` that documents it durably. Because the doc lives in the tracked `CLAUDE.md`, it ships to every
deployment and survives the next overlay — which is the whole point.

## Problem

Updating a hub deployment today is a manual, discovery-heavy chore. Almost all the effort is *figuring things
out*, not doing them:

1. **Finding the source** — that the upstream is `ELesch/claude-worktree-hub` and the pristine clone lives at
   `C:\mydev\claude-worktree-hub`.
2. **Cutting through noise** — most file "differences" between source and deployment are just CRLF
   line-endings, not real changes; only a fraction of the ~54 tracked files actually need updating (last time:
   17 of 53).
3. **Knowing what's safe** — that overlaying the tracked tooling files won't harm config, ledger, worktrees, or
   `PRODUCT.md`, because those are gitignored upstream and so aren't part of the update set.

And the natural place to write this down — `CLAUDE.md` — is itself a tracked hub file that every update
**overwrites**. A note added to a deployment's copy is wiped on the next update. **Any durable fix has to live
in the upstream repo** and ship from there.

## Background: source vs. deployment (why an overlay is the right shape)

- **Source clone** (`C:\mydev\claude-worktree-hub`): a *normal* git clone of `ELesch/claude-worktree-hub`.
  `git ls-files` here lists the **tooling** — the 54 tracked `.ps1` / `.md` / `.json` files. `git pull` refreshes
  it from GitHub. This is the only place the tooling file list is enumerable.
- **Deployment** (e.g. `C:\mydev\connect`): a *bare-repo hub*. Its `.git` is a pointer to `.bare`, which is a
  bare clone of the **target project** (the app being developed), not the tooling. So `git status` / `git
  ls-files` at a deployment root can't see the tooling — the tooling files just sit in the root as **plain
  files**. That is exactly why the update must enumerate from the source clone and copy *onto* the deployment.
- **`.gitignore` defines the safe set.** Runtime data — `.bare/`, the worktree folders, `.launchers/`,
  `.issue-images/`, `.review/*.db`, `hub.config.json`, `.env*`, and `PRODUCT.md` — is gitignored, so it is
  **absent from `git ls-files`** and the overlay can't touch it. No special-casing needed.
- **The one trap:** `HUB-STATE.md` is **tracked** (so it *is* in `git ls-files`) but holds **per-deployment
  live state** (default-branch tip, in-flight work, process notes). A blind overlay would clobber a
  deployment's live state with the source's template. It must be excluded.

## Goal

One idempotent command, run **inside the hub you want to update**:

```powershell
.\update-hub.ps1 -DryRun   # preview exactly what would change
.\update-hub.ps1           # pull latest source, overlay tracked tooling files
```

It reports precisely which files changed (the "17 of 53" signal), skips CRLF-only noise, and never touches
runtime data or `HUB-STATE.md`.

## Chosen approach (settled in brainstorming)

- **Direction — run inside the target hub.** Target = `$PSScriptRoot` (the hub the script lives in / is run
  from), matching every other hub script's convention. `-Source` overrides the source path.
- **`HUB-STATE.md` — hard-coded skip.** A constant skip-list (`@('HUB-STATE.md')`), never overwritten. Not a
  configurable `-Skip` param (YAGNI); the list is a one-line constant, easy to edit if it ever grows.
- **Source resolution — error with guidance.** `-Source` defaults to `C:\mydev\claude-worktree-hub`. The
  script validates it is a git work-tree whose `origin` remote is `ELesch/claude-worktree-hub` (tolerant of
  https/ssh and a trailing `.git`). Missing or wrong-remote → stop with the exact fix command. No auto-clone,
  no surprise network beyond the opt-outable pull.

## Non-goals (YAGNI)

- **No deletions.** The overlay is additive (create + update); it never removes a file from the deployment. If
  a tooling file is retired upstream, that is a rare manual cleanup, not something an auto-overlay should do.
- **No auto-clone** of the source if it's missing (that was the rejected option).
- **No config field and no `-Skip` param.** The skip-list is a hard-coded constant.
- **No README / other-doc edits.** `CLAUDE.md` is the documented home for this. A README pointer can be added
  later if wanted; out of scope here.
- **Not a general file-sync tool.** It is scoped to this one source repo and refuses any other (remote
  validation), so it can't be pointed at an arbitrary directory by mistake.

## The two artifacts

### 1. `update-hub.ps1`

**Signature:** `[-Source <path>] [-DryRun] [-NoPull]`, `-Source` default `C:\mydev\claude-worktree-hub`.
`[CmdletBinding()]`, `$ErrorActionPreference = 'Stop'`. Mirrors `init-hub.ps1` conventions: an `Invoke-Git`
helper that checks `$LASTEXITCODE`, colored `Write-Host`, and dry-run-aware steps.

**Algorithm:**

1. **Resolve** Target = `$PSScriptRoot`; full-path both Target and `-Source`.
2. **Validate Source:** it is a git work-tree, and `git -C <source> remote get-url origin` matches
   `ELesch/claude-worktree-hub` **case-insensitively** (normalize away `.git`, `https://`, `git@…:`).
   Otherwise `throw` with the remediation (clone it, or pass the right `-Source`).
3. **Target == Source?** → print "you're in the source clone; nothing to overlay" (still refresh it via pull
   unless `-NoPull`), then exit cleanly.
4. **Refresh source** (unless `-NoPull`): `git -C <source> fetch` then `pull --ff-only`. A dirty or
   non-fast-forward source is a **warning, not fatal** — you author in that clone, so a failed pull shouldn't
   abort; the overlay proceeds from its current checkout. **`-DryRun` still refreshes the source** (a safe,
   idempotent ff-only pull of a repo you own) so the preview reflects the latest tooling; it only suppresses
   writes to the *deployment*. Use `-NoPull` to skip the source refresh too (a fully read-only preview).
5. **Enumerate:** `git -C <source> ls-files`, minus the skip-list `@('HUB-STATE.md')`.
6. **Per file** (`f`): `srcNorm` = CRLF-normalized text of `<source>/f`. If `<target>/f` is missing →
   **new**. Else `dstNorm` = CRLF-normalized text of `<target>/f`; if `srcNorm -ceq dstNorm` → **unchanged**
   (this is what collapses CRLF-only noise — EOL is ignored for the change decision); else → **updated**.
   For new/updated (and not `-DryRun`): create parent dirs, write `srcNorm` as **UTF-8 without BOM**.
7. **Report:** list the new and updated files, then a summary line — e.g.
   `12 updated · 1 new · 40 unchanged · 1 skipped (HUB-STATE.md)`. `-DryRun` prints the identical report and
   writes nothing.

**Pure, unit-testable helpers:** `ConvertTo-Crlf` (line-ending normalizer) and the source-remote matcher.
The script is structured so it can be dot-sourced by the test without running `main`.

### 2. `CLAUDE.md` changes

- **New `## Updating the hub itself` section**, placed right after the opening orientation blockquotes and
  before `## Repository`. Content: the two commands, the "run it from inside the hub you want to update" note,
  what is preserved (gitignored runtime data + `HUB-STATE.md`), and a one-liner that *this section is itself
  the thing that survives updates* (so future edits go upstream).
- **Directory-structure tree:** add one `update-hub.ps1` line, consistent with how every other helper is
  listed.

## Error handling / edge cases

- **Source missing / wrong remote** → `throw` naming the expected remote + the fix.
- **Source dirty or non-fast-forward** → warn, continue with the current checkout; `-NoPull` skips the network
  step entirely.
- **Target == Source** (running the copy in the source clone) → friendly no-op after the pull.
- **New file in source, absent in deployment** (e.g. `update-hub.ps1` itself on the first run) → created.
- **File retired upstream** → left in place (additive overlay); manual cleanup, called out in the report only
  if trivially detectable, otherwise ignored.
- **Self-overlay** (the running script copies over itself) → safe; PowerShell reads the whole script into
  memory before executing.
- **All tracked files are text** (`.ps1` / `.md` / `.json`) → CRLF-normalize-all is safe; no binary handling
  needed.

## Testing

- **`update-hub.Tests.ps1` (Pester):**
  - `ConvertTo-Crlf` is idempotent and maps LF / CRLF / mixed input all to CRLF.
  - The skip-list excludes `HUB-STATE.md`.
  - A file identical except for EOL → **unchanged** (no write).
  - A file with a real content diff → **updated**.
  - The remote matcher accepts `https://…/ELesch/claude-worktree-hub(.git)` and `git@github.com:ELesch/…`
    and rejects a different repo.
- **Acceptance:** the script parses clean (PowerShell parser), Pester is green, and `.\update-hub.ps1
  -DryRun` run against a real deployment prints a sensible "N updated · … unchanged" report and writes
  nothing.

## Rollout

- Pure addition: one script + one `CLAUDE.md` section + one directory-tree line + one test file + this spec.
  No config, schema, or behavior changes to any existing tool.
- Ships via the normal PR flow to `ELesch/claude-worktree-hub`. From then on, every deployment receives
  `update-hub.ps1` and self-updates with it.
- The first run in an existing deployment creates `update-hub.ps1` there (it's new) and reports the real
  content deltas — the manual chore becomes `-DryRun` then run.
