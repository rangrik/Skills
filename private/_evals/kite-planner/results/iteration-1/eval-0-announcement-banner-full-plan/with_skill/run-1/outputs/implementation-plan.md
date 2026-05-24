# Implementation Plan: Admin Announcement Banner

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/announcement-banner-system-design.md
- Summary: Build a workspace-scoped admin announcement banner that lets workspace admins publish, edit, schedule, and remove one active plain-text banner with an optional link. All authenticated users in the workspace can see the active banner in the app shell, can dismiss it per user, and dismissal is stored server-side so it persists across devices and sessions.

## Scenario order & status
| # | ID | Title | Status |
|---|----|-------|--------|
| 1 | S1 | Feature gate and no-active-banner baseline | planned |
| 2 | S2 | Admin publishes a valid immediate banner | planned |
| 3 | S3 | User dismisses a banner across devices and sessions | planned |
| 4 | S4 | Scheduled start and end windows control visibility | planned |
| 5 | S5 | Admin removes a banner early | planned |
| 6 | S6 | Admin edits the active banner text | planned |
| 7 | S7 | Dismissal survives an admin edit | planned |
| 8 | S8 | New workspace user sees an existing active banner | planned |
| 9 | S9 | Invalid banner input is rejected | planned |
| 10 | S10 | Publishing a new banner replaces the previous active banner | planned |
| 11 | S11 | Concurrent publish attempts preserve the one-active-banner invariant | planned |
| 12 | S12 | Only workspace admins can mutate banners | planned |
| 13 | S13 | Banner reads and dismissals are authenticated and workspace-scoped | planned |
| 14 | S14 | Non-critical failures degrade gracefully and remain observable | planned |

## Ordering rationale
- S1 establishes the rollout guard, empty-state behavior, and the app-shell/admin-settings integration points that later scenarios depend on.
- S2 is the first end-to-end vertical slice: persistence, admin write path, active-banner read path, and banner rendering.
- S3 adds the central server-side dismissal invariant required by the blueprint and reused by edit, scheduling, and new-user scenarios.
- S4 and S5 add lifecycle controls after the basic publish/read/dismiss flows exist.
- S6 and S7 are ordered after dismissal because edits must preserve the dismissal semantics already introduced.
- S8 validates the workspace/user relationship once active banner visibility and dismissal are in place.
- S9 hardens the write contract after the main write paths exist.
- S10 and S11 handle replacement and concurrency once publish is already functional.
- S12 and S13 add the adversarial authorization and scoping guarantees around the complete route surface.
- S14 closes the plan with reliability and observability behavior that applies across all user-facing flows.

## Scenario S1 — Feature gate and no-active-banner baseline
- Order: 1
- Type: edge_case
- Status: planned
- Design references: System design §2 System Placement, §10 Rollout & Operability, §7 Reliability & Failure Handling, D4 poll endpoint contract

### Gherkin
Given the announcement banner feature is disabled or no banner is active for a workspace
When a user opens the app and an admin opens admin settings
Then users see no banner, the UI remains otherwise unchanged, and the admin announcement surface is unavailable while the feature is disabled

### Code-blind plan
- Preconditions: The feature has a rollout flag decision and a normal empty state is defined by the blueprint.
- Required capabilities: A feature flag that can disable frontend surfaces and backend routes fail-closed; an app-shell location where an announcement banner can render nothing without shifting unrelated behavior; an admin settings navigation location that can hide or show the announcements page; a workspace-aware active-banner read contract that can return no banner.
- Postconditions: With the flag off or no active banner, users and admins experience the app normally with no banner shown and no accidental data creation path available.
- Risks / assumptions: The design assumes a feature flag mechanism exists or can be represented by an environment or configuration toggle. The empty state must not log noisy errors or show placeholder UI.

### Research questions
- RQ1: What feature flag or configuration mechanism should gate frontend components and backend routes for workspace features?
- RQ2: Where is the app-shell or layout integration point for a top-of-app banner that can render nothing when absent?
- RQ3: Where is the admin settings navigation/page registration mechanism for a new announcements page?
- RQ4: What route or middleware pattern should return an unavailable response when a disabled feature is requested?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S2 — Admin publishes a valid immediate banner
- Order: 2
- Type: happy_path
- Status: planned
- Design references: Blueprint happy path and rules; System design D1, D2, D3, D4, D5, §2, §4, §6, §8

