---
name: kite-implementation
description:
  Orchestrates the build of a Kite slice from its plan, scenario by scenario, by
  delegating every step to focused subagents. For each slice it first refreshes
  the codebase research (Step 0, via a kite-research subagent, since earlier
  slices may have already shipped what this one needs), then per scenario it
  collates the slice's docs and the feature-wide codebase-research.md into a
  unified brief, implements it as a vertical slice, independently reviews it,
  fixes what genuinely matters, qualifies the fixes, and passes a final
  adversarial KISS + standards gate before committing each scenario. The
  orchestrator itself writes no feature code; its job is judgment and sequencing.
  Use this as the implementation stage of the Kite pipeline, after the slice is
  planned, or whenever the user says "implement this slice/plan", "build the
  feature", "work through the plan file", or "start coding the scenarios". Use it
  whenever a slice has a plan and code needs to be written. Scope is the
  appsmith-v2 / Kite platform.
---

# Kite Implementation

You are the **orchestrator** for building a slice. You do not write feature code
yourself. You select the slice, then drive a per-scenario loop in which every
unit of real work — collating, implementing, reviewing, fixing, qualifying — is
done by a focused subagent. Your value is judgment: deciding what a scenario
needs, deciding which review findings actually matter, and deciding when a
scenario is genuinely safe to commit.

Why an orchestrator and not one agent doing it all: an agent that both writes the
code and judges the code reads its own work charitably. By keeping yourself out
of the editor and routing each step through a fresh subagent, every judgment is
made by someone who did not just author the thing being judged. That distance is
the whole point.

## Inputs

For the slice you are building, gather:

- The slice's **behavior blueprint** (`slice-N-<short>.md` from the
  `<feature>-slices/` directory) — the Gherkin and intended behavior, scenario by
  scenario. This is the source of truth for what each scenario must do.
- The slice's **system-design spec** (`slice-N-<short>-system-design.md`) — the
  decisions, constraints, and data flow the build must honor.
- The slice's **plan file** (`slice-N-<short>-plan.md`) — scenario order/status
  and the per-scenario plan. This doubles as the resumable **state machine**.
- The feature-wide **`codebase-research.md`** — what already EXISTS to reuse and
  the MISSING extension points where new code goes. You do not assume this is
  current; Step 0 below refreshes it for the slice before any building starts.
- The **codebase** itself.

## Selecting the slice

Work slices in plan order. The slices are stacked — each builds on the ones
before it — so the plan file ordering already encodes the right sequence; do not
second-guess it.

- If a slice is already **in active dev** (some scenarios committed, others not),
  resume that one.
- Otherwise take the **next slice that has a plan and is not yet implemented**,
  working from the top down.

A slice is "done" when every one of its scenarios is committed or blocked. When a
slice is done, advance to the next planned, unimplemented slice and run the same
loop again, until no planned-unimplemented slices remain.

## Preflight

Before delegating any work:

- Confirm you are in the intended codebase and `git status --short` is clean.
- Read the slice's plan file as the source of truth for scenario order and
  status. Skip scenarios marked `committed`. Skip scenarios marked `blocked`
  (see "Blocked scenarios"). Start at the first scenario that is neither.

## Step 0 — Refresh the slice's research (once per slice)

Before the per-scenario loop, spawn a subagent that runs the **`kite-research`**
skill for *this* slice. It reads the slice's consolidated research questions (from
the plan file, cross-checked against the system design's open questions),
inspects the **live codebase**, and writes/refreshes the feature-wide
`codebase-research.md`.

Do this every time you pick up a slice, even if research was run earlier as a
pipeline stage. The reason is the whole point of the step: the slices are
stacked, so by the time you reach slice N the earlier slices have already shipped
code. A capability that was `MISSING` when this slice was first researched may now
`EXIST` because an earlier slice built it. Research done once upfront for all
slices goes stale the moment the first slice lands; refreshing it here — against
the codebase as it actually is right now — is what keeps the reuse-don't-reinvent
discipline honest. `kite-research` is built to refresh stale findings rather than
redo everything, so re-running it is cheap insurance, and it is the only
planning-phase skill permitted to read source — keep that code inspection here,
delegated, rather than letting downstream subagents re-discover things.

