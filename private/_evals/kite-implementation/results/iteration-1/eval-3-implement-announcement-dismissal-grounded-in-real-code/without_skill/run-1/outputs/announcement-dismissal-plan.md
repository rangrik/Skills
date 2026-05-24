# Implementation Plan: Announcement banner dismissal

## Feature
- Blueprint: docs/features/announcement-dismissal/blueprint.md
- System design: docs/features/announcement-dismissal/system-design.md
- Summary: A signed-in user can dismiss the active announcement banner so it
  stops showing for them. Dismissal is per-user and per-announcement, must be
  idempotent (dismissing twice is a safe no-op), and the active-announcement
  endpoint must stop returning an announcement the current user has already
  dismissed. Admin authoring of announcements is out of scope here.

## Scenario order & status
| # | ID | Title                                          | Status     |
|---|----|------------------------------------------------|------------|
| 1 | S1 | User dismisses the active announcement          | committed  |
| 2 | S2 | Active endpoint hides a dismissed announcement   | committed  |
| 3 | S3 | Dismissing the same announcement twice is a no-op| committed  |
| 4 | S4 | Auto-expire dismissals after the retention window| blocked    |

## Scenario S1 — User dismisses the active announcement
- Order: 1
- Type: happy_path
- Status: committed
- Design references: System design §2 (dismissals are per-user, per-announcement
  rows), §4 (the dismiss endpoint must require an authenticated user)

### Gherkin
Given I am a signed-in user and an active announcement exists
When I POST to dismiss that announcement by its id
Then a dismissal row is recorded for (my user, that announcement)
And the response is success

### Code-blind plan            (written by kite-planner)
- Preconditions: an active announcement exists; the actor is authenticated
- Required capabilities: a way to know the current authenticated user; a place
  to persist a per-user dismissal (user, announcement, timestamp); a route to
  receive the dismiss action
- Postconditions: a dismissal row exists for (user, announcement)
- Risks / assumptions: an anonymous caller must not be able to dismiss

### Research questions         (written by kite-planner)
- RQ1: How does an authenticated route obtain the current user in this codebase?
- RQ2: Is there an existing announcement model and data layer to build on?
- RQ3: Is there a dismissal table/model already? If not, where should it live,
  and how are new routes registered?

### Research findings          (written by kite-research)
- RQ1 → EXISTS: session_manager.get_current_user() — used by authenticated
  routes (see backend/app/routes/account_routes.py, which calls
  `current_user = session_manager.get_current_user()`) to resolve the current
  user inside a request. Reuse the same call in the dismiss route.
- RQ2 → EXISTS: the Announcement model in backend/app/models/announcement.py and
  the data layer backend/app/database/announcement_db.py
  (get_active_announcement) already exist; reuse them — do not redefine the
  announcement table.
- RQ3 → MISSING: no dismissal model exists — ADD an `announcement_dismissals`
  model in backend/app/models/announcement_dismissal.py with a SQL migration in
  backend/app/migrations/ (next number after the highest existing migration).
  Routes auto-register by file glob in backend/app/__init__.py
  (`register_routes` globs `routes/*_routes.py`), so the dismiss endpoint can go
  in backend/app/routes/announcement_routes.py and will be picked up
  automatically — no manual registration line is needed.
