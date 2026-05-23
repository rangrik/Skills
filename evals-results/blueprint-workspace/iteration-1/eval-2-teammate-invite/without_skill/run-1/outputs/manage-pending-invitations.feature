Feature: Manage pending invitations
  As a workspace admin
  I want to see, resend, and revoke pending invitations
  So that I can keep the workspace membership under control

  Background:
    Given I am logged in as "ada@acme.test"
    And I am an admin of the workspace "Acme"
    And a pending invitation exists for "grace@acme.test" with role "Member"
    And I am on the Members settings page

  Scenario: Pending invitations are listed on the Members page
    Then I see a "Pending invitations" section
    And it lists "grace@acme.test" with role "Member", the inviter, and the sent date

  Scenario: Resend a pending invitation
    When I resend the invitation for "grace@acme.test"
    Then a new invitation email is sent to "grace@acme.test"
    And the invitation expiry is reset to 7 days from now
    And the invitation status remains "pending"

  Scenario: Revoke a pending invitation
    When I revoke the invitation for "grace@acme.test"
    Then the invitation status becomes "revoked"
    And "grace@acme.test" no longer appears in the "Pending invitations" section
    And the Accept link in the invitation email no longer works

  Scenario: An accepted invitation leaves the pending section
    Given the invitation for "grace@acme.test" has been accepted
    When I refresh the Members settings page
    Then "grace@acme.test" appears in the active members list
    And "grace@acme.test" no longer appears in the "Pending invitations" section

  Scenario: An expired invitation is shown as expired
    Given the invitation for "grace@acme.test" has expired
    When I refresh the Members settings page
    Then the invitation for "grace@acme.test" is shown with status "expired"
    And I am offered the option to resend it

  Scenario: A standard member cannot manage pending invitations
    Given I am logged in as "tim@acme.test"
    And I am a member of the workspace "Acme"
    When I am on the Members settings page
    Then I cannot resend or revoke any pending invitation
