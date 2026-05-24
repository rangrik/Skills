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
- Commit: `774eb4cd6c feat(team-invites): create pending workspace invites`
- Reused research findings: admin authorization via `require_workspace_admin`;
  invitation persistence as a new `invitations` model/table; async invite email
  through `enqueue_email`.
- Extension points changed: added `backend/app/auth/guards.py`,
  `backend/app/models/invitation.py`, `backend/app/models/workspace.py`,
  `backend/app/database/invitation_db.py`,
  `backend/app/database/workspace_membership_db.py`,
  `backend/app/services/team_invitation_service.py`,
  `backend/app/services/email_jobs.py`, `backend/app/queue/email_jobs.py`,
  `backend/app/routes/invitation_routes.py`,
  `backend/app/schemas/team_invitation_schema.py`, migration
  `backend/app/migrations/115-create-team-invitations.sql`, and focused
  service tests.
- Research mismatch handled: the researched paths for auth, queue, membership,
  route registration, and workspace models were absent in this worktree, so the
  same capabilities were added at the current backend's auto-discovered
  route/service/database/model extension points.
- Tests: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed. Targeted pytest was attempted but skipped
  as environment-blocked because `uv` panicked under the sandbox and the local
  `.venv` had no pytest.
- Architecture check: PASS — route remained thin and auto-discovered, business
  logic stayed in the service, DB modules flushed without committing, durable
  state was in Postgres, and email delivery used the Celery wrapper.
- Scenario check: PASS — independent `kite-scenario-check` verified the admin
  invite creates a pending expiring invite and queues email asynchronously.

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
- Commit: `81b5348682 feat(team-invites): accept workspace invite tokens`
- Reused research findings: membership creation is idempotent behind the
  workspace membership service; add accept handling in
  `backend/app/routes/invitation_routes.py`; resolve or create a local user
  before adding membership.
- Extension points changed: extended `backend/app/database/invitation_db.py`,
  `backend/app/database/workspace_membership_db.py`,
  `backend/app/services/workspace_membership.py`,
  `backend/app/services/team_invitation_service.py`,
  `backend/app/routes/invitation_routes.py`,
  `backend/app/schemas/team_invitation_schema.py`, `backend/app/schemas/__init__.py`,
  and focused service tests.
- Research mismatch handled: the researched class
  `WorkspaceMembershipService.add_member` was absent, so a function-based
  `backend/app/services/workspace_membership.py` was added to match current
  backend service conventions.
- Tests: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed. Targeted pytest was attempted but skipped
  as environment-blocked because `uv` panicked under the sandbox and the local
  `.venv` had no pytest.
- Architecture check: PASS — acceptance rules live in the service, membership
  persistence is in the DB module, the route only maps HTTP to service calls,
  and transaction ownership remains with the request-scoped session.
- Scenario check: PASS — independent `kite-scenario-check` verified accepting a
  valid token creates membership with the invited role and marks the invite
  `accepted`.

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
- Commit: `9a8813561c feat(team-invites): reuse pending invite requests`
- Reused research findings: enforce one pending invite per
  `(workspace_id, lower(email))` and return the existing pending invite on
  re-invite.
- Extension points changed: extended
  `backend/app/migrations/115-create-team-invitations.sql`,
  `backend/app/database/invitation_db.py`,
  `backend/app/services/team_invitation_service.py`, and focused service tests.
- Tests: `python3 -m py_compile ...`, `git diff --check`, and
  `git diff --cached --check` passed. Targeted pytest was attempted but skipped
  as environment-blocked because `uv` panicked under the sandbox and the local
  `.venv` had no pytest.
- Architecture check: PASS — uniqueness is durable in Postgres, the DB helper
  owns insert-or-return-existing behavior, the service suppresses a duplicate
  email enqueue, and no hidden commits were introduced.
- Scenario check: PASS — independent `kite-scenario-check` verified no second
  invite row is created and the existing pending invite is reused successfully.

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
- Status: skipped as blocked.
- Reason: kite-research marked the scenario blocked because no authoritative
  expiry policy exists in the blueprint or system design. Per kite-implementation,
  blocked scenarios were not implemented.
