# Implementation Plan: Admin Announcement Banner

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-system-design.md
- Summary: Workspace admins can publish one active plain-text announcement banner, optionally with a link and schedule, for all users in a workspace. Users see the active banner in the app shell, can dismiss it per user across devices and sessions, and admins can edit, replace, or remove it. The system design implements this with server-side announcement and dismissal persistence, workspace-scoped read/write routes, a polling frontend banner, admin settings UI, feature-flagged rollout, authorization, validation, and observability.

## Scenario order & status
| # | ID | Title | Status |
|---|----|-------|--------|
| 1 | S1 | Flagged empty state and no active banner | planned |
| 2 | S2 | Admin publishes an immediate plain-text banner | planned |
| 3 | S3 | Workspace users see the active banner within the polling window | planned |
| 4 | S4 | User dismisses a banner across devices and sessions | planned |
| 5 | S5 | Admin edits active banner text without resetting dismissals | planned |
| 6 | S6 | Admin publishes a new banner that replaces the previous active banner | planned |
| 7 | S7 | Banner with future start time is hidden until it starts | planned |
| 8 | S8 | Banner with end time stops showing after expiry | planned |
| 9 | S9 | Banner without end time remains until removed early | planned |
| 10 | S10 | New workspace user sees an already-active banner | planned |
| 11 | S11 | Invalid schedule is rejected with validation | planned |
| 12 | S12 | Invalid message or link input is rejected or rendered safely | planned |
| 13 | S13 | Concurrent admin activity resolves deterministically | planned |
| 14 | S14 | Non-admin write attempts are forbidden | planned |
| 15 | S15 | Runtime failures degrade according to feature criticality | planned |

## Ordering rationale

S1 establishes the feature flag, the app-shell mount point, and the normal no-banner response before any write behavior exists. S2 then creates the first vertical publish flow, and S3 makes the user-facing polling/read path explicit. S4 adds server-side dismissal, which later scenarios must preserve. S5 and S6 depend on the banner identity and dismissal model from S4. S7 through S9 extend the same publish/read path with scheduling and removal behavior. S10 verifies that the model is workspace- and user-aware without relying on prior sessions. S11 and S12 add validation and safety around the write path once the core write behavior is in place. S13 handles cross-admin races after the baseline create/edit/replace behavior exists. S14 locks down the adversarial authorization case across every write route. S15 is last because it tests graceful degradation and retry behavior across the routes and components created by earlier scenarios.

## Scenario S1 — Flagged empty state and no active banner
- Order: 1
- Type: edge_case
- Status: planned
- Design references: System design §10 feature flag, D4 workspace-scoped poll endpoint, §7 poll failure behavior, §8 authenticated reads, §15 rollout and deployability.

### Gherkin
Given the announcement banner feature is enabled for a workspace
And there is no active banner in that workspace
When an authenticated workspace user opens the app
Then no announcement banner is rendered
And the app layout remains otherwise unchanged

### Code-blind plan
- Preconditions: The feature is allowed to be deployed behind `announcement_banner_enabled`, and authenticated users can be associated with a workspace.
- Required capabilities: A feature-flag gate for the admin settings entry, app-shell banner mount, and backend routes; a workspace-aware read path that can answer "no active banner"; an app-shell component that renders nothing for an empty response; authentication for user reads; telemetry for active-banner poll misses.
- Postconditions: With the feature enabled and no active announcement, users see no banner, the empty state is treated as normal, and the system has the minimal end-to-end read surface needed by later scenarios.
- Risks / assumptions: The design says routes should return 404 when the flag is off and fail closed if the flag service is unavailable. The blueprint treats "no active banner" as normal, so the UI must avoid user-visible errors or empty placeholders.

