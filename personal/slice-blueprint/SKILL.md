---
name: slice-blueprint
description: >-
  Cuts one large behavior blueprint into a stacked sequence of smaller
  blueprints, each a thin but FULL-STACK, end-to-end shippable vertical slice
  — DB, backend, API, and UI together, never one layer in isolation. Each
  slice builds on the ones before it (a walking skeleton first, then
  capability layered on top) and is written in the same section format as the
  source blueprint, with its Gherkin and every other section narrowed to that
  slice's scope. Use immediately after a behavior blueprint exists and the
  feature is too big to ship in one go. Reach for it when the user says "slice
  this blueprint", "break this feature into slices", "split this into
  deliverable increments", "how should we phase this build", or "cut this into
  vertical slices" — even if they never say "slice".
---

# Slice Blueprint

You take one large behavior blueprint and cut it into an ordered, **stacked**
sequence of smaller blueprints. Each smaller blueprint describes a single
**vertical slice** of the feature: a thin but complete, end-to-end, shippable
increment. The output files reuse the _exact_ section format of the source
blueprint — they are blueprints themselves, just narrower.

## Why this skill exists

A finished blueprint is complete but monolithic. It describes the whole feature
— every happy path, every deviation, every edge case — as one indivisible thing.
Trying to build all of it at once is how teams end up with three weeks of work
that demos nothing until the very end, integrates late, and discovers its
hardest risks last.

The fix is to slice. But _how_ you slice decides everything, and the tempting
cut is the wrong one.

**The wrong cut is horizontal.** "First we build all the database tables, then
all the API endpoints, then all the UI." Each horizontal layer is individually
invisible: a schema with no reader proves nothing, an endpoint with no caller
proves nothing, a UI with no backend is a mock. You integrate at the end, you
demo at the end, and every risk you were worried about is still unproven until
the end. Horizontal slicing front-loads effort and back-loads learning — exactly
backwards.

**The right cut is vertical.** Each slice reaches through _every_ layer it needs
— data, backend logic, API, UI — to deliver one observable, end-to-end behavior.
The first slice is the thinnest path that still touches the whole stack: a
_walking skeleton_ that proves the architecture holds together. Every later
slice stacks one coherent capability on top of the skeleton, reusing what
earlier slices already built. At the end of _each_ slice you have something a
person can actually use and you can actually demo — and you learned your
integration risks on slice one, not slice five.

So the one rule that defines this skill: **slices are vertical, never
horizontal.** A slice that delivers only a schema, only routes, only UI, or only
"plumbing" with no observable change is forbidden. If you cannot finish the
sentence _"after this slice, the user can \_\_\_"_ or _"after this slice, the
user sees \_\_\_"_, you have cut horizontally — re-cut.

## Inputs

- **The source blueprint** — a behavior blueprint in the standard format
  (problem & intent, actors, glossary, preconditions, scope, happy-path
  scenarios, deviation scenarios, flagged assumptions, coverage checklist). This
  is your only required input and your source of truth. Read it fully before
  cutting anything.
- **Optional: a system design document.** If one exists, it tells you which
  layers each behavior touches and where the architectural risk lives — useful
  for ordering, but the blueprint remains the authority on behavior.

Treat the blueprint as fixed. You are re-partitioning its scenarios, not
rewriting them and not inventing new behavior. If the blueprint is genuinely
ambiguous about something that changes where a scenario belongs, note it rather
than silently guessing.

## What you produce

A `<feature-name>-slices/` directory, created next to the source blueprint,
containing:

- **`slice-1-<short>.md` … `slice-N-<short>.md`** — one mini-blueprint per
  slice, each in the identical blueprint format (see
  `references/slice-blueprint-template.md`), with every section narrowed to that
  slice.
- **`SLICES.md`** — an index: the slices in stacked order, what each delivers,
  what it builds on, and a coverage ledger proving every scenario from the
  source blueprint landed in exactly one slice. See the template file for its
  shape.

Each slice file is a self-contained mini-blueprint that stands on its own. That
is the whole point of keeping the format identical.

## Workflow

Eight phases. Do them in order. The early phases are analysis you do in your
head or notes; do not start writing slice files until the user has confirmed the
cut (Phase 5), and never before Phase 6. Phase 7 is an automated self-check of
what you wrote, before you hand anything to the user.

### Phase 1 — Read the blueprint and inventory everything it commits to

Read the source blueprint end to end. Then build two inventories.

