# Skill Benchmark: kite-research

**Model**: <model-name>
**Date**: 2026-05-24T01:51:24Z
**Evals**: 0, 1, 2 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 100% ± 0% | 78% ± 6% | +0.22 |
| Time | 85.7s ± 18.2s | 88.7s ± 14.7s | -2.9s |
| Tokens | 6248 ± 1175 | 6177 ± 1675 | +71 |

## Notes

- with_skill reached 100.0% pass-rate across all three evals, improving from 94.4% in iteration 1 and widening the baseline delta from +0.11 to +0.22.
- The S2-only miss from iteration 1 was fixed: the revised skill output explicitly rejected getUserById as id-based, not username-based, and pointed to a username lookup extension point.
- The clarified MISSING-vs-BLOCKING rule held: ordinary missing username/route work stayed researched/MISSING, while the synchronous notification and missing order email contradiction stayed blocked.
- with_skill became slightly faster than without_skill on average in iteration 2 (-2.9s) with roughly equal token usage, so the added specificity did not impose a measurable cost in this run.