### Research questions
- RQ1: Is there an existing feature-flag mechanism that can gate backend routes, admin navigation, and app-shell components? If so, where is it used for similar features?
- RQ2: Is there an existing authenticated app-shell or layout component where workspace-wide banners should be mounted above the main content?
- RQ3: Is there an existing pattern for a lightweight authenticated workspace-scoped GET endpoint that returns an empty result without surfacing UI errors?
- RQ4: Is there an existing telemetry/logging pattern for route hit/miss/error counters that should be used for announcement poll metrics?
- RQ5: Is there an existing empty-state response schema convention for nullable resources, or should this feature define one?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S2 — Admin publishes an immediate plain-text banner
- Order: 2
- Type: happy_path
- Status: planned
- Design references: System design §2 placement, D2 one-active invariant, D5 synchronous writes, D6 start/end query-time filtering, §4 `workspace_announcements`, §8 admin authorization and input validation, §9 publish logs/metrics.

### Gherkin
Given an authenticated workspace admin is on the Announcements page
And no active banner currently exists
When the admin enters a non-empty plain-text message of at most 200 characters
And leaves start and end date empty
And clicks Publish
Then the banner is saved as the workspace's active banner
And it is active immediately
And the admin receives confirmation that it was published

### Code-blind plan
- Preconditions: S1 has established the feature flag, admin settings entry point, and empty active-banner read behavior.
- Required capabilities: An admin settings page or panel for announcement creation; server-side admin authorization; validation for required message and maximum length; workspace ID taken from the authenticated session rather than client input; persistence for an announcement record with immediate default start time; a transaction shape that preserves the one-active-banner invariant; publish success and failure UI states; structured publish logs and metrics.
- Postconditions: A workspace admin can publish a valid immediate banner, one active announcement exists for that workspace, and the stored record has enough identity and schedule data for user reads and dismissals.
- Risks / assumptions: The system design assumes a workspace-admin role gate and Postgres support for the proposed key and constraint strategy. The plan must not assume those mechanisms already exist until research confirms them.

### Research questions
- RQ1: Where should a new admin Announcements settings page or panel be registered in the product navigation?
- RQ2: Is there an existing workspace-admin authorization middleware or guard for admin settings write routes? If so, what is its expected usage?
- RQ3: What migration framework and naming conventions should create the announcement persistence tables and indexes?
- RQ4: Is there an existing service/repository pattern for workspace-scoped transactional writes that should own the publish operation?
- RQ5: What validation library or request-schema convention should enforce message length, required fields, date parsing, and workspace scoping?
- RQ6: Is there an existing toast, inline error, or form submission state pattern for admin settings publish flows?
- RQ7: What logging and metrics helpers should be used for publish success, conflict, and error events?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S3 — Workspace users see the active banner within the polling window
- Order: 3
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 3, system design D3 short polling, D4 combined active/dismissed response, D6 query-time filtering, §6 latency/load targets, §8 least-privilege response fields, §15 accessibility note.

### Gherkin
Given a workspace has an active banner within its active window
And an authenticated user in that workspace has not dismissed that banner
When the user's app polls for the active announcement
Then the banner appears across the top of the app within a short time
And it displays the announcement message as plain text

### Code-blind plan
- Preconditions: S2 has created an active announcement record with workspace, identity, message, and schedule fields.
- Required capabilities: A user-facing active-banner endpoint that authenticates the caller and resolves their workspace; server-side filtering for active status and schedule window; response fields limited to display data and dismissal state; frontend polling with configurable interval and backoff; app-shell rendering across main app views; accessible banner markup and dismiss control placement; metrics for poll hit/miss/error.
- Postconditions: Users in the same workspace see the active banner without a page refresh within the accepted polling interval, and users outside the workspace do not receive it.
- Risks / assumptions: The design accepts 30-second polling latency as "within a short time." If product expects tighter delivery, the polling decision must be revisited.

### Research questions
- RQ1: Is there an existing data-fetching or polling helper in the React frontend that supports configurable intervals and backoff?
- RQ2: Where should a cross-app banner be mounted so it appears above the main content without breaking layouts?
- RQ3: What backend pattern resolves the authenticated user's current workspace for read routes?
- RQ4: Are there existing response DTO or serializer conventions for returning only display-safe fields?
- RQ5: Is there an existing accessibility pattern for dismissible top-of-page notices or banners?
- RQ6: Is there an environment/configuration mechanism for `ANNOUNCEMENT_POLL_INTERVAL_MS` or equivalent?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S4 — User dismisses a banner across devices and sessions
- Order: 4
- Type: happy_path
- Status: planned
- Design references: Blueprint dismissal rule, system design D1 server-side dismissal, D4 combined response, §4 `announcement_dismissals`, §7 dismiss idempotency and retry, §8 dismiss authorization.

