# Implementation Plan: Admin Announcement Banner

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-system-design.md
- Summary: Workspace admins can publish one short plain-text announcement banner, optionally with a link and start/end window, for all users in the workspace. Users can dismiss a banner per user across devices and sessions. The design uses server-side persistence, workspace-scoped authenticated APIs, short polling for display, feature-flagged rollout, and database-enforced single-active-banner semantics.

## Scenario order & status
| # | ID | Title | Status |
|---|----|-------|--------|
| 1 | S1 | Admin settings page and empty state | planned |
| 2 | S2 | Publish immediate banner and show it to users | planned |
| 3 | S3 | User dismissal persists per user across sessions and devices | planned |
| 4 | S4 | Admin edits active banner without resetting dismissals | planned |
| 5 | S5 | Admin removes active banner early | planned |
| 6 | S6 | Future start date delays visibility | planned |
| 7 | S7 | End date expiry stops visibility | planned |
| 8 | S8 | Invalid or unsafe publish input is rejected | planned |
| 9 | S9 | User joining after publish sees the active banner | planned |
| 10 | S10 | Publishing a new banner replaces the previous active banner | planned |
| 11 | S11 | Non-admin write attempts are rejected | planned |
| 12 | S12 | Feature flag fail-closed behavior | planned |
| 13 | S13 | Runtime failures degrade gracefully | planned |

## Ordering rationale
S1 establishes the vertical surfaces and normal empty state that every later scenario reuses. S2 creates the first end-to-end banner path: admin write, persistence, user polling, and display. S3 adds the server-side dismissal identity that S4 depends on. S5 through S7 reuse the active-banner display path while adding removal and time-window rules. S8 hardens the write path after the basic publish flow exists. S9 validates workspace/user scoping using the already-published banner behavior. S10 adds replacement and admin race handling after publish and edit are both available. S11 then applies authorization hardening across the write operations. S12 and S13 finish the plan with rollout and reliability behavior from the system design because those are cross-cutting guards over the already-defined surfaces.

## Scenario S1 - Admin settings page and empty state
- Order: 1
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 1; blueprint edge case "No banner is active"; System design sections 2, 8, and 10.

### Gherkin
Given the announcement banner feature is enabled for a workspace
And a workspace admin is signed in
And no announcement banner is active for that workspace
When the admin opens the Announcements page in admin settings
Then the admin can see the announcement authoring surface
And app users in the workspace see no announcement banner
And no error or placeholder banner is shown to users

### Code-blind plan
- Preconditions: The feature is enabled for the workspace; a signed-in workspace admin and at least one signed-in workspace user are available for verification.
- Required capabilities: A feature-flag check for announcement-banner surfaces; a workspace-admin-only settings navigation entry and page; a workspace-scoped active-banner read path that returns an empty result when no banner is active; an app-shell placement for the user-facing banner that renders nothing for an empty result.
- Postconditions: The admin has a usable place to create announcements, and the user-facing shell handles the normal no-banner state without visible disruption.
- Risks / assumptions: The design requires the feature flag to gate the admin page, banner component, and backend routes. Empty state must be treated as normal behavior, not as an error.

### Research questions
- RQ1: Is there an existing workspace feature-flag mechanism suitable for gating admin navigation, app-shell mounting, and backend route behavior?
- RQ2: Is there an existing admin-settings navigation/page pattern for workspace-admin-only settings pages?
- RQ3: Is there an existing authenticated workspace context resolver for reads from the app shell?
- RQ4: Is there an existing app-shell insertion point for a top-of-app banner that can render nothing without shifting unrelated layout?
- RQ5: Is there an established empty-result response shape for lightweight authenticated read endpoints?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S2 - Publish immediate banner and show it to users
- Order: 2
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path steps 2 and 3; blueprint rules for plain text, optional link, no start date, no end date, and one active banner; System design sections 2, 3 decisions D2 through D6, 4, 6, 8, and 9.

### Gherkin
Given the announcement banner feature is enabled
And a workspace admin is on the Announcements page
When the admin enters a non-empty plain-text message of at most 200 characters
And optionally provides a valid link
And does not provide a start date or end date
And clicks Publish
Then the banner is active immediately for the workspace
And every authenticated user in the workspace sees the banner at the top of the app within the configured polling window
And the banner remains active until it is replaced, removed, or otherwise made inactive

