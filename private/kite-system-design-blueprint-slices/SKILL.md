---
name: kite-system-design-blueprint-slices
description: >-
  Takes one approved behavior slice (a `slice-N-*.md` from a `<feature>-slices/`
  directory produced by slice-blueprint) and works out HOW the system should
  achieve that behavior, at a high-level system-design altitude (NOT
  implementation detail). Works one slice at a time and writes one spec per
  slice as a sibling (`slice-N-<short>-system-design.md`). It reasons like a
  senior architect across every concern (data shape & integrity, performance,
  reliability, security, cost, rollout, …), using a data-movement lens as the
  entry point — do we have the data or generate it, how does it travel to the
  product surface, which existing subsystems act on it and with what effect. It
  is CODE-BLIND: it never reads source itself; instead it grills the user to
  resolve the unknowns only the USER can answer (intent, approach, trade-offs)
  and records the unknowns only the CODEBASE can answer as a separate list of
  research questions. Before each slice's design finalizes it commissions ONE
  firewalled reality check — a separate code-aware sub-agent that reads the code
  and returns contradictions in subsystem + behavior terms only (never code), so
  a decision that fights what already exists is caught and resolved with the user
  on that slice, not discovered downstream. The output enumerates Decisions,
  Tradeoffs, Assumptions,
  Scope (in & out), Risks, Constraints, and Dependencies, plus the data-flow
  narrative and the codebase questions. It consults
  `kite-design-system-standards` for the platform's principles and may read the
  repo's `SYSTEM_TAXONOMY.md` to name subsystems. Fires on "design the system
  for this slice", "solution design for slice N", "how should the system achieve
  this", "grill me on the design for this slice", or whenever an approved slice
  exists and the next job is its technical design — even when the user only says
  "design this slice". Not for product behavior (blueprint, then slice, first).
  Not for reading the codebase (that is the research stage). Not for
  step-by-step implementation tasks (that is planning). Scope is the appsmith-v2
  / Kite platform.
---

# Kite Slice System Design

**Step 3 of the Kite pipeline: Solution Design — how should the system achieve
this behavior?** You take one approved behavior slice and produce a high-level
technical spec for how the system makes that slice real: where its data comes
from and how it moves, which subsystems act on it, and the decisions,
trade-offs, risks, and constraints that shape the build — reasoning like a
senior architect and grilling the user to resolve every unknown that only they
can answer.

You work **one slice at a time** and produce a **one-to-one** output: for
`slice-2-refresh.md` you write `slice-2-refresh-system-design.md` next to it.
The spec, the slice, and a list of codebase questions are the artifact this step
hands forward — but not straight to planning. Once **every** slice has a design,
the full set goes to a fresh-eyes critic, **`kite-system-design-conformance-review`**,
which audits each design against its slice before the specs proceed to human
approval and planning (Step 4). See **P6 — Stop and hand off** for exactly when
and how to make that handoff.

## What this skill is really for: resolve the unknowns

A slice tells you _what the product should do_. This step works out _how the
system should achieve it_ — well enough that the build can then proceed almost
mechanically from sound engineering principles. The way you get there is by
**surfacing the unknowns and resolving the ones only the user can answer.**

There are two kinds of unknown, and keeping them apart is the heart of this
skill:

- **User-answerable unknowns** — questions about _intent and approach_ that no
  amount of code-reading would settle: do we already have this data or do we
  generate it (and how — a route, our own AI agent, a third-party integration)?
  what data is it, roughly, and what integrity does it need? what trade-offs are
  acceptable? how fresh must it be? **You grill the user to resolve these.**
  They are what block an implementer from proceeding.
- **Codebase-answerable unknowns** — _does X already exist? where is Y wired?
  what is the current shape of Z?_ These you do **not** answer (you are
  code-blind) and do **not** ask the user to play compiler for. You record them
  as a **list of questions for the codebase**, which the research stage answers
  later.

The bar for "done" is **autonomy**: the spec is complete when no user-answerable
unknown remains — when an implementer holding this spec, the codebase, and good
engineering principles could build the slice **without coming back to ask the
user anything**. Whatever is still open should be a codebase question, not a
product or intent question.

## The one rule: stay code-blind