### Gherkin
Given an authenticated user sees an active banner
When the user clicks the dismiss control
Then the banner disappears for that user
And that same user does not see that banner again in later sessions
And that same user does not see that banner again on another device

### Code-blind plan
- Preconditions: S3 renders an active banner with a stable announcement identity in the frontend.
- Required capabilities: A dismiss action endpoint authenticated as the current user; server-side storage keyed by announcement identity and user identity; idempotent dismissal writes that tolerate double clicks and retries; frontend optimistic or confirmed hide behavior; retry and toast behavior on dismiss failure; active-banner reads that combine announcement data with dismissal state for the current user.
- Postconditions: Dismissal is an authoritative server-side fact for one user and one banner, persists across sessions/devices, and suppresses future renders of that banner only for that user.
- Risks / assumptions: Dismissal must never accept a client-supplied user ID. The design keeps dismissal tied to announcement ID, so later text edits must not create a new identity.

### Research questions
- RQ1: Is there an existing pattern for idempotent user-action endpoints that insert a user/resource join record?
- RQ2: What current-user identity field should be used for dismissal writes, and where is it exposed to route handlers?
- RQ3: What frontend pattern should hide dismissed UI after a server mutation and surface retryable failures?
- RQ4: Is there an existing database convention for composite primary keys or unique constraints on join tables?
- RQ5: How are cross-device/session behaviors usually covered in tests for server-side user preferences?
- RQ6: Where should dismiss metrics and error logs be emitted?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S5 — Admin edits active banner text without resetting dismissals
- Order: 5
- Type: edge_case
- Status: planned
- Design references: Blueprint edit rule and deviation scenario, system design §2 PATCH edit route, D1 dismissal tied to announcement ID, §7 admin write failure behavior, §13 concurrent admin edit race callout.

### Gherkin
Given a workspace has an active banner
And one user has already dismissed that banner
And another user has not dismissed it
When a workspace admin edits the active banner's text
Then the non-dismissed user sees the edited text on a later poll
And the dismissed user still does not see that banner

### Code-blind plan
- Preconditions: S4 stores dismissal by announcement identity and active-banner reads suppress dismissed banners.
- Required capabilities: An admin-only edit operation for the active announcement; validation for edited message and optional link fields; preservation of the same announcement identity on edit; update timestamps or equivalent audit fields; polling refresh behavior for users who have not dismissed the banner; no dismissal deletion or reset on edit; admin UI state for edit success/failure.
- Postconditions: Editing updates banner content for users who are still eligible to see it, while all prior dismissals for that announcement remain effective.
- Risks / assumptions: The blueprint is explicit that editing text does not bring the banner back. The implementation must distinguish editing an existing banner from publishing a new banner.

### Research questions
- RQ1: How do admin settings pages represent edit mode for an existing workspace-scoped resource?
- RQ2: Is there an existing route/service pattern for updating a resource while preserving its identity and authorization scope?
- RQ3: Where should validation for edited message and link fields be shared with the publish flow?
- RQ4: Is there an existing stale-data or refetch pattern so non-dismissed users see edited text on the next poll?
- RQ5: Are audit fields such as updated time and updating admin identity expected for admin edits?
- RQ6: Are there existing tests for "update does not reset per-user state" patterns that can guide coverage?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S6 — Admin publishes a new banner that replaces the previous active banner
- Order: 6
- Type: edge_case
- Status: planned
- Design references: Blueprint one-active-banner rule and replacement rule, system design D2 database invariant, §4 publish-replaces transaction, §7 concurrent publish conflict handling, §9 publish metrics.

### Gherkin
Given a workspace already has an active banner
When a workspace admin publishes a different valid banner
Then the previous banner is no longer active
And the new banner is the only active banner for that workspace
And users who dismissed the previous banner may still see the new banner if they have not dismissed it

