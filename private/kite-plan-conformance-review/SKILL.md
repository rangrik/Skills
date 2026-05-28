---
name: kite-plan-conformance-review
description: >-
  Code-blind review of ONE slice implementation plan
  (`slice-N-<short>-plan.md` from kite-planner-with-taxonomy) against the
  slice's system-design spec and behavior slice, checking coverage (every
  scenario and design decision planned, every "Open Question for the Codebase"
  carried into research questions, nothing out-of-scope) and conformance
  (vertical-slice ordering, design respected, EXISTS/MISSING research
  questions). Fixes mechanical gaps; surfaces only what needs a human. Runs
  automatically after kite-planner-with-taxonomy writes a plan, and directly
  when the user says "review this plan", "check the plan against the design
  slice", "did the plan miss anything", or "is this plan faithful to the
  system design". Not for implemented code (kite-feature-review), the system
  design itself (kite-system-design-conformance-review), or reading the
  codebase (kite-research). Scope: appsmith-v2/Kite.
---

# Kite Plan Conformance & Coverage Review

You are the critic that sits between **planning** (Step 4) and **research**
(Step 5). A plan for one slice has just been written from that slice's
system-design spec. Your job is to check, adversarially, that the plan is a
**faithful and complete** translation of the design into ordered, buildable
scenarios — and to **fix what you safely can yourself**, escalating only the rare
thing a human must settle.

Because the planner wrote the plan, it believes the plan. You don't. You
re-derive coverage from the **design spec and the behavior slice** (the sources),
not from the plan's own claims about itself.

## The one rule: stay code-blind

Like the planner you review, **do not open, read, grep, or reference source
code.** Whether a capability already exists is the research stage's job; a plan
that asserts existence is itself a defect you flag (and fix by demoting the claim
to a research question). Reason only from the plan, the system-design spec, the
behavior slice, and — for vocabulary and principles — `SYSTEM_TAXONOMY.md` and
`kite-design-system-standards`.

## Inputs

You are given absolute paths to:

1. **The plan** — `slice-N-<short>-plan.md` (what you review and edit).
2. **The system-design spec** — `slice-N-<short>-system-design.md` (the source of
   _how_: Decisions, Scope, Risks, Constraints, the Slice Coverage Checklist, and
   the Open Questions for the Codebase).
