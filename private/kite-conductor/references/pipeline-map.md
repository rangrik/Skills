# Pipeline map — artifact handoff chain & what to hand each stage

Read this whenever you're unsure what a stage consumes, what it produces, or
where its output must land. Everything lives under the single project directory
`kite-conductor/<project-title>/` (created by `grill-me`), so paths below are
relative to that directory unless they say "repo root".

## Directory layout the pipeline fills in

```
kite-conductor/<project-title>/
  main.md                              # Phase 0  grill-me intake
  CONDUCTOR-PROGRESS.md                # your resumable state (you write this)
  <feature>-blueprint.md               # Phase 1  blueprint
  <feature>-slices/                    # Phase 2  slice-blueprint
    slice-1-<short>.md ... slice-N-<short>.md
    SLICES.md
    CONFORMANCE-REVIEW.md              #          slice-conformance-review
    slice-N-<short>-system-design.md   # Phase 3  kite-solution-design
    BLAST-IMPACT.md
    SOLUTION-DESIGN-PROGRESS.md
    SYSTEM-DESIGN-CONFORMANCE-REVIEW.md
    slice-N-<short>-plan.md            # Phase 4a kite-planner-with-taxonomy
    codebase-research.md               # Phase 4b kite-implementation (its Step 0)
    slice-N-<short>-S<ID>-unified.md   #          kite-implementation per-scenario briefs
  feature-review-<feature>.md          # Phase 5  kite-feature-review

# Outside the project dir (NOT in kite-conductor/, NOT subject to never-commit):
<repo-root>/SYSTEM_TAXONOMY.md          # system-taxonomy (repo-wide artifact)
<repo-root>/.gitignore                  # you append `kite-conductor/`
<feature code commits>                  # kite-implementation makes real product commits
```

`<project-title>` is the human-readable title `grill-me` chose. `<feature>` is a
short slug you derive once the blueprint exists; use it for filenames, but keep
every file under the same project dir.

## Stage-by-stage: input → output

| #   | Skill                        | Reads                                                                               | Writes                                                                                                                                | Notes                                                                                |
| --- | ---------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 0   | `grill-me`                   | the user (interview)                                                                | `main.md`                                                                                                                             | Front door. No gate; user is in the loop throughout.                                 |
| 1   | `blueprint`                  | `main.md`                                                                           | `<feature>-blueprint.md`                                                                                                              | Gate after.                                                                          |
| 2a  | `slice-blueprint`            | `<feature>-blueprint.md`                                                            | `<feature>-slices/slice-*.md`, `SLICES.md`                                                                                            | —                                                                                    |
| 2b  | `slice-conformance-review`   | the blueprint + `<feature>-slices/`                                                 | `CONFORMANCE-REVIEW.md` (+ surgical slice edits)                                                                                      | Gate after 2b.                                                                       |
| 3   | `kite-solution-design`       | `<feature>-slices/`                                                                 | `slice-N-*-system-design.md`, `BLAST-IMPACT.md`, `SOLUTION-DESIGN-PROGRESS.md`, `SYSTEM-DESIGN-CONFORMANCE-REVIEW.md`                 | Whole-set orchestrator; owns its designer + critic + readout in-session. Gate after. |
| —   | `system-taxonomy`            | the codebase                                                                        | `<repo-root>/SYSTEM_TAXONOMY.md`                                                                                                      | Once, before the loop, only if missing/stale.                                        |
| 4a  | `kite-planner-with-taxonomy` | one `slice-N-*-system-design.md`, the behavior slice, `SYSTEM_TAXONOMY.md`          | `slice-N-*-plan.md`                                                                                                                   | Auto-runs `kite-plan-conformance-review`. May ask the user.                          |
| 4b  | `kite-implementation`        | one `slice-N-*-plan.md`, system-design spec, behavior slice, `codebase-research.md` | refreshes `codebase-research.md` (its Step 0), per-scenario `*-unified.md`, **code commits**, fills the plan's implementation records | Per-scenario loop owned internally. Repeat 4a→4b per slice.                          |
| 5   | `kite-feature-review`        | blueprint, system-design, all commits, plan files                                   | `feature-review-<feature>.md`                                                                                                         | Auto-runs once all slices done; present the report.                                  |

## What to tell each stage when you launch it

You write nothing yourself; you just point each skill at the right inputs and
tell it where to write. Be explicit about paths so nothing leaks outside the
project dir. For the phases you **delegate to a sub-agent** (everything except the
`grill-me`/`blueprint` interviews and the gates — see the SKILL's hybrid model),
also attach the **relay contract**: stop and hand any user-only decision back to
the conductor, never ask the user directly, and return a brief summary plus paths
rather than the full documents.

- **blueprint:** "The intake is at `kite-conductor/<project-title>/main.md`.
  Write the behavior blueprint to
  `kite-conductor/<project-title>/<feature>-blueprint.md`."
- **slice-blueprint:** "Slice `…/<feature>-blueprint.md` into
  `…/<feature>-slices/`."
- **slice-conformance-review:** "Audit `…/<feature>-slices/` against
  `…/<feature>-blueprint.md`."
- **kite-solution-design:** "Drive the design phase over `…/<feature>-slices/`.
  Use `<repo-root>/SYSTEM_TAXONOMY.md` if present." (It handles the rest
  itself.)
- **kite-planner-with-taxonomy:** "Plan slice
  `…/<feature>-slices/slice-N-<short>- system-design.md`."
- **kite-implementation:** "Build slice
  `…/<feature>-slices/slice-N-<short>- plan.md`." (It refreshes research and
  runs its own loop.)
- **kite-feature-review:** "Review the whole feature against
  `…/<feature>-blueprint.md` and the slice specs; write the report to
  `…/feature-review-<feature>.md`."

## The two facts that change the obvious reading

1. **No standalone research phase.** Research is `kite-implementation`'s Step 0.
   Skip a dedicated `kite-research` stage entirely.
2. **Whole-set design, per-slice build.** Phase 3 is one call over all slices;
   Phase 4 loops plan→implement per slice. Don't interleave design into the
   per-slice loop — it breaks the cross-slice blast-impact ledger.
