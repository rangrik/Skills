---
name: kite-system-design-conformance-review
description: >-
  Adversarially audits the per-slice system-design specs
  (`slice-N-<short>-system-design.md`) produced by
  `kite-system-design-blueprint-slices` against (a) the behavior slice each was
  derived from and (b) each spec's own template + autonomy bar — finding
  scenarios left undesigned, guarantees the design would silently weaken, scope
  that drifted past the slice, hollow or placeholder template sections, and
  user-answerable unknowns left unresolved (the autonomy failure). It then
  triages only the real AND meaningful findings into three dispositions — a
  fix it applies to the spec, a question it asks the USER interactively (folding
  the answer back in), or a note it merely reports — and verifies every applied
  change landed with a fresh sub-agent. This is the critic stage AFTER
  `kite-system-design-blueprint-slices`, run ONCE every slice in a
  `<feature>-slices/` directory has a system-design spec. Reach for it whenever
  such specs exist and the user says "review the system designs", "check the
  designs against the slices", "did the design miss anything", "audit the
  system-design conformance", "are the solution designs faithful to the slices",
  or has just finished designing all the slices and wants the designs checked
  before planning and implementation — even if they never say "conformance".
  NOT for reviewing behavior slices against the blueprint (that is
  `slice-conformance-review`), reviewing an implemented feature (that is
  `kite-feature-review`), or critiquing the slice's product behavior (that is
  the blueprint's job).
---

# Kite System-Design Conformance Review

You take a `<feature>-slices/` directory in which every behavior slice
(`slice-N-<short>.md`) now has a system-design spec
(`slice-N-<short>-system-design.md`), and you find every place a design failed
to faithfully achieve the behavior its slice committed to, or fell short of its
own completeness and autonomy bar. Then you resolve the gaps that are *real and
meaningful* — fixing what you can fix, asking the user what only they can
answer — and verify your changes landed. You stop there.

This is the **Step-3 critic**: it sits to `kite-system-design-blueprint-slices`
exactly as `slice-conformance-review` sits to `slice-blueprint`. Run it once,
**after every slice has a design**, before planning (Step 4) consumes the specs.

## Why this is a separate skill from the designer

`kite-system-design-blueprint-slices` writes its own coverage proof — the §12
*Slice Coverage Checklist* that claims "every scenario in this slice is handled,"
and the §11 *Decision Coverage Checklist* that claims every architectural
dimension was considered. A generator believes its own checklists. It will tick
"HP-2 → §4 D2" while D2 says nothing that actually achieves HP-2; it will mark a
taxonomy dimension "Resolved" with a pointer to a section that doesn't resolve
it; it will "assume" its way past an intent fork the user actually had to settle,
and never flag it; it will state a confident "we already store this" in the
prose instead of recording it as the §10 codebase question the skill's own rules
require. None of these trip the generator's checks, because it is grading its own
homework.

A critic with fresh eyes catches them — but only if the critic refuses to trust
the checklists and re-derives the truth from the slice and the template. That
refusal is the method below. (Same reason `kite-implementation` and
`kite-feature-review` are separate agents: builder and critic must have different
incentives.)

## Inputs

- **The slices directory** — `<feature>-slices/`, containing the
  `slice-N-<short>.md` behavior slices, their
  `slice-N-<short>-system-design.md` specs, and `SLICES.md`.
- **The design-doc template** — the section contract every spec must fill, owned
  by the producer skill at
  `kite-system-design-blueprint-slices/references/design-doc-template.md`. The
  load-bearing sections are summarized in `references/defect-taxonomy.md` so the
  review sub-agent need not hunt for the file, but treat the producer's template
  as the authority on what "complete" means.
- **`kite-design-system-standards`** (optional, if consultable) — to sanity-check
  that a §4 decision's cited principle number actually exists and governs what
  it claims. If it can't be consulted, note that and judge citations only for
  internal coherence.

