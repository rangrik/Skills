# Design Principles — the reasoning lens

> **Precedence (read first).** In the **appsmith-v2 / Kite repo, `kite-design-system-standards`'s engineering principles are authoritative and supersede this file** — on any conflict, the Kite standard wins, and recommendations should cite the governing Kite principle *number*. This file is a **gap-filler** for concerns the standard doesn't cover (e.g. explicit latency targets, accessibility, least-surprise). If the standard is silent on a question, these principles apply; don't invent a Kite principle that isn't in the standard.

These are the principles of how a great technical system is designed. The skill internalizes them in **P1** and applies them throughout **P2** (tracing the data flow and classifying the decision surface) and **P3** (forming recommendations, grilling against the standards, and weighing trade-offs).

They are **heuristics, not a checklist.** Use them to *reason*: when you recommend an option, cite the principle(s) it upholds; when you accept a compromise, name the principle it bends. The taxonomy tells you *what* to decide; these tell you *how to decide well*.

When two principles pull in opposite directions (they often do — e.g. simplicity vs. scalability), make the trade-off explicit, pick one deliberately, and record it. Don't blend them silently.

---

## 1. Simplicity first / YAGNI
The best design is the fewest moving parts that satisfy *this* blueprint. Don't build for imagined futures or hypothetical scale. Complexity must be paid for by a real, present requirement. *Apply:* prefer the option that removes a component, a state, or a failure mode over the one that adds capability nobody asked for.

## 2. Match existing patterns over novelty
Fit the codebase's conventions and proven building blocks. Boring and consistent beats clever and bespoke. Novelty must earn its keep against the cost of being the only thing shaped that way. *Apply:* before inventing, check how the repo already solves the adjacent problem and follow it unless there's a concrete reason not to.

## 3. High cohesion, loose coupling
Each module owns one responsibility; dependencies cross well-defined contracts, not internals. A change in one place shouldn't ripple. *Apply:* put the decision where the responsibility already lives; define the seam (interface/schema/event) explicitly rather than reaching across boundaries.

## 4. Get the data model right
Data outlives code and is the hardest thing to change. Decide schema, ownership, and invariants deliberately, and plan for evolution (migrations, backfills, versioning) up front. *Apply:* spend disproportionate care on persistence decisions; treat "we'll reshape the table later" as a red flag.

## 5. Design for failure
Everything fails — networks, third parties, the process itself. Assume timeouts, partial failure, and downstream outages, degrade gracefully, and make the failure mode visible to the user and to operators. *Apply:* for every external call and async step, ask "what happens when this fails or hangs?" and design the answer before the happy path.

## 6. Idempotency & bounded operations
Operations should be retry-safe and bounded. Put timeouts, limits, pagination, and backpressure everywhere; never issue an unbounded query or an un-rate-limited call to a downstream you don't control. *Apply:* make writes idempotent (dedupe keys, upserts); cap every loop, fetch, and queue.

## 7. Prefer reversible (two-way-door) decisions
Defer irreversible commitments; make it cheap to change course. Identify the one-way doors (data formats, public contracts, irreversible migrations) and flag them explicitly so they get extra scrutiny. *Apply:* when unsure, choose the option that's easiest to undo, and call out which decisions are hard to reverse.

## 8. Measure, don't guess
Optimize the proven hot path, not the imagined one. Make the common case fast; don't pay complexity for performance you haven't measured a need for. *Apply:* state the expected load and latency target; if a "fast" option adds complexity without evidence it's needed, prefer the simple one and add the signal to measure it.

## 9. Make illegal states unrepresentable
Encode invariants in types, schema constraints, and enums so the system *can't* enter a bad state, instead of validating after the fact. *Apply:* prefer a constraint or a narrow type over a runtime check; if two fields can't both be set, model them so they can't be.

## 10. Observability from day one
If you can't see it, you can't operate it. Design the signals — logs, metrics, traces, and the few alerts that matter — alongside the feature, not after an incident. *Apply:* for each decision, ask "how will we know this is working / failing in production?" and capture the answer.

## 11. Security & privacy by design
Least privilege, validate at every trust boundary, treat secrets and PII as first-class constraints, and assume input is hostile. Security is part of the design, not a later pass. *Apply:* for every input and integration, ask who can reach it, what they could abuse, and what data is exposed.

## 12. Cost as a first-class constraint
Per-request cost and third-party metering shape the architecture as much as latency does. Cache, batch, and set ceilings deliberately. *Apply:* for any paid external call or expensive compute, ask "what's the cost per use, what's the ceiling, and what stops it running away?"

## 13. Cache invalidation is a design decision
Caching is rarely free correctness. Be explicit about *what* is cached, *where* it lives, its *TTL*, *how* it's invalidated, and the freshness-vs-cost trade-off you're accepting. *Apply:* never add a cache without answering all five; pair every cache with its invalidation/refresh story.

## 14. Principle of least surprise
The system should behave the way the next engineer (and the user) expects, and consistently with the rest of the codebase. Predictability beats cleverness. *Apply:* when an option is locally optimal but inconsistent with how the system works elsewhere, prefer consistency.

## 15. Design the seams for testing
A feature you can't test cheaply will rot. Build in the seams — injectable/mocked third parties, deterministic boundaries, pure cores — so it's testable by construction. *Apply:* for each external dependency, decide the mock/stub strategy as part of the design, not as a testing afterthought.
