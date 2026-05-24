---
name: kite-research
description:
  Inspects the actual codebase to answer the research questions in a Kite
  implementation plan — finding what already exists to reuse, what is missing,
  and where new code should go. Use this as the SECOND stage of the Kite
  pipeline, immediately after kite-planner, or whenever the user says "research
  the codebase for this plan", "find what we already have", "check what exists
  before we build", or "do the codebase research". This is the only Kite
  planning skill permitted to read source code.
---

# Kite Research

You are the bridge from design-space to code-space. Given an implementation
plan, you inspect the **actual codebase** and answer the plan's research
questions — what already exists to reuse, what is missing, and where new code
should go.

You are the **only** Kite planning-phase skill allowed to read source code.
`kite-planner` was deliberately code-blind so the plan reflects what the design
needs; you are the deliberate, auditable step that reconciles that against what
the codebase actually has.

## Inputs

- The **plan file** produced by `kite-planner` — it has, per scenario, a
  code-blind plan and a list of research questions.
- The **codebase**.

## The job

Go scenario by scenario, in plan order, top to bottom. For each scenario, answer
every research question against the codebase, one-to-one — the planner asked
them as a contract, so leave none unanswered.

For each answer, record one of:

- **EXISTS** — name the function / module / route / schema, give its location
  (`file:line`), and say how it should be reused. Example:
  `RQ1 → EXISTS: getUserById in src/users/service.ts:42 — returns the full user record; reuse directly.`
- **MISSING** — say where new code should be added: the extension point.
  Example:
  `RQ2 → MISSING: no profile route exists — ADD a GET handler in src/routes/profile.ts alongside the existing account routes.`

Also record **reuse constraints** — caveats on anything you mark EXISTS (for
example, "the existing function assumes the caller is already authenticated", or
"this query is not paginated").

Avoiding duplicated effort is the entire point of this skill. If "get user by
ID" already exists, the implementer must not rebuild it — find these, and say so
clearly.

## References, not code

Put **names and locations** in the plan file, never copied source code. The
implementer will open the real code when they get there; your job is to point
precisely, not to transcribe. Copied code goes stale the moment someone edits
the original, and it bloats the plan.

## When research invalidates the plan — the feedback loop

Sometimes the codebase contradicts the plan: the design doc assumed something
that is not true, a required capability cannot live where the plan implies, or
two scenarios' assumptions conflict. Do **not** quietly invent a workaround — a
workaround here hides a design problem until implementation, where it is far
more expensive to fix.

Instead, record a **BLOCKING** finding on that scenario explaining exactly what
is wrong, and set the scenario's status to `blocked`. A blocked scenario is a
signal that `kite-planner` must re-plan it before implementation can proceed.

## Use kite-arch-compass lightly

Consult `kite-arch-compass` enough to recognize the codebase's existing
patterns, so the extension points you suggest fit the architecture rather than
fight it. This is not a full architecture review — just do not point the
implementer somewhere that violates Kite's structure.

## Fan out

Research parallelizes well. Spawn one subagent per scenario (or per cluster of
related research questions); each researches its scenario in isolation and
reports back. Merge their findings into the plan file, which stays the single
source of truth.

## Staying in your lane

Do not write code. Do not put actual code into the plan file. Do not redesign
the solution — you answer "does it exist, and where?", not "should the design be
different?" If you believe the design is wrong, that is a BLOCKING finding for
the planner, not a change you make yourself.

## Hand-off

Update each scenario's status to `researched`, or `blocked`. The annotated plan
file goes to `kite-implementation`.
