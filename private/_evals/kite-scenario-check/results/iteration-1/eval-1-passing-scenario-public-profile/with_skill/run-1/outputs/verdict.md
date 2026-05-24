FAIL

- `When a visitor requests GET /api/profiles/alice` / `Then the response status is 200`: `profile_routes.py` references `get_profile_service` in `Depends(get_profile_service)` but never imports or defines it, so the route module cannot load and the GET request cannot return 200.
- `Then the response includes alice's display name`: the response model and service include `display_name`, so this clause is implemented once the route wiring is fixed.
- `Then the response includes alice's join date`: the service maps `member.created_at.date()` to `join_date`, so this clause is implemented assuming `created_at` is the stored join timestamp for 2024-03-01.
- `Then the response does NOT include alice's email address`: `PublicProfileResponse` omits email, so this clause is satisfied.

Scenario drift: no meaningful drift beyond this scenario; the code is scoped to public profile retrieval.

Commit readiness: do not commit yet. Fix the missing route dependency wiring and re-check.
