# Behavior Spec: Invite Teammates by Email

**Status:** Draft · **Date:** 2026-05-22

## 1. Problem & Intent

A workspace is only useful once a team is in it, but today there is no in-product way for
a workspace admin to bring teammates aboard. This feature lets a workspace admin invite
one or more people by email address from the Members settings page; each invitee receives
an invitation email and joins the workspace by accepting it. The primary success outcomes
are: (a) an invitation is recorded and an email is delivered for each invited address,
and (b) an invitee who accepts ends up inside the workspace as a member — whether they
already had an account or had to create one.

## 2. Actors

- **Workspace admin** — the primary user; initiates the flow by sending invitations.
- **Invitee** — the person who receives an invitation email and accepts it. May be a
  brand-new user (no account) or an existing user (already has an account).
- **System** — the product; validates input, records invitations, sends email, enforces
  limits, and adds accepted invitees to the workspace.
- **Email provider** — the external service that delivers invitation emails.

## 3. Glossary

| Term | Definition |
|------|------------|
| Workspace | The shared team account that members belong to and work within. |
| Admin | A workspace member with the permission to invite, manage, and remove members. |
| Member | A person who has accepted an invitation and now has access to the workspace. |
| Invitee | A person who has been sent an invitation but has not yet accepted it. |
| Invitation | A pending record linking one email address to one workspace, carrying a unique accept token and an expiry. |
| Pending invitation | An invitation that has been sent but not yet accepted, revoked, or expired. |
| Accept link / token | The unique, single-purpose URL embedded in the invitation email that an invitee uses to accept. |
| Existing user | A person who already has a product account under the invited email address. |
| New user | A person with no product account under the invited email address. |
| Send | The action of submitting the invite form, which creates invitation records and dispatches emails. |

## 4. Preconditions & Assumptions

**Preconditions**

- The admin is signed in and has a confirmed admin role in the target workspace.
- The workspace exists and is in good standing (not suspended, not over a hard seat cap
  that blocks all invites — seat limits are handled as a deviation, not a precondition).
- The product can reach a working email provider.

**Standing assumptions**

- Email addresses uniquely identify a person within the product; one address maps to at
  most one account.
- Invitations are workspace-scoped: an invitation grants access to exactly one workspace.
- Invitation accept links are time-limited (see flagged assumption A6 for the default
  window).
- Newly invited members join with a default non-admin "member" role unless a role was
  explicitly chosen at invite time (role selection itself is out of scope — see Section 5).

## 5. Scope

**In scope**

- Navigating to the Members settings page and opening the invite UI.
- Entering one or more email addresses and sending invitations.
- Validation of entered email addresses.
- Delivery of invitation emails and the accept flow.
- New invitees creating an account; existing invitees signing in; both joining the
  workspace.
- Deviations across all enumerated taxonomy categories for the above.

**Out of scope**

- Choosing or customizing the invitee's role/permissions at invite time (assumed default
  "member"; flagged where it interacts with behavior).
- Managing existing members (editing roles, removing members) after they have joined.
- Bulk invitation by CSV upload or directory/SSO sync.
- Resending or revoking a pending invitation from the Members page (noted as a desirable
  follow-up; this spec covers initial send and accept only).
- Billing and seat-purchase flows beyond the seat-limit message shown at invite time.

## 6. Happy-Path Scenarios

The intended flow, confirmed from the feature description. There are two legitimate ways
an invitee succeeds — as a new user and as an existing user — and both are happy paths.

