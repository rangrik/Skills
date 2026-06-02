# kite-testing

A standalone, personal **agentic Gherkin scenario runner**. Point it at any
running Kite environment — a PR's dev server, a deploy preview, staging, or
prod — and it runs `.feature` scenarios end-to-end, headless, driven by an LLM
agent. Self-contained: no dependency on any Kite checkout.

The operating runbook is the skill (`SKILL.md`), invocable as
`/kite-testing` once symlinked into `~/.claude/skills/`.

## Setup (once)

```bash
cd ~/Skills/private/kite-testing
npm install
npx playwright install chromium
cp .env.example .env     # then fill in ANTHROPIC_API_KEY (and KITE_BASE_URL)
```

## Run

```bash
# bundled example features against KITE_BASE_URL (from .env):
npm run scenarios

# a specific feature — bundled, or an absolute path to a PR's .feature:
npm run scenarios -- features/login.feature
npm run scenarios -- /path/to/your-pr/checkout.feature

# override the target per run (a deploy preview, staging, a worktree URL):
KITE_BASE_URL=https://v2dp4242.dp.appsmith.com/ npm run scenarios -- features/login.feature

# watch the browser:
HEADED=1 npm run scenarios:headed -- features/login.feature

# one scenario by line, or filter by tag:
npm run scenarios -- features/app-generation.feature:14
npm run scenarios -- --tags "@anonymous"
```

Exit code is the verdict (0 = all passed). Report + failure screenshots land
in `test-results/scenarios/` (`report.html`, `report.json`).

## Layout

```
kite-testing/
├── SKILL.md                       # the /kite-testing runbook
├── cucumber.mjs                   # config (tsx ESM, .env autoload)
├── features/*.feature             # example scenarios (write your own)
├── step-definitions/*.steps.ts    # generic step vocabulary
└── support/
    ├── config.ts                  # base URL, roles, paths, model, timeouts
    ├── agent.ts                   # act() / extract() — Playwright + Claude
    ├── auth.ts                    # inlined WorkOS login (self-contained)
    ├── auth-setup.ts              # one-time login per role → cached session
    ├── world.ts                   # per-scenario browser context
    └── hooks.ts                   # auth + lifecycle + screenshots
```

## Writing scenarios

Most `.feature` files need no new step code — use the generic vocabulary:

| Step | Meaning |
| --- | --- |
| `Given I am logged in` | assert the cached session is active |
| `Given I open the home page` | navigate to `/` |
| `When I navigate to "<path or url>"` | go somewhere |
| `When I "<instruction>"` | agentic action — the quoted text is the prompt |
| `When I wait until "<condition>"` | poll until the condition is observed |
| `Then I should see "<description>"` | agentic assertion |
| `Then I should not see "<description>"` | negative agentic assertion |
| `Then the page URL should contain "<fragment>"` | URL check |

Tags: `@anonymous` runs logged-out (login features); `@role:<name>` runs as a
non-default role (creds from `SCENARIO_<NAME>_EMAIL/PASSWORD`).

## Notes

- `KITE_BASE_URL` defaults to `https://v2.local.com/`. For a worktree dev
  server, pass that worktree's `task print-dev-url` output.
- The default `user` role uses the shared returning test account
  (`kite_e2e_user@appsmith.rocks`); override via `SCENARIO_USER_EMAIL` /
  `SCENARIO_USER_PASSWORD`.
- Login is inlined in `support/auth.ts` (WorkOS AuthKit). If the hosted login
  UI changes, update the selectors there.
- A fresh-signup (`@role:new-user`) flow isn't included yet.
