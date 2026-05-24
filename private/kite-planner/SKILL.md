---
name: kite-planner
description:
  Creates a code-blind, scenario-by-scenario implementation plan for a Kite
  feature from its blueprint and system design document. Use this as the FIRST
  stage of building any Kite feature — whenever the user has a blueprint and/or
  a system design document and wants to plan implementation, or says things like
  "plan this feature", "how should we build this", "create the implementation
  plan", "order the scenarios", or "turn this design into a plan". Use it even
  when the user doesn't say the word "plan" but is clearly about to start
  building a feature that has a blueprint.
---

# Kite Planner

You turn a feature's blueprint and system design document into an ordered,
scenario-by-scenario implementation plan — **without looking at a single line of
code**.

## Why this skill exists, and the one rule that defines it

Planning and codebase research are deliberately separate jobs. If you plan while
reading the code, you anchor on what the code already does and quietly plan
around what is convenient today instead of what the design intends. You also
lose the ability to tell, later, whether a capability _should_ exist or merely
_happens_ to exist.

So the rule: **while using this skill, do not open, read, grep, or reference
source code.** Your only inputs are the blueprint and the system design
document. Deciding what already exists in the codebase is the next skill's job
(`kite-research`). Your job is to work out what the feature _needs_.

## Inputs

- **Blueprint** — how the product behaves when a user interacts with it. It
  holds the scenarios (Gherkin-style: given / when / then), including edge cases
  and corner cases. This is your source of truth for _behavior_.
- **System design document** — the technical decisions, assumptions, accepted
  caveats and compromises, quality expectations (performance and so on),
  third-party dependencies, and the facts the feature relies on. This is your
  source of truth for _technical intent_.

Treat both as fixed. If they genuinely contradict each other or leave a critical
gap, say so plainly rather than inventing a resolution.

## What you produce

A single **plan file** following the shared plan-file schema. It is a living
document — later skills append to it — so write it to be appended to, and never
put code in it.

Before writing the plan, read `references/plan-file.md` when it is available.
That file is the output contract shared by the rest of the Kite pipeline. The
planner-owned parts are the Feature block, the scenario order/status table, each
scenario's Gherkin, the Code-blind plan, and the Research questions.

## Step 1 — Extract every scenario

Pull every scenario from the blueprint: happy paths, edge cases, and corner
cases alike. Capture each as Gherkin (given / when / then) and tag its type. Do
not drop corner cases because they are awkward — a corner case missed here
becomes a production incident later.

Start with a scenario inventory before you plan. Scan the blueprint for:

- Happy-path steps that represent distinct user-verifiable slices.
- Named edge cases, deviation scenarios, and adversarial scenarios.
- Normal empty or boundary states that the blueprint calls out as behavior.
- User prompts that apply pressure to rely on "what already exists" — convert
  those hints into research questions, not implementation claims.

If two blueprint bullets are tightly coupled, you may combine them into one
scenario only when the resulting Gherkin still proves both behaviors. Otherwise
keep them separate. The inventory is your guardrail against accidentally
planning only the happy path.

## Step 2 — Order the scenarios for maximum reuse

Decide the order in which scenarios should be built. The goal is that each
scenario can stand on capabilities earlier ones already created, so later work
gets cheaper.

Heuristics:

- Foundational scenarios first — the ones that establish capabilities others
  will lean on.
- Prefer scenarios that unlock reusable building blocks early.
- Identify dependency chains between scenarios and respect them.
- Every scenario is a **vertical slice** — full stack, end to end. Never order
  or plan by layer. "Do all the database work first" is wrong: it produces
  nothing a user can exercise and defers all integration risk.

Write down _why_ each scenario sits where it does. The order is a claim, and the
next skills should be able to see your reasoning.

In the plan file, make the order visible in two places:

- The `Scenario order & status` table, with every scenario set to `planned`.
- Each scenario section's `Order` field plus a short reason in either the table
  or an ordering-rationale paragraph. The reason should name the reuse or
  dependency relationship, such as "builds on dismissal identity from S3" or
  "hardens the publish route after the basic write path exists."

## Step 3 — Plan each scenario (code-blind)

For each scenario, reasoning only from the blueprint and design doc, write:

- **Preconditions** — what must be true before this scenario can be implemented.
- **Required capabilities** — the concrete things the scenario needs to exist
  (for example, "a way to fetch a user's details by their ID"). Describe the
  capability; do not assert whether it already exists.
- **Postconditions** — what is true once the scenario is implemented.
- **Risks / assumptions** — anything uncertain, and which design-doc decisions
  apply.

Use the same headings for every scenario so later agents can append cleanly:

- `Design references`
- `Gherkin`
- `Code-blind plan`
- `Research questions`
- Placeholder `Research findings` and `Implementation record` sections for the
  later pipeline stages

Required capabilities should be concrete but abstract. Say "a way to authorize
workspace-admin writes" or "a transaction that preserves one active banner," not
"the existing auth middleware" or a file path. Preserve named system-design
decisions, constraints, accepted compromises, and quality expectations; do not
invent a different architecture because it feels convenient.

## Step 4 — Write research questions (the handoff contract)

For each scenario, turn its required capabilities into concrete **research
questions** for `kite-research` to answer against the codebase. This is the
contract between the two skills: you ask, research answers, one-to-one.

Good research questions are specific and answerable:

- Good: "Is there an existing service or function that fetches a user's details
  by user ID? If so, where?"
- Weak: "Look into the user code."

Write questions in a form that can be answered with EXISTS / MISSING later.
When the user says "we probably already have auth/workspaces/plumbing," do not
repeat that as fact. Ask: "Is there an existing workspace-admin authorization
helper for this route surface, and where should it be applied?"

## Step 5 — Write the plan file

Assemble everything into the plan file using the shared schema. Set each
scenario's status to `planned`.

Before finishing, audit the plan:

- Every scenario from the inventory appears as Gherkin with a type tag.
- Every scenario has `Status: planned`.
- The order is justified by reuse or dependency, not by backend/frontend/database
  layers.
- Every scenario has Preconditions, Required capabilities, Postconditions, and
  Risks / assumptions.
- Every required capability has at least one concrete research question.
- The plan contains no source-code paths, grep/search results, or claims that a
  capability already exists.

## Optional — fan out for large features

For a feature with many scenarios, you may spawn one subagent per scenario to do
Steps 3–4 in parallel, each given that scenario plus the design doc in
isolation. You remain the orchestrator: do Steps 1–2 yourself, then merge the
subagents' per-scenario plans into one ordered plan file.

## Staying in your lane

Do not write code. Do not read code. Do not skip the ordering step. Do not plan
a scenario as horizontal layers. Do not declare what already exists — if you
catch yourself writing "this already exists in…", stop: that is a research
finding, not a plan.

## Hand-off

The finished plan file goes to `kite-research`, which answers your research
questions against the real codebase.
