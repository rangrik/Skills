---
name: kite-design-system-standards
description: >-
  The authoritative reference for the architecture, design principles, and
  engineering standards of the appsmith-v2 (Kite) platform. Consult it whenever
  working in the appsmith-v2 repository — before or while adding or changing a
  route, service, schema, model, migration, agent, tool, skill, queue or worker,
  event flow, billing path, deployment flow, or frontend module — and whenever
  reviewing, refactoring, or making an architectural or design decision in that
  repo. Use it in two ways: look up the recommended standard before you build,
  or test an existing implementation against the standards and flag deviations.
  Reach for it whenever you are unsure whether an approach matches how this
  codebase is meant to be built, even if "architecture", "standards", or
  "conformance" are never said explicitly. Scope is strictly the appsmith-v2 /
  Kite platform — do not apply these standards to any other project or repo.
---

# Kite Design System Standards

The single source of truth for *how code is meant to be written* in the
appsmith-v2 (Kite) platform. It carries the platform's 43 engineering principles
and a map of which principles govern each of its 19 components, so that any
contributor — human or agent — builds the way the rest of the codebase is built,
and can check whether existing code does the same.

## Why this skill exists

A codebase stays healthy only while everyone changing it shares the same design
commitments. As collaborators and users multiply, the gap between "code that
happens to work" and "code built to the platform's standards" becomes the gap
between a system that scales and one that accrues debt. An AI agent is especially
prone to producing plausible-looking code that quietly diverges from local
convention. This skill closes that gap: it gives one place to look up the
standard before building, and one instrument to test an implementation against
the standard afterward.

## What is in this skill

- **`references/engineering-principles-contract.md`** — the standards catalogue,
  and the source of truth. Part 1 is the **Principle Catalogue**: 43 principles
  grouped into 8 themes, each stated *prescriptively* (the statement is the
  standard) with real examples from the repo. Part 2 is the **Component Map**:
  19 components of the platform, each listed against the principles it must
  follow.
- **`references/conformance-checklists.md`** — a review instrument: per-component
  yes/no checks derived from the catalogue, used in conformance mode.

The catalogue is principle-centric. Architectural styles, design patterns, and
frameworks (modular monolith, mediator, adapter, state machine, circuit breaker,
FastAPI, Celery, TanStack Query, and so on) are named *inside* the principle
entries to keep each principle concrete — look for them there.

## Scope — appsmith-v2 only

These standards describe one specific platform. Apply them only to code in the
appsmith-v2 / Kite repository. If the work is in another project, this skill
does not apply — say so rather than imposing these standards elsewhere.

## Two modes

Every use of this skill is one of two modes. Decide which you are in:

- **Mode A — Guidance lookup.** *"I am about to build or change X — what does the
  standard recommend?"* Use before and during implementation.
- **Mode B — Conformance review.** *"Here is an implementation — does it comply?"*
  Use during code review, refactoring, or when validating existing code.

A single request can need both: look up the standard for a piece you are adding
(Mode A), then review the surrounding code you are changing (Mode B).

## Mode A — Guidance lookup

1. **Locate the entry point.** You can enter the catalogue two ways, whichever
   fits the question:
   - *By component* — if you are touching a known part of the system (a route, a
     Celery task, the orchestrator, billing…), find it in Part 2's Component Map.
     It lists the principle numbers that govern that component.
   - *By topic* — if you are making a cross-cutting decision (how to handle
     retries, where state should live, how to fail on an outage…), scan Part 1's
     8 themes and find the principle for that topic.
2. **Read the governing principles in full.** Part 2 gives one-line notes; open
   the numbered entries in Part 1 for the principles that actually bear on your
   decision. Each entry states the standard prescriptively and shows how the repo
   already realises it.
3. **Follow the recommended standard.** The principle's prescriptive statement is
   the recommendation. Build to it. Prefer it over an ad-hoc choice every time.
