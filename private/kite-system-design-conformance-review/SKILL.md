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
  triages only the real AND meaningful findings into dispositions — a
  fix it applies to the spec, a question it asks the USER interactively (folding
  the answer back in), a contradiction it returns to the designer to resolve, or
  a note it merely reports — and verifies every applied change landed with a
  fresh sub-agent. It ALSO runs a whole-set code-aware backstop: a single
  carved-out sub-agent reads the actual codebase and checks the feature's
  cross-slice blast radius for contradictions a single slice's own reality check
  (run earlier, per slice, by the designer) structurally couldn't see — chiefly
  collateral where one slice's design affects a subsystem another slice owns —
  reporting them back in subsystem + behavior terms only, never code, so the
  code-blind designer can resolve them with the user before the specs finalize.
  This is the critic stage AFTER
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
own completeness and autonomy bar. You **also** run a whole-set code-aware
backstop — checking the feature's *cross-slice* blast radius against the codebase
that actually exists, for the collateral a single slice's own reality check (run
earlier, per slice, by the designer) couldn't see. Then you resolve the gaps that
are *real and meaningful* — fixing what you can fix, asking the user what only
they can answer, and **returning reality contradictions to the designer** to
resolve in its grill loop — and verify your changes landed. You stop there.

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
4. **A cross-slice reality-contradiction handoff to the designer** — when the
   whole-set code-aware backstop finds collateral the per-slice checks couldn't
   see, a section listing each one in subsystem + behavior terms (no code), and a
   recommendation to re-run `kite-system-design-blueprint-slices` on the affected
   slice(s) to resolve them with the user. These are *not* fixed inline —
   resolving them is the designer's code-blind, user-facing job. (Most reality
   contradictions are already resolved upstream, per slice, at the designer's P4a;
   this backstop exists for what a single slice structurally couldn't see.)

## How this runs: four roles, three of them sub-agents

The same "don't grade your own homework" logic that separates this skill from the
designer also applies *inside* it. The work is split across four roles, three of
them delegated to fresh sub-agents on purpose:

- **The reality reviewer sub-agent** (Stage 0) — *the one code-aware role.* Spawn
  a sub-agent that **is** allowed to read the codebase (the single carved-out
  exception in this otherwise code-blind skill). Give it *all* the design specs at
  once, the `SYSTEM_TAXONOMY.md`, and the defect taxonomy's Family C. Its job is
  the **whole-set, cross-slice** view: it looks across every slice's design
  together for collateral a single slice couldn't see — one slice's design
  affecting a subsystem an earlier or later slice owns (C5 across slices) — and
  acts as a safety net for any per-slice contradiction (C1–C4) the designer's P4a
  check missed. It returns findings **through the firewall**: subsystem name +
  design element + the contradiction's nature, with *no* code artifacts (Family C
  in `references/defect-taxonomy.md` defines the firewall precisely). It is a
  separate sub-agent from the code-blind reviewer below precisely so code never
  leaks into the rest of the skill or into the designer.
- **The review sub-agent** (Stage 1) — code-blind. Spawn a sub-agent whose only
  context is the slices, their design specs, the template contract, and the
  defect taxonomy — *not* your reasoning, not the designer's, *not* the reality
  reviewer's code findings. It re-derives, per slice, what the design must achieve
  (from the slice) and must contain (from the template), hunts defect classes 1–7,
  and returns candidate findings each with a proposed verdict, meaningfulness, and
  disposition. Fresh eyes are the entire value: an agent that already "knows" how
  a design was reasoned will rationalize a weakened guarantee as "a reasonable
  simplification."
- **You, the orchestrator** (Stages 2–3). You take both sub-agents' findings,
  critically evaluate them, confirm the real-and-meaningful ones, reject false
  positives, leave defensible calls alone — then **resolve** the survivors: fix
  what you can fix, **ask the user directly** for the gaps that need their intent
  and fold the answer back into the spec, and **route reality contradictions back
  to the designer** (Family C never gets fixed inline). You own the edits because
  you own the report. You stay code-blind: you only ever see the reality
  reviewer's firewalled findings, never the code behind them.
- **The verification sub-agent** (Stage 4). Spawn a *different* sub-agent, given
  only the list of changes claimed and the files, to confirm each one landed. It
  must not be the agent that applied them — a fixer checking its own work is the
  self-confirmation trap this whole skill exists to break.

