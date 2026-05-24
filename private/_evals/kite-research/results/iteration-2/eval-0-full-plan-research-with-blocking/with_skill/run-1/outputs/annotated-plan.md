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
| 2 | S2 | View someone's public profile  | researched |
| 3 | S3 | Order confirmation on checkout | blocked    |

## Scenario S1 -- View own account
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
- S1.RQ1 -> EXISTS: `requireAuth` in `src/middleware/auth.ts:7` rejects unauthenticated requests and attaches the resolved user id to `req.userId`; it is already used by the account routes in `src/routes/account.ts:9` and `src/routes/account.ts:15`. Reuse it on authenticated account endpoints.
- Reuse constraints for S1.RQ1: `requireAuth` expects a bearer token in the `Authorization` header and exposes the user id on the request object; handlers that need the caller id must run after this middleware.
- S1.RQ2 -> EXISTS: `getUserById` in `src/users/service.ts:7` fetches the full user record by primary key. It can be reused as-is for the authenticated caller's own account record, and the existing `GET /account` handler already does this in `src/routes/account.ts:9`.
- Reuse constraints for S1.RQ2: `getUserById` performs no authorization check itself, so callers must authenticate before invoking it. It returns `User | null`, so any new handler should decide how to handle a missing user record rather than assuming a non-null result.

## Scenario S2 -- View someone's public profile
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
- S2.RQ1 -> MISSING: no username-based lookup function exists in the provided user service. The nearest existing function is `getUserById` in `src/users/service.ts:7`, but it is id-based, not username-based. Add a new username lookup service function in `src/users/service.ts` alongside `getUserById`.
- Reuse constraints for S2.RQ1: do not adapt `getUserById` for username lookup; the query and lookup key are different. The public profile response should also avoid returning the full private account record unless a typed public-profile shape is introduced or reused.
- S2.RQ2 -> MISSING: no public profile route exists. The existing routes in `src/routes/account.ts:9` and `src/routes/account.ts:15` are account-scoped and auth-gated with `requireAuth`. Add a new public profile route under `src/routes/`, preferably a separate profile route module alongside `src/routes/account.ts`, and omit `requireAuth` from the public GET handler.
- Reuse constraints for S2.RQ2: keep the new route as a thin HTTP adapter: parse the username, delegate to the new user service lookup, and shape only public fields. If the real route registry requires explicit wiring, register the new router the same way the account router is registered.

## Scenario S3 -- Order confirmation on checkout
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
- S3.RQ1 -> BLOCKING: there is no synchronous order-confirmation sender. The existing notification function is `queueOrderConfirmation` in `src/notifications/notifier.ts:7`, and the notifier explicitly states that notifications are asynchronous-only in `src/notifications/notifier.ts:4`. This contradicts the plan's requirement for checkout to await delivery and include a delivery result inline.
- Reuse constraints for S3.RQ1: `queueOrderConfirmation` can enqueue work but cannot prove delivery to the checkout handler. The planner must re-plan this scenario before implementation, either around the async queue behavior or around a deliberate notification architecture change.
- S3.RQ2 -> BLOCKING: the `Order` interface in `src/orders/schema.ts:4` does not carry a customer email address, and `src/orders/schema.ts:2` says the order intentionally has no `email` column because contact details are resolved from the user record. This contradicts the plan's precondition that the order record has the customer's contact email.
- Reuse constraints for S3.RQ2: implementation cannot read an email from `Order` as currently defined. The planner must decide whether checkout should resolve contact details through `userId` or whether the data model/design must change before this scenario can proceed.
