# Implementation Plan: Public user profiles & order confirmations

## Feature
- Blueprint: docs/blueprints/public-profiles.md
- System design: docs/design/public-profiles.md
- Summary: Let visitors view a public profile page for any user by username, let
  the owner edit their own profile, and send an order confirmation when an order
  is placed.

## Scenario order & status
| # | ID | Title                          | Status     |
|---|----|--------------------------------|------------|
| 1 | S1 | View own account               | researched |
| 2 | S2 | View someone's public profile  | blocked    |
| 3 | S3 | Order confirmation on checkout | blocked    |

## Scenario S1 - View own account
- Order: 1
- Type: happy_path
- Status: researched
- Design references: "Authenticated reads go through the existing session layer."

### Gherkin
Given I am a signed-in user
When I open my account page
Then I see my own user record

### Code-blind plan            (written by kite-planner)
- Preconditions: a request can be associated with an authenticated user
- Required capabilities: a way to reject unauthenticated requests; a way to fetch the full user record by the user's id
- Postconditions: the authenticated user's record is returned
- Risks / assumptions: assumes sessions already exist

### Research questions         (written by kite-planner)
- RQ1: Is there an existing mechanism that rejects unauthenticated requests and identifies the calling user? If so, where?
- RQ2: Is there an existing function that fetches the full user record by user id? If so, where, and can it be reused as-is?

### Research answers
- S1.RQ1: Yes. `requireAuth` rejects unauthenticated requests and attaches the resolved user id to the request in `src/middleware/auth.ts:7` and `src/middleware/auth.ts:13`. The account route applies this middleware to the own-account read in `src/routes/account.ts:9`.
- S1.RQ2: Yes. `getUserById` fetches the full user record by id in `src/users/service.ts:7`. It can be reused as-is for this scenario because authentication is handled before it is called; the existing `GET /account` handler already uses `getUserById` with the authenticated request user id in `src/routes/account.ts:10`.

### Implementation notes
- Existing code already satisfies this scenario's core route, auth, and user-fetch capabilities.
- No blocker found for S1.

## Scenario S2 - View someone's public profile
- Order: 2
- Type: happy_path
- Status: blocked
- Design references: "Public profiles are addressable by username, not id."

### Gherkin
Given a user has a public profile
When a visitor opens that user's profile page by username
Then the visitor sees the public profile fields

### Code-blind plan            (written by kite-planner)
- Preconditions: profiles can be looked up by a public-facing username
- Required capabilities: a way to look up a user by username (not id); a public, unauthenticated route that serves a profile by username
- Postconditions: a visitor can view a public profile without signing in
- Risks / assumptions: usernames are unique and stable

### Research questions         (written by kite-planner)
- RQ1: Is there an existing function that looks up a user by username? If so, where?
- RQ2: Is there an existing public (unauthenticated) profile route, and if not, where should a new one be added so it fits the routing structure?

### Research answers
- S2.RQ1: No. `src/users/service.ts` currently exposes `getUserById` at `src/users/service.ts:7` and `updateUserProfile` at `src/users/service.ts:13`; there is no username-based lookup function in the supplied user service.
- S2.RQ2: No. The only supplied route module is `src/routes/account.ts`, and its existing account routes are authenticated with `requireAuth` at `src/routes/account.ts:9` and `src/routes/account.ts:15`. A new public profile route should fit the existing Express Router module pattern shown in `src/routes/account.ts:6`; the clean placement is a new route module under `src/routes` for public profiles, mounted with the rest of the route modules. If the implementation is constrained to the supplied route file only, keep the public profile handler separate from the authenticated `/account` handlers and do not attach `requireAuth`.

### Implementation notes
- S2 is blocked on a missing username lookup capability in the user service.
- S2 is also blocked on a missing unauthenticated public profile route.
- The eventual implementation should return only public profile fields, not the full user record, because the existing full-record fetch is id-based and designed for authenticated own-account access.

## Scenario S3 - Order confirmation on checkout
- Order: 3
- Type: happy_path
- Status: blocked
- Design references: "On checkout the customer must receive a confirmation
  email synchronously, and the checkout response must include the email
  delivery result so the UI can confirm it was sent before returning."

### Gherkin
Given I have placed an order
When checkout completes
Then I receive an order confirmation email and the checkout response reports it was delivered

### Code-blind plan            (written by kite-planner)
- Preconditions: an order exists and has the customer's contact email on it
- Required capabilities: a synchronous send-order-confirmation function the checkout handler can call inline and read the delivery result from; an email field on the order record to send to
- Postconditions: the confirmation email is sent and its delivery result is returned in the checkout response
- Risks / assumptions: assumes email delivery can be awaited inline during checkout

### Research questions         (written by kite-planner)
- RQ1: Is there a synchronous function to send an order confirmation that returns a delivery result the caller can read inline? If so, where?
- RQ2: Does the order record carry the customer's email address to send to? If so, where is it defined?

### Research answers
- S3.RQ1: No. `queueOrderConfirmation` in `src/notifications/notifier.ts:7` only queues an order confirmation and returns no delivery result to the caller. The surrounding notifier notes at `src/notifications/notifier.ts:4` through `src/notifications/notifier.ts:6` indicate notifications are asynchronous and callers cannot read delivery results inline.
- S3.RQ2: No. The `Order` interface in `src/orders/schema.ts:4` contains order id, user id, status, total, and creation timestamp fields, but no customer email field. The schema note at `src/orders/schema.ts:2` through `src/orders/schema.ts:3` says contact details are resolved from the user record rather than stored on the user-facing order.

### Implementation notes
- S3 is blocked by a design/code mismatch: the current notification path is asynchronous-only, while the scenario requires synchronous delivery feedback during checkout.
- S3 is also blocked because the order record does not carry the customer email required by the code-blind plan.
- Before implementation, choose whether to change the product requirement to match the existing async queue model or introduce a new synchronous notification capability and a reliable source for the customer's email.
