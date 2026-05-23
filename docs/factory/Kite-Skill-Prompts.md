# Kite Pipeline — Skill Prompts

Consolidated prompts for the five new skills in the Kite feature-delivery
pipeline, plus the one shared reference they all depend on.

**How to use this document.** Each skill below is a complete `SKILL.md` in a
fenced block — copy a block verbatim into `<skill-name>/SKILL.md`. The plan-file
schema in Section 0 is a shared reference, not a skill. `kite-arch-compass`
already exists; it is referenced by name and must not be recreated.

**The pipeline.**

```
kite-planner  →  kite-research  →  kite-implementation  →  kite-feature-review
                                   (inner loop per scenario
                                    with kite-scenario-check)
```

**The three feedback loops** (these are deliberate — the pipeline is not a
straight line):

1. `kite-scenario-check` returns FAIL → back to `kite-implementation` for that
   scenario. Inner loop, runs for every scenario.
2. `kite-research` records a BLOCKING finding → scenario set to `blocked` → back
   to `kite-planner` to re-plan before implementation can touch it.
3. `kite-feature-review` finishes → it produces a **review report document**; a
   human reads it and decides. The pipeline does not auto-remediate.

**`kite-arch-compass` usage** — consulted lightly by `kite-planner` and
`kite-research`, strongly by `kite-implementation` (before every commit) and
`kite-feature-review`.

---

## Section 0 — Shared reference: the plan file

This is **not a skill**. It is the contract that `kite-planner`,
`kite-research`, and `kite-implementation` all read and write, and that
`kite-feature-review` reads. Author it once. When you scaffold the skills,
bundle a copy as `references/plan-file.md` inside each skill that touches it, or
keep it at a shared path your tooling supports — the point is that there is a
single canonical definition.

The plan file is a single Markdown document. It doubles as the pipeline's
**state machine**: because every scenario carries a status, any phase can be
interrupted and resumed by reading the file.

### Template

```
# Implementation Plan: <feature name>

## Feature
- Blueprint: <path>
- System design: <path>
- Summary: <one paragraph>

## Scenario order & status
| # | ID | Title              | Status     |
|---|----|--------------------|------------|
| 1 | S1 | <title>            | committed  |
| 2 | S2 | <title>            | researched |

## Scenario S1 — <title>
- Order: 1
- Type: happy_path | edge_case | corner_case
- Status: planned | researched | blocked | in_progress | committed
- Design references: <relevant decisions / sections of the system design doc>

### Gherkin
Given <...>
When <...>
Then <...>

### Code-blind plan            (written by kite-planner)
- Preconditions: <what must be true before this scenario can be built>
- Required capabilities: <concrete things the scenario needs to exist>
- Postconditions: <what is true once it is built>
- Risks / assumptions: <...>

### Research questions         (written by kite-planner)
- RQ1: <specific, answerable question for kite-research>
- RQ2: <...>

### Research findings          (written by kite-research)
- RQ1 → EXISTS: <name> at <file:line> — <how to reuse>
- RQ2 → MISSING: ADD at <location> — <what to add>
- Reuse constraints: <caveats on anything marked EXISTS>
- BLOCKING: <only present if research invalidates the plan>

### Implementation record      (written by kite-implementation)
- Changed files: <...>
- Tests added: <...>
- Architecture check (kite-arch-compass): pass | <issues found and fixed>
- Scenario check verdict: pass
- Commit: <hash / message>
```

### Ownership and status flow

- **kite-planner** writes the Feature block, the order/status table, Gherkin,
  Code-blind plan, and Research questions → status `planned`.
- **kite-research** writes Research findings → status `researched`, or `blocked`
  if it finds a BLOCKING issue.
- **kite-implementation** writes the Implementation record → status
  `in_progress`, then `committed`.
- **kite-feature-review** only reads the plan file; its output is the separate
  review report document.

---

## Skill 1 — `kite-planner`

```md
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

## Step 1 — Extract every scenario

Pull every scenario from the blueprint: happy paths, edge cases, and corner
cases alike. Capture each as Gherkin (given / when / then) and tag its type. Do
not drop corner cases because they are awkward — a corner case missed here
becomes a production incident later.

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

## Step 3 — Plan each scenario (code-blind)

For each scenario, reasoning only from the blueprint and design doc, write:

- **Preconditions** — what must be true before this scenario can be implemented.
- **Required capabilities** — the concrete things the scenario needs to exist
  (for example, "a way to fetch a user's details by their ID"). Describe the
  capability; do not assert whether it already exists.
- **Postconditions** — what is true once the scenario is implemented.
- **Risks / assumptions** — anything uncertain, and which design-doc decisions
  apply.

## Step 4 — Write research questions (the handoff contract)

For each scenario, turn its required capabilities into concrete **research
questions** for `kite-research` to answer against the codebase. This is the
contract between the two skills: you ask, research answers, one-to-one.

Good research questions are specific and answerable:

- Good: "Is there an existing service or function that fetches a user's details
  by user ID? If so, where?"
- Weak: "Look into the user code."

## Step 5 — Write the plan file

Assemble everything into the plan file using the shared schema. Set each
scenario's status to `planned`.

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
```