### Code-blind plan
- Preconditions: S1 is implemented. The workspace admin can access the authoring page, and users can reach the app shell with the banner component mounted.
- Required capabilities: A persisted workspace announcement record with message, optional link, start and end timestamps, status, creator, and timestamps; a transactional publish operation that archives any prior active banner before creating the new one; a single-active-banner invariant at the persistence layer; an authenticated workspace-scoped active-banner read that filters by server time; a polling client with a configurable interval; safe plain-text rendering and optional HTTPS link rendering; structured logging and metrics for publish and poll.
- Postconditions: Publishing an immediate banner creates exactly one active workspace banner, users see it without a page reload after polling, and no fan-out worker or external service is required.
- Risks / assumptions: The design accepts up to 30 seconds of freshness latency. It assumes the app can use server-side time for activation. Optional link display text is not fully specified by the blueprint; the plan should preserve the design intent without adding rich text or a separate targeting model.

### Research questions
- RQ1: What migration mechanism should create new announcement and dismissal persistence structures, and what naming conventions should be followed?
- RQ2: Is there an existing transaction helper for multi-step workspace-scoped writes?
- RQ3: Is there an existing pattern for enforcing database-level partial unique constraints or equivalent single-active invariants?
- RQ4: Is there an existing admin write route or service pattern for workspace-scoped resources?
- RQ5: Is there an existing authenticated app-level route pattern for lightweight polling reads?
- RQ6: Is there an existing frontend data-fetching or polling helper that supports configurable intervals and graceful empty results?
- RQ7: Is there an established component or styling pattern for top-of-app informational banners?
- RQ8: Is there an existing structured logging and metrics helper for route-level publish and poll instrumentation?
- RQ9: Is there an existing safe-link validation helper that enforces HTTPS-only URLs?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S3 - User dismissal persists per user across sessions and devices
- Order: 3
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 4; blueprint rule "Dismissal is per user"; System design decision D1, decision D4, data model section 4, reliability section 7, and security section 8.

### Gherkin
Given an active announcement banner is visible to a signed-in workspace user
When the user dismisses the banner
Then the dismissal is recorded for that user and that announcement
And the banner no longer appears for that user in the current session
And the banner does not reappear for that user in later sessions or on another device
And other users who have not dismissed the banner can still see it

### Code-blind plan
- Preconditions: S2 is implemented. A visible active banner exists, and there are at least two users in the workspace for per-user verification.
- Required capabilities: A server-side dismissal record keyed by announcement and authenticated user; an idempotent dismiss write that tolerates retries and double clicks; an active-banner read that joins or otherwise combines announcement state with the current user's dismissal state; frontend behavior that hides the banner only after a successful dismissal or refetches after a failure; a user-facing transient error for failed dismissal writes.
- Postconditions: Dismissal is authoritative on the server, applies only to the current user, survives device/session changes, and does not mutate the announcement itself.
- Risks / assumptions: The client must never accept a user ID from the request body for dismissal. Dismissal persistence is central to the blueprint and must not fall back to browser-only storage.

### Research questions
- RQ1: Is there an existing persistence pattern for join tables keyed by resource ID and user ID?
- RQ2: Is there an existing route or service pattern for idempotent authenticated user actions?
- RQ3: Is there an established way to derive the current user ID from the session for writes without trusting client-supplied user IDs?
- RQ4: Is there an existing frontend mutation pattern for optimistic or confirmed dismissal actions with retry/error handling?
- RQ5: Is there an existing toast or transient error mechanism suitable for "Could not save dismissal, please try again" behavior?
- RQ6: Is there an existing test pattern for cross-session or cross-device persistence expectations?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S4 - Admin edits active banner without resetting dismissals
- Order: 4
- Type: edge_case
- Status: planned
- Design references: Blueprint rule "An admin can edit the active banner's text"; blueprint deviation "dismissal sticks to the banner, not its text"; System design sections 2, 7, 8, 9, and open risk 5.

