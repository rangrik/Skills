# The BLAST-IMPACT Ledger (`BLAST-IMPACT.md`)

The single, durable home for **cross-boundary blast-radius effects** a feature's
slices surface but do **not** fix. It is a per-feature artifact that lives at
`<feature>-slices/BLAST-IMPACT.md`, a sibling of `SLICES.md` and the slice
designs, and it **accumulates across every slice** and every pipeline stage.

This file is the authority for *what the ledger is, what goes in it, and how every
skill in the pipeline reads and writes it.* Other skills point here rather than
restating the schema (single source of truth).

---

## 1. Why it exists

When a slice's design discovers that what it builds will **affect a subsystem the
slice does not own** — a different feature's consumer, a shared store another
subsystem reads, a downstream effect outside this slice's reach — there is a real
effect but **the remedy is not this slice's job.** Three things go wrong if that
note has no home:

- the **owner of the affected subsystem never learns** the effect is coming;
- the **whole-set critic and the final review can't see all such effects at once**;
- the **implementer "helpfully" reaches out of its lane** and fixes the other
  feature — the exact scope creep the C5 bar exists to prevent.

The ledger fixes all three: one place, carried forward, that records the effect,
names who *would* own the remedy, and states plainly that this feature is not
doing it. It is institutional memory (Kite Principle 35) for blast radius.

## 2. What qualifies for an entry — the discriminator

An entry is a **real effect on a subsystem outside the current slice's ownership,
whose remedy lives outside the current slice's scope.** Concretely, both hold:

1. **The effect is real** — an existing subsystem (or a later slice's subsystem)
   will behave differently, see different data, or carry a new hazard because of
   what this slice builds. Not hypothetical, not benign-and-irrelevant.
2. **The remedy is not in this slice or the subsystems it builds** — fixing it
   would mean changing a subsystem this slice does not own (another feature, a
   shared consumer, a later slice). This is the same ownership test as Family C's
   C5 escalation bar in
   `kite-system-design-conformance-review/references/defect-taxonomy.md`.

If the remedy **is** in this slice's owned subsystems, it is **not** a ledger
entry — it's in-scope design (and, if it would regress a consumer, a fork to
resolve with the user now). The ledger is specifically the home for *"real, but
not ours to fix here."*

**What never goes in it:** in-scope TODOs for this slice; benign/equivalent
effects with no downstream consequence (those need no record at all); and — the
firewall — **any code**: no file paths, symbols, table/column names, enum values,
migration ids, snippets, or line numbers. State every effect as **subsystem
behavior** in `SYSTEM_TAXONOMY.md` terms, exactly as the reality-check firewall
requires. A note that can only be written by quoting code is at the wrong
altitude — restate it as behavior or drop it.

## 3. Entry schema

Each entry is one row in the ledger table, with a stable id. Keep every field at
system-design altitude.

| Field | Meaning |
|---|---|
| **ID** | `BI-1`, `BI-2`, … — stable, never reused, never renumbered. |
| **Affected subsystem** | Canonical `SYSTEM_TAXONOMY.md` name of the subsystem outside this slice that is impacted. |
| **Surfaced by** | Which slice + stage + design element surfaced it (e.g. "slice-1 design, P4a C5, Decision D5"). |
| **Effect** | What the affected subsystem will experience — behavior only, firewall-safe, no code. |
| **Regression or benign-but-noted?** | Whether it is a genuine regression (wrong/broken/contractually-different data or behavior) or a non-harmful effect recorded for awareness. |
| **Why out of scope here** | The remedy owner — which feature / later slice / shared subsystem would have to act. |
| **Recommended action + owner** | What should happen and who owns it; or "monitor only — no action needed." |
| **Severity / blocking?** | Does a downstream owner need to act, and is it blocking for them (before/after this feature ships)? |
| **Status** | Exactly **one** of `open` · `routed to <owner>` · `accepted (no fix)` · `picked up by slice-N` · `resolved by slice-N` · `withdrawn (superseded — see History)`. Never combine values (write `picked up by slice-2`, not `open (picked up…)`); the prior state belongs in History. |
| **History** | Append-only log of which slice touched the entry and how (never overwrite — see §4). |

