# Behavior Spec: Forgot Password / Password Reset Flow

**Status:** Draft for engineering & QA review
**Last updated:** 2026-05-22
**Owner:** Product

---

## 1. Summary

Users who cannot remember their password currently have to email support to regain access. This spec defines a self-service password reset flow: the user requests a reset from the login page, receives an email with a time-limited reset link, sets a new password, and is logged in and returned to their dashboard.

## 2. Goals

- Let users reset their own password without contacting support.
- Keep the flow secure against account enumeration, link reuse, and brute force.
- Get the user back to a working, logged-in state with minimal friction.

## 3. Non-Goals

- Multi-factor authentication changes.
- Username recovery ("forgot email").
- Admin-initiated password resets.
- Social / SSO account password handling (see Section 9, Edge Cases).

## 4. Glossary

| Term | Meaning |
|---|---|
| Reset token | A single-use, cryptographically random secret embedded in the reset link. |
| Reset request | The action of submitting an email address on the "Forgot password" page. |
| Active session | A logged-in browser session with valid auth credentials/cookies. |

---

## 5. Happy Path

1. On the **login page**, the user sees a **"Forgot password?"** link.
2. The user clicks it and lands on the **"Forgot password" page** with a single email input and a **"Send reset link"** button.
3. The user enters the email associated with their account and submits.
4. The system shows a **confirmation message**: "If an account exists for that email, we've sent a reset link."
5. The user receives an **email** containing a reset link valid for a limited time.
6. The user clicks the link and lands on the **"Set new password" page**.
7. The user enters a **new password** and **confirms it** in a second field.
8. The user submits. The system validates and saves the new password.
9. The user is **automatically logged in** and **redirected to their dashboard**, with a brief success confirmation.

---

## 6. Detailed Behavior by Screen

### 6.1 Login Page — "Forgot password?" link

- A "Forgot password?" link is visible on the login page, placed near the password field.
- Clicking it navigates to the "Forgot password" page.
- If the user typed an email into the login form before clicking, that email is pre-filled on the next page (nice-to-have, not required).

### 6.2 "Forgot password" Page (request reset)

**Inputs**
- Email address (single text field).
- "Send reset link" button.
- A "Back to login" link.

**On submit**
- Validate the email is well-formed (contains a local part, `@`, and a domain). If not, show an inline error: "Enter a valid email address." Do not submit.
- If well-formed, send the request to the server.
- Regardless of whether an account exists, show the **same generic confirmation**: "If an account exists for that email, we've sent a reset link with instructions."
  - This prevents account enumeration — an attacker must not be able to tell whether an email is registered.
- The button enters a loading state during the request and is disabled to prevent double-submit.

**Server behavior**
- If an account exists for the email:
  - Generate a new reset token, store its hash with an expiry timestamp, and invalidate any previously issued unused tokens for that account.
  - Send the reset email.
- If no account exists: do nothing (but still return success to the client).
- Rate-limit requests per email and per IP (see Section 8).

### 6.3 Reset Email

- Subject: e.g. "Reset your [App] password".
- Body clearly states the link is for resetting the password and will expire (state the duration, e.g. 1 hour).
- Contains one primary call-to-action button/link to the "Set new password" page, carrying the reset token.
- Includes a safety line: "If you didn't request this, you can ignore this email — your password won't change."
- Links to support in case of trouble.

### 6.4 "Set new password" Page

**On page load — token validation**
- The page validates the token before showing the form.
- If the token is **valid and unexpired**: show the new-password form.
- If the token is **invalid, already used, or expired**: show an error state with a clear message and a button to **request a new reset link** (returns to 6.2).

**Form inputs**
- New password field (masked, with a show/hide toggle).
- Confirm password field (masked).
- "Reset password" button.

**Validation (on submit)**
- New password must meet password policy. Default policy (adjust to match existing app policy):
  - Minimum 8 characters.
  - Not identical to a small set of obvious weak values, and ideally not the user's previous password.
