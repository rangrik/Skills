---
name: grill-me
description: Interview the user relentlessly about a plan, design, or feature idea until reaching shared understanding — resolving each branch of the decision tree — then capture that understanding as the seed document a build starts from. Use when the user wants to stress-test a plan, get grilled on a design, says "grill me", OR is kicking off a new feature/project and needs the problem pinned down before blueprinting. As the front door of the kite-conductor pipeline it writes `kite-conductor/<project-title>/main.md`, the intake the blueprint skill builds from.
---

# Grill Me

You interview the user relentlessly about every aspect of their plan, design, or feature
idea until you reach a genuine shared understanding — then you write that understanding
down as the seed the rest of the pipeline builds on.

## The interview

Walk down each branch of the decision tree, resolving the dependencies between decisions
one at a time. For each question, provide your recommended answer and the reasoning behind
it, so the user is reacting to a concrete proposal rather than a blank prompt.

- Ask the questions **one at a time** — a wall of questions produces shallow answers.
- If a question can be answered by exploring the codebase, explore the codebase instead of
  asking.
- Keep going until the load-bearing decisions are settled and you could explain the intent
  back to the user without hand-waving.
- If the user has already supplied a fully-resolved understanding (a detailed brief or
  spec), don't re-interview from scratch — confirm the open gaps, then go straight to
  capturing it below.

## Capture the result — `main.md`

The point of grilling is to produce a durable seed, not just a good conversation. When the
understanding is solid:

1. **Establish the project.** Pick a short kebab-case `<project-title>` for what is being
   built (confirm it with the user if it isn't obvious).
2. **Create the project home** at `kite-conductor/<project-title>/`. Every later skill in
   the pipeline — blueprint, slices, system design, plans, research, reviews — writes into
   this same directory, so all of a project's working documents live in one place and are
   easy to find.
3. **Keep it out of the product PR.** Ensure the repository's `.gitignore` ignores
   `kite-conductor/`. These are working/thinking documents, not shippable code; they
   should never bloat a feature's diff. Add the entry if it is missing — creating the
   `.gitignore` file itself if the repository has none yet.
4. **Write `kite-conductor/<project-title>/main.md`** — a faithful record of the grilled
   understanding: the problem and why it matters, the intended outcome, the decisions
   resolved (with the reasoning that settled them), and any open questions still
   outstanding. This is the intake the `blueprint` skill reads to build the behavior
   specification.

Then hand off: the natural next step is the `blueprint` skill, which reads `main.md` and
turns it into a complete, unambiguous behavior blueprint inside the same project directory.
