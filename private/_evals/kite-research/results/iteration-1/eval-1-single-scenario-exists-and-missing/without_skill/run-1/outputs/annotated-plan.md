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
| 1 | S1 | View own account               | planned    |
| 2 | S2 | View someone's public profile  | researched |
| 3 | S3 | Order confirmation on checkout | planned    |

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

### Research findings
- S2.RQ1 — Status: researched. No existing username lookup function is present in the provided user service. `src/users/service.ts:7` has the existing id-based user lookup, and `src/users/service.ts:13` has the existing mutable profile update path; neither is a username lookup. Implementation needs a new user-service function for lookup by public username.
- S2.RQ2 — Status: researched. No existing public profile route is present in the provided route file. `src/routes/account.ts:9` and `src/routes/account.ts:15` are account routes that use the auth middleware from `src/middleware/auth.ts:7`, so they are not the unauthenticated visitor route required for S2. Add the new public profile route in the routing layer next to `src/routes/account.ts` or in a new sibling profile/user route module, depending on local route registration conventions; the S2 route should omit `requireAuth` and call the new username lookup.

### Implementation note
- Research is complete for S2, but implementation is blocked on adding both missing capabilities: a user-by-username service lookup and a public unauthenticated route that serves only public profile fields.

## Scenario S3 — Order confirmation on checkout
- Order: 3
- Type: happy_path
- Status: planned
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