**The scenario inventory** — a numbered list of every scenario in the blueprint:
every `@happy-path`, every `@deviation`, every row of every `Scenario Outline`.
Use the **stable ID tag each scenario already carries** from the blueprint (`@HP-1`,
`@DEV-7.3a` — see `gherkin-style.md`); that ID is the join key every later stage uses to
reference the scenario instead of re-copying its Gherkin, so carry it through unchanged.
(If you are slicing an older blueprint whose scenarios have no ID tags, mint them now in
document order — `HP-1`, `DEV-7.3a` — and they become the canonical IDs.)

This inventory is your coverage ledger. The cardinal sin of slicing is losing a
scenario — an edge case that quietly falls between two slices becomes the
production incident the blueprint was written to prevent. Every scenario in this
inventory must end up assigned to exactly one slice by the end. Nothing silently
dropped.

**The commitments inventory** — the blueprint's other load-bearing assertions,
the ones a scenario count never sees. A scenario is a promise you _test_; these
are promises you _build to_, and losing one is the same class of error — it just
hides better. Inventory at least:

- **Every glossary term, and every field enumerated inside one.** A "Keyword
  table" defined as a list of columns, a "Scoreboard" defined as a list of
  metrics — each column and each metric is its own commitment, not a detail you
  may quietly trim when narrowing the term.
- **Every confirmed decision** in the Flagged Assumptions / decisions section
  ("manual refresh fires immediately, no confirmation dialog").
- **Every standing assumption and every in-scope bullet.**

Each item here, like each scenario, must end up either present in a slice or
explicitly deferred to a **named** slice by the end. "Dropped because it felt
like a detail" is how a confirmed decision or a table column silently vanishes
from the build — the failure mode this inventory exists to prevent.

### Phase 2 — Find the walking skeleton (slice 1)

Find the single thinnest happy path that still exercises every architectural
layer the feature needs end to end. That is slice 1.

"Thinnest" is about **breadth, not depth** — and this distinction governs the
whole skill. Cut slice 1 narrow on breadth: one entry condition, one path, defer
every _other_ behavior (alternative paths, the rest of the feature, the polish).
But go _full depth_ on the one behavior it does own: a slice is only worth
shipping as a chunk if it is genuinely shippable, which means it handles the
realistic failure modes of the behavior it introduces. So slice 1 includes the
risk scenarios that protect its one happy path — the provider being down, the
fetch returning nothing, the connection dropping mid-fetch — because shipping
that path without them is not a smaller deliverable, it is a broken one.

Concretely: slice 1 picks one path and strips away other _behaviors_, not the
error handling _of_ that path. Its job is to prove the integration works end to
end _and_ to be the first thing you could actually put in front of users.

For guidance on what makes a good skeleton and how to recognize a bad one, read
`references/slicing-heuristics.md`.

### Phase 3 — Stack the remaining slices

Lay out the rest of the feature as slices that each add **one coherent
capability** on top of what earlier slices already built. Order them by:

1. **Dependency** — a slice may only rely on capabilities that earlier slices
   created, _and_ on preconditions a real user can already reach — either through
   an earlier slice of this feature or through pre-existing product capability
   they already have. The stack only grows upward. A slice may **not** assume a
   precondition that only a _later_ slice of this feature produces, or that
   engineering has to hand-seed: that is the most common backwards cut (a consumer
   shipped before its producer), and the Reachability check in Phase 4 exists to
   catch it.
2. **Risk** — pull risky integrations (an external paid provider, a tricky
   concurrency guarantee) earlier rather than later, so you learn the hard parts
   while there is still room to react.
3. **Value** — among orders that satisfy dependency and risk, prefer the one that
   delivers user-visible value soonest. (That each slice be independently demoable
   is not a preference to weigh here — it is a hard bar enforced by the
   Reachability check in Phase 4; this force only breaks ties between cuts that
   already clear it.)

Then assign **every** scenario from the Phase 1 inventory to exactly one slice —
happy paths _and_ deviations. The rule for deviations is simple and strict:

**A deviation rides with the slice that introduces the behavior it protects.** A
slice ships its happy path together with the risk scenarios for that path —
provider errors, invalid input, the connection dropping, the boundary cases —
because a chunk you ship is only meaningful if it is robust. A slice that
delivers a happy path but defers that path's failure handling has not shipped a
smaller thing; it has shipped a fragile thing, and shipping in chunks loses its
point.

This means deviations distribute _naturally_ across the stack by behavior
ownership: a manual-refresh race belongs to the slice that introduces manual
refresh; a stale-cache boundary belongs to the slice that introduces caching; a
script payload in the domain input belongs to the slice that introduces the
input field. A deviation lands in a later slice only when the _behavior it
concerns_ is itself introduced later — never to thin out an earlier slice by
stripping its risk handling.

