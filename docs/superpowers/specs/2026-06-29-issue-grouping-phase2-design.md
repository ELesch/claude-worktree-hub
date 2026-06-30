# Issue Grouping (Overlap Clusters) — Phase 2 Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

**Scope:** This is **Phase 2** of the two-phase issue-grouping feature. [Phase 1](2026-06-29-issue-grouping-phase1-design.md)
shipped a read-only `issue clusters` selector that **proposes** grouped waves (connected components of
approved · simple-track · file-overlapping issues, with advisory same-area findings/recs). Phase 2 makes a
proposed cluster **actionable end-to-end**: multi-issue provisioning (`new-worktree.ps1 -Issues N,M,…`), a
grouped seed prompt, and grouped merge/resolve that turn one cluster into **one worktree → one PR closing
several issues**. It also folds in the three sibling-matching precision fixes surfaced in Phase 1 review.

## Problem

Phase 1 proposes grouped waves but nothing can act on them. The `clusters` command literally prints
`→ Phase 2 will provision: new-worktree.ps1 -Issues 12,15,19`, but:

- **No multi-issue provisioning exists.** `new-worktree.ps1` is strictly one issue → one `issue-<N>-<slug>`
  worktree, gated on that one issue, with one `ISSUE.md`.
- **The ledger can't represent a multi-issue worktree.** A worktree's issue link is the single
  `worktree.issue` column, and **four** read-paths join on it — `clusters` eligibility + in-flight,
  `issue next` eligibility + in-flight — plus `monitor`'s owns-count and `resolve`. A grouped worktree that
  recorded only one of its issues would **under-claim** the others' files, because a cluster is a
  *transitively* connected component (12–15 share file A, 15–19 share file B, but 12 and 19 may share
  nothing). A second worktree could then grab an issue colliding on file B — the exact collision grouping
  exists to prevent.
- **No grouped brief or seed.** There is no way to drop N issues' briefs into one worktree, and no canonical
  prompt telling the agent to close N issues in one PR.
- **Merge closes one issue at a time.** The merge runbook and report assume a single `Fixes #N`.

So the grouping loop is half-open: the orchestrator can *see* a good wave but must still provision it as
disjoint singletons, discarding the very signal Phase 1 surfaced.

## Goal

Close the loop. Specifically:

1. **`new-worktree.ps1 -Issues 12,15,19`** — provision **one** worktree for an approved cluster.
2. **A `worktree_issue` membership link** so the whole ledger understands a worktree can own several issues —
   in-flight detection, eligibility, `monitor`, and resolve all reason over the full membership.
3. **A grouped seed prompt** — one branch, **one PR closing all members** (`Fixes #12` / `Fixes #15` /
   `Fixes #19`), a wave-level product-necessity gate that judges each member, and the cluster's advisory
   siblings riding along as opportunistic fold-ins.
4. **Grouped merge/resolve** — merge the single PR (GitHub auto-closes all members), a merge report that lists
   the wave, and ledger close-out across the membership.
5. **Sibling-precision hardening** — fix the three Phase 1 matcher bugs so the advisory siblings the grouped
   seed surfaces are trustworthy.

## Chosen approach (settled in brainstorming)

- **Full vertical** — provisioning **and** grouped seed **and** grouped merge/resolve (not a half-step).
- **Approach A: ad-hoc `-Issues` + a thin `worktree_issue` join table; the cluster stays ephemeral.** The
  orchestrator reads the `clusters` proposal and copies its numbers into `-Issues`; the **durable record is
  the worktree's membership**, not a persisted cluster entity. Chosen over a `cluster`/`cluster_member`
  table because the only new state is tied to a *real* worktree (nothing to rot), and it matches the hub's
  "selector proposes, human provisions, `git worktree list` is the source of truth" philosophy.
- **Fold in** the three sibling-precision fixes as a hardening section of this cycle.

## Non-goals (YAGNI) — Phase 2

- **No persisted cluster entity.** No `cluster`/`cluster_member` tables, no `-Cluster <id>`, no cluster
  lifecycle. A wave's identity *is* the set of issue numbers you pass to `-Issues` (Approach A). Reconsider
  only if a future phase needs a stable, referenceable wave id.
- **`issue next` is untouched.** The disjoint-singleton selector stays exactly as-is for maximum parallelism;
  `clusters` + `-Issues` are the grouped path **alongside** it.
- **No new GitHub auto-actions.** Provisioning never files or closes issues; the only issue closure is
  GitHub's own `Fixes #N`-on-merge; merge stays human-initiated; solvers still never auto-merge or apply
  migrations.
