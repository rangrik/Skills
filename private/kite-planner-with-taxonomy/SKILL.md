---
name: kite-planner-with-taxonomy
description: >-
  Turns ONE approved system-design slice (`slice-N-<short>-system-design.md`
  from kite-system-design-blueprint-slices) into an ordered,
  scenario-by-scenario implementation plan — code-blind, grounded in the
  slice's design decisions, the platform's `SYSTEM_TAXONOMY.md`, and
  kite-design-system-standards. Orders the slice's scenarios for maximum
  reuse, plans each, and emits one consolidated set of research questions,
  then auto-spawns kite-plan-conformance-review to check it. Step 4 of the
  Kite pipeline (after solution-design, before research). Triggers on "plan
  this slice", "create the implementation plan for slice N", "turn this system
  design into a plan", or "order the scenarios for this slice" — even when the
  word "plan" is never said. Not for product behavior (slice-blueprint), the
  system design itself (kite-system-design-blueprint-slices), or reading the
  codebase (kite-research). Scope: appsmith-v2/Kite.
---

# Kite Planner (with taxonomy)

You turn **one** approved system-design slice into an ordered,
scenario-by-scenario implementation plan for that slice — **without looking at a
single line of source code**. You build *on top of* the slice's design: it
already decided _how_ the system should achieve the behavior; your job is to
break that into the ordered, buildable scenarios an implementer will work, and
to name the open codebase questions that must be answered first.

## Why this skill exists, and the one rule that defines it

Planning and codebase research are deliberately separate jobs. If you plan while
reading the code, you anchor on what the code already does and quietly plan
around what is convenient today instead of what the slice's design intends. You
also lose the ability to tell, later, whether a capability _should_ exist or
merely _happens_ to exist.

So the rule: **while using this skill, do not open, read, grep, or reference
source code.** Your inputs are the slice's system-design spec, the behavior
slice it designs, `SYSTEM_TAXONOMY.md`, and `kite-design-system-standards`.
Deciding what already exists in the codebase is the research stage's job
(`kite-research`). Your job is to work out what the slice _needs_, in build
order.

## One slice at a time — and stop

You plan **exactly one slice** and then **stop**. You do not roll on to the next
slice in the stack on your own, even when more remain. The pipeline maps
one-to-one (one behavior slice → one system-design spec → one plan), and a human
gate sits between slices. When you finish, say which slice is done and offer the
next one — don't start it.

## Inputs to gather first

