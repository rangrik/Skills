Feature: Send teammate invitations
  As a workspace admin
  I want to invite teammates by email from the Members settings page
  So that they can join the workspace

  Background:
    Given I am logged in as "ada@acme.test"
    And I am an admin of the workspace "Acme"
    And I am on the Members settings page

  Scenario: Admin sees the Invite control
    Then I see an "Invite" button

  Scenario: Open the invite dialog
    When I click "Invite"
    Then an invite dialog opens
    And the role selector defaults to "Member"

  Scenario: Invite a single teammate successfully
    When I click "Invite"
    And I enter the email "grace@acme.test"
    And I select the role "Member"
    And I click "Send"
    Then I see a confirmation that 1 invitation was sent
    And a pending invitation for "grace@acme.test" with role "Member" appears in the Members list
    And an invitation email is sent to "grace@acme.test"

  Scenario: Invite multiple teammates in one submission
    When I click "Invite"
    And I enter the emails:
      | grace@acme.test |
      | linus@acme.test |
      | margaret@acme.test |
    And I select the role "Member"
    And I click "Send"
    Then I see a confirmation that 3 invitations were sent
    And a pending invitation exists for each of:
      | grace@acme.test |
      | linus@acme.test |
      | margaret@acme.test |
    And an invitation email is sent to each of those addresses

  Scenario: Invite a teammate as an admin
    When I click "Invite"
    And I enter the email "linus@acme.test"
    And I select the role "Admin"
    And I click "Send"
    Then a pending invitation for "linus@acme.test" with role "Admin" appears in the Members list

  Scenario: Malformed email blocks sending
    When I click "Invite"
    And I enter the email "not-an-email"
    And I click "Send"
    Then the address "not-an-email" is flagged as invalid
    And no invitation is sent

  Scenario: Malformed email does not block the valid ones once corrected
    When I click "Invite"
    And I enter the emails:
      | grace@acme.test |
      | broken-email |
    And I click "Send"
    Then the address "broken-email" is flagged as invalid
    And no invitations are sent
    When I remove the address "broken-email"
    And I click "Send"
    Then I see a confirmation that 1 invitation was sent
    And a pending invitation exists for "grace@acme.test"

  Scenario: Inviting someone who is already an active member
    Given "margaret@acme.test" is already an active member of the workspace
    When I click "Invite"
    And I enter the email "margaret@acme.test"
    And I click "Send"
    Then I see a message that "margaret@acme.test" is already a member
    And no invitation is created for "margaret@acme.test"

  Scenario: Already-a-member address does not block other valid addresses
    Given "margaret@acme.test" is already an active member of the workspace
    When I click "Invite"
    And I enter the emails:
      | margaret@acme.test |
      | grace@acme.test |
    And I click "Send"
    Then I see a message that "margaret@acme.test" is already a member
    And a pending invitation exists for "grace@acme.test"
    And an invitation email is sent to "grace@acme.test"

  Scenario: Inviting an email that already has a pending invitation
    Given a pending invitation exists for "grace@acme.test"
    When I click "Invite"
    And I enter the email "grace@acme.test"
    And I click "Send"
    Then no duplicate invitation is created for "grace@acme.test"
    And I am offered the option to resend the existing invitation

  Scenario: Duplicate addresses within one submission are de-duplicated
    When I click "Invite"
    And I enter the emails:
      | grace@acme.test |
      | grace@acme.test |
    And I click "Send"
    Then exactly 1 invitation is created for "grace@acme.test"

  Scenario: Email addresses are matched case-insensitively
    Given "margaret@acme.test" is already an active member of the workspace
    When I click "Invite"
    And I enter the email "Margaret@Acme.Test"
    And I click "Send"
    Then I see a message that "Margaret@Acme.Test" is already a member
    And no invitation is created

  Scenario: A standard member cannot invite teammates
    Given I am logged in as "tim@acme.test"
    And I am a member of the workspace "Acme"
    When I am on the Members settings page
    Then I do not see an "Invite" button

  Scenario: A non-admin is denied when invoking the invite API directly
    Given I am logged in as "tim@acme.test"
    And I am a member of the workspace "Acme"
    When I attempt to send an invitation directly via the API
    Then the request is denied with a permission error
    And no invitation is created

  Scenario: Sending is blocked when it would exceed the seat limit
    Given the workspace has 1 remaining seat
    When I click "Invite"
    And I enter the emails:
      | grace@acme.test |
      | linus@acme.test |
    And I click "Send"
    Then I see a message that the seat limit would be exceeded
    And no invitations are sent

  Scenario: Invitation is still created when email delivery fails
    Given email delivery is failing
    When I click "Invite"
    And I enter the email "grace@acme.test"
    And I click "Send"
    Then a pending invitation for "grace@acme.test" is created
    And I see a delivery warning with the option to resend
