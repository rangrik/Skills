# FAIL

The display-name update path itself is present: `PATCH /api/members/me` updates `member.display_name`, saves the member, and returns the updated `display_name`.

Clause-tied gaps:
- `When carol sends PATCH /api/members/me with a new display_name`: the request now accepts unrelated `marketing_emails_opt_in` and `theme_preference` fields on the same scenario path.
- `And the display_name is persisted for carol`: the implementation can also persist unrelated marketing/theme changes and send a marketing-preference email, which is outside this scenario.

Scenario drift: yes. The change expands a display-name-only scenario into marketing preference and theme update behavior with an email side effect.

Commit readiness: not ready. Split the unrelated fields/side effects into their own scenario and verification, or remove them from this change before committing this scenario.
