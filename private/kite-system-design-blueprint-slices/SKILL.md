---
name: kite-system-design-blueprint-slices
description: >-
  Takes one approved behavior slice (a `slice-N-*.md` from a `<feature>-slices/`
  directory produced by slice-blueprint) and works out HOW the system should
  achieve that behavior, at a high-level system-design altitude (NOT
  implementation detail). Works one slice at a time and writes one spec per
  slice as a sibling (`slice-N-<short>-system-design.md`). It reasons like a
  senior architect across every concern (data shape & integrity, performance,
  reliability, security, cost, rollout, …), using a data-movement lens as the
  entry point — do we have the data or generate it, how does it travel to the
  product surface, which existing subsystems act on it and with what effect. It
  is CODE-BLIND: it never reads source; instead it grills the user to resolve
  the unknowns only the USER can answer (intent, approach, trade-offs) and
  records the unknowns only the CODEBASE can answer as a separate list of
  research questions. The output enumerates Decisions, Tradeoffs, Assumptions,
  Scope (in & out), Risks, Constraints, and Dependencies, plus the data-flow
  narrative and the codebase questions. It consults
  `kite-design-system-standards` for the platform's principles and may read the
  repo's `SYSTEM_TAXONOMY.md` to name subsystems. Fires on "design the system
  for this slice", "solution design for slice N", "how should the system achieve
  this", "grill me on the design for this slice", or whenever an approved slice
  exists and the next job is its technical design — even when the user only says
  "design this slice". Not for product behavior (blueprint, then slice, first).
  Not for reading the codebase (that is the research stage). Not for
  step-by-step implementation tasks (that is planning). Scope is the appsmith-v2
  / Kite platform.
---

# Kite Slice System Design

**Step 3 of the Kite pipeline: Solution Design — how should the system achieve
this behavior?** You take one approved behavior slice and produce a high-level
technical spec for how the system makes that slice real: where its data comes
from and how it moves, which subsystems act on it, and the decisions,
trade-offs, risks, and constraints that shape the build — reasoning like a
senior architect and grilling the user to resolve every unknown that only they
can answer.

You work **one slice at a time** and produce a **one-to-one** output: for
`slice-2-refresh.md` you write `slice-2-refresh-system-design.md` next to it.
The spec, the slice, and a list of codebase questions are the artifact this step
hands forward (after human approval) to planning and research.

## What this skill is really for: resolve the unknowns

A slice tells you _what the product should do_. This step works out _how the
system should achieve it_ — well enough that the build can then proceed almost
mechanically from sound engineering principles. The way you get there is by
**surfacing the unknowns and resolving the ones only the user can answer.**

There are two kinds of unknown, and keeping them apart is the heart of this
skill:

- **User-answerable unknowns** — questions about _intent and approach_ that no
  amount of code-reading would settle: do we already have this data or do we
  generate it (and how — a route, our own AI agent, a third-party integration)?
  what data is it, roughly, and what integrity does it need? what trade-offs are
  acceptable? how fresh must it be? **You grill the user to resolve these.**
  They are what block an implementer from proceeding.
- **Codebase-answerable unknowns** — _does X already exist? where is Y wired?
  what is the current shape of Z?_ These you do **not** answer (you are
  code-blind) and do **not** ask the user to play compiler for. You record them
  as a **list of questions for the codebase**, which the research stage answers
  later.

The bar for "done" is **autonomy**: the spec is complete when no user-answerable
unknown remains — when an implementer holding this spec, the codebase, and good
engineering principles could build the slice **without coming back to ask the
user anything**. Whatever is still open should be a codebase question, not a
product or intent question.

## The one rule: stay code-blind

**While using this skill, do not open, read, grep, or reference source code.**
Finding what already exists is a _different job_, owned by the research stage
(Step 5). If you design while reading code you anchor on what is convenient
today instead of what the slice needs, and you can no longer tell whether a
capability _should_ exist or merely _happens_ to. So every "does it already
exist" question becomes a recorded codebase question, never an investigation —
and a confident "we already have that" from the user is recorded as a question
too, not banked as fact.

## When to use

Use this once a feature's behavior has been sliced (a `<feature>-slices/`
directory exists) and a slice is approved, and the open question is _how the
system should achieve that slice's behavior_. This is Step 3, after
`slice-blueprint` (Step 2) and before planning (Step 4).

**When NOT to use:**

- Defining what the product does, happy paths, or edge cases → the **blueprint**
  (Step 1). Cutting it into slices → **slice-blueprint** (Step 2). Both first.
- Discovering what already exists in the codebase → the **research stage** (Step
  5). This skill only _poses_ those questions.
- A scenario-by-scenario implementation plan → a **planning skill** (Step 4),
  after this. This skill is high-level design, not implementation steps.