```gherkin
Feature: Invite Teammates by Email
  Workspace admins grow their team by inviting people by email; invitees accept the
  emailed invitation and join the workspace as members.

  Background:
    Given a workspace exists
    And the admin is signed in with an admin role in that workspace

  @happy-path
  Scenario: Admin sends an invitation to a single new email address
    Given the admin is on the Members settings page
    When the admin opens the invite dialog, enters one valid email address, and sends it
    Then a pending invitation is created for that address
    And an invitation email is sent to that address
    And the invited address appears in the Members list as "Pending"
    And the admin sees a confirmation that the invitation was sent

  @happy-path
  Scenario: Admin sends invitations to several email addresses at once
    Given the admin is on the Members settings page
    When the admin opens the invite dialog, enters three valid email addresses, and sends them
    Then a pending invitation is created for each of the three addresses
    And an invitation email is sent to each of the three addresses
    And all three invited addresses appear in the Members list as "Pending"
    And the admin sees a confirmation that three invitations were sent

  @happy-path
  Scenario: A new user accepts an invitation and joins by creating an account
    Given a pending invitation has been sent to a person with no existing account
    When the invitee clicks "Accept" in the invitation email and creates an account
    Then the invitee's account is created with the invited email address
    And the invitee is added to the workspace as a member
    And the invitation is marked as accepted
    And the invitee lands inside the workspace

  @happy-path
  Scenario: An existing user accepts an invitation and joins by signing in
    Given a pending invitation has been sent to a person who already has an account
    When the invitee clicks "Accept" in the invitation email and signs in
    Then the invitee is added to the workspace as a member
    And the invitation is marked as accepted
    And the invitee lands inside the workspace
```

## 7. Deviation Scenarios

Produced by traversing every atomic step of the happy paths against all 14 taxonomy
categories. Grouped by category.

### 7.1 Incomplete or invalid input

```gherkin
@deviation @invalid-input
Scenario: Sending the invite form with no email addresses entered
  Given the admin has opened the invite dialog
  When the admin presses "Send" without entering any address
  Then no invitation is created
  And the email field is highlighted with the message "Enter at least one email address"
  And the invite dialog stays open

@deviation @invalid-input
Scenario Outline: Entering a malformed email address
  Given the admin has opened the invite dialog
  When the admin enters "<value>" and presses "Send"
  Then no invitation is created for that entry
  And the entry is flagged inline with the message "<message>"
  And any valid addresses entered alongside it remain in the field

  Examples:
    | value             | message                                  |
    | jane@             | Enter a complete email address           |
    | @example.com      | Enter a complete email address           |
    | jane example.com  | Enter a valid email address              |
    | jane@@example.com | Enter a valid email address              |
    | (blank between commas) | Remove the empty entry              |

@deviation @invalid-input
Scenario: Sending a mix of valid and invalid addresses
  Given the admin has opened the invite dialog
  And the admin has entered two valid addresses and one malformed address
  When the admin presses "Send"
  Then the two valid addresses are not sent yet
  And the malformed address is flagged inline with a specific reason
  And the admin can correct or remove the flagged address and send all valid ones together
  And no partial send occurs that would leave the admin unsure which invitations went out

@deviation @invalid-input
Scenario: Entering the same email address twice in one invite form
  Given the admin has opened the invite dialog
  When the admin enters the same valid address twice and presses "Send"
  Then only one invitation is created for that address
  And the admin is shown that the duplicate entry was merged, not sent twice
```

### 7.2 Duplicate submission / retry of a completed action

```gherkin
@deviation @duplicate-retry
Scenario: Admin clicks Send twice on a slow connection
  Given the admin has entered valid addresses and pressed "Send"
  And the send request is still in flight
  When the admin presses "Send" a second time
  Then no second set of invitations is created
  And the "Send" control is disabled or shows progress until the first request resolves
  And the admin sees a single confirmation once the send completes

@deviation @duplicate-retry
Scenario: Admin re-opens the invite dialog and re-sends the same addresses
  Given the admin already has pending invitations out to two addresses
  When the admin opens the invite dialog and enters those same two addresses again
  Then no duplicate pending invitation is created for either address
  And the admin is told an invitation is already pending for those addresses
  And the admin is offered the option to resend (refresh) the existing invitation instead

@deviation @duplicate-retry
Scenario: Invitee clicks the Accept link a second time after already joining
  Given the invitee has already accepted the invitation and is a member
  When the invitee clicks the same "Accept" link again
  Then no duplicate membership is created
  And the invitee is taken straight into the workspace they already belong to
  And no error is shown for the repeated click
```