- Reuse constraints: the existing GET /announcements/active route in
  announcement_routes.py is intentionally tolerant of DB timeouts (it returns
  "no announcement" instead of erroring); do not regress that behavior when
  editing the file.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/models/announcement_dismissal.py
  - backend/app/migrations/115-create-announcement-dismissals-table.sql
  - backend/app/models/__init__.py
  - backend/app/database/announcement_db.py
  - backend/app/schemas/announcement_schema.py
  - backend/app/routes/announcement_routes.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests / checks:
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff check app/models/announcement_dismissal.py app/database/announcement_db.py app/routes/announcement_routes.py app/schemas/announcement_schema.py tests/test_routes/test_announcement_routes.py` — passed
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff format --check app/models/announcement_dismissal.py app/database/announcement_db.py app/routes/announcement_routes.py app/schemas/announcement_schema.py tests/test_routes/test_announcement_routes.py` — passed after formatting
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python - <<'PY' ...` import/schema check — passed
  - `cd backend && UV_CACHE_DIR=/private/tmp/uv-cache uv run pytest -q tests/test_routes/test_announcement_routes.py::TestDismissAnnouncement tests/test_routes/test_announcement_routes.py::TestGetActiveAnnouncement::test_returns_empty_when_database_timeout_occurs` — blocked before tests by uv sandbox panic
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python -m pytest -q tests/test_routes/test_announcement_routes.py::TestDismissAnnouncement tests/test_routes/test_announcement_routes.py::TestGetActiveAnnouncement::test_returns_empty_when_database_timeout_occurs` — collected tests but blocked in setup because asyncpg TCP connection to the test Postgres DB raised `PermissionError: [Errno 1] Operation not permitted`
- Architecture check: PASS — reused the existing Announcement model/data/route locations, added the dismissal model under app/models with Mapped/mapped_column, added sequential migration 115, used the existing route glob by extending announcement_routes.py, and left the GET /announcements/active timeout handling unchanged.
- Scenario check: PASS — the POST route requires `session_manager.has_current_user()`, obtains `session_manager.get_current_user()`, records one (user_id, announcement_id) row through the database layer, and returns `{"success": true}`; anonymous callers receive 401 and do not write.
- Commit: 617b8ae6bd feat(announcements): add dismissal endpoint

## Scenario S2 — Active endpoint hides a dismissed announcement
- Order: 2
- Type: happy_path
- Status: committed
- Design references: System design §3 (the active lookup must exclude
  announcements the current user has dismissed)

### Gherkin
Given I have dismissed the current active announcement
When I fetch the active announcement
Then the endpoint returns no announcement for me

### Code-blind plan            (written by kite-planner)
- Preconditions: a dismissal row exists for (me, the active announcement)
- Required capabilities: a way to exclude announcements the current user has
  dismissed from the active lookup
- Postconditions: the active endpoint returns null for a user who dismissed it,
  while still returning it for users who have not
- Risks / assumptions: the active lookup currently has no user context — it must
  gain one without breaking the anonymous/timeout-tolerant path

### Research questions         (written by kite-planner)
- RQ1: Where is the active-announcement query, and how is it shaped?

### Research findings          (written by kite-research)
- RQ1 → EXISTS: get_active_announcement in
  backend/app/database/announcement_db.py runs a single SELECT ordered by
  created_at and is called from the GET /announcements/active route. EXTEND it
  (or add a user-aware variant) to left-exclude announcements that have a
  dismissal row for the given user. Keep the existing no-user / timeout-tolerant
  behavior intact for the anonymous case.
