# Worktree Expert Consultation — Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

## Problem

Worktree solver agents make consequential design decisions in isolation — where new code
belongs, how to model data, what to log, how to keep a change extensible — and they make them
with the judgment of a single session under time pressure, not the judgment of a professional
application-development team. There is no way for a worktree to get a second, expert opinion on a
decision, and no record of the decisions made or *why*. The result is locally-reasonable choices
that are globally regrettable (coupling, schema dead-ends, unobservable features, gold-plating),
and a loss of the decision rationale that future work could learn from.

## Goal

Give every worktree session a panel of **consultable domain-expert agents** that reason about a
specific decision in the context of "what is the professional solution that produces the best
long-term result" — manageable, easy-to-use, complete, easily-extended — and **record every
consultation and the resulting decision** in the hub ledger so the activity becomes an
observability/improvement loop, never noise.

## Non-goals (YAGNI)

- **Not** binding/authoritative review — experts advise; the worktree decides and records.
- **Not** a separate windowed/headless process — experts are in-process subagents (see Constraints).
- **Not** an automatic code-editing reviewer — experts are read-only; they never touch code or the ledger.
- **Not** the full lens set in v1 — quality/testing is folded into `hub-principal`; promote to a
  standalone expert later only if the principal's advice proves too shallow there.
- **Not** outcome-linking automation (correlating overrides with later bugs) in v1 — the schema
  *enables* it; the analysis stays a human/feedback-loop activity for now.

## Constraints (these shape the design)