### Gherkin
Given a workspace admin is on the Announcements page
When they enter a plain-text message of 1 to 200 characters, optionally provide an https link, leave the start date empty, and publish
Then one active banner is stored for the workspace and authenticated users in that workspace see it at the top of the app within the polling window

### Code-blind plan
- Preconditions: S1 has established the gated page, app-shell mount point, and no-banner response behavior.
- Required capabilities: Workspace-announcement persistence with message, optional link, start/end window, status, creator, and timestamps; a server-side publish operation that creates the active banner for the authenticated admin's workspace; a user-aware active-banner read endpoint; a polling frontend component; a banner UI that displays plain text and an optional link without rich-text rendering.
- Postconditions: A valid immediate publish creates exactly one active workspace banner, returns success to the admin, and becomes visible to users without requiring a page reload beyond the polling interval.
- Risks / assumptions: Link display text is not specified by the blueprint; the design assumes either the URL itself or a fixed label such as "Learn more." Polling latency is accepted at about 30 seconds.

### Research questions
- RQ1: What migration framework and naming convention should create the new announcement persistence tables and indexes?
- RQ2: What backend route/module should own admin settings write endpoints for workspace-scoped resources?
- RQ3: What backend route/module should own app-level authenticated read endpoints used by the app shell?
- RQ4: What data-access or transaction helper should be used for the publish operation?
- RQ5: What frontend data-fetching pattern should the polling banner component use?
- RQ6: What UI component patterns should be used for a top-of-app banner, dismiss button, and optional link?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S3 — User dismisses a banner across devices and sessions
- Order: 3
- Type: happy_path
- Status: planned
- Design references: Blueprint dismissal rule; System design D1, D4, §4, §7, §8

### Gherkin
Given an authenticated user sees an active banner
When they click the dismiss control
Then the dismissal is recorded for that user and banner, the banner disappears for that user, and it does not return for that user across devices or sessions

### Code-blind plan
- Preconditions: S2 has an active banner visible to users.
- Required capabilities: Server-side dismissal persistence keyed by announcement and authenticated user; a dismiss endpoint that never accepts a client-supplied user identity; an idempotent write path for repeated dismiss actions; active-banner reads that include or apply dismissal state; frontend behavior that hides the banner after a successful dismissal and handles retryable failure.
- Postconditions: Dismissed users no longer see that announcement anywhere they sign in, while users who have not dismissed it continue to see it.
- Risks / assumptions: Dismissal must not use local storage or cookies as the source of truth. The UI should avoid permanently hiding the banner if the server dismissal fails.

### Research questions
- RQ1: How does the backend identify the authenticated user ID and workspace ID in request handlers?
- RQ2: Where should user-by-announcement dismissal records be stored and queried?
- RQ3: What insert-or-ignore or equivalent idempotency pattern is used for duplicate writes?
- RQ4: How should the frontend represent a pending, successful, and failed dismiss request?
- RQ5: What toast or transient error pattern should be used if dismissal cannot be saved?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S4 — Scheduled start and end windows control visibility
- Order: 4
- Type: edge_case
- Status: planned
- Design references: Blueprint edge cases and scheduling rules; System design D6, §4, §7, §13 clock-skew callout

### Gherkin
Given an admin publishes a banner with a future start date or an end date
When users poll before the start date, during the active window, and after the end date
Then the banner is hidden before the start, visible during the active window unless dismissed, and hidden for everyone after the end date

### Code-blind plan
- Preconditions: S2 has publish and active read behavior; S3 has dismissal filtering.
- Required capabilities: Admin UI controls for optional start and end date/time; server-side timestamp validation and normalization; active-banner query logic based on server-side current time; no scheduled expiry job required for visibility; clear handling when start is omitted or end is omitted.
- Postconditions: Time windows determine visibility consistently for all users, with no client clock dependency for whether a banner is active.
- Risks / assumptions: Browser clock skew can confuse admins setting "now"; the design uses server or database time as authoritative.

