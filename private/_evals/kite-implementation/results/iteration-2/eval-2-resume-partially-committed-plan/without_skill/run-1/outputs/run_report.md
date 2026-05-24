# Run Report: Team Invites

## Scenarios Attempted, In Order

1. S1 — Admin invites a new member by email
2. S2 — Recipient accepts a valid invite
3. S3 — Re-inviting a pending email is no-op

## Scenarios Skipped As Blocked

- S4 — Accepting an expired invite fails: skipped because the plan copy marks it
  `blocked`; its research says no invite expiry duration is defined and the
  referenced system-design expiry policy is missing.

## Exact Reused Research Findings

- S1 RQ1 plan finding: `require_workspace_admin in backend/app/auth/guards.py:88`.
  Actual checkout result: not present. Reused existing owner/admin analogue:
  `website_collaboration_service._require_owner` plus
  `slack_access.require_website_slack_access` on
  `/applications/{application_id}/collaborations/invites`.
- S1 RQ2 plan finding: `no invites table exists`.
  Actual checkout result: stale. Reused existing `WebsiteInvite` and
  `WebsiteCollaboration` in `backend/app/models/website_collaboration.py` and
  migration `109-create-website-collaborations.sql`; extended them with status.
- S1 RQ3 plan finding: `enqueue_email in backend/app/queue/email_jobs.py:31`.
  Actual checkout result: not present. Reused existing Celery task infrastructure
  in `backend/app/services/celery_host_service.py` and email sender
  `backend/app/services/email_service.py`.
- S2 RQ1 plan finding:
  `WorkspaceMembershipService.add_member in backend/app/services/workspace_membership.py:54`.
  Actual checkout result: not present. Reused existing collaborator membership
  path `website_collaboration_db.add_collaboration`, called by
  `website_collaboration_service.accept_invite`.
- S2 RQ2 plan finding: `no accept route exists`.
  Actual checkout result: stale. Reused existing accept route
  `POST /api/v1/invites/{token}/accept` in
  `backend/app/routes/website_collaborations_routes.py`.
- S3 RQ1 plan finding: add partial unique index on pending invites.
  Actual checkout result: still missing. Implemented on existing
  `website_invites` as `(website_id, lower(invited_email)) WHERE status =
  'pending' AND invited_email IS NOT NULL`.

## Exact New Extension Points Changed

- `backend/app/all_enums.py`: added `WebsiteInviteStatus`.
- `backend/app/migrations/115-add-status-to-website-invites.sql`: added invite
  status and status check constraint.
- `backend/app/migrations/116-unique-pending-website-invites.sql`: dedupes
  duplicate pending invites and adds the partial unique index.
- `backend/app/models/website_collaboration.py`: added `WebsiteInvite.status`.
- `backend/app/schemas/website_collaboration_schema.py`: made invite email
  required and exposed invite status.
- `backend/app/database/website_collaboration_db.py`: normalized invite emails,
  added pending invite lookup, get-by-id, upsert/reuse for pending invites,
  accepted status transition, and token lookup status filtering.
- `backend/app/services/website_collaboration_service.py`: added invitee
  validation, created/reused result metadata, email-bound acceptance,
  `send_website_invite_email_task`, and `enqueue_invite_email`.
- `backend/app/routes/website_collaborations_routes.py`: commits invite creation
  before dispatching email, dispatches only for newly-created invites, and
  returns reused invite details for idempotent re-invites.
- `backend/tests/test_routes/test_website_collaboration_routes.py`: added focused
  route/service tests for S1-S3.
- `frontend/src/data/WebsiteCollaboration/types.ts`: synced required invite email
  and status.
- `frontend/src/pages/AppDetails/pages/SettingsPage/components/CollaboratorsModal.tsx`:
  requires email input and updates copy for emailed invites.
- `agent-context/prds/2026-05-23-team-invites.md`: added required PRD and checked
  off S1-S3.

## Tests Run Or Explicitly Skipped

- `pwd && git status --short`: passed before coding; cwd was the throwaway
  worktree and status was clean.
- `python3 -m py_compile backend/app/all_enums.py backend/app/models/website_collaboration.py backend/app/database/website_collaboration_db.py backend/app/services/website_collaboration_service.py backend/app/routes/website_collaborations_routes.py backend/app/schemas/website_collaboration_schema.py backend/tests/test_routes/test_website_collaboration_routes.py`: passed.
- `git diff --check HEAD~3..HEAD`: passed.
- `UV_CACHE_DIR=/private/tmp/uv-cache uv run pytest tests/test_routes/test_website_collaboration_routes.py -q`: skipped/blocked by environment; `uv` panicked before dependency sync with `system-configuration ... Attempted to create a NULL object`.
- `UV_CACHE_DIR=/private/tmp/uv-cache uv run ruff check --fix ...` and
  `UV_CACHE_DIR=/private/tmp/uv-cache uv run ruff format ...`: skipped/blocked
  for the same `uv` panic.
- `pnpm lint`: skipped/blocked by environment; frontend dependencies are not
  installed and ESLint failed to resolve `eslint-plugin-storybook`.
- `pnpm exec prettier --write ...`: skipped/blocked; `prettier` was not present
  in local frontend dependencies.

## Architecture Check Result Per Committed Scenario

- S1: PASS (manual). The existing website-collaboration route remains thin,
  business validation lives in the service, persistence lives in the database
  module/model/migration, and invite email is Celery-dispatched after the invite
  transaction commits.
- S2: PASS (manual). Token validation, invited-email authorization,
  collaborator creation, and invite status transition remain in the
  service/database layers; the existing route still owns draft provisioning.
- S3: PASS (manual). Idempotency is enforced by a database partial unique index
  and PostgreSQL upsert; the route only uses service metadata to avoid duplicate
  email dispatch.

## Scenario Check Result Per Committed Scenario

- S1: PASS (manual). A website owner submitting a valid non-member email creates
  a `pending` invite with `expires_at` and enqueues an invitation email
  asynchronously. Added test:
  `test_create_invite_creates_pending_invite_and_enqueues_email`.
- S2: PASS (manual). A matching invitee accepting a valid token is added as a
  collaborator and the invite becomes `accepted`. Added test:
  `test_accept_invite_adds_collaboration_and_marks_invite_accepted`.
- S3: PASS (manual). Re-inviting the same pending email returns success with the
  same invite/token, preserves exactly one pending row, and does not send a
  second email. Added test:
  `test_reinviting_pending_email_reuses_invite_without_second_email`.

## Commits Created

- `fd26c01c7d feat(team-invites): email pending collaborator invites`
- `307f7fedca feat(team-invites): accept email-bound collaborator invites`
- `6c491f3dfd feat(team-invites): reuse pending collaborator invites`

## Remaining Blockers Or Uncertainties

- S4 remains blocked exactly as the plan states: the benchmark plan says the
  expiry duration is undefined and must be re-planned against a real expiry
  policy. I did not implement S4.
- Full backend pytest/ruff and frontend lint/prettier were not runnable in this
  sandbox because backend dependency sync hit a `uv` panic and frontend
  `node_modules` is incomplete.
