# Profile: debugging / RCA

**Accent:** `--accent:#fb7185; --accent-bg:rgba(251,113,133,.14);` (rose)
**Badge:** `🔍 DEBUG`
**Sub-line:** what's being investigated · status

## What the reader wants
"What's the symptom, what did we rule in/out, what's the evidence, and what's the root cause?" This is an *investigation* — show the trail, not just the conclusion.

## Recommended structure (adapt to the issue)
1. **Symptom** — what was observed, concretely (the error, the bad output). A `.callout.bad` or a small repro flow.
2. **Timeline** — if events matter, a horizontal sequence of what happened when (inline SVG or `.hflow`).
3. **Hypotheses** — what was suspected, and ruled in/out, with the evidence for each. A `.matrix` (hypothesis · evidence · verdict) reads well.
4. **Root cause** — the confirmed cause, foregrounded (`.callout.good` or a diagram pinpointing it).
5. **Fix / next** — proposed fix or open follow-ups.

## Notes
- Rose = "investigation in progress / incident". Distinct from amber bug-fix (which assumes the cause is known and is being repaired).
- Keep ruled-out branches visible — the value is in showing *why* it's the root cause, not just asserting it.
