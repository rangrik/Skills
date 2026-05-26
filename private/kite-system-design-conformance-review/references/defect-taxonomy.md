# System-Design Conformance Defect Taxonomy

The recurring ways a per-slice system-design spec
(`slice-N-<short>-system-design.md`) fails to faithfully achieve its behavior
slice, falls short of its own template and autonomy bar, or designs against a
codebase reality it never checked. For each: **how to detect it**, a **worked
example** (drawn from designing a "Growth tab — SEO keyword rankings" feature,
the same running example the slicing skills use), and **what the fix or question
looks like**. Read this before the Stage-1 hunt; the fidelity modes (2) and the
autonomy mode (5) are the ones the designer's own checklists never catch, and the
reality family (C1–C5) is the one *no* code-blind reading can catch at all.

A mental model: defects split into three families.

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
- **Reality contradictions (C1–C5)** — the design vs the actual codebase across
  the proposed feature's whole **blast radius**. The designer was code-blind on
  purpose, so it can confidently mark a subsystem "New" that already exists,
  decide an approach the shipped code already rejected, or leave a §10 question
  open that reality already answered. These are invisible to families 1–7 because
  nothing in the slice or the template knows what is built. They are found by the
  **one code-aware reviewer** this skill is allowed to spawn (Stage 0), and — to
  keep the designer code-blind — reported back **only in subsystem + behavior
  terms, never code** (see the firewall below). They route back to the designer's
  grill loop, not to an inline fix.

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

## Family C — Reality contradictions *(design vs the actual codebase)*

These are the defects a code-blind designer **structurally cannot** see on its
own. They are caught by a code-aware reviewer mapping the **blast radius** of the
design — every subsystem it marks New, Modified, or Reused, plus the existing
subsystems that already read or write the same data — and checking each against
what is actually built. The point is to make the user **clarify** each real
contradiction now, so a decision built on a false premise doesn't flow downstream
into planning and code as noise.

This family is hunted in **two places**, both governed by this same definition and
firewall:

- **Per slice, at the designer's P4a gate** (`kite-system-design-blueprint-slices`)
  — the primary catch. Before each slice's spec finalizes, the designer commissions
  a reality check scoped to *that slice's* blast radius (its subsystems + its
  `Builds on:` ancestors). This is where C1–C4 and a slice's own C5 are normally
  found and resolved with the user, so the false floor never reaches the next
  slice.
- **Whole-set, at this skill's Stage 0** — the backstop. Once every slice is
  designed, one pass over *all* designs together catches the **cross-slice
  collateral** a single slice couldn't see (C5 where one slice's design affects a
  subsystem another slice owns) and nets anything the per-slice checks missed.

The firewall and the dispositions below apply identically in both places.

### The firewall — how a code-aware finding is allowed to travel

The reviewer reads source; the designer must not. So a Family-C finding crosses
the boundary **only** as three system-design-altitude facts:

1. **The subsystem** — its canonical `SYSTEM_TAXONOMY.md` name (the title the
   team and the design doc already use). If the thing isn't in the taxonomy, name
   it plainly at system altitude *and* flag the taxonomy gap — never reach for a
   code identifier to name it.
2. **The design element it collides with** — e.g. "§3 row *DataForSEO adapter =
   New*", "Decision D1", "Assumption A8", "§10 Q1".
3. **The nature of the contradiction**, phrased exactly as the design doc itself
   phrases things — *exists / already supplies this field / already persists this
   in a different shape / already retries / has a different contract* — plus a
   recommended reconciliation direction.

What may **never** cross: file paths, symbol or function names, class names,
table or column names, migration ids, code snippets, line numbers. Those are the
proof the reviewer used; they stay on the reviewer's side. A finding that can
only be stated by quoting code is a finding stated at the wrong altitude —
re-state it as a subsystem behavior, or drop it. This is what keeps the designer
**code-blind but system-aware**: it learns *which named subsystem* contradicts
*which decision*, never the source.

