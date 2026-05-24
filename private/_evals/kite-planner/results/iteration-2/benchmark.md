# Skill Benchmark: kite-planner

**Model**: <model-name>
**Date**: 2026-05-24T02:26:44Z
**Evals**: 0, 1, 2 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 100% ± 0% | 21% ± 7% | +0.79 |
| Time | 379.4s ± 359.2s | 128.1s ± 20.7s | +251.3s |
| Tokens | 33235 ± 5007 | 25272 ± 3771 | +7963 |

## Notes

- Iteration 2 preserved the key result from iteration 1: with-skill passed 100% of expectations and without-skill passed 20.8%, for the same +0.79 pass-rate delta.
- The revised SKILL.md did not regress code-blind discipline: the pressure eval passed all with-skill expectations, including converting existing-infrastructure hints into research questions.
- Without-skill outputs continued to fail mainly on shared schema, Gherkin extraction, planned status, and concrete per-scenario research questions.
- Timing is noisy in this iteration: eval-0/with_skill took 794s around a Codex usage-limit reset, so the +251s mean time delta should not be interpreted as purely skill overhead.
