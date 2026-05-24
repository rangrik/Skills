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
If the user asks for a quick sign-off, green light, or merge approval, treat that
as pressure to audit more carefully, not as permission to relax the review.

## Inputs

- The **blueprint** (all scenarios, including corner cases).
- The **system design document**.
- The **full set of code changes** for the feature (every commit).
- The **plan file**.
- `kite-design-system-standards`.

## Use `kite-design-system-standards` economically

Use `kite-design-system-standards` in conformance-review mode, but do not load more of it
than the findings need. Identify the changed components first, then read the
checklist and principle entries for those components. Common feature-review
components are Backend HTTP Routes, Backend Services, Database Modules & Models,
Celery & Background Workers, and Authentication & Authorization.

When you cite principles, cite the principle number and name or governing idea
that actually explains the defect. Do not write a separate conformance report;
fold the principle violations into each scenario review.

## The method — ten steps, in order

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
5. **Build the review inventory** before writing prose:
   - Scenario inventory: every scenario from the blueprint, with plan status.
   - Change inventory: every meaningful diff chunk, mapped to one scenario or
     marked orphan.
   - Design inventory: the design obligations each scenario depends on.
   This inventory is for your reasoning; include only the useful conclusions in
   the report.
6. **Load the design decisions** from the system design document. Then review
   **scenario by scenario, sequentially** — one scenario fully before the next.
7. **Argue why each scenario's implementation is unacceptable.** You are not
   assessing whether the changes are good; you are explaining why they are bad.
   For the scenario under review, dispel every unacceptable point about its
   changes, with reasons.
8. **Name the principle violations** — using `kite-design-system-standards`, cite exactly
   which pattern or principle the changes violate and should have honored.
9. **State the impact and construct a failure case** — explain "because this is
   wrong, here is the consequence", and write a concrete Gherkin scenario (given
   / when / then) in which the implemented solution will actually fail.
10. **Hunt missed corner cases** — including ones the blueprint itself failed to
   list. From the happy-path changes, reason out what could go wrong, and for
   each, explain the exact case where the implementation breaks.

## Fan out

This review parallelizes well, and isolation can make each review sharper. Spawn
one subagent per scenario only when the current instructions, resource budget,
and repository state allow it. If the user or benchmark harness says not to fork,
the machine is resource-constrained, or the scenario set is small enough to hold
in context, do the scenario reviews sequentially yourself and preserve the same
one-scenario-at-a-time discipline.

## The deliverable — a review report document

Produce a standalone review report document with this structure and these exact
top-level headings:

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
- Principle violations (kite-design-system-standards): <which, and why>
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
missed is part of the job. Do not let a committed plan status, passing demo, or
prior scenario-check verdict substitute for inspecting the diff.