### Research questions
- RQ1: What date/time input components and timezone conventions are used in admin settings forms?
- RQ2: Where should timestamp parsing and validation live for backend request payloads?
- RQ3: What database or service helper should supply authoritative current time for active-window filtering?
- RQ4: Are there established tests or helpers for time-dependent backend behavior?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S5 — Admin removes a banner early
- Order: 5
- Type: happy_path
- Status: planned
- Design references: Blueprint remove rule; System design D5, D6, §2, §4, §7

### Gherkin
Given a workspace admin sees an active banner in the Announcements page
When they click Remove and confirm the action
Then the banner stops showing for every user before its scheduled end time

### Code-blind plan
- Preconditions: S2 has an active banner and admin page; S4 has time-window semantics.
- Required capabilities: Admin UI affordance for removing the active banner; a synchronous remove endpoint; persistence update that marks the banner removed and makes the active-banner query exclude it immediately; user-facing poll behavior that clears the banner on the next successful poll.
- Postconditions: Removed banners no longer appear, while historical records and dismissal records can remain for audit or retention.
- Risks / assumptions: Removal is different from deleting history; the design prefers soft removal with status and current end time.

### Research questions
- RQ1: What confirmation dialog or destructive-action pattern should the admin UI use?
- RQ2: What backend delete or remove route convention should be followed for admin resources?
- RQ3: How are soft-removed records represented in nearby data models, if applicable?
- RQ4: What frontend cache or polling state must be invalidated after an admin removes a banner?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S6 — Admin edits the active banner text
- Order: 6
- Type: happy_path
- Status: planned
- Design references: Blueprint edit rule; System design §2, §4, §7, §13 concurrent edit callout

### Gherkin
Given a workspace admin is editing the active banner
When they change the banner text and save
Then the active banner keeps the same banner identity and users who have not dismissed it see the updated text

### Code-blind plan
- Preconditions: S2 has active banner creation and rendering.
- Required capabilities: Admin UI for loading and editing the current active banner; an edit endpoint that updates message and allowed editable fields without creating a new banner identity; validation shared with publish; frontend polling behavior that picks up changed content.
- Postconditions: The active banner content updates for non-dismissed users while remaining the same announcement for dismissal purposes.
- Risks / assumptions: The design accepts last-writer-wins for simultaneous text edits unless a later research finding identifies an existing optimistic-locking standard that should be followed.

### Research questions
- RQ1: How should the admin page fetch and display the current active banner for editing?
- RQ2: What backend update route convention should be used for admin resources with an ID?
- RQ3: Is there an established shared validation layer for create and update payloads?
- RQ4: Is there an existing optimistic-locking or stale-form pattern for admin settings edits?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S7 — Dismissal survives an admin edit
- Order: 7
- Type: deviation
- Status: planned
- Design references: Blueprint deviation scenario; System design D1, D4, §4

### Gherkin
Given a user has dismissed an active banner
When an admin edits that banner's text
Then the user still does not see the banner because dismissal is tied to the banner identity, not the text

### Code-blind plan
- Preconditions: S3 records dismissal by announcement identity; S6 edits without replacing the announcement identity.
- Required capabilities: Stable announcement ID across edits; dismissal lookup by announcement ID and user ID; tests or checks that edit does not clear dismissals or create a replacement announcement unintentionally.
- Postconditions: Editing content cannot resurrect a dismissed banner for users who already dismissed that banner.
- Risks / assumptions: If product later wants substantial edits to count as a new announcement, that would contradict the current blueprint.

### Research questions
- RQ1: How can implementation tests verify that an edit preserves the announcement identity?
- RQ2: Where should dismissal-filtering logic live so both original and edited content use the same rule?
- RQ3: Are there existing update patterns that accidentally replace rows or IDs and should be avoided for this feature?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S8 — New workspace user sees an existing active banner
- Order: 8
- Type: edge_case
- Status: planned
- Design references: Blueprint edge case; System design D1, D4, §4, §8

### Gherkin
Given a banner was published before a user joined the workspace
When the new user opens the app during the banner's active window
Then they see the banner because they have no dismissal record for that banner

### Code-blind plan
- Preconditions: S2 has active visibility; S3 has per-user dismissal records; S4 has active-window filtering.
- Required capabilities: Active-banner reads scoped to the user's current workspace; dismissal joins or checks that treat missing records as not dismissed; no publication-time membership snapshot that would exclude later users.
- Postconditions: New users are included automatically by workspace scope and active-window state.
- Risks / assumptions: Workspace membership and request workspace resolution must be authoritative and cannot come from a client-supplied workspace ID.