So **do not create a "hardening" or "resilience" slice** that collects the error
handling for behaviors shipped in earlier slices. That is a horizontal slice in
the time dimension: it adds no new behavior, and it means every earlier slice
shipped fragile for several iterations. If you find yourself reaching for one,
the deviations in it almost always belong back with the slices whose behavior
they guard.

`references/slicing-heuristics.md` has the detailed ordering criteria and worked
examples of placing deviations by behavior ownership.

### Phase 4 — Validate the cut before writing anything

Run these checks across your planned slices. If any fails, re-cut — it is
far cheaper to fix the partition now than after you have written N files.

- **Vertical check.** For every slice, can you complete _"after this slice the
  user can/sees \_\_\_"_? Does it touch the layers that sentence requires (not a
  single isolated layer)? A slice failing this is horizontal — merge it into a
  neighbor or re-cut.
- **Reachability check.** From a clean state, can a _real end user_ reach this
  slice's happy-path precondition using only this slice and earlier ones (or
  product capability they already have) — with the feature flag **on** and
  **nothing hand-seeded**? If the only honest answer is "after a later slice
  ships," "once engineering seeds a row," or "with the flag off until slice N,"
  the slice is not independently demoable and the cut is wrong. Pull the producer
  of that precondition into this slice — the cheapest end-to-end mechanism is
  fine, e.g. a synchronous build a later slice replaces with an async one — or
  merge. Naming the gap as a boundary assumption does **not** discharge it: a
  precondition the _feature itself_ is responsible for creating is not a boundary
  state, it is a missing earlier slice (the Boundary-state check below draws the
  line). The litmus: if you cannot honestly write "a user does X and sees Y, from
  a clean state, flag on, nothing seeded," this slice is mis-cut.
- **Robustness / shippability check.** For each slice, does it handle the
  realistic failure modes of the behavior it introduces — or did its risk
  scenarios get deferred elsewhere? A slice that ships a happy path while its
  error handling lives in a later slice is not shippable; pull those deviations
  back in. And if you have a slice whose only content is hardening behaviors
  shipped earlier, dissolve it and return its scenarios to their owning slices.
- **Stacking check.** Does each slice depend only on slices before it? If slice
  2 secretly needs something only slice 4 builds, the order is wrong.
- **Coverage check.** Is every item from **both** Phase 1 inventories assigned
  to exactly one slice — every scenario _and_ every commitment (glossary term,
  enumerated field, confirmed decision, standing assumption)? None dropped, none
  duplicated. If something genuinely belongs nowhere, that is a finding to
  surface, not a thing to bury.
- **Realizability check.** For every scenario placed in a slice, walk its steps
  and confirm each control, affordance, capability, or state the steps mention
  is built by _this_ slice or an earlier one. A scenario can pass the coverage
  check (it is "assigned somewhere") yet quietly reference machinery the slice
  does not build — a "refresh" button that arrives two slices later, a "previous
  snapshot" that does not exist yet, a background job nothing in scope runs.
  That is a silent defect a ledger never catches. When you find one, you have
  two honest moves: move the scenario to the slice that builds the thing, or
  adapt the scenario's wording to this slice's reality and flag the adaptation.
  Never leave a placed scenario pointing at something unbuilt.
- **Internal-consistency check.** A slice's happy-path and deviation scenarios
  must describe one coherent world. When a slice makes a layer-boundary decision
  that removes or changes a behavior the monolith had — "this slice always
  fetches; the fresh-cache short-circuit is deferred" — re-read every scenario
  in that slice and confirm none still assumes the removed behavior. A happy
  path that says "a loading state is shown on every visit" sitting next to a
  deviation that says "the previously cached data stays on screen" is two
  different worlds in one slice; reconcile them.
- **Boundary-state check.** Stacking creates transient or degraded states the
  whole-feature blueprint never had to consider, precisely because earlier
  slices have not built later capabilities yet: the first slice serves stale
  data because caching is not in yet; the first manual refresh has no prior
  snapshot to diff for movement deltas. These are real states a user hits when a
  slice ships alone. You do not silently invent feature behavior for them — but
  you do **surface each as a flagged boundary assumption** in the slice, and
  raise it to the user when it needs a defined product behavior. (This is not
  authoring: the feature's behavior is conserved; the boundary state exists only
  because of the ordering _you_ introduced, so naming it is part of slicing
  honestly.) **But sort boundary states into two kinds.** A _benign_ one leaves
  the slice fully usable — stale data until caching ships, no movement-delta on
  the first snapshot; flag it and move on. A _fatal_ one makes the slice
  impossible for a user to exercise at all — its happy path needs a precondition
  only a later slice or hand-seeding can produce, or it needs the feature flag
  held off until a later slice. A fatal boundary state is a failed Reachability
  check, not a flag-and-move-on: re-cut. "The flag stays off until slice N" never
  excuses a non-demoable slice.