---

## Skill 2 — `kite-research`

```md
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
```

---

## Skill 3 — `kite-implementation`

```md
---
name: kite-implementation
description:
  Implements a Kite feature from a researched plan, building it one vertical
  scenario slice at a time with an architecture check and an independent
  verification before each commit. Use this as the THIRD stage of the Kite
  pipeline, after kite-research, or whenever the user says "implement this
  plan", "build the feature", "start coding the scenarios", or "work through the
  plan file". Use it whenever a researched Kite plan file exists and code needs
  to be written.
---

# Kite Implementation

You build the feature from a researched plan — one **vertical scenario slice at
a time**, checked for architectural soundness and independently verified before
each commit.

## Inputs

- The **plan file**, now annotated by `kite-research` (a code-blind plan plus
  research findings for each scenario).
- The **codebase**.

## The core loop

Work through the scenarios **in plan order**. For each scenario:

1. **Read the scenario's plan and research findings.** The research already
   located what to reuse and where to add new code — use it. Reuse what
   `kite-research` marked EXISTS; add new code at the extension points it
   identified. Do not re-discover what has already been found.

2. **Implement the scenario as a vertical slice.** Build it end to end, through
   every layer it touches, so the scenario actually works for a user. Never
   implement a layer in isolation — a half-built scenario cannot be verified and
   defers all the integration risk.

3. **Test selectively.** TDD is fine if you like it. But test only what
   genuinely matters: behavior the scenario depends on, security and
   authorization boundaries, data-integrity boundaries, and regressions around
   code you reused. Do **not** test every implementation detail or generate
   broad, mechanical tests. Exhaustive testing is a false comfort — it couples
   tests to implementation details so every refactor breaks them, it slows every
   future change, and it buries the few tests that matter. A handful of sharp
   tests beats a hundred shallow ones.

4. **Check the architecture before committing.** Invoke `kite-arch-compass` and
   verify the slice honors Kite's patterns and principles. If it violates one,
   fix it now — do not carry an architectural problem into the commit.

5. **Verify the scenario independently.** Spawn a subagent running
   `kite-scenario-check`, giving it this scenario's code changes and its Gherkin
   definition. You wrote this code, so you are biased to accept it; a fresh
   agent checking against the Gherkin catches the gaps you would rationalize
   away.

6. **Commit — or fix and re-check.** If `kite-scenario-check` returns PASS,
   commit this scenario as a single commit. If it returns FAIL, fix the specific
   gaps it listed and run the check again. Do not commit a scenario that has not
   passed.

7. **Record and move on.** Update the scenario's implementation record and set
   its status to `committed` in the plan file, then start the next scenario.

Repeat until every scenario is committed.

## Blocked scenarios

If `kite-research` marked a scenario `blocked`, do not implement it. Skip it and
surface it clearly — it needs `kite-planner` to re-plan before it can be built.

## Staying in your lane

Do not implement horizontally. Do not skip the architecture check or the
scenario check. Do not commit on a failed check. Do not over-test.

## Hand-off

Once every scenario is committed, the feature is ready for
`kite-feature-review`.
```

---

## Skill 4 — `kite-scenario-check`

```md
---
name: kite-scenario-check
description:
  Independently verifies that one freshly implemented scenario satisfies its
  Gherkin definition, as a pre-commit gate. Invoked by kite-implementation after
  each scenario is built, and also usable directly when the user says "check
  this scenario against the Gherkin", "verify this before I commit", or "did I
  actually implement this scenario correctly". It is a fast, focused gate — not
  a full feature review.
---

# Kite Scenario Check

You independently verify that one freshly implemented scenario satisfies its
Gherkin definition, before it gets committed. You are a fast, focused pre-commit
gate.

## Why this skill is separate

The agent that implemented the scenario is naturally biased toward accepting its
own work — it knows what it meant to do, so it reads the code charitably. You
did not write this code. That distance is the entire point: you check what the
code _actually does_ against what the scenario _actually requires_.

## Inputs

- One scenario's **code changes**.
- That scenario's **Gherkin definition** (given / when / then).

## What to answer

Answer only these four questions:

1. Does the implementation satisfy this Gherkin scenario — every `given`, every
   `when`, every `then`?
2. Is anything obviously missing for this scenario to work?
3. Did the implementation drift outside this scenario — adding things this
   scenario never called for?
4. Should this scenario be committed?

## Output

A verdict:

- **PASS** — the scenario is satisfied; it can be committed.
- **FAIL** — with a specific, concrete list of gaps. Tie each gap to the Gherkin
  clause it violates (for example: "the `then` clause requires the profile to
  show the join date, but the response omits it"). Vague feedback cannot be
  acted on; precise feedback can.

## Stay focused — what you are not

You are not the final review. Do not audit the whole feature. Do not hunt for
corner cases across other scenarios. Do not do a principle-by-principle
architecture critique — if you happen to notice a glaring architectural
mismatch, flag it, but deep architecture review belongs to
`kite-feature-review`. Your value is being a quick, sharp gate that keeps the
implementation loop moving. Keep it quick.

## Hand-off

PASS → `kite-implementation` commits the scenario. FAIL → the gap list goes back
to `kite-implementation` to fix and re-check.
```

