# Profile: explainer

**Accent:** `--accent:#2dd4bf; --accent-bg:rgba(45,212,191,.13);` (teal)
**Badge:** `📖 EXPLAINER`
**Sub-line:** what's being explained · the issue/PR it belongs to

## What the reader wants
"Help me *understand* this — how it behaves, what the journeys are, what changed." An explainer documents an **existing** system or change for comprehension (walkthroughs, before/after journeys, what's-what guides). It is **not planning new work** — that's what plan/feature/fix profiles are for.

## Recommended structure (adapt to the content)
1. **The journeys / scenarios** — the hero. Walk each user-visible path as a flow (often several small flows beat one big one). Before-vs-after pairs work well when explaining a change.
2. **The cast** — a short key of components/terms the reader must know (tree or compact panels).
3. **Edge cases & gotchas** — `.callout`s for the surprising bits.

## Notes
- Teal = "read to understand", distinct from violet flow (designing something new) — explainers describe what *is*, flows design what *will be*.
- **Always set `issue` + `branch` in the meta sidecar** — explainers belong to a piece of work and must group under it in the dashboard, sharing its PR/DP/CI live data.
