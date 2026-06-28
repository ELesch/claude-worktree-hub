# Design — hub-findings channel: capturing prompt / memory / environment problems

**Date:** 2026-06-28
**Status:** Approved (design), pending implementation plan
**Topic:** Give worktree agents (and the orchestrator) a ledger channel to log problems with the hub's
own operating layer — prompts, config, helper scripts, memory, and environment assumptions — so they
get surfaced and fixed instead of silently papered over or lost.

---

## 1. Problem

Every existing ledger channel points **outward at the target repo** (`<owner/repo>`):

- **`finding`** — recon discoveries about the repo's code (proposed → verified → filed → completed).
- **`recommendation`** — solver out-of-scope follow-ups about the repo's code (proposed → filed as a GH
  issue / dismissed).
- **`issue`** — the GitHub-issue backlog of record.

But agents also hit a **different class of problem — defects in the hub's own operating layer**, not in
the code they were sent to fix. Examples:

- The session **assumes the wrong terminal** (defaults to bash when the hub is PowerShell, or runs a
  POSIX idiom that fails on Windows).
- The session **tries to use a tool / command the prompt implied was available** but isn't, or uses it
  wrong because the standing instructions were ambiguous.
- A **`hub.config.json` value is wrong** for the project (e.g. `packageManager`/`installCmd` mismatch),
  so the seeded workflow misfires.
- A **standing instruction in `WORKTREE.md` / `CLAUDE.md` / a seed prompt is unclear, stale, or
  incorrect**, mis-steering the agent.

These have **nowhere to go today**. They are not repo bugs, so filing them as `finding`/`recommendation`
→ GitHub issues on the target repo would be wrong and noisy. And the agent **cannot fix them itself**:
it is sandboxed to a worktree of the target repo and auto-mode soft-denies editing `.claude/*` and the
hub's own files. So the standing rule "**never paper over a problem — surface it**" (WORKTREE.md §1)
currently has **no channel** for this category. The knowledge evaporates when the worktree is retired.

The fix is a **dedicated channel that flows these findings *up* to the orchestrator** — the only actor
that owns the prompts, config, scripts, and memory and can actually change them.

## 2. Goal & success criteria

A worktree agent (or the orchestrator) that notices a hub/prompt/memory/environment problem can **log it
with one command**, and the orchestrator can **see it, fix the real artifact, and stamp it resolved** —
on the same triage cadence as every other ledger item, so it never rots.

Success =

- An agent can record a hub finding via `review-coverage.ps1 hubfind …` from inside its worktree (same
  call pattern, same permission surface as the `progress`/`recommend` calls it already makes).
- Open hub findings appear in `monitor` and in the `ledger-to-html.ps1` dashboard.
- The orchestrator can list them (`hub-findings`), fix the named artifact, and close them
  (`hub-resolve -Id N -Target … -Note …`) — recording **where** the fix landed and **what** changed.
- They are folded into the merge-time backlog sweep (CLAUDE.md §"Merging a finished PR" step 4) so they
  are triaged regularly, not left to accumulate.
- A hub finding **never** becomes a GitHub issue on the target repo.

## 3. Decisions (locked)

| Decision | Choice |
|---|---|
| Mechanism | **A dedicated channel in the SQLite coverage ledger** (a sibling to `finding`/`recommendation`), not a flat file or a convention-only protocol. |
| Schema shape | **A new `hubfinding` table** — *not* a reuse of `recommendation` with a flag. `recommendation`'s lifecycle is "→ GitHub issue on the repo"; a hub finding's lifecycle is "→ edit a hub artifact / write memory". Distinct lifecycles ⇒ distinct tables. |
| Name | **"hub finding"** — verb `hubfind`, table `hubfinding`, list `hub-findings`, close `hub-resolve` (parallels the existing nouns; `hub-resolve` does not collide with the finding-completing `resolve`). |
| Sources | **Both** worktree agents *and* the orchestrator (this session notices these too). The actor is the existing `-Worktree` field; the orchestrator logs with `-Worktree orchestrator`. |
| Fix destinations recorded | All four the channel must recognize: **prompt** (WORKTREE.md / CLAUDE.md / seed templates), **config** (`hub.config.json`), **script** (helper `.ps1`), **memory** (auto-memory files). Captured in a `target` column set at resolution. |
| New param surface | **Exactly one new param: `-Target`.** Everything else reuses existing params (`-Worktree`, `-Category`, `-Title`, `-Detail`, `-Severity`, `-Id`, `-Note`, `-Dismiss`, `-All`). |
| Resolution model | The tool **tracks**; the orchestrator **acts**. `hub-resolve` stamps status + records the target/note — it does **not** auto-edit hub files or auto-write memory (those are judgment edits the orchestrator makes by hand, exactly as `promote`/`file-rec` keep the GitHub action explicit). |

