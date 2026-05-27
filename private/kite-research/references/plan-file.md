# Plan file

The plan file is a single Markdown document, **one per slice**, written next to
the slice as `slice-N-<short>-plan.md` by `kite-planner-with-taxonomy`. It
doubles as the pipeline's **state machine**: the slice carries a status, every
scenario carries a status.

Research questions live at the **slice level** (one consolidated list), not per
scenario. Research **findings** are not stored here — they live in the
feature-wide `codebase-research.md` (see `references/codebase-research.md`); the
plan's `Research findings` line is a pointer to this slice's section there.

### Template (the parts research reads / touches)

```
# Implementation Plan — <feature name> · Slice N: <slice title>

## Slice
- Behavior slice: <path to slice-N-<short>.md>
- System design: <path to slice-N-<short>-system-design.md>
- Builds on: <earlier slices this one assumes, or "—">
- Summary: <one paragraph>

## Scenario order & status
| # | ID | Title | Type | Status |

## Scenario S1 — <title>
- Order / Type / Status / Gherkin (→ slice-N-<short>.md › <ID>) / Design references
### Code-blind plan            (written by kite-planner-with-taxonomy)
### Implementation record      (written by kite-implementation)

## Slice research questions      (written by kite-planner-with-taxonomy)
| #   | Question (EXISTS / MISSING + location) | Why | Capability if MISSING | Blocks | Source |
| RQ1 | ...                                    | ... | ...                   | S1, S4 | §10 Q1 |

## Research findings             (written by kite-research)
→ See codebase-research.md › "Slice N — research iteration".
- Status set to `researched`, or `blocked` (with the BLOCKING reason) if research
  contradicts the slice's plan/design.

## Conformance & coverage review (written by kite-plan-conformance-review)
```

### Ownership and status flow

- **kite-planner-with-taxonomy** writes the Slice block, the order/status table,
  each scenario's Code-blind plan, and the slice-level Research questions →
  status `planned`.
- **kite-research** answers the slice's research questions into
  `codebase-research.md`, points the plan's Research findings line there, and sets
  the slice status to `researched`, or `blocked` if it finds a BLOCKING issue.
- **kite-implementation** writes each scenario's Implementation record → scenario
  status `in_progress`, then `committed`.
- **kite-feature-review** only reads the plan file; its output is the separate
  review report document.