- **No change to the cluster algorithm.** Phase 1's eligibility/graph/caps compute is unchanged; only the
  advisory-sibling *matching precision* is hardened (§8).
- **No backfill.** Existing single-issue worktrees keep using `worktree.issue` alone; nothing is migrated.
- **No auto-register inside `new-worktree.ps1`.** Registration stays orchestrator-driven (as the single-issue
  flow is today); provisioning just prints the exact `register -Issues …` command.
- **Not grouping complex work.** Clusters are simple-track by Phase 1 construction. `-Issues` trusts the
  orchestrator's list (it came from `clusters`), but the wave-level necessity gate still judges each member.

## Constraints (these shape the design)

- **Backward compatible / no migration.** Every existing query and the single-issue flow keep working
  unchanged. The new table is idempotent; existing hubs re-run `init` once (the documented upgrade path for
  added tables). Single-issue worktrees write **no** `worktree_issue` rows.
- **One membership definition, used everywhere.** `Membership(W) = {W.issue if not null} ∪
  {worktree_issue.issue_number where worktree = W.name}`. Singles → `{N}`; grouped → the full set. Every
  "issues/paths owned by **active** worktrees" computation reads this union, so the two selectors and the
  monitor never disagree about what is in flight.
- **One PR per wave.** Never auto-merge; the agent opens one PR with one `Fixes #<N>` line per member. Solvers
  never apply DB migrations (unchanged hard rule).
- **Match existing UX.** Colored `Write-Host` for selector/CLI output; the shared `format-report.ps1`
  box-table for completion/merge reports.
- **PowerShell/sqlite plumbing** (from Lessons): the script's `Exec`/`Query`/`Scalar` helpers + `q`
  SQL-escaper; check `$LASTEXITCODE` on native git/gh/sqlite; pass any comma-bearing native-flag value as one
  quoted token; `Invoke-Git` wrapper for git exit codes.
- **Force-include briefs.** Every issue brief reaches the agent via an `@`-mention (never "go read"), as the
  single-issue flow already guarantees.

## Architecture overview

Nine units, each independently understandable/testable:

| # | Unit | Responsibility | Where |
|---|------|----------------|-------|
| 1 | `worktree_issue` schema | the worktree→many-issues link + indexes | `review-coverage.ps1` `init` block |
| 2 | Unified membership | one "active member issues / claimed paths" definition; rewire the 4 read-paths + monitor | `Get-IssueClusterPlan`, `issue next`, `monitor` |
| 3 | `register -Issues` | write primary to `worktree.issue` + all members to `worktree_issue` | `register` verb |
| 4 | `-Issues` provisioning | parse/validate/gate-all-approved, naming, advisory overlap check, register hint | `new-worktree.ps1` |
| 5 | Grouped briefs | per-member `ISSUE-<N>.md` + `issue-<N>-assets\` + an `ISSUES.md` index | `hub-lib.ps1` `Save-IssueBundle` + new helper |
| 6 | Grouped seed + rules | canonical grouped solver prompt + a WORKTREE.md "Grouped waves" subsection | `CLAUDE.md`, `WORKTREE.md` |
| 7 | Grouped merge/resolve | one PR closes N; merge report lists the wave; ledger close-out over membership | `CLAUDE.md` merge runbook |
| 8 | Sibling-precision hardening | the 3 Phase-1 matcher fixes (+ optional invariant-test hardening) | `Get-IssueClusterPlan` |
| 9 | Tests | Pester for schema/membership/register/monitor/precision; testable provisioning helpers | `review-coverage.Tests.ps1` |

## 1. `worktree_issue` schema

Add to the `init` schema block (idempotent), beside `issue_target`:

```sql
CREATE TABLE IF NOT EXISTS worktree_issue(
  id INTEGER PRIMARY KEY,
  worktree TEXT NOT NULL,
  issue_number INTEGER NOT NULL,
  UNIQUE(worktree, issue_number));
