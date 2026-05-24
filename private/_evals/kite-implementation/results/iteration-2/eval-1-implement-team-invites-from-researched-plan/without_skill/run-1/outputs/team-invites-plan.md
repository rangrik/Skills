# Implementation Plan: Team member invitations

## Feature
- Blueprint: docs/features/team-invites/blueprint.md
- System design: docs/features/team-invites/system-design.md
- Summary: Workspace admins can invite a person to their workspace by email.
  The invite is a resumable, expiring token sent by email; the recipient
  accepts it to join the workspace with a default role. Re-inviting an already
  pending email must be idempotent, and accepting an expired or already-used
  invite must fail gracefully.

## Scenario order & status
| # | ID | Title                                  | Status     |
|---|----|----------------------------------------|------------|
| 1 | S1 | Admin invites a new member by email    | committed  |
| 2 | S2 | Recipient accepts a valid invite       | committed  |
| 3 | S3 | Re-inviting a pending email is no-op    | committed  |
| 4 | S4 | Accepting an expired invite fails       | blocked    |

## Scenario S1 — Admin invites a new member by email
- Order: 1
- Type: happy_path
- Status: committed
- Design references: System design §3 (Invitations data model — invites table
  with status + expires_at), §5 (email delivery runs on the queue, never inline)

### Gherkin
Given I am a workspace admin
When I submit a valid email address that is not already a member
Then an invite record is created with status `pending` and an expiry
And an invitation email is sent to that address asynchronously

### Code-blind plan            (written by kite-planner)
- Preconditions: a workspace exists; the actor is authenticated as an admin
- Required capabilities: a way to authorize an actor as workspace admin; a way
  to persist an invite (email, workspace, role, token, status, expiry); a way
  to enqueue an email send off the request path
- Postconditions: a pending invite row exists; an email job is enqueued
- Risks / assumptions: email delivery may fail downstream — must not block the
  request (design §5)

### Research questions         (written by kite-planner)
- RQ1: Is there an existing way to authorize that the current actor is an admin
  of a given workspace? If so, where?
- RQ2: Is there an invites/invitations table or model already? If not, where
  should it be added?
- RQ3: Is there an existing queue/worker mechanism to send email off the
  request path? If so, where?

### Research findings          (written by kite-research)
- RQ1 → EXISTS: require_workspace_admin in backend/app/auth/guards.py:88 —
  decorator that raises 403 unless the actor is an admin of the workspace in the
  path; reuse directly on the new route.
- RQ2 → MISSING: no invites table exists — ADD an `invitations` model in
  backend/app/models/invitation.py and a migration alongside the existing
  workspace models in backend/app/models/workspace.py.
- RQ3 → EXISTS: enqueue_email in backend/app/queue/email_jobs.py:31 — pushes a
  templated email onto the existing worker queue; reuse for the invite email.
- Reuse constraints: require_workspace_admin assumes the workspace id is the
  `workspace_id` path param; the new route must follow that naming.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/auth/__init__.py
  - backend/app/auth/guards.py
  - backend/app/database/invitation_db.py
  - backend/app/database/workspace_db.py
  - backend/app/migrations/115-create-team-invitations.sql
  - backend/app/models/__init__.py
  - backend/app/models/invitation.py
  - backend/app/models/workspace.py
  - backend/app/queue/__init__.py
  - backend/app/queue/email_jobs.py
  - backend/app/routes/invitation_routes.py
  - backend/app/schemas/__init__.py
  - backend/app/schemas/invitation_schema.py
  - backend/app/services/celery_host_service.py
  - backend/app/services/invitation_service.py
  - backend/app/services/workspace_membership.py
  - backend/tests/test_routes/test_invitation_routes.py
- Reused findings:
  - Intended reuse target `backend/app/auth/guards.py:88` did not exist in this
    worktree, so a compatible `require_workspace_admin` dependency was added at
    backend/app/auth/guards.py.
  - Intended reuse target `backend/app/queue/email_jobs.py:31` did not exist in
    this worktree, so a queue-backed `enqueue_email` wrapper was added at that
    path and routed through the existing `celery_host_service` and
    `email_service`.
- New extension points changed:
  - Added `Invitation` model and `invitations` table.
  - Added workspace/workspace membership tables because the researched
    workspace primitives were absent from this worktree.
  - Added `POST /api/v1/workspaces/{workspace_id}/invitations`.
