# Implementation Plan: Admin Announcement Banner

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-system-design.md
- Summary: Build a workspace-scoped admin announcement banner that workspace admins can publish, edit, schedule, replace, and remove. The banner is shown at the top of the app to authenticated users in the workspace, can be dismissed per user across devices and sessions, and is governed by a single-active-banner invariant. The implementation is code-blind planned around the design's two-table Postgres model, synchronous REST-style writes, user-aware active-banner polling, feature-flag rollout, admin-only write authorization, query-time scheduling, and graceful failure behavior.

## Scenario Inventory
| ID | Title | Type | Blueprint / design coverage |
|---|---|---|---|
| S1 | Feature flag, admin entry point, and no-active-banner baseline | edge_case | Admin opens Announcements page; no banner active; feature flag rollout/fail-closed behavior |
| S2 | Admin publishes an immediate banner and users see it | happy_path | Publish plain-text banner with optional link; active immediately when no start date is provided; users see it within a short time |
| S3 | Publish validation rejects invalid input | edge_case | Message length/plain text; invalid link; end date before start date |
| S4 | Scheduled activation and expiry are enforced at read time | edge_case | Future start date hides banner until then; end date stops showing it; no end date persists until removal |
| S5 | User dismisses a banner and dismissal persists per user | happy_path | User clicks x; banner does not return across devices or sessions; dismiss retry/idempotency behavior |
| S6 | A user who joins after publication sees the active banner | edge_case | New workspace user sees still-active banner if they have not dismissed that banner |
| S7 | Admin edits active banner text without resetting dismissals | deviation | Edit active banner text; dismissed users still do not see it; non-dismissed users receive updated text |
| S8 | Admin removes a banner early | happy_path | Admin clicks Remove; banner stops showing for everyone before its scheduled end |
| S9 | Publishing a new banner replaces the previous active banner | edge_case | At most one active banner per workspace; new publish replaces old active banner; dismissals are tied to banner identity |
| S10 | Concurrent admin writes resolve without illegal active states | deviation | Publish/edit race; simultaneous publish conflict; most recent valid publish controls the active banner |
| S11 | Non-admin write attempts are rejected | corner_case | Only workspace admins may create, edit, or remove; crafted non-admin publish request must fail |
| S12 | Failures degrade according to the banner's criticality | edge_case | Poll failure renders no disruptive error; admin and dismiss failures surface actionable errors; observability and rollout signals exist |

## Scenario Order & Status
| # | ID | Title | Status | Ordering rationale |
|---|---|---|---|---|
| 1 | S1 | Feature flag, admin entry point, and no-active-banner baseline | planned | Establishes the gated surfaces, workspace context, and empty read path that every later scenario uses. |
| 2 | S2 | Admin publishes an immediate banner and users see it | planned | Builds the first end-to-end vertical slice: persistence, admin write, active read, polling, and rendering. |
| 3 | S3 | Publish validation rejects invalid input | planned | Hardens the write path created in S2 before scheduling, replacement, and edit flows depend on it. |
| 4 | S4 | Scheduled activation and expiry are enforced at read time | planned | Extends S2's active-banner read with time-window filtering used by publish, remove, and joined-user scenarios. |
| 5 | S5 | User dismisses a banner and dismissal persists per user | planned | Adds the server-side dismissal identity required before edit, replacement, and joined-user behavior can be proven. |
| 6 | S6 | A user who joins after publication sees the active banner | planned | Reuses S2, S4, and S5 to prove visibility is derived from workspace membership plus absence of dismissal, not recipient fan-out. |
| 7 | S7 | Admin edits active banner text without resetting dismissals | planned | Builds on S5's dismissal identity and S2's poll/render path while preserving banner identity. |
| 8 | S8 | Admin removes a banner early | planned | Reuses the active banner model and read filtering, then adds explicit early termination behavior. |
| 9 | S9 | Publishing a new banner replaces the previous active banner | planned | Builds on publish, dismissal, and time-window behavior to enforce the one-active-banner invariant. |
| 10 | S10 | Concurrent admin writes resolve without illegal active states | planned | Hardens S7 and S9 against races once the normal write paths and invariant are defined. |
| 11 | S11 | Non-admin write attempts are rejected | planned | Applies the security boundary across all admin write capabilities after their surfaces are known. |
| 12 | S12 | Failures degrade according to the banner's criticality | planned | Adds failure handling, backoff, logging, metrics, and rollout verification across the completed feature surface. |