**While using this skill, do not open, read, grep, or reference source code.**
Finding what already exists is a _different job_, owned by the research stage
(Step 5). If you design while reading code you anchor on what is convenient
today instead of what the slice needs, and you can no longer tell whether a
capability _should_ exist or merely _happens_ to. So every "does it already
exist" question becomes a recorded codebase question, never an investigation —
and a confident "we already have that" from the user is recorded as a question
too, not banked as fact.

**Code-blind, but system-aware.** "Code-blind" means *you* never read source —
not that you design in ignorance of what the system already is. Reality reaches
you through one firewalled channel, and you stay blind because the code stays on
the far side of it. That channel appears twice:

- **You commission it, per slice, at P4a** — before each slice's design hardens,
  a separate code-aware sub-agent reads the codebase and returns contradictions in
  subsystem + behavior terms only. This is the main event: it catches the false
  floor on *this* slice before the next one stacks on it.
- **The conformance critic returns it, once, at the end** —
  `kite-system-design-conformance-review` runs a whole-set pass for the
  cross-slice collateral a single slice couldn't see, and hands any of that back
  for you to resolve on re-entry (see "Re-entry" below).

Either way a contradiction arrives named at system altitude — a **subsystem** (its
`SYSTEM_TAXONOMY.md` title), the **design element** it collides with, and the
**nature** of the collision (*already exists / persists this differently / already
supplies this field*), with **no code** attached. You reason about named
subsystems and their behavior — never source — so you stay code-blind while
becoming aware of what the system already is. If a contradiction ever arrives
carrying a file path, a symbol, or a table name, that is a firewall leak: ignore
the code detail and
work only from the subsystem name and behavior.

## When to use

Use this once a feature's behavior has been sliced (a `<feature>-slices/`
directory exists) and a slice is approved, and the open question is _how the
system should achieve that slice's behavior_. This is Step 3, after
`slice-blueprint` (Step 2) and before planning (Step 4).

Also use it on **re-entry**, when `kite-system-design-conformance-review` returns
reality contradictions for a slice's design to resolve with the user — triggers
like "the conformance review found the design contradicts the codebase", "resolve
these design-vs-reality contradictions", or "the critic says these subsystems
already exist — reconcile the design". See "Re-entry" below.

**When NOT to use:**

- Defining what the product does, happy paths, or edge cases → the **blueprint**
  (Step 1). Cutting it into slices → **slice-blueprint** (Step 2). Both first.
- Discovering what already exists in the codebase → the **research stage** (Step
  5). This skill only _poses_ those questions.
- A scenario-by-scenario implementation plan → a **planning skill** (Step 4),
  after this. This skill is high-level design, not implementation steps.

## Inputs to gather first

1. **The one slice — and only that one.** Read the single `slice-N-<short>.md` you
   are designing, in full. It is the source of truth for behavior — its scenarios,
   scope, preconditions, and `Builds on:` line. Never re-derive or change the
   behavior here. Slices are designed **chronologically, in stacked order, with no
   user decision about sequencing**: the slice to design is simply the
   lowest-numbered `slice-N-*.md` that does not yet have a
   `slice-N-<short>-system-design.md` sibling. Determine that from the filenames
   alone — don't open the other slice files to choose.