### Code-blind plan
- Preconditions: S2 can publish an initial active banner and S4 ties dismissal to a specific announcement identity.
- Required capabilities: A publish operation that archives or supersedes the previous active announcement and creates a distinct new announcement identity; a database-level one-active-banner invariant; a transaction that prevents zero-or-two active rows on normal publish; frontend/admin copy that makes replacement behavior clear; poll behavior that returns the new active banner after replacement; dismissal state scoped to the replaced banner, not the workspace globally.
- Postconditions: Each workspace has at most one active banner, publishing a new banner replaces the old active banner, and old dismissals do not suppress the new banner.
- Risks / assumptions: The design's partial unique-index strategy preserves the invariant, but exact UX for rare concurrent publish conflicts is addressed separately in S13.

### Research questions
- RQ1: Is there an existing transaction helper or unit-of-work pattern for multi-step writes that must preserve a uniqueness invariant?
- RQ2: What status or archival conventions are used for superseded workspace resources?
- RQ3: How should the admin UI communicate that publishing a new banner replaces the current active banner?
- RQ4: Are there existing database partial unique-index patterns in migrations that should be followed?
- RQ5: How should tests assert that previous dismissals do not suppress a newly published announcement identity?
- RQ6: What route error format should be used if replacement cannot complete because of a conflict or database error?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S7 — Banner with future start time is hidden until it starts
- Order: 7
- Type: edge_case
- Status: planned
- Design references: Blueprint future-start edge case, system design D6 query-time filtering, §4 timestamp fields, §8 timestamp validation, §13 clock-skew callout.

### Gherkin
Given a workspace admin publishes a banner with a valid future start date and time
When a workspace user opens the app before that start time
Then no banner is shown
When the start time has passed according to server-side time
Then eligible users see the banner on a later poll

### Code-blind plan
- Preconditions: S2 can publish with schedule fields and S3 can poll for active announcements.
- Required capabilities: Admin UI controls for optional start date/time; server-side parsing and validation of start time; persistence of start time; active-banner query filtering based on authoritative server/database time; polling that naturally discovers the banner after it starts; clear admin display of scheduled state.
- Postconditions: Future-start banners can be created ahead of time without being visible early, then become visible without a background job.
- Risks / assumptions: Browser/server clock skew can confuse "start now" expectations. The design uses database time as authoritative and flags optional server-time display as a mitigation.

### Research questions
- RQ1: What date/time input components and timezone conventions are used in existing admin settings forms?
- RQ2: Is there an existing server-side date parsing and validation helper for ISO 8601 timestamps?
- RQ3: What database or query abstraction should express active-window filtering against authoritative server/database time?
- RQ4: How are timezone-sensitive scheduled states represented in admin UI copy or tests?
- RQ5: Is there an existing way to expose server time to the frontend if clock-skew mitigation is needed?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S8 — Banner with end time stops showing after expiry
- Order: 8
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 5, system design D6 query-time filtering, §4 timestamp fields, §7 expiry failure scenario, §10 reversibility.

### Gherkin
Given a workspace has an active banner with a valid end date and time
And an eligible user can currently see it
When the end date and time passes according to server-side time
Then the banner stops showing for every user in the workspace
And no scheduled worker is required to hide it

### Code-blind plan
- Preconditions: S3 returns active banners and S7 has established server-side active-window filtering.
- Required capabilities: Admin UI end date/time input; validation and persistence of optional end time; active-banner read filtering that excludes expired banners; polling behavior that removes an expired banner on the next successful poll; tests around boundary times; metrics that distinguish poll miss from error.
- Postconditions: Banners expire automatically based on server-side time, and users stop seeing expired banners without an explicit status-flipping job.
- Risks / assumptions: The design says timestamp window, not mutable status, is the visibility authority. The implementation must avoid depending only on a status field for expiry.

