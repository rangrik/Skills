import Anthropic from "@anthropic-ai/sdk";
import type { Locator, Page } from "@playwright/test";
import { MODEL } from "./config";

/**
 * The agentic act/extract layer — a small "mini-Stagehand" on Playwright +
 * the Anthropic SDK.
 *
 * `act`    : given an instruction and the page's accessibility snapshot, the
 *            model picks ONE concrete Playwright action, which we execute.
 * `extract`: given a question, the model returns a structured answer (default:
 *            a boolean + evidence) used to drive assertions.
 *
 * Both use Anthropic tool-use so the model is forced into a typed shape.
 */

const MAX_SNAPSHOT_CHARS = 12_000;

// Constructed lazily so importing the harness (e.g. for a --dry-run, or a
// non-agentic step) never requires the key — only running act/extract does.
let cachedClient: Anthropic | undefined;

function getClient(): Anthropic {
  if (!process.env.ANTHROPIC_API_KEY) {
    throw new Error(
      "ANTHROPIC_API_KEY is required for agentic act/extract steps. " +
        "Set it in the environment or in .env."
    );
  }
  if (!cachedClient) {
    cachedClient = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  }
  return cachedClient;
}

function truncate(s: string): string {
  return s.length > MAX_SNAPSHOT_CHARS
    ? s.slice(0, MAX_SNAPSHOT_CHARS) + "\n… (truncated)"
    : s;
}

/** The page's accessibility tree as YAML (role + accessible-name pairs). */
async function ariaSnapshot(page: Page): Promise<string> {
  try {
    return truncate(await page.locator("body").ariaSnapshot());
  } catch {
    return "(accessibility snapshot unavailable)";
  }
}

type AriaRole = Parameters<Page["getByRole"]>[0];

interface ActionTarget {
  role?: string;
  name?: string;
  label?: string;
  placeholder?: string;
  text?: string;
  testId?: string;
  exact?: boolean;
}

interface ActionInput {
  action:
    | "click"
    | "fill"
    | "type"
    | "press"
    | "select_option"
    | "check"
    | "uncheck"
    | "hover"
    | "goto"
    | "wait_for";
  target?: ActionTarget;
  value?: string;
  key?: string;
  url?: string;
  reasoning?: string;
}

const ACTION_TOOL: Anthropic.Tool = {
  name: "perform_action",
  description:
    "Perform a single concrete browser action that makes progress on the " +
    "instruction, targeting an element that appears in the accessibility snapshot.",
  input_schema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: [
          "click",
          "fill",
          "type",
          "press",
          "select_option",
          "check",
          "uncheck",
          "hover",
          "goto",
          "wait_for",
        ],
      },
      target: {
        type: "object",
        description:
          "How to locate the element. Prefer role + name copied from the " +
          "snapshot. Provide only the fields you need.",
        properties: {
          role: {
            type: "string",
            description: "ARIA role, e.g. button, link, textbox, tab",
          },
          name: {
            type: "string",
            description: "Accessible name exactly as shown in the snapshot",
          },
          label: { type: "string", description: "Associated form label" },
          placeholder: { type: "string" },
          text: { type: "string", description: "Visible text to match" },
          testId: { type: "string" },
          exact: { type: "boolean" },
        },
      },
      value: {
        type: "string",
        description: "Text to fill/type, or the option to select",
      },
      key: { type: "string", description: "Key to press, e.g. Enter" },
      url: { type: "string", description: "URL or path for a goto action" },
      reasoning: {
        type: "string",
        description: "One short sentence on why this action",
      },
    },
    required: ["action"],
  },
};

function buildLocator(page: Page, t: ActionTarget | undefined): Locator {
  if (!t) return page.locator("body");
  if (t.testId) return page.getByTestId(t.testId);
  if (t.role && t.name) {
    return page.getByRole(t.role as AriaRole, { name: t.name, exact: t.exact });
  }
  if (t.label) return page.getByLabel(t.label, { exact: t.exact });
  if (t.placeholder) return page.getByPlaceholder(t.placeholder, { exact: t.exact });
  if (t.text) return page.getByText(t.text, { exact: t.exact });
  if (t.role) return page.getByRole(t.role as AriaRole);
  // A name with no role: match any visible element with that text rather than
  // guessing a role (which would produce a misleading "no <role> found" error).
  if (t.name) return page.getByText(t.name, { exact: t.exact });
  return page.locator("body");
}

function toolUseInput<T>(message: Anthropic.Message, context: string): T {
  const block = message.content.find((b) => b.type === "tool_use");
  if (!block || block.type !== "tool_use") {
    // Surfacing stop_reason makes rate-limit / max_tokens / refusal failures
    // immediately recognisable instead of a generic "no result".
    throw new Error(
      `The model returned no structured result for: ${context} ` +
        `(stop_reason=${message.stop_reason}).`
    );
  }
  return block.input as T;
}