## Inputs to gather first

1. **The slice.** Read the one `slice-N-<short>.md` you are designing. It is the
   source of truth for behavior — its scenarios, scope, preconditions, and
   `Builds on:` line. Never re-derive or change the behavior here. If the user
   hasn't said which slice, list them and ask (design in stacked order).
2. **The stack context.** Read `SLICES.md` and the `Builds on:` line so you know
   which earlier slices' capabilities this one assumes. Reference their designs;
   don't redesign them.
3. **`kite-design-system-standards` (for consideration).** Consult it (Mode A)
   for the platform's engineering principles and its Component Map. It is how
   you keep recommendations conformant and how you _push back_ when the user's
   intent would bend a principle. If it can't be consulted, fall back to
   `references/design-principles.md` and note that in the output.
4. **`references/decision-taxonomy.md`** — the architect's lens: the full list
   of concerns to walk so nothing is silently skipped. This is the forcing
   function that was always central to this skill.
5. **`SYSTEM_TAXONOMY.md`** (optional, if present in the repo). Use its
   canonical names for subsystems and concepts — especially for "which
   subsystems act on the data" — so the spec speaks the team's language. If
   absent, proceed and name things plainly; don't block on it.

### Precedence & authority

In the Kite repo, `kite-design-system-standards` is authoritative and supersedes
the generic `references/design-principles.md` — on conflict, the Kite standard
wins, and recommendations cite the governing Kite principle by number. The
generic principles are the gap-filler for concerns the standard is silent on. If
the standard doesn't cover something, say so rather than inventing a principle.

## The entry lens: how is the data sourced and moved?

Start every slice by answering three questions about its data — this is the
fastest way into "how does the system achieve this behavior," and it surfaces
the biggest user-answerable unknowns early. Answer them in
`SYSTEM_TAXONOMY.md`'s vocabulary where you can.

1. **Source — do we have this data, or do we generate it?** Is it already
   produced/stored by an existing subsystem, supplied by the user, fetched from
   a third party, or generated (e.g. by one of our own AI agents)? "Have it" and
   "generate it" lead to very different designs — pin which.
2. **Travel — how does the data get from its origin to the product surface?**
   Trace the path, subsystem by subsystem, from where the data is born to where
   the user sees or uses it per the slice's scenarios.
3. **Actors & effects — which existing subsystems create, read, update, delete,
   or act on this data, and what is the effect when they do?** Name the
   subsystems on the path and the side-effects of each acting on the data
   (events emitted, downstream work triggered, caches affected, billing
   consumed).

This lens is the _way in_, not the whole design. Once the data path is sketched,
the full architect's lens (next) covers everything the data questions don't —
data shape and integrity, performance, reliability, security, cost, rollout, and
the rest.

## Process

### P1 — Absorb

Read the slice, the `Builds on:` context, and `SLICES.md`. Consult
`kite-design-system-standards` for the governing principles. Read
`SYSTEM_TAXONOMY.md` if present. Internalize `references/design-principles.md`
as the gap-filler. **Read no source code.**

### P2 — Work out how the system achieves the behavior, and map the unknowns

Sketch the **entry lens** (source → travel → actors & effects). Then walk
**every dimension in `references/decision-taxonomy.md`** — the architect's
coverage — at a **high-level system-design altitude** (which subsystem owns it,
the rough data shape and integrity, the performance/reliability/security
posture; _not_ column DDL, migration SQL, or function signatures — that depth
belongs to planning and implementation). For each concern, look up the governing
standard and classify it:

- **(a) safe default assumption** — state it so the user can correct it;
- **(b) user-answerable unknown** — an intent/approach fork only the user can
  settle; queue it for the interview, with a recommendation;
- **(c) codebase question** — a fact only the code can settle; record it for the
  research stage (this is also where "we already have X" goes);
- **(d) N/A** — justify why it doesn't apply to this slice.

**Then share the map before interviewing.** Show the user a compact sketch: the
data path, the assumptions you're making, the user-answerable unknowns queued
for the interview, the codebase questions you'll hand off, and what you've ruled
N/A. This lets them correct a miscategorization while it's cheap.

### P3 — Grill the user (resolve the user-answerable unknowns)

Drive the queued unknowns (bucket b) to resolution in **dependency order**,
using `AskUserQuestion` with the **recommended option first**. Resolve linked
decisions one at a time; group genuinely independent ones to keep the interview
short.

- **Every recommendation cites a principle.** Ground it in the governing Kite
  principle (look up the number in `kite-design-system-standards`); where the
  standard is silent, use the generic lens by name.