### Non-goals (YAGNI)

- **No GitHub issue creation** from this channel — ever. That is what `finding`/`recommendation` are for.
- **No auto-editing** of `WORKTREE.md`/`CLAUDE.md`/config/scripts and **no auto-writing** of memory by
  the tool. Resolution edits are made by the orchestrator, then stamped.
- **No new permission surface** for agents — they already run `review-coverage.ps1` for
  `progress`/`recommend`; `hubfind` is the same script.
- **No changes** to the recon/solver/issue workflows or any runtime hub behavior beyond adding the channel.
- **No new script file** — the channel lives inside the existing `review-coverage.ps1`.

## 4. Components

No new top-level script. The channel is added to existing files:

- **`review-coverage.ps1`** (changed) — the `hubfinding` table in `init`, the three verbs
  (`hubfind` / `hub-findings` / `hub-resolve`), the `-Target` param, and an open-count block in
  `monitor`.
- **`ledger-to-html.ps1`** (changed) — a fifth open-item section, "Hub findings".
- **`WORKTREE.md`** (changed) — a new section teaching agents to recognize and log hub findings, a row
  in the completion report (§4), and a line in record-to-ledger (§6).
- **`CLAUDE.md`** (changed) — the new verbs in the command list, the channel in the ledger/tables
  description, and the merge-time sweep (step 4).
- **`review-coverage.Tests.ps1`** (new) — a Pester lifecycle test against a temp DB.

## 5. Schema — the `hubfinding` table

Added to the `init` command's `CREATE TABLE IF NOT EXISTS` block (idempotent; existing hubs pick it up by
re-running `review-coverage.ps1 init`, which is safe to re-run):

```sql
CREATE TABLE IF NOT EXISTS hubfinding(
  id INTEGER PRIMARY KEY,
  source TEXT,                       -- worktree folder, or 'orchestrator'
  wtype TEXT,                        -- solver | recon | review | orchestrator
  category TEXT,                     -- env | tool | prompt | config | memory | other
  title TEXT NOT NULL,
  detail TEXT,
  severity TEXT,                     -- Low | Medium | High  (High = mis-instructs EVERY future worktree)
  status TEXT DEFAULT 'open',        -- open -> resolved | dismissed
  target TEXT,                       -- set at resolution: prompt | config | script | memory
  resolution TEXT,                   -- what was changed (free text)
  created_at TEXT DEFAULT (datetime('now')),
  resolved_at TEXT);
CREATE INDEX IF NOT EXISTS ix_hubfinding_status ON hubfinding(status);
```

Field rationale:

- **`source` / `wtype`** mirror how `activity`/`recommendation` record the actor, so `monitor` and the
  dashboard render hub findings the same way as everything else.
- **`category`** is the *kind* of defect (what surfaced). **`target`** is *where the fix landed* (set only
  at resolution). They are intentionally separate: e.g. a `category=env` finding ("assumed bash") may be
  fixed with `target=prompt` (clarify WORKTREE.md) *or* `target=script` (fix the launcher) — the data
  shows both the symptom and the cure.
- **`severity`** drives triage order; **High** specifically means "mis-instructs *every* future worktree"
  — qualitatively more urgent than a single-issue code finding, because the blast radius is all future
  agents until fixed.
- No `github_issue` column — by design this channel never produces one.

**Schema migration note:** the new table is created by `CREATE TABLE IF NOT EXISTS`, so `init` adds it to
both fresh and existing DBs with no data migration. (The existing ALTER-based migrate block at
`review-coverage.ps1` lines 122–127 is for *added columns* on `finding`/`recommendation` and is
untouched.)

## 6. CLI surface (verbs in `review-coverage.ps1`)

Mirrors the `recommend` / `recommendations` / `file-rec` / `dismiss-rec` set. **`-Target` is the only new
param**; all others already exist in the param block (`review-coverage.ps1` lines 35–49).

**Log one (agent- and orchestrator-facing):**

