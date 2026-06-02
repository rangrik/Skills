/**
 * Shared configuration for the standalone kite-testing harness.
 * Self-contained — no dependency on any Kite checkout.
 */

/** Where per-role authenticated sessions are cached (gitignored). */
export const AUTH_DIR = ".auth";

/** Where scenario reports + failure screenshots are written (gitignored). */
export const SCENARIO_OUTPUT_DIR = "test-results/scenarios";

/** Anthropic model used by the agentic act/extract layer. */
export const MODEL = process.env.LLM_MODEL || "claude-sonnet-4-20250514";

/** Re-login if a cached session file is older than this. */
export const SESSION_MAX_AGE_MS =
  Number(process.env.SCENARIO_SESSION_MAX_AGE_MS) || 6 * 60 * 60 * 1000;

/** Per-step timeout for normal agentic steps (act/extract/assert). */
export const STEP_TIMEOUT_MS =
  Number(process.env.SCENARIO_STEP_TIMEOUT_MS) || 180_000;

/** Budget for the "I wait until …" polling step. The step's own Cucumber
 *  timeout is set above this so the poll runs its full budget. */
export const WAIT_BUDGET_MS =
  Number(process.env.SCENARIO_WAIT_TIMEOUT_MS) || 20 * 60_000;

/** Timeout for the Before hook — auth setup can take a while on a cold env. */
export const HOOK_TIMEOUT_MS =
  Number(process.env.SCENARIO_HOOK_TIMEOUT_MS) || 300_000;

/** Launch headless unless HEADED=1 is set explicitly. */
export const HEADLESS = process.env.HEADED !== "1";

const DEFAULT_USER_EMAIL = "kite_e2e_user@appsmith.rocks";
const DEFAULT_USER_PASSWORD = "TestPassword123!";

/**
 * Target base URL. Point it at whatever you're testing via KITE_BASE_URL:
 * a PR's local dev URL, a deploy preview, staging, or prod. Falls back to the
 * canonical local dev URL.
 */
export function getBaseURL(): string {
  return process.env.KITE_BASE_URL || "https://v2.local.com/";
}

/** Storage-state file for a role (gitignored under .auth/). */
export function authFileFor(role: string): string {
  return `${AUTH_DIR}/scenario-${role}.json`;
}

export interface Creds {
  email: string;
  password: string;
}

/**
 * Credentials for a role. The default `user` role uses the shared returning
 * test account; any other role is read from `SCENARIO_<ROLE>_EMAIL` /
 * `SCENARIO_<ROLE>_PASSWORD`.
 */
export function credsFor(role: string): Creds {
  const key = role.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  const email = process.env[`SCENARIO_${key}_EMAIL`];
  const password = process.env[`SCENARIO_${key}_PASSWORD`];
  if (email && password) {
    return { email, password };
  }
  if (role === "user") {
    return { email: DEFAULT_USER_EMAIL, password: DEFAULT_USER_PASSWORD };
  }
  throw new Error(
    `No credentials for role "${role}". Set SCENARIO_${key}_EMAIL and ` +
      `SCENARIO_${key}_PASSWORD in the environment.`
  );
}