If the slices directory or which blueprint produced it is unclear, ask. Do not
review a design against a slice it wasn't derived from.

## Precondition: this runs at the END

Before anything else, pair them up: for every `slice-N-<short>.md`, confirm a
sibling `slice-N-<short>-system-design.md` exists. This skill is meant to run
**after the whole feature is designed** — auditing a half-designed feature
produces a report dominated by "not designed yet," which is noise, not findings.

- If **one or two** specs are missing, that is itself a finding — surface it
  ("slices 4 and 5 have no system-design spec; design them first, or do you want
  me to review only 1–3?") and let the user decide. Don't invent the missing
  designs.
- If **most** are missing, stop and say the feature isn't ready for this review
  yet; point the user back to `kite-system-design-blueprint-slices`.

## What you produce

1. **A review report** — `<feature>-slices/SYSTEM-DESIGN-CONFORMANCE-REVIEW.md`:
   one consolidated report, with a section per slice's design, listing every
   candidate gap, its adjudication (real / false-positive / defensible judgment
   call), its meaningfulness, its **disposition** (fixed / asked-user / reported
   only), and the resulting change. This is the durable artifact; it must stand
   on its own so a human can see what you changed, what you asked, and what you
   deliberately left alone.
2. **Surgical edits to the system-design specs** — applied in place, only for
   gaps that passed the gate. Minimal: restore the weakened guarantee, fill the
   real §12 pointer, move the mis-bucketed codebase claim into §10, fold a
   user's answer into the right section. Never a rewrite — you conserve the
   design's intent, you don't re-author it.
3. **A verification summary** — at the end of the report: each applied change,
   and a PASS/FAIL that it actually landed.

## How this runs: three roles, two of them sub-agents

The same "don't grade your own homework" logic that separates this skill from the
designer also applies *inside* it. The work is split across three roles, two of
them delegated to fresh sub-agents on purpose:

- **The review sub-agent** (Stage 1). Spawn a sub-agent whose only context is the
  slices, their design specs, the template contract, and the defect taxonomy —
  *not* your reasoning, not the designer's. It re-derives, per slice, what the
  design must achieve (from the slice) and must contain (from the template),
  hunts the defect classes, and returns candidate findings each with a proposed
  verdict, meaningfulness, and disposition. Fresh eyes are the entire value: an
  agent that already "knows" how a design was reasoned will rationalize a
  weakened guarantee as "a reasonable simplification."
- **You, the orchestrator** (Stages 2–3). You take the sub-agent's findings,
  critically evaluate them, confirm the real-and-meaningful ones, reject false
  positives, leave defensible calls alone — then **resolve** the survivors: fix
  what you can fix, and for the gaps that need user intent, **ask the user
  directly** and fold the answer back into the spec. You own the edits because
  you own the report.
- **The verification sub-agent** (Stage 4). Spawn a *different* sub-agent, given
  only the list of changes claimed and the files, to confirm each one landed. It
  must not be the agent that applied them — a fixer checking its own work is the
  self-confirmation trap this whole skill exists to break.

Delegate via whatever sub-agent mechanism the harness provides; prompt templates
are at the end of Stages 1 and 4. If there are many slices (say more than four),
prefer spawning one review sub-agent **per slice** in parallel — sharper focus,
smaller context — and merge their findings. If the harness genuinely has no
sub-agents, run the review and the verification as deliberately separate, fresh
passes, but prefer real sub-agents: the independence is the point.

## The four stages — in order, and do not skip the gate

The order matters and the gate (Stage 2) is non-negotiable. Reporting without
adjudicating fixes phantom defects; fixing without verifying claims changes that
never landed; and — unique to this skill — **inventing an answer to a question
only the user can settle** quietly defeats the autonomy bar the design exists to
protect.

### Stage 1 — Review: re-derive, then hunt

For **each slice/design pair**, the review sub-agent does two derivations from
source *before* trusting the spec's own checklists — because reading §11/§12
first turns the audit into proofreading:

- **From the slice:** the obligation inventory — every scenario / edge case /
  deviation, and each one's *load-bearing guarantees* (the `Then`/`And` clauses
  that are real commitments). Plus the slice's scope (in/out) and any
  `Builds on:` capabilities it is allowed to assume.
