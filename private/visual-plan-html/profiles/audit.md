# Profile: audit

**Accent:** `--accent:#f97316; --accent-bg:rgba(249,115,22,.13);` (orange)
**Badge:** `🔬 AUDIT`
**Sub-line:** scope audited · method (e.g. "15 auditors + adversarial verification") · date

## What the reader wants
"What's wrong, how bad, and what do I fix first?" An audit ranks confirmed problems in an existing codebase/system. Severity is the organizing principle, **themes** are the synthesis — 40 findings as a flat list is noise; 8 recurring shapes with their instances is signal.

## Recommended structure (adapt to the content)
1. **Funnel stats** — `.stats` row: raw findings → verified → confirmed, plus severity counts. Establishes rigor.
2. **Fix-now (critical)** — the hero. Each critical gets full treatment: attack-path/failure-path as a small flow diagram, evidence code in a `.callout.bad pre`, concrete fix.
3. **High severity** — cards with evidence + fix, slightly lighter than criticals.
4. **Themes** — group the mediums into recurring shapes (the same anti-pattern at N sites beats N separate entries). Each theme: a one-line "the shape", a compact `.matrix` of instances (finding · location), and where useful a good-vs-bad pattern comparison in `.panels`.
5. **Hotspots** — files ranked by finding count (bar-ish viz or matrix).
6. **Low / unverified** — one compact table, clearly labeled.
7. **Refuted appendix** — `<details>` with what the adversarial pass killed and why; this is what makes the confirmed list credible.
8. **Suggested order of attack** — short: fix-now / next / opportunistic.

## Notes
- Orange = "inspection result", distinct from amber bug-fix (one defect) and rose debug (one investigation). An audit is *many* findings, ranked.
- Severity colors: critical/high use `--bad`, medium `--warn`, low `--neu`. Don't rainbow the categories — severity carries the color, category is text.
- Every confirmed finding must appear somewhere (hero, theme table, or low table) — silent omission breaks trust in the report.