- **Push back — don't just transcribe.** When the user's intent would bend a
  principle (couple subsystems that should stay decoupled, skip idempotency,
  cache with no invalidation story, let one subsystem reach into another's
  data), name the principle, explain the failure it invites, and offer the
  conforming alternative. If they still choose it, it becomes a recorded
  **accepted compromise** naming the bent principle — never a silent deviation.
- **Probe the technical unknowns too.** The data questions open the door; follow
  them with the architect's questions — what is the data, roughly? what
  structure and integrity does it need? what can go wrong? how fresh must it be?
  what's the performance expectation? — but keep the answers at design altitude.
- **Convert "we already have it" into a codebase question.** Don't design around
  an assumed implementation; state the capability the slice needs and let the
  research stage confirm whether it exists.
- **Hold scope.** Every question stays tied to _this slice_. New product
  questions belong in the blueprint; earlier-slice concerns get referenced, not
  re-decided.

### P4 — Last call & the autonomy check (mandatory gate)

Before writing, ask explicitly:

> "Before I write this up — is there anything we've missed for this slice? Any
> concern, constraint, side-effect, or intent not yet captured?"

Then apply the **autonomy test**: _could an implementer with this spec, the
codebase, and good engineering principles now build the slice without asking the
user anything more?_ If a user-answerable unknown is still open, loop back into
P3. Whatever remains open must be a codebase question. Don't skip this gate.

### P5 — Write the spec

Produce `slice-N-<short>-system-design.md` next to the slice, using
`references/design-doc-template.md`. The spec captures, at a high-level
altitude:

- the **data flow** (the entry lens: source / travel / actors & effects) and a
  **high-level system view** of which subsystems are new / modified / reused;
- the standard enumeration shared across the pipeline's artifacts — **Decisions
  · Tradeoffs · Assumptions · Scope (In & Out) · Risks (what can go wrong) ·
  Constraints · Dependencies** — each first-class;
- the **Open Questions for the Codebase** (the research handoff);
- two coverage checklists (decision-taxonomy dimensions; the slice's scenarios);
- an appendix faithfully capturing the interview.

### P6 — Stop and hand off

Deliver a short summary and stop. The spec is the deliverable; it goes to
**human approval** (the pipeline's Step 3 gate), then to planning (Step 4) with
its codebase questions feeding research (Step 5). Don't invoke those skills
here. If more slices remain, offer the next one (in stacked order), each its own
file.

## Principles for running this skill

- **Resolve the user-answerable unknowns; defer the codebase ones.** The whole
  value is separating intent (grill the user, resolve it) from code truth
  (record it, hand it off). The autonomy test is the bar.
- **Architect's lens central; data-movement is the way in.** Walk the full
  decision taxonomy so no concern is silently skipped; the source/travel/actors
  questions are the high-leverage entry point, not the whole design.
- **High-level, not implementation.** This is a system-design view — subsystems,
  data shape, integrity, posture, decisions. Column-level schemas, migrations,
  and function signatures belong to planning and implementation, not here.
- **Code-blind by construction.** Reason from the slice, standards, taxonomy,
  and user — never source. Anything needing code truth is a recorded question.
- **Standards-grounded, and pushed back against.** Every decision cites the
  principle it upholds; every compromise names the one it bends. A departure is
  named and recorded, never silent.
- **Recommendation discipline.** Every question carries a recommendation with a
  principle-grounded reason; the user can always override.
- **One slice, one file, stacked.** Design the slice in front of you; lean on
  the designs it builds on; leave later slices to their own files.

## Output structure

See `references/design-doc-template.md`. In short: Summary → Data Flow (source /
travel / actors & effects) → High-Level System View (new / modified / reused) →
Decisions → Tradeoffs → Assumptions → Scope (In & Out) → Risks → Constraints →
Dependencies → Open Questions for the Codebase → Decision Coverage Checklist →
Slice Coverage Checklist → Appendix A: Captured Inputs.

## Gotchas

- **Don't read the code.** If you're about to grep or open a file, stop — that's
  a codebase question, not a design step.
- **Don't drop to implementation altitude.** Resist column DDL, migration SQL,
  and function signatures. Decide _what_ and _which subsystem_, not _how to code
  it_. The downstream steps own that.
- **Don't let the data lens crowd out the architect's lens.** The three data
  questions are the entry point; integrity, performance, reliability, security,
  cost, and rollout still get walked.
- **Don't redefine product behavior.** Behavior belongs to the slice/blueprint.
  A behavior gap is a finding to flag back, not something to invent here.
- **Don't design the whole feature at once.** One slice, one spec. Designing all
  slices together loses the one-to-one mapping the pipeline relies on.
- **Don't redesign earlier slices.** Reference what a `Builds on:` slice
  established. If it's actually wrong, flag it — don't quietly fork it.
- **"We already have X" is a codebase question, not a fact.** However confident
  the user is, a claim about what exists is unverified until research checks it.