CREATE INDEX IF NOT EXISTS ix_worktree_issue_wt   ON worktree_issue(worktree);
CREATE INDEX IF NOT EXISTS ix_worktree_issue_issue ON worktree_issue(issue_number);
```

No `ALTER` of existing tables, so the existing "add missing verify columns" migration loop is untouched.
Existing hubs run `.\review-coverage.ps1 init` once to create the table (idempotent; documented).

## 2. Unified membership (the rewire)

Define the membership of a worktree once and read it everywhere:

> **Membership(W)** = `{W.issue}` (when not null) ∪ `{wi.issue_number : worktree_issue wi where wi.worktree = W.name}`.

Single-issue worktrees have no `worktree_issue` rows, so `Membership = {W.issue}` — identical to today.

**Active member issues** (the set used for in-flight/eligibility) is `Membership(W)` unioned over every
worktree `W` whose `status IN ('registered','working','spec-gate','pr-open','blocked')` (the existing active
set). Concretely, the SQL subquery shared by all read-paths becomes:

```sql
SELECT issue FROM worktree WHERE status IN (<active>) AND issue IS NOT NULL
UNION
SELECT wi.issue_number FROM worktree_issue wi
  JOIN worktree w ON w.name = wi.worktree WHERE w.status IN (<active>)
```

**Claimed paths** = `issue_target.path` for those issue numbers with `ownership='owns'`. The four read-paths
switch from `JOIN worktree ON worktree.issue = …` to this union:

- `Get-IssueClusterPlan`: the `$claimed` in-flight-paths query **and** the eligibility exclusion
  (`number NOT IN (active member issues)`).
- `issue next`: the claimed-paths query **and** the candidate exclusion.

`monitor` updates too: the per-row `owns` count becomes **distinct owned paths across `Membership(W)`**
(not just `worktree.issue`), and the `issue` column displays the primary with a `+k` suffix when grouped
(e.g. `12 (+2)`), so a grouped worktree's true file footprint is visible at a glance.

## 3. `register -Issues`

Extend the `register` verb with an optional `-Issues` (comma list). When provided (grouped):

- Set `worktree.issue` = the **lowest** member number (the "primary", for display/back-compat).
- Insert one `worktree_issue` row per member (all of them, including the primary — `UNIQUE` + the union dedupe
  make the primary-in-both harmless).
- The existing single `-Issue N` path is unchanged (no `worktree_issue` rows written).

`new-worktree.ps1 -Issues` prints the exact `register -Worktree <folder> -WType solver -Issues 12,15,19
-Branch <br>` line for the orchestrator to run after launch.

## 4. `-Issues` provisioning (`new-worktree.ps1`)

Add `-Issues` (grouped mode; mutually exclusive with single `-Issue`):

- **Parse + dedupe + sort** the member list; require **≥2** distinct members (1 → direct the user to `-Issue`).
- **Gate (hard):** *every* member must be `review_status='approved'` in the ledger. Reuse the existing gate
  query per member; on failure, throw listing each non-approved member and the remediation commands (as the
  single-issue gate already does). `-SkipReview` bypasses (emergencies only), unchanged.
- **Overlap (advisory, non-blocking):** warn if the given members don't actually share any owned path (they
  may have been grouped deliberately); print the shared paths when they do. Never blocks — consistent with the
  hub's "scripts trust the human" stance and Phase 1's "soft overlap" treatment.
- **In-flight (advisory, non-blocking):** warn loudly if any member is already owned by an **active**
  worktree (Membership over active set) — that member is being double-claimed — but proceed; the orchestrator
  decides.
- **Naming:** folder `cluster-<lowest>-<slug>` (slug from the lowest member's title), branch
  `fix/cluster-<lowest>-<slug>`, suggested tab `#<lowest>+<k> <area>`. The `cluster-*` prefix is distinct from
  single `issue-<N>-*` and is a clean wildcard for `retire-worktree.ps1 -Name cluster-*`.
- **Briefs:** §5. **WORKTREE.md / experts / env / install:** copied exactly as the single-issue flow does.

## 5. Grouped briefs

Generalize `Save-IssueBundle` so it can write a non-default filename and asset subdir without changing the
single-issue call:

- Add optional `-FileName` (default `ISSUE.md`) and keep `-AssetsSubdir` (default `issue-assets`). The
  single-issue path uses the defaults — **byte-for-byte unchanged**.
- Grouped mode calls it **once per member**: `Save-IssueBundle -Issue 12 -FileName 'ISSUE-12.md'
  -AssetsSubdir 'issue-12-assets'`, etc. Per-member asset subdirs prevent image-name collisions
  (`img-1.png` across members).
- Then write a small **`ISSUES.md`** index: the wave's members (number · title · origin · severity), the
  shared owned paths (the cluster rationale), and the cluster's **advisory siblings** (proposed findings/recs)
  as an opportunistic fold-in list. This is the wave's cover sheet.
- **Git-exclude** the new patterns via `Add-HubExclude`: `/ISSUE-*.md`, `/ISSUES.md`, `/issue-*-assets/`
  (alongside the existing `/ISSUE.md`, `/issue-assets/`).

## 6. Grouped seed prompt + WORKTREE.md "Grouped waves" rules