```powershell
review-coverage.ps1 hubfind -Worktree <FOLDER|orchestrator> -Category <env|tool|prompt|config|memory|other> `
    -Title '<short>' -Detail '<what happened + where + what the instruction/assumption should be>' [-Severity <Low|Medium|High>]
```

- Requires `-Worktree` and `-Title` (throws otherwise, matching `recommend`).
- `INSERT INTO hubfinding(source,wtype,category,title,detail,severity)` — `wtype` resolved from the
  `worktree` table when the source is a registered worktree, else falls back to `'orchestrator'`/`'solver'`
  (same `COALESCE((SELECT wtype FROM worktree …))` trick `progress` uses at line 292).
- Also writes an `activity` row (`event='hubfind'`) so it shows in the activity feed like every other
  lifecycle event.

**List open (orchestrator triage):**

```powershell
review-coverage.ps1 hub-findings           # open only (default)
review-coverage.ps1 hub-findings -All      # include resolved + dismissed
```

- `SELECT id, source, wtype, category, severity AS sev, substr(title,1,60) AS title, status, COALESCE(target,'') AS target`
  ordered by `CASE severity WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 ELSE 2 END, id`, filtered to
  `status='open'` unless `-All`. Uses the existing `-All` switch.

**Resolve / dismiss (orchestrator, after making the real edit):**

```powershell
review-coverage.ps1 hub-resolve -Id <N> -Target <prompt|config|script|memory> -Note '<what you changed>'
review-coverage.ps1 hub-resolve -Id <N> -Dismiss [-Note '<why>']
```

- `-Id` required (throws otherwise). Default (no `-Dismiss`): `UPDATE hubfinding SET status='resolved',
  target='<Target>', resolution='<Note>', resolved_at=datetime('now') WHERE id=<N>`.
- `-Dismiss`: `status='dismissed'`, `resolution='<Note>'`, `resolved_at` stamped (reuses the existing
  `-Dismiss` switch, as `verify -Dismiss` does).
- Writes an `activity` row (`event='hub-resolve'`).
- **No GitHub call.** This is the key divergence from `file-rec`.

## 7. Agent-side recognition (`WORKTREE.md`)

A short new section (placed after §5 "Recommended follow-ups", since it is a sibling "things you found
but don't fix here" concept — but distinct because it targets the *hub*, not the repo). Draft content:

> **## Hub findings (problems with these instructions / your environment — not the repo's code)**
> If you hit a problem with **how this hub is operating you** rather than with the repo you were sent to
> fix — a command or tool that isn't what the prompt implied, the **wrong terminal assumption**
> (this hub is PowerShell), a wrong configured value, or an unclear/stale standing instruction — that is
> a **hub finding**. You **cannot** fix the hub from here, and you must **not** paper over it. Log it so
> the orchestrator can fix the real artifact:
> ```powershell
> & <hub>\review-coverage.ps1 hubfind -Worktree <FOLDER> -Category <env|tool|prompt|config|memory|other> `
>     -Title '<short>' -Detail '<what happened, where, and what it should be>' [-Severity <Low|Medium|High>]
> ```
> Then carry on with your task using the correct approach. Keep doing your repo work; this is just so the
> defect in the *hub's* instructions/environment gets fixed for every future worktree.

Plus:

- **§4 completion report** gains a row: `'Hub findings|<N logged — see ledger / none>'`.
- **§6 record-to-ledger** gains the `hubfind` example line alongside `progress`/`recommend`.

The same recognition guidance belongs in the **canonical seed prompts** in `CLAUDE.md` only by reference
(the prompts already say "follow WORKTREE.md"), so no per-prompt duplication is needed.

## 8. Integration (surfacing + triage cadence)

- **`monitor`** — add a third block after "Proposed recommendations":
  `=== Open hub findings (prompt / env / config problems) ===` listing open rows (id, source, category,
  sev, title). This is how the orchestrator "sees" them without reading windows.
- **`ledger-to-html.ps1`** — add a fifth open-item set, **Hub findings** (`status='open'`), to the
  `.DESCRIPTION` list and the rendered page (same badge/sort/search treatment as the other four tables).
- **Merge-time sweep (CLAUDE.md "Merging a finished PR" step 4)** — extend the standing-backlog sweep to
  also run `hub-findings` and triage open hub findings: fix the named artifact (edit
  WORKTREE.md/CLAUDE.md/config/script, or write a memory file), then `hub-resolve`. This puts hub findings
  on the same "verify-before-stale" cadence as `findings -Unverified` and `recommendations`.