### 7.3 Rate limits, quotas, throttling

```gherkin
@deviation @rate-limit @assumption
Scenario: Admin exceeds the hourly invitation limit
  # Assumption: a per-admin hourly invitation cap exists to limit abuse; default value TBD.
  Given the admin has reached the hourly limit for invitations sent
  When the admin attempts to send another invitation
  Then the invitation is not sent
  And the admin is told the hourly invite limit was reached and when they can send again
  And invitations already sent this hour remain valid

@deviation @rate-limit @assumption
Scenario: Inviting more people than the workspace has available seats
  # Assumption: the workspace has a seat/member quota tied to its plan; behavior at the
  # cap is to block and explain rather than to silently auto-upgrade billing.
  Given the workspace has 2 unused seats remaining
  When the admin tries to send 5 invitations at once
  Then no invitations are sent
  And the admin is told the workspace has only 2 seats left and is shown how to add seats
  And the admin can reduce the list to 2 addresses and send, or upgrade the plan

@deviation @rate-limit @assumption
Scenario: Many invitations sent in one batch
  # Assumption: a single batch is capped (default 50 addresses) to keep sends reliable.
  Given the admin has entered more addresses in one form than the per-batch limit allows
  When the admin presses "Send"
  Then the admin is told the per-send limit and how many addresses they entered
  And no invitations are sent until the list is within the limit
  And the addresses the admin entered remain in the field for trimming
```

### 7.4 Connectivity loss and interruption

```gherkin
@deviation @connectivity
Scenario: Connectivity drops while the admin is sending invitations
  Given the admin has entered valid addresses and pressed "Send"
  And the network connection drops before a response is received
  When connectivity is restored
  Then the admin is told the send did not complete
  And the entered addresses are still present so the admin can retry
  And the retry does not create duplicate invitations for any address that did go out

@deviation @connectivity
Scenario: Invitee loses connectivity while accepting the invitation
  Given the invitee has clicked "Accept" and is partway through joining
  And the network connection drops before the join completes
  When connectivity is restored and the invitee retries
  Then the invitee is either fully joined or not joined at all, never half-joined
  And the invitee can complete acceptance using the same accept link
```

### 7.5 Abandonment and resumption

```gherkin
@deviation @abandon-resume
Scenario: Admin closes the invite dialog before sending
  Given the admin has typed several addresses into the invite dialog
  When the admin closes the dialog without sending
  Then no invitations are created
  And on re-opening the dialog the admin is either shown the previously typed addresses
      restored, or is told the draft was cleared — never silently left guessing

@deviation @abandon-resume @assumption
Scenario: Invitee opens the accept link long after it was sent
  # Assumption: the accept link is valid for a fixed window (see flagged assumption A6).
  Given an invitation was sent and the invitee did not act on it
  When the invitee opens the accept link within the validity window
  Then the invitee can still accept and join the workspace normally
  And if the window has passed, the expired-link behavior in 7.13 applies instead

@deviation @abandon-resume
Scenario: Invitee abandons account creation midway and returns
  Given a new-user invitee clicked "Accept" and started creating an account
  And the invitee left before finishing
  When the invitee returns via the same accept link while it is still valid
  Then the invitee resumes account creation without the invitation being consumed
  And no partial membership exists for an account that was never created
```

### 7.6 Out-of-order actions and navigation