- New password and confirm password must match. If not, inline error: "Passwords don't match."
- Show password requirements inline so the user knows them before submitting.
- Errors are shown inline without losing field focus context; the form is not cleared on error.

**On successful submit**
- Server re-validates the token (it may have expired between page load and submit).
- Server updates the password, marks the token as used, and invalidates all other unused reset tokens for the account.
- The user is **logged in** (a fresh session is created) and **redirected to the dashboard**.
- A brief success confirmation is shown (e.g., a toast: "Your password has been updated.").

### 6.5 Dashboard (post-reset)

- The user lands on their normal dashboard, fully authenticated.
- No further action is required from the user.

---

## 7. Security Requirements

1. **No account enumeration.** The request-reset response and timing must be identical whether or not the email is registered.
2. **Token properties.** The reset token must be:
   - Cryptographically random with sufficient entropy.
   - Single-use — invalidated immediately after a successful reset.
   - Time-limited — expires after a fixed window (default: 1 hour).
   - Stored hashed at rest, not in plaintext.
3. **One active token per account.** Issuing a new reset link invalidates prior unused links for that account.
4. **Invalidate sessions.** On a successful password change, invalidate all other active sessions for that account (force re-login elsewhere). The session used to complete the reset becomes the new active session.
5. **Password hashing.** The new password is stored using the app's standard secure password hashing.
6. **Notification email.** After a successful password change, send a confirmation email to the account: "Your password was changed. If this wasn't you, contact support immediately."
7. **HTTPS only.** All reset pages and links must be served over HTTPS.
8. **No sensitive data in URLs beyond the token.** The token is the only secret in the link; do not include the email or user ID in a way that leaks identity.

## 8. Rate Limiting & Abuse Prevention

- Limit reset requests per email address (e.g., a small number per hour) — additional requests still return the generic success message but do not send more emails.
- Limit reset requests per IP address to prevent mass enumeration/spam.
- Limit reset-submit attempts per token to prevent brute forcing a weak token.
- Consider a CAPTCHA or equivalent challenge if abuse thresholds are exceeded.

---

## 9. Edge Cases

| # | Scenario | Expected behavior |
|---|---|---|
| 1 | Email not associated with any account | Generic success message shown; no email sent. |
| 2 | Email field empty or malformed | Inline validation error; no request sent. |
| 3 | User requests multiple reset links | Only the most recent link works; older links are invalidated. |
| 4 | User clicks an expired link | "Set new password" page shows expired state with a "Request a new link" action. |
| 5 | User clicks an already-used link | Same as expired — link no longer valid; offer to request a new one. |
| 6 | User clicks a malformed/tampered token | Invalid-token error state; offer to request a new one. |
| 7 | New password fails policy | Inline error listing the requirement(s) not met; form retains entered data. |
| 8 | New password and confirmation don't match | Inline "Passwords don't match" error. |
| 9 | New password equals current password | Reject with a clear message: "New password must be different from your old password." |
| 10 | Token expires while the user is on the "Set new password" page | On submit, server rejects; page shows expired state with "Request a new link". |
| 11 | User is already logged in and clicks a reset link | Allow the reset to proceed; on success, replace the session and go to dashboard. |
| 12 | User account is locked, suspended, or deleted | Do not send a reset email (or, on submit, reject with guidance to contact support). Still show the generic success message at request time. |
| 13 | Account uses SSO / social login only (no password) | Do not send a standard reset email. Optionally email the user explaining they sign in via their identity provider. Still show generic success message. |
| 14 | Email delivery fails downstream | User still sees the generic success message; system logs the failure and retries per the email provider's policy. |
| 15 | User opens the reset link on a different device/browser than where they requested it | Allowed — the flow does not require the same device. |
| 16 | Network error during request or submit | Show a non-destructive error ("Something went wrong, please try again"); entered data is preserved; the user can retry. |
| 17 | User navigates directly to the "Set new password" page with no token | Treat as invalid token; show error state with "Request a new link". |

