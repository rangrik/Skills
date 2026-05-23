# Kite Skills Architecture — Feature Delivery Lifecycle

*A spec distilled from the raw brain-dump. Purpose: a blueprint precise enough to recreate the whole skill suite from scratch.*

---

## 1. What this document is

You described, in one continuous blob, an end-to-end pipeline for taking a feature from "what should it do" all the way to "reviewed, committed code." Buried inside it are several **distinct skills**, each with its own responsibility, plus a couple of shared artifacts and one reference skill that other skills lean on.

This document does three things:

1. Separates the **inputs** (documents that already exist) from the **skills** (the agents that act).
2. Identifies **6 skills**, names them, and pins down each one's responsibility, inputs, outputs, and boundaries.
3. Lays out the **lifecycle** — how artifacts flow from one skill to the next, and where subagents fan out.

Your opening question — *"how should an implementation plan be created, or is plan creation even needed?"* — is answered directly by your own blob: **yes, planning is needed**, and it is deliberately multi-fold. The reasoning is captured in the Planner and Research skills below.

---

## 2. Inputs — what already exists (NOT skills)

These two documents are **upstream prerequisites**. Nothing in this suite creates them; everything consumes them. Keeping them out of the skill count is important — they are the raw material, not the machinery.

| Artifact | What it answers | Key contents |
|---|---|---|
| **Blueprint** | *How the product behaves when a user interacts with it.* | The full set of **scenarios** (Gherkin-style), including **corner cases**. This is the source of truth for *behavior*. |
| **System / Solution Design Document** | *How that behavior is realized technically.* | Technical decisions, assumptions, accepted caveats/compromises, quality posture (performance etc.), third-party solutions, and the facts the feature depends on. The source of truth for *technical intent*. |

> **Boundary rule:** Blueprint = behavior. Design doc = technical realization of that behavior. Every downstream skill reads one or both, but treats them as fixed.

---

## 3. Cross-cutting principles (true for every skill)

These appear repeatedly across the blob. They are not skills, but every skill must honor them, so they belong up front.

- **Vertical slices, never horizontal layers.** Work is done **scenario by scenario**, full stack at a time. Never "do the whole DB layer first."
- **Order for maximum reuse.** Scenarios are sequenced so each one can build on what earlier ones already created.
- **Planning is code-blind.** During the design-level planning phase, *no code is read or touched — not a single line.* Code only enters view in the Research phase.
- **Plan files store references, not code.** Function names, file locations, "add here" pointers — never copied source.
- **Selective testing.** TDD is allowed, but only **critical** behavior gets tests. Testing everything is treated as a fallacy that creates future drag.
- **Adversarial review.** The final review does not ask "is this good?" It asks "**why is this bad?**" and tries to break it.
- **Subagent fan-out.** Planning, research, and review are all parallelizable — one subagent per scenario, each working a scenario in isolation.
- **One shared reference skill.** Architecture principles are consulted *proactively* during implementation and *adversarially* during review — same skill, two consumers.

---

## 4. The skills — summary

**Count: 6 skills.** Five are "process" skills (they do a phase of work); one is a "reference" skill (it is consulted, it does not drive a phase).

| # | Skill (proposed name) | Type | One-line responsibility |
|---|---|---|---|
| 1 | `kite-planner` | Process | Order the scenarios and produce a code-blind, design-level plan for each one. |
| 2 | `kite-research` | Process | Walk the actual codebase and annotate the plan with what already exists vs. what must be added. |
| 3 | `kite-implementation` | Process | Implement the plan scenario by scenario, gated by architecture checks and per-scenario verification. |
| 4 | `kite-architecture-principles` | Reference | Hold Kite's ideal patterns/principles; consulted by skills 3 and 6. |
| 5 | `kite-scenario-check` | Process (micro) | Verify a freshly-implemented scenario against its Gherkin definition before commit. |
| 6 | `kite-feature-review` | Process | Final, methodical, adversarial review of the whole feature, scenario by scenario. |

> **On skill #5:** This is the one genuine judgment call in the chunking. It can stand alone (clean, reusable) or be folded into `kite-implementation` as an internal step. See §7 for the recommendation. Everything else maps 1:1 to a clearly distinct responsibility in your blob.

---

## 5. The skills — in detail

### Skill 1 — `kite-planner`

**Purpose.** Turn the blueprint + design doc into an ordered, design-level plan — *without ever looking at code.*

**Responsibilities.**