```gherkin
@deviation @out-of-order @assumption
Scenario: A non-admin member opens the invite UI directly
  # Assumption: inviting is restricted to admins; non-admin members cannot invite.
  Given a signed-in member without an admin role
  When the member navigates directly to the invite URL
  Then the invite dialog is not shown in a usable state
  And the member is told that only admins can invite teammates
  And the member is offered a way to ask an admin to invite someone

@deviation @out-of-order
Scenario: Invitee opens the accept link while signed in to a different account
  Given the invitation was addressed to one email address
  And the invitee is signed in under a different account
  When the invitee opens the accept link
  Then the invitee is told which address the invitation is for
  And the invitee is offered the choice to accept as the invited address or switch accounts
  And the invitation is not silently attached to the wrong account

@deviation @out-of-order
Scenario: Admin uses the browser Back button after sending invitations
  Given the admin has just sent invitations and seen the confirmation
  When the admin presses the browser Back button
  Then the admin is not prompted to re-send the same invitations
  And the Members list reflects the invitations that were already sent
```

### 7.7 Authentication and permission changes mid-flow

```gherkin
@deviation @auth-permission
Scenario: Admin's session expires before they press Send
  Given the admin has entered addresses in the invite dialog
  And the admin's session has expired
  When the admin presses "Send"
  Then no invitation is sent under the expired session
  And the admin is prompted to sign in again
  And after signing in, the entered addresses are still present so the admin can send

@deviation @auth-permission @assumption
Scenario: Admin loses their admin role before the send completes
  # Assumption: invite permission is checked server-side at send time, not only when the
  # dialog opened.
  Given the admin opened the invite dialog while still an admin
  And the admin's role was downgraded to member before pressing "Send"
  When the admin presses "Send"
  Then no invitations are sent
  And the admin is told their permission to invite has changed and why
  And the admin is offered a way to contact a current admin

@deviation @auth-permission @assumption
Scenario: A pending invitation's inviting admin is removed before acceptance
  # Assumption: an invitation remains valid even if the admin who sent it later leaves;
  # it is tied to the workspace, not to the inviting admin.
  Given an admin sent an invitation and was then removed from the workspace
  When the invitee opens the accept link
  Then the invitee can still accept and join the workspace
  And the invitation is attributed to the workspace rather than failing
```

### 7.8 Concurrency and stale data

```gherkin
@deviation @concurrency
Scenario: Two admins invite the same person at the same time
  Given two admins each enter the same email address and press "Send" near-simultaneously
  When both send requests are processed
  Then only one pending invitation exists for that address
  And the second admin is told an invitation to that address is already pending
  And no two competing invitations are created for the same address and workspace

@deviation @concurrency
Scenario: Invitee accepts while an admin revokes the same invitation
  Given an invitation is pending
  And an admin revokes that invitation at the same moment the invitee accepts it
  When both actions are processed
  Then the system resolves to one consistent outcome, not a half-joined state
  And if the revoke wins, the invitee is told the invitation is no longer valid and how to request a new one
  And if the accept wins, the admin sees the person as a member rather than as revoked

@deviation @concurrency
Scenario: Admin views a stale Members list and re-invites someone who just joined
  Given the admin's Members list was loaded before an invitee accepted their invitation
  When the admin invites that same address again from the stale view
  Then no duplicate invitation is created
  And the admin is told that person is already a member
  And the Members list refreshes to show the current membership
```

### 7.9 Precondition already satisfied / state conflict

