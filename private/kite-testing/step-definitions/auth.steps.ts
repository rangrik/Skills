import { When, Then } from "@cucumber/cucumber";
import { strict as assert } from "node:assert";
import { ScenarioWorld } from "../support/world";
import { credsFor } from "../support/config";
import { performWorkOSLogin } from "../support/auth";

/**
 * Explicit login steps for `@anonymous` scenarios that exercise the real
 * WorkOS login UI. Authenticated scenarios do NOT need these — they start
 * from a cached session via the Before hook.
 */

When("I log in as {string}", async function (this: ScenarioWorld, role: string) {
  const { email, password } = credsFor(role);
  await this.page.goto("/");
  await performWorkOSLogin(this.page, email, password);
  await this.page.waitForURL(/^(?!.*workos).*$/, { timeout: 30_000 });
});

Then("I should be logged in", async function (this: ScenarioWorld) {
  const { value, evidence } = await this.extract<{
    value: boolean;
    evidence?: string;
  }>(
    "Is the user now logged in (account menu, dashboard, or logout visible)? " +
      "Return value true/false."
  );
  assert.ok(value, `Login did not succeed. ${evidence ?? ""}`);
});
