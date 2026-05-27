# Slice Blueprint Template

Each slice file is a **blueprint in its own right**, written in the exact same section
structure as the source blueprint it came from. A reader who knows the blueprint format
should not be able to tell, from the structure alone, that a slice file is a slice rather
than an original blueprint — the only differences are narrower scope and a couple of
slice-specific lines (`Builds on:`, deferred-to-slice notes).

Reproduce the sections below, in this order. Guidance is in _italics_ — replace it with real
content; never copy the italic guidance into the file.

---

## Slice file: `slice-N-<short>.md`

**Title line:** `# Behavior Blueprint: <Feature Name> — Slice N: <Slice Title>`

**Status line:** `**Status:** Draft · **Date:** <YYYY-MM-DD> · **Slice:** N of M`

### 1. Problem & Intent

_The part of the overall problem **this slice** resolves, in two or three sentences — not the
whole feature's problem restated. State this slice's own primary success outcome in one line:
what can the user do or see once this slice ships that they could not before._

### 2. Actors

_Only the actors **this slice** involves. If the slice has no domain input flow, the actor
who enters a domain may not belong here yet. One line each._

### 3. Glossary

_Only the terms **this slice** actually uses. Terms whose behavior is deferred move to the
slice that introduces them — **never silently dropped.** If a term enumerates fields (a table
by its columns, a scoreboard by its metrics), keep only the fields this slice renders, and
make sure every other field lands in a later slice; a field that lands in no slice is a gap to
surface, not a column to delete. Two-column table (Term | Definition). "No specialized terms"
if none._

### 4. Preconditions & Assumptions

_Two parts, plus one slice-specific line._

- **Builds on:** _the earlier slices this slice assumes are already built and shipped (e.g.
  "Slice 1 — live keyword fetch + cache for a custom domain"). Write "Nothing — this is the
  walking skeleton" for slice 1. This line is what makes the stack legible._
- **Preconditions:** _what must be true before any scenario in this slice begins, including
  the capabilities the `Builds on:` slices provide._
- **Standing assumptions:** _global assumptions for this slice (write "None" if there are
  none). Scenario-specific assumptions go in section 8._

### 5. Scope

_Two short lists. Being explicit here is what stops a reviewer from expecting more or less
than the slice delivers._

- **In scope:** _the behaviors **this slice** covers._
- **Out of scope (deferred to later slices):** _name the slice each deferred behavior is
  going to (e.g. "Manual refresh & cooldown → Slice 3"). Plus carry forward anything the
  **source blueprint** itself declared out of scope for the whole feature._

### 6. Happy-Path Scenarios

_The happy-path Gherkin **assigned to this slice**, lifted from the source blueprint. Adapt
only as far as the narrower scope requires — e.g. a `Background` precondition that now names a
capability an earlier slice built. Apply the realizability check: a step that references a
control or state this slice does not build yet (a "refresh" action, a "previous snapshot")
must be rewritten to this slice's reality or the scenario moved to the slice that builds it —
never pasted through unchanged. Keep the `@happy-path` tag **and the scenario's stable ID
tag** (`@HP-1`) — this file is the authoritative home of the scenario, referenced downstream
by that ID. Use the same fenced `gherkin` block format as the source._

### 7. Deviation Scenarios

_The deviation Gherkin assigned to this slice, grouped by category with the category headings
(7.1, 7.2, …). Include only the categories that produced scenarios **for this slice**;
categories with no scenarios in this slice are recorded in section 9, not here. Keep the
`@deviation`, category, `@assumption`, **and stable ID** (`@DEV-7.3a`) tags exactly as in the
source — the ID is how the plan and briefs reference this scenario without re-copying it._

### 8. Flagged Assumptions

_A table of any assumption specific to this slice — including any new assumption you made
about **where a layer boundary falls** when slicing. Columns: # · Scenario · Assumed behavior
· Needs confirmation. "None" if there are none._

### 9. Coverage Checklist

_The same 14-row table as the blueprint format, but reflecting **only this slice's**
deviations. A category this slice does not touch is marked N/A with a real reason — and
"deferred to Slice X" is a perfectly good reason. A blank cell means the partition was not
finished._