A subtler leak than a bare identifier is **describing an existing subsystem's
internal shape** — "a summary record plus per-keyword child rows keyed by domain,
carrying a status field of *owned* vs *competitor*" smuggles the column names and
enum values across in prose even though no symbol is quoted verbatim. Don't do it.
A reality check returns **named collisions between a design element and a
subsystem's *behavior***, not a tour of how a subsystem is built. The test: if a
sentence reads as a *description of internal structure* rather than *"this design
element collides with this subsystem's behavior,"* you have left the altitude —
restate it as the behavior that collides, or omit it. And don't volunteer
structure to answer a "what shape is X?" question: such a question is itself at
the wrong altitude (it belongs in the design's §10 as an EXISTS/MISSING research
item, not the reality check), so answer only the contradiction it implies, if any.

### C1. Phantom-new subsystem *(reality — existence)*

**Detect:** A §3 row marks a subsystem **New**, or a §10 question treats a
capability as possibly-missing, but the subsystem already exists and works.

**Example:** §3 lists "DataForSEO adapter — New (or reuse prototype)" and §10 Q1
asks whether a ranked-keywords client exists. In reality the provider-call
subsystem is already built and tested. Every decision premised on *building it
fresh* (its grammar, its caps, its failure model) is now suspect.

**Disposition — return to designer:** Report as `{subsystem: DataForSEO provider
adapter; element: §3 New row + §10 Q1; nature: already exists and is exercised —
reuse, don't build}`. The designer asks the user whether to reuse as-is, and
revisits any decision that assumed a clean build.

### C2. Decision contradicts an existing subsystem's shape or behavior *(reality — the dangerous one)*

**Detect:** A §4 decision picks an approach that collides with how an existing
subsystem already stores, moves, or acts on the same data. The design is
internally coherent and cites a principle — it is *reality*-incoherent. This is
the Family-C analogue of defect 2: it reads perfectly and only a code-aware pass
catches it.

**Example:** D1 decides the snapshot is "one JSON document per fetch" and
explicitly lists "normalized per-keyword child table" as the *rejected*
alternative. The Ranked Keywords Snapshot subsystem already persists keywords as
individual per-keyword records — the rejected alternative is the shipped reality.
Building D1 means either a parallel store or ripping out working persistence.

**Disposition — return to designer:** Report as `{subsystem: Ranked Keywords
Snapshot; element: Decision D1; nature: already persists per-keyword records, not
a single document — D1's rejected alternative is what exists; recommend adopting
the existing shape unless the user has a reason to diverge}`. The designer puts
the fork to the user; D1 likely flips.

### C3. Assumption already settled by reality *(reality — assumptions)*

**Detect:** A §6 assumption flagged "needs confirmation" (or banked silently) is
already answered by what is built — and a contingency hanging off it dissolves.

**Example:** A8 assumes the provider "supplies the per-keyword fields incl.
year-over-year trend — needs confirmation (Q2)", and the design carries a
contingency to *drop the column or defer YoY to Slice 2 if missing*. Those fields
are already supplied and persisted. The contingency is dead weight that would
otherwise survive into the plan as a phantom branch.

**Disposition — return to designer:** Report the assumption as confirmed by
reality and the contingency as removable. Usually a light touch, but still the
user's call to confirm before the spec re-finalizes.

### C4. §10 question already answered *(reality — open questions)*

**Detect:** A §10 EXISTS/MISSING question is already settled by the codebase. The
trap is treating this as a clerical "just fill in the answer": if a decision was
built around the question's *assumed* answer, that decision is implicated too
(links straight to C1/C2).

**Example:** §10 Q9 asks the "new table + migration convention." The snapshot
tables already exist. Answering Q9 isn't enough — D1, which assumed it was
authoring a fresh table, has to be revisited.

**Disposition — return to designer:** Report the question as answered AND name
every decision/assumption that leaned on the old answer, so the designer doesn't
"resolve" the question while leaving a now-false decision standing.

### C5. Unaccounted blast-radius effect *(reality — collateral)*

**Detect:** The design's writes or changes touch a subsystem it marks "Reused"
(as if read-only), or affect an *existing* downstream consumer the design never
names. This is the part of "blast radius" beyond the design's own §3 list — what
else already depends on the data the design moves.

**Example:** The design treats the snapshot store as a fresh write target, but
existing competitor / target-keyword / draft-page subsystems already read from
that same store. The design's per-visit writes change what those consumers see —
an effect §2.3 "Actors & effects" never accounts for.

**The escalation bar — a found effect is not automatically a fork.** Detecting
that another subsystem reads the same data is the easy part; most such overlaps
are harmless. A C5 effect is worth the user's attention — and may be returned to
the designer as a fork — only when **both** of these hold:

1. **It is a regression, not just an effect.** This slice's design would make an
   existing consumer see *wrong, broken, or contractually different* data or
   behavior — not merely *fresher* or *equivalent* data through a path the
   consumer already supports. (Same domain's rankings arriving sooner is an
   effect; the consumer silently reading the *wrong* domain's rankings, or losing
   a field it relies on, is a regression.)
2. **The remedy lives in a subsystem the design under review owns** — this slice
   at the per-slice P4a gate, the feature's own slices at the whole-set backstop.
   If the only way to prevent the effect is to change a consumer that belongs to a
   *different* feature, the contradiction is not this design's to resolve. Forcing
   it in makes the slice responsible for another feature's design choice — which is
   the coupling C5 is meant to *surface*, not *create*.

When both hold, route it to the designer as a fork (below). When either fails —
the effect is benign/equivalent, or the only fix lives in a subsystem outside the
design's scope — it is **real but not meaningful**: record it as an append-only
entry in the feature's **BLAST-IMPACT ledger** (`<feature>-slices/BLAST-IMPACT.md`;
schema and rules in
`kite-system-design-blueprint-slices/references/blast-impact-ledger.md`) naming
the affected subsystem and the effect, and leave it to the whole-set backstop and
the owning subsystem's own future work. Do **not** turn it into a per-slice fork.
The ledger entry preserves the safety net (the effect isn't lost, and the owner
can find it) without dragging an unrelated feature into this slice's grill — the
slice stays focused on designing its own functionality.

**Disposition — return to designer only when the bar is met.** For an effect that
clears both tests, report the affected subsystem and the unmodelled regression;
the designer decides with the user whether to accept it or amend §2.3 / §4 — an
intent call, not a fix. For everything below the bar, report it as a recorded
note, not a contradiction to resolve.

### Adjudicating Family C (still gate it)

Reality contradictions get the **same Stage-2 gate** as everything else — the
goal is to make the user clarify *real* contradictions, not to flood them. A
"contradiction" that is actually the design correctly planning to *extend* an
existing subsystem, or correctly depending on a `Builds on:` capability, is a
**false positive** — discard it. A trivially-answered §10 fact with no decision
hanging off it is **real but not meaningful** — note it, don't make the user
clarify it. Only contradictions that would change a decision, dissolve an
assumption, or alter the blast radius reach the designer's grill loop.

For **C5 specifically**, apply its escalation bar: an effect on an existing
consumer of shared data reaches the grill loop only when it is a genuine
*regression* (wrong/broken/contractually different data, not merely fresher or
equivalent) **and** the remedy lives in a subsystem the design under review owns.
A benign/equivalent effect, or one whose only fix belongs to an unrelated
feature's subsystem, is recorded as a one-line note and left to the whole-set
backstop — it is not a per-slice fork. This is the most over-fired class in the
family: detecting a shared reader is cheap, so the bar is what keeps the safety
net from becoming noise that pulls unrelated features into a slice's design.

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
| C1 Phantom-new subsystem | Real | When a decision assumed a clean build of something that exists. | **Return to designer** (reuse decision + revisit dependents). |
| C2 Decision contradicts existing shape | Real | Almost always — the design would fight or duplicate shipped code. | **Return to designer** (fork to the user; decision likely flips). |
| C3 Assumption settled by reality | Real | When a contingency or deferral hangs off the now-settled assumption. | **Return to designer** (confirm; drop the dead branch). |
| C4 §10 question already answered | Real | When a decision leaned on the question's assumed answer. | **Return to designer** (answer it AND flag implicated decisions). |
| C5 Unaccounted blast-radius effect | Real (detection) | When this slice's design would cause an existing consumer a genuine *regression* (wrong/broken/contractually different data) **and** the remedy lives in a subsystem the design owns. A benign/equivalent effect, or one whose fix belongs to an unrelated feature, is real-but-not-meaningful. | **Return to designer** (intent call on §2.3 / §4) only when the bar is met; otherwise **append a note to the BLAST-IMPACT ledger** and leave to the whole-set backstop. |

Note the Family-C disposition is its own routing — **return to designer**, not
`fix`/`ask`. The conformance critic does not resolve a reality contradiction
inline, because resolving it is an intent call the *designer* owns and the
designer must make code-blind, from the named subsystem alone.

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