- **From the template:** the completeness inventory — the sections every spec
  must fill (§1–§12 + Appendix A) and the autonomy bar (no *user-answerable*
  unknown left open; anything still open must be a §10 codebase question).

Then hunt the defect classes. The recurring ways a system design fails its slice
or its own bar — each with how to detect it, a worked example, and what the fix
or question looks like — are in `references/defect-taxonomy.md`. **Read it before
hunting.** In brief, two families:

*Slice-fidelity (design vs its parent slice):*
1. **Undesigned scenario** — a slice scenario gets no real system-design
   treatment, though §12 may claim it does.
2. **Weakened or contradicted guarantee** — the design's data flow or decisions
   would violate, soften, or silently drop a guarantee the slice asserts. (The
   subtlest and most dangerous — it reads plausibly.)
3. **Scope drift** — the design solves for behavior the slice never scoped,
   reaches into a later slice's capability, redesigns a `Builds on:` ancestor, or
   defers slice-in-scope behavior to "out of scope."

*Completeness & autonomy (design vs its own bar):*
4. **Hollow section or false coverage** — a required section left empty,
   placeholder, or vacuous; or a §11/§12 row marked Resolved with a pointer that
   doesn't actually resolve it.
5. **Unresolved user unknown** — an intent/approach fork left silently assumed
   (not flagged for confirmation) or simply unanswered, so an implementer would
   have to go back to the user. **This is the autonomy failure, and the finding
   that routes to "ask the user."**
6. **Mis-bucketed question** — code-blindness broken in either direction: a
   codebase fact ("we already store X") asserted as settled prose instead of a
   §10 question, or a user-answerable intent question dumped into §10 as if the
   codebase could settle it.
7. **Unsupported or self-contradictory decision** — a §4 decision with no
   principle citation or rationale, a citation to a principle that doesn't govern
   what it claims, or a decision/tradeoff/risk that contradicts the §2 data flow
   or another section.

Record every candidate gap with the slice (or template) evidence and the design
evidence side by side. Hunt first, judge second — surface every candidate before
talking yourself out of any — but return a *proposed* verdict, meaningfulness,
and disposition for each, so the orchestrator has something concrete to evaluate.

**This stage is the review sub-agent's job.** Spawn it with a prompt like:

```
Adversarially review per-slice system-design specs against the behavior slices
they were derived from and against their own template. Read and follow the skill
at <path>/kite-system-design-conformance-review/SKILL.md (Stage 1 and its
defect-taxonomy reference) — but STOP after producing findings. Fix nothing.

- Slices directory: <absolute path> (slice-N-*.md, slice-N-*-system-design.md, SLICES.md)
- Template contract: <path>/kite-system-design-blueprint-slices/references/design-doc-template.md
- Design standards (if consultable): kite-design-system-standards

For each slice/design pair: build the obligation inventory from the SLICE and the
completeness inventory from the TEMPLATE *before* reading the spec's §11/§12
checklists. Then hunt the seven defect classes. Return every candidate gap with:
which slice, defect class, slice/template evidence, design evidence, a proposed
verdict (real / false-positive / defensible judgment call), a proposed
meaningfulness call, and a proposed disposition (fix / ask-user / report-only).
Do not edit any files.
```

### Stage 2 — Adjudicate: the gate

Turn the same adversarial scrutiny on the sub-agent's findings. For each
candidate gap write three things:

- **Evidence** — the exact slice/template clause and the exact design clause (or
  its absence). A gap you can't quote both sides of is usually a false positive.
