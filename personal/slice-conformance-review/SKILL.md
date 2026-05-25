---
name: slice-conformance-review
description: >-
  Adversarially audits a set of generated vertical slices against the source
  behavior blueprint they were cut from, to find what the slicing silently
  dropped, weakened, duplicated, or left unbuildable — then fixes only the gaps
  that are real AND meaningful and verifies each fix landed. This is the critic
  stage AFTER slice-blueprint: it re-derives coverage from the source instead of
  trusting the slices' own SLICES.md ledger, because a generator that wrote its
  own ledger believes it. Reach for it whenever a `<feature>-slices/` directory
  exists and the user says "review the slices", "check the slices against the
  blueprint", "did we miss anything in the slices", "are the slices faithful to
  the blueprint", "audit the slice conformance", "check what's missing in the
  slices vs the original", or has just sliced a blueprint and wants the cut
  verified before building — even if they never say "conformance" or "review".
  NOT for reviewing an implemented feature against its blueprint (that is
  kite-feature-review), reviewing a PR diff, or critiquing the source blueprint
  itself.
---

# Slice Conformance Review

You take a source behavior blueprint and the `<feature>-slices/` directory that
was cut from it, and you find every place the slicing failed to faithfully
conserve what the blueprint committed to. Then you fix the gaps that are *real
and meaningful*, and verify the fixes landed. You stop there.

## Why this is a separate skill from the slicer

The skill that cuts slices (`slice-blueprint`) writes its own coverage ledger —
the `SLICES.md` that claims "every scenario landed in exactly one slice." A
generator believes its own ledger. It will happily assert "HP-2 → Slice 1" while
HP-2's text also sits, word for word, in Slice 2; it will "adapt" a scenario for
narrower scope and, in the adapting, soften a guarantee that actually still
applied; it will promise "the refresh control arrives in Slice 3" in a flagged
assumption and never give Slice 3 a scenario that builds it. None of these trip
the generator's own checks, because the generator is grading its own homework.

A critic with fresh eyes catches them — but only if the critic refuses to trust
the artifact under review. That refusal is the whole method below. (This is the
same reason `kite-implementation` and `kite-feature-review` are separate: the
builder and the critic must be different agents with different incentives.)

## Inputs

- **The source blueprint** — the original, full behavior blueprint. The single
  source of truth for what the feature must do. Read it fully, first.
- **The slices** — the `<feature>-slices/` directory: the `slice-N-*.md`
  mini-blueprints and the `SLICES.md` index/ledger.

If either path is unclear, ask. Do not review slices against a blueprint that
isn't the one they were cut from.

## What you produce

1. **A review report** — `<feature>-slices/CONFORMANCE-REVIEW.md`: every
   candidate gap, its adjudication (real / false-positive / defensible judgment
   call), its meaningfulness, and the fix decision. This is the durable artifact;
   it must stand on its own so a human can see what you changed and what you
   deliberately did not.
2. **Surgical edits to the slice files** — applied in place, only for gaps that
   passed the Stage-2 gate (real AND meaningful). Minimal: restore the dropped
   clause, de-duplicate the scenario and correct the ledger, add the missing
   receiving scenario. Never a rewrite.
3. **A verification summary** — at the end of the report: each fix, and a
   pass/fail that it actually landed.

## How this runs: three roles, two of them sub-agents

The same "don't grade your own homework" logic that makes this a separate skill
from the slicer also applies *inside* this skill. So the work is split across
three roles, and two of them are delegated to fresh sub-agents on purpose:

- **The review sub-agent** (Stage 1 + a first-pass Stage 2). Spawn a sub-agent
  whose only context is the source blueprint and the slice files — *not* your
  reasoning, not the slicer's. It derives coverage independently, hunts the nine
  defect classes, and returns candidate findings each with a proposed verdict and
  meaningfulness. Fresh eyes are the entire value; an agent that already "knows"
  how the slices were built will rationalize the subtle defects away (we have seen
  baseline reviewers notice a softened guarantee and call it "internally coherent").
- **You, the orchestrator** (Stage 2 decision + Stage 3 fix). You take the review
  sub-agent's feedback, critically evaluate it — confirm the real-and-meaningful
  ones, reject false positives, leave defensible judgment calls alone — and apply
  the surgical fixes yourself. You own the edits because you own the report.
- **The verification sub-agent** (Stage 4). Spawn a *different* sub-agent, given
  only the list of fixes claimed and the files, to independently confirm each one
  landed. It must not be the agent that applied the fixes — a fixer checking its
  own work is the same self-confirmation trap this whole skill exists to break.

Delegate via whatever sub-agent mechanism the harness provides; sub-agent prompt
templates are at the end of Stages 1 and 4. If the harness genuinely has no
sub-agents, do the review and the verification as deliberately separate, fresh
passes — but prefer real sub-agents, because the independence is the point.

## The four stages — do them in order, do not skip the gate

The order matters and the gate (Stage 2) is non-negotiable. Reporting without
adjudicating leads to fixing phantom defects; fixing without verifying leads to
claiming a fix that never landed.