### Research questions
- RQ1: What existing test utilities support time freezing or boundary-time assertions?
- RQ2: How should the frontend remove a banner that disappears from the active-banner response after expiry?
- RQ3: Are there existing conventions for treating expired scheduled resources as inactive without mutating their status?
- RQ4: What query/index pattern should be used to keep active-window checks performant?
- RQ5: How should admin UI display an active banner that has a future end time?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S9 — Banner without end time remains until removed early
- Order: 9
- Type: edge_case
- Status: planned
- Design references: Blueprint no-end-date and Remove rules, system design §2 DELETE remove route, D5 synchronous writes, D6 `removed` status plus immediate end time, §7 admin write failures.

### Gherkin
Given a workspace admin publishes a banner without an end date
When eligible users poll for the active banner over later sessions
Then the banner remains visible unless each user dismisses it
When a workspace admin clicks Remove
Then the banner stops showing for everyone in the workspace

### Code-blind plan
- Preconditions: S2 supports publishing without an end date and S3/S4 handle display and dismissal.
- Required capabilities: Persistence of null/no-expiry end time; active-banner query that treats missing end time as ongoing; admin-only remove action; remove operation that marks the announcement no longer active and prevents future display; confirmation or undo decision in admin UI if required by existing patterns; success/failure UI for removal; structured remove logs and metrics.
- Postconditions: No-end-date banners remain active indefinitely until removed, and removal hides the banner globally without deleting dismissal history unexpectedly.
- Risks / assumptions: The system design says removal should set a removed state and end immediately. If the codebase has a soft-delete convention, the implementation should align with it after research.

### Research questions
- RQ1: What existing admin UI pattern is used for destructive or semi-destructive Remove actions?
- RQ2: Are workspace-scoped resources usually soft-deleted, statused, or hard-deleted when removed by an admin?
- RQ3: Where should remove success, error, and audit events be logged?
- RQ4: How should the app-shell polling component react when a previously visible banner is removed?
- RQ5: Are there existing tests for no-expiry scheduled resources or null end-date semantics?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S10 — New workspace user sees an already-active banner
- Order: 10
- Type: edge_case
- Status: planned
- Design references: Blueprint new-user edge case, system design D1 server-side dismissal, D4 workspace-scoped user-aware poll endpoint, §8 least privilege.

### Gherkin
Given a banner was published before a user joined the workspace
And the banner is still within its active window
When the new user opens the app for that workspace
Then the user sees the banner
And the user has no prior dismissal for that banner

### Code-blind plan
- Preconditions: S3 returns active banners by workspace and S4 suppresses only when a dismissal exists for the current user and banner.
- Required capabilities: Active-banner lookup scoped to the user's current workspace membership; dismissal lookup that defaults to not dismissed when no row exists; no dependency on membership-at-publish-time; safe behavior for users added after announcement creation; tests covering newly joined users.
- Postconditions: New members are eligible for active workspace announcements, and no migration or fan-out is needed when a banner is published.
- Risks / assumptions: This scenario relies on resolving workspace membership at read time. Any membership cache must not permanently exclude users who joined after publish.

### Research questions
- RQ1: How does the backend determine that the authenticated user currently belongs to a workspace?
- RQ2: Are there membership caches or frontend workspace-context caches that could delay new-user access to workspace-scoped resources?
- RQ3: What test fixture or factory pattern can represent a user who joins after a resource was created?
- RQ4: Does the active-banner query need to validate workspace membership beyond using the workspace ID from the authenticated session?
- RQ5: How should multi-workspace users select or change the workspace whose banner is being queried?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S11 — Invalid schedule is rejected with validation
- Order: 11
- Type: edge_case
- Status: planned
- Design references: Blueprint end-before-start edge case, system design §4 invariants, §8 timestamp validation, §7 admin publish failure behavior.

### Gherkin
Given a workspace admin is creating or editing a banner
When the admin enters an end date and time before the start date and time
And attempts to publish or save
Then the write is rejected
And the admin sees a validation message
And no active banner is created or changed by that invalid request

### Code-blind plan
- Preconditions: S2/S5 support publish and edit forms with optional schedule fields.
- Required capabilities: Shared schedule validation for create and edit; client-side validation for immediate feedback if consistent with existing forms; server-side validation as the authority; non-mutating failure behavior; user-facing validation message; tests proving the previous active banner is unchanged after invalid input.
- Postconditions: Invalid schedules cannot enter persistence, and admins receive a clear validation error without side effects.
- Risks / assumptions: The design suggests enforcing `ends_at > starts_at` in application logic and optionally in the database. Research must determine whether a database check constraint fits local migration practice.