## Scenario S1 — Feature Flag, Admin Entry Point, And No-Active-Banner Baseline
- Order: 1
- Type: edge_case
- Status: planned
- Design references: §2 System Placement; §8 Security & Privacy; §10 Rollout & Operability; A7 feature-flag assumption; D4 workspace-scoped active poll response; feature flag `announcement_banner_enabled` fail-closed behavior.

### Gherkin
Given the announcement banner feature is disabled
When a workspace admin opens admin settings or an authenticated user loads the app shell
Then the Announcements settings entry and app banner surface are absent, and backend announcement routes do not allow accidental use

Given the announcement banner feature is enabled and no banner is active for the workspace
When a workspace admin opens the Announcements page and a workspace user loads the app shell
Then the admin can see the announcement publishing controls, and the user sees no banner

### Code-blind plan
- Preconditions: The product can identify the current workspace and current user for both admin settings and app-shell requests. A rollout control exists or can be introduced in the smallest form that satisfies the design's fail-closed requirement.
- Required capabilities: A feature flag decision that gates backend announcement routes, admin settings navigation, and the app-shell banner component; an admin settings entry point for a workspace admin to open Announcements; an app-shell location above the main content where a global banner can render or render nothing; an active-banner read contract that can represent "no active banner" without a user-visible error; consistent empty-state UI for the admin page when no banner exists.
- Postconditions: With the flag off, the feature is invisible and unavailable. With the flag on and no active banner, admins can reach the Announcements page, authenticated users see no banner, and the empty state is treated as normal rather than an error.
- Risks / assumptions: The design allows either a dedicated flag system or a simpler environment/config flag, but the behavior must fail closed. The no-active-banner state must not be confused with an outage; later observability needs to distinguish normal misses from errors.

### Research questions
- RQ1: Is there an existing feature flag or configuration mechanism that can gate both frontend surfaces and backend route behavior, and how should fail-closed behavior be implemented?
- RQ2: Is there an existing admin settings navigation or panel extension point for adding an Announcements page for workspace admins?
- RQ3: Is there an existing app-shell location intended for global, top-of-app banners or notices?
- RQ4: Is there an existing authenticated workspace context available to both admin settings and app-shell requests, and what shape does it expose for user and workspace identity?
- RQ5: Is there an existing API response and frontend pattern for a normal empty state, distinct from an error state?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S2 — Admin Publishes An Immediate Banner And Users See It
- Order: 2
- Type: happy_path
- Status: planned
- Design references: §1 Summary; §2 route/component placement; D1 server-side persistence; D2 one-active invariant; D3 short-polling; D4 combined active-banner response; D5 synchronous admin writes; §4 data model and publish-replaces transaction; §6 latency targets.

### Gherkin
Given the announcement feature is enabled and a workspace admin is on the Announcements page
When the admin enters a non-empty plain-text message of at most 200 characters, optionally adds a valid link, leaves the start date empty, and publishes
Then the banner becomes active immediately for that workspace
And authenticated users in that workspace see a single-line banner with the message and optional link at the top of the app within the polling window

### Code-blind plan
- Preconditions: S1 is complete. The system can persist workspace-scoped announcement records and serve authenticated app-shell reads.
- Required capabilities: A migration path for the announcement storage model; a workspace-scoped announcement record with message, optional link, start/end timestamps, status, creator, and audit timestamps; a synchronous admin publish operation that writes an active announcement; an authenticated active-banner read that returns at most one displayable banner for the user's workspace; a polling frontend data-fetch path with a default 30-second cadence; a banner component that renders plain text and an optional safe link without rich text or HTML parsing.
- Postconditions: A workspace admin can create an immediate announcement, the system stores it as the active banner for that workspace, and users see it without needing a page refresh beyond the polling interval.
- Risks / assumptions: The design assumes Node/Express, Postgres, React, and UUID-compatible keys. The plan must preserve plain-text rendering and avoid logging banner text. Polling freshness is intentionally "within a short time," not real time.