### Stage 1 — Report: derive coverage independently, then hunt

**First, build your own inventories from the SOURCE blueprint — before you open
`SLICES.md`.** This ordering is the point: if you read the slicer's ledger first,
you anchor to its claims and audit becomes proofreading. Derive the ground truth
yourself, then compare.

- **Scenario inventory** — every `@happy-path`, every `@deviation`, every row of
  every `Scenario Outline`, each with a stable ID (`HP-1`, `DEV-7.3a`) and a
  one-line note of its *load-bearing assertions* (the `Then`/`And` clauses that
  are actual guarantees, not flavor).
- **Commitments inventory** — every glossary term and **every field enumerated
  inside one** (each table column, each scoreboard metric is its own
  commitment), every confirmed decision, every standing assumption, every
  in-scope bullet.

**Then locate each item's home in the slices by behavior, not by title.** A
scenario renamed across the cut is still the same scenario; match on what it
asserts. Now run the defect hunt. The recurring failure modes of slicing — with
how to detect each, a real example, and what a fix looks like — are in
`references/defect-taxonomy.md`. **Read it before hunting.** In brief, you are
looking for:

1. **Dropped scenario** — a source scenario lands in *no* slice.
2. **Duplicated scenario** — its behavior lands in *more than one* slice while
   the ledger claims exactly-one. (Compare your derivation to `SLICES.md`; a
   ledger that says "Slice 1" for text that also appears in Slice 2 is lying to
   itself.)
3. **Weakened / lost guarantee** — a scenario was placed, but an assertion clause
   was silently softened or dropped while *that assertion still applied in the
   slice*. Adaptation may only touch clauses that reference machinery the slice
   doesn't build yet; a guarantee that still holds must survive verbatim in
   meaning. (This is the subtlest and most dangerous mode — it reads plausibly.)
4. **Orphaned forward-promise** — a slice's flagged-assumption or out-of-scope
   note says "X arrives in Slice N," but no scenario or commitment in Slice N
   actually owns X. The promise has no receiver.
5. **Dropped commitment** — a glossary field, table column, scoreboard metric,
   confirmed decision, or standing assumption lands in no slice.
6. **Unrealizable placed scenario** — a placed scenario's steps reference a
   control or state that the owning slice (and its ancestors) never builds.
7. **Internal inconsistency** — within one slice, a happy path and a deviation
   assume different worlds (e.g. "a loading state on every visit" beside
   "previously cached data stays on screen").
8. **Undefined boundary state** — stacking created a transient/degraded state
   (slice 1 has no cache; a first snapshot has nothing to diff) that *no* slice
   names or flags.
9. **Invented behavior (scope drift)** — a slice's Gherkin asserts something the
   source never said about the feature; the slicer authored instead of
   partitioned.

Record every candidate gap with the source evidence and the slice evidence side
by side. Within the hunt, still hunt first and judge second — surface every
candidate before talking yourself out of any — but the review sub-agent should
return a *proposed* verdict and meaningfulness for each, so the orchestrator has
something concrete to evaluate in Stage 2.

**This stage is the review sub-agent's job.** Spawn it with a prompt like:

```
Adversarially review a set of vertical slices against the blueprint they were
cut from. Read and follow the skill at <path>/slice-conformance-review/SKILL.md
(Stage 1 and its defect taxonomy reference) — but STOP after producing findings.
Do not fix anything.

- Source blueprint: <absolute path>
- Slices directory: <absolute path> (slice-N-*.md + SLICES.md)

Build your own scenario + commitments inventory from the SOURCE before reading
SLICES.md. Then hunt the nine defect classes. Return every candidate gap with:
source evidence, slice evidence, a proposed verdict (real / false-positive /
defensible judgment call), and a proposed meaningfulness call. Do not edit files.
```

The orchestrator takes the returned findings into Stage 2.

### Stage 2 — Evaluate: adjudicate each candidate gap (the gate)

This is what "evaluate the gaps" means: you now turn the same adversarial
scrutiny *on your own findings*. For each candidate gap, write three things:

- **Evidence** — the exact source clause and the exact slice clause (or its
  absence). A gap you can't quote both sides of is usually a false positive.