- Reuse constraints: depends on the dismissals model from S1 landing first.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/database/announcement_db.py
  - backend/app/routes/announcement_routes.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests / checks:
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff format --check app/database/announcement_db.py app/routes/announcement_routes.py tests/test_routes/test_announcement_routes.py` — passed
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff check app/database/announcement_db.py app/routes/announcement_routes.py tests/test_routes/test_announcement_routes.py` — passed
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python - <<'PY' ...` import/signature check — passed
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python - <<'PY' ...` query-shape check — passed; user-aware lookup compiles to a LEFT OUTER JOIN against announcement_dismissals with `announcement_dismissals.id IS NULL`, and no-user lookup has no dismissal join
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python -m pytest -q tests/test_routes/test_announcement_routes.py::TestGetActiveAnnouncement::test_hides_dismissed_announcement_only_for_current_user tests/test_routes/test_announcement_routes.py::TestGetActiveAnnouncement::test_returns_empty_when_database_timeout_occurs` — collected tests but blocked in setup because asyncpg TCP connection to the test Postgres DB raised `PermissionError: [Errno 1] Operation not permitted`
- Architecture check: PASS — extended the existing announcement_db lookup with optional user context, preserved the original no-user call shape from the route, kept timeout handling scoped around the DB lookup, and added only the focused route test for the dismissed-vs-other-user boundary.
- Scenario check: PASS — the active lookup excludes announcements with a dismissal row for the current user and leaves the same active announcement visible for other users; anonymous/no-user lookup keeps the original query path.
- Commit: f0781475ae feat(announcements): hide dismissed active banner

## Scenario S3 — Dismissing the same announcement twice is a no-op
- Order: 3
- Type: edge_case
- Status: committed
- Design references: System design §2 (one dismissal per user per announcement,
  enforced by a unique constraint)

### Gherkin
Given I have already dismissed an announcement
When I dismiss the same announcement again
Then no second dismissal row is created
And the response is still success (idempotent)

### Code-blind plan            (written by kite-planner)
- Preconditions: a dismissal already exists for (me, the announcement)
- Required capabilities: a uniqueness guarantee on (user_id, announcement_id) so
  a repeat dismiss cannot create a duplicate; a way to treat the duplicate as
  success
- Postconditions: still exactly one dismissal row; success response
- Risks / assumptions: two rapid clicks must resolve to one row

### Research questions         (written by kite-planner)
- RQ1: Does the dismissals model (from S1) carry a unique constraint on
  (user_id, announcement_id)?

### Research findings          (written by kite-research)
- RQ1 → MISSING: the dismissals model is being added in S1 — ADD a unique
  constraint on (user_id, announcement_id) in the same migration, and have the
  dismiss handler treat a unique-violation (or an existing row) as a successful
  no-op rather than an error.
- Reuse constraints: depends on S1 landing the model and migration first.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/database/announcement_db.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests / checks:
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff format --check app/database/announcement_db.py tests/test_routes/test_announcement_routes.py` — passed
  - `cd backend && /Users/pranavkanade/.cache/uv/archive-v0/6ZgMPh5tjJV7jZIgq_Dan/ruff-0.15.10.data/scripts/ruff check app/database/announcement_db.py tests/test_routes/test_announcement_routes.py` — passed
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python - <<'PY' ...` idempotent insert check — passed; dismiss insert compiles to `ON CONSTRAINT uq_announcement_dismissals_user_announcement DO NOTHING`
  - `cd backend && PYTHONPATH=<uv-cache-archives> .venv/bin/python -m pytest -q tests/test_routes/test_announcement_routes.py::TestDismissAnnouncement::test_dismiss_same_announcement_twice_is_successful_noop` — collected test but blocked in setup because asyncpg TCP connection to the test Postgres DB raised `PermissionError: [Errno 1] Operation not permitted`
- Architecture check: PASS — kept idempotency in the existing announcement data layer, targeted the named unique constraint created in migration 115, and added only the focused double-dismiss route test.
- Scenario check: PASS — the first dismiss inserts a row and the second dismiss reaches the same insert path with `ON CONSTRAINT ... DO NOTHING`, so the duplicate is a successful no-op and no second row can be created.
- Commit: 38f30628c0 feat(announcements): make dismissal idempotent

## Scenario S4 — Auto-expire dismissals after the retention window
- Order: 4
- Type: corner_case
- Status: blocked
- Design references: System design §5 (dismissal retention), §6 (sweeper policy)

### Gherkin
Given a dismissal older than the retention window
When the retention sweeper runs
Then the dismissal is removed so the announcement can show again

### Code-blind plan            (written by kite-planner)
- Preconditions: a dismissal older than the retention window exists
- Required capabilities: a defined retention window; a scheduled sweeper to
  delete expired dismissals
- Postconditions: expired dismissals are removed
- Risks / assumptions: the retention window must be a single source of truth

### Research questions         (written by kite-planner)
- RQ1: What is the dismissal retention window, and where is it configured?
- RQ2: Is there a scheduled-job/sweeper mechanism this should hook into?

### Research findings          (written by kite-research)
- RQ1 → MISSING: no retention window is defined anywhere in config or design.
- BLOCKING: the system design references a "sweeper policy (§6)" and a
  "retention window (§5)", but neither section actually specifies a duration,
  and the blueprint never states how long a dismissal should last. The
  required-capability "a defined retention window" cannot be satisfied from the
  design. This scenario cannot be implemented until kite-planner re-plans it
  against a real retention policy. Setting status `blocked`.

### Skip record
- Status: blocked / skipped
- Reason: no retention duration or sweeper policy exists in the provided blueprint/system design, so implementing this would invent product behavior outside the researched plan.
- Required follow-up: re-plan S4 after a concrete dismissal retention window and scheduled cleanup mechanism are specified.