Delegate via whatever sub-agent mechanism the harness provides; prompt templates
are at the end of Stages 0, 1 and 4. The reality reviewer takes the **whole set
at once** (its value is the cross-slice view, so don't split it per slice); the
code-blind review sub-agent can still be split per slice if there are many.

The **reality pass (Stage 0) must run in a sub-agent — there is no inline
fallback.** The firewall only holds if the agent reading code is not you: you
cannot unsee source, so "read it yourself and then ignore the code" defeats the
code-blindness the rest of this skill depends on. If the harness has no sub-agent
mechanism, do **not** read code — skip Stage 0, say so loudly in the report, and
lean on the per-slice P4a checks (already done) plus the research stage as the
catch. The code-blind stages (1 and 4) *may* be run as separate fresh inline
passes if there are no sub-agents, since they never touch source — but prefer real
sub-agents: the independence is the point.

## The five stages — in order, and do not skip the gate

The order matters and the gate (Stage 2) is non-negotiable. The reality pass runs
**first** (Stage 0) because a reality contradiction can flip a decision the
code-blind hunt would otherwise waste effort auditing — there's no point grading
the fidelity of a design that's about to change. Reporting without adjudicating
fixes phantom defects; fixing without verifying claims changes that never landed;
**inventing an answer to a question only the user can settle** quietly defeats the
autonomy bar the design exists to protect; and **fixing a reality contradiction
inline** usurps the intent call the designer owns and breaks the firewall.

### Stage 0 — Reality check: cross-slice backstop (this skill's one code-aware pass)

The bulk of design-vs-reality contradictions are already caught and resolved
upstream, **per slice**, at the designer's P4a gate — before each spec finalizes,
the designer commissions its own firewalled reality check. This stage is the
**whole-set backstop** for what a single slice structurally couldn't see: the
*cross-slice collateral* where one slice's design touches a subsystem an earlier
or later slice owns, plus a safety net for any per-slice contradiction the upstream
check missed. Without it, a contradiction that only appears when all slices are
viewed together would slip straight into planning.

The reality reviewer sub-agent reads **all** the designs together and maps the
**feature-wide** blast radius — every subsystem any slice marks New / Modified /
Reused, *plus* the existing subsystems that already read or write the same data,
*plus* the data each slice's writes feed into that another slice consumes — and
checks against what is actually built, hunting Family C (C1 phantom-new subsystem,
C2 decision contradicts existing shape, C3 assumption settled by reality, C4 §10
already answered, C5 unaccounted blast-radius effect — C5 across slices is the one
this stage is really here for). Read Family C in `references/defect-taxonomy.md`
before running it.

**The firewall is the whole trick.** The reviewer reads source; the designer must
never. So every finding crosses back as exactly three things — the **subsystem**
(its `SYSTEM_TAXONOMY.md` title), the **design element** it collides with
(Decision Dn, Assumption An, a §3 row, a §10 question), and the **nature** of the
contradiction phrased at design altitude (*exists / already supplies this /
persists it differently / already retries / different contract*) plus a
recommended reconciliation. **No** file paths, symbols, table or column names,
migration ids, snippets, or line numbers — ever. That is what lets the
contradiction reach the code-blind designer without dragging code into it.

**This stage is the reality reviewer sub-agent's job.** Spawn it with a prompt
like:

```
You are the ONE code-aware reviewer in an otherwise code-blind design review. You
MAY read the codebase. Your job: take ALL of a feature's system-design specs
together and find contradictions with what the codebase actually contains —
focusing on CROSS-SLICE collateral that no single slice could see on its own (one
slice's design affecting a subsystem another slice owns), and acting as a safety
net for any per-slice contradiction an upstream check missed. Report WITHOUT
leaking any code back.

Read and follow Family C of <path>/kite-system-design-conformance-review/
references/defect-taxonomy.md, especially the firewall rule. STOP after producing
findings; fix nothing; edit no files.

- Slices directory: <absolute path> (slice-N-*-system-design.md, slice-N-*.md, SLICES.md)
- System taxonomy: <repo>/SYSTEM_TAXONOMY.md  (use its names for every subsystem)
- Codebase root: <repo path>
- Blast-impact ledger: <feature>-slices/BLAST-IMPACT.md (effects the designers
  already recorded as out-of-scope). Read it first: do NOT re-flag an effect
  already noted there. You MAY flag a recorded entry if reality shows it is
  actually a regression that meets the C5 fork bar, not the benign note it was
  filed as.

Map the FEATURE-WIDE blast radius across all slices: every New/Modified/Reused
subsystem, the existing subsystems that already touch the same data, and the data
one slice writes that another slice reads. Then check for C1–C5 against the real
code, prioritizing cross-slice C5. Return every contradiction as:
  - subsystem: <canonical SYSTEM_TAXONOMY title; if absent, a plain system-level
    name + a note that the taxonomy lacks the term>
  - design element: <which slice + Decision Dn / Assumption An / §3 row / §10 Qn>
  - nature: <the contradiction at design altitude, as the design doc would phrase
    it — exists / already supplies X / persists differently / already retries /
    different contract — plus a recommended reconciliation direction>
  - proposed verdict (real / false-positive / defensible) and meaningfulness.

ABSOLUTELY DO NOT include file paths, function/class/symbol names, table or column
names, migration ids, code snippets, or line numbers in any finding. If a
contradiction can only be expressed by quoting code, restate it as a subsystem
behavior or drop it. Code stays on your side of the firewall.
```

The orchestrator receives only these firewalled findings and carries them into
the Stage-2 gate alongside the code-blind findings. **Route them by the C5 bar:**
cross-slice collateral that meets the bar (a genuine regression whose remedy a
slice in this feature owns) is **returned to the designer** to resolve with the
user (per the designer's Re-entry step); collateral that is below the bar (benign,
or whose remedy lives outside this feature) is **appended to the BLAST-IMPACT
ledger** (append-only — never delete another slice's note; schema in
`kite-system-design-blueprint-slices/references/blast-impact-ledger.md`), not
forced into any slice. That keeps the whole-set pass from manufacturing per-slice
forks out of effects no slice should own. (If the harness has no
sub-agent mechanism, do **not** run this pass inline — as the "no inline
fallback" rule above requires: skip Stage 0, flag the skip loudly in the report,
and lean on the per-slice P4a checks already done plus the research stage as the
catch. You cannot unsee source, so reading it yourself would break the
code-blindness the rest of this skill depends on.)

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
checklists. Then hunt defect classes 1–7. Return every candidate gap with:
which slice, defect class, slice/template evidence, design evidence, a proposed
verdict (real / false-positive / defensible judgment call), a proposed
meaningfulness call, and a proposed disposition (fix / ask-user / report-only).
Do not edit any files.

You are CODE-BLIND: do not open, read, or grep source code. Reason only from the
slice, the design spec, the template, and the standards. Codebase contradictions
(Family C) are a different sub-agent's job — ignore them.
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
- **Return to designer** — a reality contradiction (Family C). You do **not** fix
  it and you do **not** ask the user yourself: resolving it is an intent call the
  *designer* owns, and the designer must make it code-blind, from the named
  subsystem alone. Add it to the handoff (Stage 3). Adjudicate it through the same
  gate first — a "contradiction" that is really the design correctly extending an
  existing subsystem is a false positive; a trivially-answered §10 fact with no
  decision hanging off it is real-but-not-meaningful, so note it rather than
  sending the designer (and user) back for noise.
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

**Return reality contradictions to the designer (do not resolve them here).**
Family-C survivors are *not* yours to fix or to put to the user — the designer
owns that, in its own grill loop, code-blind. Assemble them into the handoff
section of the report: each as `{subsystem, design element, nature +
recommendation}`, grouped by the slice whose design they belong to. Then recommend
re-running `kite-system-design-blueprint-slices` on the affected slice(s), which
will put each contradiction to the user, resolve it, and re-finalize the spec —
flipping a decision, dropping a dead assumption/contingency, or amending the data
flow as the user decides. Do not edit the spec for these yourself; the designer's
re-finalization is what closes them. (If the designer's re-finalized spec then
needs another conformance pass, that is a fresh run of this skill on the updated
set — not a loop you spin here.)

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
<2–4 sentences: are the designs faithful, complete, AND reality-aligned? how many
meaningful defects, how many fixed, how many resolved by asking the user, how
many reality contradictions returned to the designer, how many defensible
divergences left as-is. Note any slice still missing a design.>

## Reality contradictions returned to the designer
<The Family-C handoff. One row per contradiction, grouped by slice: the subsystem
(taxonomy title), the design element it collides with (Decision/Assumption/§3
row/§10 Q), the nature of the contradiction at design altitude, and the
recommended reconciliation. NO code artifacts. End with the recommendation to
re-run kite-system-design-blueprint-slices on the affected slice(s). If the
code-aware pass found none, say so.>

## Findings by slice
<One subsection per slice's design. For each candidate gap: defect class,
slice/template evidence, design evidence, verdict (real / false-positive /
defensible), meaningfulness, disposition (fixed / asked-user / returned-to-designer
/ reported), and the resulting change. Group so the meaningful ones are
unmissable.>

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
- **Code-blind everywhere but the one carved-out reviewer.** You — the
  orchestrator — and the Stage-1 reviewer verify the design's *reasoning*, not the
  codebase, and you only ever see the reality reviewer's firewalled findings. The
  Stage-0 reality reviewer is the single exception: it reads code, and it pays for
  that privilege by returning findings stripped to subsystem + behavior, never
  code. The firewall is load-bearing — it is what lets a real contradiction reach
  the code-blind designer without making the designer code-aware.
- **Don't fix what the designer must own.** A reality contradiction is resolved by
  the designer's grill loop with the user, not by your edit and not by your
  question. You surface it, named at system altitude, and hand it back. Fixing it
  inline would invent the intent call that is exactly the designer's to make.
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