```gherkin
@deviation @state-conflict
Scenario: Inviting someone who is already a member of the workspace
  Given the address "sam@example.com" already belongs to a member of the workspace
  When the admin sends an invitation to "sam@example.com"
  Then no invitation is created for that address
  And the admin is told that person is already a member
  And any other valid addresses in the same form are still sent normally

@deviation @state-conflict
Scenario: Inviting someone who already has a pending invitation
  Given a pending invitation already exists for "lee@example.com" in this workspace
  When the admin sends another invitation to "lee@example.com"
  Then no second pending invitation is created
  And the admin is told an invitation is already pending and when it was sent
  And the admin is offered the option to resend the existing invitation

@deviation @state-conflict @assumption
Scenario: Invitee tries to accept an invitation that was already revoked
  # Assumption: revoked invitations cannot be accepted; the invitee is given a recovery path.
  Given an invitation was revoked by an admin before the invitee acted on it
  When the invitee opens the accept link
  Then the invitee is told the invitation is no longer available
  And the invitee is offered a way to request a new invitation from a workspace admin
  And no membership is created

@deviation @state-conflict
Scenario: Admin invites their own email address
  Given the admin is already a member of the workspace
  When the admin enters their own email address and presses "Send"
  Then no invitation is created for the admin's own address
  And the admin is told they are already a member of this workspace
```

### 7.10 Empty, boundary, and scale extremes

```gherkin
@deviation @boundary
Scenario: Opening the Members page for a workspace with only the admin
  Given the admin is the only member of the workspace
  When the admin opens the Members settings page
  Then the page shows the admin as the sole member
  And a clear empty-team prompt invites the admin to add their first teammate
  And no error or broken layout is shown

@deviation @boundary
Scenario: Sending exactly one invitation
  Given the admin has entered exactly one valid address
  When the admin presses "Send"
  Then the confirmation message is phrased for a single invitation, not pluralized incorrectly

@deviation @boundary @assumption
Scenario: Entering an extremely long email address
  # Assumption: addresses longer than the standard 254-character RFC limit are rejected.
  Given the admin enters an email address longer than the allowed maximum
  When the admin presses "Send"
  Then that address is flagged as too long with a specific message
  And the layout of the invite dialog is not broken by the long value
```

### 7.11 Environment and device capability

```gherkin
@deviation @environment
Scenario: Admin sends invitations from a narrow mobile screen
  Given the admin opens the Members settings page on a narrow mobile viewport
  When the admin opens the invite dialog, enters addresses, and sends them
  Then every control is reachable and usable without horizontal scrolling
  And the invitation flow can be completed end to end

@deviation @environment
Scenario: Invitee opens the accept link in a mobile email client's in-app browser
  Given the invitee opens the invitation email on a phone
  When the invitee taps "Accept" and the link opens in the email app's in-app browser
  Then the accept flow loads and can be completed, or the invitee is guided to open it in a full browser
  And the invitation is not lost if the invitee switches browsers using the same link

@deviation @environment
Scenario: Admin completes the invite flow using only a keyboard and screen reader
  Given the admin navigates the Members page with assistive technology
  When the admin opens the invite dialog, enters addresses, and sends them
  Then every field, the address list, and the "Send" control are reachable and announced
  And validation errors are announced, not only shown visually
```

### 7.12 External dependency failure

```gherkin
@deviation @external-failure @assumption
Scenario: The email provider is unavailable when invitations are sent
  # Assumption: invitation records are created first; email delivery is queued and retried.
  Given the admin sends valid invitations
  And the email provider is unavailable
  Then the pending invitations are still recorded and shown as "Pending"
  And the invitation emails are queued for automatic retry
  And the admin is told delivery may be delayed, without a raw technical error

@deviation @external-failure
Scenario: An invitation email permanently bounces
  Given an invitation was sent to an address that hard-bounces
  When the bounce is reported back to the system
  Then the invitation is marked as undeliverable in the Members list
  And the admin is shown that the email did not reach the recipient
  And the admin can correct the address and resend

@deviation @external-failure @assumption
Scenario: The authentication service is down when an existing invitee tries to sign in
  # Assumption: account sign-in depends on an auth service that can be independently down.
  Given an existing-user invitee clicks "Accept"
  And the authentication service is unavailable
  Then the invitee is told sign-in is temporarily unavailable, not that the invitation is invalid
  And the invitation remains valid so the invitee can accept once the service recovers
```

### 7.13 Time, expiry, and scheduling