async function execute(
  page: Page,
  a: ActionInput,
  timeout: number
): Promise<void> {
  if (a.action === "goto") {
    if (!a.url) throw new Error("act: goto action requires a url");
    // Keep navigation on the app under test. Resolves relative paths and
    // refuses an off-origin absolute URL the model may have lifted from the
    // snapshot (a CDN, an OAuth page, etc.), which would hang a run.
    const target = new URL(a.url, page.url());
    const current = new URL(page.url());
    if (target.origin !== current.origin) {
      throw new Error(
        `act: refusing to navigate off-origin to ${target.origin} ` +
          `(current ${current.origin}). Use a path or a same-origin URL.`
      );
    }
    await page.goto(target.href, { waitUntil: "domcontentloaded" });
    return;
  }
  if (a.action === "press") {
    const key = a.key ?? a.value ?? "Enter";
    if (a.target) {
      await buildLocator(page, a.target).first().press(key, { timeout });
    } else {
      await page.keyboard.press(key);
    }
    return;
  }

  const loc = buildLocator(page, a.target).first();
  switch (a.action) {
    case "click":
      await loc.click({ timeout });
      return;
    case "hover":
      await loc.hover({ timeout });
      return;
    case "fill":
      await loc.fill(a.value ?? "", { timeout });
      return;
    case "type":
      await loc.click({ timeout });
      await page.keyboard.type(a.value ?? "", { delay: 20 });
      return;
    case "select_option":
      await loc.selectOption(a.value ?? "", { timeout });
      return;
    case "check":
      await loc.check({ timeout });
      return;
    case "uncheck":
      await loc.uncheck({ timeout });
      return;
    case "wait_for":
      await loc.waitFor({ state: "visible", timeout });
      return;
    default:
      throw new Error(`act: unsupported action "${a.action}"`);
  }
}

/** Perform a natural-language browser action against the current page. */
export async function act(
  page: Page,
  instruction: string,
  opts: { timeout?: number } = {}
): Promise<void> {
  const timeout = opts.timeout ?? 30_000;
  const snapshot = await ariaSnapshot(page);

  const message = await getClient().messages.create({
    model: MODEL,
    max_tokens: 1024,
    tools: [ACTION_TOOL],
    tool_choice: { type: "tool", name: "perform_action" },
    system:
      "You are a browser-automation agent. Given an instruction and the " +
      "current page's accessibility snapshot, choose ONE concrete browser " +
      "action that makes progress on the instruction. Only target elements " +
      "that actually appear in the snapshot, and copy accessible names verbatim.",
    messages: [
      {
        role: "user",
        content:
          `Instruction: ${instruction}\n\n` +
          `Current URL: ${page.url()}\n\n` +
          `Accessibility snapshot:\n${snapshot}`,
      },
    ],
  });

  const action = toolUseInput<ActionInput>(message, `act("${instruction}")`);
  await execute(page, action, timeout);
}

export interface ExtractOptions {
  /** JSON Schema for the structured answer. Defaults to `{ value: boolean,
   *  evidence?: string }`. */
  schema?: Anthropic.Tool.InputSchema;
  /** Also send the page's visible innerText (up to ~12 KB) alongside the ARIA
   *  snapshot. Off by default to keep token use down — opt in for content
   *  assertions that need free text the accessibility tree may not expose. */
  includeText?: boolean;
}

const DEFAULT_EXTRACT_SCHEMA: Anthropic.Tool.InputSchema = {
  type: "object",
  properties: {
    value: { type: "boolean" },
    evidence: {
      type: "string",
      description: "Brief quote/observation supporting the answer",
    },
  },
  required: ["value"],
};

/** Answer a question about the current page as structured data. */
export async function extract<T = { value: boolean; evidence?: string }>(
  page: Page,
  instruction: string,
  opts: ExtractOptions = {}
): Promise<T> {
  const schema = opts.schema ?? DEFAULT_EXTRACT_SCHEMA;
  const snapshot = await ariaSnapshot(page);

  let text = "";
  if (opts.includeText === true) {
    text = truncate(await page.locator("body").innerText().catch(() => ""));
  }

  const tool: Anthropic.Tool = {
    name: "return_result",
    description:
      "Return the answer to the question using only what is observable on the page.",
    input_schema: schema,
  };

  const message = await getClient().messages.create({
    model: MODEL,
    max_tokens: 1024,
    tools: [tool],
    tool_choice: { type: "tool", name: "return_result" },
    system:
      "You inspect a web page and answer strictly from what is visible. Do " +
      "not assume facts that are not present in the snapshot or text. If the " +
      "answer is a boolean, only return true when the evidence is clear.",
    messages: [
      {
        role: "user",
        content:
          `Question/instruction: ${instruction}\n\n` +
          `Current URL: ${page.url()}\n\n` +
          `Accessibility snapshot:\n${snapshot}\n\n` +
          `Visible text:\n${text}`,
      },
    ],
  });

  return toolUseInput<T>(message, `extract("${instruction}")`);
}
