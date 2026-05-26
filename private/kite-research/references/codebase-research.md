# codebase-research.md

A single, **feature-wide** Markdown document, written next to the slices (in the
`<feature>-slices/` directory) as `codebase-research.md`. It is created on the
first slice's research and **updated** on every later slice — never recreated.

It is the implementer's reference for what to reuse and where to add code, and it
is **kept current** as the codebase changes from slice to slice. Two design
choices make that work:

- **Findings are keyed by capability / codebase area, not by question.** Many
  questions across slices touch the same area; keying by area means each area has
  exactly one current answer, and overlap across slices is visible in one place
  for the refresh pass to land on.
- **Every finding carries provenance** — `Last verified: Slice N` plus a short
  history line — so a reader can tell at a glance whether an answer predates code
  a later slice changed, and the refresh is auditable.

### Template

```
# Codebase Research — <feature name>

Universal research for <feature>, maintained across slices. Each slice's research
iteration appends its findings and refreshes any prior answer whose code area the
new slice also touches. Findings cite names + locations, never copied source.

## Research log
| Iteration | Slice | Date       | New questions | Prior findings refreshed |
|-----------|-------|------------|---------------|--------------------------|
| 1         | 1     | 2026-05-26 | F1–F6         | —                        |
| 2         | 2     | 2026-05-28 | F7–F9         | F1 (MISSING→EXISTS), F3  |

## Findings
Keyed by capability / area. Each is the current truth for that area.

### F1 — <capability / area, e.g. "Snapshot persistence layer">
- Answer: EXISTS | MISSING
- Location: <file:line>  (EXISTS) | <extension point> (MISSING)
- Reuse / constraints: <caveats on EXISTS; convention to follow on MISSING>
- Serves questions: S1.RQ3, S2.RQ1
- Last verified: Slice 2
- History: Slice 1 → MISSING (ADD a snapshot_db.py per the db-module convention);
  Slice 2 → EXISTS at services/snapshot_db.py:31 — built by Slice 1, reuse directly

### F2 — <…>
- …

## Slice 1 — research iteration
- Questions sourced from: slice-1 plan (Slice research questions) + slice-1
  system-design §Open Questions
- Refresh pass: none (first slice)
- Discrepancies: <design asked X that the plan didn't carry — answered as F4>

| Question | Finding | Answer (short)                              |
|----------|---------|---------------------------------------------|
| S1.RQ1   | F1      | MISSING — ADD snapshot_db.py                 |
| S1.RQ2   | F3      | EXISTS — has_app_access at deps/auth.py:88   |

## Slice 2 — research iteration
- Questions sourced from: slice-2 plan + slice-2 system-design §Open Questions
- Refresh pass: F1 flipped MISSING→EXISTS (Slice 1 built the snapshot layer);
  F3 re-confirmed unchanged
- Discrepancies: none

| Question | Finding | Answer (short) |
|----------|---------|----------------|
| S2.RQ1   | F1      | EXISTS — reuse services/snapshot_db.py:31 |
| S2.RQ2   | F7      | MISSING — ADD cooldown check in … |

## Blocking findings
<!-- Present only when research contradicts a slice's plan/design. -->
- Slice 2 / S2.RQ4 — <contradiction: the design assumed …, but the code …>;
  slice status set to `blocked`, needs re-planning.
```

### Ownership

- **kite-research** owns this file end to end: it creates it on the first slice
  and, on every later slice, adds the new iteration section + findings and
  refreshes any stale prior finding the new slice overlaps.
- **kite-implementation** reads the current slice's iteration section (and the
  findings it points to) to know what to reuse and where to add code. It does not
  write here.
- The per-slice plan file (`slice-N-<short>-plan.md`) holds the scenarios,
  statuses, and questions; its **Research findings** section points here rather
  than duplicating answers.
