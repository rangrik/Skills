# Admin Announcement Banner Implementation Plan

## Scope And Constraints

This plan implements the admin announcement banner described in the approved behavior blueprint and draft system design. It is intentionally code-blind: it assumes the existing Kite codebase already has authentication, workspace scoping, admin settings, routing, database migrations, feature flags, and frontend data-fetching conventions, but it does not rely on any specific source file names.

The feature adds:

- A workspace-scoped announcement record with one active banner per workspace.
- Server-side per-user dismissals that persist across devices and sessions.
- Admin-only create, edit, and remove actions.
- A user-facing app-shell banner that polls for active announcements.
- Optional scheduling with start and end timestamps.
- Optional HTTPS link rendering.
- Feature-flagged rollout and basic observability.

The implementation should not introduce a new service, worker, WebSocket, or external provider. All behavior should fit the existing Node/Express, Postgres, and React patterns.

## Cross-Cutting Decisions To Preserve

- Store dismissals in Postgres, keyed by announcement and user. Do not use local storage, cookies, or session-only state for the authoritative dismissal fact.
- Enforce one active announcement per workspace at the database layer with a workspace-scoped uniqueness constraint for active rows.
- Resolve workspace and user identity from the authenticated session. Do not accept workspace ID or user ID from client bodies for banner reads or dismissals.
- Gate admin writes with existing workspace-admin authorization.
- Treat banner text as plain text. Do not render markdown or HTML.
- Validate optional links server-side as HTTPS URLs only.
- Use query-time start/end filtering based on server/database time. Do not add a scheduler just to expire banners.
- Short-poll the active-banner endpoint from the app shell, defaulting to roughly 30 seconds.
- Put all visible and writable behavior behind `announcement_banner_enabled`, failing closed if flag resolution fails.

## Scenario Order

Build in the order below. Each scenario should leave the product in a coherent, testable state and should be verified before moving to the next scenario.

## Scenario 1: Feature Flag Off Leaves Existing App Unchanged

**Behavior**

Given `announcement_banner_enabled` is disabled, users do not see an announcement banner, admins do not see an Announcements settings entry, and announcement endpoints do not expose usable behavior.

**Why first**

This gives the feature an operational escape hatch before any visible UI or write route is introduced. It also lets migrations and backend code ship safely ahead of rollout.

**Implementation tasks**

- Add the feature flag using the existing flag mechanism or the smallest existing-compatible substitute.
- Add flag checks around the admin settings entry, the app-shell banner mount point, and all announcement routes.
- Ensure disabled backend routes fail closed with the codebase's standard hidden-feature response, preferably 404.
- Add a no-op frontend state where the app shell layout is unchanged while the flag is off.

**Verification**

- With the flag disabled, a normal user sees no layout change.
- With the flag disabled, an admin sees no Announcements settings page or navigation item.
- With the flag disabled, announcement read, dismiss, publish, edit, and remove routes are unavailable.
- Existing auth, workspace, and settings tests still pass.

## Scenario 2: Data Model Supports One Workspace Banner And Server-Side Dismissals

**Behavior**

The database can persist workspace announcements and per-user dismissals while preventing duplicate active announcements for the same workspace.

**Why now**

The remaining scenarios depend on durable storage and the one-active-banner invariant. Getting the schema right early avoids building application behavior on weak data guarantees.

**Implementation tasks**

- Add a `workspace_announcements` migration with fields for workspace, message, optional link URL, start time, optional end time, status, creator, and timestamps.
- Add a database-level message length constraint matching the 1 to 200 character product rule.
- Add a database-level end-after-start constraint if supported by local migration conventions.
- Add a partial unique constraint or equivalent database constraint so each workspace can have at most one active announcement row.
- Add lookup indexes for active announcement reads by workspace and active time window.
- Add an `announcement_dismissals` migration keyed by announcement and user with dismissal timestamp.
- Use foreign keys and cascade behavior consistent with existing workspace and user table conventions.
- Add model, repository, or data-access helpers only where the codebase normally places database access.