## 4. The cardinal rule — append-only across slices

**Each slice's design appends its own findings and decisions. No slice ever
deletes or rewrites a note authored by another slice.** The ledger is a
cross-slice audit trail; a deletion destroys the very memory it exists to keep.

Permitted:
- **Add** a new entry (assign the next free `BI-id`).
- **Update the `Status` and append to `History`** of an entry *this slice is now
  acting on* — e.g. mark `BI-3` "picked up by slice-2" after the user agreed to
  pull it into slice 2's scope. The original author, effect text, and earlier
  history stay intact; you append, you don't overwrite.
- **Withdraw** an id you assigned *this slice* but no longer need (it was folded
  into a decision or proved not real): set `Status: withdrawn` and append a
  History line with why. Keep the id — never just drop it, because a missing id
  reads as a bug, not a withdrawal.

Forbidden:
- Deleting any entry, editing another slice's `Effect`/`Why`/`Recommended` text,
  renumbering ids, leaving a gap in the id sequence, or "cleaning up" entries you
  didn't author. If you think an entry is wrong, append a `History` line saying so
  and why — don't erase it.

## 5. Reading the ledger without polluting your context — the steward subagent

The design skill is **code-blind and context-economical.** Most entries in a
mature ledger are about *other* slices and subsystems; if the designer read the
whole file, all that unrelated detail would flood its working context and pull
concerns that aren't in front of it into the design — the pollution we avoid.

So **the design skill does not read or write `BLAST-IMPACT.md` itself.** All
ledger I/O is delegated to a **ledger-steward subagent**. Under the
`kite-solution-design` orchestrator (the normal case), the design worker does not
spawn the steward — it **yields a `LEDGER_OP` packet** (mode `FILTER` or `APPEND`)
and the orchestrator runs the steward with the prompt below and returns the
result. The steward's two jobs are the same either way:

- **Filter (read):** given the *current slice* (its behavior, scope, and §3
  subsystem map) and the ledger, return **only the entries related to — or
  potentially fixable within — this slice.** For each: `{BI-id, one-line why it's
  relevant, fixable-in-this-slice? (y/n), recommended disposition}`. **Discard
  every unrelated entry silently** — do not echo it back. This is what keeps
  unrelated notes out of the designer's context.
- **Write (append):** given a new entry (or a status update on an entry this
  slice is acting on), append it to the ledger per §3–§4 — assigning the next id,
  preserving all existing entries, never echoing the full file back. If the file
  doesn't exist yet (first slice to write), create it from the §7 skeleton.

The designer's context therefore only ever holds (a) the small related-to-this-
slice subset and (b) append confirmations — never the unrelated bulk.

Spawn the steward with a prompt shaped like:

```
You are the BLAST-IMPACT ledger steward for ONE design slice. You own all reads
and writes of <feature>-slices/BLAST-IMPACT.md so the (code-blind, context-lean)
design skill never has to load the whole ledger.

Follow blast-impact-ledger.md (this file's §2–§4 and §6). Two tasks may be asked:

FILTER: Given the current slice and its subsystem map (below), return ONLY ledger
entries related to or potentially fixable within THIS slice. For each return:
BI-id, one-line relevance, fixable-in-this-slice (y/n), recommended disposition.
Silently discard unrelated entries — do not list them.

APPEND: Given new entries / status updates (below), add them append-only: assign
the next free BI-id, preserve every existing entry verbatim, update only Status +
History on entries the slice is acting on, never delete or rewrite another slice's
text. Create the file from the skeleton if absent. Report back only the ids you
wrote — not the whole file.

- Current slice: <path / pasted scope + §3 map>
- Ledger: <feature>-slices/BLAST-IMPACT.md
- New entries / status updates (APPEND only): <pasted, or "none">
Firewall: never write code (paths, symbols, table/column names, enum values,
migration ids, snippets). Behavior only, in SYSTEM_TAXONOMY terms.
```

## 6. Per-slice lifecycle (what the designer does)

