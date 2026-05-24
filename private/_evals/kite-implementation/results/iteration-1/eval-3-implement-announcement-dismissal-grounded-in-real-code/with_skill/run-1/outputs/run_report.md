# Run Report: Announcement Dismissal Implementation

## Scenarios attempted, in order
1. S1 — User dismisses the active announcement — committed.
2. S2 — Active endpoint hides a dismissed announcement — committed.
3. S3 — Dismissing the same announcement twice is a no-op — committed.

## Scenarios skipped as blocked
- S4 — Auto-expire dismissals after the retention window — skipped as blocked. Research found no defined retention window and no concrete sweeper policy in the blueprint/system design, so this needs kite-planner re-planning.

## Exact reused research findings
- S1 RQ1 -> EXISTS: `session_manager.get_current_user()` — used by authenticated routes (see `backend/app/routes/account_routes.py`, which calls `current_user = session_manager.get_current_user()`) to resolve the current user inside a request. Reused in the dismiss route.
- S1 RQ2 -> EXISTS: the `Announcement` model in `backend/app/models/announcement.py` and the data layer `backend/app/database/announcement_db.py` (`get_active_announcement`) already exist. Reused them; did not redefine the announcements table.
- S1 RQ3 -> MISSING: no dismissal model exists. Added `announcement_dismissals` model in `backend/app/models/announcement_dismissal.py` with SQL migration `backend/app/migrations/115-create-announcement-dismissals.sql`. Kept the dismiss endpoint in `backend/app/routes/announcement_routes.py`; route auto-registration remains via `backend/app/__init__.py` glob registration.
- S1 reuse constraint: preserved the existing GET `/announcements/active` timeout-tolerant behavior while editing announcement route code.
- S2 RQ1 -> EXISTS: `get_active_announcement` in `backend/app/database/announcement_db.py` runs the active-announcement SELECT and is called by GET `/announcements/active`. Extended it with optional user-aware dismissal exclusion and kept no-user/timeout-tolerant behavior intact.
- S3 RQ1 -> MISSING: the dismissal model added in S1 needed a unique constraint on `(user_id, announcement_id)` in the same migration and duplicate dismissal handling as success. Added the unique constraint in S1 and implemented `ON CONFLICT DO NOTHING` in S3.
- S4 RQ1 -> MISSING/BLOCKING: no retention window is defined anywhere in config or design; the system design references retention/sweeper policy without a concrete duration. S4 was not implemented.

## Exact new extension points changed
- `backend/app/models/announcement_dismissal.py` — new SQLAlchemy model for per-user/per-announcement dismissals.
- `backend/app/models/__init__.py` — imported/exported `AnnouncementDismissal`.
- `backend/app/migrations/115-create-announcement-dismissals.sql` — new sequential migration creating `announcement_dismissals`, FK to `announcements`, timestamp columns, updated_at trigger, index, and unique constraint `uq_announcement_dismissals_user_announcement`.
- `backend/app/database/announcement_db.py` — added `record_announcement_dismissal`; extended `get_active_announcement` with optional `user_id` dismissal exclusion; made dismissal writes idempotent with PostgreSQL `ON CONFLICT DO NOTHING`.
- `backend/app/services/announcement_service.py` — new service layer for dismissing announcements and fetching active announcements with timeout fail-open handling.
- `backend/app/routes/announcement_routes.py` — added `POST /announcements/{announcement_id}/dismiss`; changed GET `/announcements/active` to delegate through the service with current-user context.
- `backend/app/schemas/announcement_schema.py` — added `AnnouncementDismissResponse`.
- `backend/tests/test_routes/test_announcement_routes.py` — added focused tests for S1 auth/write behavior, S2 per-user active-announcement exclusion, and S3 idempotent double-dismiss.

## Tests run or skipped
- Passed: `backend/.venv/bin/python -m py_compile backend/app/models/announcement_dismissal.py backend/app/database/announcement_db.py backend/app/services/announcement_service.py backend/app/schemas/announcement_schema.py backend/app/routes/announcement_routes.py backend/tests/test_routes/test_announcement_routes.py`.
- Passed: `git -C /private/tmp/kite-skill-evals/appsmith-impl/e3_with_skill_r1 diff --check HEAD`.
- Passed before each commit: `git diff --cached --check`.
- Blocked: `UV_CACHE_DIR=/private/tmp/kite-uv-cache task test -- backend/tests/test_routes/test_announcement_routes.py -q`; `uv` panicked before pytest started: `system-configuration ... Attempted to create a NULL object`.
- Blocked: `UV_CACHE_DIR=/private/tmp/kite-uv-cache task fmt`; `uv sync --group dev` panicked before formatting/linting started with the same `system-configuration ... Attempted to create a NULL object`.
- Blocked: `UV_CACHE_DIR=/private/tmp/kite-uv-cache task test`; `uv` panicked before pytest started with the same `system-configuration ... Attempted to create a NULL object`.

## Architecture check result per committed scenario
- S1: PASS. New slice follows route -> service -> database -> model/migration layering. DB helper leaves transaction ownership to the caller. Migration is sequential/idempotent and persists correctness-critical state. Existing GET route direct DB access was pre-existing and addressed in S2.
- S2: PASS. GET `/announcements/active` now delegates to `announcement_service`; timeout fail-open rollback behavior moved into the service; `announcement_db` owns the query and optional dismissal exclusion without committing.
- S3: PASS. Duplicate-dismiss correctness is enforced by durable unique constraint plus PostgreSQL `ON CONFLICT DO NOTHING`; DB helper performs idempotent write/read without committing.

## Scenario check result per committed scenario
- S1: PASS. Independent `kite-scenario-check` verified signed-in user, POST dismiss by id, dismissal row recorded for `(user, announcement)`, and success response.
- S2: PASS. Independent `kite-scenario-check` verified dismissed active announcement returns no announcement for that user, remains visible to another user, and timeout-tolerant behavior was not obviously regressed.
- S3: PASS. Independent `kite-scenario-check` verified repeat dismissal creates no second row and still returns success.

## Commits created
- `14966f2e6a` — Add announcement dismissal endpoint.
- `52a2bd5352` — Hide dismissed active announcements.
- `c5c00025f8` — Make announcement dismissals idempotent.

## Remaining blockers or uncertainties
- S4 remains blocked pending a defined retention duration and sweeper policy.
- Full backend format/lint/test commands could not run because `uv` panicked in this sandbox before invoking the underlying tools. The repository worktree is clean after the three commits.
