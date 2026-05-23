# Gherkin Style Guide

Gherkin is the language of the spec's scenarios. It is chosen because a `Given / When /
Then` scenario means the same thing to engineering, design, and QA — it is structured
enough to remove ambiguity and close enough to plain English that anyone can read it.
This guide keeps the output consistent and machine-parseable for Cucumber tooling.

## Structure

```gherkin
Feature: <short feature name>
  <one or two lines describing the feature's purpose — the what and why>

  Background:
    Given <a precondition shared by every scenario in this feature>

  @happy-path
  Scenario: <a single, specific behavior>
    Given <context / starting state>
    When <the action the actor takes>
    Then <the observable outcome>
    And <a further outcome>

  Scenario Outline: <a behavior that repeats across data variations>
    Given <context with a <placeholder>>
    When the user enters "<value>"
    Then <outcome involving <result>>

    Examples:
      | value        | result            |
      | valid@x.com  | accepted          |
      | not-an-email | rejected inline   |
```

- **Feature** — one per `.feature` file. The description line carries the *why*.
- **Background** — preconditions true for *every* scenario in the file. Use it to avoid
  repeating the same `Given` everywhere; do not put actions or anything scenario-specific
  in it.
- **Scenario** — one concrete behavior.
- **Scenario Outline + Examples** — the same behavior across a table of data. Reach for
  it when you would otherwise copy a scenario several times changing only values (a set
  of invalid inputs, a set of roles).

## The Given / When / Then discipline

Each keyword has one job. Keeping them honest is what makes scenarios unambiguous.

- **Given** — context only. The state of the world before the action. No actions here.
- **When** — the single action or event under test. Ideally exactly one `When` per
  scenario; if you need two, the scenario is probably two scenarios.
- **Then** — the observable, checkable outcome. What the user sees or what the system
  does — never an internal implementation detail no one can observe.
- **And / But** — continue the previous keyword's role. `And` after a `Then` is another
  outcome; `And` after a `Given` is another precondition.

## Rules that keep scenarios trustworthy

**One behavior per scenario.** If the title needs the word "and," split it. Small focused
scenarios fail for one clear reason; sprawling ones hide gaps.

**Each scenario is independent.** A scenario sets up its own world in `Given` and does not
rely on a previous scenario having run. Order must not matter.

**Write declaratively, not imperatively.** Describe the *behavior and intent*, not the
pixel-level UI mechanics. Imperative scenarios are brittle and bury the meaning; a button
rename should not invalidate the spec.

- Imperative (avoid): `When the user types "jo@x.com" into the field with id "email"
  And clicks the blue button labelled "Go"`
- Declarative (prefer): `When the user submits their email address`

  Keep enough concrete detail that the scenario is testable — name the field or value
  when it matters to the behavior — but do not script the UI.

**`Then` steps must be specific and observable.** "The user sees an error" is the
ambiguous prose this whole skill exists to eliminate. Say which message, where it
appears, and what the user can do next. A `Then` someone could not verify is not done.

**Name scenarios for the behavior.** A good title reads as the case it covers:
"Submitting the form with a required field empty," not "Test 4" or "Error case."

**Resolve, do not just report.** Especially for deviations, the `Then` steps describe the
*graceful product behavior* — the system's good response — not merely that something went
wrong.

## Tags

Tags classify scenarios and let tooling and readers filter them. Apply on the line above
`Scenario`.

- `@happy-path` — an intended, everything-goes-right flow, from the user interview.
- `@deviation` — a scenario the skill generated from the deviation taxonomy.
- `@assumption` — the graceful behavior shown rests on a product decision not dictated by
  the problem statement or interview. Always pair it with a `# Assumption:` comment
  inside the scenario naming the open decision, so the user can find and confirm it.
- A **category tag** for each deviation, drawn from the taxonomy, so scenarios can be
  grouped: `@invalid-input`, `@duplicate-retry`, `@rate-limit`, `@connectivity`,
  `@abandon-resume`, `@out-of-order`, `@auth-permission`, `@concurrency`,
  `@state-conflict`, `@boundary`, `@environment`, `@external-failure`, `@time-expiry`,
  `@adversarial`.

A deviation scenario therefore carries at least `@deviation` and one category tag, plus
`@assumption` when relevant:

```gherkin
@deviation @rate-limit
Scenario: Exceeding the hourly send limit
  ...

@deviation @adversarial @assumption
Scenario: Submitting input containing a script payload
  # Assumption: all free-text input is sanitized server-side and escaped on render.
  ...
```

## Comments

A line starting with `#` is a comment. Use it sparingly: for the mandatory
`# Assumption:` note on `@assumption` scenarios, and occasionally to explain a non-obvious
precondition. Do not narrate every step.

## Common mistakes to avoid

- Putting an action in `Given` or `Background` — actions belong in `When`.
- Multiple unrelated `When`s — that is multiple scenarios wearing one coat.
- Vague `Then` steps that no one could check.
- Implementation detail in `Then` ("a row is inserted into the orders table") instead of
  observable behavior ("the order appears in the user's order history").
- Copy-pasted near-identical scenarios that should be one `Scenario Outline`.
- Scenarios that depend on a previous scenario's leftover state.
