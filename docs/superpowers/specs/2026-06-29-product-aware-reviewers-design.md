# Product-Aware Reviewers — Design Spec

**Status:** approved design (brainstorming output) — ready for an implementation plan.

## Problem

Every review surface in the hub today judges work on **technical** grounds only. Recon finds problems;
the fan-out `verify` step asks "is this still a real bug in the current code?" (`still-valid` /
`already-fixed` / `out-of-scope`); the issue `record-review` step maps owned paths and severity for
overlap-aware scheduling. Nothing asks the question an app developer actually cares about: **is this worth
doing for *this* product?**

The result is that technically-legitimate-but-unnecessary work flows straight through to a worktree and
gets built: a11y polish on an internal admin screen no one uses with a screen reader, optimizing a query
that runs once a day, hardening an input that is always machine-generated, gold-plating a non-goal. A
finding can be 100% real and still be a waste of a worktree. The existing `hub-dx-product` / `hub-principal`
expert advisors *do* hold product context, but they are consulted by a worktree about **how to build** a
decision it has already committed to — they never weigh in on **whether to build it at all**.

## Goal

Give the hub **product-aware reviewer personas** — grounded in the user's `PRODUCT.md` (vision, target
users, priorities, non-goals) — that review a specific finding/issue and render a complete go/no-go verdict:
is it **legitimate** (real), **necessary** (worth doing for the product), and what is the **scope** of the
change it requires. The review runs as **stage one of the worktree** (before any fix code), so the most
expensive thing it prevents — building unnecessary work — is stopped at the cheapest point where full
context is already loaded. Decisions are recorded in the existing `consult` ledger so reviewer-vs-human
disagreements become a refinement signal for sharpening the personas.

## Non-goals (YAGNI)

- **Not** a discovery role — personas **only review** an existing finding/issue; recon (read-only) still
  does all discovery. A reviewer never searches the code for new problems.
- **Not** a new fan-out reviewer before provisioning. The deep necessity review lives at worktree stage one
  (a dedicated pre-provisioning reviewer would load full context, discard it, then have the worktree reload
  the same context to fix — double spend for everything that proceeds). Accepted cost: a worktree may be
  provisioned and then immediately self-cancel.
- **Not** a replacement for the *cheap* fan-out filters. Recon `verify` (factual: already-fixed/out-of-scope)
  and issue `record-review` (owned paths for scheduling) stay exactly as they are — they are logistics that
  must run before provisioning. Only the **necessity judgment** moves to stage one.
- **Not** binding/authoritative — personas advise; the worktree decides and records, and the **human**
  retains final say on closing an approved issue (the worktree never closes a human-approved issue itself).
- **Not** a new schema. Recording reuses the existing `consult` table and `progress` status. A structured
  `necessity` column is a deferred future option, not v1.
- **Not** the full persona set forever — three personas in v1; add a growth/adoption or app-specific
  stakeholder lens later only if the three prove too coarse.

## Constraints (these shape the design)

