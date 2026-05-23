# Skills

Agent Skills for Claude Code and other AI coding agents, published to [skills.sh](https://www.skills.sh).

---

## blueprint

[![skills.sh](https://skills.sh/b/rangrik/Skills)](https://skills.sh/rangrik/Skills)

Turn a loosely-stated product problem into a complete, unambiguous **behavior blueprint** — a specification of exactly how a user and the product interact, covering the happy paths *and* every deviation off them, written as Gherkin.

### Install

```sh
npx skills add rangrik/Skills/blueprint
```

Or install every skill in this repo at once:

```sh
npx skills add rangrik/Skills
```

Built for Claude Code; compatible with any agent that supports the `SKILL.md` format.

### The problem it solves

Problem statements and PRDs answer *what* and *why*. They rarely pin down the full *how* — the concrete, step-by-step interaction — and almost never enumerate what happens when the user leaves the intended path. Two failure modes follow:

- **Happy-path bias** — people describe the ideal flow and stop. Nothing forces a check that *all* the normal cases were captured.
- **The deviation blind spot** — half-filled forms, retried actions, rate limits, dropped connections, abandoned sessions, out-of-order steps. These are exactly what a happy-path description omits, and they surface late — in QA, code review, or production — where they are expensive to fix.

`blueprint` closes that gap by splitting the work: **you own intent, the skill owns completeness.**

### How it works

1. **It interviews you — only about the happy path(s).** The one thing a human must supply is what *should* happen when everything goes right.
2. **It enumerates every deviation itself.** Using a 14-category taxonomy and a step-by-step traversal matrix, it systematically finds the edge cases you would never think to list — and proposes graceful product behavior for each.
3. **It writes it all up as Gherkin** — a markdown blueprint document plus a Cucumber `.feature` file, so engineering, design, and QA all read the specification the same way.

### Usage

Once installed, describe a feature to your agent:

> "We're adding a 'forgot password' flow. Turn this into a behavior blueprint."

The skill interviews you about the intended flow, then autonomously produces `<feature>-blueprint.md` and `<feature>.feature` — including a coverage checklist across all 14 deviation categories and a list of flagged assumptions for you to confirm.

### What's inside

| File | Purpose |
|------|---------|
| `SKILL.md` | The five-phase workflow |
| `references/deviation-taxonomy.md` | 14 deviation categories and graceful-behavior principles |
| `references/gherkin-style.md` | Gherkin / Cucumber conventions |
| `references/blueprint-template.md` | Structure of the output document |