---

## 10. Acceptance Criteria (Gherkin)

```gherkin
Feature: Forgot password / password reset

  Background:
    Given the user has a registered account with email "user@example.com"

  Scenario: User sees the forgot password link on the login page
    Given the user is on the login page
    Then a "Forgot password?" link is visible

  Scenario: Requesting a reset for a registered email
    Given the user is on the "Forgot password" page
    When the user enters "user@example.com"
    And submits the request
    Then a generic confirmation message is shown
    And a reset email is sent to "user@example.com"

  Scenario: Requesting a reset for an unregistered email
    Given the user is on the "Forgot password" page
    When the user enters "nobody@example.com"
    And submits the request
    Then the same generic confirmation message is shown
    And no reset email is sent

  Scenario: Submitting an invalid email format
    Given the user is on the "Forgot password" page
    When the user enters "not-an-email"
    And submits the request
    Then an inline validation error is shown
    And no request is sent to the server

  Scenario: Completing a reset with a valid link
    Given the user has received a valid, unexpired reset link
    When the user opens the link
    Then the "Set new password" page is shown
    When the user enters a policy-compliant new password
    And confirms it with the same value
    And submits
    Then the password is updated
    And the user is logged in
    And the user is redirected to the dashboard
    And a success confirmation is shown

  Scenario: Mismatched password confirmation
    Given the user is on the "Set new password" page with a valid link
    When the user enters "NewPass123" as the new password
    And enters "NewPass124" as the confirmation
    And submits
    Then a "passwords don't match" error is shown
    And the password is not changed

  Scenario: New password fails the password policy
    Given the user is on the "Set new password" page with a valid link
    When the user enters a password that violates the policy
    And submits
    Then a validation error describing the unmet requirement is shown
    And the password is not changed

  Scenario: Using an expired reset link
    Given the user has a reset link that has expired
    When the user opens the link
    Then an expired-link error state is shown
    And a "Request a new link" action is available

  Scenario: Using an already-used reset link
    Given the user has already completed a reset using a link
    When the user opens the same link again
    Then an invalid/used-link error state is shown
    And a "Request a new link" action is available

  Scenario: Requesting a new link invalidates the old one
    Given the user requested a reset link
    When the user requests another reset link
    And then opens the first link
    Then the first link is no longer valid

  Scenario: Other sessions are invalidated after a reset
    Given the user is logged in on another device
    When the user completes a password reset
    Then the session on the other device is no longer valid

  Scenario: Confirmation email after a successful reset
    Given the user completes a password reset
    Then a "your password was changed" email is sent to the account

  Scenario: Token expires while on the set-new-password page
    Given the user is on the "Set new password" page with a valid link
    And the token expires before submission
    When the user submits a new password
    Then an expired-link error state is shown
    And the password is not changed
```

---

## 11. Open Questions for Eng / Product

1. **Token lifetime:** Default proposed is 1 hour. Confirm the desired window.
2. **Password policy:** This spec assumes the app's existing password policy. Confirm minimum length and any complexity rules so QA can test exact boundaries.
3. **Session invalidation scope:** Should completing a reset log the user out everywhere (recommended) or only on the device used? Default here: log out everywhere.
4. **SSO-only accounts:** Should we email these users an explanation, or silently do nothing? Default: silently honor the generic message; emailing is optional.
5. **Rate-limit thresholds:** Exact per-email and per-IP limits need to be set with the security/infra team.
6. **CAPTCHA:** Whether to add a challenge to the request form by default or only on abuse signals.
7. **Auto-login after reset:** This spec assumes the user is logged in automatically. Confirm — some teams prefer routing the user to the login page to sign in with the new password. Default here: auto-login.
8. **Locked/suspended accounts:** Confirm desired messaging when such an account attempts a reset.
```