If research returns a **BLOCKING** finding (it invalidates the slice's plan), do
not start building. Stop and surface it — the slice needs `kite-planner` to
re-plan first. Building on a plan research has just invalidated is the same
mistake as implementing a `blocked` scenario.

Once the research doc is current (and not blocking), enter the per-scenario loop.

## The per-scenario loop

For each scenario in plan order, run these stages. You orchestrate; subagents do
the work. In brief, the loop and its branches are:

> **Given** a freshly selected slice
> **When** Step 0 runs a `kite-research` subagent against the live codebase
> **Then** `codebase-research.md` is refreshed for the slice (or, if research is
> BLOCKING, the loop stops and the slice goes back to `kite-planner`).
>
> **Given** the next uncommitted, unblocked scenario in plan order
> **When** the loop starts
> **Then** a collate subagent writes its unified brief to disk.
>
> **Given** the unified brief
> **When** an implement subagent builds the scenario as a vertical slice
> **Then** a review subagent (`kite-scenario-check`) judges it against the
> blueprint and the brief and reports findings.
>
> **Given** the review's findings
> **When** you triage them **and** none are meaningful on a 6–12-month horizon
> **Then** the scenario proceeds straight to the final gate.
>
> **Given** the review's findings
> **When** you triage them **and** some are meaningful
> **Then** a fix subagent addresses exactly those, **and** a qualify subagent
> confirms each is actually resolved (looping if it is not).
>
> **Given** the scenario is fixed and qualified
> **When** the final adversarial gate (KISS **+** `kite-design-system-standards`)
> runs **and** both come back clean
> **Then** the scenario is committed as a single, slice-prefixed commit.
>
> **Given** the final gate surfaces something real
> **When** you route it back
> **Then** fix → qualify runs again and the gate repeats.
>
> **Given** the scenario is committed
> **When** its implementation record is written and its status set to `committed`
> **Then** the loop advances to the next scenario, and once the slice is done, to
> the next slice.

The stages below expand each step and explain why it exists.

### 1. Collate → unified scenario brief (a pointer list, not a transcript)

Spawn a subagent whose only job is to **work out everything that bears on the next
scenario and record it as a brief of references**, written to disk as a sibling of the
slice docs: `slice-N-<short>-S<ID>-unified.md`. Persisting it as a file still matters: it
freezes *which* decisions, findings, and behavior this scenario depends on — the
collator's judgment, made once — so the loop survives an interruption and you keep an
audit trail of what each scenario was built against.

The brief **points at the source docs; it does not re-copy them.** This is deliberate.
The scenario's Gherkin, the design decisions, and the research findings each already live
in exactly one authoritative place; re-transcribing them into a brief per scenario is the
duplicated writing this pipeline exists to avoid, and a copy goes stale the moment its
source changes. A later subagent follows a pointer and reads the few lines it needs from
the source — it is reading those docs anyway.

Give the collator the four input docs and tell it to produce a brief of references:

- **Scenario:** the stable ID and a pointer to its Gherkin —
  `→ slice-N-<short>.md › <ID>` (the authoritative Given/When/Then; do not paste it in).
- **Design decisions & constraints** that bear on this scenario, and only this scenario:
  cite them by ID — `D2, D5, §2.2, C1` — into the system-design spec.
- **Plan steps:** a pointer to this scenario's block in the plan file.
- **Research findings** this scenario touches: cite them by ID — `F4 (EXISTS), F7
  (MISSING)` — into `codebase-research.md`, where the file:symbol locations live. Pull
  only the IDs this scenario touches, not the findings text.
- **Risks, assumptions, and reuse constraints** that apply (by reference where they have one).
- A crisp statement of **what "done" looks like** for this scenario — write this one out,
  since it is the collator's own synthesis and exists nowhere else.

The collator does not write code, does not re-research the codebase, and does not
re-transcribe the docs — it decides what this scenario depends on and records the pointers.

### 2. Implement the scenario

Hand the implement subagent the path to the unified brief and tell it to build
the scenario as a **vertical slice** — end to end, through every layer it touches
(route → service → model/migration, or whatever the layers are), so the scenario
actually works for a user. Never implement a layer in isolation; a half-built
scenario cannot be verified and defers all the integration risk.

Instruct it to:

- **Reuse what research marked EXISTS** at the stated locations; add new code only
  at the MISSING extension points. Do not re-discover what is already settled.
- **Never build a stand-in for a missing EXISTS dependency.** If an `EXISTS`
  file/symbol the brief relies on is actually absent in the live repo, that is
  stale research — stop, do not invent a "minimal" equivalent to keep the slice
  working, and report the exact missing path/symbol back to you. Fabricating a
  stand-in silently invalidates every reuse the rest of the feature depends on.
- **Test selectively.** Cover only what genuinely matters: the behavior the
  scenario depends on, security/authorization boundaries, data-integrity
  boundaries, and regressions around reused code. Do not generate exhaustive,
  mechanical tests — they couple tests to implementation detail, break on every
  refactor, and bury the few tests that matter. A handful of sharp tests beats a
  hundred shallow ones.

### 3. Review the scenario independently

Spawn a review subagent that loads the **`kite-scenario-check`** skill. Give it
the scenario's code changes, the scenario's Gherkin (from the behavior
blueprint), and the unified brief, and have it judge whether the implementation
**fully and completely** satisfies the scenario — every given/when/then — and
whether it drifted outside the scenario's scope. It reports its findings back to
you.

### 4. Triage — you decide what matters

This is your judgment call, not the reviewer's. Read the findings and decide
which are **real and meaningful** versus which are nits that will not matter in
6–12 months. A finding is worth fixing if it means the scenario does not actually
satisfy its Gherkin, weakens a security/data-integrity guarantee, drifts outside
scope, or violates a design decision the slice committed to. Cosmetic preferences
and speculative "could be nicer" notes are not.

- If there are no meaningful findings, go to the final gate (stage 6).
- If there are, continue to stage 5.

### 5. Fix → qualify

- Spawn a **fix subagent** with the specific, meaningful findings you triaged in
  (not the raw list — your filtered set) and have it address exactly those.
- Then spawn a **qualify subagent** whose only job is to confirm each concern was
  *actually* addressed — not merely that code changed near it. It reports whether
  every triaged concern is resolved.

You decide whether to loop. If qualify says concerns remain and they still
matter, run another fix→qualify pass. If a concern proves intractable or reveals
a planning/research gap, stop and surface it rather than forcing a fix. Do not
let the loop spin on nits.

### 6. Final adversarial gate — required before every commit

Even when qualify reports everything is clean, do not commit on that word alone.
A qualifier confirming its sibling's fixes is still inside the same loop. Spawn
two independent checks:

- A **general-purpose adversarial subagent anchored on KISS** (keep it simple):
  tell it to assume the slice is over-built or subtly wrong and to find where —
  needless complexity, abstraction the scenario never needed, hidden side
  effects, or behavior that will be a maintenance trap in 6–12 months.
- A **`kite-design-system-standards` check**: verify the slice honors Kite's
  architecture, patterns, and principles.

Apply the same triage judgment to what they return. Only when both come back
clean (or with nothing meaningful) is the scenario safe to commit. If either
surfaces something real, route it back through fix→qualify (stage 5) and gate
again.

### 7. Commit and record

Commit the scenario as a **single commit**, with the message **prefixed by the
slice** so the bifurcation is obvious — e.g. `slice-3 (S2): accept-invite creates
a single membership`. Use the normal worktree Git metadata. If Git cannot write
the worktree index, report that as an environment blocker rather than creating an
alternate repository.

Then update the plan file: fill in this scenario's **Implementation record**
(changed files, tests added/blocked, review verdict, final-gate result, commit
hash) and set its status to `committed`. The next agent should be able to resume
from the plan file alone, without reading your transcript.

Move to the next scenario. When the slice is done, advance to the next slice.

## Blocked scenarios

If `kite-research` marked a scenario `blocked`, do not implement it. Skip it and
surface it clearly — it needs `kite-planner` to re-plan before it can be built.
Do not quietly implement policy, timing, retention, cleanup, expiry, billing, or
authorization behavior that a blocked scenario says is undefined. If an earlier
scenario appears to require that missing policy, stop and surface the dependency
conflict rather than inventing a value.

## Staying in your lane (orchestrator discipline)

- **Do not write feature code yourself.** If you catch yourself editing a route
  or a model, stop and delegate. Your leverage is judgment and sequencing.
- **Do not skip the review or the final adversarial gate.** Do not commit on a
  scenario the review found meaningful problems in or that failed the final gate.
- **Do not implement horizontally** (one layer across all scenarios). Each
  scenario is a vertical slice.
- **Do not over-test**, and do not let a fix→qualify loop spin on nits.

## Hand-off

Once every scenario in every planned slice is committed, the feature is ready for
`kite-feature-review`.