### Research questions
- RQ1: What migration mechanism should create the announcement persistence structures, indexes, and rollback path?
- RQ2: Is there an existing database access or transaction helper appropriate for synchronous admin writes?
- RQ3: Where should a new workspace-admin announcement publish route be registered within the backend route structure?
- RQ4: Where should the authenticated active-banner read route be registered for app-level user polling?
- RQ5: What frontend data-fetching pattern supports recurring polling with a configurable interval?
- RQ6: What existing design-system or UI primitives should render a top-of-app single-line banner with a dismiss control and optional link?
- RQ7: Is there an existing safe-link component or URL-rendering convention that should be reused for the optional link?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S3 — Publish Validation Rejects Invalid Input
- Order: 3
- Type: edge_case
- Status: planned
- Design references: §4 data invariants; §8 Input validation and XSS mitigation; A6 plain-text assumption; §13 open risk for optional link display text.

### Gherkin
Given the announcement feature is enabled and a workspace admin is composing a banner
When the admin submits an empty message, a message longer than 200 characters, non-plain-text content, an invalid or non-HTTPS link, an invalid timestamp, or an end date before the start date
Then publishing is rejected with a clear validation message
And no active banner is created or changed by that invalid request

### Code-blind plan
- Preconditions: S2's publish route and form exist in a basic valid-input form.
- Required capabilities: Server-side validation for non-empty message text capped at 200 characters; plain-text treatment of message input with no markdown or HTML rendering semantics; optional link validation that accepts only well-formed HTTPS URLs; timestamp parsing for optional start and end fields; date ordering validation that requires the end date to be after the start date when both are present; frontend form validation and error display that mirrors server-side rules without being the only enforcement.
- Postconditions: Invalid publish attempts fail before changing announcement state. Admins receive actionable messages, and the active banner remains unchanged.
- Risks / assumptions: The blueprint mentions an optional link but does not specify separate link display text. The design assumes the URL itself or a fixed label can be rendered unless product behavior later adds a link-label field. Validation must happen on the server even if the frontend prevents common mistakes.

### Research questions
- RQ1: Is there an existing request validation library or schema pattern for backend route inputs that should define announcement publish validation?
- RQ2: Is there an existing frontend form validation and field-error pattern for admin settings forms?
- RQ3: Is there an existing URL validation helper that enforces HTTPS-only links and blocks unsafe schemes?
- RQ4: Is there an existing timestamp parsing and timezone convention for admin-entered date/time fields?
- RQ5: Is there an existing text input component or utility that enforces or displays a 200-character maximum?
- RQ6: How do existing admin write routes return validation errors so that no state changes occur and the UI can show field-level or form-level messages?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S4 — Scheduled Activation And Expiry Are Enforced At Read Time
- Order: 4
- Type: edge_case
- Status: planned
- Design references: D3 short-polling; D6 query-time start/end filtering; §4 `starts_at` and `ends_at` semantics; §6 freshness trade-off; §13 clock-skew callout.

### Gherkin
Given an admin publishes a banner with a future start date
When users poll for the active banner before that start date
Then no banner is shown

Given the start date has arrived
When users poll for the active banner
Then the banner is shown if it has not expired and the user has not dismissed it

Given a banner has an end date in the past
When users poll for the active banner
Then the banner is not shown

Given a banner has no end date
When users poll for the active banner after it starts
Then the banner continues to show until it is removed or replaced

### Code-blind plan
- Preconditions: S2's publish and active read paths exist; S3's date validation prevents invalid start/end ordering.
- Required capabilities: Optional start and end date inputs in the admin form; server-side defaulting of missing start date to immediate activation; storage of nullable end date to mean no automatic expiry; active-banner read filtering based on authoritative server/database time; polling refresh that naturally reflects future activation and expiry without a scheduled job; user-facing date handling that avoids relying on browser clock correctness for visibility decisions.
- Postconditions: The app shows scheduled banners only inside their active window. Expired banners disappear for everyone without a background job, and banners without an end date remain visible until an explicit state-changing action occurs.
- Risks / assumptions: The design intentionally uses query-time filtering rather than an expiry worker. Browser/server clock skew can make "start now" feel delayed if the UI uses local time without clarifying server-relative behavior.

