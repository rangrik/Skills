# Slice Conformance Defect Taxonomy

The nine recurring ways a vertical-slice cut fails to conserve its source
blueprint. For each: **how to detect it**, a **worked example** (drawn from real
slicing of a "Growth tab — SEO keyword rankings" blueprint), and **what the fix
looks like**. Read this before the Stage-1 hunt; the subtle modes (3 and 4) are
the ones a self-graded ledger never catches.

A quick mental model: defects split into three families.
- **Coverage** (1, 2, 5) — something the blueprint named lands in zero or many
  slices. A careful ledger *can* catch these, but only if the ledger is derived
  independently rather than trusted.
- **Fidelity** (3, 6, 7, 9) — something landed, but the slice changed what it
  means. No ledger catches these; only reading the actual Gherkin does.
- **Forward-reference** (4, 8) — a promise or a stacking-induced state has no
  owner. Caught only by following every "→ Slice N" pointer to its destination.

---

## 1. Dropped scenario  *(coverage)*

**Detect:** For each scenario ID in your independent source inventory, find its
behavioral home in the slice files. Zero homes = dropped. Don't rely on
`SLICES.md` to tell you — derive the inventory yourself and check the slice files
directly.

**Example:** A blueprint's `Scenario Outline` has four rows; the slice that owns
it reproduces three. The fourth row (an empty-input case) appears in no slice. The
ledger counts the outline as "covered" because outlines are counted once.

**Fix:** Add the missing scenario/row to the owning slice's §6 or §7 and add its
row to the coverage ledger.

---

## 2. Duplicated scenario  *(coverage integrity)*

**Detect:** The opposite of dropped — a scenario's behavior appears in *two or
more* slices while the ledger asserts "exactly one." Compare your independent
placement against the ledger's claim. Watch for the same Gherkin re-titled: the
two copies may not share a heading.

**Example:** Source `HP-2 — Custom domain with no fresh cache triggers an
automatic fetch` is assigned by the ledger to Slice 1, but its near-verbatim text
*also* appears in Slice 2 (as the cache-miss branch). The "every scenario lands in
exactly one slice" invariant is false. This is defensible *behaviorally* (Slice 1
owns "first/every fetch", Slice 2 owns "stale-or-missing → fetch") — but the
ledger must say so instead of double-claiming.

**Fix:** Decide which slice owns which mechanism, re-title/re-scope so each copy
is distinct (or remove the redundant one), and correct the ledger so its
exactly-one claim holds — e.g. split the row into "HP-2a (first fetch) → Slice 1"
and "HP-2b (cache-miss fetch) → Slice 2".

---

## 3. Weakened / lost guarantee  *(fidelity — the dangerous one)*

**Detect:** For each *placed* scenario, diff its `Then`/`And` assertion clauses
against the source clause by clause. Every source assertion must be one of:
(a) present with the same meaning, (b) legitimately rewritten because it
references machinery this slice doesn't build yet, or (c) explicitly deferred to a
named slice. A clause that was **softened while the guarantee still applied in
this slice** is the defect. It reads fine in isolation — you only see it by
comparing to the source.

**Example:** Source 7.4a / 7.12a assert *"no partial or empty snapshot **is saved
as the cache**"* — a **persistence** guarantee. Slice 1 reworded this to *"no
partial or empty snapshot **is treated as a successful result**"* — only an
in-session **render** guarantee. But Slice 1's own glossary says it *writes a
snapshot on every fetch*. So a failed fetch could still persist a junk row, which
the later caching slice will read as valid — a poisoned cache. The persistence
guarantee still applied in Slice 1 and was the *more* important half; the reword
dropped exactly it.

**Fix:** Restore the lost clause to its original meaning, scoped to the slice:
*"no partial or empty snapshot is **persisted**."* Keep the render clause too if
the slice added it; the point is not to lose the persistence assertion.

---

## 4. Orphaned forward-promise  *(forward-reference)*

**Detect:** This is the *symmetric* check to "unrealizable scenario." Walk every
forward pointer in the slices — every flagged-assumption line and every
out-of-scope note of the form "X is upgraded / arrives / handled in Slice N." For
each, open Slice N and confirm a scenario or commitment there actually owns X. A
promise with no receiver is the defect.

**Example:** Slice 1's flagged assumption on the zero-keywords state says *"the
affordance is upgraded to a real refresh control in Slice 2."* But Slice 2 never
re-owns the zero-keywords scenario (its §7.10 covers only the large-result-set
case). The promised upgrade has no scenario, no checklist row, no owner — it will
simply be missed at build time.

