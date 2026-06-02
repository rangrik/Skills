import { Given, When, Then } from "@cucumber/cucumber";
import { strict as assert } from "node:assert";
import { ScenarioWorld } from "../support/world";
import { WAIT_BUDGET_MS } from "../support/config";

/**
 * Generic, reusable step vocabulary. Most `.feature` files need no new steps:
 * write the action as a quoted natural-language instruction
 * (`When I "open the user menu"`) and assertions as
 * (`Then I should see "a list of projects"`). The quoted text IS the prompt
 * handed to the agentic act/extract layer.
 */

interface BoolResult {
  value: boolean;
  evidence?: string;
}

Given("I am logged in", async function (this: ScenarioWorld) {
  await this.page.goto("/", { waitUntil: "domcontentloaded" });
  const { value, evidence } = await this.extract<BoolResult>(
    "Is a logged-in user UI visible (an account/profile menu, a dashboard, " +
      "or a logout option)? Return value true/false."
  );
  assert.ok(
    value,
    `Expected to start authenticated, but the session was not active. ${evidence ?? ""}`
  );
});

Given("I open the home page", async function (this: ScenarioWorld) {
  await this.page.goto("/", { waitUntil: "domcontentloaded" });
});

When(
  "I navigate to {string}",
  async function (this: ScenarioWorld, target: string) {
    // Relative paths resolve against the context baseURL.
    await this.page.goto(target, { waitUntil: "domcontentloaded" });
  }
);

When("I {string}", async function (this: ScenarioWorld, instruction: string) {
  await this.act(instruction);
});

When(
  "I wait until {string}",
  // This step's Cucumber timeout MUST exceed its own poll budget, otherwise
  // the default step timeout kills the wait early. See config.WAIT_BUDGET_MS.
  { timeout: WAIT_BUDGET_MS + 60_000 },
  async function (this: ScenarioWorld, condition: string) {
    const deadline = Date.now() + WAIT_BUDGET_MS;
    let lastEvidence = "";
    while (Date.now() < deadline) {
      const { value, evidence } = await this.extract<BoolResult>(
        `Is this condition now true on the page? "${condition}" ` +
          "Return value true/false."
      );
      lastEvidence = evidence ?? "";
      if (value) return;
      await this.page.waitForTimeout(5_000);
    }
    throw new Error(
      `Timed out waiting until: ${condition}. Last observation: ${lastEvidence}`
    );
  }
);

Then(
  "I should see {string}",
  async function (this: ScenarioWorld, description: string) {
    const { value, evidence } = await this.extract<BoolResult>(
      `Is "${description}" clearly visible on the page? Return value ` +
        "true/false with brief evidence.",
      { includeText: true }
    );
    assert.ok(
      value,
      `Expected to see "${description}". Evidence: ${evidence ?? "none"}`
    );
  }
);

Then(
  "I should not see {string}",
  async function (this: ScenarioWorld, description: string) {
    const { value, evidence } = await this.extract<BoolResult>(
      `Is "${description}" visible on the page? Return value true/false.`,
      { includeText: true }
    );
    assert.ok(
      !value,
      `Expected NOT to see "${description}". Evidence: ${evidence ?? "none"}`
    );
  }
);

Then(
  "the page URL should contain {string}",
  function (this: ScenarioWorld, fragment: string) {
    const url = this.page.url();
    assert.ok(
      url.includes(fragment),
      `URL "${url}" does not contain "${fragment}".`
    );
  }
);