**Verification**

- Migrations apply cleanly to an empty database.
- Migrations roll back cleanly if rollback support is expected.
- The database rejects two active announcements for one workspace.
- The database allows active announcements in different workspaces.
- Duplicate dismissal rows for the same user and announcement are prevented.

## Scenario 3: Authenticated Users See No Banner When None Is Active

**Behavior**

Given no currently active announcement exists for a workspace, an authenticated user in that workspace sees no banner and the active-banner endpoint returns an empty result.

**Why now**

This builds the read path and app-shell integration before admin writes create visible state. It establishes the normal no-banner case as a first-class path.

**Implementation tasks**

- Add the authenticated active-announcement read endpoint.
- Scope the read to the caller's workspace from session context.
- Filter by active status, `starts_at` at or before server time, and no `ends_at` or `ends_at` after server time.
- Join or check dismissal state for the caller, even though this scenario has no dismissal yet.
- Return only display-safe fields needed by the frontend.
- Add the app-shell `AnnouncementBanner` component behind the flag.
- Render nothing when the endpoint returns no banner, when the feature flag is off, or when polling fails.
- Add short-polling with a configurable interval and error backoff using existing frontend data-fetching conventions.

**Verification**

- Authenticated user in a workspace with no active announcement receives no banner.
- Unauthenticated request receives the existing standard unauthorized response.
- A user never sees announcements from another workspace.
- Poll failure does not show a user-facing error or disrupt the app shell.
- The app shell does not shift or reserve dead space when no banner is shown.

## Scenario 4: Admin Publishes An Immediate Plain-Text Banner

**Behavior**

Given a workspace admin enters a valid message and clicks Publish with no start or end date, the banner becomes active immediately and authenticated users in that workspace see it within the polling interval.

**Why now**

This is the core happy path. It connects admin UI, admin authorization, write transaction, active read, and app-shell rendering.

**Implementation tasks**

- Add the Announcements page or panel in existing admin settings behind the feature flag.
- Add a publish form with message input, optional start, optional end, optional link URL, and Publish action.
- Enforce non-empty plain text up to 200 characters in the UI for responsiveness.
- Add server-side publish validation for message length, plain-text treatment, timestamp format, and optional link URL.
- Resolve workspace and admin user from the session.
- Implement publish as a transaction that archives the previous active announcement for the workspace and inserts the new active announcement.
- Return a clear success response with the published announcement identity and display fields.
- Ensure the active read endpoint returns the new announcement to users who have not dismissed it.
- Render the banner as a single-line text announcement in the app shell with a dismiss button.

**Verification**

- Admin can publish a valid immediate banner.
- Users in the same workspace see the banner within the polling interval.
- Users in other workspaces do not see it.
- Message text is rendered as text, not HTML.
- Empty messages and messages longer than 200 characters are rejected by the server.
- The admin gets a clear validation message for invalid input.

## Scenario 5: Non-Admins Cannot Publish, Edit, Or Remove Banners

**Behavior**

Given a non-admin crafts requests to announcement admin routes, every write attempt is rejected before business logic mutates data.

**Why now**

The core publish path exists, so the adversarial access-control behavior must be locked down before adding more write routes.

**Implementation tasks**

- Apply the existing workspace-admin middleware to all admin announcement routes.
- Ensure publish, edit, and remove route handlers never trust role, workspace ID, or user ID from the request body.
- Add negative tests for non-admin authenticated users.
- Add negative tests for unauthenticated callers.
- Confirm the read endpoint remains available to any authenticated workspace user.

**Verification**

- Non-admin publish request returns forbidden and creates no announcement.
- Non-admin edit request returns forbidden and changes no announcement.
- Non-admin remove request returns forbidden and changes no announcement.
- Unauthenticated admin requests return unauthorized using existing conventions.
- A non-admin can still read the active banner and dismiss it.

