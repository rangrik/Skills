@anonymous
Feature: Authentication

  Exercises the real WorkOS login UI with no cached session. The anonymous tag
  makes the harness start a logged-out browser context. A good first scenario
  to confirm the whole loop (browser + login + agentic check) works.

  Scenario: A returning user can log in
    When I log in as "user"
    Then I should be logged in
