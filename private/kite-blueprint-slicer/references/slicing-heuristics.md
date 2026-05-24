# Slicing Heuristics

This is the judgment layer behind the workflow in `SKILL.md`. Read it when you are choosing
where to cut a blueprint. It explains how to find a good first slice, how to order the rest,
how to place deviations, and how to recognize a bad cut before it costs you N rewritten files.

## What "vertical" actually means

A vertical slice reaches through every layer it needs to deliver one observable behavior:

```
   Slice 1        Slice 2        Slice 3
  ┌───────┐      ┌───────┐      ┌───────┐
  │  UI   │      │  UI   │      │  UI   │      ← the user sees/does something
  │  API  │      │  API  │      │  API  │
  │backend│      │backend│      │backend│
  │  DB   │      │  DB   │      │  DB   │
  └───────┘      └───────┘      └───────┘
   thin, but each one works end to end
```

A horizontal slice is a single row across the whole feature — "all the DB", then "all the
API", then "all the UI". Each row is invisible on its own and integrates only at the end.
That is the anti-pattern this skill exists to prevent.

The litmus test is a single sentence: **"After this slice, the user can ___"** or **"After
this slice, the user sees ___."** If you can finish it with something real and observable, the
slice is vertical. If the only honest completion is "…nothing yet, but the schema is ready,"
it is horizontal — merge it into the slice that *uses* the schema.

## Finding the walking skeleton (slice 1)

Slice 1 is the thinnest path that still touches the whole stack. Its purpose is not to
deliver much — it is to **prove the architecture integrates** and give you the first thing you
could actually ship. De-risking beats breadth here.

The crucial distinction is **breadth versus depth**, and it runs through the whole skill:

- **Thin on breadth.** Slice 1 owns *one* path and *few* behaviors. Defer alternative paths,
  defer the rest of the feature, defer cross-cutting polish that isn't load-bearing yet.
- **Full on depth.** For the one behavior it owns, slice 1 ships the realistic failure modes
  too — because a chunk is only worth shipping if it is robust. Stripping a behavior's error
  handling does not make a smaller slice; it makes a broken one.

To find it:

1. **Pick the single most central happy path** — usually the one in the blueprint's primary
   success outcome. Ignore the alternatives for now.
2. **Collapse every choice to one branch.** If the feature handles both "custom domain" and
   "user-entered domain," pick the one that needs the *least* new UI to still exercise the
   backend and the external integration. Defer the other.
3. **Defer other *behaviors*, not this behavior's robustness.** Cut away the rest of the
   feature — other paths, other capabilities, polish that isn't load-bearing. But keep the
   risk scenarios that protect the one path you kept: the external call failing, the input
   being bad, the connection dropping. Those ride with slice 1.
4. **Keep exactly enough to be real *and* shippable.** The skeleton must go DB → backend →
   API → UI, show the user a true result, and not fall apart the first time the provider
   hiccups. A skeleton that stops at the API with no screen is horizontal; a skeleton that
   renders the happy path but white-screens on a provider error is not shippable.

**Worked example (growth keyword rankings blueprint).** The thinnest end-to-end path is:
*an app that already has a custom domain — so no domain-input UI is needed — opens the Growth
tab; the backend resolves the domain, calls DataForSEO, stores a snapshot; the UI renders the
scoreboard and table.* This single slice touches the new snapshot table, the provider
integration, the API, and the Growth tab UI. Because it must be *shippable*, it also carries
the risk scenarios for that one path — the provider being down, the provider rate-limiting
us, a malformed/empty response, the connection dropping mid-fetch, and the domain ranking for
zero keywords — since all of those are failure modes of the fetch-and-render behavior it
introduces. It deliberately omits *other behaviors*: the no-custom-domain input flow,
freshness/caching, manual refresh, and the deviations that belong to those. On day one you can
open the tab, see real keywords, and trust it won't shatter on the first bad response — and
you have de-risked the riskiest part, the paid external call.

## Ordering the rest of the stack

After the skeleton, each slice adds one coherent capability. Order by three forces, in
roughly this priority:

1. **Dependency (hard constraint).** A slice may only use what earlier slices built. This
   alone often fixes most of the order. The stack only grows upward — never plan slice 2 to
   depend on something slice 4 introduces.
2. **Risk (pull forward).** If a capability carries real uncertainty — an external dependency,
   a concurrency guarantee, a performance unknown — schedule it early so you learn the hard
   truth while there is still time and budget to respond. Late risk is expensive risk.
3. **Value (each slice demoable).** Prefer an order where every slice is something you could
   show a stakeholder and, ideally, ship. If two orderings are equally valid on dependency and
   risk, pick the one that delivers user-visible value soonest.

A reasonable continuation of the growth example, after the skeleton. Notice there is **no
"resilience" slice** — each slice carries the failure modes of the behavior it introduces:

- **Slice 2 — user-entered growth domain.** The no-custom-domain path: empty state, domain
  input, validation, normalization, save, reset — *and* the input's own risk scenarios:
  invalid-domain rejection, protocol/path/www normalization, double-submit, re-submitting the
  saved domain, and script-payload sanitization. They ride here because they all guard the
  input behavior this slice introduces. Reuses slice 1's fetch+render.
- **Slice 3 — freshness & caching.** The 7-day TTL: serve fresh instantly, auto-refetch on
  stale/missing — *and* its boundary and concurrency cases: the exact-7-day boundary, the
  data-age display, and the background-refresh-vs-on-visit overlap, since those are failure
  modes of the caching behavior introduced here.
- **Slice 4 — manual refresh.** On-demand refresh and movement deltas — *and* the 60-second
  cooldown, the in-flight de-dup, and the two-tab refresh race, because those only exist once
  manual refresh exists and they protect it.
- **Slice 5 — reach & gating.** The internal-user feature flag (with its direct-URL
  protection), deep-link state resolution, session-expiry recovery, large-result
  pagination/cap, mobile layout, and keyboard/screen-reader support — the cross-cutting
  concerns that apply once the surface is essentially complete.

This is illustrative, not prescriptive. A different but equally vertical cut is fine — what
matters is that each slice is vertical, robust for what it owns, stacks on the ones before it,
and the union covers every scenario. (Cross-cutting quality like mobile and a11y is a judgment
call: ideally each slice's UI is already accessible for the surface it adds, but consolidating
the reach pass into one slice is a defensible trade as long as no earlier slice shipped a
genuinely broken-on-mobile experience.)

## Placing deviations — by behavior ownership

Deviations (the blueprint's section 7 scenarios) are where slicing goes wrong most often. The
tempting mistake is to **herd all the error handling into one late "hardening" slice.** Resist
it. That recreates horizontal slicing in the time dimension — a slice that adds no new
behavior, only failure handling bolted onto everything at once — and it means every happy path
ships fragile for several iterations. Shipping in chunks only pays off when each chunk is
robust; a chunk whose error handling lives three slices away is not really shippable.

The rule is therefore simple:

> **A deviation rides with the slice that introduces the behavior it protects.**

A slice ships its happy path *and* the risk scenarios for that path, together, as one
robust increment. You do not weigh whether a deviation is "rare enough to defer" — you ask
which behavior it guards, and it goes wherever that behavior goes.

This makes placement almost mechanical, because deviations attach to behaviors and behaviors
are already distributed across slices:

- *"The provider returns an error during the fetch"* → guards the fetch → **slice 1** (the
  fetch is introduced there).
- *"The owner submits an invalid domain"* → guards the domain input → the slice that adds the
  input.
- *"Two manual refreshes race"* → guards manual refresh → the slice that adds manual refresh.
- *"The cache is exactly 7 days old"* → guards caching → the slice that adds caching.
- *"A script payload in the domain field"* → guards the input field → the slice that adds it.

A deviation lands in a *later* slice only when the behavior it concerns is itself introduced
later — not as a way to keep an earlier slice thin. (Thinness is bought by deferring other
*behaviors*, never by deferring a behavior's own robustness.) If a deviation seems to belong
to no slice's behavior, that is a finding to surface in `SLICES.md`, not a scenario to herd
into a catch-all.

The test to apply to a finished cut: **pick any slice and imagine shipping only it. Would a
reasonable user hit a broken or unsafe state doing the thing that slice introduces?** If yes,
a deviation that belongs to that slice got deferred — pull it back.

## How to recognize a bad cut

Re-cut if you see any of these:

- **A layer-named slice.** "Database slice," "API slice," "UI slice," "models & migrations
  slice." These are horizontal by definition.
- **A slice that fails the "after this slice the user can ___" test.** No observable outcome
  means no vertical slice.
- **A "setup," "scaffolding," or "refactor" slice with no behavior change.** Fold the setup
  into the first slice that needs it.
- **A "hardening," "resilience," or "error handling" slice for behaviors shipped earlier.**
  Horizontal in the time dimension. Its scenarios belong back with the slices whose behavior
  they guard, so each of those ships robust. (A later slice handling failures of a behavior
  *that same slice introduces* is fine — that is just depth.)
- **A slice that ships a happy path while its failure handling lives in a later slice.** Not
  shippable. Pull the risk scenarios back to the slice that owns the behavior.
- **A slice that cannot be demoed without another unshipped slice.** They are really one
  slice — merge them.
- **Slices so fine-grained that none is independently shippable.** Over-slicing produces
  ceremony without value. Each slice should be a coherent increment, not a single function.
- **A deviation with no home.** Every section-7 scenario must land somewhere. If one truly
  fits nowhere, that is a finding to surface in `SLICES.md`, not a scenario to drop.

## Sizing

Aim for each slice to be buildable and verifiable in one focused pass — small enough to hold
in your head, large enough to deliver a coherent observable outcome. If a slice feels like it
needs its own multi-week project, it is probably hiding two or three slices. If a slice
delivers nothing a person would notice, it is probably half of one.