2. **The `Builds on:` line — names only, not the files.** Use this slice's
   `Builds on:` line to know which earlier-slice **capabilities** to treat as
   already available, by name. **Do not open the other slice blueprints or their
   designs** — not the ancestors, not the later slices, not `SLICES.md`'s bodies.
   Designing one slice while reading the rest pulls the whole feature into your
   head at once, which is exactly what we're avoiding: you start optimizing for
   slices that aren't in front of you and lose the thin-slice focus. Assume the
   named ancestor capability exists and is sound; if the `Builds on:` line is too
   thin to design against, that's a gap to flag back to slicing — not a license to
   go read the ancestor. (You may glance at the bare list of slice *filenames* to
   confirm stacked order; that's not reading their content.)
3. **`kite-design-system-standards` (for consideration).** Consult it (Mode A)
   for the platform's engineering principles and its Component Map. It is how
   you keep recommendations conformant and how you _push back_ when the user's
   intent would bend a principle. If it can't be consulted, fall back to
   `references/design-principles.md` and note that in the output.
4. **`references/decision-taxonomy.md`** — the architect's lens: the full list
   of concerns to walk so nothing is silently skipped. This is the forcing
   function that was always central to this skill.
5. **`SYSTEM_TAXONOMY.md`** (optional, if present in the repo). Use its
   canonical names for subsystems and concepts — especially for "which
   subsystems act on the data" — so the spec speaks the team's language. If
   absent, proceed and name things plainly; don't block on it.
6. **The BLAST-IMPACT ledger** (`<feature>-slices/BLAST-IMPACT.md`) — the
   per-feature, append-only record of cross-boundary effects earlier slices
   surfaced but did not fix. **You do not read it directly** (its unrelated
   entries would pollute this slice's context); all reads and writes go through a
   **ledger-steward subagent**. See `references/blast-impact-ledger.md` for the
   full schema and protocol, and P1b / P4a / P6 below for when it is read,
   appended, and closed out. If the file doesn't exist yet (you're the first slice
   to surface anything), the steward creates it.

### Precedence & authority

In the Kite repo, `kite-design-system-standards` is authoritative and supersedes
the generic `references/design-principles.md` — on conflict, the Kite standard
wins, and recommendations cite the governing Kite principle by number. The
generic principles are the gap-filler for concerns the standard is silent on. If
the standard doesn't cover something, say so rather than inventing a principle.

## The entry lens: how is the data sourced and moved?

Start every slice by answering three questions about its data — this is the
fastest way into "how does the system achieve this behavior," and it surfaces
the biggest user-answerable unknowns early. Answer them in
`SYSTEM_TAXONOMY.md`'s vocabulary where you can.

1. **Source — do we have this data, or do we generate it?** Is it already
   produced/stored by an existing subsystem, supplied by the user, fetched from
   a third party, or generated (e.g. by one of our own AI agents)? "Have it" and
   "generate it" lead to very different designs — pin which.
2. **Travel — how does the data get from its origin to the product surface?**
   Trace the path, subsystem by subsystem, from where the data is born to where
   the user sees or uses it per the slice's scenarios.
3. **Actors & effects — which existing subsystems create, read, update, delete,
   or act on this data, and what is the effect when they do?** Name the
   subsystems on the path and the side-effects of each acting on the data
   (events emitted, downstream work triggered, caches affected, billing
   consumed).

This lens is the _way in_, not the whole design. Once the data path is sketched,
the full architect's lens (next) covers everything the data questions don't —
data shape and integrity, performance, reliability, security, cost, rollout, and
the rest.

## Process

### P1 — Absorb

Read **only the one slice** you are designing, in full, plus its `Builds on:`
line (names of ancestor capabilities to assume — not their files). Consult
`kite-design-system-standards` for the governing principles. Read
`SYSTEM_TAXONOMY.md` if present. Internalize `references/design-principles.md`
as the gap-filler. **Read no source code, and read no other slice** — not the
other blueprints, not their designs, not `SLICES.md`'s bodies (a glance at the
filenames for stacked order is fine).

### P1b — Reconcile with the BLAST-IMPACT ledger (via the steward subagent)

Earlier slices may have recorded cross-boundary effects they couldn't fix — and
some of those may now be *this* slice's to handle, because this slice builds the
subsystem that owns the remedy. So before you design, find out what the ledger
already holds that is relevant *to this slice* — but **without reading the ledger
yourself**, because most of its entries are about other slices and would pollute
your context with concerns that aren't in front of you.

**Skip this step if no `BLAST-IMPACT.md` exists yet** (you're an early slice and
nothing has been recorded). Otherwise:

1. **Spawn the ledger-steward subagent in FILTER mode** (prompt in
   `references/blast-impact-ledger.md` §5). Hand it this slice's scope and forming
   §3 subsystem map; it returns **only** the entries related to — or potentially
   fixable within — this slice, each as `{BI-id, why relevant, fixable here?,
   recommended}`. It silently discards everything unrelated, so your context only
   ever sees the relevant few.
2. **For each related entry, put it to the user** with `AskUserQuestion`
   (recommended option first): *pull this fix into this slice's scope now, or leave
   it parked in the ledger?* Frame the trade-off — pulling it in conserves a known
   effect early; leaving it parked keeps the slice thin. **Don't decide silently**
   and don't pull something in just because it's adjacent; relatedness is the
   subagent's call to *surface* it, but scope is the user's call.