### Research questions
- RQ1: What existing date/time input components and timezone conventions are used in admin settings?
- RQ2: Is there an existing server/database time helper or query convention for comparing timestamps against authoritative current time?
- RQ3: Where should default start-time behavior be applied so an omitted start date means active immediately?
- RQ4: Is there an existing API serialization convention for nullable timestamps and display timestamps?
- RQ5: Are there existing tests or utilities for time-dependent backend behavior that can cover future starts and expiry without a scheduled job?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S5 — User Dismisses A Banner And Dismissal Persists Per User
- Order: 5
- Type: happy_path
- Status: planned
- Design references: D1 server-side dismissal table; D4 user-aware active read; §4 `announcement_dismissals` composite identity; §7 dismissal idempotency, retry, and failure behavior; §8 least privilege for dismiss endpoint.

### Gherkin
Given an authenticated user sees an active banner in their workspace
When the user clicks the dismiss control
Then the banner is dismissed for that user
And the same banner does not reappear for that user in later sessions or on other devices
And other users in the workspace can still see the banner until they dismiss it or it stops being active

### Code-blind plan
- Preconditions: S2's active display exists, and S4's active-window filtering can identify the currently displayable banner.
- Required capabilities: A server-side dismissal record keyed by announcement and authenticated user; a dismiss endpoint that derives user identity from the session rather than request input; idempotent dismissal writes so double-clicks and retries are harmless; active-banner read logic that suppresses a banner only for users with a dismissal for that banner; frontend dismiss interaction that updates the visible banner promptly and retries or reports failure according to the design; an accessible dismiss button with an appropriate label.
- Postconditions: Dismissal is durable, per-user, per-banner, cross-device, and safe to retry. The frontend remains stateless about long-term dismissal truth.
- Risks / assumptions: Dismissal persistence is the feature's key invariant. A client-only dismissal would fail the blueprint. The dismiss endpoint must not allow users to dismiss on behalf of another user.

### Research questions
- RQ1: What migration mechanism should create the dismissal persistence structure with a unique announcement/user identity?
- RQ2: Is there an existing authenticated route pattern for deriving the current user ID without accepting a user ID in the request body?
- RQ3: Is there an existing upsert or conflict-ignore database helper for idempotent writes?
- RQ4: Where should a user-level dismiss route be registered so it is separate from admin write routes?
- RQ5: What existing frontend mutation pattern supports optimistic or immediate UI removal plus retry/error handling?
- RQ6: Is there an existing accessible icon-button or dismiss-button component that should be used for the banner close control?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S6 — A User Who Joins After Publication Sees The Active Banner
- Order: 6
- Type: edge_case
- Status: planned
- Design references: D4 workspace-scoped and user-aware active poll; D6 query-time filtering; §4 dismissal identity; §8 least privilege and workspace scoping.

### Gherkin
Given a banner was published before a user joined the workspace
And the banner is still inside its active window
And the user has no dismissal record for that banner
When the new user loads the app
Then the user sees the banner for that workspace

### Code-blind plan
- Preconditions: S2 can publish and show a workspace banner, S4 can evaluate the active window, and S5 can distinguish dismissed from not dismissed users.
- Required capabilities: Active-banner visibility derived from current workspace membership and active time window rather than a precomputed recipient list; dismissal lookup that treats absence of a dismissal record as not dismissed; workspace scoping that prevents users from seeing banners from other workspaces; app-shell polling on normal app load for newly joined users.
- Postconditions: A newly joined user sees any still-active workspace announcement without requiring the publish operation to have known about them at publish time.
- Risks / assumptions: This scenario depends on current workspace membership being authoritative at read time. Multi-workspace users must be scoped to the currently active workspace or equivalent session workspace.

### Research questions
- RQ1: How does the current session identify the user's active workspace, especially for users who belong to multiple workspaces?
- RQ2: Is there an existing workspace-membership authorization or scoping helper that should be applied to the active-banner read?
- RQ3: Does the frontend app shell fetch workspace-scoped user data on initial load in a place where banner polling can start for newly joined users?
- RQ4: Is there any existing pattern that precomputes recipients for workspace notifications, or should this feature explicitly avoid that pattern in favor of read-time membership?
- RQ5: How should tests create or represent a newly joined user with no dismissal record?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S7 — Admin Edits Active Banner Text Without Resetting Dismissals
- Order: 7
- Type: deviation
- Status: planned
- Design references: Blueprint rule that edits do not bring a banner back after dismissal; D1 dismissal keyed to announcement ID; D4 combined read response; §2 admin edit route; §9 edit logging.