```gherkin
@deviation @time-expiry @assumption
Scenario: Invitee opens an accept link after it has expired
  # Assumption: accept links expire after a fixed window (see flagged assumption A6).
  Given an invitation's validity window has passed
  When the invitee opens the accept link
  Then the invitee is told the invitation has expired
  And the invitee can request a fresh invitation from the same screen
  And no membership is created from the expired link

@deviation @time-expiry @assumption
Scenario: Admin resends an invitation that had expired
  # Assumption: resending issues a new link and resets the expiry window.
  Given an invitation to an address has expired
  When the admin resends the invitation to that address
  Then a new accept link with a fresh validity window is issued
  And the previous expired link can no longer be used to join

@deviation @time-expiry
Scenario: Invitee accepts just as the invitation reaches its expiry moment
  Given an invitation is within seconds of its expiry time
  When the invitee submits acceptance right at the boundary
  Then the outcome is deterministic — the invitee is either fully joined or shown the expired-link screen
  And the invitee is never left in an ambiguous state at the boundary
```

### 7.14 Adversarial and abuse input

```gherkin
@deviation @adversarial @assumption
Scenario: Admin enters an address containing a script or HTML payload
  # Assumption: all admin-entered values are validated, sanitized server-side, and escaped on render.
  Given the admin enters a value containing embedded script or HTML in the address field
  When the admin presses "Send"
  Then the value is rejected as an invalid email address rather than executed or stored as markup
  And the script never runs in the invite dialog, the Members list, or any email

@deviation @adversarial @assumption
Scenario: An automated client floods the invite endpoint
  # Assumption: per-admin and per-workspace rate limits plus abuse detection apply to the
  # invite endpoint.
  Given invitation requests arrive far faster than a human could send them
  When the abuse threshold is crossed
  Then further sends are throttled and the actor is told the limit was hit
  And legitimate invitations already accepted remain valid
  And honest admins sending normally are not blocked

@deviation @adversarial @assumption
Scenario: Invitee guesses or tampers with an accept token
  # Assumption: accept tokens are long, random, single-workspace, and not enumerable.
  Given a person fabricates or alters an accept token in the URL
  When they open the tampered link
  Then no workspace membership is granted
  And the response does not reveal whether any real invitation or workspace exists
  And the person is shown a generic "invitation not found" screen

@deviation @adversarial @assumption
Scenario: An invitation email is used to harass the recipient
  # Assumption: invitation emails carry a way to decline and to report the sender, and the
  # product can suppress repeat invitations to an address that declined.
  Given a person receives an unwanted invitation
  When that person chooses to decline or report it from the email
  Then the invitation is marked declined and the recipient can opt out of further invitations
  And the inviting workspace cannot repeatedly re-invite a declined address without limit
```

## 8. Flagged Assumptions

These are the product decisions the spec had to make because the feature description did
not dictate them. Each should be confirmed by the product owner.