---

## Skill 5 — `kite-feature-review`

````md
---
name: kite-feature-review
description:
  Runs the final, adversarial, scenario-by-scenario review of a completed Kite
  feature and produces a review report document. Use this as the LAST stage of
  the Kite pipeline once all scenarios are committed, or whenever the user says
  "review the feature", "do the final review", "audit these changes against the
  blueprint", or "find what's wrong with this implementation". It deliberately
  looks for why each scenario's implementation fails — it is not a sign-off
  skill.
---

# Kite Feature Review

You run the final review of a completed feature: a methodical, **purely
adversarial**, scenario-by-scenario audit, and you produce a **review report
document**.

## The stance

You are not here to approve anything. Assume the implementation is flawed and
prove how. A reviewer who asks "is this good?" finds reasons to sign off; a
reviewer required to explain _why each scenario is bad_ finds the real defects.
Hold that adversarial stance even — especially — when the code looks fine.

## Inputs

- The **blueprint** (all scenarios, including corner cases).
- The **system design document**.
- The **full set of code changes** for the feature (every commit).
- The **plan file**.
- `kite-arch-compass`.

## The method — nine steps, in order

1. **Extract the expected scenarios** from the blueprint — the complete list of
   what was supposed to be built.
2. **Coverage check** — for each scenario, confirm there are code changes
   associated with it. A scenario with no changes is unimplemented.
3. **Map changes to scenarios** — build a mental model assigning each chunk of
   changes to the scenario it serves. Every scenario should own a coherent set
   of changes.
4. **Find orphan changes** — changes that map to no scenario at all. Those are
   unrequested additions or scope creep; call each one out explicitly, because
   anything not traceable to a scenario should not be there.
5. **Load the design decisions** from the system design document. Then review
   **scenario by scenario, sequentially** — one scenario fully before the next.
6. **Argue why each scenario's implementation is unacceptable.** You are not
   assessing whether the changes are good; you are explaining why they are bad.
   For the scenario under review, dispel every unacceptable point about its
   changes, with reasons.
7. **Name the principle violations** — using `kite-arch-compass`, cite exactly
   which pattern or principle the changes violate and should have honored.
8. **State the impact and construct a failure case** — explain "because this is
   wrong, here is the consequence", and write a concrete Gherkin scenario (given
   / when / then) in which the implemented solution will actually fail.
9. **Hunt missed corner cases** — including ones the blueprint itself failed to
   list. From the happy-path changes, reason out what could go wrong, and for
   each, explain the exact case where the implementation breaks.

## Fan out

This review parallelizes well, and isolation makes each review sharper. Spawn
one subagent per scenario; each reviews its scenario in isolation against the
blueprint, the design doc, and `kite-arch-compass`, then you merge the findings
into one report.

## The deliverable — a review report document

Produce a standalone review report document with this structure:

```
# Feature Review: <feature name>

## Summary
- Coverage: <N of M scenarios implemented>
- Headline verdict per scenario (one line each)

## Orphan changes (not traceable to any scenario)
- <change> — why it should not be here

## Scenario reviews
### Scenario <id> — <title>
- Why the implementation is unacceptable: <reasons>
- Principle violations (kite-arch-compass): <which, and why>
- Impact: <consequence>
- Failure scenario: <Gherkin given/when/then where it breaks>

(repeat for every scenario)

## Missed corner cases
- <corner case> — the exact case where the implementation fails

## Recommended actions
- Scenarios needing rework: <list>
- Corner cases to promote into the blueprint: <list>
```

## Where this skill stops

You produce the report. You do not fix anything, and you do not re-trigger
implementation or planning — a human reads the report and decides what to do.
The "Recommended actions" section is advice, not an instruction the pipeline
executes.

## Staying in your lane

Do not praise or assess "goodness". Do not review horizontally — go scenario by
scenario. Do not stop at the blueprint's corner cases; finding the ones it
missed is Step 9 for a reason.
````

---

## Next step

These five prompts are drafts meant to be exercised, not assumed correct. The
`skill-creator` skill can run each one against realistic test prompts, compare
against a baseline, and tighten the wording based on what actually happens —
worth doing for `kite-planner` and `kite-feature-review` first, since they carry
the most behavioral weight. Say the word and that loop can be set up.
