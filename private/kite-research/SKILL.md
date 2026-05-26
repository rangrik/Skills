---
name: kite-research
description: >-
  Inspects the actual codebase to answer the research questions for ONE
  planned Kite slice — what already exists to reuse, what is missing, and
  where new code should go — and records the answers in a feature-wide
  `codebase-research.md`. It gathers the slice's questions from the slice
  plan ("Slice research questions") cross-checked against the system-design
  spec's "Open Questions for the Codebase", then answers each against the
  real code. On every iteration it ALSO refreshes the research doc:
  re-inspects prior findings whose code area overlaps this slice and updates
  any answer that went stale (e.g. a capability that was MISSING earlier and
  now EXISTS because a prior slice built it). Use as the stage immediately
  after kite-planner-with-taxonomy, or when the user says "research the
  codebase for this slice", "find what we already have", "check what exists
  before we build", or "refresh the research doc". The only Kite
  planning-phase skill permitted to read source code. Scope: appsmith-v2 /
  Kite platform.
---

# Kite Research

You are the bridge from design-space to code-space. Given **one planned slice**,
you inspect the **actual codebase**, answer that slice's research questions —
what already exists to reuse, what is missing, and where new code should go — and
record the answers in a feature-wide `codebase-research.md`.

You are the **only** Kite planning-phase skill allowed to read source code.
`kite-planner-with-taxonomy` and `kite-system-design-blueprint-slices` were
deliberately code-blind so the plan and design reflect what the slice _needs_;
you are the deliberate, auditable step that reconciles that against what the
codebase actually _has_.

## One slice at a time, one growing research doc

The pipeline runs a loop: research slice 1 → implement slice 1 scenario by
scenario → research slice 2 → implement slice 2 → … until every slice ships. You
own the **research** turn of each lap.

There is **one** research artifact for the whole feature: `codebase-research.md`,
written next to the slices (in the `<feature>-slices/` directory). Each iteration
**adds** the current slice's findings to it — it is not a fresh file per slice.

This is the subtlety that defines this skill: **the codebase is not static across
laps.** Slice 1's implementation writes real code, so by the time you research
slice 2, answers you (or the design) recorded earlier may be **stale** — a
service that was MISSING now EXISTS because slice 1 built it; a table whose shape
you described has gained a column; an extension point now has a neighbour to
follow. If slice 2 is implemented against a stale doc, the implementer rebuilds
what slice 1 already made, or extends a surface that has moved. So every
iteration you are responsible for two things: **answer the new slice's
questions**, and **keep the rest of the doc current** for the work about to
begin.

## Inputs

- The **current slice's plan file** — `slice-N-<short>-plan.md` from
  `kite-planner-with-taxonomy`. Its **Slice research questions** section is the
  consolidated, deduped question set for this slice (the source of truth for what
  to answer).
- The **current slice's system-design spec** — `slice-N-<short>-system-design.md`.
  Cross-check its **Open Questions for the Codebase** against the plan's list so
  nothing the design asked got dropped in planning; research any that the plan
  somehow omitted, and note the discrepancy.
- **`SLICES.md`** — for the stacked order and the `Builds on:` context (which
  earlier slices' code this one stands on, and therefore which prior findings are
  most likely to have changed).
- The **existing `codebase-research.md`**, if this is not the first slice.
- The **codebase**.

## Process

### P1 — Gather this slice's questions

Take the plan's **Slice research questions** as the working set. Reconcile them
against the system-design spec's **Open Questions for the Codebase**: if the
design asked something the plan didn't carry, add it and flag the gap. You answer
the whole set, one-to-one — they were written as a contract, so leave none
unanswered.

### P2 — Refresh the doc for currentness (skip on the first slice)

Before answering the new questions, bring the existing `codebase-research.md` up
to date for the code as it stands **now**:

1. **Find the overlap.** For each prior finding, ask whether this slice's
   questions touch the same capability, module, table, route, or area. The
   `Builds on:` line is the strongest hint — a slice almost always re-touches the
   code its predecessor laid down. An answer recorded as MISSING in an earlier
   lap, whose capability that lap was then implemented, is the highest-priority
   suspect.
2. **Re-inspect the live code** for each overlapping finding. Don't trust the old
   answer — open the actual file/symbol and confirm. A MISSING that has since been
   built flips to EXISTS with its new location; an EXISTS whose shape or
   constraints changed gets updated; a line number that drifted gets corrected.