| # | Scenario | Assumed behavior | Needs confirmation |
|---|----------|------------------|--------------------|
| A1 | Admin exceeds the hourly invitation limit (7.3) | A per-admin hourly cap on invitations exists. | Should there be an hourly cap, and what value? |
| A2 | Inviting more people than available seats (7.3) | At the seat cap, invites are blocked with an explanation; billing is not auto-upgraded. | Block-and-explain vs. allow-and-bill — which behavior is intended? |
| A3 | Many invitations in one batch (7.3) | A single send is capped at 50 addresses. | Is there a per-batch cap, and what value? |
| A4 | Non-admin member opens the invite UI (7.6) | Only admins can invite; non-admin members cannot. | Is inviting strictly admin-only, or can regular members invite too? |
| A5 | Admin loses admin role before send (7.7) | Invite permission is re-checked server-side at send time. | Confirm permission is enforced at send, not just at dialog open. |
| A6 | Accept link validity (7.5, 7.13) | Accept links expire after a fixed window. | What is the link validity window (e.g., 7, 14, 30 days)? |
| A7 | Inviting admin removed before acceptance (7.7) | A pending invitation stays valid even if the inviting admin leaves. | Should an invitation survive the inviting admin's removal? |
| A8 | Accepting a revoked invitation (7.9) | Revoked invitations cannot be accepted; invitee gets a recovery path. | Confirm revoke makes the link permanently unusable. |
| A9 | Extremely long email address (7.10) | Addresses over 254 characters are rejected. | Confirm the max-length rule and limit. |
| A10 | Email provider unavailable (7.12) | Invitation records are created first; email is queued and retried. | Confirm create-then-queue ordering and retry policy. |
| A11 | Auth service down for existing invitee (7.12) | Sign-in failure is reported distinctly from invitation invalidity. | Confirm the invitation stays valid through an auth outage. |
| A12 | Resending an expired invitation (7.13) | Resend issues a new link and invalidates the old one. | Confirm resend behavior and old-link invalidation. |
| A13 | Script/HTML payload in address field (7.14) | All input is sanitized server-side and escaped on render. | Confirm sanitization/escaping is implemented end to end. |
| A14 | Automated flooding of the invite endpoint (7.14) | Per-admin and per-workspace rate limits plus abuse detection apply. | Confirm abuse controls exist for the invite endpoint. |
| A15 | Token guessing/tampering (7.14) | Accept tokens are long, random, single-workspace, and non-enumerable. | Confirm token design and non-enumerable error responses. |
| A16 | Harassment via invitation email (7.14) | Emails carry decline/report; declined addresses can be suppressed from re-invites. | Confirm decline/report and re-invite suppression are in scope. |

## 9. Coverage Checklist

| # | Deviation category | Covered | Scenarios / Reason if N/A |
|---|--------------------|---------|---------------------------|
| 1 | Incomplete or invalid input | Yes | 4 scenarios (one a Scenario Outline) in 7.1: empty form, malformed addresses, mixed valid/invalid, in-form duplicate. |
| 2 | Duplicate submission / retry | Yes | 3 scenarios in 7.2: double-click Send, re-send same addresses, re-click Accept link. |
| 3 | Rate limits, quotas, throttling | Yes | 3 scenarios in 7.3: hourly cap, seat quota, per-batch cap. |
| 4 | Connectivity loss & interruption | Yes | 2 scenarios in 7.4: drop during send, drop during accept. |
| 5 | Abandonment & resumption | Yes | 3 scenarios in 7.5: closing dialog with draft, delayed accept, abandoned account creation. |
| 6 | Out-of-order actions & navigation | Yes | 3 scenarios in 7.6: non-admin opens invite UI, accept link while signed in elsewhere, Back after send. |
| 7 | Auth & permission changes mid-flow | Yes | 3 scenarios in 7.7: session expiry before send, role downgrade before send, inviting admin removed. |
| 8 | Concurrency & stale data | Yes | 3 scenarios in 7.8: two admins invite same person, accept-vs-revoke race, stale Members list re-invite. |
| 9 | Precondition satisfied / state conflict | Yes | 4 scenarios in 7.9: already a member, already pending, accept a revoked invite, admin invites self. |
| 10 | Empty, boundary & scale extremes | Yes | 3 scenarios in 7.10: solo-member workspace, exactly one invite, over-long address. |
| 11 | Environment & device capability | Yes | 3 scenarios in 7.11: mobile send, in-app email browser, keyboard/screen-reader. |
| 12 | External dependency failure | Yes | 3 scenarios in 7.12: email provider down, hard bounce, auth service down. |
| 13 | Time, expiry & scheduling | Yes | 3 scenarios in 7.13: expired link, resend after expiry, acceptance at the expiry boundary. |
| 14 | Adversarial & abuse input | Yes | 4 scenarios in 7.14: script payload, endpoint flooding, token tampering, harassment via email. |