### Gherkin
Given an active announcement banner exists
And a workspace user has already dismissed that banner
When a workspace admin edits the active banner's text or link
Then the banner content is updated for users who have not dismissed it
And the user who already dismissed that banner still does not see it
And the edit does not create a new banner identity

### Code-blind plan
- Preconditions: S2 and S3 are implemented. There is an active banner and at least one dismissed user plus one non-dismissed user.
- Required capabilities: An admin-only edit operation that updates the active announcement record without replacing its identity; validation of edited message and link fields; updated timestamp/log/metric behavior for edits; active-banner polling that returns updated content to non-dismissed users; dismissal checks that remain keyed to the same banner identity after edit.
- Postconditions: Edited text/link propagates through polling to eligible users, while users who dismissed that banner remain suppressed.
- Risks / assumptions: The design accepts last-writer-wins for concurrent text edits unless research finds an established optimistic-lock pattern that should be applied. The edit operation must not archive and recreate the banner, or it would break the dismissal invariant.

### Research questions
- RQ1: Is there an existing admin PATCH/update pattern for workspace-scoped resources?
- RQ2: Is there an existing validation helper that can be reused for message length, plain-text treatment, and HTTPS-only link validation on both publish and edit?
- RQ3: Is there an established update/audit logging pattern for admin edits?
- RQ4: Is there an existing optimistic-lock or last-writer-wins convention for admin settings edits?
- RQ5: Is there an existing frontend cache invalidation or polling refresh pattern after an admin edit?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S5 - Admin removes active banner early
- Order: 5
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 5; blueprint rule "If no end date is given, it stays active until the admin removes it"; blueprint rule "An admin can end a banner early"; System design decision D6, data model section 4, rollout section 10, and observability section 9.

### Gherkin
Given an active announcement banner exists for a workspace
When a workspace admin clicks Remove
Then the banner is ended for the workspace immediately
And users no longer see it on subsequent polls
And a banner with no configured end date remains active until this remove action or replacement occurs

### Code-blind plan
- Preconditions: S2 is implemented. An active banner can be published and displayed.
- Required capabilities: An admin-only remove operation for the active announcement; a persistence state that marks the banner removed and/or ends its visibility using server time; active-banner reads that exclude removed announcements; frontend admin UI state that reflects successful removal; structured logging and metrics for remove; clear admin-facing errors if removal fails.
- Postconditions: The active banner is no longer visible to any user after polling, and indefinite banners have an explicit admin-controlled end path.
- Risks / assumptions: The design treats removal as soft deletion rather than hard deletion. Visibility should be controlled by the server-side read, not by client-side hiding alone.

### Research questions
- RQ1: Is there an existing admin DELETE/remove route convention for soft-removing workspace resources?
- RQ2: Is there an existing persistence convention for removed or archived statuses?
- RQ3: Is there an existing server-time helper for setting removal or end timestamps?
- RQ4: Is there an existing frontend confirmation or immediate-remove pattern for admin settings controls?
- RQ5: Is there an existing logging/metrics helper for admin remove events?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S6 - Future start date delays visibility
- Order: 6
- Type: edge_case
- Status: planned
- Design references: Blueprint edge case "The start date is in the future"; System design decision D6, data model section 4, performance section 6, and open risk 2.

### Gherkin
Given a workspace admin publishes a banner with a start date in the future
When users poll for the active announcement before that start date
Then no banner is shown
When the server-side start time is reached
Then eligible users see the banner within the configured polling window

### Code-blind plan
- Preconditions: S2 is implemented. Publishing accepts an optional start timestamp, and user polling is in place.
- Required capabilities: Validation and normalization of ISO 8601 start timestamps; server-side time-window filtering for active-banner reads; frontend/admin display of scheduled state where needed; tests or verification controls that can evaluate before-start and after-start behavior using server time.
- Postconditions: Future-start banners are stored as active records but are not visible until the server-side start time is reached.
- Risks / assumptions: Browser clock skew must not determine visibility. Admin UX may need to communicate that times are server-relative or normalized to an agreed timezone.

