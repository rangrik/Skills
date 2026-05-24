# Implementation Plan: Public user profiles & order confirmations

## Feature
- Blueprint: docs/blueprints/public-profiles.md
- System design: docs/design/public-profiles.md
- Summary: Let visitors view a public profile page for any user by username, let
  the owner edit their own profile, and send an order confirmation when an order
  is placed.

## Research scope
- Reviewed the provided target repository files:
  - `src/users/service.ts`
  - `src/routes/account.ts`
  - `src/middleware/auth.ts`
  - `src/orders/schema.ts`
  - `src/notifications/notifier.ts`
- No source code from fixtures is copied here; findings cite symbols and file:line locations only.

## Scenario order & status
| # | ID | Title                          | Status     |
|---|----|--------------------------------|------------|
| 1 | S1 | View own account               | researched |
| 2 | S2 | View someone's public profile  | researched |
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
- S1.RQ1: Yes. `requireAuth` in `src/middleware/auth.ts:7` rejects unauthenticated requests and attaches the authenticated user id to the request at `src/middleware/auth.ts:13`. The existing account route already uses it for authenticated account reads at `src/routes/account.ts:9`.
- S1.RQ2: Yes. `getUserById` in `src/users/service.ts:7` fetches the full user record by primary key. It is reusable as-is for authenticated own-account reads because the function explicitly assumes authentication happens before the service call, and the account route already composes it with `requireAuth` at `src/routes/account.ts:9` and `src/routes/account.ts:10`.

### Implementation notes
- The existing `GET /account` route already appears to satisfy this scenario: it is registered in `src/routes/account.ts:9`, uses `requireAuth`, calls `getUserById`, and returns the resulting user record.
- No new blocker found for S1.

## Scenario S2 - View someone's public profile
- Order: 2
- Type: happy_path
- Status: researched
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
- S2.RQ1: No. `src/users/service.ts` currently exposes `getUserById` at `src/users/service.ts:7` and `updateUserProfile` at `src/users/service.ts:13`, but no username-based lookup function is present in the provided user service.
- S2.RQ2: No existing public profile route is present. The only provided route module is `src/routes/account.ts`, and both existing `/account` routes are authenticated through `requireAuth` at `src/routes/account.ts:9` and `src/routes/account.ts:15`. A new unauthenticated public profile route should be added under `src/routes` as a separate public profile route module, following the same Express `Router` module pattern used by `src/routes/account.ts:6`. It should not use `requireAuth`.

### Implementation notes
- Add a username-based user service lookup near the existing user service functions in `src/users/service.ts`.
- Add a public route under `src/routes`, separate from authenticated account routes, that calls the username lookup and returns only public profile fields.
- The provided files do not include the `User` type definition or route registration/bootstrap file, so the exact list of public fields and the registration point for the new route must be confirmed during implementation.
- No hard blocker found for S2; required capabilities are missing but can be added in the natural service and route locations.

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
- S3.RQ1: No. The notification implementation is asynchronous-only. `queueOrderConfirmation` in `src/notifications/notifier.ts:7` enqueues an order confirmation job and returns no delivery result to the caller. The file-level notification notes at `src/notifications/notifier.ts:4`, `src/notifications/notifier.ts:5`, and `src/notifications/notifier.ts:6` explicitly state that callers cannot block on or read delivery results inline.
- S3.RQ2: No. The `Order` interface in `src/orders/schema.ts:4` includes `id`, `userId`, `status`, `totalCents`, and `createdAt`, but it has no customer email field. The schema notes at `src/orders/schema.ts:2` and `src/orders/schema.ts:3` explicitly say contact details are resolved from the user record instead of the user-facing order.

### Blocking notes
- This scenario is blocked against the current design requirement because both required preconditions are contradicted by the provided codebase:
  - Notification delivery is queue-based and cannot provide an inline delivery result.
  - The order record does not carry the customer's email address.
- To unblock S3, the product/design decision needs to change in one of two directions:
  - Keep the existing asynchronous notification architecture and change the checkout behavior so it reports enqueue success instead of confirmed email delivery.
  - Or approve a larger architecture/schema change that introduces synchronous email delivery with a readable delivery result and a defined source for the customer's email during checkout.
