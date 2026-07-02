# Batches & Sets (Plan-and-Fire Waves) — Phase 3 Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

**Scope:** This is **Phase 3** of the issue-grouping line.
[Phase 1](2026-06-29-issue-grouping-phase1-design.md) shipped a read-only `issue clusters` selector that
**proposes** grouped waves. [Phase 2](2026-06-29-issue-grouping-phase2-design.md) made a proposed cluster
**actionable** — `new-worktree.ps1 -Issues N,M,…` provisions one worktree owning several issues (via the
`worktree_issue` link), and one PR closes them all. Both phases left the **wave itself ephemeral**: Phase 2's
"Open questions" explicitly deferred a *persisted, referenceable wave id* ("for dashboards or re-running a
wave"). Phase 3 fills that gap. It formalizes a **batch** — a persisted collection of worktree sessions — and
makes it **plan-and-fire**: compose the whole wave from the existing selector, preview it, and fire the entire
fleet in one command, then monitor / merge / visualize it as a unit.

## Vocabulary (used precisely throughout)

- **Set** — the issue-group owned by **one** worktree session. Already modeled by Phase 2: a *singleton* set is
  one issue (`worktree.issue`), a *cluster* set is N issues (`worktree.issue` = lowest member + one
  `worktree_issue` row per member). **Phase 3 adds no `set` table** — a set *is* a worktree's membership.
- **Batch** — a **named, persisted collection of worktree sessions** fired together as one wave. This is the
  net-new tier (a new `batch` table + a `worktree.batch` link).
- So the hierarchy is **batch → worktrees (sets) → issues**. A batch groups worktrees; a worktree groups issues.

## Problem

The overlap-aware wave is computed but never persisted or fired as a unit:

- **The wave is ephemeral.** `Get-IssueClusterPlan` (behind `issue clusters`) and `issue next` compute an
  excellent file-disjoint wave — clusters, singletons, deferrals, advisory siblings — but the output is
  **printed and thrown away**. To act on a 6-set wave the orchestrator hand-copies numbers into six separate
  `new-worktree.ps1` invocations, runs six `register` commands, launches six windows, and tracks the group only
  in its own head. No single "fire this wave" action exists.
- **No batch tier in the ledger.** cwh's `worktree` table has no `batch` column and there is no `batch` entity
  (connect has one; cwh never got it). So there is no stable id for a wave, no batch-level monitoring, and no
  batch rollup at merge — the orchestrator cannot even ask "what did wave 20 contain / how far along is it?".
- **The engine isn't reusable from a driver.** `Get-IssueClusterPlan` returns structured data, but it lives
  inside `review-coverage.ps1` and is only reachable through the `issue clusters` command's `Write-Host`
  output — a provisioning driver can't call it without duplicating the 140-line algorithm.

Net: the hub can *see* a great wave but must fire it one set at a time, with no durable record of the wave and
no way to watch or report it as a whole. That is slow and error-prone — exactly the friction Phase 3 removes.

## Goal

Make a wave a first-class, fireable, trackable object. Specifically:

1. **A `batch` tier** in the ledger — a persisted collection of worktree sessions (`batch` table +
   `worktree.batch` link), mirroring connect's proven shape.
2. **`new-batch.ps1`** — the plan-and-fire driver: compute the wave (reusing `Get-IssueClusterPlan`) → **terminal
   preview** (read-only, the default) → **fire on confirm**: create the batch, provision each set via the
   existing `new-worktree.ps1 -Issue`/`-Issues`, `register` each with `-Batch`, and launch each window through
   the windowed wrapper with the right seed prompt.
3. **Reuse, don't rebuild** — extract the composer engine into a shared lib dot-sourced by both
   `review-coverage.ps1` and `new-batch.ps1`, so there is exactly one implementation of the overlap logic.
4. **`batch set|show|list`** + **`register -Batch`** + **batch grouping in `monitor`** — the ledger CRUD and the
   live monitor view.
5. **Batch-aware read surfaces** — a **Batch entity/view** in `ledger-explorer.ps1` (drawer traverses
   batch → worktrees → member issues), a **batch column** in `ledger-to-html.ps1`, and a **batch rollup** in the
   merge report.
6. **Docs** — a "Batches (plan-and-fire waves)" section + cheatsheet + directory entry in `CLAUDE.md`, and a
   one-line batch note in `WORKTREE.md`.

## Chosen approach (settled in brainstorming)

- **Plan-and-fire, not tag-as-you-go.** Compose the *whole* wave up front and fire it as a unit — the batch
  exists to launch and track a fleet, not merely to label worktrees after the fact.
- **Seed from the selector, then edit; terminal preview, fire on confirm.** The composer drafts the sets from
  `Get-IssueClusterPlan`, prints them, and fires on confirmation. Because firing is confirmed synchronously,
  **there is no persisted `planned` limbo state and no plan-file** — worktrees are born live at fire. "Editing"
  the draft is done with **filter flags** on the preview (`-Exclude`, `-Only`, `-MaxSets`, cluster caps): re-run
  the preview until the wave looks right, then `-Fire`.
- **Set == `worktree_issue` (Phase 2), not a new table.** The only net-new entity is the **batch**. Chosen over a
  `set`/`set_member` table for the same reason Phase 2 chose ephemeral clusters: the durable per-set state is
  already tied to a *real* worktree (nothing new to rot), and it keeps `git worktree list` the source of truth.
- **Mirror connect's `batch` table verbatim** (`id, label, status, notes, timestamps`) — battle-tested shape,
  and it keeps the two hubs' ledgers convergent on this tier.
- **Full v1** — schema, engine extraction, driver, ledger CRUD, monitor, **both** HTML surfaces, merge rollup,
  and docs, in one cycle (user-selected scope).

## Non-goals (YAGNI) — Phase 3

- **No `set`/`set_member` table and no `planned` worktree status.** Fire-on-confirm makes a pre-provision limbo
  state unnecessary; a set is a worktree's `worktree_issue` membership, unchanged from Phase 2.
- **No plan-file and no CLI mutation subcommands** (`batch move`/`split`/`drop`). Editing is filter-flag
  re-preview, per the chosen fast path. Reconsider only if hand-authoring waves becomes common.
- **The selector algorithms are unchanged.** `Get-IssueClusterPlan` and `issue next` keep their exact behavior;
  the only change is **extracting** the engine to a shared lib (behavior-preserving, guarded by a
  characterization test). No re-tuning of eligibility/graph/caps.
- **No new GitHub auto-actions.** Firing never files or closes issues; the approval gate is reused, not
  relaxed; solvers still never auto-merge or apply migrations; the only issue closure remains GitHub's own
  `Fixes #N`-on-merge.
- **No auto-minting a batch from `issue next`.** A batch is created explicitly by `new-batch.ps1` (or
  `batch set`). Auto-mint is a future hook.
- **No re-run / clone / template of a batch, and no auto-derived batch status.** Status is an explicit field the
  orchestrator sets (connect's model); `show`/`list` display a derived done/total count for visibility only.
- **No backfill.** Existing worktrees keep `batch = NULL`; nothing is migrated into batches.
- **No headless launching, ever.** Every session in a fired batch opens through the windowed wrapper
  (Critical rule #7); `new-batch.ps1` never calls `claude --print`.

## Constraints (these shape the design)

- **Backward compatible; idempotent, non-destructive migration.** `batch` is added via `CREATE TABLE IF NOT
  EXISTS`; `worktree.batch` is added via the **same idempotent ADD-COLUMN migration loop `init` already runs**
  for the verify columns (`review-coverage.ps1` ~line 318 — `PRAGMA table_info` check, then `ALTER TABLE … ADD
  COLUMN`). Existing hubs re-run `.\review-coverage.ps1 init` once (the documented upgrade path). Worktrees with
  `batch = NULL` behave exactly as today.
- **One engine definition, used everywhere.** After extraction, `issue clusters` and `new-batch.ps1`'s preview
  call the *same* `Get-IssueClusterPlan` — they can never disagree about the wave.
- **Preview is non-interactive; fire is guarded.** The default (preview) writes nothing and needs no TTY, so the
  orchestrator can run it and show the user. `-Fire` provisions; it requires either an interactive `Read-Host`
  "y" **or** `-Yes` (scripted). Safety rails: `-MaxSets` fleet-width cap (with an explicit default), the
  existing hard approval gate reused per set (never provision an unapproved issue; `-SkipReview` override only),
  and windowed-wrapper-only launch.
- **Delegate, don't duplicate.** `new-batch.ps1` shells out to the existing `new-worktree.ps1` (provisioning +
  briefs + env + install + gate) and `review-coverage.ps1` (`batch set`, `register -Batch`); it owns only the
  compose/preview/orchestrate glue. No re-implementation of provisioning.
- **PowerShell/sqlite plumbing** (from Lessons): `Exec`/`Query`/`Scalar` + the `q` SQL-escaper; check
  `$LASTEXITCODE` after native `git`/`gh`/`sqlite3`; pass any comma-bearing native-flag value as **one quoted
  token**; `Invoke-Git` for git exit codes; the `.git` pointer / launcher-spacing rules are untouched here.
- **Match existing UX.** Colored `Write-Host` for the driver + CLI output; the shared `format-report.ps1`
  box-table for the batch report; the HTML surfaces stay **client-rendered** and are validated by exercising the
  embedded JS in node + a headless browser (not by string-matching static HTML).

## Architecture overview

Twelve units, each independently understandable/testable:

| # | Unit | Responsibility | Where |
|---|------|----------------|-------|
| 1 | `batch` schema + `worktree.batch` migration | the batch table, the worktree link column, indexes | `review-coverage.ps1` `init` |
| 2 | Engine extraction | move `q` + `ActiveMemberIssuesSql` + `Get-IssueClusterPlan` to a shared lib dot-sourced by both callers | new `ledger-lib.ps1`; `review-coverage.ps1` |
| 3 | `batch set\|show\|list` | ledger CRUD for batches (mirror connect) + `show` traverses to member issues | `review-coverage.ps1` `batch` verb |
| 4 | `register -Batch` | stamp `worktree.batch` + activity event | `review-coverage.ps1` `register` |
| 5 | `monitor` batch grouping | group active worktrees under their batch; batch header + done/total | `review-coverage.ps1` `monitor` |
| 6 | `new-batch.ps1` — compose + preview | run engine → render sets (issues/paths/gate+overlap warnings/siblings); dry-run default; filter flags | `new-batch.ps1` |
| 7 | `new-batch.ps1` — fire | create batch → per-set `new-worktree.ps1` + `register -Batch` → launch windowed wrapper + seed | `new-batch.ps1` |
| 8 | Batch lifecycle + merge rollup | `in-process→merged→retired\|aborted`; batch box-table at merge | `CLAUDE.md` runbook + `batch set` |
| 9 | Explorer Batch view | re-add the batch entity + drawer traversal batch→worktrees→member issues | `ledger-explorer.ps1` |
| 10 | Dashboard batch column | batch column/section on the worktree/open-items view | `ledger-to-html.ps1` |
| 11 | Docs | Batches section + cheatsheet + dir entry; WORKTREE.md batch note | `CLAUDE.md`, `WORKTREE.md` |
| 12 | Tests | schema/migration/register-batch/monitor/engine-parity + `new-batch` preview helpers | `review-coverage.Tests.ps1` (+ helpers) |

## 1. `batch` schema + `worktree.batch` migration

Add to the `init` schema block (idempotent), mirroring connect:

```sql
CREATE TABLE IF NOT EXISTS batch(
  id INTEGER PRIMARY KEY,                          -- the batch number (auto-assigned by new-batch.ps1; or explicit)
  label TEXT, status TEXT DEFAULT 'in-process',    -- in-process -> merged -> retired | aborted
  notes TEXT,                                      -- plan + results: anchors, migrations carried, what dropped/deferred
  created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
CREATE INDEX IF NOT EXISTS ix_worktree_batch ON worktree(batch);
```

`worktree.batch` is a **new column on an existing table**, so `CREATE TABLE IF NOT EXISTS` won't add it. Extend
the existing ADD-COLUMN migration (the loop at ~line 318 that adds verify columns): after a `PRAGMA
table_info(worktree)` check, `ALTER TABLE worktree ADD COLUMN batch INTEGER;` when absent. Existing hubs run
`init` once. `batch` NULL = not in a batch (every current worktree), fully back-compatible.

## 2. Engine extraction → `ledger-lib.ps1`

Move three self-contained, already-parameterized helpers out of `review-coverage.ps1` into a new
`ledger-lib.ps1`, dot-sourced by both `review-coverage.ps1` and `new-batch.ps1`:

- `q($s)` — the SQL single-quote escaper (pure).
- `ActiveMemberIssuesSql($ActiveStatuses)` — returns the membership-union SQL (pure string builder).
- `Get-IssueClusterPlan($Db, $MaxI, $MaxF)` — the read-only wave engine (takes `$Db` explicitly; returns
  `Clusters`/`Singletons`/`NotGrouped`/`DeferOverCap`/`DeferInFlight`/`Meta`/`OwnPaths`).

The script-scoped `Exec`/`Query`/`Scalar` (which close over `$db`) **stay in `review-coverage.ps1`** —
`new-batch.ps1` performs no direct writes (it delegates all ledger writes to `review-coverage.ps1`), and its
one read is `Get-IssueClusterPlan`. Extraction is **behavior-preserving**: `review-coverage.ps1` dot-sources
the lib at the top and its call sites are unchanged. A characterization test (§12) pins parity.

## 3. `batch set | show | list`

Add a `batch` verb to `review-coverage.ps1`, mirroring connect:

- **`batch set -Id N [-Title label] [-Status in-process|merged|retired|aborted] [-Note '…']`** — upsert
  (`INSERT … ON CONFLICT(id) DO UPDATE`), stamp `updated_at`, log an `activity('orchestrator','batch',<status>,'batch N')`.
  Used by `new-batch.ps1` at fire and by the merge runbook for lifecycle transitions.
- **`batch show -Id N`** — the batch row + notes, then **its worktrees** (`WHERE batch=N`), and for each
  worktree its **member issues** via `worktree_issue` (the batch→worktree→issue traversal — richer than
  connect, whose worktrees are single-issue). This is the data source for the merge rollup box-table.
- **`batch list [-N k]`** — recent batches with derived `sets` (worktree count) and `done`
  (merged/retired count) so progress is visible at a glance.

Batch id: `new-batch.ps1` auto-assigns `SELECT COALESCE(MAX(id),0)+1 FROM batch` unless `-Id` is given;
`batch set` requires explicit `-Id` (parity with connect, and how lifecycle updates target a batch).

## 4. `register -Batch`

Add an optional `-Batch N` to the existing `register` verb. When present, include `batch=N` in the
worktree upsert (INSERT column + `ON CONFLICT … DO UPDATE SET batch=excluded.batch`) and log the batch on the
register activity row. Composes with both `-Issue` (singleton set) and `-Issues` (cluster set) from Phase 2 —
`new-batch.ps1` calls exactly one `register` per set with the right issue arg **plus** `-Batch`.

## 5. `monitor` batch awareness

`monitor` gains a `batch` column on each worktree row (`COALESCE(batch,'') AS batch`) and a new "Open batches"
summary section (`id · label · sets · done` for `status='in-process'` batches), so a fired wave is visible at a
glance. Purely presentational; the passthrough `Query` helper is kept (no bespoke grouped renderer for v1).

## 6. `new-batch.ps1` — compose + preview (the default, read-only)

The driver. Dot-sources `hub-config.ps1` (`$Hub`/`$HubConfig`) and `ledger-lib.ps1` (the engine).

- **Compute the wave:** call `Get-IssueClusterPlan $db $MaxIssues $MaxFiles`. Each **cluster → a multi-issue
  set**, each **singleton → a solo set**, in the engine's priority order.
- **Filter flags (the "edit" mechanism):** `-Exclude 105,107` (drop issues), `-Only 101,103,104` (restrict to
  these), `-MaxSets k` (cap the number of sets fired; excess sets listed as "deferred to next batch"),
  `-MaxIssues`/`-MaxFiles` (passed straight to the engine's caps). Re-run the preview with different flags until
  the wave looks right.
- **Render the preview** (colored `Write-Host`): a header (proposed batch id, set count, total issues), then per
  set — set index, worktree name it *will* get (`issue-<N>-<slug>` or `cluster-<lowest>-<slug>`), its issues
  (number · origin · severity · title), owned paths, and any **advisory siblings** (proposed findings/recs the
  engine matched). Then a warnings block: any member **not `approved`** (blocks fire), any member already owned
  by an **active** worktree (double-claim — advisory), and the engine's `NotGrouped`/deferrals.
- **Read-only:** the default run writes nothing to the ledger, disk, or GitHub, and exits 0 — safe for the
  orchestrator to run and paste back to the user.

## 7. `new-batch.ps1` — fire (provision + register + launch)

On **`-Fire`** (guarded by interactive `Read-Host` "y" unless `-Yes`):

1. **Gate:** re-validate that every member of every set is `review_status='approved'` (unless `-SkipReview`);
   abort listing offenders + remediation if not. Enforce `-MaxSets`.
2. **Create the batch:** `review-coverage.ps1 batch set -Id <auto> -Status in-process [-Title <label>]`.
3. **Per set** (each independently; a failure is reported and skipped, not rolled back — sibling sets are
   independent worktrees):
   - **Provision** via the existing script — singleton: `new-worktree.ps1 -Issue N -Install`; cluster:
     `new-worktree.ps1 -Issues N,M,… -Install`. This reuses Phase 2's gate, `ISSUE.md`/`ISSUES.md` briefs, env
     copy, and install — no duplication.
   - **Register:** `review-coverage.ps1 register -Worktree <folder> -WType solver -Issue/-Issues … -Branch <br>
     -Batch <id>`.
   - **Launch** the window through the windowed wrapper (the generated per-worktree launcher; one `Start-Process
     pwsh … -File <launcher>` per set, following the Lessons launcher-spacing rule), seeded with the canonical
     **solver** prompt (singleton) or **grouped-wave** prompt (cluster) from `CLAUDE.md`, identity placeholders
     filled. Sets are launched with a small stagger to avoid Windows Terminal races.
4. **Summarize:** print which sets fired (worktree · issues · branch), which were skipped/deferred, and the
   batch id; remind the orchestrator that `monitor` now groups them and how to merge/roll-up.

`-DryRun` (alias of the default preview) and `-Fire`/`-Yes` are the only mode flags; everything else is a
filter or a cap.

## 8. Batch lifecycle + merge rollup

- **Lifecycle:** `in-process` (set at fire) → `merged` (all sets merged) → `retired` (all torn down) |
  `aborted` (abandoned). Transitions are explicit `batch set -Id N -Status …` calls in the merge runbook; status
  is **not** auto-derived (connect's model), but `show`/`list` display the derived done/total so the orchestrator
  knows when to flip it.
- **Merge rollup:** extend the `CLAUDE.md` "Merging a finished PR" runbook. Each member PR still merges + reports
  per-PR as today (grouped-wave PRs already close N members via `Fixes #`). When the **last** member of a batch
  merges, flip the batch to `merged` and render a **batch box-table** with `format-report.ps1`, fed by `batch
  show -Id N`: one row per set (worktree · issues · PR · merge state), plus migrations applied across the batch
  and any dropped/deferred members. Then `retired` after teardown (`retire-worktree.ps1 -Name cluster-*`/`issue-*`).

## 9. Explorer Batch view (`ledger-explorer.ps1`)

Re-add the **Batch** entity removed last session (cwh had no batch table then; now it does), shaped for cwh:

- New `qBatches` query (all `batch` columns + derived `sets`/`done` counts); add `batches` to `dataJson`, the
  `IX` index maps, and the `ENTITIES`/`ORDER` lists; a sidebar view with live open-count (non-retired batches).
- **Relationship maps:** `wtByBatch` (worktrees grouped by `batch`); the batch drawer's **Connections** block
  traverses **batch → its worktrees → each worktree's member issues** (reusing the existing `memberIssuesByWt`
  union from the explorer's worktree drawer) — the two-hop traversal that is richer than connect's single-issue
  batches. The worktree drawer gains a "Batch" chip linking back up.
- Validate by exercising the embedded JS in node (relationship assertions) + a headless browser DOM check, per
  the client-rendered-HTML rule — never by string-matching the static file.

## 10. Dashboard batch column (`ledger-to-html.ps1`)

Add a **batch** column to the open-worktrees section (and/or a small "Open batches" table) showing `batch id ·
label · sets · done`, with the worktree rows linking to their batch. Same client-rendered validation approach.

## 11. Docs

- **`CLAUDE.md`:** a new "**Batches (plan-and-fire waves)**" subsection under the issue-lane / provisioning area
  — the batch→sets→issues model, the `new-batch.ps1` preview→fire workflow, the safety rails, and the
  merge-rollup step; cheatsheet lines for `new-batch.ps1` + `batch set|show|list` + `register -Batch`; and a
  `new-batch.ps1` entry + a `ledger-lib.ps1` entry in the directory-structure block.
- **`WORKTREE.md`:** one line noting a worktree may belong to a batch (grouping only — the grouped-wave/set rules
  from Phase 2 already cover multi-issue ownership; nothing else changes for the solver).

## Error handling / edge cases

- **Empty wave** (nothing `approved`/eligible) → preview says so and fire is a no-op.
- **A member not `approved`** → preview flags it; fire aborts naming offenders + remediation (`issue sync` →
  review → `issue approve`), or `-SkipReview`.
- **Fleet exceeds `-MaxSets`** → fire only the top-k sets; the rest are printed as "deferred to a next batch".
- **A set's provisioning fails mid-fire** (git/gh/install error) → report it, continue with the remaining sets;
  the batch stays `in-process` with the sets that did fire. Re-run `new-batch.ps1 -Fire -Exclude <done issues>`
  to add the rest, or fix and re-provision that set with `new-worktree.ps1` directly.
- **A member already owned by an active worktree** (double-claim) → loud advisory in preview; proceeds on fire
  (orchestrator's call), consistent with Phase 2's non-blocking overlap stance.
- **Non-interactive `-Fire` without `-Yes`** → refuse with a clear message (avoids a hung `Read-Host`); the
  orchestrator path is preview → `-Fire -Yes`.
- **Batch id collision** → avoided by `MAX(id)+1` auto-assign; explicit `-Id` upserts (connect semantics).
- **Engine extraction regression** → caught by the parity characterization test (§12) before anything ships.
- **Existing worktrees / ungrouped hubs** → `batch = NULL`; `monitor`/explorer/dashboard render exactly as today.

## Testing

Pester in `review-coverage.Tests.ps1` (seed a temp DB; assert row state + rendered output), run via the saved
module at `C:\mydev\pester-modules`:

- **Schema/migration:** `init` creates `batch`; the ADD-COLUMN migration adds `worktree.batch` to a
  pre-existing worktree table; both are idempotent (re-run `init`, no error, no dup, existing rows intact with
  `batch` NULL).
- **Engine parity (guards the extraction):** a characterization test seeds a known issue graph and asserts
  `Get-IssueClusterPlan` returns the same clusters/singletons/deferrals/siblings after the move to
  `ledger-lib.ps1` as a captured baseline — proving extraction changed no behavior.
- **`register -Batch`** stamps `worktree.batch` (and composes with `-Issue` and `-Issues`); omitting it leaves
  `batch` NULL.
- **`batch set|show|list`:** `set` upserts + logs activity; `show` returns the worktrees and their member
  issues; `list` derives correct `sets`/`done` counts.
- **`monitor`** groups active worktrees under batch headers with the right done/total, and renders ungrouped
  worktrees unchanged when no batch is present.
- **`new-batch.ps1` preview logic** (factor into testable helpers): sets derived from a
  `Get-IssueClusterPlan` result; `-Exclude`/`-Only`/`-MaxSets` shape the set list correctly; unapproved-member
  detection; **dry-run writes nothing** (read-only invariant: no ledger/disk/GitHub change; process exits 0).
- **HTML surfaces:** node relationship assertions (batch present in `DATA`; `wtByBatch` groups correctly;
  batch→worktree→issue traversal resolves) + a headless-browser render of a Batch drawer, per the
  client-rendered rule. The static HTML is **not** string-matched.

Provisioning/launch (`git worktree add`, `Start-Process`) is integration-level; the unit-testable logic —
set derivation, filter application, gate decision, worktree-name computation, and the **exact command list the
fire step would run** (the per-set `new-worktree.ps1 -Issue`/`-Issues`, `register … -Batch`, and `batch set`)
— is factored into pure helpers and asserted directly, so the fire plan is verified without launching any
window.

## Rollout

- **Additive:** one table + one column (idempotent migration) + one `batch` verb + one `register` param + one
  `monitor` grouping + one new driver (`new-batch.ps1`) + one lib extraction (`ledger-lib.ps1`) + two HTML
  columns/views + doc/prompt edits + tests. No destructive migration; existing hubs run `init` once.
- **Behavior-compatible:** the selector algorithms are untouched (extraction is characterization-tested);
  ungrouped worktrees and the single/grouped provisioning flows are unchanged. The feature is **opt-in** by
  running `new-batch.ps1`; hubs that keep provisioning set-by-set are unaffected.
- **Sequencing dependency:** the explorer Batch view (§9) edits `ledger-explorer.ps1`, which currently exists as
  **uncommitted work from the prior session**. Land or fold in that file first so the batch view applies to a
  committed base (raised for the user at the spec-review gate).
- **`update-hub.ps1`:** the two new tracked files (`new-batch.ps1`, `ledger-lib.ps1`) join the overlay
  automatically once committed (it enumerates via `git ls-files`).

## Open questions / future (Phase 4 hooks)

- **Auto-mint a batch from `issue next`.** Let the disjoint-singleton selector optionally persist its wave as a
  batch directly (Phase 3 keeps batch creation in `new-batch.ps1`).
- **Auto-derived batch status.** Flip `in-process → merged` automatically when the last set merges, instead of
  an explicit `batch set` (kept manual now for parity + predictability).
- **Re-run / clone / template a batch.** A stable batch id makes "re-fire this wave" or "a standard weekly
  hardening batch" possible later.
- **Cross-batch / cross-set `depends-on` sequencing.** Order batches (or sets within a batch) so a dependency's
  work lands before its dependents' — carried forward from Phase 1/2.
- **Capacity-aware fleet sizing.** Choose `-MaxSets` from machine capacity (CPU/RAM/open windows) instead of a
  fixed default.
- **CLI wave editing** (`batch move`/`split`/`drop`) or a plan-file, if hand-authoring waves outgrows the
  filter-flag approach.
