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

  # --- 7.1 Incomplete or invalid input ---

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

  # --- 7.2 Duplicate submission / retry of a completed action ---

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

  # --- 7.3 Rate limits, quotas, throttling ---

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

  # --- 7.4 Connectivity loss and interruption ---

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

  # --- 7.5 Abandonment and resumption ---

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

  # --- 7.6 Out-of-order actions and navigation ---

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

  # --- 7.7 Authentication and permission changes mid-flow ---

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

  # --- 7.8 Concurrency and stale data ---

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

  # --- 7.9 Precondition already satisfied / state conflict ---

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

  # --- 7.10 Empty, boundary, and scale extremes ---

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

  # --- 7.11 Environment and device capability ---

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

  # --- 7.12 External dependency failure ---

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

  # --- 7.13 Time, expiry, and scheduling ---

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

  # --- 7.14 Adversarial and abuse input ---

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
