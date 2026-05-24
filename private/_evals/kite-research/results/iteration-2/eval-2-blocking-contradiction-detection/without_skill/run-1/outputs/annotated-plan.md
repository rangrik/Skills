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
- S3.RQ1: No. The only order-confirmation notification entry point found is `queueOrderConfirmation` in `src/notifications/notifier.ts:7`. That module documents notifications as asynchronous-only at `src/notifications/notifier.ts:4` and says callers cannot block on or read delivery results inline at `src/notifications/notifier.ts:6`. The function enqueues an order-confirmation job at `src/notifications/notifier.ts:8` and exposes no delivery-result value to checkout.
- S3.RQ2: No. The persisted `Order` shape is defined in `src/orders/schema.ts:4`, and its stored fields at `src/orders/schema.ts:5` through `src/orders/schema.ts:9` do not include a customer contact email. The schema note at `src/orders/schema.ts:2` says the order intentionally does not store an email column, with contact details resolved from the user record at `src/orders/schema.ts:3`.

### Implementation verdict
S3 cannot be implemented as written. The design requires synchronous email delivery and an inline delivery result in the checkout response, but the codebase only exposes an asynchronous queue path for order confirmations. The plan also assumes the order record carries the destination email, while the order schema intentionally omits that data. Implementing S3 would require changing the design or introducing new product and architecture decisions, such as accepting queued confirmation semantics, adding a synchronous notification provider contract, or deriving recipient contact details from the user record instead of the order.
