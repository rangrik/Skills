# Blueprint Template

This file defines the structure of the `<feature-name>-blueprint.md` deliverable.
Reproduce the sections below, in this order, in the output file. Each section is
described with guidance in _italics_ — replace the guidance with real content; never copy
the guidance text into the deliverable.

The companion `<feature-name>.feature` file contains exactly the Gherkin scenario blocks
from sections 6 and 7 — the `Feature` block and every `Scenario` / `Scenario Outline`,
verbatim with tags and `# Assumption:` comments — and nothing else.

---

## Section-by-section structure

**Title line:** `# Behavior Blueprint: <Feature Name>`

**Status line:** `**Status:** Draft · **Date:** <YYYY-MM-DD>`

### 1. Problem & Intent

_Two or three sentences: the problem this feature solves (the why) and what the feature
is (the what). Carried over from the problem statement or PRD — this is the only part
that stays as prose. State the primary success outcome(s) in one line._

### 2. Actors

_A short list of everyone who participates: the primary user who initiates the flow, plus
any secondary actors — an admin, the system itself, a third-party service, another end
user. One line each, describing their role in this feature._

### 3. Glossary

_Every domain term that two readers could interpret two ways, defined once — "active,"
"submitted," "member," "expired" — so the scenarios cannot be misread. Render as a
two-column table (Term | Definition). If the feature has no ambiguous terms, write "No
specialized terms" and move on._

### 4. Preconditions & Assumptions

_Two parts. **Preconditions:** what must be true before any scenario in this spec begins
— the world state the flow assumes. **Standing assumptions:** the global assumptions made
while writing this spec that the team should know about (write "None" if there are none).
Scenario-specific assumptions live with their scenarios and are collected in section 8._

### 5. Scope

_Two short lists. **In scope:** the behaviors this spec covers. **Out of scope:** closely
related things it deliberately does not, so no one expects them here. This keeps the spec
from being read as covering more — or less — than it does._

### 6. Happy-Path Scenarios

_The intended flows confirmed by the user in the interview — all of them, every distinct
legitimate way to succeed, not just the primary one. Gherkin, tagged `@happy-path`. The
`Background` block is a good home for preconditions shared by every scenario in the
feature._

Example shape:

```gherkin
Feature: <Feature Name>
  <one-line purpose>

  Background:
    Given <a precondition shared by every scenario>

  @happy-path
  Scenario: <primary success path>
    Given <context>
    When <the action>
    Then <the observable outcome>
```

### 7. Deviation Scenarios

_The scenarios produced by the deviation-taxonomy traversal. Group them by category, with
the category name as a subsection heading (7.1, 7.2, ...). Include only the categories
that produced scenarios — categories that did not apply are recorded in section 9, not
here. Every scenario is tagged `@deviation`, a category tag, and `@assumption` where the
graceful behavior was a choice rather than a given._

Example shape:

```gherkin
@deviation @invalid-input
Scenario: <specific deviation>
  Given <context>
  When <the action>
  Then <the graceful product behavior — specific and observable>
```

### 8. Flagged Assumptions

_A consolidated table of every scenario tagged `@assumption` — the product decisions the
skill had to make because the problem statement and interview did not dictate them. This
is the user's review queue and the most valuable section for the next conversation.
Columns: # · Scenario · Assumed behavior · Needs confirmation. If nothing was assumed,
state that explicitly._

### 9. Coverage Checklist

_The forcing function made visible: a table with one row per taxonomy category. Each row
is either covered (state how many scenarios) or marked N/A with a real, specific reason.
An empty cell or a missing row means the enumeration was not finished. Use exactly these
14 rows:_

| # | Deviation category | Covered | Scenarios / Reason if N/A |
|---|--------------------|---------|---------------------------|
| 1 | Incomplete or invalid input | | |
| 2 | Duplicate submission / retry | | |
| 3 | Rate limits, quotas, throttling | | |
| 4 | Connectivity loss & interruption | | |
| 5 | Abandonment & resumption | | |
| 6 | Out-of-order actions & navigation | | |
| 7 | Auth & permission changes mid-flow | | |
| 8 | Concurrency & stale data | | |
| 9 | Precondition satisfied / state conflict | | |
| 10 | Empty, boundary & scale extremes | | |
| 11 | Environment & device capability | | |
| 12 | External dependency failure | | |
| 13 | Time, expiry & scheduling | | |
| 14 | Adversarial & abuse input | | |

---

## Producing the two files

- The `.md` file is the human source of truth: narrative sections 1–5 and 8–9 wrapped
  around the Gherkin of sections 6–7.
- The `.feature` file is for tooling: the `Feature` block and every scenario from
  sections 6 and 7, verbatim, with tags and `# Assumption:` comments — no markdown, no
  narrative.
- The scenarios must be **identical** between the two files. The `.md` adds context
  around them; it never alters them.
- Name both files in kebab-case from the real feature name, e.g.
  `password-reset-blueprint.md` and `password-reset.feature`.