1. **Order the scenarios.** Read every scenario in the blueprint and arrange them in an implementation order that maximizes reuse downstream (earlier scenarios lay groundwork later ones can stand on).
2. **Plan each scenario.** Going scenario by scenario, work out *how* it would be implemented, reasoning only from the blueprint and the design doc.
3. **For each scenario, capture three things:**
   - **Preconditions** — what must already be true *before* this scenario can be implemented.
   - **Postconditions** — what is true *after* it is implemented.
   - **Requirements** — the concrete things the scenario needs to exist (e.g. "a way to fetch user details by ID").
4. **Write progress to the plan file** as it goes, so the next phase has something to act on.
5. **Fan out (optional).** It may spawn one subagent per scenario, each pairing that scenario with the design doc independently, then merge their output back. The planner is the **top-level orchestrator**.

**Inputs:** Blueprint, System Design Document.

**Output:** **Plan file** — ordered scenario list; per scenario a preconditions / postconditions / requirements block.

**Must NOT:** Read, open, or reference any source code. Write any code. Skip the ordering step. Plan a scenario horizontally (layer-by-layer).

**Worked example (from your blob):** Scenario *"user can visit their profile and see their own details"* → requirement: *"fetch user details by ID"* → "user details" becomes a precondition for that phase. The planner records this **as a requirement**, not as a verdict on whether it already exists — that check belongs to Research.

---

### Skill 2 — `kite-research`

**Purpose.** Bridge from design-space into code-space. It is the **only planning-time skill that reads the codebase.**

**Responsibilities.**

1. Take the plan file and go **top to bottom, scenario by scenario.**
2. For each scenario's requirements, search the codebase: **does this already exist?**
3. When something exists, record the **reference** — the function name / file / location to reuse (e.g. "`getUserById` already exists in `users/service`"), so effort is not duplicated.
4. When something is missing, record **where new code should be added.**
5. Update the plan file in place with these references.

**Invocation model.** The planner writes what it has done so far to the plan file, then **kicks off research subagent(s)** — possibly several, depending on how many scenarios/requirements the plan produced. Each subagent researches and reports back, and the plan file is updated with their findings.

**Inputs:** Plan file (with requirements), the **codebase**.

**Output:** **Plan file, augmented** — same file, now annotated with codebase references (reuse points + insertion points). The "research file" and "plan file" may be one and the same file.

**Must NOT:** Write code. Put *actual code* into the plan file — only names, references, and locations. Re-decide the design (it answers "does it exist?", not "should it be designed differently?").

> **Why this is its own skill, not part of the Planner:** the boundary is sharp and load-bearing — the Planner is code-blind by rule; Research is defined by reading code. Different mode of work, different failure modes. Keep them separate. (If you ever want fewer skills, this is the *only* merge that is even arguable — see §7.)

---

### Skill 3 — `kite-implementation`

**Purpose.** Build the feature from the annotated plan, one vertical scenario slice at a time.

**Responsibilities.** For each scenario, in plan order:

1. Read the plan/research file and implement that scenario across the full stack.
2. **Before committing**, check the implementation is **architecturally sound** by consulting `kite-architecture-principles`.
3. **Test selectively.** TDD is permitted, but only **critical** behavior is tested — not everything. Over-testing is explicitly to be avoided.
4. **Verify** the scenario by handing it to `kite-scenario-check` (a review subagent) — does the implemented code satisfy the Gherkin scenario it was meant to satisfy?
5. If verification passes ("this might just work"), **commit that scenario.**
6. Move to the next scenario. Repeat until **every scenario is implemented and committed.**

**Inputs:** Plan/research file, the codebase, `kite-architecture-principles`, Gherkin scenarios from the blueprint.

**Output:** Working code, **committed per scenario** (one commit per scenario slice).

**Must NOT:** Implement horizontally. Skip the architecture check. Skip the per-scenario verification before commit. Generate exhaustive test suites.

---

### Skill 4 — `kite-architecture-principles`

**Purpose.** A **reference skill** — the single source of truth for Kite's ideal patterns and architectural principles. It does not drive a phase; it is *consulted.*

**Responsibilities.**

- State which patterns are ideal for implementing which kinds of functionality.
- Serve two consumers with the same body of knowledge:
  - `kite-implementation` consults it **proactively** — "is what I'm about to commit sound?"
  - `kite-feature-review` consults it **adversarially** — "which principle/pattern does this change violate?"

**Inputs:** None at runtime — it *is* the knowledge.

**Output:** Pattern guidance / principle rulings on demand.

**Must NOT:** Do implementation or review work itself. It is purely the rulebook.

> In your blob this is referred to twice — once as the "Kite architecture skill" and once as the "architecture principles skill for just Kite." These are **the same skill**; this spec treats them as one.

---

### Skill 5 — `kite-scenario-check`