## 9. Orchestrator resolution workflow

When triaging an open hub finding, the orchestrator:

1. Reads it (`hub-findings`, or the dashboard).
2. Makes the **real** fix in the named artifact:
   - **prompt** → edit `WORKTREE.md` / `CLAUDE.md` / a seed-prompt template.
   - **config** → edit `hub.config.json` (and `hub.config.example.json` if the default should change for
     everyone).
   - **script** → edit the helper `.ps1`.
   - **memory** → write a memory file under `~/.claude/projects/.../memory/` + a `MEMORY.md` pointer
     (per the memory rules), for facts that should persist across sessions rather than live in a doc.
3. Stamps it: `hub-resolve -Id N -Target <…> -Note '<what changed>'` (or `-Dismiss -Note '<why>'`).

Choosing **prompt vs memory** is a judgment call the orchestrator makes: durable *operating rules* that
should bind every future worktree belong in `WORKTREE.md`/`CLAUDE.md` (versioned, shipped with the hub);
*orchestrator-side facts/feedback* that guide this session across runs belong in auto-memory. The channel
records which was chosen via `target`, so the history shows how each finding was actually addressed.

## 10. Error handling / PowerShell quirks

- Reuse the existing `Exec`/`Query`/`q`/`NullableInt` helpers and the `.timeout 8000` busy-timeout (so
  concurrent solver writers don't hit "database is locked").
- Respect the repo's documented PowerShell quirks: check `$LASTEXITCODE` for native calls; no `;` inside
  `if(...)` conditions; pass any comma-bearing native-flag value as a single quoted token.
- Required-arg guards (`throw` when `-Worktree`/`-Title`/`-Id` missing) match the existing verbs exactly.

## 11. Testing strategy

- **Pester** (`review-coverage.Tests.ps1`, new) — a lifecycle round-trip against a **temp DB** (point the
  script at a throwaway `coverage.db`): `init` → `hubfind` (assert one `open` row with the right
  category/severity) → `hub-findings` (assert it lists) → `hub-resolve -Target prompt -Note …` (assert
  `status='resolved'`, `target`/`resolution`/`resolved_at` set) → `hub-resolve -Dismiss` on a second row
  (assert `dismissed`). Run via the saved Pester module at `C:\mydev\pester-modules` (standard
  `Install-Module` fails on this machine — see project memory).
- **Manual smoke** — from a real worktree, `hubfind` once; confirm it appears in `monitor` and in the
  HTML dashboard; `hub-resolve` it; confirm it clears from the open views.

## 12. Documentation updates

- **`CLAUDE.md`** — add `hubfind`/`hub-findings`/`hub-resolve` to the `review-coverage.ps1` command block;
  add `hubfinding` to the "Tables:" description of the ledger (one clause: "**hubfinding** — problems with
  the hub's own operating layer (prompts/config/scripts/memory/env), logged by any worktree or the
  orchestrator; lifecycle open → resolved/dismissed, fixed by editing a hub artifact, never a GH issue");
  extend the merge-time sweep (step 4); mention it in the worktree-monitoring narrative.
- **`WORKTREE.md`** — the new section + report row + record line from §7.
- **`README.md`** — one line in the ledger/commands overview noting the hub-findings channel exists (kept
  brief; CLAUDE.md holds the detail).
- **Optional doctor nudge** — `hub-checks.ps1` check #16 ("ledger has expected tables") may add
  `hubfinding` to its expected-tables set so the doctor prompts a re-`init` on an older hub. Low priority;
  include only if cheap.

## 13. File-ownership summary (for the implementation plan)

| File | New/Changed | Responsibility |
|---|---|---|
| `review-coverage.ps1` | changed | `hubfinding` table in `init`; `hubfind`/`hub-findings`/`hub-resolve` verbs; `-Target` param; `monitor` block |
| `ledger-to-html.ps1` | changed | fifth open-item section (Hub findings) |
| `WORKTREE.md` | changed | new "Hub findings" section + completion-report row + record-to-ledger line |
| `CLAUDE.md` | changed | command list + ledger/tables description + merge-time sweep + monitoring narrative |
| `review-coverage.Tests.ps1` | new | Pester lifecycle round-trip on a temp DB |
| `README.md` | changed (1 line) | mention the channel in the ledger/commands overview |
| `hub-checks.ps1` | changed (optional) | add `hubfinding` to expected-tables check #16 |
