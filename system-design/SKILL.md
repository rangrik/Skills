---
name: system-design
description: >-
  Use this skill when a feature's product behavior is already pinned down
  (usually in a behavior blueprint) and the next job is designing HOW it gets
  built — the system and architecture decisions that make it production-grade.
  Fires on "design the system for this", "what's the architecture for X", "grill
  me on the system design", or "turn this blueprint into a technical design" —
  even when the user only says "design the solution". It reads the blueprint and
  reasons about every concern a senior architect would (placement, data model,
  caching, latency, scale, reliability, third-party integrations, security,
  observability, cost, rollout), interviewing the user decision by decision with
  a recommendation each time, then writes a system-design document read
  alongside the blueprint. Not for defining product behavior or edge cases —
  write the blueprint first. Not for loose ideas with no behavior spec —
  brainstorm first. Not for step-by-step implementation tasks — that's a
  planning skill, after this. BTW, kite & appsmith-v2 are the same project,
  names are used interchangeably.
---

# System Design

Turn a finished **behavior blueprint** into a **production-grade
system/architecture design** — by reasoning like a senior architect, grilling
the user decision by decision with a recommendation every time, and writing a
design document that reads alongside the blueprint.

## When to use

Use this when product behavior is already specified (a `<feature>-blueprint.md`
exists, or the user describes settled behavior) and the open question is _how
the system is built_: where it lives, the data model, caching, latency/scale,
concurrency, reliability, third-party contracts, security, observability, cost,
and rollout.

**When NOT to use:**

- Defining what the product does, the happy path, or edge cases → that's the
  **behavior blueprint**. Write it first; this skill consumes it.
- A loosely-stated idea with no behavior spec yet → **brainstorm** first to
  settle intent.
- A generic conversational stress-test with no deliverable → that's
  **grill-me**; this skill produces a document.
- Breaking the design into step-by-step implementation tasks → that's a
  **planning skill** (`writing-plans` / `create-plan`), which runs _after_ this.

## Inputs to gather first

1. **The blueprint.** Locate and read `<feature>-blueprint.md` (typically at
   repo root). It is the source of truth for behavior — never re-derive or
   change it here. If no blueprint file exists but the user has described
   settled behavior inline, restate that behavior in your own words and get
   their confirmation before proceeding — the design needs a fixed behavioral
   target. If the behavior is still loose or contested, stop and steer them to
   settle it first (brainstorm, then blueprint); designing a system on top of
   unsettled behavior wastes the interview.
2. **The authoritative architecture standard.** **In the appsmith-v2 / Kite
   repo, the `kite-arch-compass` skill is the front door** — invoke it (Mode A,
   guidance lookup) before proposing anything. It carries the Kite-specific
   engineering principles and a Component Map (each component → the principles
   that govern it). Map the feature to its component(s), read the governing
   principles, and let them shape every recommendation. If `kite-arch-compass`
   can't be invoked, fall back to the supporting references below and the
   generic lens — and note in the output document that the authoritative
   standard could not be consulted, so the design rests on the generic lens
   alone.
3. **Supporting references** for detail the compass points to:
   `agent-context/architecture/system-overview.md` (component map, module
   inventory, orchestrator loop), `backend/docs/rules/` (`module-taxonomy.md`,
   `error-handling.md`, `celery-tasks.md`, `feature-flags.md`,
   `orchestrator-tools.md`), `frontend/claude.md` (frontend architecture, state,
   token rules), and `docs/decisions/` (precedent ADRs — reuse prior decisions
   instead of re-litigating them).
4. **Outside the Kite repo:** `kite-arch-compass` does **not** apply (it is
   strictly Kite-scoped). Use that repo's own architecture docs, conventions,
   and decision records, plus the generic reasoning lens below.

### Precedence & authority

In the Kite repo, **`kite-arch-compass`'s principles are authoritative and
supersede the generic `references/design-principles.md`** — on any conflict, the
Kite standard wins. The generic principles are the **cross-project default** and
a **gap-filler** for concerns the compass is silent on (e.g. explicit latency
targets, accessibility, least-surprise). If the compass doesn't cover a
question, say so plainly rather than inventing a Kite principle (per its own
"honesty about coverage" rule).

## Process

### P1 — Absorb

Read the blueprint and the relevant architecture references. **In the Kite repo,
invoke `kite-arch-compass` (Mode A)**: find the feature's component(s) in its
Component Map and read the governing principles. **Internalize
`references/design-principles.md`** as the cross-project lens and gap-filler.
Sketch the candidate solution shape in your head.

### P2 — Map the decision surface

Walk every dimension in `references/decision-taxonomy.md`. For each, look up the
governing standard (Kite repo: `kite-arch-compass` component → principles;
otherwise the generic lens), evaluate the candidate against it, and classify it
as one of:

- **(a) safe default assumption** — state it plainly so the user can correct it;
- **(b) requires a user decision** — queue it for the interview;
- **(c) N/A** — justify why it doesn't apply to this feature.

Prefer answering from the codebase / the compass over asking the user. Only
genuine forks reach the interview.

**Then share the map before interviewing.** Show the user a brief sketch of the
candidate solution shape, the assumptions you're making (so they can correct
any), the genuine forks queued for the interview, and what you've ruled N/A.
This orients the user, signals how long the interview will be, and — most
valuable — lets them catch a miscategorization (a real decision you filed as a
safe assumption) while it's still cheap to fix. Invite correction, then move
into the interview.