- **Verdict** — one of:
  - **Real defect** — the slicing genuinely failed to conserve something.
  - **False positive** — re-reading proves the commitment *is* conserved (just
    moved, or reworded without loss). Discard it; note why, so you don't
    re-raise it.
  - **Defensible judgment call** — a real divergence from the source, but a
    *correct* one the slicer made on purpose and flagged (e.g. reframing a
    "scheduled background refresh" the feature never scoped into "two concurrent
    on-visit refetches"). These are not defects. Record them as acknowledged —
    **do not fix them.** Auto-"fixing" a correct judgment call is how a reviewer
    makes the slices *worse*.
- **Meaningfulness** — even among real defects, fix only the ones that matter.
  Ask: does this gap cause a lost guarantee, an untested behavior that ships,
  a build that reads a poisoned data path, an orphaned commitment that never
  gets built, or a reviewer misled about what a slice delivers? If yes →
  meaningful. If it's a cosmetic reword that loses no guarantee, a label
  difference, or a stylistic nit → **real but not meaningful; report it, don't
  fix it.** The user was explicit: fix a gap only if it is meaningful.

**Only gaps that are `Real defect` AND `meaningful` enter the fix list.**
Everything else lives in the report with its verdict and reasoning. The value of
this gate is that the report stays honest about *why* something was or wasn't
touched.

### Stage 3 — Fix: surgical edits to the survivors only

Apply the smallest edit that resolves each fix-list defect, in the slice files
and/or `SLICES.md`. The fix shape follows the defect type (full recipes in
`references/defect-taxonomy.md`):

- Dropped scenario → add it to the owning slice's §6/§7 and the ledger.
- Duplicated scenario → keep the behavior in the one slice that should own it,
  remove or re-scope the copy, and correct the ledger so its exactly-one claim is
  true.
- Weakened guarantee → restore the lost clause to its original meaning, scoped to
  the slice (e.g. "no partial or empty snapshot is *persisted*", not "...treated
  as a successful result").
- Orphaned forward-promise → add the receiving scenario/commitment to the named
  slice, or, if it genuinely belongs nowhere, downgrade the promise to a flagged
  open question.
- Dropped commitment → add the carried-content row and put the field/decision in
  the slice that should carry it.

Keep edits in the source blueprint's voice and the slice template's format. You
are conserving the blueprint's intent, not rewriting it — the same discipline the
slicer was supposed to hold.

### Stage 4 — Verify: targeted re-check of just the fixes

Re-check **only the items you fixed** — not the whole feature. For each fix,
confirm the specific thing is now true: the restored clause now appears in the
slice; the ledger now maps the scenario to exactly one slice and the duplicate is
gone; Slice N now contains the promised scenario. Record pass/fail per fix in the
report's verification summary.

This is a bounded check, not a loop. Do not re-run the full Stage-1 hunt, and do
not iterate until "clean" — a fresh full hunt would surface new lower-priority
observations forever. Fix the meaningful gaps once, confirm they landed, stop.

**This stage is the verification sub-agent's job, and it must not be the agent
that applied the fixes.** Spawn a fresh sub-agent with a prompt like:

```
Independently verify that a set of fixes was actually applied to some slice
files. For each claimed fix below, open the named file and confirm the specific
change is present (and, where relevant, that the thing it replaced is gone).
Report PASS/FAIL per fix with the evidence you saw. Do not make any edits, and do
not evaluate whether the fixes were the right ones — only whether they are in.

- Files: <absolute paths>
- Claimed fixes:
  1. <file/section>: <what should now be true, e.g. "§7.4a asserts the snapshot
     is not *persisted*, not merely 'not treated as a successful result'">
  2. ...
```

Fold its PASS/FAIL results into the report's Verification section verbatim. If it
returns a FAIL, that fix did not land — re-apply it (Stage 3) and re-verify just
that one; do not expand the scope.

## Report format

Write `CONFORMANCE-REVIEW.md` in the slices directory using this structure:

```markdown
# Slice Conformance Review: <Feature Name>

**Source:** <blueprint path> · **Slices reviewed:** <N> · **Date:** <YYYY-MM-DD>

## Verdict
<2–3 sentences: is the cut faithful? how many meaningful defects, how many fixed,
how many defensible divergences left as-is.>

## Findings
<One subsection per candidate gap. For each: defect type, source evidence, slice
evidence, verdict (real / false-positive / defensible), meaningfulness, and fix
decision. Group by severity so the meaningful ones are unmissable.>

## Fixes applied
<One row per fixed defect: what was wrong, the edit made, the file/line touched.>

## Acknowledged divergences (intentionally not fixed)
<The defensible judgment calls and the real-but-cosmetic gaps, each with the
reason it was left alone. This section is why the report is trustworthy.>

## Verification
<One row per fix: the fix, and PASS/FAIL that it landed.>
```

## Principles to hold throughout

- **Distrust the ledger; derive the truth.** The single highest-value habit here
  is building your own inventory from the source before reading `SLICES.md`. Every
  defect class above hides behind a ledger that looks complete.
- **Hunt first, judge second.** Stages 1 and 2 are separate on purpose. If you
  adjudicate while hunting, you talk yourself out of the subtle findings (the
  weakened guarantee especially) before you've fully seen them.
- **A correct divergence is not a defect.** Slicing is judgment work; the slicer
  sometimes *should* deviate from the source (reframing an unscoped mechanism,
  flagging a boundary state). Recognize these and leave them be — the report's
  credibility depends on not "fixing" them.
- **Meaningful or it doesn't get touched.** A real gap that costs nothing
  downstream is a note, not an edit. Reserve edits for gaps that would otherwise
  lose a guarantee, ship an untested behavior, or mislead the builder.
- **Fix surgically, verify narrowly, then stop.** You are closing specific holes,
  not re-slicing. Minimal edits, a targeted re-check, done — no open-ended loop.
