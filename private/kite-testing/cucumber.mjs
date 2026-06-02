// Cucumber config for the standalone kite-testing harness.
//
// Run via the npm scripts, which set the tsx ESM loader so the TypeScript
// support/step files load without a build step:
//   NODE_OPTIONS='--import tsx' cucumber-js [feature path]

// Load .env for local convenience (KITE_BASE_URL, ANTHROPIC_API_KEY, …).
import "dotenv/config";

export default {
  // Default feature set; override by passing a feature path on the CLI, e.g.
  //   npm run scenarios -- /path/to/your.feature
  paths: ["features/**/*.feature"],
  import: ["support/**/*.ts", "step-definitions/**/*.ts"],
  format: [
    "progress",
    "html:test-results/scenarios/report.html",
    "json:test-results/scenarios/report.json",
  ],
  formatOptions: { snippetInterface: "async-await" },
};