3. **If the user pulls it in,** it becomes in-scope design for this slice (carry it
   through P2–P4 like any other requirement), and the steward marks that entry
   "picked up by slice-N" (status update only — never deleting the original). If
   left parked, it stays untouched.

This keeps the ledger from being a write-only graveyard: every prior note gets a
chance to be picked up by the slice that *can* fix it, but only with the user's
say-so, and only the relevant ones ever reach your context.

### P2 — Work out how the system achieves the behavior, and map the unknowns

Sketch the **entry lens** (source → travel → actors & effects). Then walk
**every dimension in `references/decision-taxonomy.md`** — the architect's
coverage — at a **high-level system-design altitude** (which subsystem owns it,
the rough data shape and integrity, the performance/reliability/security
posture; _not_ column DDL, migration SQL, or function signatures — that depth
belongs to planning and implementation). For each concern, look up the governing
standard and classify it:

- **(a) safe default assumption** — state it so the user can correct it;
- **(b) user-answerable unknown** — an intent/approach fork only the user can
  settle; queue it for the interview, with a recommendation;
- **(c) codebase question** — a fact only the code can settle; record it for the
  research stage (this is also where "we already have X" goes);
- **(d) N/A** — justify why it doesn't apply to this slice.

**Then share the map before interviewing.** Show the user a compact sketch: the
data path, the assumptions you're making, the user-answerable unknowns queued
for the interview, the codebase questions you'll hand off, and what you've ruled
N/A. This lets them correct a miscategorization while it's cheap.

### P3 — Grill the user (resolve the user-answerable unknowns)

Drive the queued unknowns (bucket b) to resolution in **dependency order**,
using `AskUserQuestion` with the **recommended option first**. Resolve linked
decisions one at a time; group genuinely independent ones to keep the interview
short.

- **Every recommendation cites a principle.** Ground it in the governing Kite
  principle (look up the number in `kite-design-system-standards`); where the
  standard is silent, use the generic lens by name.
- **Push back — don't just transcribe.** When the user's intent would bend a
  principle (couple subsystems that should stay decoupled, skip idempotency,
  cache with no invalidation story, let one subsystem reach into another's
  data), name the principle, explain the failure it invites, and offer the
  conforming alternative. If they still choose it, it becomes a recorded
  **accepted compromise** naming the bent principle — never a silent deviation.
- **Probe the technical unknowns too.** The data questions open the door; follow
  them with the architect's questions — what is the data, roughly? what
  structure and integrity does it need? what can go wrong? how fresh must it be?
  what's the performance expectation? — but keep the answers at design altitude.
- **Convert "we already have it" into a codebase question.** Don't design around
  an assumed implementation; state the capability the slice needs and let the
  research stage confirm whether it exists.
- **Hold scope.** Every question stays tied to _this slice_. New product
  questions belong in the blueprint; earlier-slice concerns get referenced, not
  re-decided.

### P4 — Pre-write gate: reality check, last call, autonomy (mandatory)

Three things stand between a drafted design and a written spec. Do them in order;
none is skippable.

#### P4a — Reality check (the one code-aware step, firewalled)

This is the gate that stops you from finalizing a slice that decided *against*
what is already built. You stay code-blind — but before this slice's design
hardens, you **commission** one reality check: spawn a separate sub-agent that
**is** allowed to read the codebase, hand it this slice's forming decisions and
its §3 subsystem map (New / Modified / Reused) plus the **names** of the
`Builds on:` capabilities it assumes, and have it check that map against what
actually exists. (You pass names, not ancestor files — you haven't read those,
and the sub-agent doesn't need them; its job is design-vs-codebase, not
design-vs-other-slice.)

Why per-slice, and why here: slices stack. If this slice marks a subsystem "New"
that already exists, or decides an approach the shipped code already rejected, and
that goes unnoticed, the *next* slice builds on the false floor — and the user,
who has by now formed a whole-feature mental model, gets tripped at the very end
when it's most expensive to unwind. Catching it on *this* slice lets the user
recalibrate (or go do more research and come back) while the model is still small.