The durable rules live in `WORKTREE.md`; the per-wave prompt stays thin.

- **WORKTREE.md gains a short "Grouped waves" subsection** (under §2/§6a) that states the four deltas from a
  single-issue solve: (a) you own **several** issues in one branch; (b) you open **one PR** whose body has
  **one `Fixes #<N>` line per member**; (c) the **stage-one product-necessity gate runs once for the wave**
  but **judges each member** — a member the persona flags as not-necessary is dropped/asked **individually**
  (the wave is **not** halted wholesale; user-origin members are never auto-HALTed, per the existing §6a
  calibration). *Dropping a member* = not implementing it in this wave, omitting its `Fixes #<N>` line, and
  surfacing it in the completion report for the user to close or re-triage — never silently skipped.
  (d) the cluster's **advisory siblings** (from `ISSUES.md`) may be folded in **if cheap and
  in-scope**, noting any you address in the PR — they stay `proposed` otherwise.
- **A canonical grouped solver prompt** in `CLAUDE.md` (beside the single-issue and complex prompts), filling
  `<MEMBERS>`/`<FOLDER>`/`<BRANCH>`/`<AREA>`:
  - `@WORKTREE.md @ISSUES.md @ISSUE-12.md @ISSUE-15.md @ISSUE-19.md` (force-include the index **and** every
    member brief).
  - Identity: "solver for a **grouped wave** of #12/#15/#19 (same area: `<AREA>`) — one branch, one PR closing
    all three."
  - Stage one: run the wave-level necessity gate (judge each member); route the persona per the dominant
    area/labels.
  - Implement each member's fix, scoped to the cluster's files; validate with `<verifyCmd>` + tests.
  - One PR, base `<defaultBranch>`, body with `Fixes #12` / `Fixes #15` / `Fixes #19` (each on its own line)
    and a `## Recommended follow-up issues` section as usual.
- **Grouped completion report** (the shared box-table, adapted): the `Issue` row becomes
  `Issues|#12,#15,#19 — <AREA>`; add a one-line **per-member** acceptance summary; `Necessity` carries the
  wave verdict + any per-member flags; everything else (Changes/Tests/Verify/PR/Status) as today.

## 7. Grouped merge / resolve

Extend the `CLAUDE.md` "Merging a finished PR" runbook with a grouped note:

- **Merge** the single PR (`gh pr merge <M> --squash --delete-branch`); the per-member `Fixes #<N>` lines make
  GitHub **auto-close every member** on merge.
- **Merge report** (one per PR): the `Issue #<N>` row becomes `Issues #12,#15,#19 (all auto-closed via Fixes)`;
  migrations handled exactly as today.
- **Ledger close-out:** `progress -Worktree <folder> -Status merged` then `retired` key off the **worktree
  name**, so they already work unchanged for grouped. The next `issue sync` flips the closed members to
  `closed`. `resolve -Id <finding> -Issue <N>` is per-finding and unchanged. The worktree's `worktree_issue`
  rows are inert once it leaves the active set (in-flight only considers active worktrees); retirement may
  leave them or delete them — leaving them is harmless and keeps history.

## 8. Sibling-precision hardening (the 3 Phase-1 matcher fixes)

In `Get-IssueClusterPlan`'s advisory-sibling block — each fix gets a red test first (TDD):

1. **`-like` wildcard escaping.** Path/area needles containing `[`…`]` (a `[wip]` label token, a Next.js
   `[id].tsx` path) are parsed as character classes by `-like`. Wrap every needle in
   `[System.Management.Automation.WildcardPattern]::Escape($n)` before the `-like "*$n*"` test, so needles
   match literally.
2. **Pipe-field consistency.** The two sibling `SELECT`s sanitize `title` (`replace(title,'|','/')`) but not
   `scope`/`topic`/`area`; a literal `|` in those shifts the `-split '\|', 5` parse. Sanitize them too:
   `replace(COALESCE(scope,''),'|','/')`, `replace(COALESCE(topic,''),'|','/')`,
   `replace(COALESCE(area,''),'|','/')`.
3. **Basename false-positives.** Common basenames (`index.ts`, `index.tsx`, `utils.ts`, `types.ts`, …) make an
   unrelated file produce a strong `[path]` tag. Keep a small generic-basename set; a **basename-only** match
   on a generic name is **demoted** to a weak `[path:base]` tag (still shown, ranked below real path/area
   hits) rather than counted as a strong path match. Full-path matches and non-generic basenames are
   unaffected.
