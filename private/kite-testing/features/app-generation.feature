Feature: Kite app generation — starting a build

  Authenticated smoke coverage. Untagged scenarios start from a cached session
  for the default "user" role. Steps are natural language, executed by the
  agentic act/extract layer. Use these as a template for your own PR scenarios.

  Background:
    Given I am logged in

  Scenario: The home prompt page is ready for input
    Given I open the home page
    Then I should see "a large prompt input where you can describe an app to build"

  Scenario: Submitting a brief starts app creation
    Given I open the home page
    When I "type 'a landing page for a neighbourhood coffee shop called Bean There' into the main prompt input"
    And I "submit the prompt to start building the app"
    Then I should see "the app creation or discovery flow has started"
    And the page URL should contain "discovery"
