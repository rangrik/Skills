PASS

Clause check:
- `Given a member "alice" with a public profile` / `When a visitor requests GET /api/profiles/alice`: implemented by `GET /api/profiles/{username}` and lookup by username.
- `Then the response status is 200`: FastAPI returns 200 for successful service response.
- `And the response includes alice's display name`: `display_name` is included in `PublicProfileResponse`.
- `And the response includes alice's join date`: `join_date` is included and derived from `member.created_at.date()`.
- `And the response does NOT include alice's email address`: response model exposes only `username`, `display_name`, and `join_date`; no email field is returned.

Scenario drift: None found against the provided Gherkin.

Commit readiness: Ready to commit for this scenario.
