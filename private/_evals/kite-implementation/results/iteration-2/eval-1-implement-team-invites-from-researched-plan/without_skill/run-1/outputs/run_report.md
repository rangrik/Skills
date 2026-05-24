# Run Report: Team Invites

## Scenarios attempted, in order
1. S1 — Admin invites a new member by email
2. S2 — Recipient accepts a valid invite
3. S3 — Re-inviting a pending email is a no-op

## Scenarios skipped as blocked
- S4 — Accepting an expired invite fails gracefully
  - Skipped because the plan marks it blocked: no invite expiry duration is
    defined, and the referenced system-design expiry policy section is missing.

## Exact reused research findings
- S1 RQ1: `require_workspace_admin in backend/app/auth/guards.py:88` was marked
  EXISTS, but that path did not exist in this worktree. I added a compatible
  `require_workspace_admin` dependency at `backend/app/auth/guards.py`.
- S1 RQ2: no invites table exists. Added `Invitation` in
  `backend/app/models/invitation.py` and SQL migration
  `backend/app/migrations/115-create-team-invitations.sql`.
- S1 RQ3: `enqueue_email in backend/app/queue/email_jobs.py:31` was marked
  EXISTS, but that path did not exist in this worktree. I added a compatible
  queue-backed `enqueue_email` wrapper at `backend/app/queue/email_jobs.py`.
- S2 RQ1: `WorkspaceMembershipService.add_member in
  backend/app/services/workspace_membership.py:54` was marked EXISTS, but that
  path did not exist in this worktree. I added the compatible service in S1 and
  reused it for S2.
- S2 RQ2: no accept route exists. Added accept handlers in
  `backend/app/routes/invitation_routes.py`.
- S3 RQ1: added and used the partial unique index on
  `(workspace_id, lower(email)) WHERE status = 'pending'`.

## Exact new extension points changed
- `backend/app/auth/guards.py`
- `backend/app/database/invitation_db.py`
- `backend/app/database/workspace_db.py`
- `backend/app/migrations/115-create-team-invitations.sql`
- `backend/app/models/invitation.py`
- `backend/app/models/workspace.py`
- `backend/app/queue/email_jobs.py`
- `backend/app/routes/invitation_routes.py`
- `backend/app/schemas/invitation_schema.py`
- `backend/app/services/invitation_service.py`
- `backend/app/services/workspace_membership.py`
- `backend/app/services/celery_host_service.py`
- `backend/tests/test_routes/test_invitation_routes.py`

## Tests run or skipped
- Passed: `backend/.venv/bin/python -m py_compile ...` for the changed backend
  invite files and focused route test.
- Blocked: `uv run pytest tests/test_routes/test_invitation_routes.py -q`
  failed because `uv` tried to read `/Users/pranavkanade/.cache/uv/...`, which
  is outside the sandbox.
- Blocked: `UV_CACHE_DIR=/private/tmp/uv-cache uv sync --offline` and
  `UV_CACHE_DIR=/private/tmp/uv-cache uv run --offline pytest ...` panicked in
  `system-configuration`.
- Blocked: `UV_CACHE_DIR=/private/tmp/uv-cache uv run --offline --no-sync
  pytest tests/test_routes/test_invitation_routes.py -q` failed because pytest
  is not installed in the sandbox-created `.venv`.
- Full `task fmt` / `task test` skipped for the same Python dependency
  environment blocker.

## Architecture check result per committed scenario
- S1: PASS, manual generic check. Route delegates to service; persistence is in
  database/model/migration files; admin guard uses `workspace_id`; email send is
  enqueued rather than sent inline.
- S2: PASS, manual generic check. Accept route stays thin; service owns token
  validation/user resolution/membership orchestration; database helper owns row
  locking and status mutation.
- S3: PASS, manual generic check. Idempotency is enforced through the partial
  unique index and database insert conflict handling; route avoids duplicate
  email enqueue based on the `created` result.

## Scenario check result per committed scenario
- S1: PASS, manual generic check. Admin invite creates a pending invite with
  expiry and queues email; non-admin invite returns 403.
- S2: PASS, manual generic check. Valid token for the current user's email adds
  one membership and marks the invite accepted; double accept remains
  membership-idempotent.
- S3: PASS, manual generic check. Re-inviting the same normalized pending email
  returns the same invite and leaves exactly one pending row.

## Commits created
- `4b4f0764cc` — Implement team invite creation
- `5eeee28b38` — Implement team invite acceptance
- `e7c9d2b44a` — Make pending team reinvites idempotent

## Remaining blockers or uncertainties
- S4 remains blocked until the product/design source defines a concrete invite
  expiry duration and accept-time expiry behavior.
- The researched EXISTING files for workspace admin guard, email queue job, and
  workspace membership service were absent in this worktree, so compatible
  local implementations were added.
- Full pytest/format verification could not run in this sandbox because the
  Python dependency environment could not be synced.
