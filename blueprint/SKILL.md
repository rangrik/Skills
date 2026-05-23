---
name: blueprint
description: >-
  Turn a loosely-stated product problem or feature idea into a complete, unambiguous
  behavior specification. Interviews the user about the intended happy path(s), then
  autonomously enumerates every plausible deviation and edge case — invalid input,
  retries, rate limits, lost connectivity, abandoned sessions, out-of-order actions,
  expired sessions, concurrency, boundary states, external failures — and proposes
  graceful product behavior for each, writing it up as a markdown blueprint plus
  Cucumber .feature files. Use whenever someone has a feature idea, problem statement,
  or PRD to pin down into concrete behavior; asks for a behavior blueprint, behavior
  spec, interaction spec, acceptance criteria, or Gherkin/Cucumber scenarios; asks
  what the edge cases are or what could go wrong with a feature; or describes a
  feature loosely and wants it made rigorous and complete — even if they never say
  the words 'behavior spec'.
---

# Blueprint

*Turns a loosely-stated product problem into a complete, unambiguous behavior blueprint: the happy paths are interviewed from the user, every deviation is mapped by the skill, and the whole thing is written up as Gherkin.*

## Why this skill exists

The journey from "here is a problem we want to solve" to "here is a feature" routinely
skips its hardest, most valuable step: rigorously describing how a real user actually
behaves while using the feature. Problem statements and PRDs answer *what* and *why*.
They rarely pin down the full *how* — the concrete, step-by-step interaction — and they
almost never enumerate what happens when the user leaves the intended path.

Two failure modes follow:

1. **Happy-path bias.** People describe the ideal flow and then stop. Once the obvious
   path feels "covered," thinking ends. Nothing forces a check that *all* the normal
   cases were actually enumerated.
2. **The deviation blind spot.** The moments that make a product feel broken are almost
   all deviations — a half-filled form gets submitted, a successful action gets retried,
   a rate limit gets blown past, connectivity drops mid-flow, the user abandons and
   returns, or does things out of order. Happy-path descriptions omit exactly these, so
   they surface late — in QA, code review, or production — where they are expensive and
   embarrassing to fix.

The deeper cause is that thinking through complete behavior is tedious and cognitively
demanding. Humans anchor on the ideal case and tire quickly. This skill fixes that by
splitting the work so each side does what it is good at.

## The core idea: who owns what

**The user owns intent. The skill owns completeness.**

The user is the only authority on what the feature is *for* and what *should* happen when
everything goes right. So the skill interviews them — and only them — about the **happy
path(s)**. That is the one thing a human must supply.

Enumerating deviations is the opposite kind of work: mechanical, exhausting, and
unbounded if done by free association. That is the skill's job. **Never ask the user to
brainstorm edge cases, errors, or failure modes.** If they volunteer some, capture them
gratefully — but the burden of completeness is the skill's, and Phase 3 discharges it
systematically.

A spec is only a genuine source of truth if engineering, design, and QA all read it the
same way. That is why the output is Gherkin: structured `Given / When / Then` scenarios
that mean one thing to everyone, not prose that three teams interpret three ways.

## Workflow

Five phases. Do them in order. Phases 1–2 involve the user; Phases 3–5 do not.

### Phase 1 — Intake the problem

Get the problem statement. It may already be in the conversation, in an uploaded PRD or
doc (read it fully), or you may need to ask for it. Extract: the problem being solved
(the *why*), the feature concept (the *what*), the actors involved, and any constraints
already stated.

Do not over-interrogate here. The *why* is usually fine as prose, and the PRD-style
framing is rarely the weak point. Save your interview energy for the happy path. If there
is genuinely nothing to work from, ask the user for a short paragraph describing the
problem and the feature, then continue.

### Phase 2 — Interview for the happy path (hybrid, user-facing)

This is the **only** phase where you interview the user. The goal is to enumerate 100% of
the *normal* cases.

Note the plural: **"normal cases" is plural.** Most features have more than one legitimate
way to succeed — log in with a password versus SSO, pay with a saved card versus a new
one, accept an invite as an existing user versus a brand-new one. Stopping at the first
happy path is itself a form of happy-path bias. Probe explicitly for alternatives.

Work through, conversationally:

- **Success outcome(s).** What does "this worked" mean? There may be several distinct
  successful end states — name each one.
- **Actors.** Who initiates the flow? Who or what else participates (the system, an
  admin, a third-party service, another user)?
- **Entry points.** How does the user arrive at this flow?
- **The primary happy path, one atomic step at a time.** For each step capture: which
  actor acts, what they do, how the system responds, and what the user perceives next.
  Keep steps small enough that each has a single clear actor and outcome.
- **Alternative happy paths.** After the primary path, ask directly: "Is there another
  legitimate way a user completes this successfully?" Walk each one the same way.
- **Preconditions and glossary.** Harvest these *in passing* — what must be true before
  the flow starts, and any domain term that two people could read two ways. Do not run a
  separate interrogation for them.