- **Independence check.** Could each slice be merged and shipped on its own as a
  coherent, robust product increment? If a slice only makes sense bundled with
  another, they are one slice. The quick test: can you write its one-line demo —
  "a user does X and sees Y, from a clean state, flag on, nothing seeded"? If you
  can't write that line honestly, the slice failed the Reachability check above.

### Phase 5 — Confirm the cut with the user before writing the files

Slicing is a judgment call, and the user is the authority on whether the
increments are _meaningful_. The aim is delivery a reviewer can absorb quickly —
not so coarse that a slice is a system-bloat hangover, not so fine that the
stack is ceremony. There is no right number of slices; there is only whether
_these_ slices are the right cut for _this_ feature.

So before writing the detailed slice files, present the proposed cut and ask the
user to confirm it. Show, compactly:

- the ordered slice list, each with its one-line _"after this slice the user
  can/sees \_\_\_"_,
- what each slice owns (its happy path plus the risk scenarios riding with it),
- and the `Builds on` dependency for each.

Then ask plainly whether the slices look right, or whether any should be merged,
split, or reordered. Adjust until they confirm. Confirming the boundaries now is
far cheaper than rewriting a directory of mini-blueprints later — and it is the
moment the user's sense of "meaningful delivery" gets to shape the cut.

(When running non-interactively with no user to answer, present the proposed cut
in your summary as the thing you would have asked them to confirm, then
proceed.)

### Phase 6 — Write the slice files and the index

Read `references/slice-blueprint-template.md`. For each slice, write
`<feature-name>-slices/slice-N-<short>.md` as a full mini-blueprint in the
identical format, with every section scoped to the slice:

- **Problem & intent** — the part of the overall problem this slice resolves,
  and its own one-line success outcome. Not the whole feature's problem
  restated.
- **Actors / glossary** — only the actors and terms this slice actually
  involves. When you narrow the glossary, **defer terms to the slice that
  introduces them — never silently drop one.** And if a term enumerates fields
  (a table defined by its columns, a scoreboard defined by its metrics), each
  field follows the same rule: a column belongs in the slice that renders it,
  and if none does, that is a gap to surface, not a column to quietly delete.
  The commitments inventory from Phase 1 is your checklist here.
- **Preconditions & assumptions** — include a `Builds on:` line naming the
  earlier slices this one assumes are already shipped. That is what makes the
  stack legible.
- **Scope** — _In scope:_ what this slice delivers. _Out of scope:_ the things
  deferred to **named** later slices, plus anything the source blueprint itself
  put out of scope. Being explicit here is what stops a reviewer from expecting
  more (or less) than the slice gives.
- **Happy-path & deviation scenarios** — the Gherkin assigned to this slice,
  lifted from the source blueprint and adapted only as far as the narrower scope
  requires. Keep the tags, **including each scenario's stable ID tag** (`@HP-1`,
  `@DEV-7.3a`): the slice file is now the authoritative home of that scenario's
  Gherkin, and the plan and implementation briefs reference it by ID rather than
  re-copying it. When you lift a scenario, apply the realizability
  check from Phase 4: if a step names a control or state this slice does not
  build (the source said "offers a way to refresh" but manual refresh is a later
  slice), either move the scenario or rewrite that step to what this slice
  actually does — do not paste it through unchanged.
- **Flagged assumptions** — any assumption specific to this slice, including
  every layer-boundary decision and every boundary state the stacking creates
  (from the Phase 4 boundary-state check): "this slice always fetches, no cache
  yet"; "on the first refresh there is no prior snapshot, so movement deltas are
  absent until a second one exists." Naming these is how a reviewer knows the
  degraded state is intended, not an oversight.
- **Coverage checklist** — the same 14-category table, reflecting _this slice's_
  deviations. Categories this slice does not touch are marked N/A with a real
  reason ("deferred to slice 4 — resilience" is a real reason; a blank cell is
  not).

Then write `SLICES.md` — the index and coverage ledger. Its job is to let
someone see the whole stack at a glance and trust that nothing was lost. The
template file specifies its shape.

### Phase 7 — Self-check the cut with a conformance review (before handoff)

You just wrote these slices, so you are the worst-placed agent to judge whether
they faithfully conserve the source blueprint — you will trust your own ledger
and rationalize your own adaptations. So before handing anything to the user,
run an independent conformance review and act on what it finds. This is not
optional polish; it is the step that catches the silent guarantee you softened,
the scenario your ledger double-claims, and the "arrives in a later slice"
promise that has no owner.

