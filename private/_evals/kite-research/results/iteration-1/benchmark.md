# Skill Benchmark: kite-research

**Model**: <model-name>
**Date**: 2026-05-24T01:51:24Z
**Evals**: 0, 1, 2 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 94% ± 10% | 83% ± 3% | +0.11 |
| Time | 92.4s ± 21.2s | 69.7s ± 8.5s | +22.7s |
| Tokens | 5801 ± 754 | 6041 ± 1054 | -240 |

## Notes

- with_skill beat without_skill by +0.11 pass-rate (94.4% vs 83.0%), but baseline was already strong because the eval prompts name the desired research behavior explicitly.
- The only with_skill miss was eval 1 S2.RQ1: it identified no username lookup and named the user service extension point, but did not explicitly say getUserById is id-based, so the near-miss rejection was under-explained.
- without_skill failed by over-blocking S2 in the full-plan eval: missing capabilities were marked blocked instead of researched/MISSING, which is exactly the lane discipline kite-research should enforce.
- with_skill took about 22.7s longer on average while using slightly fewer tokens; the skill improved correctness but its original instructions encouraged slower, more expansive research.