### Research questions
- RQ1: Is there an existing date/time input and timezone handling pattern in admin settings?
- RQ2: Is there an existing server-side timestamp parser/validator for ISO 8601 inputs?
- RQ3: Is there an existing way to test time-window behavior without relying on wall-clock waits?
- RQ4: Is there an established pattern for presenting scheduled-but-not-yet-visible admin settings state?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S7 - End date expiry stops visibility
- Order: 7
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path step 5; blueprint rule "If no end date is given, it stays active until the admin removes it"; System design decision D6, reliability section 7, and performance section 6.

### Gherkin
Given a workspace admin publishes a banner with an end date
And the banner is visible during its active window
When the server-side end date passes
Then the banner stops showing for everyone on subsequent polls
And no scheduled worker is required to hide it

### Code-blind plan
- Preconditions: S2 and S6 are implemented. Active-banner reads already apply server-side time-window filtering.
- Required capabilities: End timestamp validation and persistence; server-side filtering that excludes banners whose end time has passed; frontend polling behavior that removes an expired banner from the app shell after the next successful poll; admin UI behavior that can represent ended/expired state if the active banner is no longer visible.
- Postconditions: Expiry is deterministic from stored timestamps and server time, and expired banners do not require background jobs to disappear.
- Risks / assumptions: The design keeps status useful for active/archived/removed semantics, but visibility is derived from time-window filtering. That distinction must remain clear in implementation and tests.

### Research questions
- RQ1: Is there an existing shared helper for comparing stored timestamps against database or server time?
- RQ2: Is there an existing test pattern for expiry without adding a background worker?
- RQ3: Is there an existing admin settings pattern for displaying a resource that has ended or is no longer active?
- RQ4: Is there an existing frontend polling/cache pattern that removes stale displayed data after a null active response?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S8 - Invalid or unsafe publish input is rejected
- Order: 8
- Type: edge_case
- Status: planned
- Design references: Blueprint edge case "The end date is before the start date"; blueprint rules for plain text and 200-character maximum; System design security section 8, data model section 4, and open risk 4.

### Gherkin
Given a workspace admin is creating or editing an announcement
When the admin submits an empty message, a message over 200 characters, non-plain-text content, an unsafe or non-HTTPS link, invalid timestamps, or an end date before the start date
Then the request is rejected
And the admin sees a validation message
And no active banner is created or mutated by that invalid request

### Code-blind plan
- Preconditions: S2 and S4 are implemented. Publish and edit paths both accept user-provided fields.
- Required capabilities: Shared validation for message presence, message length, plain-text handling, optional HTTPS-only link URL, valid timestamps, and end-after-start ordering; admin UI validation that mirrors server rules without replacing server enforcement; safe rendering that never parses banner text as HTML or markdown; transactional write behavior that leaves existing active state unchanged on validation failure.
- Postconditions: Invalid input is rejected consistently on publish and edit, with clear admin-facing messages and no partial persistence.
- Risks / assumptions: The blueprint mentions an optional link but not a separate link label. This plan should not add extra link-label behavior unless product behavior is clarified later.

### Research questions
- RQ1: Is there an existing validation library or schema pattern for route handlers and matching frontend forms?
- RQ2: Is there an existing convention for returning field-level validation errors to admin settings forms?
- RQ3: Is there an existing text sanitization or plain-text rendering standard for user-authored text?
- RQ4: Is there an existing URL validation helper that blocks javascript-like or non-HTTPS schemes?
- RQ5: Is there an existing transaction or request-validation pattern that prevents partial writes after validation errors?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S9 - User joining after publish sees the active banner
- Order: 9
- Type: edge_case
- Status: planned
- Design references: Blueprint edge case "A user who joins after a banner was published"; System design decision D4, security section 8, and data model section 4.

### Gherkin
Given a banner was published before a user joined the workspace
And the banner is still inside its active window
When the new user signs in to the workspace
Then the user sees the banner
And the user has no dismissal recorded for that banner until they dismiss it