- **Verdict** — one of:
  - **Real defect** — the design genuinely fails to achieve the slice or meet its
    bar.
  - **False positive** — re-reading proves the obligation *is* met (just handled
    in a different section, or the coverage pointer does hold). Discard, note why.
  - **Defensible judgment call** — a real divergence the designer made on
    purpose and flagged: a boundary state named as a flagged assumption, an
    intent fork resolved by an explicit recommendation in Appendix A because the
    user was unavailable, a capability correctly deferred to a named later slice.
    These are not defects. Record as acknowledged — **do not "fix" them.**
    Auto-correcting a correct judgment call is how a reviewer makes a design
    *worse*.
- **Meaningfulness** — even among real defects, act only on the ones that matter.
  Meaningful when the gap would: lose a guarantee the slice promised, leave a
  scenario shipping with no design behind it, send the implementer back to the
  user (autonomy broken), poison a data path, mislead the builder about what a
  decision delivers, or design something the slice never asked for. Cosmetic
  rewords, a missing-but-obvious label, a stylistic nit → **real but not
  meaningful: report it, don't act on it.**

**Only `Real defect` AND `meaningful` gaps get acted on.** Everything else lives
in the report with its verdict and reasoning. This gate is why the report stays
honest about why something was or wasn't touched.

Then assign each surviving gap its **disposition** — the routing the user asked
for:

- **Fix** — you can resolve it by editing the spec *without inventing user
  intent*: restore a weakened guarantee to match the slice; add the real §12
  pointer for a scenario whose handling already exists in the design; move a
  mis-bucketed "we already have X" claim from prose into a §10 question; add the
  governing principle citation to a decision; reconcile a self-contradiction. (The
  user's two framings — correcting something *wrong* and adding something
  *missing* — are both this: same target, the spec; the report's reason column
  records which.)
- **Ask the user** — the gap is an unresolved user-answerable unknown (class 5,
  and sometimes class 1/3 when the right design depends on intent). You **cannot
  invent the answer** — that is exactly the autonomy bar the design protects.
  Queue it for Stage 3's interview.
- **Report only** — false positives, defensible calls, real-but-cosmetic nits.

### Stage 3 — Resolve: ask, then fix

Do the asking first, because a user's answer may change what you fix.

**Ask the user (the queued unknowns).** Drive them to resolution with
`AskUserQuestion`, in dependency order, **recommended option first**:

- **Ground every recommendation in a principle.** Cite the governing Kite
  principle number from `kite-design-system-standards` where applicable; where the
  standard is silent, name the generic design principle. The designer skill held
  this discipline; you hold it too.
- **Push back, don't just transcribe.** If the user's answer would bend a
  principle (couple subsystems that should stay decoupled, skip idempotency on a
  retried path, cache with no invalidation story), name the principle, explain
  the failure it invites, offer the conforming alternative. If they still choose
  it, fold it in as a **named accepted compromise**, never a silent one.
- **Then fold the answer into the spec**, in the section that owns it: a resolved
  fork becomes a §4 Decision (with its citation) or a confirmed §6 Assumption;
  an answer that reveals a real risk adds a §8 row; if the unknown was
  mis-filed in §10, move it out now that it's settled. Keep the design's voice.

**Fix (the rest).** Apply the smallest edit that resolves each fix-list gap, in
the spec and only where the defect lives. The fix shape follows the defect class
(full recipes in `references/defect-taxonomy.md`). Keep every edit in the
template's format and the design's voice — you are conserving intent, not
re-authoring.

### Stage 4 — Verify: targeted re-check of just the changes

Re-check **only what you changed** — not the whole feature. For each applied
change, confirm the specific thing is now true: the restored guarantee now
appears in the data flow / decision; the §12 row now points at a section that
genuinely handles the scenario; the folded-in answer now lives in the right
section; the mis-bucketed claim is now a §10 question and gone from the prose.
Record PASS/FAIL per change.