### Research questions
- RQ1: What form validation pattern is used for admin settings pages with both client and server validation?
- RQ2: How are field-specific validation errors represented by backend routes and rendered in the frontend?
- RQ3: Is there a local convention for adding database check constraints for business invariants?
- RQ4: How should publish and edit share validation to avoid divergent schedule rules?
- RQ5: What tests should assert that invalid write requests leave the current active banner unchanged?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S12 — Invalid message or link input is rejected or rendered safely
- Order: 12
- Type: edge_case
- Status: planned
- Design references: Blueprint message and optional-link rules, system design §4 message length invariant, §8 input validation and XSS mitigation, §13 optional link display-text callout.

### Gherkin
Given a workspace admin is creating or editing a banner
When the message is empty or longer than 200 characters
Then the write is rejected with a validation message
When the message contains characters that could be interpreted as markup
Then the message is stored and rendered only as plain text
When an optional link is provided
Then only a valid safe link is accepted and rendered safely

### Code-blind plan
- Preconditions: S2/S5 support create and edit flows, and S3 renders banner content.
- Required capabilities: Shared message validation for required and maximum-length constraints; plain-text storage and rendering with no rich-text parsing; optional link validation according to the design's safe URL rule; safe frontend link rendering; admin UI validation messages for message and link fields; tests for long input, empty input, markup-like input, and unsafe link schemes.
- Postconditions: Announcement content remains plain text, unsafe links are rejected, and user-facing banner rendering does not introduce stored XSS risk.
- Risks / assumptions: The blueprint says "optional link" but does not specify whether link display text is the URL, a fixed label, or a separate label. The plan treats display-label choice as a product/design detail to confirm before implementation.

### Research questions
- RQ1: What validation helper should enforce maximum string length and non-empty input in admin write routes?
- RQ2: How do existing components render untrusted plain text and links safely?
- RQ3: Is there an existing URL validation helper or allowlist policy for user-provided links?
- RQ4: What frontend component should represent the optional banner link, including focus and accessibility behavior?
- RQ5: Should the product use the URL itself, a fixed label, or an additional label field for optional banner links?
- RQ6: Are there existing security tests for stored XSS or unsafe URL schemes that this feature should mirror?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S13 — Concurrent admin activity resolves deterministically
- Order: 13
- Type: corner_case
- Status: planned
- Design references: Blueprint deviation scenario for concurrent admin activity, system design D2 one-active invariant, §7 concurrent publish handling, §13 concurrent admin edit race callout.

### Gherkin
Given two workspace admins are working with the same active banner
And one admin publishes a banner while another admin is editing the old one
When both actions reach the server close together
Then the system ends with one deterministic active banner for the workspace
And the admin-facing result clearly communicates whether each write succeeded, was superseded, or must be reloaded

### Code-blind plan
- Preconditions: S5 supports edit, S6 supports replacement publish, and the one-active-banner invariant exists.
- Required capabilities: A deterministic concurrency policy for publish-vs-edit and publish-vs-publish races; database constraint or transaction behavior that prevents multiple active banners; clear conflict or supersession responses; admin UI reload guidance after conflict; metrics for conflict results; tests that simulate interleaved admin writes.
- Postconditions: Concurrent admin actions cannot produce multiple active banners or a partially edited/replaced banner, and admins get actionable feedback.
- Risks / assumptions: There is a potential tension between the blueprint's "most recent publish wins" language and the design's note that a concurrent publish can return a 409 to the losing admin. This scenario should preserve the blueprint's deterministic one-active outcome and requires confirmation on exact UX for rare conflicts.