### Gherkin
Given an active banner exists
And one user has dismissed that banner
And another user has not dismissed it
When a workspace admin edits the active banner's text
Then the dismissed user still does not see that banner
And the non-dismissed user sees the updated text after the next poll
And the edit does not create a second active banner

### Code-blind plan
- Preconditions: S2's active banner exists, S3's validation rules are available for message and optional link fields, and S5's dismissal identity is keyed to the banner rather than its text.
- Required capabilities: An admin edit operation for the active announcement that preserves the announcement identity; validation for edited message/link fields matching publish validation; active read behavior that returns updated fields for non-dismissed users; dismissed-user suppression that does not depend on message text; structured edit logging that excludes banner text.
- Postconditions: Admins can correct or update active banner content. Dismissed users remain dismissed because the banner identity is unchanged, while non-dismissed users receive the updated content.
- Risks / assumptions: The design calls out concurrent admin edit races as last-writer-wins unless optimistic locking is later added. Edits must not accidentally archive and recreate the banner, because that would reset dismissal semantics.

### Research questions
- RQ1: Where should an admin edit route or action live relative to the publish route?
- RQ2: Is there an existing update pattern that preserves record identity while applying validation and audit timestamps?
- RQ3: Can the same server-side validation schema or helper used for publish be reused for edit?
- RQ4: How should the frontend admin form load and update the current active banner for editing?
- RQ5: What existing logging utility supports structured edit logs without recording message text?
- RQ6: Is there an existing convention for last-writer-wins edits or optimistic locking in admin settings?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S8 — Admin Removes A Banner Early
- Order: 8
- Type: happy_path
- Status: planned
- Design references: Blueprint rule for Remove; D5 synchronous writes; D6 remove sets an explicit removed state and current end time; §2 admin remove route; §7 admin write failure behavior; §9 remove logging.

### Gherkin
Given an active banner is visible to users in a workspace
When a workspace admin clicks Remove for that banner
Then the banner stops showing for every user in the workspace after the next active-banner check
And the removed banner is no longer considered active

### Code-blind plan
- Preconditions: S2 can publish and show an active banner; S4 active-window filtering exists; S7 can identify the active banner in the admin UI.
- Required capabilities: An admin remove operation that marks the active banner removed and makes its active window end immediately; active read filtering that excludes removed banners; admin UI affordance for Remove with appropriate confirmation or clear action state; frontend polling that naturally removes the banner after the backend state changes; structured remove logging.
- Postconditions: Admins can end a banner before its scheduled end, and no user continues to see it after their next successful poll.
- Risks / assumptions: "Remove" is a soft state change in the design, not necessarily hard deletion. The rollout flag remains the emergency global rollback, but Remove is the normal per-banner admin action.

### Research questions
- RQ1: Where should an admin remove route or action be registered relative to publish and edit?
- RQ2: Is there an existing soft-delete or status-transition pattern for admin-managed records?
- RQ3: Is there an existing confirmation, destructive action, or inline remove UI pattern in admin settings?
- RQ4: How should the active-banner read exclude removed records while preserving archived/removed records for audit?
- RQ5: What existing logging utility supports structured remove logs with workspace, announcement, and admin identities?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S9 — Publishing A New Banner Replaces The Previous Active Banner
- Order: 9
- Type: edge_case
- Status: planned
- Design references: D2 one-active-banner invariant enforced at the database layer; §4 publish-replaces transaction; D1 dismissal keyed by announcement ID; §7 concurrent publish conflict handling; C3 idempotency-key compromise.

### Gherkin
Given a workspace already has an active banner
When a workspace admin publishes a new valid banner
Then the previous banner is no longer active
And the new banner is the only active banner for that workspace
And users who dismissed the previous banner are eligible to see the new banner if they have not dismissed the new banner