4. **If you must deviate, do it openly.** See "The deviation rule" below.

Stay economical: pull in only the component and principles your decision needs,
not the whole contract. (That restraint is itself Principle 10 — progressive
disclosure.)

*Example.* Task: "add a background job that emails a user when their export is
ready." Component Map → **Celery & Background Workers** governs it (principles
15, 19, 21, 23, 25, 31). Reading those: the job must be idempotent (P15), bounded
in its retries with a terminal state (P21), and cancellation-cooperative (P25).
So: design an idempotency key, set `max_retries` with backoff, and check for
cancellation cooperatively — before writing the task body.

## Mode B — Conformance review

1. **Identify the component(s).** Determine which of the 19 components the code
   under review belongs to. A change often spans several (a new endpoint with a
   new service and table touches components 1, 2, and 3) — cover each.
2. **Run the checklists.** Open `references/conformance-checklists.md` and work
   through every relevant component's checklist. Each question is phrased so that
   "yes" means conformant.
3. **Confirm each "no" against the catalogue.** For every "no", open the cited
   principle (`[P21]` → Principle 21) and read the full entry. The principle text
   tells you whether the "no" is a genuine defect or a deliberate, justified
   exception. Mark questions that truly do not apply as **N/A with a one-line
   reason** — never silently skip them.
4. **Write a conformance report** using the template below.

Judge severity by which theme the violated principle sits in. Violations of
**State & Correctness** (Theme III) and **Security** (Theme V) are normally
blocking — they cause data corruption or breaches. Violations of structure,
abstraction, observability, or quality themes are usually should-fix: real, but
not release-blocking. State the severity; do not leave it implicit.

### Conformance report template

```
## Conformance Report — <what was reviewed>

Component(s) reviewed: <list>
Verdict: Conformant | Conformant with deviations | Non-conformant

### Deviations
For each one:
- [P<n>] <principle name> — <component>
  - Observed: <what the code does>
  - Standard: <what the principle requires>
  - Severity: blocking | should-fix | minor
  - Remediation: <concrete, specific change that would make it conformant>

### Conformant
<the checklists / principles that passed cleanly — one line>

### Not applicable
- <check> — <why it does not apply>
```

If there are no deviations, say so plainly — a clean report is a real outcome,
not a sign the review was shallow.

*Example.* Reviewing a new `*_db.py` function that calls `await db.commit()`
itself. Component → **Database Modules & Models**; checklist question [P17] asks
whether db modules `flush()` and leave `commit()` to the caller. Answer: no.
Report it — `[P17] Explicit transaction boundaries`, Observed: db module commits;
Standard: db modules flush, the route/service owns the commit; Severity:
should-fix; Remediation: replace `commit()` with `flush()` and let the caller
commit.

## The deviation rule

The documented standard wins over an ad-hoc choice by default. Sometimes a
deviation is genuinely the right call — a real constraint the principle did not
anticipate. That is allowed, on one condition: **the deviation is made explicit
and justified, never slipped in silently.** Name the principle being departed
from, state why, and record it where the next reader will see it (a comment, the
PR description, or a decision record — Principle 37). In a conformance review, an
*undocumented* deviation is itself a finding, even if the underlying choice turns
out to be defensible.

## Honesty about coverage

The catalogue is researched fact about this specific repository — not generic
best practice. Work within it:

- Do not invent principles that are not in the contract. If a question is not
  covered, say so plainly rather than guessing a standard.
- If the code clearly contradicts the contract because the *repository* has moved
  on, that is a signal the contract is stale. Flag it as "possible contract
  drift" so the catalogue can be refreshed — do not silently trust outdated text.

## Maintaining this skill

The catalogue is a living document, regenerated as architecture research
deepens. When the research changes: re-copy the updated
`engineering-principles-contract.md` into `references/`, and if the principle
numbering or the Component Map changed, update `references/conformance-checklists.md`
to match — the checklist questions cite principle numbers and must stay in sync.