- **Headless Claude is banned** (Critical rule #7 — bills outside the subscription). Personas MUST be
  in-process `Agent`/subagent calls inside the worktree's own interactive session, never `claude --print`.
  This is already how `WORKTREE.md` §6 consults experts.
- **Worktree subagent file-resolution bug:** subagents spawned inside a git worktree can resolve file reads
  to the *main* repo root rather than the worktree's CWD (Claude Code #31546/#44557). So the design does
  **not** depend on the persona reading the worktree's code itself. The worktree's **main session** — which
  is reading the relevant code anyway to assess/fix the issue — **curates the evidence** (the finding, the
  relevant current code excerpts, the draft scope) and the relevant `PRODUCT.md` context, and passes it
  *into* the persona prompt. The persona has `Read/Grep/Glob` as a fallback but reasons primarily about the
  provided context. This is the same resolution the expert-consultation channel already uses.
- **"Does it all," reconciled with the bug:** the persona is the **reviewer of record** for the single
  holistic go/no-go (legitimacy + necessity + scope), but it leans on the worktree's curated code-facts for
  legitimacy/scope and contributes the product judgment for necessity. It is not asked to audit the whole
  codebase alone.
- **Per-worktree provisioning is established:** `new-worktree.ps1`/`spawn-child.ps1` already copy
  `<hub>/.claude/agents/hub-*.md` into each worktree and git-exclude them via the `hub-*` glob, so new
  `hub-product-*.md` files are provisioned automatically with no script change.

## Architecture overview

Six units, each independently understandable/testable:

| # | Unit | Responsibility | Interface |
|---|------|----------------|-----------|
| 1 | Persona agent definitions | The three product-stakeholder review lenses | `.claude/agents/hub-product-*.md` (frontmatter + system prompt) |
| 2 | Provisioning | Get personas into each worktree session | **none** — existing `hub-*` copy/exclude already covers them |
| 3 | Stage-one necessity gate | *When* + *how* a worktree reviews before building | `WORKTREE.md` new section + roster addition |
| 4 | Routing | Which persona reviews a given item | `CLAUDE.md` orchestrator guidance + persona "Also consult" |
| 5 | Recording + outcome | Auto-halt vs. gate; queryable decision log | reuse `consult` verb + `progress` status; completion report + PR |
| 6 | Refinement loop | Sharpen personas from reviewer-vs-human deltas | `CLAUDE.md` (reuse the consult improvement loop) |

## 1. Persona agent definitions (the roster)

Three Markdown agent files in the hub repo at `.claude/agents/hub-product-*.md` (committed, versioned),
namespaced `hub-product-` so they never collide with agents the target app ships and so the existing
`hub-*` provisioning glob picks them up.

Common frontmatter (matches the existing experts):
```yaml
---
name: hub-product-<x>
description: <routing trigger — "Review for <stakeholder> necessity ...">
tools: Read, Grep, Glob      # read-only fence — review, never edit; never write the ledger
model: opus
---
```

| Agent | Lens | The necessity question |
|-------|------|------------------------|
| `hub-product-owner` *(default)* | App-owner / business value — the app developer's motives, desires, needs | "Does this advance a stated `PRODUCT.md` priority / serve the roadmap, or is it a distraction or gold-plating a non-goal?" |
| `hub-product-user` | End-user advocate | "Would a real user of this app notice, care, or be blocked? Does it affect task success or trust — or is it internal-only polish no user sees?" |
| `hub-product-maintenance` | Support & maintenance cost | "What is the cost of *inaction* (support tickets, on-call pain, tech-debt interest) versus the scope of the fix? Is the fix proportionate?" |

**System-prompt shape (every persona):** *you are reviewing ONE specific finding/issue for product
necessity, grounded in the `PRODUCT.md` brief provided. The worktree gives you the item, the relevant
current code/evidence, and the product context — reason about what you are given.* Return a fixed structure:

- **Legitimacy:** `still-valid | already-fixed | partially-fixed | out-of-scope` (confirm/challenge from the
  evidence given; flag if you cannot tell from the evidence → `needs-info`).
- **Necessity:** `necessary | borderline | not-necessary`, **+ confidence** `high | medium | low`, grounded
  explicitly in `PRODUCT.md` (name the priority it serves or the non-goal it gold-plates).
- **Scope/effort:** the change this would require (files/areas + rough size), and whether it is proportionate
  to the value.
- **Recommendation:** `proceed | dismiss | defer`, one-line rationale tied to the product brief.
- **Also consult:** another `hub-product-<x>` if necessity really hinges on that lens, or "none."

Personas must **calibrate by origin** (told in the prompt): for `user`-origin items (the human filed and
approved them) lean to "confirm + right-size scope," halting only when clearly wrong; for `recon` /
`recommendation`-origin items, genuinely weigh "should we do this at all." Be explicit about uncertainty
rather than confident hand-waving.

If no `PRODUCT.md` content is provided, the persona says so and flags that product intent is unstated —
it does not invent it (same rule the existing product experts follow).

## 2. Provisioning

**No change.** `new-worktree.ps1` and `spawn-child.ps1` already call `Copy-HubExperts` (copies
`<hub>/.claude/agents/hub-*.md` into the worktree's `.claude/agents/`) and `Add-HubExclude` with
`/.claude/agents/hub-*.md`. The `hub-product-*` files match that glob, so they are copied and git-excluded
automatically. (A test will assert the personas are among the copied files.)

## 3. Stage-one necessity gate (`WORKTREE.md`)

A new **mandatory stage one** runs in **both** tracks, before any fix code. This is distinct from §6's
existing consults: §6 is *how* to build a decision; this is *whether* to build at all.

**The flow:**
1. The worktree reads `@ISSUE.md` and the relevant current code (it does this anyway to assess the fix),
   establishing the facts: is the problem still real, and what is the rough scope.
2. It reads `<hub>\PRODUCT.md` live and **consults the routed persona** (§4) in-process, pasting in the
   item, the code evidence, the draft scope, the item's **origin**, and the relevant product context — the
   same curated-context mechanism as §6 (does **not** rely on the persona reading worktree files).
3. It branches on the persona's verdict:
   - **necessary** → proceed to the normal workflow (simple §2 / complex §3). Record the consult
     (`followed=yes`).
   - **not-necessary, confidence=high** → **HALT** (auto, non-blocking): do not write fix code; set worktree
     status `halted-unnecessary`; record the consult (`decision='halted — not necessary'`); produce the
     completion report recommending the human close the issue. The worktree does **not** close the
     human-approved issue itself.
   - **borderline, or not-necessary at medium/low confidence**, or **legitimacy=already-fixed/out-of-scope** →
     **STOP at a gate** (blocking): set status `spec-gate`, present the persona's verdict, and **wait for the
     user** to choose proceed / dismiss / re-scope. Record the consult **and the human's choice** (this is
     the refinement signal — `followed=yes|partial|overridden` + rationale).

**Complex track:** this folds into the existing research→`SPEC.md`→gate. `SPEC.md` must include a **Product
necessity** section (the persona's verdict + the priority it serves), and the §3 gate is where a borderline
necessity verdict gets the user's call — so necessity is settled *before* the breakdown is approved.

**Calibration:** for `user`-origin approved issues the gate is a fast confirm-and-right-size, not a
re-litigation of the user's explicit request; the halt path is reserved for items that are clearly
unnecessary or already-fixed.

The three personas are also added to the §6 expert roster list (they are consultable advisors of the same
kind), with a pointer that the **mandatory** use is the stage-one gate.

## 4. Routing (which persona)

Flat/worktree-orchestrated, mirroring the expert channel:

- **Default:** `hub-product-owner` (the app-developer's-motives lens — the most general product judgment).
- **Orchestrator hint:** the seed prompt MAY name a different primary persona for a clearly-typed item,
  using the item's labels/category/area:

  | Item is about… | Primary persona |
  |---|---|
  | UX, a11y, error messages, user-facing behavior/copy, onboarding | `hub-product-user` |
  | feature scope, priority, roadmap fit, "should we even build this" | `hub-product-owner` (default) |
  | perf, refactor, tech-debt, deps, observability, test-only, internal tooling | `hub-product-maintenance` |

- **Onward routing:** the persona's "Also consult" line lets it pull in a sibling persona when necessity
  hinges on another lens; the worktree spawns that second persona (no nested convening in v1).

One persona per item by default (token economy + "does it all"); a second only when the first routes to it
or the item is high-stakes/contested.

## 5. Recording + outcome (reuse `consult` + `progress`)

**No schema change.** Each stage-one review is recorded with the existing `consult` verb:
```powershell
& <hub>\review-coverage.ps1 consult -Worktree <FOLDER> -Expert hub-product-<x> -Area product-necessity `
    -Issue <N> -Question 'Is #<N> necessary for the product? <one-line>' `
    -Advice '<persona verdict: legitimacy · necessity+confidence · scope · recommendation>' `
    -Decision '<proceed | halted — not necessary | gated → user chose X>' `
    -Followed <yes|partial|overridden> -Rationale '<why, esp. if you/the user overrode the persona>'
```
- `area='product-necessity'` makes these consults filterable for the refinement loop and reporting.
- The **necessity verdict** lives in `-Advice`; the **action taken** in `-Decision`; the **agreement** in
  `-Followed`. Override capture (`overridden` + rationale) is the core signal — exactly as for experts.
- **Outcome status** uses the free-text `progress` status (no schema change): `halted-unnecessary` on an
  auto-halt; the existing `blocked`/`spec-gate` while waiting at the gate. `monitor` already lists worktree
  status and recent consults, so halts and necessity reviews surface with everything else.
- The worktree never closes the GitHub issue; on a halt/dismiss it **recommends** closure in its report and
  the orchestrator/human closes it at triage (consistent with auto-mode soft-denying issue-state changes and
  the hub's human-checkpoint rule).

## 6. Refinement loop (`CLAUDE.md`)

Reuse the **existing consult improvement loop** — no new machinery:

- Document the personas, the stage-one gate, and the `product-necessity` consult convention in `CLAUDE.md`
  (expert roster + the merge-time sweep, mirroring how the consult channel is documented).
- At the merge-time sweep, the orchestrator already glances at a worktree's consults (especially overrides).
  Product-necessity consults appear there; an `overridden` row means the persona and the human disagreed on
  necessity — the highest-value rows.
- **The loop:** periodically query `consult WHERE expert LIKE 'hub-product-%'` — override rate, which
  persona, decisions that later correlated with reverted/duplicate work — and use it to sharpen the persona
  system prompts and `PRODUCT.md`. The data is structured so this is a query, not an archaeology dig.

## 7. Completion report + PR integration

- **Completion report (`WORKTREE.md` §4):** add a **Necessity** row (persona · verdict · confidence ·
  one-line product rationale). On a halt, the report's shape changes — `Status` = `⛔ halted — not necessary
  (recommend closing #<N>)`, `PR` = `none`, and the Necessity row carries the reasoning. `format-report.ps1`
  needs no change (it renders arbitrary rows).
- **PR body:** when the work proceeds, the persona's necessity verdict joins the existing `## Design
  decisions` section of the PR body (the same place expert consults are summarized), so the
  "why this was worth doing" travels with the code.

## Error handling / edge cases

- **No persona files present** (old worktree / provisioning skipped): stage one degrades to an in-session
  reasoning step grounded in `PRODUCT.md`; `WORKTREE.md` says to note "product reviewers unavailable" and
  reason carefully rather than block (same fallback as §6).
- **No `PRODUCT.md`:** the persona advises that product intent is unstated; the worktree leans toward
  **proceed** for `user`-origin items (the human chose them) and surfaces the gap, rather than halting work
  for lack of a brief.
- **Persona says `not-necessary` on a `user`-origin issue the human explicitly filed:** never auto-halt;
  always route to the gate so the human can confirm — the human's own request outranks the persona.
- **App ships its own `.claude/agents/`:** `hub-product-` namespacing + copy-only-`hub-*` guarantees no
  clobber (same guarantee as the experts).
- **`needs-info` legitimacy** (persona can't tell from the evidence): treat as the gate path; the worktree
  gathers more evidence or asks the user, never proceeds on an unconfirmed bug.

## Testing

- **Pester** (`review-coverage.Tests.ps1`): `consult` rows with `expert='hub-product-*'` and
  `area='product-necessity'` round-trip (already supported by the verb — assert the convention, no new code);
  `progress -Status halted-unnecessary` records and surfaces in `monitor`.
- **Provisioning** (`new-worktree`/`spawn-child` tests): assert the three `hub-product-*.md` are among the
  files `Copy-HubExperts` copies and that `/.claude/agents/hub-*.md` excludes them.
- **Persona prompts** are not unit-tested (they are judgment); validated by use + the refinement loop.
- **`WORKTREE.md`/`CLAUDE.md`** changes are doc edits — covered by review, not unit tests.

## Rollout

- Add the three `.claude/agents/hub-product-*.md` files + the `WORKTREE.md`/`CLAUDE.md` edits to the hub
  repo. No `review-coverage.ps1` schema migration is required (recording reuses `consult`/`progress`), so
  existing hubs need no `init` re-run for this feature.
- Existing worktrees do not get the personas retroactively (only newly-provisioned ones do) — acceptable,
  since the stage-one gate is a per-session behavior.

## Open questions / future

- A structured `necessity` / `necessity_confidence` column (on `consult` or a small `product_review` table)
  if querying necessity outcomes by free-text `advice` proves too weak for the refinement loop.
- A growth/adoption persona, or an app-specific stakeholder lens, if the three v1 lenses prove too coarse.
- An optional *lightweight* necessity pre-screen in the existing fan-out (auto-dismiss only high-confidence
  junk before provisioning) if "provisioned-then-self-cancelled" worktrees become common enough to be worth
  the extra tier.
- Outcome-linking: correlate `not-necessary`/`overridden` product consults with later reverted or duplicate
  work to measure persona quality over time.
