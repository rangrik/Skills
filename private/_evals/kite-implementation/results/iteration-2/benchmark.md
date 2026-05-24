# Skill Benchmark: kite-implementation

**Model**: <model-name>
**Date**: 2026-05-24T04:10:42Z
**Evals**: 1, 2, 3 (1 runs each per configuration)

## Summary

| Metric | With Skill | Without Skill | Delta |
|--------|------------|---------------|-------|
| Pass Rate | 43% ± 11% | 87% ± 6% | -0.44 |
| Time | 3.9s ± 1.0s | 868.1s ± 518.7s | -864.2s |
| Tokens | 103612 ± 2090 | 1286299 ± 342274 | -1182688 |

## INVALID with_skill DATA — DO NOT INTERPRET AS A REGRESSION

**The with_skill column in this iteration is an invalid artifact, not a real
measurement of skill quality.** All three iteration-2 `with_skill` children
failed at `turn.started` after a Codex usage-limit reset, before doing any work:

- Each `with_skill` run: `returncode=1`, `total_tokens=0` (the ~103k "tokens"
  above is only the static prompt text the aggregator counts from output files,
  not model usage), `transcript_chars=0`, wall time 3.3–5.0s.
- `outputs/codex_stdout.jsonl` for every with_skill run contains:
  `{"type":"error","message":"You've hit your usage limit ... try again at
  May 24th, 2026 12:13 AM."}` followed by `turn.failed`.
- HEAD never moved off the base commit `9573929d23`, so
  `git_cumulative_diff.patch` is empty and `git_show_stat.txt` shows the base
  commit's unrelated e2b/sandbox files. The heuristic grader then scored those
  empty/base-commit outputs, producing the spurious 43% and the false
  "sandbox_routes.py" / "e2b_service_retry.py" evidence lines — none of which
  the agent wrote.
- The without_skill runs started earlier (03:07–03:23 UTC) and completed
  normally; the with_skill runs all started at 03:31 UTC, after the budget was
  exhausted. This is a budget/sequencing artifact, confirmed by the
  skill-creator session log which states the relaunched with_skill children
  "failed before spending tokens" and were to be "rerun after the reset."

**Valid comparison signal:** In iteration-1, where the `with_skill` children
actually executed (rc=0, ~11–12M tokens each), the with_skill pass rates match
the baseline exactly on all three evals (0.90 / 0.889 / 0.909 vs identical
without_skill values) — i.e. the skill performs at parity with the generic
baseline on this heuristic grader. Treat iteration-1 as the authoritative
comparison; re-run the three iteration-2 with_skill children once the Codex
usage limit resets to obtain valid iteration-2 data.