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

### Research findings          (written by kite-research)
- RQ1 → EXISTS: <name> at <file:line> — <how to reuse>
- RQ2 → MISSING: ADD at <location> — <what to add>
- Reuse constraints: <caveats on anything marked EXISTS>
- BLOCKING: <only present if research invalidates the plan>

### Implementation record      (written by kite-implementation)
- Changed files: <...>
- Tests added: <...>
- Architecture check (kite-design-system-standards): pass | <issues found and fixed>
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
