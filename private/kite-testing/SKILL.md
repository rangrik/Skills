---
name: kite-testing
description: >
  Use this skill when you want to run a behavior scenario file (Gherkin /
  .feature) end-to-end against a running Kite environment — a PR's dev server,
  a deploy preview, staging, or production — driven headlessly by an agent, to
  verify a feature or a PR actually works with no human clicking through a
  browser. Reach for it on "kite-test this PR", "run this scenario", "agentic
  scenario test this feature", or "execute these acceptance scenarios
  headless". For verifying a UI change with a watchable video, use the
  ui-testing skill instead; for a human-style browser prompt to hand to another
  agent already on the prompt page, use the claude-browser-test-prompt skill.
argument-hint: "<path to a .feature file> [target: a URL, or staging | deploy-preview | local]"
---

# kite-testing

Run a Gherkin `.feature` file end-to-end against a running Kite environment,
headless, driven by an LLM agent. A standalone personal tool — point it at any
PR's environment and check that it actually works.

It lives at `~/Skills/private/kite-testing/` and is self-contained (own deps +
inlined login, no dependency on any Kite checkout).

## When to use

- You want to actually run a `.feature` scenario and get a pass/fail against a
  real environment (a PR's dev URL, a deploy preview, staging, prod).
- You're testing one of your in-flight PRs and want it exercised end-to-end.

## When NOT to use

- Verifying a UI change with a watchable video → `ui-testing`.
- Producing a copy-paste browser prompt for a human-style session on the
  prompt page → `claude-browser-test-prompt`.

## Step 1 — Parse inputs

From `$ARGUMENTS`: the **scenario file** (a path — bundled like
`features/login.feature`, or an absolute path to a `.feature` anywhere) and an
optional **target** (a URL or env keyword). If no scenario is given, list
`~/Skills/private/kite-testing/features/*.feature` and ask which to run, or
offer to write one for the PR under test.

## Step 2 — Resolve the target URL → `KITE_BASE_URL`

| Target            | KITE_BASE_URL                                        |
| ----------------- | ---------------------------------------------------- |
| a full `https://` | used verbatim                                        |
| `local` (default) | unset → `https://v2.local.com/`; for a worktree dev server pass its `task print-dev-url` output |
| `deploy-preview`  | `https://v2dp<PR_NUMBER>.dp.appsmith.com/`           |
| `staging`         | `https://staging.kite.ai/`                           |
| `prod`            | `https://kite.ai/`                                   |

For a worktree's local dev server, make sure it's up (`task start` in that
worktree) and grab its URL with `task print-dev-url`.

## Step 3 — One-time prerequisites

```bash
cd ~/Skills/private/kite-testing
npm install                              # first run only
npx playwright install chromium          # first run only
```

`ANTHROPIC_API_KEY` (powers `act`/`extract`) must be set — in the environment
or in `~/Skills/private/kite-testing/.env` (gitignored; see `.env.example`).
The default `user` role uses the shared returning test account.

## Step 4 — Run the scenario

```bash
cd ~/Skills/private/kite-testing

# default target from .env:
npm run scenarios -- features/login.feature

# or set the target for this run (a PR's deploy preview, etc.):
KITE_BASE_URL="https://v2dp4242.dp.appsmith.com/" \
  npm run scenarios -- features/app-generation.feature

echo "exit: $?"     # 0 = all scenarios passed
```

- Point at a PR's own scenario file: `npm run scenarios -- /abs/path/to.feature`
- Watch the browser: `HEADED=1 npm run scenarios:headed -- <feature>`
- One scenario: append `:<line>` → `<feature>:14`
- Filter by tag: `-- --tags "@anonymous"`

Tip: start with `features/login.feature` (cheap: one login + one check) to
confirm the target + key + auth all work before a heavier scenario.

## Step 5 — Interpret and report

- **Exit status** is the verdict (0 = all passed).
- `test-results/scenarios/report.html` (open it) and `report.json` hold
  per-scenario pass/fail and the failing step's error.
- A full-page screenshot is attached to any failed scenario.
- Summarise: which scenarios passed/failed, the failing step + its error, and
  the screenshot path. If a step failed inside `act`/`extract`, quote the
  model's reported evidence — it usually names what was missing.

## Writing scenarios

Most `.feature` files need no new step code — use the generic vocabulary (in
`step-definitions/`):

| Step | Meaning |
| --- | --- |
| `Given I am logged in` | assert the cached session is active |
| `Given I open the home page` | navigate to `/` |
| `When I navigate to "<path or url>"` | go somewhere |
| `When I "<instruction>"` | agentic action — the quoted text is the prompt |
| `When I wait until "<condition>"` | poll until the condition is observed (long flows) |
| `Then I should see "<description>"` | agentic assertion |
| `Then I should not see "<description>"` | negative agentic assertion |
| `Then the page URL should contain "<fragment>"` | URL check |

Tags: `@anonymous` runs logged-out; `@role:<name>` runs as a non-default role
(creds from `SCENARIO_<NAME>_EMAIL/PASSWORD`). Add new step definitions only
when an action can't be expressed as a natural-language `When I "…"`.

## Gotchas

- **Point at a reachable env.** A worktree dev server must be up (`task
  start`); a deployed target must be reachable.
- **LLM steps are non-deterministic.** Keep instructions concrete; phrase
  assertions so the evidence is unambiguous. A flaky step is usually a vague
  instruction — read the evidence before retrying.
- **Whole-pipeline flows are slow** (create → design → build → publish can be
  10–20 min). Scope a scenario, or gate long waits with `When I wait until
  "…"` (`SCENARIO_WAIT_TIMEOUT_MS`, default 20 min; normal steps default to
  180 s via `SCENARIO_STEP_TIMEOUT_MS`).
- **Stale session.** If `Given I am logged in` fails mid-run, the cached
  session expired — delete `~/Skills/private/kite-testing/.auth/scenario-*.json`
  to force a clean re-login (auto-refreshes after 6 h).
- **Login UI drift.** Auth is inlined in `support/auth.ts`; if the hosted login
  page changes, update the selectors there.
