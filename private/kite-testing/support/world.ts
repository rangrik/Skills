import {
  World,
  IWorldOptions,
  setWorldConstructor,
} from "@cucumber/cucumber";
import {
  chromium,
  type Browser,
  type BrowserContext,
  type Page,
} from "@playwright/test";
import { existsSync } from "node:fs";
import { authFileFor, getBaseURL, HEADLESS } from "./config";
import { act, extract, type ExtractOptions } from "./agent";

export interface ScenarioParameters {
  baseUrl?: string;
}

/**
 * Per-scenario world. Owns a headless Chromium context that starts from a
 * cached authenticated session (when a role is supplied), and exposes the
 * agentic `act` / `extract` helpers bound to the current page.
 */
export class ScenarioWorld extends World<ScenarioParameters> {
  browser?: Browser;
  context?: BrowserContext;
  page!: Page;
  baseUrl: string;
  lastExtract: unknown;

  constructor(options: IWorldOptions<ScenarioParameters>) {
    super(options);
    this.baseUrl = this.parameters?.baseUrl || getBaseURL();
  }

  /** Launch a browser context. Pass a role to start authenticated from its
   *  cached session; omit it for an anonymous (logged-out) context. */
  async open(role?: string): Promise<void> {
    this.browser = await chromium.launch({ headless: HEADLESS });

    let storageState: string | undefined;
    if (role) {
      const stateFile = authFileFor(role);
      // The Before hook calls ensureAuth(role) first, so the file must exist.
      // If it doesn't, fail loudly instead of silently running logged-out.
      if (!existsSync(stateFile)) {
        throw new Error(
          `No cached session for role "${role}" at ${stateFile}. ` +
            `ensureAuth("${role}") should have created it — check the auth logs.`
        );
      }
      storageState = stateFile;
    }

    this.context = await this.browser.newContext({
      baseURL: this.baseUrl,
      ignoreHTTPSErrors: true,
      ...(storageState ? { storageState } : {}),
    });
    this.page = await this.context.newPage();
  }

  async close(): Promise<void> {
    await this.context?.close().catch(() => {});
    await this.browser?.close().catch(() => {});
  }

  /** Perform a natural-language action on the current page. */
  act(instruction: string, opts?: { timeout?: number }): Promise<void> {
    return act(this.page, instruction, opts);
  }

  /** Answer a question about the current page as structured data. */
  async extract<T = { value: boolean; evidence?: string }>(
    instruction: string,
    opts?: ExtractOptions
  ): Promise<T> {
    const result = await extract<T>(this.page, instruction, opts);
    this.lastExtract = result;
    return result;
  }
}

setWorldConstructor(ScenarioWorld);
