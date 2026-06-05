---
name: visual-plan-html
description: Produce a STANDALONE VISUAL HTML for the user to understand a piece of work — a feature, a bug fix, a new flow, a debugging/RCA, or whatever else. The user reads the HTML (markdown is just the agent's scratchpad), so ALWAYS generate one. Use whenever you produce a plan / design / fix write-up / investigation, when in plan mode or about to ExitPlanMode, or when the user says "make a plan", "design doc", "write it up", "HTML view", or references a plan's HTML. The HTML must EARN being HTML — diagrams, flows, comparisons, color-coded paths — never reflowed markdown text (the user will reject it), and it must LOOK different per work-type so the page signals what it is at a glance. NEVER mermaid; hand-build with the shared design system + inline SVG. This skill is a living system: the look lives in design-system.css and each work-type is an editable profile under profiles/.
---

# visual-plan-html

The user reads the HTML to *understand the work* — what's changing, why, how it flows, how it's verified. So the page has two jobs: **(1) signal its kind at a glance** — a bug fix should not look like a feature should not look like a flow — and **(2) make the structure visible**, not narrate it. If it's prose in boxes, it has failed; the user would read the markdown.

## How to build one

1. **Classify the work-type** — feature, bug fix, new flow/design, debugging/RCA, or something else (see registry). When unsure, pick the closest; the profile is a starting point, not a cage.
2. **Read that profile** in `profiles/<type>.md`. It gives the accent color, the badge, and the *recommended structure* for that kind of work.
3. **Inline `design-system.css`** verbatim into the output's `<style>` (keeps the file standalone), then set `--accent` / `--accent-bg` and the `.badge` text from the profile.
4. **Build the body around THIS issue's content** using the profile's structure as a guide — not a fixed section list. Diagram the things worth seeing; cut sections that don't apply; add ones that do.
5. **Write to `~/.claude/plans/<slug>.html` and `open` it.** Keep a markdown version wherever the project keeps plans if useful, but the HTML is the deliverable for the user.
6. **Write a `~/.claude/plans/<slug>.meta.json` sidecar** so the artifact shows up in the dashboard (`dashboard/server.py`). Fields: `slug`, `title`, `type` (the work-type key), `issue` (e.g. `V2-4684`), `branch`, `repo`. This applies to **every** artifact — plans, explainers, walkthroughs alike — and `issue` + `branch` are what associate it with its work: the dashboard groups cards by issue and resolves PR / DP / CI / Claude-review live from the branch. Do not hardcode PR numbers or links. (HTMLs without a sidecar still appear, but as inferred "unfiled" cards — the sidecar is what files them properly.)

## Craft rules (these come from real failures — do not regress them)

- **Callouts use `.callout`** — the label is a small kicker *above* a full-width body. Never a bold label in a skinny left column with the body wrapping beside it (that produces unreadable word-mush).
- **Metrics go in `.stats`** (a stat row), never as boxed numbers mid-sentence.
- **"How to test" uses `.checks`** — each item is a card with *Action → Expect*, scannable in seconds. File paths use `.paths`, not a callout.
- **Readability first:** the shared `--max-width`, generous line-height and vertical rhythm are there on purpose. Tables must breathe. Don't out-clever the legibility.
- **Color carries meaning** — use the legend's scheme (bad/good/existing/accent); don't decorate.

## Work-type registry

| Type | Profile | Identity | Use when |
|---|---|---|---|
| Bug fix | `profiles/bug-fix.md` | 🐛 amber | fixing a defect — root cause + before/after + verification |
| Feature | `profiles/feature.md` | ✦ blue | building new capability — flow + building blocks + phases |
| New flow / design | `profiles/flow.md` | ⇄ violet | how a system works/will work — the diagram is the hero |
| Debugging / RCA | `profiles/debug.md` | 🔍 rose | why something broke — symptom → evidence → root cause |
| Explainer | `profiles/explainer.md` | 📖 teal | understanding an existing system/change — journeys, walkthroughs, what's-what (not planning new work) |
| Audit | `profiles/audit.md` | 🔬 orange | ranked findings over an existing codebase — severity-first, themed, with verification funnel |

## This is a living skill — how to evolve it

- **Change the global look** (colors, spacing, a component) → edit `design-system.css`. Every future HTML inherits it.
- **Change one work-type's feel or structure** → edit its `profiles/<type>.md`.
- **Add a new work-type** (something that isn't bug/feature/flow/debug) → copy `profiles/_TEMPLATE.md` to `profiles/<new>.md`, set its accent + badge + structure, and add a row to the registry above.

## Anti-patterns

- Reflowing markdown into styled HTML text. ← the thing this skill exists to prevent.
- One layout for every work-type (everything looks the same → tells you nothing).
- Mermaid / external diagram or CSS libraries.
- Cramped tables, skinny-column callouts, numbers buried in prose.