3. **Update in place, with provenance.** Edit the finding's answer, bump its
   **Last verified: Slice N**, and append a one-line history note (e.g. `Slice 1 →
   MISSING (ADD at …); Slice 2 → EXISTS at services/snapshot_db.py:31 — built by
   Slice 1`). The history is what lets a reader trust the doc and audit the
   refresh.

Findings with no overlap to this slice you leave untouched (but they keep their
older `Last verified` marker, which honestly signals they predate this slice's
code).

### P3 — Answer the new questions against the codebase

For each not-already-covered question, inspect the code and record one of:

- **EXISTS** — name the function / module / route / schema, give its location
  (`file:line`), and say how to reuse it. Example: `EXISTS: get_app_domain in
  services/domains_db.py:42 — resolves an app's connected custom domain; reuse
  directly.`
- **MISSING** — name the extension point where new code should be added. Example:
  `MISSING: no growth route module — ADD a growth_routes.py alongside the existing
  app-scoped route modules.`

A good answer explains _why_ the nearest code satisfies or fails the capability —
not just "yes/no". If the slice needs username lookup and the repo has
`get_user_by_id`, say explicitly it is **id-based, not username-based**. Avoiding
duplicated effort is the entire point: if a capability already exists, find it and
say so clearly so the implementer doesn't rebuild it.

Also record **reuse constraints** — caveats on anything EXISTS (e.g. "assumes the
caller is already authenticated", "this query is not paginated").

### P4 — Write `codebase-research.md`

Update the universal research doc using `references/codebase-research.md`:

- Update the **Findings** ledger (refreshed prior findings + new ones), each with
  its current answer, location, reuse constraints, the questions it serves,
  **Last verified: Slice N**, and a short history line.
- Add this slice's **iteration section**: the questions (mapped to the findings
  that answer them), and a short note of what the refresh pass changed.
- Add a **research-log** row for this iteration.

Findings are keyed by capability/area, not by question, precisely so overlap
across slices is visible in one place and the refresh has something to land on.

### P5 — Update the plan and hand off

Set the slice's status to `researched` in `slice-N-<short>-plan.md` (or `blocked`
— see below), and make its **Research findings** section a pointer to this slice's
iteration section in `codebase-research.md` rather than duplicating answers.

The slice is now ready for `kite-implementation`, which reads this slice's section
of `codebase-research.md` for what to reuse and where to add code.

## References, not code

Put **names and locations** in the research doc, never copied source. The
implementer opens the real code when they get there; your job is to point
precisely, not transcribe. Copied code goes stale the instant the original is
edited — which, in this loop, is _constantly_.

Prefer repo-logical locations (`services/domains_db.py:42`) over absolute machine
paths. When researching a fixture or throwaway worktree with a fixture→repo path
mapping, cite the mapped repo path plus line number.

## When research invalidates the plan — the feedback loop

Sometimes the codebase contradicts the slice: the design assumed something untrue,
a required capability cannot live where the plan implies, or two scenarios'
assumptions conflict. Do **not** quietly invent a workaround — that hides a design
problem until implementation, where it is far costlier to fix.

Record a **BLOCKING** finding (in the doc and the slice's plan), explain exactly
what is wrong, and set the slice status to `blocked`. A blocked slice signals that
`kite-planner-with-taxonomy` (or the design step) must revisit it before
implementation proceeds.

Do not block on ordinary missing surfaces. Missing services, routes, schemas,
handlers, or jobs are normal implementation work: answer **MISSING**, name the
extension point, keep the status `researched`. Use **BLOCKING** only when the
current codebase contradicts the slice's assumptions or makes the planned behavior
impossible without re-planning.

## Use kite-design-system-standards lightly

Consult `kite-design-system-standards` enough to recognize the codebase's existing
patterns, so the extension points you name fit the architecture rather than fight
it. This is not a full architecture review — just don't point the implementer
somewhere that violates Kite's structure.

## Fan out

Research parallelizes well. Spawn one subagent per question cluster; each
researches its area in isolation and reports back. You remain the orchestrator:
run the refresh pass (P2) and merge all findings into the single
`codebase-research.md`, which stays the one source of truth. Use fan-out when the
slice has many substantial questions in a real repo; for a focused slice or a
small fixture, inline research is clearer — keep the same one-to-one answer
format.

## Staying in your lane

Do not write code. Do not put actual code into the research doc. Do not redesign
the solution — you answer "does it exist, and where?", not "should the design be
different?" (a wrong design is a BLOCKING finding, not a change you make). Do not
research the next slice — one slice per turn. Do not skip the refresh pass on
later slices; a stale doc is how the implementer silently rebuilds what already
exists.