### Code-blind plan
- Preconditions: S2, S3, S6, and S7 are implemented. Workspace membership changes or fixtures can represent a user who joined after publication.
- Required capabilities: Active-banner reads based on current authenticated workspace membership rather than publication-time membership; dismissal lookup that treats missing dismissal records as not dismissed; no precomputed fan-out list of banner recipients; tests or verification fixtures for a user added after publication.
- Postconditions: Banner eligibility is dynamic based on current workspace membership and the active window, not fixed at publish time.
- Risks / assumptions: This scenario depends on existing workspace membership semantics; the plan must ask research to find the correct membership source rather than assume one.

### Research questions
- RQ1: Is there an existing workspace membership resolver for the current authenticated user?
- RQ2: Is there an existing fixture or test helper for adding a user to a workspace after a resource was created?
- RQ3: Is there any existing notification or membership fan-out mechanism that must be avoided or bypassed because this banner is read-time scoped?
- RQ4: Is there an established query pattern for treating absent per-user rows as false/undismissed?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S10 - Publishing a new banner replaces the previous active banner
- Order: 10
- Type: deviation
- Status: planned
- Design references: Blueprint rule "At most one banner is active per workspace"; blueprint deviation "An admin publishes a banner while another admin is editing the old one"; System design decision D2, data model section 4, reliability section 7, and open risk 5.

### Gherkin
Given one announcement banner is active for a workspace
And another admin may have a stale edit view of that banner
When a workspace admin publishes a new banner
Then the previous active banner is no longer active
And the newly published banner is the active banner for the workspace
And the system never exposes two active banners for the same workspace
And a truly conflicting simultaneous publish is handled with a clear conflict response rather than creating two active banners

### Code-blind plan
- Preconditions: S2, S4, and S8 are implemented. Publish and edit routes already exist and validate input.
- Required capabilities: A publish transaction that archives or otherwise deactivates the previous active banner before creating the new one; a persistence-layer uniqueness guarantee for one active banner per workspace; conflict detection and clear admin-facing recovery messaging for concurrent publishes; stale edit handling that does not resurrect or mutate an announcement that is no longer the active banner unless product behavior explicitly allows it; polling behavior that surfaces only the new active banner.
- Postconditions: The workspace has at most one active announcement, users see the newest active banner after polling, and admin race conditions do not violate the invariant.
- Risks / assumptions: The blueprint says the most recent publish wins. The system design also accepts a conflict response for true simultaneous publish races due to the database invariant. Research should verify how the app normally expresses conflict responses and stale-edit behavior.

### Research questions
- RQ1: Is there an existing database constraint or index migration pattern for enforcing one active resource per workspace?
- RQ2: Is there an existing transaction helper that can archive the prior active row and create a new active row atomically?
- RQ3: Is there an existing error-mapping convention for uniqueness conflicts to admin-facing conflict responses?
- RQ4: Is there an existing stale-edit or optimistic-concurrency pattern for admin settings forms?
- RQ5: Is there an existing frontend refresh/reload prompt pattern for "another admin changed this" conflicts?
- RQ6: Is there an established test pattern for concurrent or interleaved admin writes?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S11 - Non-admin write attempts are rejected
- Order: 11
- Type: adversarial
- Status: planned
- Design references: Blueprint adversarial scenarios; System design security section 8 and abuse vectors section 8.

### Gherkin
Given a signed-in user is not a workspace admin
When the user crafts a request to create, edit, or remove an announcement banner
Then the request is rejected before announcement business logic runs
And no announcement record is created, edited, removed, or otherwise mutated
And authenticated non-admin users can still read and dismiss banners according to normal user behavior

### Code-blind plan
- Preconditions: S2, S4, S5, and S3 are implemented. Admin write paths and user read/dismiss paths exist.
- Required capabilities: Workspace-admin authorization for publish, edit, and remove; authenticated user authorization for active-banner read and dismissal; route-level rejection before business logic for non-admin writes; tests covering crafted requests, not just hidden UI controls; no client-supplied workspace or user IDs trusted for authorization.
- Postconditions: Only workspace admins can mutate announcements, while regular authenticated users can read and dismiss only within their authorized workspace context.
- Risks / assumptions: UI hiding is insufficient for this scenario. Authorization must be enforced server-side and scoped to the workspace.