**Purpose.** A lightweight, per-scenario verification gate used *inside* implementation. It is the "send a subagent to review what it just did against the Gherkin scenario" step.

**Responsibilities.**

- Take one freshly-implemented scenario and its Gherkin definition.
- Judge whether the implementation actually satisfies that scenario.
- Return a pass/fail signal so `kite-implementation` can decide whether to commit.

**Inputs:** One scenario's code changes, that scenario's Gherkin definition.

**Output:** A verdict ("this might just work" → commit, or "not yet" → fix).

**Must NOT:** Do a whole-feature review (that is skill 6). Be exhaustive or adversarial — it is a fast confidence gate, not the final tribunal.

**Standalone vs. folded-in:** This is the one optional skill. It is a *distinct responsibility* (verification ≠ implementation), so it earns its own entry — but it is small and only ever called by `kite-implementation`. You may keep it standalone (cleaner, reusable, and it shares DNA with skill 6) or fold it into `kite-implementation` as an internal step. **Recommendation in §7.**

---

### Skill 6 — `kite-feature-review`

**Purpose.** The **final, separate, methodical, purely adversarial** review of the *entire* feature. Distinct from skill 5: skill 5 is a fast per-scenario gate during build; skill 6 is the heavyweight whole-feature tribunal after build.

**Responsibilities — the 9-step method, in order.**

1. **Identify** the scenarios that were supposed to be implemented, from the blueprint.
2. **Check coverage** — does every scenario have code changes associated with it?
3. **Build the mental model** — map each chunk of changes to the scenario it belongs to. Every scenario should own a set of changes.
4. **Detect orphan changes** — find changes associated with *no* scenario. Those are things that should not be there (scope creep / unintended additions).
5. **Load the design decisions** from the system design document, then review **scenario by scenario, sequentially.**
6. **Argue why each change is unacceptable.** The review does *not* assess whether changes are good — it exists to explain **why the implementation of the scenario under review is bad.** It must dispel every unacceptable point about that one scenario's changes, with reasons.
7. **Cite principle violations** — using `kite-architecture-principles` as reference, name exactly which principle or pattern is being violated and should have been honored.
8. **State the impact, and construct a failure scenario** — "because this is wrong, here is the impact," and produce a concrete Gherkin scenario in which the implemented solution will fail.
9. **Hunt missed corner cases** — even corner cases the blueprint itself missed. From the happy-path changes, work out exactly what could go wrong and why it would not work in that case.

**Invocation model.** Purely adversarial, and **parallelizable** — multiple subagents, each reviewing exactly one scenario in isolation, then merged into one report.

**Inputs:** Blueprint (scenarios + corner cases), System Design Document, the full set of code changes, `kite-architecture-principles`.

**Output:** **Review report** — per scenario: why it fails, which principles it violates, the impact, a failure-mode Gherkin scenario; plus the list of orphan (un-scoped) changes; plus newly-discovered corner-case failures.

**Must NOT:** Praise or assess "goodness." Review horizontally instead of scenario by scenario. Stop at the blueprint's corner cases — it must find new ones.

---

## 6. The lifecycle

### Phase walk-through

```
   ┌─────────────┐     ┌──────────────────────┐
   │  Blueprint  │     │ System Design Doc    │   ← inputs (already exist)
   │  (behavior) │     │ (technical intent)   │
   └──────┬──────┘     └──────────┬───────────┘
          │                       │
          └───────────┬───────────┘
                      ▼
        ╔═══════════════════════════════╗
        ║  PHASE 1 — PLANNING           ║   kite-planner
        ║  (code-blind)                 ║   • order scenarios for reuse
        ║                               ║   • per scenario: pre/post/requirements
        ║   ↳ optional: 1 subagent      ║
        ║     per scenario, merged back ║
        ╚═══════════════╤═══════════════╝
                        ▼
                 ┌──────────────┐
                 │  PLAN FILE   │  ordered scenarios + requirements
                 └──────┬───────┘
                        ▼
        ╔═══════════════════════════════╗
        ║  PHASE 2 — RESEARCH           ║   kite-research
        ║  (reads the codebase)         ║   • planner writes progress, then
        ║                               ║     kicks off research subagent(s)
        ║   ↳ N subagents, scenario     ║   • "does it exist? where to add?"
        ║     by scenario, merged back  ║
        ╚═══════════════╤═══════════════╝
                        ▼
                 ┌──────────────┐
                 │  PLAN FILE   │  + codebase references
                 │  (augmented) │    (reuse points, insertion points)
                 └──────┬───────┘
                        ▼
        ╔═══════════════════════════════╗
        ║  PHASE 3 — IMPLEMENTATION     ║   kite-implementation
        ║  loop, scenario by scenario:  ║
        ║   1. implement the slice      ║
        ║   2. arch check ──────────────╫──▶ kite-architecture-principles
        ║   3. selective critical tests ║
        ║   4. verify ──────────────────╫──▶ kite-scenario-check (vs Gherkin)
        ║   5. commit the scenario      ║
        ║   6. next scenario            ║
        ╚═══════════════╤═══════════════╝
                        ▼
                 ┌──────────────┐
                 │ COMMITTED    │  one commit per scenario
                 │ CODE         │
                 └──────┬───────┘
                        ▼
        ╔═══════════════════════════════╗
        ║  PHASE 4 — FINAL REVIEW       ║   kite-feature-review
        ║  adversarial, 9-step method   ║   • map changes → scenarios
        ║                               ║   • find orphan changes
        ║   ↳ N subagents, one per      ║   • why each scenario is bad
        ║     scenario, in isolation    ║──▶ kite-architecture-principles
        ╚═══════════════╤═══════════════╝
                        ▼
                 ┌──────────────┐
                 │ REVIEW       │  per-scenario failures, principle
                 │ REPORT       │  violations, impact, failure Gherkins,
                 └──────────────┘  orphan changes, missed corner cases
```

