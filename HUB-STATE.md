# HUB-STATE.md — live orchestrator state (kept OUT of CLAUDE.md to avoid churn)

> **Purpose.** This file holds the **volatile** hub state that would otherwise churn `CLAUDE.md`:
> the **current-state one-liner** (default-branch tip / what's staged or on hold / standing backlog)
> and small running **process notes**. It is meant to be **`@`-mentioned** into the orchestrator
> session (`@HUB-STATE.md`) so it loads into context without editing the big, stable `CLAUDE.md`.
>
> **Rule:** when the default-branch tip moves, work advances, or you need a small process/state note —
> **update THIS file, not `CLAUDE.md`.** Durable rules, patterns, and lessons stay in `CLAUDE.md` /
> `WORKTREE.md`.
>
> **The per-worktree registry lives in the LEDGER, not here** — `.\review-coverage.ps1 monitor` (the
> `worktree` table is one row per worktree, status updated as it progresses). Don't duplicate it as a
> markdown table; this file is for the narrative state the ledger doesn't capture.

## Current state

_One-liner snapshot: default-branch tip · what's in flight / staged / on hold · standing-backlog summary._

- _(nothing recorded yet — fill in as work lands; e.g. "`main` tip `<sha>`; batch N staged + on hold; ~K Low recs standing")_

## Small process notes

_Running scratch for small orchestrator notes that don't warrant a `CLAUDE.md` edit._

- 2026-06-30 — Live hub state split out of `CLAUDE.md` into this file (lean, ledger-aware variant of
  connect's `HUB-STATE.md`): `@`-mention `@HUB-STATE.md` in orchestrator sessions and update it (not
  `CLAUDE.md`) for current-state + process notes; the per-worktree registry stays in the ledger (`monitor`).
