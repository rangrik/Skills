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
- Changed files:
  - backend/app/models/announcement_dismissal.py
  - backend/app/models/__init__.py
  - backend/app/migrations/115-create-announcement-dismissals.sql
  - backend/app/database/announcement_db.py
  - backend/app/services/announcement_service.py
  - backend/app/schemas/announcement_schema.py
  - backend/app/routes/announcement_routes.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests:
  - `backend/.venv/bin/python -m py_compile backend/app/models/announcement_dismissal.py backend/app/database/announcement_db.py backend/app/services/announcement_service.py backend/app/schemas/announcement_schema.py backend/app/routes/announcement_routes.py backend/tests/test_routes/test_announcement_routes.py` — passed
  - `git diff --cached --check` — passed before commit
  - `task test -- backend/tests/test_routes/test_announcement_routes.py -q` — skipped/blocked because `uv` panicked in the sandbox while creating/syncing the environment (`system-configuration ... Attempted to create a NULL object`)
- Architecture check: PASS — new S1 slice follows route -> service -> database -> model/migration layering; database helper flushes without committing; migration 115 is sequential/idempotent and persists correctness-critical state. Existing GET route direct-db access was pre-existing and left for the S2 active-endpoint slice.
- Scenario check: PASS — independent `kite-scenario-check` subagent verified every S1 Gherkin clause and found no missing behavior or drift.
- Commit: 14966f2e6a Add announcement dismissal endpoint

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
- Changed files:
  - backend/app/database/announcement_db.py
  - backend/app/services/announcement_service.py
  - backend/app/routes/announcement_routes.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests:
  - `backend/.venv/bin/python -m py_compile backend/app/database/announcement_db.py backend/app/services/announcement_service.py backend/app/routes/announcement_routes.py backend/tests/test_routes/test_announcement_routes.py` — passed
  - `git diff --cached --check` — passed before commit
  - `task test -- backend/tests/test_routes/test_announcement_routes.py -q` — skipped/blocked because `uv` panicked in the sandbox while creating/syncing the environment (`system-configuration ... Attempted to create a NULL object`)
- Architecture check: PASS — GET /announcements/active now delegates to announcement_service; the service preserves timeout fail-open rollback behavior and delegates query shape to announcement_db; the database function gained optional user-aware dismissal exclusion without owning transaction commits.
- Scenario check: PASS — independent `kite-scenario-check` subagent verified S2 and found no missing behavior or drift; it also found no obvious regression to the timeout-tolerant path.
- Commit: 52a2bd5352 Hide dismissed active announcements

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
- Changed files:
  - backend/app/database/announcement_db.py
  - backend/tests/test_routes/test_announcement_routes.py
- Tests:
  - `backend/.venv/bin/python -m py_compile backend/app/database/announcement_db.py backend/tests/test_routes/test_announcement_routes.py` — passed
  - `git diff --cached --check` — passed before commit
  - `task test -- backend/tests/test_routes/test_announcement_routes.py -q` — skipped/blocked because `uv` panicked in the sandbox while creating/syncing the environment (`system-configuration ... Attempted to create a NULL object`)
- Architecture check: PASS — duplicate-dismiss correctness is enforced by the durable unique constraint added in S1 and handled with PostgreSQL `ON CONFLICT DO NOTHING`; the database helper performs the idempotent write and read without committing the caller-owned transaction.
- Scenario check: PASS — independent `kite-scenario-check` subagent verified S3 and found no missing behavior or drift.
- Commit: c5c00025f8 Make announcement dismissals idempotent

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

### Implementation record
- Status: skipped as blocked.
- Reason: kite-research marked S4 blocked because neither the blueprint nor the system design defines the dismissal retention duration or a concrete sweeper policy. This needs kite-planner re-planning before implementation.
- Changed files: none.
- Commit: none.
