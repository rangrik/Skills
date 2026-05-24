# Run Report: Announcement Dismissal

## Scenarios attempted, in order
1. S1 — User dismisses the active announcement — committed
2. S2 — Active endpoint hides a dismissed announcement — committed
3. S3 — Dismissing the same announcement twice is a no-op — committed

## Scenarios skipped as blocked
- S4 — Auto-expire dismissals after the retention window — skipped as blocked because the researched plan found no configured retention window and no concrete sweeper policy. Implementing it would invent product behavior and needs re-planning.

## Exact reused research findings
- Reused `session_manager.get_current_user()` from authenticated routes, specifically the pattern in `backend/app/routes/account_routes.py`.
- Reused the existing `Announcement` model in `backend/app/models/announcement.py`; did not redefine the announcements table.
- Reused and extended `backend/app/database/announcement_db.py`, including the existing `get_active_announcement` active lookup.
- Reused the existing GET `/announcements/active` route in `backend/app/routes/announcement_routes.py`.
- Preserved the existing DB-timeout-tolerant GET behavior by leaving `_is_database_timeout` and `_return_no_announcement_after_timeout` in place and preserving the no-user one-argument data-layer call path.
- Reused route auto-registration from `backend/app/__init__.py`; no manual route registration was added.

## Exact new extension points changed
- Added `backend/app/models/announcement_dismissal.py` with `announcement_dismissals`.
- Added `backend/app/migrations/115-create-announcement-dismissals-table.sql` as the next migration, including `uq_announcement_dismissals_user_announcement` on `(user_id, announcement_id)`.
- Updated `backend/app/models/__init__.py` to export `AnnouncementDismissal`.
- Extended `backend/app/database/announcement_db.py` with `dismiss_announcement()` and optional user-aware active lookup exclusion.
- Updated `backend/app/routes/announcement_routes.py` with `POST /announcements/{announcement_id}/dismiss` and user-aware active lookup routing.
- Added `DismissAnnouncementResponse` in `backend/app/schemas/announcement_schema.py`.
- Added focused tests in `backend/tests/test_routes/test_announcement_routes.py`.

## Tests run or skipped
- Passed: final `ruff check` on touched backend files.
- Passed: final `ruff format --check` on touched backend files.
- Passed: S1 import/schema check for model columns, unique constraint metadata, route import, and dismiss response schema.
- Passed: S2 query-shape check confirming no-user lookup has no dismissal join and user-aware lookup uses `LEFT OUTER JOIN announcement_dismissals ... announcement_dismissals.id IS NULL`.
- Passed: S3 idempotent insert check confirming the insert compiles to `ON CONSTRAINT uq_announcement_dismissals_user_announcement DO NOTHING`.
- Attempted but blocked: targeted pytest route tests for S1, S2, S3, and the existing active-route timeout test. `uv run` first failed in this sandbox with a uv panic; running pytest via cached archives collected tests but failed during fixture setup because asyncpg TCP connection to the test Postgres DB raised `PermissionError: [Errno 1] Operation not permitted`.
- Skipped: full `task fmt` / `task test`; this checkout has no `Taskfile`, and backend pytest could not access Postgres from the sandbox. Direct ruff checks were run instead.

## Architecture check result per committed scenario
- S1: PASS — model/data/route changes were placed in the existing backend layers, migration 115 was sequential and idempotent, route glob registration was reused, and GET timeout handling was not regressed.
- S2: PASS — active lookup gained optional user context in the existing data layer while preserving the original no-user path and timeout-tolerant route structure.
- S3: PASS — idempotency is enforced at the data layer using the named unique constraint from migration 115; the route behavior remains a success response for repeated dismissals.

## Scenario check result per committed scenario
- S1: PASS — authenticated POST records one `(user_id, announcement_id)` dismissal row and returns `{"success": true}`; unauthenticated callers receive 401 before any write.
- S2: PASS — active lookup excludes an announcement dismissed by the current user and leaves it visible for other users; no-user lookup behavior remains unchanged.
- S3: PASS — repeated dismissals target `ON CONSTRAINT uq_announcement_dismissals_user_announcement DO NOTHING`, so duplicate rows cannot be created and the response remains success.

## Commits created
- `617b8ae6bd feat(announcements): add dismissal endpoint`
- `f0781475ae feat(announcements): hide dismissed active banner`
- `38f30628c0 feat(announcements): make dismissal idempotent`

## Remaining blockers or uncertainties
- S4 remains blocked until a concrete dismissal retention window and sweeper mechanism are specified.
- Database-backed route tests should be rerun in an environment where the backend test Postgres database is reachable.
