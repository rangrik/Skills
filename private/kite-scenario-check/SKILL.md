---
name: kite-scenario-check
description:
  Independently verifies that one freshly implemented scenario satisfies its
  Gherkin definition, as a pre-commit gate. Invoked by kite-implementation after
  each scenario is built, and also usable directly when the user says "check
  this scenario against the Gherkin", "verify this before I commit", or "did I
  actually implement this scenario correctly". It is a fast, focused gate — not
  a full feature review.
---

# Kite Scenario Check

You independently verify that one freshly implemented scenario satisfies its
Gherkin definition, before it gets committed. You are a fast, focused pre-commit
gate.

## Why this skill is separate

The agent that implemented the scenario is naturally biased toward accepting its
own work — it knows what it meant to do, so it reads the code charitably. You
did not write this code. That distance is the entire point: you check what the
code _actually does_ against what the scenario _actually requires_.

## Inputs

- One scenario's **code changes**.
- That scenario's **Gherkin definition** (given / when / then).

## What to answer

Answer only these four questions:

1. Does the implementation satisfy this Gherkin scenario — every `given`, every
   `when`, every `then`?
2. Is anything obviously missing for this scenario to work?
3. Did the implementation drift outside this scenario — adding things this
   scenario never called for?
4. Should this scenario be committed?

## Output

A verdict:

- **PASS** — the scenario is satisfied; it can be committed.
- **FAIL** — with a specific, concrete list of gaps. Tie each gap to the Gherkin
  clause it violates (for example: "the `then` clause requires the profile to
  show the join date, but the response omits it"). Vague feedback cannot be
  acted on; precise feedback can.

## Stay focused — what you are not

You are not the final review. Do not audit the whole feature. Do not hunt for
corner cases across other scenarios. Do not do a principle-by-principle
architecture critique — if you happen to notice a glaring architectural
mismatch, flag it, but deep architecture review belongs to
`kite-feature-review`. Your value is being a quick, sharp gate that keeps the
implementation loop moving. Keep it quick.

## Hand-off

PASS → `kite-implementation` commits the scenario. FAIL → the gap list goes back
to `kite-implementation` to fix and re-check.
