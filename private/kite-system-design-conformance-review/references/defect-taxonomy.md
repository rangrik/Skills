# System-Design Conformance Defect Taxonomy

The seven recurring ways a per-slice system-design spec
(`slice-N-<short>-system-design.md`) fails to faithfully achieve its behavior
slice, or falls short of its own template and autonomy bar. For each: **how to
detect it**, a **worked example** (drawn from designing a "Growth tab — SEO
keyword rankings" feature, the same running example the slicing skills use), and
**what the fix or question looks like**. Read this before the Stage-1 hunt; the
fidelity modes (2) and the autonomy mode (5) are the ones the designer's own
checklists never catch.

A mental model: defects split into two families.

- **Slice-fidelity (1–3)** — the design vs the parent slice. Does the design
  actually *achieve* the slice's behavior and *conserve* its guarantees, or did
  it acknowledge the scenario and then design something narrower, wider, or
  weaker? The §12 Slice Coverage Checklist *can* hide all three — it ticks
  "handled" without proving it. Only reading the slice's guarantees against the
  design prose catches them.
- **Completeness & autonomy (4–7)** — the design vs its own template and the
  autonomy bar. Is every required section truly filled? Is every "Resolved"
  checklist row real? And — the bright line of this skill — was every
  *user-answerable* unknown actually resolved, or did the design assume its way
  past an intent fork the user had to settle?

A short reminder of the section contract you are auditing against (authority is
`kite-system-design-blueprint-slices/references/design-doc-template.md`):

> §1 Summary · §2 Data Flow (2.1 Source / 2.2 Travel / 2.3 Actors & effects) ·
> §3 High-Level System View · §4 Decisions (each citing a principle) ·
> §5 Tradeoffs · §6 Assumptions · §7 Scope (In & Out) · §8 Risks ·
> §9 Constraints & Dependencies · §10 Open Questions for the Codebase ·
> §11 Decision Coverage Checklist (every decision-taxonomy dimension) ·
> §12 Slice Coverage Checklist (every slice scenario) · Appendix A: Captured
> Inputs. The **autonomy bar**: read alongside the codebase, no
> *user-answerable* unknown remains; anything still open is a §10 codebase
> question.

---

## 1. Undesigned scenario  *(slice-fidelity — coverage)*

**Detect:** For each scenario / edge case / deviation in your independent
obligation inventory (built from the SLICE, before reading §12), find where the
design actually achieves it — a decision, a data-flow step, a risk mitigation, a
§10 question that gates it. Zero real homes = undesigned. The §12 row may *claim*
a home; verify the pointed-to section actually addresses that scenario's
behavior, not merely names it.

**Example:** The slice has a deviation "the keyword fetch returns zero rows → the
empty state explains why and offers a retry." §12 maps it to "§2 Data Flow," but
§2 only traces the happy fetch path and never says what the system does on an
empty result. The scenario has a checklist tick but no design.

**Fix (or ask):** If the design elsewhere already implies the handling, add the
real §12 pointer and a sentence making it explicit. If achieving it needs an
intent choice (retry automatically? show stale data? hard error?), that is a
**question for the user**, not something to invent.

---

## 2. Weakened or contradicted guarantee  *(slice-fidelity — the dangerous one)*

**Detect:** For each *load-bearing guarantee* in the slice (the `Then`/`And`
clauses that are real commitments — persistence, integrity, security, ordering,
"no X happens"), check the design's §2 data flow and §4 decisions *enforce* it.
The defect is a design that would silently violate or soften a guarantee the
slice still asserts. It reads plausibly — you only see it by holding the slice's
guarantee against the design's mechanics.

**Example:** The slice asserts "no partial or empty snapshot is **persisted**."
The design's §2.3 says the snapshot row is written as soon as the fetch
*starts*, and updated on completion — so a fetch that errors mid-flight leaves a
partial row persisted. The design's §4 even ticks "data integrity" as resolved.
The guarantee the slice promised is quietly broken by the chosen write order.

**Fix:** Bring the design back into conformance with the guarantee — here, change
§2.3 / the relevant decision to persist only on successful completion, and note
it as a risk-mitigation in §8. Restore the guarantee's *meaning*, minimally;
don't re-architect. If conforming requires an intent choice, **ask the user**.

---

## 3. Scope drift  *(slice-fidelity)*

**Detect:** Compare the design's effective scope to the slice's §7 and its
`Builds on:` line. Three shapes: (a) the design solves for behavior the slice
never scoped (it *authored*, didn't *design what was asked*); (b) it reaches into
or rebuilds a capability a `Builds on:` ancestor already owns, or one a *later*
slice owns; (c) it pushes slice-in-scope behavior into §7 "out of scope."

**Example (a):** The slice scopes "view rankings only," but the design adds a
decision and data-flow for "export the table to CSV," which appears in no slice.
**Example (c):** The slice's happy path requires showing the per-keyword movement
delta, but the design lists "movement deltas" under §7 Out of Scope, deferring
behavior the slice actually committed to.

**Fix (or flag):** For (a), remove the un-scoped design; if it's genuinely
desirable, flag it as a *new* proposal for the slice/blueprint, outside the
conserved set — don't bank it. For (b), replace the rebuild with a dependency on
the owning slice's design (§9). For (c), pull the behavior back in-scope and
design it — or, if the user truly intends to defer it, that's a **question** and
then a slice-level correction, not a silent design choice.

---

## 4. Hollow section or false coverage  *(completeness)*

**Detect:** Walk the template's section list. Flag any required section left
empty, still holding a `<…>` placeholder, or filled with a vacuous line that
says nothing ("Risks: standard risks apply"). Then walk §11 and §12 row by row:
a row marked **Resolved** must point at a section that genuinely resolves it; a
row marked **N/A** must carry a real reason. "Resolved → §4" where §4 never
touches that dimension is false coverage — the checklist lying to itself.

**Example:** §8 Risks contains only the placeholder `| R1 | <…> | <…> | <…> |`.
And §11 marks "A3 Concurrency & consistency — Resolved — §4" although no §4
decision discusses concurrency at all (two tabs open, two concurrent refetches).

**Fix (or ask):** If the missing content is mechanically derivable from decisions
already made, fill it and correct the pointer. If the empty section hides a real
unmade decision (e.g. concurrency genuinely wasn't thought through), that is
either a §10 codebase question or — if it's an intent fork — a **question for the
user**. Don't paper a placeholder over a real gap.

---

## 5. Unresolved user unknown  *(autonomy — the bright line)*

**Detect:** This is the autonomy-bar check, and the finding that **routes to
asking the user**. Look for intent/approach forks the design *settled by silent
assumption* without flagging for confirmation, or simply left dangling. Signals:
a §6 assumption that is really a product/intent decision the user should have
made; prose that picks one of several reasonable approaches with no rationale and
no "needs confirmation"; a behavior the slice leaves open that the design also
leaves open. Ask the litmus question: *could an implementer with this spec, the
codebase, and good principles build the slice without going back to the user?* If
a fork still needs the user, it's this defect.

**Example:** The slice says rankings "refresh periodically." The design neither
decides nor asks how fresh: it just states in §6 "Assumption: data is refreshed
on each page visit." But "on every visit" (a paid API call each load) vs "at most
once per hour" vs "a nightly job" is an **intent + cost tradeoff only the user
can settle** — and the design banked one silently.

**Disposition — ask the user, don't fix:** Surface the fork with
`AskUserQuestion`, recommended option first, citing the governing principle (and
the cost tradeoff here). Fold the answer into the spec as a §4 Decision (with
citation) or a confirmed §6 Assumption. **Never invent the answer** — fabricating
intent is exactly the failure the autonomy bar exists to prevent.

---

## 6. Mis-bucketed question  *(autonomy / code-blindness)*

**Detect:** The designer skill is code-blind: facts only the codebase can settle
belong in §10, and intent only the user can settle gets resolved with the user.
This defect is the boundary broken in *either* direction:

- **Codebase fact stated as settled prose** — "we already store the snapshot in
  the rankings table" asserted in §2 or §4 as fact, instead of recorded as a §10
  EXISTS/MISSING question. The design banked an unverified "we have X."
- **User question dumped into §10** — an intent/approach fork ("should we cache
  or refetch?") parked in §10 as if research could answer it, when only the user
  can.

**Example:** §10 contains "Q4: Should rankings be cached for an hour or refetched
each visit?" — but no amount of code-reading answers that; it's a product/cost
choice. Meanwhile §4 D2 asserts "the existing `KeywordSnapshot` table already has
a `fetchedAt` column we reuse," stated as fact with no §10 question behind it.

**Fix / ask:** Move the codebase claim into §10 as an EXISTS/MISSING question and
strip the "we already have it" certainty from the prose (a **fix**). Move the
intent fork out of §10 and resolve it with the user (an **ask**), then record the
answer in §4/§6.

---

## 7. Unsupported or self-contradictory decision  *(completeness)*

**Detect:** For each §4 decision: it must carry a rationale and cite the
governing principle (Kite principle number where applicable, generic principle by
name where the standard is silent). Flag a decision with no citation, a citation
to a principle that doesn't actually govern what it claims, or no rationale at
all. Separately, read §2 / §4 / §5 / §8 together for contradiction: a decision
that conflicts with the data flow, a tradeoff that contradicts a constraint, a
risk "mitigated" by something another decision rules out.

**Example (unsupported):** §4 D1 "We compute deltas in the frontend" cites
"[P-3]" but P-3 governs idempotency, not client/server placement — the citation
is decorative. **Example (contradiction):** §2.3 says the snapshot is written by
the backend worker, but §4 D1 says deltas are computed in the frontend from data
the worker never sends — the data flow can't feed the decision.

**Fix (or ask):** For a missing/wrong citation where the decision itself is
sound, add the correct governing principle (a **fix**). For a genuine
contradiction, reconcile to the version the slice's behavior requires; if which
side is correct depends on intent, **ask the user**. If the decision is
unsupported because it was never really made, that's defect 5 — ask.

---

## Adjudication reference (Stage 2)

Map each candidate gap to a verdict, a meaningfulness call, and a disposition.

| Defect class | Usual verdict | Meaningful when… | Usual disposition |
| --- | --- | --- | --- |
| 1 Undesigned scenario | Real | Almost always — a scenario ships with no design behind it. | Fix if handling is derivable; **ask** if it needs an intent choice. |
| 2 Weakened/contradicted guarantee | Real | When the broken guarantee is load-bearing (integrity, security, persistence, ordering). Nearly always meaningful. | Fix to restore the guarantee; **ask** only if conforming needs intent. |
| 3 Scope drift | Real | When it adds un-asked work, rebuilds an ancestor, or drops slice-required behavior. | Fix (remove / re-depend / pull back in); flag authored behavior as a new proposal. |
| 4 Hollow section / false coverage | Real | When the empty section or false tick hides an unmade decision a builder relies on. | Fix if derivable; **ask** if it hides a real intent gap. Cosmetic placeholder on a truly N/A section → report only. |
| 5 Unresolved user unknown | Real | When an implementer would have to return to the user — the autonomy bar is broken. Almost always meaningful. | **Ask the user.** Never invent. |
| 6 Mis-bucketed question | Real | When a banked "we have X" could send the build down a poisoned path, or a user fork sits where research can't answer it. | Fix the codebase-fact direction; **ask** the user-fork direction. |
| 7 Unsupported / contradictory decision | Real (contradiction) / often minor (citation) | Contradiction: always. Missing citation: meaningful only if it masks that no decision was really made. | Fix the citation; reconcile the contradiction; **ask** if the right side needs intent. |

Defensible judgment calls that look like defects but are not — record as
acknowledged divergences, **never act on them**:

- A **boundary or degraded state that the design names** as a flagged assumption
  (looks like an undesigned scenario, but it's correctly surfaced for a later
  call) — defect-1/4-shaped but correct.
- An **intent fork resolved by an explicit recommendation in Appendix A** because
  the user was unavailable at design time, clearly recorded as such — defect-5-
  shaped but correct (the design didn't hide it; it made and flagged a call).
- A **capability deferred to a named later slice** with a real §9 dependency —
  defect-3-shaped but correct.
- A **mechanism the slice's source never scoped, reframed** into what the slice
  does scope — defect-3-shaped but correct.
