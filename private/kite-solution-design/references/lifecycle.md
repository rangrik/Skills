# Lifecycle — the full annotated walk

This is the narrative version of the orchestration, the prose source behind the
lifecycle diagram. Read it once to internalize who does what and why; the SKILL.md
loop is the operational summary. Throughout, **O** = orchestrator (you), **DW** =
design worker, **RW** = reality-check worker, **SW** = ledger-steward worker,
**BW** = whole-set backstop worker, **CW** = conformance critic worker,
**VW** = verify worker, **U** = the user.

## Phase 0 — Preflight (O)

O locates `<feature>-slices/`, confirms behavior slices + `SLICES.md` exist, and
reads/creates `SOLUTION-DESIGN-PROGRESS.md`. O determines the lowest-numbered
slice without a `*-system-design.md` sibling — that is where work resumes.
Producing slices is upstream (`slice-blueprint`); O never re-derives behavior.

## Per-slice loop — repeats for each slice in stacked order

The design phase's deepest principle is *don't pull the whole feature into your
head*. O honors it structurally: **a fresh DW per slice**, holding only that
slice. The cross-slice memory lives with O and in `BLAST-IMPACT.md`.

### Step 1 — Ledger reconcile (O ↔ SW ↔ U)
If `BLAST-IMPACT.md` exists, O spawns SW in FILTER mode with this slice's scope.
SW returns *only* this slice's relevant entries (silently discarding the rest, so
nothing unrelated pollutes the design). For each, O relays a FORK to U: *pull this
parked effect into scope now, or leave it parked?* Pulled-in entries become
in-scope requirements O passes to DW; SW marks them "picked up by slice-N". This
is why the ledger isn't a write-only graveyard — every parked note gets a chance
to be picked up by the slice that can fix it, but only with U's say-so.

### Step 2 — Spawn the design worker (O → DW)
O spawns DW for this one slice with the slice path, `Builds on:` names, taxonomy,
and any pulled-in ledger entries. DW absorbs the slice, sketches the data-movement
lens (source → travel → actors & effects), walks the decision taxonomy, and
classifies every unknown: safe assumption · user-answerable fork · codebase
question · N/A.

### Step 3 — The map, then the grill (DW → O → U)
DW first yields **the map** so a miscategorization is cheap to catch; O relays it
to U. Then DW yields its **P3 FORKs** in dependency order — each with a
recommendation and the principle behind it, plus push-back if U's likely intent
bends a principle. O relays each via the fork-relay contract and resumes DW with
the answer. **O answers nothing.** A bent principle comes back as a *named accepted
compromise*, never silent.

### Step 4 — Reality check (DW → O → RW → O → DW → U)
DW yields a **REALITY_CHECK_REQUEST** (forming decisions + §3 New/Modified/Reused
map + `Builds on:` names). O spawns **RW** — code-aware — itself. *This is the
linchpin:* because O owns the spawn, DW never reads code, so its code-blindness is
structural rather than honor-system. RW hunts C1–C5 and returns each contradiction
**firewalled**: subsystem name + design element + nature-of-collision only — no
paths, symbols, tables, or snippets. O hands them to DW. DW adjudicates and yields
a FORK for each genuine contradiction (O relays to U). For a C5 blast-radius effect
below the escalation bar (benign/equivalent data, or remedy owned by another
feature), DW yields a **LEDGER_OP/APPEND** instead — O records it; it is *not* a
fork. The escalation bar: a C5 effect is a fork only when it is a genuine
regression AND the remedy lives in a subsystem this slice owns.

### Step 5 — Spec written + closeout (DW → O → SW → U)
DW yields a **last-call FORK**, applies the autonomy test (could an implementer
build this with the spec + codebase + good principles and ask U nothing more?), and
writes `slice-N-<short>-system-design.md`, then emits **SPEC_WRITTEN**. O asks SW
for this slice's open/parked entries and tells U plainly what this slice is **not**
fixing and where it's recorded — every time, zero surprise. O marks the slice
`designed` and advances to the next un-designed slice.

## After every slice has a design — the whole-set phase

The critic works the whole set at once, so it runs only when every slice is
`designed`. Per-slice reality checks (step 4) cannot see cross-slice collateral —
"slice 1's write changes what slice 3's subsystem reads" — so the whole-set passes
exist for exactly that.

### Step 6 — Whole-set backstop (O → BW)
O spawns **BW** — code-aware, the whole set at once — to map the feature-wide blast
radius and find cross-slice contradictions, returned **firewalled**. BW appends
below-bar collateral to the ledger (via SW); bar-meeting collateral returns to O.

### Step 7 — Conformance critic (O → CW → O)
O spawns **CW** — fresh-eyes, code-blind — handing it BW's firewalled findings as
its Stage-0 input (CW does not read code; O already did). CW re-derives coverage
from the slices and template (distrusting the designer's own checklists), hunts
defect classes 1–7, and **applies the fixes it owns** to the specs. It yields its
other dispositions: **ASK** FORKs (O relays to U; answer folded into the spec by
CW), **RETURN_TO_DESIGNER** packets for Family-C reality contradictions (step 8),
and below-bar LEDGER_OP/APPENDs. Report-only items stay in CW's report.

### Step 8 — Designer re-entry for returns (O → DW → U)
For each slice with returned contradictions, O spawns a fresh DW in re-entry mode
with just those contradictions. DW runs a focused grill (O relays the FORKs to U)
and folds each resolution into that slice's spec — flip a decision, drop a dead
assumption, correct a §3 row, close a §10 question, or amend §2.3. If a
re-finalization materially changed decisions, O notes it; a fresh whole-set pass is
U's call, not a loop O spins.

### Step 9 — Verify + readout (O → VW → O → U)
O spawns a fresh **VW** (never a fixer) with the list of applied changes; it
returns PASS/FAIL per change, folded into the report. A FAIL → re-apply that one
change and re-verify just it, no re-hunt. O marks every slice
`conformance-checked`.

Finally, the **blast-impact readout**: O asks SW for all open/parked
`BLAST-IMPACT.md` entries and tells U, plainly, every cross-boundary effect the
feature's design leaves unfixed — each with severity and the owner who would fix
it. Mandatory. This is the payoff of the whole ledger discipline: the user ends the
design phase knowing exactly what blast radius they're carrying forward, and for
whom.

## Close (O)

Every slice has a conformance-reviewed spec; the ledger is current; U has had the
readout. O sets `Phase: done` and names the next stage — planning
(`kite-planner-with-taxonomy`), one slice at a time — without invoking it. Planning,
research, and implementation are out of scope for this orchestrator.

## Why each guard exists (the failures they prevent)

- **Fresh DW per slice** → prevents the designer optimizing for slices not in
  front of it (loss of thin-slice focus).
- **O owns every code-aware spawn + the firewall** → the design/critic workers
  stay code-blind by construction, not by promise; code never anchors intent.
- **Every fork relayed, none answered by O** → preserves the autonomy bar:
  intent is decided by the user, never fabricated by an agent.
- **Per-slice reality check AND whole-set backstop** → the per-slice catch is
  cheap and early; the whole-set catch sees cross-slice collateral the per-slice
  one structurally can't.
- **Verifier ≠ fixer** → breaks the self-confirmation trap.
- **Blast-impact readout is mandatory** → no out-of-scope effect leaves the design
  phase as a silent surprise.