### P3 — Interview (relentless, dependency-ordered)

Drive the queued decisions to resolution in **dependency order**, using
`AskUserQuestion` with the **recommended option first**. Resolve
dependency-linked decisions one at a time — you can't sensibly settle caching
before you know whether the fetch is sync or background. Independent decisions
don't need that discipline: group two or three into a single `AskUserQuestion`
call so the interview doesn't drag.

- **Every recommendation's rationale is grounded in a principle.** In the Kite
  repo, **cite the governing Kite principle by its compass number** — look the
  number up in the compass, don't recall it from memory (e.g. "recommend a
  background refresh job, citing `[P<n>]` for asynchronous/backpressured work
  and `[P<n>]` for idempotency"). Where the compass is silent, or off-repo, fall
  back to the generic lens (e.g. "_cache invalidation is a design decision_").
- **Surface assumptions and compromises live.** When you default something, say
  so and invite correction. When you trade something away, name the compromise
  explicitly, **say which principle it bends (the Kite principle number
  in-repo)**, and confirm it's acceptable. This follows `kite-arch-compass`'s
  deviation rule — a departure must be named, justified, and recorded; an
  undocumented deviation is itself a finding.
- **Don't let scope drift.** Every question stays tied to building _this_
  blueprint, in production. If the user opens a new product question, note that
  it belongs in the blueprint and steer back.

### P4 — Last call (mandatory gate)

Before writing anything, explicitly ask the user:

> "Before I write this up — is there anything we've missed? Any concern,
> constraint, or context not yet captured?"

If anything surfaces, loop back into P3 and resolve it. Do not skip this gate.

### P5 — Write

Produce `<feature>-system-design.md` (next to the blueprint, at repo root) using
`references/design-doc-template.md`. The synthesized design goes up top; the
captured interview goes in the appendix.

Then fill **both** completeness checklists — they catch different gaps:

- **Decision Coverage Checklist** — every taxonomy dimension marked Resolved /
  Assumed / N/A, so no _architectural dimension_ is silently skipped.
- **Blueprint Coverage Checklist** — walk the blueprint top to bottom and map
  every behavior rule, edge case, and deviation/adversarial scenario to where
  the design handles it. The taxonomy checklist proves the dimensions were
  covered, but a feature can pass every dimension and still drop a blueprint
  behavior that belongs to no single dimension — a partial-window edge case, a
  stated cap like "show up to ten items", a specific deviation. Any blueprint
  item with no home is either a missing design decision (go resolve it) or a
  genuine N/A (say why) — never a silent omission.

### P6 — Stop

Deliver a short summary and stop. The document is the deliverable. You may note
in one line that it can feed a planning skill or a decision record next — but do
not invoke them or generate them here.

## Principles for running this skill

- **Production-grade lens.** Even if the feature is agentic, it ships to
  production; reason about every quality attribute, not just the happy path.
- **Authoritative standard first.** Reason from the governing standard —
  `kite-arch-compass` in the Kite repo, the generic lens elsewhere (the
  precedence rule lives in **Precedence & authority** above). Every decision
  cites the principle it upholds; every compromise names the one it bends and
  follows the deviation rule.
- **Recommendation discipline.** Every question carries a recommendation with a
  reason. The user can always override.
- **Assumption/compromise honesty.** Defaults and trade-offs are stated out loud
  and land in their own tables in the document — never buried in prose.
- **Codebase-aware.** Explore the codebase and the compass before asking; fit
  existing patterns over invention.
- **Completeness via two checklists.** The taxonomy coverage table proves every
  _architectural dimension_ was considered; the blueprint coverage table proves
  every _blueprint behavior, edge case, and deviation_ was. A feature can pass
  the first and still silently drop something only the second catches — both are
  forcing functions, not formalities.

## Output structure

See `references/design-doc-template.md`. In short: Summary → System Placement →
Architecture Decisions (ADR-style, each citing the principle it upholds) → Data
Model → External Services → Performance/Scale/Caching → Reliability → Security →
Observability → Rollout → Assumptions → Compromises → Open Risks → Out of Scope
→ Decision Coverage Checklist → Blueprint Coverage Checklist → **Appendix A:
Captured Inputs** (the faithful interview record).

## Gotchas

- **Don't redefine product behavior.** Behavior, happy paths, and edge cases
  belong to the blueprint. If a behavior gap appears, flag it for the blueprint
  rather than inventing behavior here.
- **Assumptions and compromises get tables, not prose.** They are first-class
  artifacts the reader must be able to scan.
- **Don't apply Kite standards off-repo.** `kite-arch-compass` is strictly
  scoped to appsmith-v2 / Kite. In any other repo, use that repo's conventions
  and the generic lens — don't cite Kite principle numbers.
- **This skill is forward design (Mode A), not conformance review.** To validate
  an _already-built_ implementation against the standards, use
  `kite-arch-compass` Mode B (conformance review) — don't build that workflow
  here.
- **External-system grammar belongs in a skill, not the design prose.** URL
  parts, API parameters, query DSLs, escape rules — if probing the live system
  can surface invalid combinations, its home is a probe-tested skill, not a
  paragraph in the design doc. Note that as a follow-up rather than encoding the
  grammar inline.
