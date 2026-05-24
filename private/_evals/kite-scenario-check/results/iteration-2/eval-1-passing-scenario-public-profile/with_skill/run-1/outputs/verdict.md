PASS

Clause check:
- Given a member "alice" with a public profile: satisfied. `get_public_profile` fetches by username and only returns a response when `profile_is_public` is true.
- And alice joined on 2024-03-01: satisfied. The response sets `join_date` from `member.created_at.date()`, so a member joined on that date returns it.
- When a visitor requests `GET /api/profiles/alice`: satisfied. The route handles `GET /api/profiles/{username}` and passes `alice` to the service.
- Then the response status is 200: satisfied. A successful service return produces the route response.
- And the response includes alice's display name: satisfied. `display_name` is in `PublicProfileResponse` and is populated from the member.
- And the response includes alice's join date: satisfied. `join_date` is in `PublicProfileResponse` and is populated.
- And the response does NOT include alice's email address: satisfied. The response model has no email field and the service never returns one.

Missing or drift: none.

Commit readiness: commit this scenario.
