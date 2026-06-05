# Profile: bug fix

**Accent:** `--accent:#f2994a; --accent-bg:rgba(242,153,74,.14);` (amber)
**Badge:** `🐛 FIX`
**Sub-line:** one-line essence · `PR #… · branch …`

## What the reader wants
"What was actually broken, what's the fix, and how do I know it works?" Lead with the **root cause** — make the defect *visible* — then the **before → after**, then **verification**.

## Recommended structure (adapt to the issue)
1. **Root cause** — the one diagram that shows *why* it broke (a mis-keyed path, a wrong branch, a bad state). Often a small flow or a 2-up "correct case vs broken case". Name the single root mismatch.
2. **Symptom(s)** — if one cause produced multiple visible bugs, show each as a compact mini-flow card so the reader connects symptom→cause.
3. **The fix** — `before` (the broken structure) vs `after` (the fixed structure) panels. If a key line changed, show it in a `.callout` with the code in a `<pre>`.
4. **Going forward / model** (optional) — if the fix implies a rule or model worth locking, a small diagram + a `.callout.warn` guardrail.
5. **How it's tested** — `.checks` (Action → Expect), tag each UNIT / DP. Put pass counts in `.stats`, not prose.

## Notes
- Amber says "repair" at a glance — distinct from feature-blue and flow-violet.
- Keep root cause above the fold; that's what the reader scans for first.