### Research questions
- RQ1: How does the app resolve a user's current workspace during app-shell requests?
- RQ2: Is there a workspace membership model that the active-banner query must consult beyond the session workspace ID?
- RQ3: How can tests create or simulate a user with no dismissal record for an existing workspace banner?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S9 — Invalid banner input is rejected
- Order: 9
- Type: edge_case
- Status: planned
- Design references: Blueprint message length and invalid date edge case; System design §4, §8

### Gherkin
Given a workspace admin is publishing or editing a banner
When the message is empty, longer than 200 characters, not plain text, has an invalid link, has invalid timestamps, or has an end date before the start date
Then the write is rejected and the admin sees a validation message without changing the active banner

### Code-blind plan
- Preconditions: S2 and S6 have create and update forms and endpoints.
- Required capabilities: Shared server-side validation for message length, required message, plain-text treatment, https-only optional link, timestamp parsing, and end-after-start rule; matching client-side validation for fast feedback; clear validation messages; no partial persistence when validation fails.
- Postconditions: Invalid inputs do not create, replace, edit, or remove any banner state.
- Risks / assumptions: "Plain text" means HTML or markdown is not rendered as markup; it may be accepted as literal text unless product requires rejection. Link display behavior remains an open product detail.

### Research questions
- RQ1: What validation library or request-schema pattern should be used for backend payload validation?
- RQ2: What form validation pattern should the admin frontend use for field-level errors?
- RQ3: How should the implementation distinguish "render as literal text" from "reject unsafe markup" for message input?
- RQ4: What URL validation helper should enforce https-only links?
- RQ5: What error response shape should validation failures use?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S10 — Publishing a new banner replaces the previous active banner
- Order: 10
- Type: deviation
- Status: planned
- Design references: Blueprint one-active-banner rule and admin editing deviation; System design D2, D5, §4, §7

### Gherkin
Given one banner is active and one admin is editing older banner content
When another admin publishes a newer banner or the first admin later publishes their edited version
Then the most recent successful publish becomes the workspace's active banner and the previous active banner is no longer active

### Code-blind plan
- Preconditions: S2 has publish; S5 has inactive status handling; S6 has admin editing.
- Required capabilities: A transactional replace operation that archives the previous active banner and inserts the new active banner; a database-level one-active-banner invariant; admin UI refresh behavior after successful publish; active-banner reads that return only the current active banner.
- Postconditions: Sequential publishes never leave two active banners for one workspace, and the last successful publish is what users see.
- Risks / assumptions: The blueprint's "most recent publish wins" is treated as sequential successful publishes. Truly simultaneous publish collisions are handled by S11 according to the design.

### Research questions
- RQ1: What transaction API should be used to archive the previous active banner and create the new one atomically?
- RQ2: How should a partial unique index or equivalent invariant be represented in migrations?
- RQ3: How should the admin UI handle a publish response that replaced a previous banner?
- RQ4: Are there existing conflict or stale-data messaging patterns for admin settings?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S11 — Concurrent publish attempts preserve the one-active-banner invariant
- Order: 11
- Type: corner_case
- Status: planned
- Design references: System design D2, §7 concurrent publish handling, §12 C3

### Gherkin
Given two workspace admins publish banners for the same workspace at nearly the same time
When the publish operations race
Then the system preserves exactly one active banner and returns a clear conflict response to any admin whose publish did not become active

### Code-blind plan
- Preconditions: S10 has transactional replacement and a database invariant.
- Required capabilities: Error handling for one-active-banner constraint conflicts; an admin-facing conflict message; no retry loop that could accidentally create surprising state; tests or checks that simulate concurrent publish behavior.
- Postconditions: A race cannot create multiple active banners, and losing admins are told to reload before continuing.
- Risks / assumptions: The design accepts a conflict response for simultaneous races rather than guaranteeing that the request that arrived last always wins.

### Research questions
- RQ1: How are database unique-constraint violations detected and mapped to HTTP conflict responses?
- RQ2: What test infrastructure can exercise two concurrent publish requests against the same workspace?
- RQ3: What admin UI pattern should display a conflict and prompt reload?
- RQ4: Is there an idempotency-key pattern already used for low-frequency admin writes?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S12 — Only workspace admins can mutate banners
- Order: 12
- Type: adversarial
- Status: planned
- Design references: Blueprint adversarial scenarios; System design §8 Authorization