**Fix:** Add the receiving scenario or commitment to the named slice (here: a
Slice 2 scenario, or a carried-content row, for "the zero-keywords state gains a
refresh control"). If on reflection it belongs nowhere, downgrade the promise from
a commitment to a flagged open question so it stops reading as planned work.

---

## 5. Dropped commitment  *(coverage — the non-scenario kind)*

**Detect:** Run the *commitments* inventory, not just the scenario one. Each
glossary term, each **field enumerated inside a term** (every keyword-table
column, every scoreboard metric), each confirmed decision, each standing
assumption must land in some slice or be deferred to a named one. A scenario count
that reconciles can still hide a dropped table column or a lost "no confirmation
dialog" decision.

**Example:** A blueprint's "Keyword table" glossary entry lists 13 columns; the
slice that renders the table lists 12, silently omitting "snippet ownership." No
scenario references it, so the scenario ledger looks complete.

**Fix:** Add the column to the rendering slice's glossary and a carried-content
ledger row mapping it to that slice.

---

## 6. Unrealizable placed scenario  *(fidelity)*

**Detect:** For each placed scenario, walk its steps and confirm every control,
affordance, capability, or state it names is built by *this* slice or an ancestor.
A scenario can pass coverage ("assigned somewhere") yet reference machinery the
slice doesn't build — a "refresh" button two slices early, a "previous snapshot"
that doesn't exist yet.

**Example:** Slice 1 places a scenario whose step says "the owner triggers a
manual refresh," but manual refresh is a Slice 2 capability. The scenario is in
the wrong slice or was pasted through unadapted.

**Fix:** Move the scenario to the slice that builds the capability, or rewrite the
offending step to what this slice actually does (and flag the adaptation). This
overlaps with the slicer's own realizability check — you are double-checking it
independently, because the slicer sometimes skips it.

---

## 7. Internal inconsistency within a slice  *(fidelity)*

**Detect:** Within a single slice, read the happy paths and deviations together.
When the slice made a layer-boundary decision (e.g. "this slice always fetches; no
cache yet"), confirm no scenario in the same slice still assumes the removed
behavior.

**Example:** A slice's happy path says "a loading state is shown on every visit"
(no cache), but a deviation in the same slice says "the previously cached data
stays on screen" (assumes a cache). Two different worlds in one slice.

**Fix:** Reconcile — usually by moving the cache-assuming deviation to the caching
slice, since the inconsistency is a symptom that the deviation was placed too
early.

---

## 8. Undefined boundary state  *(forward-reference)*

**Detect:** Stacking creates transient or degraded states the whole-feature
blueprint never had to consider, because earlier slices haven't built later
capabilities yet. List them per slice and confirm each is *named* — surfaced as a
flagged boundary assumption — even if the resolution is deferred.

**Example:** Slice 1 serves a live fetch on every visit with no freshness gate
(every visit is a paid call) until caching ships in Slice 2; the first-ever
snapshot has no prior snapshot to diff, so movement deltas aren't computable. If a
slice hits one of these and says nothing, the degraded state looks like an
oversight rather than an intended interim.

**Note on adjudication:** A boundary state that *is* flagged is usually a
**defensible judgment call**, not a defect — leave it. The defect is only when the
state is left entirely *unnamed*. And inventing a concrete product behavior for it
is *out of scope* for this skill: surface it for a product call, don't author it.

**Fix:** Add a flagged-assumption row naming the boundary state and what's
deferred. Do not invent the resolving behavior.

---

## 9. Invented behavior / scope drift  *(fidelity)*

**Detect:** The inverse of dropping — a slice's Gherkin asserts something the
*source blueprint never said about the feature*. The slicer authored new behavior
instead of partitioning existing behavior.

**Example:** A slice adds a scenario "the owner can export the keyword table to
CSV," but export appears nowhere in the source blueprint (which scoped "viewing
only"). The slicer drifted.

**Fix:** Remove the invented behavior, or — if it's actually desirable — flag it
as a *new* proposed behavior for the source blueprint, explicitly outside the
conserved set. A slicer conserves; it does not author.

---

## Adjudication reference (Stage 2)

Map each candidate gap to a verdict and a meaningfulness call:

| Defect type | Usual verdict | Meaningful when… |
| --- | --- | --- |
| 1 Dropped scenario | Real | Almost always — a lost scenario is a lost test/behavior. |
| 2 Duplicated scenario | Real (ledger) | When the double-claim could mislead the builder about ownership; cosmetic if both copies are identical and clearly the same slice. |
| 3 Weakened guarantee | Real | When the dropped clause is a guarantee that still holds in the slice (data integrity, security, persistence). Nearly always meaningful. |
| 4 Orphaned promise | Real | When the promised thing is a real commitment (a control, a column) that will be missed at build. |
| 5 Dropped commitment | Real | When the field/decision affects what gets built or shipped. |
| 6 Unrealizable scenario | Real | Always — the slice can't satisfy it as written. |
| 7 Internal inconsistency | Real | Always — the slice contradicts itself. |
| 8 Undefined boundary state | Real *only if unnamed* | When a user actually hits the state while the slice ships alone. |
| 9 Invented behavior | Real | When it expands scope beyond the conserved blueprint. |

Defensible judgment calls that look like defects but are not: a mechanism the
source named but the feature never scoped, reframed to a real mechanism the slice
introduces (defect-2-shaped but correct); a boundary state that *is* flagged
(defect-8-shaped but correct); a clause rewritten because it genuinely referenced
unbuilt machinery (defect-3-shaped but correct). Record these as acknowledged
divergences — never fix them.
