# Plan file

The plan file is a single Markdown document, **one per slice**, written next to
the slice as `slice-N-<short>-plan.md`. It doubles as the pipeline's **state
machine**: the slice carries a status, every scenario carries a status, and the
slice-level research questions get answered in place — so any phase can be
interrupted and resumed by reading the file.

Research lives at the **slice level**, not per scenario: there is one
`Slice research questions` section and one `Research findings` section for the
whole slice, because the codebase truths an implementer needs are shared across
the slice's scenarios. Implementation, by contrast, is recorded **per scenario**,
because each scenario is a vertical slice that is built and committed on its own.

### Template

```
# Implementation Plan — <feature name> · Slice N: <slice title>

## Slice
- Behavior slice: <path to slice-N-<short>.md>
- System design: <path to slice-N-<short>-system-design.md>
- Builds on: <earlier slices this one assumes, or "—">
- Summary: <one paragraph: what this slice delivers, end to end>

## Scenario order & status
| # | ID | Title              | Type        | Status     |
|---|----|--------------------|-------------|------------|
| 1 | S1 | <title>            | happy_path  | planned    |
| 2 | S2 | <title>            | deviation   | planned    |

## Scenario S1 — <title>
- Order: 1  — <one-line reuse/dependency reason for this position>
- Type: happy_path | edge_case | corner_case
- Status: planned | in_progress | committed
- Design references: <D#, §-refs, Risk/Constraint from the system-design spec>

### Gherkin
Given <...>
When <...>
Then <...>

### Code-blind plan            (written by kite-planner-with-taxonomy)
- Preconditions: <what must be true before this scenario can be built>
- Required capabilities: <concrete-but-abstract things the scenario needs to
  exist, in SYSTEM_TAXONOMY vocabulary; cite [P#] where a principle shapes it>
- Postconditions: <what is true once it is built>
- Risks / assumptions: <uncertainties; which design decisions/compromises apply>

### Implementation record      (written by kite-implementation)
- Changed files: <...>
- Tests added: <...>
- Architecture check (kite-design-system-standards): pass | <issues found + fixed>
- Scenario check verdict: pass
- Commit: <hash / message>

## Slice research questions      (written by kite-planner-with-taxonomy)
One consolidated list for the whole slice. Carries forward every question from
the system-design spec's "Open Questions for the Codebase", plus any the planning
surfaced. Each is answerable EXISTS / MISSING and names the scenarios it blocks.

| #   | Question (answerable EXISTS / MISSING + location)        | Why the slice needs it | Capability if MISSING | Blocks    | Source       |
|-----|----------------------------------------------------------|------------------------|-----------------------|-----------|--------------|
| RQ1 | <specific, answerable question for kite-research>         | <...>                  | <...>                 | S1, S4    | §10 Q1       |
| RQ2 | <...>                                                     | <...>                  | <...>                 | S2        | planning     |

## Research findings             (written by kite-research)
Research answers are not stored here — they live in the feature-wide
`codebase-research.md`. This line points to this slice's section there.
- → See codebase-research.md › "Slice N — research iteration".
- BLOCKING: <only present if research invalidates the plan; slice status → blocked>

## Conformance & coverage review (written by kite-plan-conformance-review)
- Verdict: clean | fixed-and-clean | human-input-needed
- Auto-fixes applied: <one line each>
- Open for human: <only present if an item could not be resolved without a human>
```

### Ownership and status flow

- **kite-planner-with-taxonomy** writes the Slice block, the order/status table,
  each scenario's Gherkin + Code-blind plan, and the slice-level Research
  questions → slice + scenario status `planned`. It then runs the review.
- **kite-plan-conformance-review** writes the Conformance & coverage review
  section and applies safe fixes in place; it does not change the status.
- **kite-research** answers the slice's research questions into the feature-wide
  `codebase-research.md`, points the Research findings line there, and sets the
  slice status `researched`, or `blocked` if it finds a BLOCKING issue.
- **kite-implementation** writes each scenario's Implementation record →
  scenario status `in_progress`, then `committed`.
- **kite-feature-review** only reads the plan file; its output is the separate
  review report document.