Run it as a delegated loop — **the review and the verification must each be a
fresh sub-agent, never your own context** (the whole point is independence from
the agent that did the slicing):

1. **Review (sub-agent).** Spawn a sub-agent to apply the
   `slice-conformance-review` skill against the source blueprint and the
   `<feature>-slices/` directory you just wrote, returning candidate findings
   only (each with a proposed verdict and meaningfulness). It must not see your
   slicing rationale — only the files.
2. **Evaluate the feedback (you).** Critically read the returned findings. Keep
   the ones that are genuinely _real and meaningful_ — a lost guarantee, a
   duplicated scenario the ledger lies about, an orphaned forward-promise, a
   dropped commitment. Discard false positives, and **leave defensible judgment
   calls alone** (a boundary state you already flagged, a mechanism you reframed
   on purpose). Do not fix a gap just because it was reported.
3. **Apply the meaningful fixes (you).** Make the surgical edits to the slice
   files and `SLICES.md`. Minimal changes that restore the lost commitment — not
   a re-slice.
4. **Verify (a different sub-agent).** Spawn a _separate_ sub-agent — not the
   one that reviewed, and not you who applied the fixes — to confirm each fix
   actually landed in the files. A fixer confirming its own fix is the bias this
   step exists to remove.

If `slice-conformance-review` is not available in this environment, do the
equivalent yourself as a deliberately fresh, adversarial pass — but prefer the
delegated sub-agent loop, because the independence is what makes the check worth
anything. Carry what the self-check found and fixed into the Phase 8 summary so
the user sees it.

### Phase 8 — Summarize and ask the user to review

Give a short summary: how many slices, a one-line "delivers" for each, and
explicit confirmation that every source scenario **and every commitment** (the
Phase 1 commitments inventory — glossary fields, confirmed decisions, standing
assumptions) is covered (cite the ledgers). Flag any scenario or commitment you
could not cleanly place, any layer-boundary assumption you had to make, and any
boundary state the stacking introduced that needs a product decision. Point the
user at `SLICES.md` and the slice files, and ask them to review the cut —
whether the slices look right, whether any should be merged, split, or
reordered.

## Principles to hold throughout

- **Vertical or it doesn't ship.** This is the whole skill. Re-read the "after
  this slice the user can \_\_\_" test whenever a slice feels off — a slice that
  fails it is the failure mode this skill exists to prevent.
- **The skeleton earns the right to the rest.** Slice 1 being thin is a feature,
  not a weakness. Proving the full stack integrates on a tiny path is worth more
  than building any single layer completely.
- **Thin on breadth, full on depth.** Cut each slice narrow — few behaviors, one
  path — but ship each behavior it owns complete with the risk scenarios that
  protect it. A slice that defers its own failure handling is not a smaller
  deliverable, it is a fragile one, and shipping in chunks only pays off when
  every chunk is genuinely shippable.
- **The user owns "meaningful," you own the rest.** How coarse or fine the cut
  should be is a product judgment about what a reviewer can absorb and what is
  worth shipping. Propose a cut, but confirm it with the user before writing the
  files — do not decide the granularity for them in silence.
- **Conserve everything the blueprint asserts, not just its scenarios.** The
  union of all slices equals the source blueprint, exactly — its scenarios _and_
  its glossary fields, confirmed decisions, and standing assumptions. Any of
  them may move to a different slice than first expected, but none may vanish. A
  scenario count that reconciles can still hide a dropped table column or a lost
  "no confirmation dialog" decision; conserve the commitments too.
- **Don't rewrite behavior, re-partition it — but do name the states stacking
  creates.** You are a slicer, not an author: if a slice's Gherkin says
  something the source blueprint never said about the _feature_, you have
  drifted — pull back. The exception is the transient or degraded states that
  exist _only_ because of the slice ordering you chose (a slice that has no
  cache yet, a first refresh with no prior snapshot). Those are not new feature
  behavior, and leaving them undefined is its own defect — flag them as boundary
  assumptions and raise the ones that need a product call.
- **A placed scenario must be a buildable scenario.** Assigning a scenario to a
  slice is not enough; the slice must actually build everything the scenario's
  steps reference. A scenario that points at a control or state two slices away
  is mis-placed or un-adapted, even though the ledger looks complete.
- **Stack honestly.** `Builds on:` lines and the deferred-to-slice-X notes are
  not bureaucracy; they are what lets each slice stand on its own as a coherent
  increment while still composing into the whole feature.
