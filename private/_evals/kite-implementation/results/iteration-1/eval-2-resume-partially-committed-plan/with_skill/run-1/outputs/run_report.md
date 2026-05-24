# Run Report: Team member invitations

## Scenarios attempted, in order
1. S1 — Admin invites a new member by email — committed.
2. S2 — Recipient accepts a valid invite — committed.
3. S3 — Re-inviting a pending email is no-op — committed.
4. S4 — Accepting an expired invite fails — skipped as blocked.

## Scenarios skipped as blocked
- S4 — kite-research marked this blocked because no authoritative expiry policy
  exists in the blueprint or system design. Per kite-implementation, it was not
  implemented.

## Exact reused research findings
- S1 RQ1: `require_workspace_admin in backend/app/auth/guards.py:88` should gate
  the route and assumes the path param is `workspace_id`.
- S1 RQ2: no invites table exists; add `invitations` model in
  `backend/app/models/invitation.py` and migration alongside workspace models.
- S1 RQ3: `enqueue_email in backend/app/queue/email_jobs.py:31` should enqueue a
  templated invite email off the request path.
- S2 RQ1: `WorkspaceMembershipService.add_member` creates membership and relies
  on a unique `(workspace_id, user_id)` DB constraint for idempotency.
- S2 RQ2: add the accept route in `backend/app/routes/invitation_routes.py`.
- S2 reuse constraint: accept flow resolves or creates the user before calling
  membership creation.
- S3 RQ1: add a partial unique index on `(workspace_id, lower(email)) WHERE
  status = 'pending'` and return the existing invite on conflict.
- S4 RQ1: no expiry duration is defined; scenario remains blocked pending
  re-planning against a real expiry policy.

Research mismatch handled: several researched "EXISTS" paths were absent in
this worktree (`backend/app/auth/guards.py`, `backend/app/queue/email_jobs.py`,
`backend/app/services/workspace_membership.py`, route registration file, and
workspace model file). The implementation added equivalent capabilities at the
current backend's auto-discovered route/service/database/model extension points.

## Exact new extension points changed
- Added `backend/app/auth/__init__.py`
- Added `backend/app/auth/guards.py`
- Added `backend/app/models/invitation.py`
- Added `backend/app/models/workspace.py`
- Updated `backend/app/models/__init__.py`
- Added `backend/app/database/invitation_db.py`
- Added `backend/app/database/workspace_membership_db.py`
- Added `backend/app/services/team_invitation_service.py`
- Added `backend/app/services/workspace_membership.py`
- Added `backend/app/services/email_jobs.py`
- Added `backend/app/queue/__init__.py`
- Added `backend/app/queue/email_jobs.py`
- Added `backend/app/routes/invitation_routes.py`
- Added `backend/app/schemas/team_invitation_schema.py`
- Updated `backend/app/schemas/__init__.py`
- Added `backend/app/migrations/115-create-team-invitations.sql`
- Added `backend/tests/test_services/test_team_invitation_service.py`

## Tests run or explicitly skipped
- Initial worktree verification: `pwd` returned the throwaway worktree and
  `git status --short` was clean.
- S1: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed.
- S2: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed.
- S3: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed.
- Targeted pytest attempted:
  `cd backend && uv run pytest -q tests/test_services/test_team_invitation_service.py`
  and scenario-specific variants. Skipped as environment-blocked because `uv`
  first hit sandbox-denied global cache access, then panicked with
  `Attempted to create a NULL object`; the repo-local `.venv` had no `pytest`.
- Full `task fmt` / `task test` skipped for the same environment blocker.

## Architecture check result per committed scenario
- S1: PASS. Route is thin and auto-discovered, service owns invite business
  logic, DB modules flush without committing, state is durable in Postgres, and
  email delivery is queued through the Celery wrapper.
- S2: PASS. Token HTTP mapping stays in the route, acceptance rules live in the
  service, membership persistence is in the DB module, and transaction ownership
  remains with the request-scoped session.
- S3: PASS. Pending-email uniqueness is enforced durably by a partial unique
  index; insert-or-return-existing lives in the DB helper; service returns the
  existing invite without a second email enqueue.

## Scenario check result per committed scenario
- S1: PASS from independent `kite-scenario-check`.
- S2: PASS from independent `kite-scenario-check`.
- S3: PASS from independent `kite-scenario-check`.

## Commits created
- `774eb4cd6c feat(team-invites): create pending workspace invites`
- `81b5348682 feat(team-invites): accept workspace invite tokens`
- `9a8813561c feat(team-invites): reuse pending invite requests`

## Remaining blockers or uncertainties
- S4 remains blocked until the product/design source defines a concrete invite
  expiry policy.
- Pytest and full repo quality commands could not be run in this sandbox because
  `uv` failed before dependency/test execution.