| #   | Deviation category                      | Covered | Scenarios / Reason if N/A |
| --- | --------------------------------------- | ------- | ------------------------- |
| 1   | Incomplete or invalid input             |         |                           |
| 2   | Duplicate submission / retry            |         |                           |
| 3   | Rate limits, quotas, throttling         |         |                           |
| 4   | Connectivity loss & interruption        |         |                           |
| 5   | Abandonment & resumption                |         |                           |
| 6   | Out-of-order actions & navigation       |         |                           |
| 7   | Auth & permission changes mid-flow      |         |                           |
| 8   | Concurrency & stale data                |         |                           |
| 9   | Precondition satisfied / state conflict |         |                           |
| 10  | Empty, boundary & scale extremes        |         |                           |
| 11  | Environment & device capability         |         |                           |
| 12  | External dependency failure             |         |                           |
| 13  | Time, expiry & scheduling               |         |                           |
| 14  | Adversarial & abuse input               |         |                           |

---

## Index file: `SLICES.md`

The index lets a reader see the whole stack at a glance and trust that nothing was lost.

**Title line:** `# Slice Plan: <Feature Name>`

**Status line:** `**Source blueprint:** <relative path> · **Slices:** M · **Date:** <YYYY-MM-DD>`

### Stacked slice order

_A table, one row per slice, in build order:_

| Slice | File | Delivers (one line: "the user can/sees ___") | Builds on |
| ----- | ---- | -------------------------------------------- | --------- |
| 1     | `slice-1-<short>.md` | _…_ | — |
| 2     | `slice-2-<short>.md` | _…_ | Slice 1 |
| …     | …    | …                                            | …         |

### Coverage ledger

_The proof that every scenario from the source blueprint landed in exactly one slice. A
table mapping each source scenario ID (from the Phase 1 inventory) to the slice that owns it.
If any scenario could not be placed, say so explicitly here rather than omitting the row —
an unplaced scenario is a finding the user needs to see._

| Source scenario | Tag(s) | Owned by slice |
| --------------- | ------ | -------------- |
| HP-1 — _short label_ | `@happy-path` | 1 |
| DEV-7.3a — _short label_ | `@deviation @rate-limit` | 3 |
| …               | …      | …              |

### Carried-content ledger

_The proof that the blueprint's non-scenario commitments survived the cut too (the Phase 1
commitments inventory). One row per glossary term, enumerated field (table column / scoreboard
metric), confirmed decision, and standing assumption — each mapped to the slice that carries
it, or marked "deferred → Slice N". An item that lands nowhere is a finding, surfaced in Notes,
not an omitted row. This is the ledger that catches a dropped table column or a lost
"no confirmation dialog" decision — things the scenario ledger above will never show._

| Commitment | Kind | Owned by / deferred to slice |
| ---------- | ---- | ---------------------------- |
| _year-over-year trend_ | keyword-table column | 1 |
| _no confirmation dialog on manual refresh_ | confirmed decision | 4 |
| …          | …    | …                            |

### Notes

_Anything the user should know: scenarios you could not cleanly place, assumptions about
layer boundaries, or places the source blueprint was ambiguous about where a behavior
belongs._

---

## Producing the files

- Each `slice-N-<short>.md` is a complete, standalone mini-blueprint that stands on its own —
  complete enough to be worked from with no other context except (optionally) the system
  design document.
- Keep the Gherkin clean and tagged exactly as in the source blueprint, so it can still be
  lifted into a `.feature` file later if test automation is wanted.
- Name slice files `slice-<N>-<short-kebab>.md` where `<short>` is a 1–3 word handle for what
  the slice delivers (e.g. `slice-1-custom-domain-live-fetch.md`).
- Put everything in `<feature-name>-slices/` next to the source blueprint, where
  `<feature-name>` matches the source blueprint's kebab-case name (drop the `-blueprint`
  suffix: `growth-keyword-rankings-blueprint.md` → `growth-keyword-rankings-slices/`).