1. **Reconcile on entry (only if the ledger exists).** After absorbing the slice
   (P1) and before finalizing the design, **yield a `LEDGER_OP` (FILTER)**. For
   each related entry the orchestrator returns, **yield a `FORK`** (recommended
   option first): *pull this fix into the current slice's scope, or leave it
   parked in the ledger?* If pulled in, it becomes in-scope design for this slice
   and the steward marks the entry "picked up by slice-N." If left parked, it
   stays as-is. (Slice 1 normally has no ledger yet — skip.)
2. **Append as you design.** Whenever the design surfaces a C5 / out-of-scope
   effect (typically at the P4a reality check, but anywhere), **yield a
   `LEDGER_OP` (APPEND)** with the new entry. Don't escalate it to the user as a
   fork — it's a recorded note (that's the whole "record, never grill"
   disposition).
3. **Closeout every run (§6.1).** When the slice's design is finished, do the
   awareness handoff below — every time, without being asked.

### 6.1 Closeout — tell the user plainly what is *not* being fixed

After the spec is written, yield a `LEDGER_OP` (FILTER) for the **open / parked**
entries, then tell the user (through the orchestrator), in plain words:

> "Heads up — these items are recorded in `<feature>-slices/BLAST-IMPACT.md` and
> **this slice is not fixing them**: [BI-id — one-line each]. Please open the
> ledger and review it so you're aware of the blast radius we're leaving for
> [owner/later slice]."

The point is that the user is never surprised: every out-of-scope effect is
named, and the fact that we're deliberately not addressing it is said out loud,
not buried. Do this at the end of *every* slice's design.

## 7. File skeleton (the steward creates this on first write)

```markdown
# Blast-Impact Ledger — <Feature Name>

Cross-boundary effects this feature's slices surface but do **not** fix. One
per-feature ledger, append-only across slices (never delete another slice's
notes). Schema + rules:
`kite-system-design-blueprint-slices/references/blast-impact-ledger.md`.

| ID | Affected subsystem | Surfaced by | Effect (behavior, no code) | Regression / benign | Why out of scope here | Recommended action + owner | Severity / blocking? | Status | History |
|----|--------------------|-------------|----------------------------|---------------------|-----------------------|----------------------------|----------------------|--------|---------|
| BI-1 | <taxonomy name> | slice-N design, <stage/element> | <behavioral effect> | <regression/benign> | <remedy owner> | <action + owner> | <sev / blocking?> | open | <slice-N: added> |
```

## 8. Who owns the ledger

The ledger belongs to the **design phase**, and only the design phase. The
`kite-solution-design` orchestrator runs the ledger-steward subagent on behalf of
its workers (which yield `LEDGER_OP` packets rather than spawning the steward
themselves). Two skills' work touches it:

- **`kite-system-design-blueprint-slices`** (the designer, this skill's owner) —
  reads it via the steward at **P1b** to reconcile (letting the slice that *can*
  fix a parked effect pick it up with the user's permission), appends out-of-scope
  effects at **P4a** (the "record, never grill" disposition), and runs the **P6
  closeout** that points the user at the ledger and names what is not being fixed.
- **`kite-system-design-conformance-review`** (the design critic) — its whole-set
  Stage-0 backstop reads the ledger to avoid re-flagging an effect already
  recorded, and **appends** the below-bar cross-slice collateral it catches
  (returning only bar-meeting collateral to the designer). It reviews the whole
  set, so the whole ledger is relevant — no steward filter needed.

Crucially, the ledger does **not** propagate **past** the design phase. Once an
effect is recorded (accepted as out-of-scope, or picked up into a slice), the
design has already decided what happens to it: a picked-up effect becomes ordinary
in-scope work the design spec describes, and a parked effect is, by definition,
not this slice's concern. So **nothing after the design phase reads this ledger** —
later work builds from the design spec itself, and forwarding the blast radius
onward would only pollute it with concerns the design already resolved. The
ledger's audience is the **user** (awareness, via the closeout) and the **design
phase itself** — the designer across slices, and its conformance critic.