## Scenario 6: User Dismisses A Banner Across Devices And Sessions

**Behavior**

Given a user sees an active banner, when they dismiss it, that same banner does not appear again for that user on any device or session.

**Why now**

Dismissal persistence is the main reason this feature needs server-side user state. It should be verified before edit and replacement behavior depend on dismissal semantics.

**Implementation tasks**

- Add the authenticated dismiss endpoint for an announcement ID.
- Record dismissal for the current authenticated user only.
- Make dismissal idempotent so double-clicks, retries, and repeated requests are harmless.
- Confirm the announcement belongs to the caller's workspace before recording dismissal.
- Update the active read endpoint so dismissed banners are returned with enough state for the client to suppress them, or are omitted according to the chosen API contract.
- Wire the app-shell dismiss button to the endpoint.
- Apply optimistic hiding only if failed dismissal restores or keeps the banner in a clear, retryable state.
- Add transient error handling for dismiss failures.

**Verification**

- User dismisses a banner and no longer sees it after refresh.
- The same user remains dismissed in a second browser/device simulation.
- A different user in the workspace still sees the banner.
- Repeated dismiss requests do not create duplicate records or errors.
- A user cannot dismiss an announcement from another workspace.
- If dismiss fails, the user receives a lightweight retryable error and the server state remains accurate.

## Scenario 7: Scheduling Controls Start And End Visibility

**Behavior**

An admin can schedule a future start time and optional end time. A future banner is hidden before its start time, visible during its active window, and hidden after its end time.

**Why now**

Scheduling builds on the core publish and read paths. It should be added before replacement and edit flows so all write operations preserve the same validation rules.

**Implementation tasks**

- Complete start and end date/time controls in the admin publish form.
- Normalize submitted timestamps according to existing app conventions.
- Validate timestamps server-side as ISO-compatible values.
- Reject an end time that is before or equal to the start time with a clear validation message.
- Default missing start time to immediate activation.
- Preserve missing end time as no expiry.
- Ensure active read filtering is based on server/database time, not browser time.
- Ensure the admin UI communicates current scheduled state without relying on client clock correctness where possible.

**Verification**

- Banner with a future start does not appear before the start time.
- Banner appears once server time reaches the start time.
- Banner with an end time disappears after the end time.
- Banner with no end time remains active until replaced or removed.
- End-before-start publish is rejected with no data mutation.
- Scheduling behavior works consistently after page refresh and across sessions.

## Scenario 8: Publishing A New Banner Replaces The Previous Active Banner

**Behavior**

Given one active banner exists, when an admin publishes another valid banner, the new banner becomes the active banner for the workspace and the previous active banner is no longer shown.

**Why now**

The blueprint requires at most one active banner and says publishing a new one replaces the previous active banner. This scenario validates the full replacement invariant under normal conditions.

**Implementation tasks**

- Ensure publish uses one transaction for archiving the previous active row and creating the new active row.
- Preserve old announcement and dismissal records for audit unless existing retention policy says otherwise.
- Ensure dismissals are tied to announcement ID, so dismissing the old banner does not dismiss the new banner.
- Refresh admin page state after publish so admins see the current active banner.
- Ensure the app-shell poll naturally picks up the new banner.

**Verification**

- Publishing a second banner archives or deactivates the first.
- Users see the second banner and not the first.
- A user who dismissed the first banner still sees the second banner.
- No workspace can have two active banners after replacement.
- Other workspaces are unaffected.

## Scenario 9: Concurrent Admin Publishes Resolve Safely

**Behavior**

Given two admins publish at nearly the same time, the database never stores two active banners for the workspace. One publish succeeds and the conflicting publish receives a clear reload-and-review response.

**Why now**

The normal replacement path is in place, so race behavior can be hardened without disrupting earlier flows. This protects the most important consistency invariant.

**Implementation tasks**