### Research questions
- RQ1: Are there existing conflict-response conventions for concurrent admin writes, such as HTTP 409, stale-update errors, or reload prompts?
- RQ2: What transaction isolation, retry, or unique-constraint handling pattern is used for one-active-resource invariants?
- RQ3: How can tests reliably simulate two admin writes arriving close together?
- RQ4: Should edit operations include optimistic locking or updated-time preconditions, or is last-writer-wins acceptable for this product area?
- RQ5: What exact user-facing copy should be used when another admin has just published or changed the banner?
- RQ6: Is the design-approved 409 behavior for concurrent publish considered compatible with the blueprint's "most recent publish wins" deviation?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S14 — Non-admin write attempts are forbidden
- Order: 14
- Type: corner_case
- Status: planned
- Design references: Blueprint adversarial scenarios, system design §8 authorization, §10 feature flag route behavior, §15 security and privacy coverage.

### Gherkin
Given a user is authenticated but is not a workspace admin
When the user attempts to create, edit, or remove an announcement by using the UI or crafting a direct request
Then the request is rejected before any announcement business logic mutates data
And no banner is created, changed, replaced, or removed

### Code-blind plan
- Preconditions: S2, S5, S6, and S9 have write routes for create, edit, replace, and remove.
- Required capabilities: Workspace-admin authorization guard on every admin write path; route-level rejection before validation or persistence side effects; no client-supplied workspace override; consistent unauthorized/forbidden response format; hidden or disabled admin UI entry for non-admin users; audit/logging for forbidden write attempts if consistent with local security practice; tests for crafted direct requests.
- Postconditions: Only workspace admins can mutate announcement state, and crafted requests from non-admin users cannot bypass the UI.
- Risks / assumptions: The design assumes an admin-role middleware exists. Research must confirm exact role naming and whether workspace admin differs from broader organization admin roles.

### Research questions
- RQ1: What existing middleware or guard enforces workspace-admin-only access for admin settings writes?
- RQ2: How are non-admin admin-settings routes expected to respond: 401, 403, 404, or another convention?
- RQ3: How is admin navigation hidden or gated for non-admin users in the frontend?
- RQ4: Is workspace ID ever accepted from request bodies in similar admin routes, or always derived from the session/context?
- RQ5: What security test pattern should cover crafted direct requests against admin-only endpoints?
- RQ6: Should forbidden write attempts be logged or metered, and if so through which security logging path?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.

## Scenario S15 — Runtime failures degrade according to feature criticality
- Order: 15
- Type: corner_case
- Status: planned
- Design references: System design §7 failure scenarios, retries, and timeouts; D3 polling trade-off; §9 observability; §10 fail-closed flag behavior.

### Gherkin
Given the announcement banner feature is enabled
When the active-banner poll fails due to a backend or network error
Then the app does not show a disruptive error to the user
And polling backs off before retrying
When a dismiss request fails
Then the user receives a transient retryable error and may try again
When an admin publish, edit, or remove request fails
Then the admin receives a clear error and no unconfirmed success is shown

### Code-blind plan
- Preconditions: S3, S4, S5, S6, and S9 have read, dismiss, and admin write operations.
- Required capabilities: Frontend poll error handling that renders no banner and backs off; dismiss retry behavior and toast/error affordance; admin write error states; backend status mapping for database unavailable, conflict, validation, unauthorized, and feature-flag-off cases; structured error logs and metrics; alertable counters for poll and dismiss error rates; tests for failure responses without real external services.
- Postconditions: The non-critical banner display fails quietly for ordinary users, user-initiated dismiss failures are visible and retryable, admin write failures are explicit, and operators can observe feature health.
- Risks / assumptions: The design says poll errors should degrade to absent banner. This is acceptable for display-only announcements but means outages may hide critical admin messages, so observability is important.

### Research questions
- RQ1: What frontend data-fetching utilities support poll backoff and silent failure modes?
- RQ2: What toast or inline error pattern should be used for dismiss failure and admin write failure?
- RQ3: How are backend database-unavailable errors mapped to user-facing status codes in existing routes?
- RQ4: What metrics and alerting helpers are available for endpoint result counters and error-rate alerts?
- RQ5: How should tests inject backend/network failure for polling, dismiss, and admin writes?
- RQ6: Is fail-closed feature-flag behavior already standardized for backend routes and frontend feature mounts?

### Research findings
- TBD by kite-research.

### Implementation record
- TBD by kite-implementation.