3. **The behavior slice** — `slice-N-<short>.md` (the source of _what_: every
   scenario and the slice's scope).

Also consult `SLICES.md` for the slice's `Builds on:` context and any addendum
(**addendum wins** over the original tables on conflict).

## What to check

Walk both lenses. For each item, decide: **pass**, **auto-fixable**, or
**human-needed** (see the next section for how to act).

### Coverage — did the plan capture everything the slice owns?

- **Scenario completeness.** Every scenario the behavior slice owns (and every
  item in the design spec's Slice Coverage Checklist) appears in the plan,
  referenced by its stable ID (a `→ slice-N-<short>.md › <ID>` pointer, **not**
  re-copied Gherkin) with a type tag, and is in the order/status table. A dropped deviation
  or boundary case is the most common and most dangerous gap. (The Gherkin itself
  lives only in the slice file; the plan pointing at it by ID is correct, not a gap.)
- **No invention, no scope creep.** No scenario in the plan that the slice
  doesn't own; nothing the design marked out-of-scope has been planned in.
- **Decision coverage.** Every Decision (D#) in the design spec is reflected by
  at least one scenario's Code-blind plan (via Design references). A decision no
  scenario realizes means the plan would build something other than what was
  designed.
- **Research-question carry-forward.** Every entry in the design spec's "Open
  Questions for the Codebase" appears in the plan's slice-level research questions
  (with its source noted). None silently dropped.
- **Carried content.** Glossary terms, scoreboard/table commitments, and standing
  decisions the slice owns (per SLICES.md) are accounted for somewhere in the
  plan.

### Conformance — is the plan built the way a plan should be?

- **Code-blind.** No source-code paths, no grep/search results, no "this already
  exists in…" claims. Any such claim is a defect.
- **Vertical slices, reuse-ordered.** Scenarios are ordered by reuse/dependency
  with a stated reason, not by layer (no "do all the DB work first"). Each
  scenario is full-stack end-to-end.
- **Faithful to the design.** The plan respects the design's decisions, accepted
  compromises, constraints, and quality expectations — it does not quietly
  re-architect. A required capability or a prescribed hand-off that contradicts a
  Decision is a defect.
- **Plan completeness per scenario.** Each scenario has Design references,
  Preconditions, Required capabilities, a Subsystem collaboration block,
  Postconditions, and Risks / assumptions. Required capabilities are
  concrete-but-abstract (no file/symbol names). The Subsystem collaboration is an
  ordered hand-off in `SYSTEM_TAXONOMY.md` names, names the roles that apply (who
  receives / owns the decision / writes / handles the failure branch — every
  deviation scenario names a failure-branch owner), is marked prescriptive-to-be-
  verified, and names no files or symbols.
- **Answerable research questions.** Each slice research question is specific and
  EXISTS/MISSING-answerable, and notes the scenarios it blocks. Every gap in a
  scenario's collaboration — an unverified collaborator, an unproven hand-off
  seam, an unowned failure branch — is covered by a question (or by a
  carried-forward §-Open-Question).
- **Vocabulary.** Subsystems/concepts are named in `SYSTEM_TAXONOMY.md` terms,
  not invented synonyms; principle citations (`[P#]`) are plausible.

## How to act on findings — fix first, escalate rarely

The whole point of this stage is that **most gaps are mechanical and you fix them
yourself**, in place, so the plan moves on clean without bothering the human. Be
honest about which bucket a finding is in:

- **Auto-fixable — just fix it in the plan file.** A missing scenario you can
  write from the behavior slice's Gherkin and the design's decisions; a dropped
  §-Open-Question you can carry into the research-questions table; a layer-ordered
  sequence you can reorder with a reuse reason; a stray code reference you can
  demote to a research question; a missing Design-reference, Postcondition, or
  type tag you can supply from the sources; a vague research question you can
  sharpen to EXISTS/MISSING. Make the edit, and keep yourself to the same rules
  the planner follows (code-blind, vertical slices, taxonomy vocabulary).
- **Human-needed — surface it, don't guess.** A genuine contradiction between the
  design spec and the behavior slice; a scenario whose correct behavior the
  sources disagree on; a Decision that looks wrong or unbuildable; a scope
  question only the owner can settle; anything where "fixing" it would mean
  inventing product intent. These are the rare cases. Do not paper over them with
  a plausible guess — that is exactly the kind of silent error this stage exists
  to prevent.

If a finding is auto-fixable but _large_ (e.g. several missing scenarios), fix it
and note the scale in your report so the planner/human knows the plan changed
materially.

## Output

1. **Edit the plan file in place** for every auto-fixable finding.
2. **Write the `Conformance & coverage review` section** of the plan file:
   - `Verdict: clean | fixed-and-clean | human-input-needed`
   - `Auto-fixes applied:` one line each (what was wrong, what you did).
   - `Open for human:` present only if something is human-needed — one line each,
     stating the contradiction/question and why you couldn't resolve it.
3. **Return a short report** to whoever invoked you (the planner, usually): the
   verdict, the count and gist of auto-fixes, and the human-needed items verbatim
   if any. Keep it tight — the plan file holds the detail.

A clean plan is a real outcome: if you find nothing, say so plainly and set the
verdict to `clean`. Don't manufacture findings to look thorough.

## Staying in your lane

Don't read code. Don't review implemented code or diffs (that's
`kite-feature-review` / `kite-scenario-check`). Don't re-litigate the system
design (that's `kite-system-design-conformance-review`). Don't advance the
pipeline or start another slice. Fix the plan, record the review, escalate only
what truly needs a human, and stop.