### Code-blind plan
- Preconditions: S2 publish exists, S5 dismissal identity exists, and S8/S4 know how inactive banners are excluded from user reads.
- Required capabilities: A single transaction or equivalent atomic operation that deactivates the previous active banner and creates the new active banner; a database-level invariant that prevents more than one active banner per workspace; error handling for invariant conflicts; dismissal records scoped to announcement identity so a previous dismissal does not suppress a newly published banner; admin UI behavior that makes replacement understandable when publishing while another banner is active.
- Postconditions: Publishing a replacement never leaves two active banners. The active banner is the newly published one, and previous dismissals only apply to the previous banner.
- Risks / assumptions: The design accepts a possible 409 for true concurrent publish conflicts rather than adding application-level locks. Admin publish idempotency keys are called out as a follow-up, so retries after ambiguous network failure may produce a reload-required conflict instead of transparent idempotent success.

### Research questions
- RQ1: What database migration/index mechanism supports enforcing a one-active-record-per-workspace invariant?
- RQ2: What transaction helper should perform the deactivate-previous-plus-create-new publish operation atomically?
- RQ3: How are database unique-conflict errors detected and mapped to user-facing conflict responses?
- RQ4: How should the admin UI communicate that publishing while a banner is active replaces the existing active banner?
- RQ5: Does the current data access layer support preserving old dismissal records while ensuring they are matched only to the old announcement identity?
- RQ6: Is there any existing idempotency-key pattern for low-frequency admin writes, or should this remain a documented follow-up as the design accepts?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S10 — Concurrent Admin Writes Resolve Without Illegal Active States
- Order: 10
- Type: deviation
- Status: planned
- Design references: Blueprint deviation for admin publish while another admin is editing; D2 database invariant and conflict handling; D5 synchronous writes; §7 concurrent publish response; §13 concurrent edit race callout.

### Gherkin
Given one admin is editing the currently active banner
And another admin publishes a new valid banner for the same workspace
When both actions complete in overlapping time
Then the system does not produce more than one active banner
And the active banner is the most recent valid publish outcome
And any stale edit of an old banner does not reactivate or overwrite the newly published active banner

Given two admins publish valid banners for the same workspace at nearly the same time
When the writes race
Then exactly one active banner remains
And the losing admin receives a clear conflict response that instructs them to reload

### Code-blind plan
- Preconditions: S7 edit behavior and S9 replacement behavior exist, including the database-level one-active invariant.
- Required capabilities: Conflict-safe publish behavior under concurrent writes; stale-edit handling that prevents updates to archived, removed, or replaced banners from changing current active state; clear user-facing conflict messaging for losing concurrent publish requests; deterministic reload behavior in the admin UI after conflicts; tests or verification strategy for overlapping publish/edit and publish/publish timing.
- Postconditions: Concurrent admin actions preserve the invariant and produce understandable admin outcomes. Stale writes do not resurrect replaced banners.
- Risks / assumptions: The blueprint phrase "most recent publish wins" must be interpreted with the design's database constraint and 409 conflict behavior for true simultaneous publish races. Edit races are accepted as last-writer-wins only for the same still-active banner, not for stale records after replacement.

### Research questions
- RQ1: How can the backend detect that an edit request targets a banner that is no longer active for the workspace?
- RQ2: Is there an existing stale-write, conflict, or reload-required response pattern in admin settings?
- RQ3: How are database constraint violations surfaced through the route error layer today?
- RQ4: Is there an existing test helper for simulating concurrent or overlapping writes against the database?
- RQ5: How should the admin UI reload or refresh active banner state after a conflict response?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S11 — Non-Admin Write Attempts Are Rejected
- Order: 11
- Type: corner_case
- Status: planned
- Design references: Blueprint adversarial scenarios; §8 Authorization, least privilege, workspace ID from session; §10 backend routes return unavailable when feature flag is off.

### Gherkin
Given the announcement feature is enabled
And a user is authenticated but is not a workspace admin
When the user opens or crafts a request to publish, edit, or remove a banner
Then the request is rejected before any announcement state changes
And the user cannot choose a workspace or user identity in the request body to bypass authorization

