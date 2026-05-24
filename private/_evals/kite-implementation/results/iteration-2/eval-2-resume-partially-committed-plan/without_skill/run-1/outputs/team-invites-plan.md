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

### Implementation record      (written by benchmark child run)
- Commit: fd26c01c7d feat(team-invites): email pending collaborator invites
- Actual codebase reconciliation: the plan's workspace-specific symbols
  (`backend/app/auth/guards.py`, `backend/app/queue/email_jobs.py`,
  `backend/app/models/workspace.py`) were not present in this checkout. The
  existing collaboration surface is website-scoped: `WebsiteInvite` and
  `WebsiteCollaboration` in `backend/app/models/website_collaboration.py`,
  owner authorization in `website_collaboration_service._require_owner`, and
  route gating through `slack_access.require_website_slack_access`.
- Extension points changed: added `WebsiteInviteStatus`, migration
  `115-add-status-to-website-invites.sql`, invite status on the model/schema,
  required invitee email in the request schema/frontend type, Celery-backed
  `send_website_invite_email_task`, `enqueue_invite_email`, route-side commit
  before email dispatch, and a focused route test.
- Architecture check: PASS (manual) — route delegates business logic to the
  service, DB writes remain in the database layer, email delivery is Celery
  dispatched after commit, and frontend type/copy stays in sync with the
  backend schema.
- Scenario check: PASS (manual) — owner invite creates a pending row with
  expiry and dispatches email asynchronously; added test
  `test_create_invite_creates_pending_invite_and_enqueues_email`.
- Verification: `python3 -m py_compile ...` passed; `git diff --check` passed.
  `uv run pytest ...` could not run because `uv` panicked in macOS
  SystemConfiguration before dependency sync.

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

### Implementation record      (written by benchmark child run)
- Commit: 307f7fedca feat(team-invites): accept email-bound collaborator invites
- Actual codebase reconciliation: no `WorkspaceMembershipService.add_member`
  exists in this checkout. The existing equivalent is
  `website_collaboration_db.add_collaboration`, called through
  `website_collaboration_service.accept_invite`; the accept route already lives
  in `backend/app/routes/website_collaborations_routes.py`.
- Extension points changed: invite acceptance now rejects an email-bound invite
  when the current actor email does not match the invited email; the accepted
  status transition is persisted by `mark_invite_accepted`.
- Architecture check: PASS (manual) — token validation, membership creation,
  and status transition remain in the service/database layers; route behavior
  still handles draft provisioning separately.
- Scenario check: PASS (manual) — accepting a valid invite adds the collaborator
  and marks the invite accepted; added test
  `test_accept_invite_adds_collaboration_and_marks_invite_accepted`.
- Verification: `python3 -m py_compile ...` passed; `git diff --check` passed.
  Full pytest remained blocked by the `uv` panic.

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

### Implementation record      (written by benchmark child run)
- Commit: 6c491f3dfd feat(team-invites): reuse pending collaborator invites
- Actual codebase reconciliation: applied the plan's partial-unique-index
  requirement to the existing `website_invites` table as
  `(website_id, lower(invited_email)) WHERE status = 'pending' AND invited_email
  IS NOT NULL`.
- Extension points changed: added migration
  `116-unique-pending-website-invites.sql`, database
  `get_or_create_pending_invite`, service result metadata indicating created
  versus reused invite, route-side skip of duplicate email dispatch for reused
  invites, and a route regression test.
- Architecture check: PASS (manual) — concurrency protection is enforced at the
  database index/upsert layer, while the route only uses the service's
  created/reused result to decide whether to enqueue email.
- Scenario check: PASS (manual) — re-inviting an existing pending email returns
  success with the same invite/token, keeps one pending row, and sends no
  second email; added test
  `test_reinviting_pending_email_reuses_invite_without_second_email`.
- Verification: `python3 -m py_compile ...` passed; `git diff --check` passed.
  Full pytest remained blocked by the `uv` panic.

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
