Feature: Accept a workspace invitation
  As an invited teammate
  I want to accept an invitation from my email
  So that I become a member of the workspace

  Background:
    Given an admin has invited "grace@acme.test" to the workspace "Acme" with role "Member"
    And the invitation email contains an "Accept" link

  Scenario: New user accepts and creates an account
    Given "grace@acme.test" does not have an account
    When I open the invitation email and click "Accept"
    Then I am taken to the sign-up screen
    And the email field is pre-filled with "grace@acme.test"
    When I complete account creation
    Then I am a member of the workspace "Acme" with role "Member"
    And the invitation status is "accepted"
    And I land inside the workspace "Acme"

  Scenario: Existing user accepts while logged out
    Given "grace@acme.test" already has an account
    And I am not logged in
    When I open the invitation email and click "Accept"
    Then I am asked to log in
    When I log in as "grace@acme.test"
    Then I am a member of the workspace "Acme" with role "Member"
    And the invitation status is "accepted"
    And I land inside the workspace "Acme"

  Scenario: Existing user accepts while already logged in as the invited email
    Given "grace@acme.test" already has an account
    And I am logged in as "grace@acme.test"
    When I open the invitation email and click "Accept"
    Then I am a member of the workspace "Acme" with role "Member"
    And the invitation status is "accepted"
    And I land inside the workspace "Acme"

  Scenario: Accepted invitee receives the role assigned by the admin
    Given an admin has invited "linus@acme.test" to the workspace "Acme" with role "Admin"
    And "linus@acme.test" already has an account
    And I am logged in as "linus@acme.test"
    When I open the invitation email and click "Accept"
    Then I am a member of the workspace "Acme" with role "Admin"

  Scenario: Logged-in user accepts an invitation addressed to a different email
    Given I am logged in as "other@acme.test"
    When I open the invitation email for "grace@acme.test" and click "Accept"
    Then I am warned that the invitation was sent to "grace@acme.test"
    And I am offered the option to switch accounts or log in as "grace@acme.test"
    And I am not added to the workspace as "other@acme.test"

  Scenario: Accepting an expired invitation
    Given the invitation for "grace@acme.test" has expired
    When I open the invitation email and click "Accept"
    Then I see that the invitation has expired
    And I am advised to ask an admin to resend it
    And I am not added to the workspace

  Scenario: Accepting a revoked invitation
    Given the invitation for "grace@acme.test" has been revoked
    When I open the invitation email and click "Accept"
    Then I see that the invitation is no longer valid
    And I am not added to the workspace

  Scenario: Accepting an already-accepted invitation
    Given the invitation for "grace@acme.test" has already been accepted
    And I am logged in as "grace@acme.test"
    When I open the invitation email and click "Accept"
    Then I see that the invitation was already used
    And I land inside the workspace "Acme"

  Scenario: Accept link with an unknown token
    When I open an Accept link with an unknown token
    Then I see that the invitation could not be found or is no longer valid
    And I am not added to any workspace

  Scenario: Acceptance is blocked when the seat limit was reached after sending
    Given the workspace seat limit was reached after the invitation was sent
    And "grace@acme.test" already has an account
    And I am logged in as "grace@acme.test"
    When I open the invitation email and click "Accept"
    Then I see a message that the workspace has no available seats
    And I am advised to contact an admin
    And I am not added to the workspace
