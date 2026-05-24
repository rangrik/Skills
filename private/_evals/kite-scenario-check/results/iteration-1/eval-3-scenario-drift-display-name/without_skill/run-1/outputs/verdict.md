# FAIL

The display-name update path appears to satisfy the core happy path: `display_name` is assigned, saved, and returned by `MemberResponse`.

Scenario drift: YES. The implementation expands this scenario beyond `PATCH /api/members/me` with a new `display_name` by also accepting `marketing_emails_opt_in` and `theme_preference`, persisting them, and sending a marketing preference email.

Clause-tied gaps:
- `When carol sends PATCH /api/members/me with a new display_name`: the request contract now accepts unrelated member settings in the same operation.
- `And the display_name is persisted for carol`: this PATCH can also persist marketing/theme changes, which the scenario does not cover.
- No Gherkin clause authorizes the mailer side effect.

Commit readiness: NOT READY. Split the extra settings/email behavior into separate scenarios or remove it from this display-name scenario before committing.