This is a bounded check, not a loop. Do not re-run the full Stage-1 hunt and do
not iterate until "clean" — a fresh full hunt surfaces new low-priority
observations forever. Resolve the meaningful gaps once, confirm they landed, stop.

**This stage is the verification sub-agent's job, and it must not be the agent
that applied the changes.** Spawn a fresh sub-agent with a prompt like:

```
Independently verify that a set of changes was actually applied to some
system-design spec files. For each claimed change below, open the named file and
confirm the specific change is present (and, where relevant, that what it
replaced is gone). Report PASS/FAIL per change with the evidence you saw. Make no
edits, and do not judge whether the changes were the right ones — only whether
they are in.

- Files: <absolute paths>
- Claimed changes:
  1. <file / section>: <what should now be true, e.g. "§2.3 now asserts no
     partial snapshot is persisted, matching slice scenario 7.4a">
  2. <file / section>: <e.g. "§4 D3 now records the user's choice to refetch on
     every visit as an accepted compromise citing P-12">
  ...
```

Fold its PASS/FAIL verbatim into the report's Verification section. A FAIL means
that change did not land — re-apply it (Stage 3) and re-verify just that one; do
not expand scope.

## Report format

Write `SYSTEM-DESIGN-CONFORMANCE-REVIEW.md` in the slices directory using this
structure:

```markdown
# System-Design Conformance Review: <Feature Name>

**Slices directory:** <path> · **Designs reviewed:** <N of M slices> · **Date:** <YYYY-MM-DD>

## Verdict
<2–4 sentences: are the designs faithful and complete? how many meaningful
defects, how many fixed, how many resolved by asking the user, how many
defensible divergences left as-is. Note any slice still missing a design.>

## Findings by slice
<One subsection per slice's design. For each candidate gap: defect class,
slice/template evidence, design evidence, verdict (real / false-positive /
defensible), meaningfulness, disposition (fixed / asked-user / reported), and the
resulting change. Group so the meaningful ones are unmissable.>

## Questions asked & answers
<One row per user question: the unknown, the recommendation given (+ principle),
any push-back raised, the user's answer, and where it was folded into the spec.>

## Fixes applied
<One row per fix: what was wrong, the edit made, the file/section touched, and
whether the reason was "correct (something wrong)" or "complete (something missing)".>

## Acknowledged divergences (intentionally not acted on)
<The defensible judgment calls and the real-but-cosmetic gaps, each with the
reason it was left alone. This section is why the report is trustworthy.>

## Verification
<One row per applied change: the change, and PASS/FAIL that it landed.>
```

## Principles to hold throughout

- **Distrust the checklists; re-derive the truth.** The highest-value habit here
  is building the obligation inventory from the slice and the completeness
  inventory from the template *before* reading §11/§12. Every defect class hides
  behind a checklist that looks complete.
- **Conform to the slice, not just acknowledge it.** A scenario being *named* in
  §12 isn't coverage; the design must actually achieve its behavior and conserve
  its guarantees. The weakened-guarantee defect is the one to fear.
- **Never invent intent.** The bright line of this skill: a gap that needs a
  user-answerable answer goes to the user, not into a fabricated assumption.
  Inventing the answer is precisely the autonomy failure the design exists to
  prevent — and it is why this skill *asks* rather than only fixing.
- **Stay code-blind, like the designer.** You verify the design's reasoning, not
  the codebase. A "does X exist?" question is a §10 codebase question, never
  something you go and check.
- **A correct divergence is not a defect.** A flagged boundary state, a fork
  resolved by a recorded recommendation, a capability deferred to a named slice —
  these are judgment, not failure. Leave them; the report's credibility depends
  on it.
- **Meaningful or it doesn't get touched.** A real gap that costs nothing
  downstream is a note, not an edit and not a question that wastes the user's
  attention.
- **Fix surgically, ask sparingly, verify narrowly, then stop.** Close specific
  holes, ask only the questions that truly need the user, re-check just those
  changes — no open-ended loop, no re-design.