Given a request is unauthenticated
When it attempts to read, dismiss, publish, edit, or remove announcement data
Then it is rejected according to the route's authentication requirement

### Code-blind plan
- Preconditions: Admin write routes from S2, S7, S8, and S9 exist; user read and dismiss routes from S2 and S5 exist.
- Required capabilities: Workspace-admin authorization middleware or equivalent guard for all create, edit, remove, and replacement writes; authenticated-user guard for active reads and dismissals; workspace ID derived from session context rather than request body; user ID derived from session context for dismissal; consistent forbidden/unauthorized responses; negative tests for crafted non-admin write attempts.
- Postconditions: Only workspace admins can mutate banners. Non-admins and unauthenticated callers cannot publish, edit, remove, or spoof workspace/user identity.
- Risks / assumptions: The design assumes an existing admin-role middleware, but research must confirm the correct role/scope name and application point. Authorization must be enforced server-side even if the UI hides admin controls.

### Research questions
- RQ1: Is there an existing workspace-admin authorization helper or middleware for admin settings write routes?
- RQ2: Is there an existing authenticated-user middleware for app-level reads and user actions?
- RQ3: How should backend routes derive workspace ID and user ID from the session, and are request-body workspace/user IDs explicitly rejected or ignored?
- RQ4: What response status and error body conventions are used for unauthenticated and unauthorized route access?
- RQ5: Are there existing security or route tests for crafted non-admin requests that should be extended for announcement routes?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S12 — Failures Degrade According To The Banner's Criticality
- Order: 12
- Type: edge_case
- Status: planned
- Design references: §7 Reliability & Failure Handling; §9 Observability; §10 Rollout & Operability; C1 short-polling compromise; C2 no shared cache; C4 dismissal retention; §13 open risks and callouts.

### Gherkin
Given the announcement feature is enabled
When the active-banner poll fails because persistence is temporarily unavailable
Then users do not see a disruptive app error, the banner surface renders absent, and the next poll backs off before retrying

Given a dismiss request fails after retry
When the user has attempted to dismiss a visible banner
Then the user sees a transient error and the banner may remain visible until dismissal succeeds

Given an admin publish, edit, or remove request fails
When the admin submits the action
Then the admin sees a clear error message and no successful state change is implied

Given announcement operations succeed or fail
When the system records telemetry
Then publish, edit, remove, poll, and dismiss logs or metrics are emitted without storing banner text in logs

### Code-blind plan
- Preconditions: Core read, write, dismiss, edit, remove, authorization, and replacement behavior exists through S11.
- Required capabilities: Poll error handling that renders no banner and distinguishes errors from normal misses in telemetry; client polling backoff that resumes normal cadence after success; dismiss retry and user-facing failure toast; admin write failure messages that avoid implying success; mapping for database unavailable, validation, authorization, and conflict failures; structured logs for publish/edit/remove and errors without banner text; metrics for poll, dismiss, publish outcomes and rollout health; rollout verification for enabling the feature in a test workspace before wider rollout.
- Postconditions: The banner feature fails gracefully: non-critical display failures do not break the app, user actions communicate persistence failures, admin writes communicate unsuccessful outcomes, and operators can observe poll and dismiss health during rollout.
- Risks / assumptions: The design intentionally avoids shared cache and background workers at current scale. Cleanup and idempotency-key support are accepted follow-ups unless research finds an existing low-cost pattern that should be reused immediately.

### Research questions
- RQ1: Is there an existing frontend polling backoff pattern for non-critical widgets?
- RQ2: Is there an existing toast or transient notification pattern for failed user actions such as dismissal?
- RQ3: How do admin settings forms display backend write failures without clearing unsaved input?
- RQ4: What backend error mapping convention should distinguish database unavailable, validation, conflict, unauthorized, and not-found outcomes?
- RQ5: What structured logging helper should emit announcement publish, edit, remove, and error events without message text?
- RQ6: What metrics library and naming convention should be used for poll, dismiss, publish, active-age, and error-rate signals?
- RQ7: Is there an existing rollout checklist or workspace-targeted flag enablement process that should verify the feature before wider rollout?
- RQ8: Is there an existing retention or cleanup mechanism that should be used for old announcements and dismissal records, or should cleanup remain a follow-up?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.