4. *(Optional)* harden the read-only invariant test to also snapshot each issue's `review_status` and assert
   the total-`activity` delta is exactly the one expected row.

## Error handling / edge cases

- **`-Issues` with one (or zero) members** → not a wave; instruct the user to use `-Issue N`. No worktree
  created.
- **Duplicate / unsorted members** → deduped and sorted; primary = lowest.
- **A member not `approved`** → hard gate throws, naming every non-approved member + remediation (`issue sync`
  → review → `issue approve`), or `-SkipReview`.
- **Members don't overlap on any owned file** → advisory warning; proceeds (deliberate grouping allowed).
- **A member already owned by an active worktree** → loud advisory warning (double-claim); proceeds.
- **One member's brief fetch fails** (`gh`/image download) → warn and continue with the rest, as the
  single-issue bundle already does; the wave still provisions.
- **Image-name collisions across members** → prevented by per-member `issue-<N>-assets\` subdirs.
- **Grouped worktree retired before merge** → `worktree_issue` rows remain but, being inactive, are ignored by
  in-flight detection; the members return to `clusters`/`next` eligibility.
- **Existing single-issue worktrees** → no `worktree_issue` rows; membership = `{worktree.issue}`; behavior
  identical to pre-Phase-2.

## Testing

Pester in `review-coverage.Tests.ps1` (seed a temp DB; assert row state and rendered output):

- **Schema/`init`** creates `worktree_issue` and is idempotent (re-run `init`, no error, no dup).
- **`register -Issues 12,15,19`** sets `worktree.issue=12` and writes exactly the three `worktree_issue` rows;
  single `register -Issue 42` writes none.
- **In-flight union (the core correctness test):** a grouped worktree owning {12,15,19} causes both `clusters`
  and `issue next` to **defer** an approved issue that collides on issue 19's owned file — proving the
  transitive-component claim is honored (the bug Approach A exists to prevent).
- **Eligibility exclusion:** a member of an active grouped worktree is excluded from `clusters`/`next`
  candidates.
- **`monitor`** shows a grouped worktree's `owns` as the **distinct path count across all members** and the
  `issue` column as `12 (+2)`.
- **Sibling-precision:** (1) a `[wip]`/`[id]`-bearing needle matches literally (no char-class crash/miss);
  (2) a `|` in `scope`/`area` doesn't corrupt the parse; (3) a generic basename (`index.ts`) yields a weak
  `[path:base]` tag, not a strong `[path]` one; a non-generic basename still yields `[path]`.
- **Read-only invariant** (extended): after `clusters`, no row in
  `issue`/`issue_target`/`finding`/`recommendation`/`worktree`/`worktree_issue` changed; exactly one new
  `activity` row; (optional) `review_status` per issue unchanged.

Provisioning's `git worktree add` / `gh` steps are integration-level; factor the unit-testable logic — member
parsing, the all-approved gate decision, `cluster-<lowest>-<slug>` naming — into helper functions and test
those directly. The seed-prompt and merge changes are documentation edits (`WORKTREE.md`/`CLAUDE.md`),
reviewed rather than unit-tested.

## Rollout

- Pure additions: one table + indexes, one `register` param, one `new-worktree.ps1` mode, one `Save-IssueBundle`
  generalization + an `ISSUES.md` helper, doc/prompt edits, and tests. **No schema migration** of existing
  tables; existing hubs run `.\review-coverage.ps1 init` once to add `worktree_issue`.
- `issue next` and the Phase 1 `clusters` algorithm are behavior-compatible; the membership rewire is
  transparent to single-issue worktrees.
- The feature is opt-in by invoking `new-worktree.ps1 -Issues …`; nothing changes for hubs that keep
  provisioning singletons.

## Open questions / future (Phase 3 hooks)

- **Persisted clusters.** Still available later if a stable, referenceable wave id is ever needed (e.g. for
  dashboards or re-running a wave) — Approach A deliberately defers it.
- **Auto-register inside `new-worktree.ps1`.** Folding the `register -Issues` call into provisioning (for both
  single and grouped) would remove a manual step; left out now to keep registration orchestrator-driven and
  consistent across the codebase.
- **Splitting an over-cap component into sequenced waves.** Phase 1 defers over-cap members; a later phase
  could schedule them as a follow-on wave automatically once the first merges.
- **Cross-wave `depends-on` sequencing** (carried from Phase 1): order waves so a dependency's wave is
  scheduled before its dependents'.
- **Structured finding/rec paths** (a `finding_target` table mirroring `issue_target`) to make sibling
  matching exact rather than fuzzy — the durable fix beyond §8's precision hardening.