- Catch the database uniqueness violation or equivalent conflict from the one-active constraint.
- Return a conflict response using the codebase's standard API error shape.
- Show the losing admin a clear message that another banner was just published and they should reload.
- Ensure the admin UI reloads or offers a reload action after conflict.
- Add a concurrency test that exercises simultaneous publish attempts.

**Verification**

- Simultaneous publishes do not create duplicate active announcements.
- Exactly one active announcement remains after the race.
- Losing admin sees a conflict message rather than a generic failure.
- Users see only the winning active banner.
- Metrics or logs classify this as a publish conflict, not an unexpected server error.

## Scenario 10: Admin Edits Active Banner Text Without Resetting Dismissals

**Behavior**

Given a user dismissed a banner, when an admin edits that banner's text, the dismissed user still does not see it. Users who have not dismissed it see the edited text.

**Why now**

This scenario depends on dismissal being attached to the announcement identity rather than the message text. It verifies a subtle blueprint rule that is easy to regress.

**Implementation tasks**

- Add an admin edit route for the active announcement.
- Limit edits to fields supported by the blueprint and design, such as message and optional link URL, unless the existing admin UX intentionally supports date edits.
- Reuse publish validation for message and link fields.
- Keep the announcement ID stable during edit.
- Do not delete or rewrite dismissal records on edit.
- Add edit controls to the admin page for the current active banner.
- Update active read responses so undismissed users see edits after the next poll.

**Verification**

- Admin edits active banner text successfully.
- Undismissed users see the edited text after refresh or poll.
- A user who already dismissed the banner still does not see it after the edit.
- Invalid edited text or link URL is rejected.
- Non-admin edit remains forbidden.
- Concurrent last-writer-wins edit behavior is acceptable and covered by tests or documented as current behavior.

## Scenario 11: Admin Removes A Banner Early

**Behavior**

Given an active banner exists, when an admin clicks Remove, the banner stops showing for everyone before its scheduled end time.

**Why now**

Remove is the final core admin operation and uses the same auth, workspace scoping, status, and active-read paths already built.

**Implementation tasks**

- Add an admin remove route for the active announcement.
- Mark the announcement removed and set its end timestamp to server time, or follow the equivalent data model state from the design.
- Keep historical row and dismissal records unless retention policy says otherwise.
- Add a Remove action in the admin UI with an appropriate confirmation if existing settings patterns require it.
- Refresh admin page state after removal.
- Ensure app-shell polling hides the removed banner.

**Verification**

- Admin removes an active banner.
- Users stop seeing it after the next poll or refresh.
- Removing an already inactive or removed banner is handled idempotently or with the codebase's standard not-found/stale-state response.
- Non-admin remove remains forbidden.
- No other workspace's banner is affected.

## Scenario 12: Optional Link Is Validated And Rendered Safely

**Behavior**

Given an admin includes an optional HTTPS link, users see a safe link with the banner. Invalid or unsafe links are rejected.

**Why now**

The optional link is part of the blueprint but is best validated after the core lifecycle works. Separating it makes XSS and URL-scheme checks explicit.

**Implementation tasks**

- Add link URL input and validation to publish and edit flows if not already completed in earlier UI work.
- Accept only well-formed HTTPS URLs unless product explicitly approves additional schemes.
- Render the link as a normal anchor using existing design-system styling.
- Use the URL itself or an existing fixed label such as "Learn more" unless product specifies a separate label field.
- Ensure link rendering does not use HTML injection.
- Add accessible name and keyboard behavior consistent with other links in the app.

**Verification**

- Valid HTTPS link appears with the banner and opens normally.
- Empty link is accepted and renders no link.
- `javascript:`, `data:`, malformed, and non-HTTPS URLs are rejected server-side.
- Link URL is not logged as banner content if logging policies consider it sensitive.
- Banner remains readable and single-line or gracefully truncates according to design-system standards.

## Scenario 13: Users Who Join Later See Still-Active Banners

**Behavior**

Given a user joins a workspace after a banner was published, they see the banner if it is still active and they have not dismissed it.