1. **The slice's system-design spec** — `slice-N-<short>-system-design.md`. This
   is your primary source: its Decisions (D#), Tradeoffs, Assumptions, Scope,
   Risks, Constraints, Dependencies, the data-flow narrative, and especially its
   **§ Open Questions for the Codebase**. The design has already been made; you
   plan to it, you do not re-make it. If the user hasn't said which slice, list
   the `*-system-design.md` files and ask (plan in stacked order).
2. **The behavior slice** — `slice-N-<short>.md`. The source of truth for
   _behavior_: its scenarios (happy-path + deviations), scope, preconditions, and
   `Builds on:` line. Every scenario this slice owns must appear in your plan.
3. **`SLICES.md`** — the stack context, the coverage ledger, and any addendum.
   Read the `Builds on:` line so you know which earlier slices' capabilities this
   one assumes (reference them; don't replan them). **If an addendum contradicts
   the original tables, the addendum wins** — plan to the corrected facts.
4. **`SYSTEM_TAXONOMY.md`** (the `system-taxonomy` skill's output, at the repo
   root). This is the **source of names for every Subsystem collaboration** (see
   below): its canonical subsystem and concept names are how the plan speaks the
   team's language — "the **Snapshot** store", "the **domains** subsystem" —
   instead of inventing synonyms. It needs to be good enough to name every
   collaborator a scenario relies on; when it isn't, **Step 3's "When the taxonomy
   can't name a collaborator"** tells you how to enrich it rather than invent a
   name. If it is absent entirely, name things plainly and don't block on it.
5. **`kite-design-system-standards`** (Mode A — guidance lookup). The platform's
   engineering principles and Component Map. Use it to keep each scenario's
   collaboration conformant: its **Component Map and layering principles decide
   which subsystem may own each role** in the hand-off — routes don't write to the
   DB, a service does `[P1]` — and you cite the governing principle when a role
   assignment or ordering choice rests on one. You don't need to understand the
   skill's internals — consult it the way its own instructions describe, pull only
   the principles your scenario touches, and cite them by number (e.g. `[P15]`).

Treat the design spec and the behavior slice as fixed. If they genuinely
contradict each other or leave a gap an implementer couldn't close, say so
plainly and flag it — don't invent a resolution or quietly re-architect.

## What you produce

A single **plan file** for this slice, written next to the slice as
`slice-N-<short>-plan.md`, following `references/plan-file.md`. It is a living
document — later pipeline stages append to it — so write it to be appended to,
and never put code in it. Read `references/plan-file.md` before writing; it is
the output contract shared with `kite-research` and `kite-implementation`.

## Step 1 — Inventory every scenario the slice owns

Pull every scenario this slice owns from the behavior slice: happy paths,
deviations, edge and corner cases alike. Cross-check against the design spec's
**Slice Coverage Checklist** so nothing the design accounted for is dropped.
**Reference each scenario by its stable ID** (`HP-1`, `DEV-7.3a`) into the slice file
and tag its type (`happy_path | edge_case | corner_case`) — do **not** re-copy the
`Given / When / Then` into the plan. The slice file is the authoritative Gherkin; the
plan points at it by ID so the behavior lives in exactly one place.

A corner case dropped here becomes a production incident later, so the inventory
is your guardrail against accidentally planning only the happy path. If two
scenarios are tightly coupled you may combine them into one only when the
resulting Gherkin still proves both behaviors; otherwise keep them separate.

## Step 2 — Order the scenarios for maximum reuse

Decide the order in which this slice's scenarios should be built, so each
scenario can stand on capabilities earlier ones already created and later work
gets cheaper.

Heuristics:

- Foundational scenarios first — the ones that establish capabilities others
  lean on (often the happy path that lays down the data path the design spec's
  flow describes).
- Prefer scenarios that unlock reusable building blocks early.
- Identify dependency chains between scenarios and respect them.
- Every scenario is a **vertical slice** — full stack, end to end. Never order or
  plan by layer. "Do all the database work first" is wrong: it produces nothing a
  user can exercise and defers all integration risk to the end.

Write down _why_ each scenario sits where it does. The order is a claim, and the
next stages should see your reasoning. Make it visible in two places: the
`Scenario order & status` table (every scenario `planned`), and each scenario's
`Order` field plus a one-line reason naming the reuse or dependency relationship
("builds on the fetch+store path from S1", "hardens the save route after the
basic write path exists").

## Step 3 — Plan each scenario (code-blind, grounded in the design)

For each scenario, reasoning only from the design spec, behavior slice,
taxonomy, and standards, write:

- **Design references** — the design decisions this scenario realizes, cited
  (`D2`, `§2.2`, the relevant Risk/Constraint). This is what keeps the plan
  faithful to the design instead of re-deciding it.
- **Preconditions** — what must be true before this scenario can be implemented.
- **Required capabilities** — the concrete things the scenario needs to exist
  (for example, "a way to persist one Snapshot per fetch keyed by normalized
  domain"). Describe the capability in taxonomy vocabulary; **do not assert
  whether it already exists** and do not name a file or symbol. Where a
  capability is shaped by a principle, cite it (`[P18]` for the migration
  convention, `[P1]` for layering). This is the scenario's **parts list** — what
  must be true — not yet how the parts are wired.
- **Subsystem collaboration (how to achieve it)** — the new heart of the plan,
  described in full below. The capabilities say *what* must exist; this says
  *who does what, in what order* — the ordered hand-off between named subsystems
  that actually delivers the behavior. Write it for every scenario.
- **Postconditions** — what is true once the scenario is implemented.
- **Risks / assumptions** — anything uncertain, and which design-spec decisions,
  accepted compromises, or quality expectations apply.

Keep required capabilities **concrete but abstract**: "a way to authorize
app-scoped writes" or "a transaction that stores all-or-nothing," not "the
existing auth middleware" or a path. Preserve the design's named decisions,
constraints, accepted compromises, and quality expectations; if you find
yourself wanting a different architecture because it feels convenient, that's a
finding to flag, not a change to make.

### The Subsystem collaboration — how the scenario gets achieved

A list of required capabilities is a parts list: it tells the implementer what
must exist, but not how the pieces fit. The question the next stages actually
need answered is **how would this be implemented** — and the honest, code-blind
way to answer it is to name the **subsystems** that collaborate and the **order**
in which they hand off to each other. So each scenario also carries a
**Subsystem collaboration**: an ordered hand-off, written entirely in
`SYSTEM_TAXONOMY.md` names, that makes four roles explicit —

- **who receives** — the entry point that takes the request or the incoming data;
- **who owns the decision** — the subsystem that makes the scenario's key branch
  or choice (resolve which domain, accept or reject, success vs. failure);
- **who writes** — the subsystem that persists or produces the result;
- **who handles the failure branch** — for every deviation / edge / corner
  scenario, the subsystem that owns the error path (a happy-path scenario may
  legitimately have none yet — say so).

Read it as a choreography: subsystem A receives, passes to B, B decides, C
writes, D catches the failure. Order it the way the data actually moves — the
design spec's data-flow narrative is your guide — and let the **standards'
Component Map and layering principles decide which subsystem may own each role**
(routes don't write to the DB, a Service does `[P1]`), citing the principle that
places it. Where the hand-off reuses a path an earlier scenario laid down, say so
("reuses S1's DataForSEO-adapter → Snapshot-store seam") — that is the same reuse
relationship your ordering claimed in Step 2, now made concrete.

Because you are **code-blind**, you cannot know these subsystems exist or own
these responsibilities today — you are *prescribing* the collaboration from the
taxonomy, the design, and the standards, not reporting it from the code. So mark
the whole block **prescriptive — to be verified by research**. That label is not
a hedge; it is the hinge of Step 4: every place the prescribed hand-off might not
hold becomes a research question.

The distinction to hold onto: the **taxonomy gives you the cast and their general
roles** (the noun — "the Snapshot store persists snapshots"); you **prescribe the
specific choreography** for this scenario (the verb — "persists one row per fetch,
keyed by normalized domain, all-or-nothing"); and whether that specific
choreography holds in the code is **research's** job, never yours and never the
taxonomy's.

### When the taxonomy can't name a collaborator

The collaboration only works if you can put a real, shared name on each role.
When you can't — the taxonomy has no term for the subsystem that would own a
hand-off — resolve it cheapest-first, and never by reading code yourself:

1. **Check the standards' Component Map first.** `kite-design-system-standards`
   names the platform's components; the owner you're missing is often already
   there. Use that name and cite the principle that places it. This needs no code
   and no subagent.
2. **If it's still unnamed, enrich the taxonomy — via a subagent, not yourself.**
   Spawn a small subagent that runs the `system-taxonomy` skill, scoped to *just*
   the missing subsystem(s): "discover and add the subsystem that owns
   <responsibility> — its canonical name, its responsibility, and its
   relationships to <neighbors> — and write it into `SYSTEM_TAXONOMY.md`." The
   subagent may read source code, because that is the taxonomy skill's job; it
   works for the **taxonomy document**, not for you.

   Two boundaries keep you code-blind, and they are not optional:
   - The subagent returns **only** the taxonomy names it added (and that it
     updated the doc). It must **not** report files, symbols, paths, line
     numbers, or "this already exists at…" — nothing about the code. If it tries
     to hand you code facts, ignore them.
   - You then **re-read `SYSTEM_TAXONOMY.md`** and take the new names from there.
     You learn *vocabulary*, never *implementation*.

   Enriching the taxonomy gives you a name to write the hand-off with; it never
   lets you assert the hand-off is real. The block stays prescriptive-to-be-
   verified, and its gaps still become Step 4 research questions.

## Step 4 — Consolidate the slice-level research questions

Research questions live at the **slice level**, not per scenario — the codebase
truths an implementer needs ("does a DataForSEO client already exist?", "what is
the migration convention?") are shared across the slice's scenarios, and asking
them once keeps the handoff to `kite-research` clean.

Build the list in two moves:

1. **Carry forward** every question from the design spec's **§ Open Questions for
   the Codebase**. Those were authored at design altitude and are still owed;
   bring them in verbatim, preserving their original IDs as the source.
2. **Augment** with the _new_ questions that planning the scenarios surfaced. The
   richest source is now the **gaps in each scenario's Subsystem collaboration** —
   because that block is prescriptive-to-be-verified, every place the prescribed
   hand-off might not hold is a question:
   - **Existence of a named collaborator** — you named a subsystem from the
     taxonomy, but code-blind you can't know it exists or owns that role: "Does
     <subsystem> exist and own <responsibility> as prescribed? (Blocks S#.)"
   - **A hand-off seam** — does a path already connect two subsystems, or must one
     be created: "Is there an existing path from <A> to <B>, or must a seam be
     added? (Blocks S#.)"
   - **The failure-branch owner** — who handles <deviation> today, if anyone:
     "Does any subsystem already own <failure>, or is it unhandled? (Blocks S#.)"
   - **A still-unnamed role** — if even after the Component Map and a taxonomy
     enrichment a role has no clear owner: "What subsystem, if any, owns
     <responsibility> today? (Blocks S#.)"

   Also add any required capability whose existence/shape is unknown and isn't
   already covered by a collaboration-gap or a carried-forward question.

Then **dedupe and consolidate** into one ordered list. Each question must be
specific and answerable EXISTS / MISSING:

- Good: "Is there an existing service or helper that resolves an app's connected
  custom domain, and where? (Needed by S1, S4.)"
- Weak: "Look into the domain code."

When the user (or the design spec) says "we probably already have X," do not
bank it as fact — phrase it as a question for research to confirm. Note which
scenarios each question blocks, so research and implementation can sequence
around it.

## Step 5 — Write the plan file

Assemble everything into `slice-N-<short>-plan.md` using `references/plan-file.md`.
Set the slice and every scenario to status `planned`.

Before finishing, audit the plan:

- Every scenario the slice owns is referenced by its stable ID (a
  `→ slice-N-<short>.md › <ID>` pointer, not re-copied Gherkin), carries a type tag, and
  is in the order/status table.
- The order is justified by reuse or dependency, not by backend/frontend/database
  layers.
- Every scenario has Design references, Preconditions, Required capabilities, a
  **Subsystem collaboration** block, Postconditions, and Risks / assumptions.
- Each Subsystem collaboration is an ordered hand-off in `SYSTEM_TAXONOMY.md`
  names, makes the roles that apply explicit (who receives / owns the decision /
  writes / handles the failure branch — every deviation scenario names a
  failure-branch owner), and is marked **prescriptive — to be verified**.
- The slice-level research questions carry forward every §-Open-Question and add
  one for each collaboration gap (plus any unknown capability) — deduped, each
  EXISTS/MISSING-answerable, each noting the scenarios it blocks.
- The plan contains no source-code paths, grep/search results, or claims that a
  capability or collaborator already exists.

## Step 6 — Auto-review, then hand off

After writing the plan, **spawn a subagent that runs `kite-plan-conformance-review`**
on it. Give the subagent the absolute paths to the plan file, the slice's
system-design spec, and the behavior slice. That review checks the plan's
coverage and conformance against the design, **fixes what it safely can**
(a missing scenario, a dropped §-Open-Question, a layer-ordered sequence, a
stray code reference), and returns a short report of what it fixed plus any item
it could **not** resolve without a human.

Then:

- If the review surfaced **human-needed** items (a genuine design/behavior
  contradiction, a scope question, a decision that looks wrong), present them
  plainly and stop for the human. These should be rare — most findings at this
  stage are mechanical and the reviewer fixes them itself.
- Otherwise, report that the slice plan is written and reviewed clean, and offer
  the next slice (in stacked order) — **without starting it**.

The finished plan file goes to `kite-research`, which answers the slice-level
research questions against the real codebase, then to `kite-implementation`.

## Optional — fan out for a large slice

For a slice with many scenarios, you may spawn one subagent per scenario to do
Step 3 in parallel, each given that scenario plus the design spec in isolation.
You remain the orchestrator: do Steps 1–2 and Step 4 yourself (ordering and the
consolidated research questions are slice-wide, not per scenario), then merge the
per-scenario plans into the one ordered plan file before the Step 6 review.

Resolve any **taxonomy gaps before you fan out** — run the "When the taxonomy
can't name a collaborator" enrichment first, so every parallel scenario-planner
reads one complete `SYSTEM_TAXONOMY.md` and names collaborators consistently.
Two subagents enriching the taxonomy at once would race on the same file.

## Staying in your lane

Do not write code. Do not read code — not even through the taxonomy-enrichment
subagent: it works for the taxonomy doc and returns only names, never files or
symbols, and you take new names by re-reading `SYSTEM_TAXONOMY.md`. Do not skip
the ordering step. Do not plan a scenario as horizontal layers. Do not re-decide
the design — if a decision looks wrong, flag it, don't fork it. Do not declare
what already exists, and do not assert a prescribed collaboration is real — if
you catch yourself writing "this already exists in…", stop: that is a research
finding, not a plan. Do not roll on to the next slice.
