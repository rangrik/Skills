# Run Report: Announcement Dismissal

## Scenarios attempted, in order
1. S1 — User dismisses the active announcement — committed
2. S2 — Active endpoint hides a dismissed announcement — committed
3. S3 — Dismissing the same announcement twice is a no-op — committed

## Scenarios skipped as blocked
- S4 — Auto-expire dismissals after the retention window — skipped as blocked. The plan says no retention window is defined in config, design, or blueprint, so this needs re-planning before implementation.

## Exact reused research findings
- `session_manager.get_current_user()` exists and is used by authenticated routes; verified in `backend/app/routes/account_routes.py`. The dismiss route reuses `session_manager.has_current_user()` and `session_manager.get_current_user()`.
- `Announcement` exists in `backend/app/models/announcement.py`; reused directly and did not redefine the `announcements` table.
- `backend/app/database/announcement_db.py` and `get_active_announcement` exist; extended this data layer instead of creating a parallel announcement lookup.
- `GET /announcements/active` exists in `backend/app/routes/announcement_routes.py`; extended the existing route while preserving its DB timeout handling path.
- Route auto-registration exists in `backend/app/__init__.py` via `register_routes` globbing `routes/*_routes.py`; added the dismiss endpoint to the existing `announcement_routes.py` and did not add manual registration.
- No dismissal model/table existed; added the missing `announcement_dismissals` model and migration.

## Exact new extension points changed
- Added `backend/app/models/announcement_dismissal.py` with `AnnouncementDismissal`.
- Updated `backend/app/models/__init__.py` to export `AnnouncementDismissal`.
- Added `backend/app/migrations/115-create-announcement-dismissals.sql`, the next migration number after 114, with `announcement_dismissals`, `announcement_id` FK to `announcements(id)`, `user_id`, timestamps, and unique constraint `uq_announcement_dismissals_user_announcement` on `(user_id, announcement_id)`.
- Extended `backend/app/database/announcement_db.py` with `get_announcement_by_id`, idempotent `create_announcement_dismissal`, and optional `user_id` exclusion in `get_active_announcement`.
- Extended `backend/app/routes/announcement_routes.py` with `POST /announcements/{announcement_id}/dismiss` and optional current-user context for `GET /announcements/active`.
- Added `AnnouncementDismissResponse` in `backend/app/schemas/announcement_schema.py`.
- Added targeted tests in `backend/tests/test_routes/test_announcement_routes.py` for S1 auth/row creation, S2 per-user active hiding, and S3 double-dismiss idempotency.

## Tests run or skipped
- Ran `python3 -m py_compile ...` on touched Python files for each scenario — passed.
- Ran `git -C /private/tmp/kite-skill-evals/appsmith-impl/e3_without_skill_i2_r1 diff --check` for each scenario — passed.
- Attempted `uv run ruff ...`; skipped because `uv` first failed on the user uv cache permission, then with `UV_CACHE_DIR=/private/tmp/kite-uv-cache` panicked while creating `.venv` with `system-configuration` NULL object panic.
- Attempted focused pytest through system Python for S2 and S3; skipped because `/opt/homebrew/opt/python@3.14/bin/python3.14` has no `pytest` module installed.
- Full `task fmt` and `task test` were not run because the available Python toolchain could not provide ruff/pytest in this sandbox.

## Architecture check result per committed scenario
- S1: PASS (manual without-skill baseline). Reused existing announcement model/data/route extension points, used backend ORM conventions, added the next sequential migration, and preserved the active-route timeout fallback.
- S2: PASS (manual without-skill baseline). Extended the existing active lookup with optional user context, kept no-user behavior intact, and retained the DB timeout fallback around the data-layer call.
- S3: PASS (manual without-skill baseline). Reused the S1 unique constraint and implemented idempotency in the data-layer insert with PostgreSQL `ON CONFLICT DO NOTHING`.

## Scenario check result per committed scenario
- S1: PASS (manual independent Gherkin check). Authenticated users can POST a dismissal and get success; unauthenticated/no-current-user requests are rejected before a row is inserted.
- S2: PASS (manual independent Gherkin check). A dismissal row excludes the active announcement for that user while leaving it visible for other users/no-user lookups.
- S3: PASS (manual independent Gherkin check). Repeating the same dismiss POST returns success and the unique constraint/conflict handler keeps exactly one row.

## Commits created
- `4fc7fcf095` — Add announcement dismissal endpoint
- `e445c86f39` — Hide dismissed active announcements
- `6b87ea4f78` — Make announcement dismissal idempotent

## Remaining blockers or uncertainties
- S4 remains blocked until a real retention duration and sweeper integration point are specified.
- Automated ruff/pytest verification remains blocked by the local sandbox/toolchain issue described above; only syntax and whitespace checks were completed.
