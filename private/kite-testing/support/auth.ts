import { expect, type Page } from "@playwright/test";

/**
 * WorkOS AuthKit login, inlined so this tool depends on no Kite source.
 * Selectors mirror Kite's hosted login page:
 *   land → (switch to Sign in) → Email → Continue → Password → "Sign in".
 */
export async function performWorkOSLogin(
  page: Page,
  email: string,
  password: string
): Promise<void> {
  // `/` may render the Kite landing page before redirecting to AuthKit.
  if (!/authkit/i.test(page.url())) {
    const loginLink = page.getByRole("link", { name: /^Login$/i }).first();
    if (await loginLink.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await loginLink.click();
    }
  }

  await expect(page).toHaveURL(/authkit/i, { timeout: 15_000 });
  await page.waitForLoadState("load");

  // AuthKit defaults to the sign-up view; switch to sign-in when offered.
  const signInLink = page.getByRole("link", { name: "Sign in", exact: true });
  if (await signInLink.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await signInLink.click();
    await page.waitForLoadState("load");
  }

  await page.getByRole("textbox", { name: "Email" }).fill(email);
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("textbox", { name: "Password" }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
}

/**
 * Log in via the WorkOS password flow and save the authenticated session to
 * `storageStatePath` for reuse by scenarios.
 */
export async function loginWithPassword(
  page: Page,
  opts: {
    email: string;
    password: string;
    storageStatePath: string;
    logPrefix?: string;
  }
): Promise<void> {
  const { email, password, storageStatePath } = opts;
  const prefix = opts.logPrefix ?? "[Auth]";

  console.log(`${prefix} Logging in via WorkOS as ${email}`);
  await page.goto("/");
  await performWorkOSLogin(page, email, password);

  await page.waitForURL(/^(?!.*workos).*$/, { timeout: 30_000 });
  await expect(page).not.toHaveURL(/authkit/i);
  await expect(page.getByLabel("Open profile menu")).toBeVisible({
    timeout: 30_000,
  });

  console.log(`${prefix} Authenticated as ${email}`);
  await page.context().storageState({ path: storageStatePath });
}
