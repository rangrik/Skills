import { chromium } from "@playwright/test";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { loginWithPassword } from "./auth";
import {
  AUTH_DIR,
  authFileFor,
  credsFor,
  getBaseURL,
  HEADLESS,
  SESSION_MAX_AGE_MS,
} from "./config";

/**
 * One-time authentication per role. Logs in via the inlined WorkOS password
 * flow and caches the session as a Playwright `storageState` file so
 * subsequent scenarios start already authenticated.
 *
 * Idempotent: returns immediately if a fresh cached session exists. Delete
 * `.auth/scenario-*.json` to force a clean re-login.
 */

function isFresh(file: string): boolean {
  if (!existsSync(file)) return false;
  return Date.now() - statSync(file).mtimeMs < SESSION_MAX_AGE_MS;
}

export async function ensureAuth(role: string): Promise<void> {
  if (role === "new-user") {
    throw new Error(
      "The `new-user` (fresh signup) role isn't supported in this standalone " +
        "tool yet. Use the default `user` role, or set SCENARIO_<ROLE>_EMAIL / " +
        "SCENARIO_<ROLE>_PASSWORD for an existing account."
    );
  }

  mkdirSync(AUTH_DIR, { recursive: true });
  const file = authFileFor(role);
  if (isFresh(file)) {
    return;
  }

  const browser = await chromium.launch({ headless: HEADLESS });
  const context = await browser.newContext({
    baseURL: getBaseURL(),
    ignoreHTTPSErrors: true,
  });
  const page = await context.newPage();

  try {
    const { email, password } = credsFor(role);
    await loginWithPassword(page, {
      email,
      password,
      storageStatePath: file,
      logPrefix: `[Scenario:${role}]`,
    });
  } finally {
    await context.close();
    await browser.close();
  }
}
