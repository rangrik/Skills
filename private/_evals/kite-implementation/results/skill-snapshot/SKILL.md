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