### Gherkin
Given a user is not a workspace admin
When they try to open the admin announcement controls or craft create, edit, or remove requests
Then the system rejects the action before business logic runs and no banner state changes

### Code-blind plan
- Preconditions: S2, S5, and S6 define the mutation routes and admin UI.
- Required capabilities: Admin-role middleware on all create, edit, and remove routes; frontend navigation that hides admin-only controls from non-admin users; authorization tests for UI routing and direct backend requests; no workspace or user authority accepted from client payloads.
- Postconditions: Non-admin users cannot create, edit, replace, or remove banners by UI or crafted request.
- Risks / assumptions: The design assumes an existing workspace-admin role or equivalent permission abstraction.

### Research questions
- RQ1: What authorization middleware or permission helper checks workspace-admin access?
- RQ2: How should frontend admin settings routes hide or block pages for non-admin users?
- RQ3: What backend tests should verify create, edit, and remove reject non-admin sessions?
- RQ4: Where should authorization happen in the route chain so validation or business logic cannot run first?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S13 — Banner reads and dismissals are authenticated and workspace-scoped
- Order: 13
- Type: adversarial
- Status: planned
- Design references: System design D4, §8 Authorization, §8 Least privilege

### Gherkin
Given a user is unauthenticated or belongs to a different workspace
When they request the active banner or attempt to dismiss a banner
Then unauthenticated requests are rejected, cross-workspace banner data is not exposed, and dismissals are recorded only for the authenticated user in their workspace

### Code-blind plan
- Preconditions: S2 has active reads; S3 has dismissals; S8 has workspace membership behavior.
- Required capabilities: Authentication middleware on read and dismiss routes; workspace scoping for active-banner lookup; dismissal write that verifies the announcement belongs to the user's workspace; response payload that includes only display fields needed by non-admin users.
- Postconditions: Banner visibility and dismissal state cannot cross workspace boundaries, and a user cannot dismiss on behalf of another user.
- Risks / assumptions: Multi-workspace users may require a current-workspace context; research must confirm how that context is represented.

### Research questions
- RQ1: What authentication middleware should protect app-level read and dismiss endpoints?
- RQ2: How is current workspace context represented for users who may belong to multiple workspaces?
- RQ3: How should the dismiss handler verify the announcement belongs to the authenticated user's workspace?
- RQ4: What response serialization pattern prevents leaking admin-only fields to normal users?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.

## Scenario S14 — Non-critical failures degrade gracefully and remain observable
- Order: 14
- Type: corner_case
- Status: planned
- Design references: System design §7 Reliability & Failure Handling, §9 Observability, §10 Rollout & Operability

### Gherkin
Given the banner system is enabled
When polling, dismissal, or admin write operations fail because of transient backend or database errors
Then user-facing behavior matches the operation criticality, the app remains usable, and logs or metrics capture the failure

### Code-blind plan
- Preconditions: S2 through S13 define the route surface and core behavior.
- Required capabilities: Poll failures that render no banner without a user-facing error; dismiss failures that keep the banner visible and show a transient retryable error; admin write failures that show clear errors without changing state; structured logs for publish, edit, remove, and backend failures; metrics for poll, dismiss, and publish results; alertable error rates.
- Postconditions: Announcement failures do not break the main app, admins get actionable write errors, and operators can detect failures or conflict spikes.
- Risks / assumptions: The poll endpoint is non-critical display behavior, so hiding the banner on poll failure is acceptable. Metrics labels must avoid high-cardinality or sensitive data beyond accepted workspace-level labels.

### Research questions
- RQ1: What logging helper and event naming conventions should structured announcement logs use?
- RQ2: What metrics library and label conventions are used for backend counters and gauges?
- RQ3: What frontend error and retry patterns should be used for polling and dismissal?
- RQ4: How should admin write errors be surfaced in settings forms?
- RQ5: Where are alert definitions or operational dashboards maintained, if in scope for implementation?

### Research findings
- To be completed by kite-research.

### Implementation record
- To be completed by kite-implementation.