A renderable version of this flow is in the companion file `Kite-Skills-Lifecycle.mermaid`.

### Artifacts that flow through the lifecycle

| Artifact | Created by | Consumed by | Notes |
|---|---|---|---|
| Blueprint | *(upstream)* | Planner, Implementation, Feature Review | Behavior + Gherkin scenarios + corner cases. |
| System Design Doc | *(upstream)* | Planner, Feature Review | Technical decisions, assumptions, caveats. |
| Plan file | Planner | Research, Implementation | Ordered scenarios + per-scenario pre/post/requirements. |
| Plan file (augmented) | Research | Implementation | Same file + codebase references. Plan file and research file may be one file. |
| Committed code | Implementation | Feature Review | One commit per scenario. |
| Review report | Feature Review | *(you)* | Adversarial findings, per scenario. |

---

## 7. Open decisions & recommendations

**1. Keep Research separate from Planner — recommended.** The code-blind / code-reading boundary is the single most important rule in your blob. Two skills make that boundary impossible to accidentally cross. Merging them invites the planner to "peek" at code and corrupt the design-level reasoning.

**2. Keep `kite-scenario-check` as a standalone skill — mild recommendation.** It is a distinct responsibility (verification ≠ implementation) and it shares logic with `kite-feature-review` (both judge code against Gherkin). A standalone skill lets you build the Gherkin-verification logic once and call it in two intensities — light (per-scenario gate) and heavy (final tribunal). If you would rather minimize file count, folding it into `kite-implementation` as an internal step is acceptable and changes nothing about behavior. Lean layout = 5 skills; recommended layout = 6.

**3. Blueprint and design-doc authoring are out of scope here.** Your blob treats both as already existing. If you later want skills that *produce* them, those would be two additional skills — but nothing in this blob specifies them, so they are deliberately excluded from the count.

**4. Per-scenario plan-entry template.** To make the Planner's output machine-consumable by Research and Implementation, every scenario entry in the plan file should follow a fixed shape:

```
## Scenario <order#>: <Gherkin title>
Preconditions (what must be true before):
  - ...
Requirements (what this scenario needs to exist):
  - <requirement>  →  [research fills: EXISTS at <ref>  |  ADD at <location>]
Postconditions (what is true after):
  - ...
Implementation notes (design-level, no code):
  - ...
```

The Planner fills everything except the bracketed part of each requirement line; Research fills the bracketed part. This is what makes the same file serve as both plan file and research file.

---

## 8. One-paragraph recap

Your blob describes a four-phase pipeline over two pre-existing inputs. The Blueprint and the System Design Document are the raw material. **`kite-planner`** orders the scenarios for reuse and writes a code-blind, design-level plan with preconditions, postconditions, and requirements for each. **`kite-research`**, run as subagents the planner spawns, is the only planning-time skill that reads code — it annotates each requirement with "already exists here" or "add it here." **`kite-implementation`** then builds the feature one vertical scenario slice at a time, checking soundness against **`kite-architecture-principles`**, testing only critical behavior, verifying each slice with **`kite-scenario-check`** against its Gherkin scenario, and committing per scenario. Finally **`kite-feature-review`** runs an adversarial, nine-step, scenario-by-scenario tribunal — mapping changes to scenarios, flagging orphan changes, naming violated principles, predicting failure modes, and hunting corner cases the blueprint itself missed. Six skills: five process, one reference.
