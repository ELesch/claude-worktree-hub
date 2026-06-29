# Issue Grouping (Overlap Clusters) — Phase 1 Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

**Scope:** This is **Phase 1** of a two-phase feature. Phase 1 adds a read-only *selector* that
**proposes** grouped waves. Phase 2 (separate spec) adds the multi-issue provisioning, the grouped seed
prompt, and the grouped merge/resolve that turn a proposed cluster into one worktree → one PR closing
several issues. Phase 1 is shippable and testable on its own.

## Problem

The issue lane's `issue next` selector picks file-**disjoint** *singleton* issues so worktrees parallelize
without colliding, and **defers** anything that collides on an owned file. But a file collision is *signal*,
not just an obstacle: issues that own the same file are the **same area**, and one session could knock them
all out in a single PR. Today that signal is discarded (deferred), so related small follow-ups each consume
a separate provision → review → PR → merge cycle, and the backlog tends to **grow faster than it closes**.

Field evidence from an analogous hub: before grouping, every batch was net-positive on backlog (~+12 items);
the first **net-negative** batch (closed 29, created 20) happened precisely because bundling let one session
clear **4–6 prior findings at once**. Grouping is the equalizer — and the overlap clusters are its natural
seams.

## Goal

Add `issue clusters`: a read-only selector that **proposes grouped waves**. Each proposed cluster is a
connected component of **approved, simple-track** issues that overlap on **owned files**, sized to stay a
small reviewable PR. For each cluster, surface **same-area proposed findings/recs** as *advisory* extras a
future session can fold in opportunistically. The orchestrator (human) reads the proposals and decides —
nothing is provisioned, approved, or filed by this command.

This realizes the user's framing exactly: *prioritize approved issues* (the cluster spine is approved work),
and *propose groupings for simple items affecting similar areas* (advisory siblings ride along, staying
`proposed` until resolved at merge).

## Non-goals (YAGNI) — Phase 1

- **Not provisioning.** `clusters` proposes; it never creates worktrees, branches, PRs, or GitHub state.
  Multi-issue provisioning, the grouped seed prompt, and grouped merge are **Phase 2**.
- **Not a replacement for `issue next`.** The disjoint singleton selector stays exactly as-is for maximum
  parallelism; `clusters` is the grouped-wave view **alongside** it.
- **Not grouping complex work.** Only `track='simple'` approved issues are grouped. `complex` or unrecorded
  track stays a singleton (safe default — never silently bundle architectural work into an "easy" PR).
- **Not gating on siblings.** Advisory siblings are surfaced, never required, never blocking; they stay
  `proposed` until the orchestrator verifies/resolves them at merge. **The approval gate is untouched** — no
  unapproved issue or finding ever earns a worktree from this feature.
- **Not auto-promoting siblings** (chosen: *advisory bundle*, not *auto-promote*) — the human triage
  checkpoint for promoting findings/recs to issues is preserved.
- **Not splitting over-cap components** into co-scheduled sub-clusters (chosen: *cap + simple-track*, not
  *split-if-too-big*). Over-cap members **defer** to the next wave instead.
- **No new schema.** Pure computation over existing tables; the only write is one `activity` row.

## Constraints (these shape the design)

- **Read-only / idempotent.** `clusters` must not mutate ledger state except a single `activity` log row,
  and must be safe to run any number of times. (Mirrors the read-only discipline of recon `verify`.)
