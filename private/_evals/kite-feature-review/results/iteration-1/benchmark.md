# Skill Benchmark: kite-feature-review

**Model**: <model-name>
**Date**: 2026-05-24T01:45:34Z
**Evals**: 1, 2, 3 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 100% ± 0% | 68% ± 3% | +0.32 |
| Time | 167.8s ± 69.3s | 69.2s ± 6.2s | +98.5s |
| Tokens | 625682 ± 463684 | 140018 ± 20173 | +485664 |

## Notes

- Iteration 1: with_skill passed all 25 expectations across 3 evals; without_skill passed 17/25. The +0.32 delta is driven by exact report structure, principle citations, concrete Gherkin failure cases, and missed-corner-case coverage.
- Baselines found many real defects, so the suite is not merely testing generic bug-finding. The gap is that baselines usually produced merge-review prose rather than the prescribed final Kite feature-review artifact.
- The skilled runs spent substantially more time and tokens, especially eval 2. Transcript review shows the skill drove broad architecture-reference loading; the skill was revised to make kite-arch-compass lookup more targeted.
- The original Fan out instruction conflicts with benchmark/resource-constrained execution. The skill was revised to make fan-out conditional while preserving one-scenario-at-a-time isolation.
