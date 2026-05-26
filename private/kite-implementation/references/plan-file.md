# Plan file

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

### Research questions reference (written by kite-planner)
- Consolidated, slice-level research questions for kite-research to answer.

### Implementation record      (written by kite-implementation)
- Unified brief: <path to slice-N-<short>-S<ID>-unified.md>
- Changed files: <...>
- Tests added: <...>
- Scenario-check review verdict: <meaningful findings, or clean>
- Final adversarial gate (KISS + kite-design-system-standards): pass | <issues found and fixed>
- Commit: <hash / message, prefixed with the slice>
```

### Where research findings live

In the current pipeline, `kite-research` writes findings into a single,
**feature-wide `codebase-research.md`** rather than inlining them per scenario in
the plan file. The plan file carries the consolidated research *questions*; the
*answers* (EXISTS reuse points and MISSING extension points) live in
`codebase-research.md`. The implementation loop's collate step pulls the relevant
findings from there into each scenario's unified brief. (Older plan fixtures that
inline findings still work — the collator reconciles whatever layout it is given.)

### Ownership and status flow

- **kite-planner** writes the Feature block, the order/status table, Gherkin,
  Code-blind plan, and Research questions → status `planned`.
- **kite-research** writes Research findings → status `researched`, or `blocked`
  if it finds a BLOCKING issue.
- **kite-implementation** writes the Implementation record → status
  `in_progress`, then `committed`.
- **kite-feature-review** only reads the plan file; its output is the separate
  review report document.