**Why now**

This validates that visibility is computed from current workspace membership and announcement state, not from a precomputed audience snapshot.

**Implementation tasks**

- Ensure active read uses the caller's current workspace membership.
- Avoid fan-out records or per-user prepopulation when banners are published.
- Confirm no dismissal record is created until the user explicitly dismisses.
- Add a test or fixture that creates a user after announcement publication.

**Verification**

- Newly added user sees a still-active banner.
- Newly added user does not see an expired, removed, or future banner.
- Newly added user can dismiss the banner and dismissal persists normally.

## Scenario 14: Admin And User Failure States Are Graceful

**Behavior**

Database or network failures produce clear admin errors, retryable dismiss behavior, and silent user-facing degradation for the non-critical poll widget.

**Why now**

The main behavior is complete, so failure handling can be tested across all endpoints and frontend states without reworking contracts.

**Implementation tasks**

- Return clear validation, unauthorized, forbidden, conflict, not-found, and unavailable responses using existing API error conventions.
- Make poll errors render no banner and back off before retrying.
- Make dismiss failures retry once if that matches app conventions, then show a small retryable message.
- Make admin publish, edit, and remove failures visible and actionable.
- Add structured logs for publish, edit, remove, and endpoint failures without logging banner text.
- Add counters for poll hit, miss, error; dismiss success and error; publish success, conflict, and error.
- Add or update alerts if the codebase has alert definitions colocated with service metrics.

**Verification**

- Poll database failure does not break page rendering.
- Dismiss database failure does not falsely persist dismissal.
- Admin write database failure leaves prior state unchanged and shows an error.
- Logs include workspace, announcement, and admin identifiers where appropriate, but not banner text.
- Metrics distinguish expected conflict from unexpected error.

## Scenario 15: Rollout, Accessibility, And Regression Readiness

**Behavior**

The feature can be deployed safely, enabled for a test workspace, verified end to end, and rolled back by disabling the feature flag.

**Why last**

This scenario ties together deployment, frontend polish, accessibility, and regression checks once all functional behavior exists.

**Implementation tasks**

- Confirm deploy order: migrations first, backend behind disabled flag, frontend behind disabled flag, then enable for a test workspace.
- Add end-to-end coverage for publish, view, dismiss, edit, remove, and schedule where the existing test stack supports it.
- Add route-level or service-level tests for validation, authorization, workspace isolation, and concurrent publish conflict.
- Add frontend tests for banner rendering, no-banner state, dismiss action, and admin form validation.
- Verify keyboard dismissal with a real button and accessible label.
- Ensure the banner does not obscure navigation, app chrome, or page content on desktop and mobile breakpoints.
- Ensure the banner works with reduced-motion preferences if any transition is added.
- Document rollback: disable `announcement_banner_enabled`; data remains in place.

**Verification**

- Full automated test suite relevant to backend, frontend, and migrations passes.
- Manual test workspace validates immediate publish, scheduled publish, dismiss across sessions, edit without resetting dismissals, replacement, and removal.
- Feature flag off hides UI and disables routes after data already exists.
- The admin settings page and app-shell banner meet existing design-system and accessibility standards.
- Rollout metrics show poll errors, dismiss errors, and publish conflicts at acceptable levels during test rollout.

## Handoff Checklist For The Implementer

- Identify the existing migration framework and primary-key conventions before writing migrations.
- Identify the existing admin-role middleware and session workspace accessor before writing routes.
- Identify the existing feature-flag mechanism before adding flag checks.
- Identify existing API error shapes for validation, unauthorized, forbidden, conflict, and unavailable responses.
- Identify existing frontend data-fetching and polling conventions before building the app-shell banner.
- Identify existing admin settings navigation and form patterns before adding the Announcements page.
- Identify existing telemetry, logging, and alert conventions before adding observability.
- Keep each scenario independently reviewable and avoid bundling unrelated refactors into the feature work.
