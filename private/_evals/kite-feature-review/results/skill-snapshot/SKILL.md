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