**Interview discipline (hybrid).** Use open, conversational questions to *elicit* steps
("What happens right after they hit Send?"). Use the `AskUserQuestion` multiple-choice
tool to *disambiguate or confirm* when there is a small set of plausible answers ("After
the email sends, does the user stay on the page or get redirected?"). Ask about one topic
per turn — a wall of questions is tiring and produces shallow answers, which is the very
failure mode this skill fights. Be relentless about **coverage**, not **volume**:
relentless means not stopping until every step has a clear actor, action, and response
and every success path is named — it does not mean asking forty questions.

**The forcing function — play it back before moving on.** When you believe the happy
path(s) are complete, read `references/gherkin-style.md`, then play the flow back to the
user two ways at once: as a numbered step list *and* as draft Gherkin happy-path
scenario(s). Seeing it concretely is what makes a person notice the missing step. Ask
them to confirm or correct. **Do not proceed to Phase 3 until the user confirms the happy
path is right.** This playback is the forcing function that secures "100% of normal
cases."

**If the happy path is already written down** (a detailed PRD, or the user spelled it out
in their request), do not re-interview from scratch. Extract it, play it back for
confirmation, and ask only about genuine gaps. Respect the work the user already did.

**Boundary:** do not ask the user about edge cases, errors, or deviations. That is
Phase 3, and it is yours.

### Phase 3 — Enumerate deviations (autonomous, no user interview)

This is where the skill earns its keep — and it must not itself fall into happy-path
bias. The antidote is to make deviation-finding **mechanical and exhaustive** instead of
relying on inspiration, which tires and misses things.

Read `references/deviation-taxonomy.md`. It contains the deviation categories, the
questions that detect each one, and the graceful-behavior patterns that resolve them.

Build a **traversal matrix**. List every atomic step of every happy path down one axis,
and every deviation category across the other. Visit each cell and ask one question:
*can this category of deviation occur at this step?* This converts an open-ended,
tiring task ("think of edge cases") into a finite, checkable one ("inspect N×M cells").
That conversion is the forcing function against the deviation blind spot — work the
matrix cell by cell rather than free-associating.

For every cell where a deviation is real, write a Gherkin scenario:

- The `Then` steps must specify the **graceful product behavior** — what *should* happen.
  Do not merely name the problem; resolve it. Apply the graceful-behavior principles from
  the taxonomy: preserve the user's work, make repeated actions idempotent, communicate
  honestly and specifically, keep the system in a safe and consistent state, and always
  offer a way forward.
- When the correct behavior is genuinely determined by the problem statement or the
  interview, state it with confidence.
- When you must *choose* — the spec does not dictate the answer — pick the best graceful
  default, write it anyway, and tag that scenario `@assumption` with a short
  `# Assumption:` comment naming the open decision. Per the user's preference, **flag,
  do not block**: never stop to ask. Surfacing the assumption in the doc lets them
  verify it later.

Some deviations are not tied to one step but to the **whole flow** — abandoning and
returning, the session expiring, connectivity dropping, concurrent activity in another
tab. The taxonomy marks these; apply them to the flow as a whole.

**Coverage rule.** Every category in the taxonomy must end up either with at least one
scenario *or* with an explicit, justified "not applicable" note in the coverage
checklist. Silent omission is the exact failure this skill is designed against — forcing
an explicit, reasoned N/A keeps the enumeration honest.

### Phase 4 — Write the outputs

Read `references/blueprint-template.md` and (if not already) `references/gherkin-style.md`.
Derive a short kebab-case feature name for filenames. Produce two deliverables:

1. **`<feature-name>-blueprint.md`** — the full markdown blueprint, following the
   template: problem and intent, actors, glossary, preconditions and assumptions, scope,
   happy-path scenarios, deviation scenarios grouped by category, the consolidated
   flagged-assumptions list, and the coverage checklist.
2. **`<feature-name>.feature`** — a Cucumber file with every scenario in pure Gherkin,
   tagged (`@happy-path`, `@deviation`, `@assumption`, plus a category tag such as
   `@rate-limit`). One feature file suits most features; split into several only when
   there are clearly separable sub-features.

The Gherkin scenarios must be identical between the two files — the `.md` wraps them in
narrative; the `.feature` file is just the scenarios. Save both to the folder the user is
working in.

### Phase 5 — Deliver and summarize

Give a short summary: the feature name, how many happy-path scenarios, how many deviation
scenarios and how many taxonomy categories they span, and how many assumptions were
flagged. Point the user explicitly at the flagged-assumptions section — those are the
decisions only they can finalize, and that is the natural next step.

## Principles to hold throughout

- **Be specific in `Then` steps.** "The user sees an error" is the kind of ambiguous
  prose this skill exists to kill. Say *what* error, *where*, and *what the user can do
  next*.
- **Resolve, don't just report.** Every deviation scenario should leave the product in a
  defined, graceful state. A spec that lists problems without answers is half a spec.
- **Prefer graceful realism over completeness theatre.** Do not invent absurd scenarios
  to pad the count. A deviation belongs in the spec because it can plausibly happen to a
  real user, not to fill a cell.
- **The flagged assumptions are a feature, not an apology.** They are precisely the
  product decisions that were hiding inside "obvious" — surfacing them is the point.
