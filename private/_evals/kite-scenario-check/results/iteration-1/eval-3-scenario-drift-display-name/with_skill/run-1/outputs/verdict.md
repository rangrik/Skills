FAIL

- Scenario satisfaction: the display-name path itself appears to satisfy the `when` and `then` clauses: PATCH `/api/members/me` updates `req.display_name`, returns status 200 through the route, includes the updated `display_name`, and saves the member.
- Missing for this scenario: nothing obvious is missing for the display-name-only behavior.
- Scenario drift: the implementation adds `marketing_emails_opt_in` and `theme_preference` request/response fields and persists them, which the Gherkin never calls for. It also sends a marketing-preference email from the display-name update endpoint, outside the scenario's `When carol sends PATCH /api/members/me with a new display_name` scope.
- Commit readiness: do not commit this scenario as-is; remove the unrelated marketing-email and theme-preference behavior from this scenario slice or move it to a separate scenario.
