# CONDUCTOR-PROGRESS.md — the resumable state file

This is the conductor's own thin state machine, written to
`kite-conductor/<project-title>/CONDUCTOR-PROGRESS.md`. It exists so a fresh
agent (or you, after an interruption) can resume the pipeline from disk without
the transcript. Keep it thin: it tracks the overall phase and the per-slice
build status, and leans on each sub-skill's own progress artifacts for finer
detail.

## Skeleton

```markdown
# Conductor Progress — <Project Title>

**Project dir:** kite-conductor/<project-title>/ **Feature slug:** <feature>
**Phase:** grill | discover | slice | design | taxonomy | build | review | done
**gitignore ensured:** yes | no

## Phase checklist

| Phase      | Artifact                                  | Done? | Approved? |
| ---------- | ----------------------------------------- | ----- | --------- |
| 0 grill    | main.md                                   | yes   | n/a       |
| 1 discover | <feature>-blueprint.md                    | yes   | yes       |
| 2 slice    | <feature>-slices/ + CONFORMANCE-REVIEW.md | yes   | yes       |
| 3 design   | slice-\*-system-design.md (all)           | no    | no        |
| 5 review   | feature-review-<feature>.md               | no    | n/a       |

## Build loop (Phase 4) — one slice at a time

| Slice           | Demo line ("user does X, sees Y") | Planned? | Built? | Status                |
| --------------- | --------------------------------- | -------- | ------ | --------------------- |
| slice-1-<short> | _one-line demo, flag on, no seed_ | yes      | yes    | committed             |
| slice-2-<short> | _one-line demo, flag on, no seed_ | yes      | no     | in progress (S3 of 5) |
| slice-3-<short> | _one-line demo, flag on, no seed_ | no       | no     | pending               |

## Notes

- <blockers surfaced, decisions the user made at a gate, anything a resumer
  needs>
```

## Resume rules

Read this file plus what's on disk, then pick up at the first unfinished point:

1. **Phase order is fixed:** grill → discover → slice → design → taxonomy →
   build → review. A phase whose output artifact already exists on disk is done
   — skip it.
2. **Gates:** if a front-half artifact exists but `Approved?` is `no`, present
   it and get approval before advancing. Don't silently treat "written" as
   "approved".
3. **Build loop:** resume the lowest-numbered slice that is not yet `Built`. For
   intra-slice detail (which scenario, which step), trust the slice's own
   `slice-N-*-plan.md` scenario statuses and `kite-implementation`'s loop —
   don't duplicate that bookkeeping here.
4. **Taxonomy:** the freshness check runs once between design and build; mark it
   via the `Phase` field, not a separate row.
5. **Keep it current:** update `Phase`, the relevant `Done?`/`Approved?` cell,
   and the build table after each stage and each gate, so the file alone always
   reflects reality.

## What NOT to put here

- No copies of artifact contents — point to the files, don't transcribe them.
- No per-scenario implementation records — those live in the plan files.
- No design decisions or blast-impact entries — those live in the design phase's
  own docs (`BLAST-IMPACT.md`, the specs). Keep this file a map, not a mirror.