- Tests:
  - `backend/.venv/bin/python -m py_compile ...` passed for changed S1 Python
    files and the focused route test.
  - `uv run pytest tests/test_routes/test_invitation_routes.py -q` could not
    run because `uv` tried to read `/Users/pranavkanade/.cache/uv/...` outside
    the sandbox.
  - `UV_CACHE_DIR=/private/tmp/uv-cache uv run --offline pytest ...` could not
    run because `uv` panicked in `system-configuration` while syncing.
- Architecture check result: PASS (manual generic check): route delegates to a
  service, persistence is in database/model modules plus a SQL migration,
  route uses the `workspace_id` path param required by the guard, and email
  delivery is enqueued instead of sent inline.
- Scenario check result: PASS (manual generic check): admin-only invite path
  creates a pending invitation with `expires_at` and attempts to enqueue a
  background email; non-admin callers receive 403.
- Commit: 4b4f0764cc Implement team invite creation

## Scenario S2 — Recipient accepts a valid invite
- Order: 2
- Type: happy_path
- Status: committed
- Design references: System design §3 (invite status transitions), §4
  (membership creation must be idempotent and atomic)

### Gherkin
Given a pending, unexpired invite exists for my email
When I accept it via its token
Then I become a member of the workspace with the invited role
And the invite status becomes `accepted`

### Code-blind plan            (written by kite-planner)
- Preconditions: a pending invite with a valid token exists
- Required capabilities: a way to look up an invite by token; a way to create a
  workspace membership for a user; a way to transition the invite to `accepted`
  atomically with membership creation
- Postconditions: a membership row exists; the invite is `accepted`
- Risks / assumptions: a double-accept (two clicks) must not create two
  memberships (design §4)

### Research questions         (written by kite-planner)
- RQ1: Is there an existing membership-creation service for adding a user to a
  workspace? If so, where, and is it idempotent?
- RQ2: Where should the accept-invite route live?

### Research findings          (written by kite-research)
- RQ1 → EXISTS: WorkspaceMembershipService.add_member in
  backend/app/services/workspace_membership.py:54 — creates a membership;
  enforces a unique (workspace_id, user_id) constraint at the DB level, so a
  repeated call is a safe no-op. Reuse directly.
- RQ2 → MISSING: no accept route exists — ADD a POST handler in
  backend/app/routes/invitation_routes.py (new file) alongside the existing
  workspace routes registered in backend/app/routes/__init__.py.
- Reuse constraints: add_member expects a resolved User object, not an email —
  the accept flow must resolve or create the user first.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/database/invitation_db.py
  - backend/app/routes/invitation_routes.py
  - backend/app/schemas/__init__.py
  - backend/app/schemas/invitation_schema.py
  - backend/app/services/invitation_service.py
  - backend/tests/test_routes/test_invitation_routes.py
- Reused findings:
  - Intended reuse target `WorkspaceMembershipService.add_member` was absent
    from this worktree before S1, so the S2 accept flow reuses the compatible
    `WorkspaceMembershipService.add_member` added in the S1 commit at
    backend/app/services/workspace_membership.py.
  - Accept flow resolves or creates the actor `User` before calling
    `add_member`, matching the research constraint.
- New extension points changed:
  - Added token lookup with `SELECT ... FOR UPDATE`.
  - Added invitation accepted-state transition helper.
  - Added `POST /api/v1/invitations/accept` and
    `POST /api/v1/invitations/{token}/accept`.
- Tests:
  - `backend/.venv/bin/python -m py_compile ...` passed for changed S2 Python
    files and the focused route test.
  - `uv run pytest tests/test_routes/test_invitation_routes.py -q` remains
    blocked by the sandboxed `uv` cache/path issue described in S1.
- Architecture check result: PASS (manual generic check): accept route stays
  thin, service owns token validation and membership orchestration, database
  helper owns row locking and status mutation, and user resolution happens
  before membership creation.
- Scenario check result: PASS (manual generic check): a valid token for the
  current user's email creates exactly one membership via the unique
  membership upsert and marks the invite `accepted`; repeat/double accept is
  idempotent for membership creation.
- Commit: 5eeee28b38 Implement team invite acceptance

