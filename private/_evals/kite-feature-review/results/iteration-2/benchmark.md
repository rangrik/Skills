# Skill Benchmark: kite-feature-review

**Model**: <model-name>
**Date**: 2026-05-24T02:00:08Z
**Evals**: 1, 2, 3 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 100% ± 0% | 68% ± 3% | +0.32 |
| Time | 146.4s ± 1.9s | 79.0s ± 20.0s | +67.3s |
| Tokens | 365436 ± 53953 | 138892 ± 17913 | +226544 |

## Notes

- Iteration 2: with_skill again passed all 25 expectations across 3 evals; without_skill again passed 17/25. Pass-rate delta stayed +0.32, so quality did not regress after the skill revision.
- Efficiency improved materially: skilled mean time dropped from 167.8s to 146.4s, and skilled mean token usage dropped from about 625.7k to 365.4k. The eval-2 skilled outlier fell from 1.16M tokens / 247.1s to 419.6k tokens / 148.5s.
- The revised targeted architecture-lookup guidance reduced variance: skilled runtime stddev fell from 69.3s to 1.9s and token stddev from 463.7k to 54.0k.
- Baseline remained strong at general defect discovery but consistently missed the Kite-specific report contract: exact headings, P-numbered architecture citations, and concrete Gherkin failure cases.
- No third iteration is indicated: iteration 2 satisfies all key expectations and clearly beats baseline while improving efficiency over iteration 1.
