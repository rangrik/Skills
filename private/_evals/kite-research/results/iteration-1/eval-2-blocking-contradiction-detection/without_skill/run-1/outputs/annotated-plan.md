# Implementation Plan: Public user profiles & order confirmations

## Feature
- Blueprint: docs/blueprints/public-profiles.md
- System design: docs/design/public-profiles.md
- Summary: Let visitors view a public profile page for any user by username, let
  the owner edit their own profile, and send an order confirmation when an order
  is placed.

## Scenario order & status
| # | ID | Title                          | Status  |
|---|----|--------------------------------|---------|
| 1 | S1 | View own account               | planned |
| 2 | S2 | View someone's public profile  | planned |
| 3 | S3 | Order confirmation on checkout | blocked |

## Scenario S1 — View own account
- Order: 1
- Type: happy_path
- Status: planned
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

## Scenario S2 — View someone's public profile
- Order: 2
- Type: happy_path
- Status: planned
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

## Scenario S3 — Order confirmation on checkout
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
- S3.RQ1: No. The only order-confirmation notification capability found in the fixture is `queueOrderConfirmation(orderId)` at `src/notifications/notifier.ts:7`. It enqueues an `order-confirmation` job at `src/notifications/notifier.ts:8` and returns `Promise<void>`, not a delivery result. The notifier explicitly documents that notifications are asynchronous-only and that callers cannot block on or read delivery results inline at `src/notifications/notifier.ts:4` through `src/notifications/notifier.ts:6`. This directly contradicts the design requirement for checkout to synchronously send the email and include the delivery result in the response.
- S3.RQ2: No. The persisted order shape is defined by `Order` at `src/orders/schema.ts:4`, and its fields are `id`, `userId`, `status`, `totalCents`, and `createdAt` at `src/orders/schema.ts:5` through `src/orders/schema.ts:9`. The schema notes that the order intentionally has no email column and that contact details are resolved from the user record at `src/orders/schema.ts:2` through `src/orders/schema.ts:3`. `getUserById(id)` exists at `src/users/service.ts:7`, but that only means an implementation would need to resolve contact details through the user path; it does not satisfy the plan's precondition that the order itself carries the customer's email address.

### Implementation note
S3 cannot be implemented as written. The written design depends on two capabilities that the current codebase deliberately does not provide: synchronous email delivery with an inline delivery result, and a customer email field on the order record. Implementing the scenario requires changing the design to match the existing asynchronous notification model, or changing the notification/order architecture first. A straightforward implementation of the current plan would either return before delivery is known or invent a new synchronous delivery path that conflicts with `src/notifications/notifier.ts`.
