import {
  BeforeAll,
  Before,
  After,
  Status,
  setDefaultTimeout,
  type ITestCaseHookParameter,
} from "@cucumber/cucumber";
import { mkdirSync } from "node:fs";
import { ScenarioWorld } from "./world";
import { ensureAuth } from "./auth-setup";
import { HOOK_TIMEOUT_MS, SCENARIO_OUTPUT_DIR, STEP_TIMEOUT_MS } from "./config";

// Agentic steps make LLM calls and drive a real app, so the default 5 s
// Cucumber step timeout is far too low. Long pipeline waits use the dedicated
// "I wait until …" step (which sets its own higher timeout).
setDefaultTimeout(STEP_TIMEOUT_MS);

const ROLE_TAG_PREFIX = "@role:";

function roleForScenario(tags: string[]): string | undefined {
  if (tags.includes("@anonymous")) return undefined;
  const roleTag = tags.find((t) => t.startsWith(ROLE_TAG_PREFIX));
  return roleTag ? roleTag.slice(ROLE_TAG_PREFIX.length) : "user";
}

BeforeAll(function () {
  mkdirSync(SCENARIO_OUTPUT_DIR, { recursive: true });
});

Before(
  { timeout: HOOK_TIMEOUT_MS },
  async function (this: ScenarioWorld, { pickle }: ITestCaseHookParameter) {
    const tags = pickle.tags.map((t) => t.name);
    const role = roleForScenario(tags);
    if (role) {
      // Idempotent — reuses a fresh cached session; only logs in when needed.
      await ensureAuth(role);
    }
    await this.open(role);
  }
);

After(async function (
  this: ScenarioWorld,
  { result }: ITestCaseHookParameter
) {
  try {
    if (result?.status === Status.FAILED && this.page) {
      const buffer = await this.page.screenshot({ fullPage: true });
      this.attach(buffer, "image/png");
    }
  } catch {
    // A screenshot failure must not mask the real scenario failure.
  } finally {
    await this.close();
  }
});