### Research questions
- RQ1: Is there an existing workspace-admin authorization middleware or helper for admin routes?
- RQ2: Is there an existing authenticated-user middleware or helper for app-level read/dismiss routes?
- RQ3: Is there an existing convention for deriving workspace ID from the session rather than request body parameters?
- RQ4: Is there an existing test helper for asserting non-admin crafted requests fail before mutation?
- RQ5: Is there an existing audit/logging convention for denied admin attempts, or should denied requests only use standard access logs?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S12 - Feature flag fail-closed behavior
- Order: 12
- Type: corner_case
- Status: planned
- Design references: System design rollout section 10 and assumptions A7; applies to blueprint-visible admin page and app-shell banner surfaces.

### Gherkin
Given the announcement banner feature flag is disabled or unavailable
When a workspace admin opens settings
Then the Announcements page or navigation entry is not available
When a user opens the app
Then the banner component does not mount or render
When any announcement-banner backend route is called
Then the route behaves as unavailable according to the design
And no announcement data is created accidentally

### Code-blind plan
- Preconditions: S1 through S11 define the feature surfaces that must be gated.
- Required capabilities: A single feature-flag decision that defaults to off when unavailable; frontend gating for admin settings navigation/page and app-shell component; backend gating for admin and user announcement routes; tests for flag-on and flag-off behavior; rollout documentation or configuration hooks for test workspace, gradual rollout, and full rollout.
- Postconditions: The feature can be safely deployed dark, enabled gradually, and immediately disabled without losing stored data.
- Risks / assumptions: If the workspace has no dedicated flag system, an environment or configuration toggle may satisfy the design intent, but research must identify the appropriate local mechanism.

### Research questions
- RQ1: Is there an existing feature-flag or configuration mechanism that can gate frontend and backend behavior per workspace?
- RQ2: Is fail-closed behavior already available when the flag service or configuration lookup fails?
- RQ3: Is there an existing pattern for hiding settings navigation entries behind flags?
- RQ4: Is there an existing backend route pattern for returning unavailable/not found when a feature flag is off?
- RQ5: Is there an established rollout checklist or environment configuration location for staged enablement?

### Research findings
- Pending.

### Implementation record
- Pending.

## Scenario S13 - Runtime failures degrade gracefully
- Order: 13
- Type: corner_case
- Status: planned
- Design references: System design reliability section 7, observability section 9, performance section 6, and accepted compromises C1 through C4.

### Gherkin
Given the announcement banner feature is enabled
When the active-banner poll fails because storage or the network is unavailable
Then users do not see a disruptive error for the non-critical banner widget
And the client backs off before polling again
When dismissal fails
Then the user receives a transient retryable error and the banner remains eligible until dismissal succeeds
When admin publish, edit, or remove fails
Then the admin receives a clear error and no partial banner change is applied

### Code-blind plan
- Preconditions: S2 through S5 are implemented. Poll, dismiss, and admin write flows exist.
- Required capabilities: Poll error handling that renders no banner and records an error metric/log; client backoff for repeated poll failures; dismiss retry behavior plus transient user-facing error; admin write error handling with clear messages and no automatic retry; route timeouts and storage-error mapping; metrics counters and alerts for poll, dismiss, and publish/edit/remove errors.
- Postconditions: Banner failures do not break the main app, admin failures are visible and retryable, and operators have enough signals to detect poll or dismissal error spikes.
- Risks / assumptions: The design intentionally chooses graceful absence over user-visible poll errors. Admin write idempotency keys are a follow-up, so conflict/error messaging must be clear enough to prevent accidental repeated publishes.

### Research questions
- RQ1: Is there an existing frontend polling backoff helper or retry policy to reuse?
- RQ2: Is there an existing global or local error display pattern for transient user action failures?
- RQ3: Is there an existing admin form error pattern for storage or validation failures?
- RQ4: Is there an existing route error-mapping layer for storage unavailable, conflict, unauthorized, validation, and not-found responses?
- RQ5: Is there an existing metrics library and naming convention for counters, gauges, labels, and alert hooks?
- RQ6: Is there an existing structured logging convention that avoids logging user-authored banner text?
- RQ7: Is there an existing timeout policy for lightweight route handlers?

### Research findings
- Pending.

### Implementation record
- Pending.