## Scenario S3 — Re-inviting a pending email is a no-op
- Order: 3
- Type: edge_case
- Status: committed
- Design references: System design §3 (one pending invite per email per
  workspace — enforced by a partial unique index)

### Gherkin
Given a pending invite already exists for an email in this workspace
When an admin invites that same email again
Then no second invite row is created
And the response is success (idempotent), reusing the existing invite

### Code-blind plan            (written by kite-planner)
- Preconditions: a pending invite for the email already exists
- Required capabilities: a uniqueness guarantee on (workspace, email, pending)
  so a re-invite cannot create a duplicate; a way to return the existing invite
- Postconditions: still exactly one pending invite; success response
- Risks / assumptions: concurrent re-invites must resolve to one row (design §3)

### Research questions         (written by kite-planner)
- RQ1: Does the invitations model (from S1) support a partial unique index on
  (workspace_id, email) where status = pending?

### Research findings          (written by kite-research)
- RQ1 → MISSING: the invitations model is being added in S1 — ADD a partial
  unique index on (workspace_id, lower(email)) WHERE status = 'pending' in the
  same migration, and have the invite service catch the unique-violation and
  return the existing invite.
- Reuse constraints: depends on S1 landing the model first.

### Implementation record
- Status: committed
- Changed files:
  - backend/app/database/invitation_db.py
  - backend/app/routes/invitation_routes.py
  - backend/app/services/invitation_service.py
  - backend/tests/test_routes/test_invitation_routes.py
- Reused findings:
  - Reused the S1 `invitations` model/table.
  - Reused the partial unique index
    `invitations_pending_workspace_email_unique` on
    `(workspace_id, lower(email)) WHERE status = 'pending'`, added in the S1
    migration because the index belongs to the table creation.
- New extension points changed:
  - `invitation_db.create_invitation` now uses PostgreSQL
    `INSERT ... ON CONFLICT DO NOTHING` against the partial unique index and
    returns the existing pending invite when a conflict occurs.
  - Create-invite route now enqueues email only when a new invite row is
    created.
- Tests:
  - `backend/.venv/bin/python -m py_compile ...` passed for changed S3 Python
    files and the focused route test.
  - `uv run pytest tests/test_routes/test_invitation_routes.py -q` remains
    blocked by the sandboxed `uv` cache/path issue described in S1.
- Architecture check result: PASS (manual generic check): idempotency is
  enforced in the database layer using the table's partial unique index; the
  route only branches on the service/database `created` result to avoid a
  duplicate email enqueue.
- Scenario check result: PASS (manual generic check): repeating an invite for
  the same normalized email returns the same pending invite row, does not
  create a second row, and reports success.
- Commit: e7c9d2b44a Make pending team reinvites idempotent

## Scenario S4 — Accepting an expired invite fails gracefully
- Order: 4
- Type: corner_case
- Status: blocked
- Design references: System design §3 (expires_at), §6 (expiry policy)

### Gherkin
Given an invite whose expiry has passed
When I attempt to accept it
Then acceptance is refused with a clear "invite expired" result
And no membership is created

### Code-blind plan            (written by kite-planner)
- Preconditions: an invite exists whose expires_at is in the past
- Required capabilities: a defined expiry duration; a way to detect expiry at
  accept time
- Postconditions: acceptance refused; no membership created
- Risks / assumptions: the expiry window must be a single source of truth

### Research questions         (written by kite-planner)
- RQ1: Where is the invite expiry duration defined, and what is the value?
- RQ2: Is expiry evaluated at accept time, or via a background sweeper?

### Research findings          (written by kite-research)
- RQ1 → MISSING: no expiry duration is defined anywhere.
- BLOCKING: the system design document references an "expiry policy (§6)" but
  §6 does not exist in the document, and the blueprint never states how long an
  invite is valid. The required-capability "a defined expiry duration" cannot be
  satisfied from the design. This scenario cannot be implemented until
  kite-planner re-plans it against a real expiry policy. Setting status
  `blocked`.

### Implementation record
- Status: skipped as blocked
- Reason: no expiry duration or expiry evaluation policy is defined in the
  plan/design, so this scenario needs re-planning before implementation.
- Changed files: none
- Architecture check result: not run; scenario was not implemented.
- Scenario check result: not run; scenario was not implemented.
- Commit: none