- **Headless Claude is banned** (Critical rule #7 — bills outside the subscription). Experts MUST be
  in-process `Agent`/subagent calls inside the worktree's own interactive session (subscription-covered),
  never `claude --print`.
- **Known worktree file-resolution bug:** subagents spawned inside a git worktree can resolve file
  reads to the *main* repo root rather than the worktree's CWD (Claude Code issues #31546/#44557). The
  design **avoids relying on experts reading the right files**: the worktree curates the question and
  passes the relevant context *into* the expert prompt. (This is also better practice — "give a subagent
  exactly what it needs.") Verify behavior on the installed version during implementation.
- **Per-worktree provisioning** is the hub's established pattern (`WORKTREE.md`/`ISSUE.md` are copied in +
  git-excluded + `@`-mentioned). Expert definitions follow the same pattern for deterministic discovery.

## Architecture overview

Seven units, each independently understandable/testable:

| # | Unit | Responsibility | Interface |
|---|------|----------------|-----------|
| 1 | Expert agent definitions | The professional-judgment lenses (6 agents) | `.claude/agents/hub-*.md` (frontmatter + system prompt) |
| 2 | Provisioning | Get the experts into each worktree session | `new-worktree.ps1` copy + `.bare/info/exclude` |
| 3 | Consult workflow | *When* + *how* a worktree consults + records | `WORKTREE.md` new section |
| 4 | Recording | Structured, queryable consultation log | `consult` table + `review-coverage.ps1 consult` verb |
| 5 | Surfacing | Make consults visible | `monitor` block + dashboard section |
| 6 | Orchestrator docs + loop | Triage consults; sharpen experts | `CLAUDE.md` |
| 7 | In-repo ADR note | Rationale travels with the code | PR-body `## Design decisions` |

## 1. Expert agent definitions (the roster)

Six Markdown agent files live canonically in the **hub repo** at `.claude/agents/hub-*.md` (committed,
versioned), namespaced `hub-` so they never collide with agents the target app ships.

Common frontmatter:
```yaml
---
name: hub-<x>
description: <routing trigger — "Consult for <domain> decisions ...">
tools: Read, Grep, Glob      # read-only fence — advise, never edit; never write the ledger
model: opus                  # deep reasoning
---
```

System-prompt shape (every expert): *reason about the SPECIFIC question in the given context; weigh the
long-term/professional trade-off; return a structured recommendation* —
**Recommendation · Key trade-offs · What to avoid · "Also consult `hub-<y>` if …"** — and be explicit
about uncertainty rather than confident hand-waving.

| Agent | Lens |
|-------|------|
| `hub-principal` | Staff-engineer generalist. Whole-team judgment: long-term maintainability, simplicity, completeness, extensibility, "what will we regret in six months," when to STOP gold-plating. Default consult; frames cross-cutting decisions and points to specialists. |
| `hub-architect` | Module/API boundaries, where new code belongs, coupling vs cohesion, data flow, extension points, avoiding the choice that paints you into a corner. |
| `hub-data` | Schema & migration design, integrity/constraints, indexing, backward-compatible evolution, query shape. |
| `hub-observability` | What to log/measure/trace; structured events; what activity to capture so it is genuinely useful for future improvement; avoiding noise. |
| `hub-security` | Authz/authn, input validation, secrets handling, data exposure, safe-by-default. |
| `hub-dx-product` | The consumer's view: API/UX ergonomics, naming, error messages, edge cases users hit, "is this actually easy to use." |

**Routing (v1):** worktree-orchestrated/flat. `hub-principal` is the default; it may *recommend* a
specialist, but the **worktree** spawns the specialist (the principal does not convene nested subagents
in v1). Nested "principal convenes specialists" is a deferred future option (Claude Code supports nested
subagents, but it multiplies token cost and interacts with the worktree bug).

## 2. Provisioning

`new-worktree.ps1` (and `spawn-child.ps1`) copy `<hub>/.claude/agents/hub-*.md` into the new worktree's
`.claude/agents/` directory and add the pattern to `.bare/info/exclude` so the copies are git-excluded
(never committed into the app's branch/PR) — exactly the mechanism already used for `WORKTREE.md`. Only
`hub-*` files are copied/excluded, so any app-owned `.claude/agents/*` are left untouched.

## 3. Consult workflow (`WORKTREE.md`, new section)

**When:**
- **Mandatory at the spec-gate (complex track):** before a complex worktree STOPs to present
  `SPEC.md`/`PLAN.md` for human approval, it consults the relevant expert(s) on each key design decision
  and folds the guidance in — so what reaches the human gate is already pressure-tested.
- **On-demand (both tracks):** at any consequential fork it is unsure about, it consults the fitting
  expert rather than guessing.

**How:** the worktree **curates the question + the relevant context** (the decision, the options it sees,
the constraints, the specific code/excerpts) and invokes the expert **in-process** (`Agent` tool with
`subagent_type: hub-<x>`, or `@hub-<x>`). It does **not** rely on the expert to go find the right files
(worktree bug). The advice is **advisory**: the worktree weighs it, makes the decision, and records the
consultation (§4) — including, when it overrides the expert, *why*.

**Default:** consult `hub-principal` for holistic calls; pull in a specialist for domain-deep ones (often
because the principal said to).

## 4. Recording (`consult` table + verb)

A new append-only table in the hub-local SQLite ledger (`.review/coverage.db`):

```sql
CREATE TABLE IF NOT EXISTS consult(
  id INTEGER PRIMARY KEY,
  worktree TEXT, wtype TEXT, expert TEXT NOT NULL, area TEXT,
  issue INTEGER,
  question TEXT NOT NULL, advice TEXT, decision TEXT,
  followed TEXT,            -- yes | partial | overridden
  rationale TEXT,          -- why; REQUIRED in spirit when followed='overridden'
  created_at TEXT DEFAULT (datetime('now')));
CREATE INDEX IF NOT EXISTS ix_consult_expert ON consult(expert);
```

Recorded by the **worktree** (not the expert — experts are read-only and don't know the final decision)
via:
```
review-coverage.ps1 consult -Worktree <w> -Expert hub-<x> -Area <area> -Question '<q>' \
    -Advice '<expert recommendation summary>' -Decision '<what you decided>' \
    -Followed <yes|partial|overridden> -Rationale '<why, esp. if overridden>' [-Issue <N>]
```
The verb also writes an `activity` row (`event='consult'`) for the live feed. Append-only: a consult is a
point-in-time record, no lifecycle/status.

**Advisory + override capture is the core observability value:** the `overridden` + `rationale` rows are
exactly where you later learn whether the expert or the engineer was right.

## 5. Surfacing (`monitor` + dashboard)

- `monitor`: a "Recent consults" block (latest N, with `overridden` flagged) so the orchestrator sees
  decision activity alongside everything else.
- `ledger-to-html.ps1`: a new "Consults / decisions" section (worktree · expert · question · decision ·
  followed), consistent with the existing five sections.
- A lightweight `consult report` / list view (counts by expert + override rate) feeds the feedback loop.

## 6. Orchestrator docs + feedback loop (`CLAUDE.md`)

- Document the roster, the `consult` verb, and the advisory model in the ledger command reference + tables
  description (mirroring how `hubfinding` was documented).
- At the merge-time sweep, glance at the merged worktree's consults — especially overrides — as part of
  triage.
- **The improvement loop (the point of the observability):** periodically review the consult log (which
  experts on what, override rate, decisions that later correlated with findings/bugs) and use it to
  **sharpen the expert system prompts**. The data is structured precisely so this is a query, not an
  archaeology dig.

## 7. In-repo ADR note (PR body)

In addition to the ledger row, the worktree appends a short `## Design decisions` section to its PR body
summarizing each consult (decision + one-line rationale, expert named) so the reasoning travels with the
code for human reviewers — not only in the hub-local ledger.

## Error handling / edge cases

- **No expert files present** (e.g. an old worktree, or provisioning skipped): consulting degrades to a
  normal in-session reasoning step; `WORKTREE.md` says to note "experts unavailable" rather than block.
- **App ships its own `.claude/agents/`:** `hub-` namespacing + copy-only-`hub-*` guarantees no clobber.
- **`consult` verb without a configured hub:** runs on the same defensive-config path as the other ledger
  verbs (works with `-DbPath` against a temp DB for tests).
- **Empty/short advice:** the verb records whatever the worktree passes; `-Question` and `-Expert` are the
  only hard-required fields.

## Testing

- **Pester** (`review-coverage.Tests.ps1`, the existing suite): `consult` table created by `init`;
  `consult` verb inserts the row with the right columns + an `activity` row; `-Followed overridden`
  round-trips; required-field guards throw; `monitor`/dashboard render the consult section (smoke).
- **Provisioning:** a check that `new-worktree.ps1` copies `hub-*.md` into the worktree's `.claude/agents/`
  and excludes them (and copies *only* `hub-*`).
- Expert **prompts** are not unit-tested (they're judgment); they are validated by use + the feedback loop.

## Rollout

The `consult` table is created by `review-coverage.ps1 init` (idempotent); existing hubs re-run `init`
once. The expert `.claude/agents/hub-*.md` files are added to the hub repo; existing worktrees don't get
them retroactively (only newly-provisioned worktrees do) — acceptable, since consultation is a per-session
behavior.

## Open questions / future

- Promote `hub-quality` (and any other folded lens) to a standalone expert if the principal's coverage
  proves too shallow.
- Nested routing (principal convenes specialists itself) once the worktree-bug interaction is verified.
- Outcome-linking: correlate `overridden` consults with later `finding`/`recommendation`/bug rows to
  measure decision quality over time.
