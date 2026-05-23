Feature: Forgot Password / Self-Service Password Reset
  Lets a user who has forgotten their password recover access by email, without
  contacting support, and return signed in to their dashboard.

  Background:
    Given the application has a login page with a "Forgot password?" link

  @happy-path
  Scenario: Requesting a reset link for a registered account
    Given the user is on the login page and has forgotten their password
    When the user opens "Forgot password?" and submits the email of their registered account
    Then the system sends a reset link to that email address
    And the user sees a confirmation that a reset link has been sent if the address is registered
    And the user is told to check their inbox and spam folder

  @happy-path
  Scenario: Choosing a new password from a valid reset link
    Given the user has received a reset link and the token is still valid
    When the user opens the reset link
    Then the user is shown a reset page to choose a new password
    And the user is asked to enter the new password and confirm it

  @happy-path
  Scenario: Completing the reset and landing on the dashboard
    Given the user is on the reset page reached from a valid reset link
    When the user enters a new password that meets the password policy and a matching confirmation, and submits
    Then the account password is updated to the new password
    And the reset token is consumed so it cannot be used again
    And the user is signed in and taken to their dashboard
    And the user sees a confirmation that their password was changed

  @deviation @invalid-input
  Scenario: Submitting the reset request with the email field empty
    Given the user is on the "Forgot password" page
    When the user submits the form without entering an email address
    Then the request is not submitted
    And the "Email" field is highlighted with the message "Enter your email address"

  @deviation @invalid-input
  Scenario: Submitting the reset request with a malformed email address
    Given the user is on the "Forgot password" page
    When the user submits "not-an-email" as the email address
    Then the request is not submitted
    And the "Email" field is highlighted with the message "Enter a valid email address"
    And the value the user typed remains in the field for correction

  @deviation @invalid-input
  Scenario Outline: Submitting a new password that fails the password policy
    Given the user is on the reset page reached from a valid reset link
    When the user enters "<password>" as the new password and submits
    Then the password is not changed
    And the password field shows the specific reason "<reason>"
    And the reset token remains valid so the user can correct and resubmit

    Examples:
      | password   | reason                                            |
      | (empty)    | Enter a new password                              |
      | abc        | Password is too short — use at least 8 characters |
      | password   | Password is too common — choose something less guessable |

  @deviation @invalid-input
  Scenario: Confirmation password does not match the new password
    Given the user is on the reset page reached from a valid reset link
    When the user enters a new password and a confirmation that does not match, and submits
    Then the password is not changed
    And the confirmation field is highlighted with the message "Passwords do not match"
    And the new-password field keeps its entered value so only the confirmation must be re-typed

  @deviation @invalid-input @assumption
  Scenario: Choosing a new password identical to the current password
    # Assumption: reusing the current password is allowed but discouraged with a notice;
    # the product may instead choose to block reuse of recent passwords.
    Given the user is on the reset page reached from a valid reset link
    When the user enters a new password identical to their current password and submits
    Then the reset completes and the user is signed in to their dashboard
    And the user is shown a non-blocking notice that the password is unchanged from before

  @deviation @duplicate-retry
  Scenario: Requesting a reset link twice for the same address
    Given the user already requested a reset link for their email address
    When the user submits the "Forgot password" form again for the same address
    Then the user sees the same "reset link sent" confirmation
    And a fresh reset link is sent, and any previously issued token for that account is invalidated
    And only the most recent reset link will work

  @deviation @duplicate-retry
  Scenario: Clicking "Send reset link" twice on a slow connection
    Given the user has submitted the "Forgot password" form and the request is still in flight
    When the user clicks "Send reset link" a second time before a response returns
    Then no second request is processed
    And the user sees a single "reset link sent" confirmation once the request completes

  @deviation @duplicate-retry
  Scenario: Clicking "Set new password" twice on a slow connection
    Given the user has submitted a valid new password and the request is still in flight
    When the user clicks "Set new password" a second time before a response returns
    Then only one password change is applied
    And the user is taken to their dashboard once, with a single confirmation

  @deviation @duplicate-retry
  Scenario: Reloading the reset page after the reset already completed
    Given the user has completed a password reset and the token is now consumed
    When the user reloads the reset page or reopens the same reset link
    Then the reset form is not shown again
    And the user is told the link has already been used
    And the user is offered links to sign in or to request a new reset link

  @deviation @rate-limit @assumption
  Scenario: Requesting too many reset links in a short window
    # Assumption: the cap is 5 reset requests per email address per hour;
    # the exact threshold is a product decision.
    Given the user has requested 5 reset links for their address within the past hour
    When the user submits the "Forgot password" form again for that address
    Then no additional reset email is sent
    And the user sees a message that too many requests have been made and to try again later
    And the message states roughly how long to wait before requesting again

  @deviation @rate-limit @assumption
  Scenario: A single client IP requests resets for many addresses
    # Assumption: a per-IP request cap and/or a CAPTCHA challenge is applied after a
    # threshold; the threshold and challenge type are product/security decisions.
    Given a single client has submitted reset requests for many different email addresses
    When that client submits another reset request
    Then the request is challenged with a CAPTCHA or temporarily blocked
    And legitimate users on the same shared network are not permanently blocked

  @deviation @connectivity
  Scenario: Losing connectivity while submitting the reset request
    Given the user submits the "Forgot password" form
    And the network connection drops before a response is received
    When connectivity is restored
    Then the user is told the request did not complete and can retry
    And the email address the user typed is still present in the field

  @deviation @connectivity
  Scenario: Losing connectivity while submitting the new password
    Given the user submits a new password on the reset page
    And the network connection drops before a response is received
    When connectivity is restored
    Then the user is told the password change did not complete
    And either the password was fully changed or fully unchanged — never partially applied
    And if it was not changed, the reset token is still valid so the user can retry

  @deviation @connectivity
  Scenario: Closing the tab after the password change succeeded
    Given the user's new password was saved and the token consumed
    And the user closes the tab before the dashboard finishes loading
    When the user later opens the application and signs in with the new password
    Then the new password works and the user reaches their dashboard

  @deviation @abandon-resume
  Scenario: Requesting a reset link but never opening it
    Given the user requested a reset link but never opened it
    When the link's validity window passes
    Then the token expires and can no longer be used
    And the user's existing password is unchanged and their account is unaffected

  @deviation @abandon-resume
  Scenario: Leaving the reset page open without submitting
    Given the user opened a valid reset link and left the reset page open without submitting
    When the user returns after the token's validity window has passed and submits a new password
    Then the password is not changed
    And the user is told the link has expired and is offered a one-click way to request a new one

  @deviation @abandon-resume @assumption
  Scenario: Returning to the login page after a reset link was already requested
    # Assumption: requesting a reset does not lock the account; the old password keeps
    # working until a reset is actually completed.
    Given the user requested a reset link but then remembered their old password
    When the user signs in with their old password before completing any reset
    Then the user is signed in normally
    And any outstanding reset token remains usable until it expires or is consumed

  @deviation @out-of-order
  Scenario: Opening the reset page URL directly without a token
    Given the user navigates to the reset page URL with no reset token present
    When the page loads
    Then the password form is not shown
    And the user is told a valid reset link is required
    And the user is offered a link to request a reset

  @deviation @out-of-order
  Scenario: Using the browser Back button after completing the reset
    Given the user has completed the reset and is on their dashboard
    When the user presses the browser Back button to the reset page
    Then the reset form is not re-submittable
    And the user is told the link has already been used and is offered a link to sign in

  @deviation @out-of-order
  Scenario: Already signed in when opening a reset link
    Given the user already has an active signed-in session
    When the user opens a valid reset link
    Then the reset page still loads and lets the user choose a new password
    And on completion the password is updated and the session reflects the new credential

  @deviation @auth-permission @assumption
  Scenario: The account is disabled before the reset is completed
    # Assumption: a reset cannot reactivate a disabled or suspended account;
    # such users are routed to support.
    Given the user has a valid reset link
    And an administrator disables the user's account before the reset is completed
    When the user submits a new password
    Then the password is not changed and the user is not signed in
    And the user is told the account is not active and is given a way to contact support

  @deviation @auth-permission
  Scenario: Completing a reset invalidates other active sessions
    Given the user is signed in on another device
    When the user completes a password reset on the current device
    Then the user is signed in on the current device with the new password
    And the session on the other device is signed out and requires the new password to sign back in

  @deviation @concurrency
  Scenario: Requesting a second reset link, then using the first
    Given the user requested a reset link, then requested a second one before using either
    When the user opens the first (older) reset link
    Then the older link is rejected as no longer valid
    And the user is told a newer reset link was sent and to use the most recent email

  @deviation @concurrency
  Scenario: Opening the same valid reset link in two tabs
    Given the user opened the same valid reset link in two browser tabs
    And the user completed the password reset in the first tab
    When the user submits a new password in the second tab
    Then the second submission does not change the password again
    And the second tab tells the user the link has already been used and offers a link to sign in

  @deviation @concurrency @assumption
  Scenario: An administrator changes the password while a reset is in progress
    # Assumption: last completed write wins, and any in-flight reset token is invalidated
    # by an admin-initiated credential change.
    Given the user holds a valid reset link
    And an administrator resets the account password through an admin tool
    When the user submits a new password from their reset link
    Then the user is told the link is no longer valid because the credential changed
    And the user is offered a one-click way to request a fresh reset link

  @deviation @state-conflict
  Scenario: Requesting a reset for an email with no registered account
    Given no account exists for the submitted email address
    When the user submits that address on the "Forgot password" page
    Then the user sees the same "reset link sent if the address is registered" confirmation
    And no reset email is sent and no account is created

  @deviation @state-conflict @assumption
  Scenario: Requesting a reset for an account that has no password set
    # Assumption: accounts created via SSO with no local password are offered a
    # "set a password" path rather than a "reset" error.
    Given the account for the submitted address exists but was created through SSO and has no local password
    When the user submits that address on the "Forgot password" page
    Then a link is sent that lets the user set a password for the first time
    And the resulting page is framed as setting a password, not resetting one

  @deviation @boundary
  Scenario: Submitting an extremely long email address
    Given the user is on the "Forgot password" page
    When the user submits an email address longer than the maximum allowed length
    Then the request is not submitted
    And the "Email" field shows the message "Enter a valid email address"
    And the application does not error or truncate silently

  @deviation @boundary
  Scenario: Submitting an extremely long new password
    Given the user is on the reset page reached from a valid reset link
    When the user enters a new password far longer than the maximum supported length
    Then the password is rejected before submission with a stated maximum length
    And the rest of the form keeps its entered values

  @deviation @environment
  Scenario: Completing the reset flow on a narrow mobile screen
    Given the user opens the reset link on a narrow mobile viewport
    When the user works through requesting and setting the new password
    Then every field and button is reachable and usable without horizontal scrolling
    And the flow can be completed end to end

  @deviation @environment
  Scenario: Completing the reset flow with keyboard and screen reader only
    Given the user navigates the reset pages using only a keyboard and a screen reader
    When the user works through each field and submits
    Then every field has an associated label and validation errors are announced
    And the flow can be completed without a mouse

  @deviation @environment @assumption
  Scenario: Opening the reset page with JavaScript disabled
    # Assumption: the reset flow degrades to server-side validation and submission so it
    # works without client-side JavaScript; if not, an explicit unsupported notice is shown.
    Given the user opens the reset page in a browser with JavaScript disabled
    When the user submits a new password
    Then the form is validated and processed server-side
    And the user can still complete the reset, or is clearly told the browser is unsupported

  @deviation @external-failure
  Scenario: The email provider is unavailable when sending the reset link
    Given the user submits a valid reset request for a registered account
    And the email provider is unavailable
    Then the reset request is recorded and the email is queued for automatic retry
    And the user still sees the standard "reset link sent" confirmation without a raw technical error
    And the user is advised the email may be delayed and can request another link if it does not arrive

  @deviation @external-failure
  Scenario: The credential store is unavailable when saving the new password
    Given the user submits a valid new password from a valid reset link
    And the credential store cannot be reached
    Then the password is not changed
    And the user sees a message that the change could not be saved right now and to try again shortly
    And the reset token remains valid so the user can retry without requesting a new link

  @deviation @time-expiry
  Scenario: Opening a reset link after it has expired
    Given the user opens a reset link whose validity window has passed
    When the page loads
    Then the password form is not shown
    And the user is told the link has expired
    And the user can request a new reset link directly from that screen

  @deviation @time-expiry @assumption
  Scenario: The token expires while the user is filling in the new password
    # Assumption: token validity is checked at submission time, not only at page load.
    Given the user opened a valid reset link and the token expired while the page was open
    When the user submits a new password
    Then the password is not changed
    And the user is told the link expired and is offered a one-click way to request a fresh link
    And the password the user typed is not retained in the new link's page, for security

  @deviation @time-expiry
  Scenario: Completing a reset just inside the validity window
    Given the user opens a reset link with only seconds left before expiry
    When the user submits a valid new password before the window closes
    Then the password change is accepted
    And the user is signed in and taken to their dashboard

  @deviation @adversarial
  Scenario: Probing the reset-request page to discover which emails are registered
    Given an attacker submits both a registered and an unregistered email address
    When each request completes
    Then both produce the identical confirmation message and indistinguishable response timing
    And the attacker cannot tell from the response whether either account exists

  @deviation @adversarial
  Scenario: Guessing or tampering with a reset token in the URL
    Given an attacker submits a reset page URL with a fabricated or altered token
    When the page loads or a password is submitted
    Then the token is rejected as invalid and no password is changed
    And the user is shown the standard invalid-link message with no detail about why it failed

  @deviation @adversarial @assumption
  Scenario: Submitting a new password containing a script payload
    # Assumption: all user-supplied input is validated server-side and escaped on render.
    Given the user enters a new password value containing an embedded script
    When the user submits the reset page
    Then the value is treated purely as a password string and never rendered as markup
    And the script never executes for that user or any administrator viewing account data