- **Findings/recs carry no structured paths** — only free-text `scope`. Sibling matching is therefore
  necessarily fuzzy (path-substring + area token), which is exactly why siblings are **advisory-only**. False
  positives are cheap (ignore the line); false negatives are fine (it's opportunistic).
- **Honest deferral.** Issues that share an owned file **cannot** run in parallel worktrees; over-cap and
  in-flight members must be **reported as deferred, never silently dropped** (the same contract `issue next`
  already honors with its "Deferred" list).
- **Match the existing selector UX.** Colored `Write-Host` output in the style of `issue next` / `issue list`
  — *not* the `format-report.ps1` box-table tool (that is for completion/merge reports).
- **Active-worktree claim semantics must match `issue next` exactly** (same active-status set
  `'registered','working','spec-gate','pr-open','blocked'`), so the two selectors agree on what is "in
  flight." An issue with **any** owned path claimed by an active worktree is deferred (in-flight area) — same
  as `next`.
- **PowerShell/sqlite plumbing conventions** (from Lessons): use the script's existing `Exec`/`Query`/
  `Scalar` helpers and `q` SQL-escaper; check `$LASTEXITCODE` on native git/gh/sqlite calls; pass any
  comma-bearing native-flag value as one quoted token.

## Architecture overview

Seven units, each independently understandable/testable:

| # | Unit | Responsibility | Interface |
|---|------|----------------|-----------|
| 1 | `clusters` subcommand | dispatch + params + read-only orchestration | `issue clusters [-MaxIssues 4] [-MaxFiles 8]` |
| 2 | Eligibility | select approved · simple · not-in-flight · has-owned-path issues; split out in-flight deferrals | SQL over `issue` / `issue_target` / `worktree` |
| 3 | Overlap graph + components | edges = shared owned path **or** `depends-on`; connected components | in-script graph (hashsets) |
| 4 | Cap + deferral | enforce `≤MaxIssues` / `≤MaxFiles`; cap-subset + defer overflow | per-component logic |
| 5 | Advisory siblings | match open findings/recs to a cluster by path / area | SQL `LIKE` + area over `finding` / `recommendation` |
| 6 | Output + activity | colored proposal render (clusters / singletons / deferred) + one `activity` row | `Write-Host` + `INSERT activity` |
| 7 | Tests | Pester coverage of the algorithm + the read-only invariant | `review-coverage.Tests.ps1` |

## 1. `clusters` subcommand

Add `clusters` to the `issue` sub-command `switch`, to its help string, and to the top-level usage block.
Add two optional params to the existing param block: `[int]$MaxIssues = 4` and `[int]$MaxFiles = 8`
(guarded to `>= 1`; out-of-range falls back to the default). No `-N` — the command shows **all** proposable
clusters (the orchestrator wants the whole grouping picture, not a top-k).

```
.\review-coverage.ps1 issue clusters [-MaxIssues 4] [-MaxFiles 8]
```

The handler is pure read → compute → render, then a single `activity` insert.

## 2. Eligibility

An issue is **cluster-eligible** when **all** hold:
- `review_status = 'approved'`, and
- `track = 'simple'` (`complex` or `NULL` → excluded; listed as a singleton/“not grouped”), and
- it is **not in flight**: no active worktree (`worktree.status IN (<active set>)`) is registered against it,
  **and none of its owned paths is claimed** by an active worktree, and
- it has `≥1` owned path (`issue_target.ownership='owns'`). An approved simple issue with no recorded owned
  paths cannot be overlap-clustered → reported as a singleton.

The active-claimed-paths set is computed exactly as in `issue next` (join `issue_target` → `worktree` on the
active status set). An eligible issue with **any** owned path in that set is removed from clustering and added
to the **deferred (in-flight area)** list, naming the colliding path/worktree.

After this step we hold: `Eligible` (issue → set of its owned paths, all currently free) and
`DeferredInFlight`.

## 3. Overlap graph + connected components

Over `Eligible` only:
- Build `path → {issues}` from the owned paths. Any two issues sharing a path are **adjacent** (the primary
  seam — "collide on files = same area").
- Add adjacency for every `issue_link` with `kind='depends-on'` **where both endpoints are `Eligible`**
  (dependent work must travel in one session, never split across parallel worktrees). `related` links are
  **not** grouping edges (they become advisory notes in output).
- Compute **connected components** (BFS/DFS or union-find over the adjacency map).

A component of size 1 → a **singleton** (reported separately, not a cluster).

`depends-on` edges pointing at a **non-eligible** issue (complex/unapproved/in-flight) are not grouping edges,
but are captured as an advisory **"depends on #X (not in this wave: <reason>)"** note on the dependent
issue's cluster, so the orchestrator sees the cross-wave dependency.

## 4. Cap + deferral

For each component with `≥2` issues:
- If `issues ≤ MaxIssues` **and** `|union(owned paths)| ≤ MaxFiles` → propose the whole component as a
  **cluster**.
- Otherwise (over a cap): the component is one area whose members **share files and cannot parallelize**, so
  it is not split into co-scheduled sub-clusters. Instead:
  - Propose the **highest-priority cap-respecting subset**: order the component's members by priority
    (user-origin first, then severity, then number) and greedily admit members while
    `count ≤ MaxIssues` **and** running `|union paths| ≤ MaxFiles`.
  - List every non-admitted member as **deferred — "same area as Cluster N, exceeds cap; next wave after its
    PR merges."** They regroup naturally once the shared files are free.

Because the whole component is already one area (transitively overlapping), the admitted subset need not be
independently re-checked for internal connectivity — every member is same-area by construction.

Clusters are ordered for display by their best member's priority; issues **within** a cluster by severity.

## 5. Advisory siblings

For each proposed cluster, surface **open, not-yet-filed** ledger items plausibly in the same area:
- **Open findings:** `status='proposed'`. (There is **no** `verified` status value — `verify` records a
  `verdict` but leaves `status='proposed'`, and its `already-fixed`/`out-of-scope` verdicts auto-set
  `status='dismissed'`. So `status='proposed'` is precisely the not-yet-filed, not-dismissed set; a
  verified-still-valid finding is a `proposed` row with a non-null `verdict`, and MAY be shown first as a
  higher-confidence sibling.)
- **Open recommendations:** `status='proposed'`.

A row is a **sibling** of a cluster when **either**:
- **path match (strong):** its `scope` text contains a cluster owned path's **full path or file basename** —
  SQL `LIKE` per path. (Basenames, not bare directories, to avoid a broad segment like `src` matching
  everything.) OR
- **area match (weak):** its `area` (recs) / `topic` (findings) matches a cluster **area token** —
  case-insensitive — where area tokens = the **containing-directory path(s)** of the cluster's owned files
  (e.g. `src/lib`, not the top-level `src`) plus the cluster issues' label tokens.

Siblings are **deduped**, tagged with **why** they matched (`[path: …]` or `[area: …]`) and a
"verify before bundling" caption, and capped to the **top 5 by severity** per cluster (with a "+k more — see
`findings`/`recommendations`" note if truncated) to keep the proposal readable. They are printed for human
judgement only; the command takes no action on them.

## 6. Output + activity

Colored `Write-Host`, in the `issue next` family. Shape:

```
=== Proposed grouped waves (approved · simple-track · file-overlap) ===

Cluster 1 — area: src/lib  (3 issues, 2 files)
  #12  [user]   High    owns:1   Fix N+1 in page queries
  #15  [recon]  Medium  owns:1   Cache page-query results
  #19  [recon]  Medium  owns:2   Dedupe page-query builders
  files: src/lib/page-queries.ts, src/lib/cache.ts
  advisory siblings (proposed — verify before bundling):
    finding #81  Med  [path: page-queries.ts]  Missing index hint on …
    rec     #93  Low  [area: lib]              Extract query-builder helper
  → Phase 2 will provision: new-worktree.ps1 -Issues 12,15,19

Singletons (approved, no overlap — use issue next / new-worktree -Issue N):
  #22  [user]  High  owns:2  Tighten auth redirect

Deferred:
  #28 — same area as Cluster 1, exceeds cap (≤4 issues); next wave after Cluster 1 merges
  #30 — in-flight area (src/api owned by active worktree issue-27-…)
```

The `→ Phase 2 will provision` line is a forward hint only (documents intent; harmless now).

Empty states are explicit and friendly: "no approved simple-track issues to group" (none eligible); when all
eligible issues are disjoint, the Clusters section is empty and everything lands under Singletons (i.e.,
`clusters` degrades to `issue next`'s wave minus complex items).

**Activity (the only write):**
```sql
INSERT INTO activity(worktree,wtype,event,detail)
VALUES('orchestrator','issue','clusters','<C> clusters, <I> grouped issues, <D> deferred');
```
so `monitor`/`status` reflect that a grouping proposal was produced.

## Error handling / edge cases

- **No eligible issues / a single eligible issue** → no clusters; friendly message and (if any) the singleton
  list. Never errors.
- **All eligible issues disjoint** → all singletons (graceful degrade to `issue next` minus complex).
- **`MaxIssues`/`MaxFiles` ≤ 0** → guarded to the defaults (4/8) with a one-line notice.
- **`depends-on` to a non-eligible issue** → not a grouping edge; emitted as an advisory cross-wave note.
- **Finding with empty `scope`** → only area-matchable (no crash on a NULL/empty `LIKE`).
- **Issue owning a path that is partly in-flight** → the whole issue defers (in-flight area), matching
  `issue next` (any claimed owned path defers the issue).
- **Issue with `track='simple'` but `review_status!='approved'`** → not eligible (the approval gate is the
  spine); it does not appear, consistent with the hard gate.

## Testing

Pester, in `review-coverage.Tests.ps1` (seed a temp DB, assert rendered output and row state):
- shares-a-file → grouped; fully disjoint → separate singletons.
- `complex` / `NULL`-track issue sharing a file → **not** grouped (appears as singleton).
- `depends-on` with no shared file → grouped; `related` with no shared file → **not** grouped.
- component over `MaxIssues` → cap-sized cluster + the remainder in Deferred ("exceeds cap").
- issue with an owned path claimed by an active worktree → Deferred (in-flight area).
- advisory sibling matched by **scope-path** and (separately) by **area**; `filed`/`completed`/`dismissed`
  findings and non-`proposed` recs **excluded**.
- **read-only invariant:** after `clusters`, no row in `issue`/`issue_target`/`finding`/`recommendation`/
  `worktree` changed; exactly one new `activity` row exists.

## Rollout

- Pure addition to `review-coverage.ps1` (one new sub-command + two optional params) plus its Pester tests.
  **No schema migration**, so existing hubs need no `init` re-run for Phase 1.
- `issue next` and every other command are untouched; the feature is opt-in by invoking `issue clusters`.
- Documentation: a short `CLAUDE.md` note that `issue clusters` is the grouped-wave companion to `issue next`
  (full batching-workflow docs land with Phase 2, when grouping becomes provisionable end-to-end).

## Open questions / future (Phase 2 hooks)

- **Persisting a chosen cluster.** Phase 2 provisioning could take an ad-hoc `-Issues 12,15,19`, or `clusters`
  could persist proposed clusters (a small `cluster`/`cluster_member` table) so a wave has a stable id. Decide
  in the Phase 2 spec; Phase 1 deliberately stays computation-only.
- **Soft overlap (same directory) as a grouping hint** — currently a non-blocking note in `issue show`; could
  become a weak grouping edge if hard-path overlap proves too sparse.
- **Cap tuning from field data** — 4 issues / 8 files are starting defaults; revisit once real grouped PRs are
  measured against reviewability.
- **Sibling precision** — if free-text `scope` matching proves too noisy/weak, Phase 2+ could add structured
  paths to findings/recs (a `finding_target` table mirroring `issue_target`).
- **Cross-wave `depends-on` sequencing** — surfacing is enough for Phase 1; later the selector could order
  waves so a dependency's wave is scheduled before its dependents'.