What it checks — Family C of
`kite-system-design-conformance-review/references/defect-taxonomy.md`, scoped to
this slice's blast radius: C1 phantom-new subsystem, C2 a decision that
contradicts an existing subsystem's shape/behavior, C3 an assumption reality
already settled, C4 a forming §10 question reality already answers, and C5 a
blast-radius effect within this slice's own reach. C5 is the over-firing one:
sharing a data store with another subsystem is common and usually harmless, so it
escalates to a fork **only** when this slice's design would cause an existing
consumer a genuine regression *and* the remedy lives in a subsystem this slice
owns. A benign/equivalent effect, or one whose fix belongs to a *different*
feature, is recorded as a note — not a fork (see Family C's C5 escalation bar).

**The firewall keeps you code-blind.** The sub-agent reads source; you must not.
It returns each contradiction as only three things — the **subsystem** (its
`SYSTEM_TAXONOMY.md` title), the **design element** it collides with, and the
**nature** of the collision at design altitude (*exists / persists this
differently / already supplies this field*) plus a recommended reconciliation.
**No** file paths, symbols, table/column names, migration ids, snippets, or line
numbers ever reach you. If one does, it's a leak — ignore the code detail and
work from the subsystem name alone. And don't *invite* the leak: when you
commission the check, ask it for **contradictions against your forming design** —
not for a description of how an existing subsystem is built. A prompt that asks
"what is the shape/keying of X?" or "does the field set match?" will get a
code-level answer back (column names, enum values, record layout) and pull the
reviewer into a guided tour instead of a contradiction hunt. Keep "what shape is
X?" where it belongs — a §10 EXISTS/MISSING research question — not in the reality
check.

**Resolve contradictions in the grill loop, before writing.** Each real
contradiction is a fork for the user, recommended option first, the same as P3:
adopt the existing subsystem's shape (and flip the decision that fought it), reuse
what exists (drop the "New"/build framing), confirm the assumption and delete its
dead contingency, or accept a blast-radius effect with a §8/§2.3 amendment. Push
back if the user wants to diverge from what exists; if they still choose to, record
it as a **named accepted compromise**. Then fold each resolution into the forming
design. Adjudicate first so you don't drag the user through noise — a "New"
subsystem you genuinely intend to *extend*, or a §10 fact with no decision hanging
off it, isn't a contradiction worth a fork. **For a C5 blast-radius effect
specifically**, hold it to the bar before grilling: only put it to the user when
this slice's design would cause an existing consumer a real regression *and* the
remedy lives in a subsystem this slice owns. If the consumer ends up reading
equivalent/fresher data through a path it already supports, or its only fix lives
in a subsystem another feature owns, **append it to the feature's BLAST-IMPACT
ledger** (hand the steward subagent a new entry — append-only — per
`references/blast-impact-ledger.md`; a brief pointer from §8 / §2.3 to the
`BI-id` is fine) and leave it to the whole-set backstop — do not escalate it to a
per-slice fork. The slice's design stays about the slice's own functionality; an
unrelated feature's reaction to a shared store is recorded in the ledger, not
adopted as this slice's problem.

Spawn the reality check with a prompt like:

```
You are a code-aware reality checker for ONE system-design slice that is still
being finalized. You MAY read the codebase. Check the design's forming decisions
and subsystem map against what actually exists — and report contradictions
WITHOUT leaking any code back.

Read and follow Family C of <path>/kite-system-design-conformance-review/
references/defect-taxonomy.md, especially the firewall rule. Report only; edit
nothing.

- Slice: <absolute path to slice-N-*.md>
- Forming design (decisions + §3 New/Modified/Reused subsystem map): <pasted below>
- Builds-on capabilities this slice assumes: <names only — the ancestor files are
  out of scope; treat these as available>
- System taxonomy: <repo>/SYSTEM_TAXONOMY.md  (name every subsystem from it)
- Codebase root: <repo path>

Scope to THIS slice's blast radius: the subsystems in its §3 map and the existing
codebase subsystems they touch. Hunt C1–C5. For C5 (effects on existing consumers
of shared data), apply Family C's escalation bar: report an effect as a
contradiction to RESOLVE only when this slice's design would cause an existing
consumer a genuine regression (wrong / broken / contractually different data — NOT
merely fresher or equivalent data) AND the remedy lives in a subsystem this slice
owns. An effect on a consumer that belongs to a DIFFERENT feature, or any benign /
equivalent-data effect, is reported as a one-line note (affected subsystem +
effect), explicitly flagged "note, not a fork" — never as a contradiction to
resolve. Do not pull an unrelated feature into this slice's findings just because
it reads the same store. Return each contradiction as:
  - subsystem (canonical SYSTEM_TAXONOMY title; if absent, a plain system name + a
    note the taxonomy lacks the term)
  - design element (Decision Dn / Assumption An / §3 row / forming §10 Qn)
  - nature (the collision at design altitude + a recommended reconciliation)
  - proposed verdict (real / false-positive / defensible) + meaningfulness.

ABSOLUTELY DO NOT include file paths, function/class/symbol names, table or column
names, migration ids, code snippets, or line numbers. If a contradiction can only
be expressed by quoting code, restate it as a subsystem behavior or drop it.
Do NOT describe an existing subsystem's internal shape (its tables, columns, enum
values, or record layout) — not even in prose, and not even to answer a "what
shape is X?" question. "A summary record plus per-keyword child rows carrying a
status of owned vs competitor" leaks column names and enum values without quoting
a symbol — that is still a leak. Return NAMED COLLISIONS between a design element
and a subsystem's BEHAVIOR, not a tour of how anything is built. Report findings
only — no preamble, no narration of your investigation, no stray reasoning; if you
have no contradiction for a subsystem, say nothing about its internals.
```

**The reality check must run in a sub-agent — there is no inline fallback.** The
firewall only works if the agent that reads code is *not* you: you cannot unsee
source you've read, so "do it yourself and then ignore the code" is not a real
option for a skill whose whole identity is code-blindness. If the harness has no
sub-agent mechanism, do **not** read code here. Instead, leave the relevant
"does X already exist / is its shape Y?" items as §10 codebase questions (the
skill's normal code-blind behavior) and note in the spec that the P4a reality
check was skipped for lack of a sub-agent — the conformance review's whole-set
backstop and the research stage then become the catch. Losing the early catch is
the acceptable cost; letting the designer read code is not.

#### P4b — Last call

Ask explicitly:

> "Before I write this up — is there anything we've missed for this slice? Any
> concern, constraint, side-effect, or intent not yet captured?"

#### P4c — Autonomy test

_Could an implementer with this spec, the codebase, and good engineering
principles now build the slice without asking the user anything more?_ If a
user-answerable unknown is still open — including a reality contradiction P4a
surfaced but didn't resolve — loop back into P3. Whatever remains open must be a
codebase question. Don't skip this gate.

### P5 — Write the spec

Produce `slice-N-<short>-system-design.md` next to the slice, using
`references/design-doc-template.md`. The spec captures, at a high-level
altitude:

- the **data flow** (the entry lens: source / travel / actors & effects) and a
  **high-level system view** of which subsystems are new / modified / reused;
- the standard enumeration shared across the pipeline's artifacts — **Decisions
  · Tradeoffs · Assumptions · Scope (In & Out) · Risks (what can go wrong) ·
  Constraints · Dependencies** — each first-class;
- the **Open Questions for the Codebase** (the research handoff);
- two coverage checklists (decision-taxonomy dimensions; the slice's scenarios);
- an appendix faithfully capturing the interview.

### P6 — Continue to the next slice, or hand off

Deliver a short summary of the slice you just designed. The spec is a deliverable;
the whole set goes to **human approval** (the pipeline's Step 3 gate), then to
planning (Step 4) with its codebase questions feeding research (Step 5). Don't
invoke planning or research here.

**Blast-impact closeout — do this every time, before moving on.** A slice that
recorded out-of-scope effects must not let them pass silently. Ask the steward
subagent for the **open / parked** entries, then tell the user plainly, in their
own words — not buried in the summary:

> "Heads up — these items are recorded in `<feature>-slices/BLAST-IMPACT.md` and
> **this slice is not fixing them**: [BI-id — one-line each]. Please open the
> ledger and review it so you're aware of the blast radius we're leaving for
> [owner / later slice]."

The point is zero surprise: every effect we're deliberately not addressing is
named out loud and the user is pointed at the ledger to see the full picture. If
this slice recorded nothing and picked nothing up, say so in one line ("no new
blast-impact entries this slice"). Then continue.

**If more slices remain, continue straight to the next one** — the
lowest-numbered `slice-N-*.md` without a design — in stacked order, **without
asking the user which slice to do next.** Sequencing is not the user's decision;
the order is fixed by the stack, and you just walk it. (The user's involvement is
the per-slice design conversation — the P3 grill and the P4a contradiction forks —
not picking the next slice.) Open only that next slice's file, run P1–P5 for it,
and keep going. Don't review yet: the conformance critic runs over the *whole
set*, so it only makes sense once every slice has a design.

**When the slice you just designed was the last one — every `slice-N-*.md` in
the directory now has a `slice-N-<short>-system-design.md` sibling — hand off to
the critic before these specs go to planning.** Recommend running
**`kite-system-design-conformance-review`** on the `<feature>-slices/` directory.
That skill is to this one what `slice-conformance-review` is to `slice-blueprint`:
a fresh-eyes critic that re-derives each design's obligations from its slice and
the design-doc template, rather than trusting the §11/§12 coverage checklists
*this* skill wrote. It exists precisely because a generator grades its own
homework — it will tick "scenario handled" against a section that doesn't handle
it, mark a taxonomy dimension "Resolved" with a pointer that doesn't resolve it,
or quietly bank an intent fork as a §6 assumption that an implementer would
actually have to take back to the user. The critic catches those, fixes the
mechanical gaps, surfaces the ones only the user can settle, and verifies its
fixes landed.

So the deliverable of *this* skill is "all slices designed," and what you do with
that output is route it through the conformance review (the Step-3 critic) — the
specs are not ready for human approval + planning until that review has run.
Don't run the critic yourself per slice and don't act as your own critic on the
set; recommend the dedicated skill, which uses independent sub-agents on purpose.

## Re-entry: resolving cross-slice contradictions from the conformance review

Most reality contradictions are already caught and resolved per slice at P4a,
before each spec finalizes — that's the point of the hybrid. But one class
survives: **cross-slice collateral** a single slice structurally couldn't see —
an effect this slice's design has on a subsystem that an *earlier* or *later*
slice owns, visible only when the whole set is viewed at once. The conformance
critic's whole-set pass exists to catch exactly that, and when it does, it does
**not** fix it — it hands it back to you, because resolving it is an intent call
you own and must make code-blind. This is the backstop that keeps a false premise
the per-slice check couldn't reach from hardening into a plan downstream.

A returned contradiction arrives as `{subsystem (taxonomy title), design element
(Decision Dn / Assumption An / §3 row / §10 Qn), nature + recommended
reconciliation}` — no code. To resolve it, re-enter the affected slice and run a
**focused P3 grill loop** over just the returned contradictions:

- **Put each contradiction to the user as a fork, recommended option first**, the
  same way P3 does — grounded in the governing `kite-design-system-standards`
  principle. Most reconciliations are one of: *adopt the existing subsystem's
  shape* (and flip the decision that fought it), *reuse what exists* (and drop the
  "New"/build framing), *confirm the assumption and delete its now-dead
  contingency*, or *amend §2.3 / §4 for a blast-radius effect the design missed*.
  If the returned collateral is genuinely **out of this slice's scope to fix**
  (the remedy lives in a subsystem another slice or feature owns), don't force it
  into §2.3 — **append it to the BLAST-IMPACT ledger** via the steward
  (append-only) and leave it parked. Push back if the user wants to diverge from
  what exists — name the duplication or conflict it invites — and if they still
  choose it, record it as a **named accepted compromise**, never silent.
- **Fold the resolution into the spec** in the section that owns it: flip or
  rewrite the §4 Decision, retract or confirm the §6 Assumption, correct the §3
  New/Modified/Reused row, close the §10 question (it's answered now), or add the
  §8 risk / §2.3 effect the user accepted. Keep the design's voice and altitude —
  you're reconciling intent with reality, not re-authoring the slice.
- **Re-apply the autonomy test (P4c)** for the affected slice, then re-finalize its
  spec. The contradictions are closed when the re-finalized design no longer
  decides against the named subsystem. If your re-finalization materially changed
  decisions, recommend another conformance pass on the updated set — but resolve
  once and hand back; don't spin your own loop.

## Principles for running this skill

- **Resolve the user-answerable unknowns; defer the codebase ones.** The whole
  value is separating intent (grill the user, resolve it) from code truth
  (record it, hand it off). The autonomy test is the bar.
- **Architect's lens central; data-movement is the way in.** Walk the full
  decision taxonomy so no concern is silently skipped; the source/travel/actors
  questions are the high-leverage entry point, not the whole design.
- **High-level, not implementation.** This is a system-design view — subsystems,
  data shape, integrity, posture, decisions. Column-level schemas, migrations,
  and function signatures belong to planning and implementation, not here.
- **Code-blind by construction.** Reason from the slice, standards, taxonomy,
  and user — never source. Anything needing code truth is a recorded question.
- **Standards-grounded, and pushed back against.** Every decision cites the
  principle it upholds; every compromise names the one it bends. A departure is
  named and recorded, never silent.
- **Recommendation discipline.** Every question carries a recommendation with a
  principle-grounded reason; the user can always override.
- **One slice, one file, stacked — and don't read the others.** Design the slice
  in front of you; assume its `Builds on:` capabilities by name; never open the
  ancestor or later slice files or their designs. Sequencing is automatic (next
  un-designed slice in order), not a user choice.
- **The BLAST-IMPACT ledger is append-only and read through the steward.** Record
  every cross-boundary effect you can't fix here; never read or write the ledger
  yourself (the steward subagent does, so unrelated entries don't pollute your
  context); never delete or rewrite a note another slice authored — you may only
  add, or update the status of an entry this slice is picking up. Close out every
  slice by telling the user plainly what is *not* being fixed.

## Output structure

See `references/design-doc-template.md`. In short: Summary → Data Flow (source /
travel / actors & effects) → High-Level System View (new / modified / reused) →
Decisions → Tradeoffs → Assumptions → Scope (In & Out) → Risks → Constraints →
Dependencies → Open Questions for the Codebase → Decision Coverage Checklist →
Slice Coverage Checklist → Appendix A: Captured Inputs.

Alongside the per-slice spec, this skill also maintains one **per-feature
co-output**: the `BLAST-IMPACT.md` ledger (`references/blast-impact-ledger.md`),
written and read only through the steward subagent, append-only across slices.
The spec is what this slice *does*; the ledger is what this slice *affects but
won't fix* — both move forward together to the conformance review, planning, and
the final review.

## Gotchas

- **Don't read the code yourself.** If *you* are about to grep or open a file,
  stop — that's a codebase question, not a design step. The one sanctioned look at
  reality is the P4a reality check, and it happens at arm's length: a separate
  sub-agent reads the code and hands back only firewalled, code-free findings.
  Commissioning that check is not reading code; opening a file to "just confirm"
  is.
- **Don't read `BLAST-IMPACT.md` yourself.** Like code, the ledger is read at
  arm's length — the steward subagent reads it and hands back only the entries
  relevant to this slice. If you open the file directly to "just check," you pull
  every other slice's unrelated effects into your context, which is the pollution
  the steward exists to prevent. Same for writing: hand the steward the entry to
  append; don't edit the file yourself (and never delete another slice's note).
- **Don't drop to implementation altitude.** Resist column DDL, migration SQL,
  and function signatures. Decide _what_ and _which subsystem_, not _how to code
  it_. The downstream steps own that.
- **Don't let the data lens crowd out the architect's lens.** The three data
  questions are the entry point; integrity, performance, reliability, security,
  cost, and rollout still get walked.
- **Don't redefine product behavior.** Behavior belongs to the slice/blueprint.
  A behavior gap is a finding to flag back, not something to invent here.
- **Don't design the whole feature at once, or even read it.** One slice, one
  spec, and you only ever open the one slice's file. Reading the whole set loses
  the one-to-one mapping and quietly drags the entire feature into your head,
  which is what makes designs drift toward slices that aren't in front of you.
- **Don't redesign — or read — earlier slices.** Assume what a `Builds on:` line
  names, by name; don't open the ancestor's blueprint or design. If the named
  capability is too thin to design against, flag it back to slicing — don't go
  read the ancestor to fill the gap, and don't quietly fork it.
- **"We already have X" is a codebase question, not a fact.** However confident
  the user is, a claim about what exists is unverified until research checks it.
