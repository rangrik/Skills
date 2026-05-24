# Implementation Plan: Admin Announcement Banner

## Purpose

Build a workspace-scoped admin announcement banner for Kite. A workspace admin can publish one short plain-text announcement, optionally with a link and start/end dates. Users in that workspace see the banner at the top of the app while it is active, can dismiss it, and the dismissal persists across devices and sessions. Only one active banner may exist per workspace.

This plan is code-blind: it is based only on the behavior blueprint and system design. Implementation should first map the named responsibilities below onto Kite's existing auth, workspace, admin-settings, routing, migration, feature-flag, frontend data-fetching, and notification/layout patterns.

## Product Invariants

- Announcement messages are plain text, non-empty, and at most 200 characters.
- An announcement may include one optional safe external link.
- At most one active announcement exists per workspace.
- Publishing a new announcement replaces the previous active announcement.
- If no start time is provided, the announcement is active immediately.
- If no end time is provided, the announcement remains active until removed.
- If an end time is before the start time, publish is rejected.
- Dismissal is stored per user and per announcement, server-side.
- Editing an announcement does not reset previous dismissals.
- Non-admins cannot create, edit, or remove announcements, including through crafted requests.
- Visibility is determined server-side using the authenticated user's workspace and the database server's current time.

## Handoff Research Checklist

Before coding each affected area, confirm the existing Kite conventions for:

- Database migration framework, table naming, timestamp helpers, UUID generation, enum/check-constraint style, and rollback conventions.
- How workspace and user identity are exposed on authenticated backend requests.
- Existing admin-role authorization middleware and how admin settings routes are organized.
- Existing feature-flag mechanism and expected fail-closed behavior.
- Backend validation and error-response conventions.
- Frontend API client, query/polling abstraction, toast/error pattern, and test utilities.
- App shell/layout insertion point for persistent top-of-app UI.
- Existing admin settings navigation and form component patterns.
- Observability conventions for structured logs, metrics, and alert labels.

## Scenario Order

The order below builds durable foundations first, then backend behavior, then user-facing surfaces, and finally operational rollout. Each scenario should be independently verifiable before moving to the next.

## Scenario 1: Add Persistent Announcement Storage

**User value:** The system has an authoritative place to store announcements and dismissals, allowing the rest of the feature to satisfy cross-device behavior.

**Implementation scope:**

- Add a `workspace_announcements` persistence model/table scoped to workspace.
- Store message, optional link URL, start time, optional end time, status, creator, and standard timestamps.
- Enforce message length at the data layer where possible.
- Enforce the one-active-announcement-per-workspace invariant with a database-level uniqueness constraint.
- Add indexes that support active-announcement lookup by workspace and time window.
- Add an `announcement_dismissals` persistence model/table keyed by announcement and user.
- Ensure duplicate dismissals are impossible or harmless through the persistence model.
- Add rollback migrations for the new tables and indexes.

**Acceptance checks:**

- A workspace cannot have two records marked active at the same time.
- Dismissal records are unique per announcement/user pair.
- Deleting an announcement, if supported by the retention model, does not leave orphaned dismissals.
- Migrations apply and roll back cleanly in a local/test database.

**Tests:**

- Migration test or schema assertion for table shape, indexes, constraints, and rollback.
- Model/repository tests for creating announcements and dismissals.
- Concurrency-oriented test proving the database rejects two active announcements for the same workspace.

## Scenario 2: Gate the Feature Behind a Fail-Closed Flag

**User value:** The feature can be deployed safely without immediately exposing unfinished or unverified UI/API behavior.

**Implementation scope:**

- Add an `announcement_banner_enabled` feature flag using the existing Kite flag mechanism.
- Default the flag to disabled.
- Backend announcement routes should not allow accidental reads or writes while the flag is disabled.
- Frontend admin navigation and app-shell banner mounting should be hidden while the flag is disabled.
- If flag resolution fails, treat the feature as disabled.

**Acceptance checks:**

- With the flag off, no admin announcement UI is visible.
- With the flag off, user-facing banner UI does not mount.
- With the flag off, backend routes do not expose or mutate announcement state.
- With the flag on, the feature surfaces become available to authorized users.

**Tests:**

- Backend route tests for disabled-flag responses.
- Frontend render tests for hidden nav/banner when disabled.
- Flag-failure test confirming fail-closed behavior.

## Scenario 3: Publish an Announcement as a Workspace Admin

**User value:** A workspace admin can create the announcement that users will later see.

**Implementation scope:**

- Add an admin-only publish endpoint in the existing admin settings route area.
- Derive workspace ID and admin user ID from the authenticated session, never from the request body.
- Validate message as plain text, non-empty, and no longer than 200 characters.
- Validate optional link URL using the product's accepted policy. The system design recommends allowing only well-formed HTTPS URLs.
- Validate start/end timestamps as ISO timestamps or equivalent accepted client format.
- Reject an end time that is not after the start time.
- For omitted start time, store an immediate start.
- For omitted end time, store no expiry.
- Implement publish-replaces-old in a single transaction: retire the previous active announcement, then create the new active announcement.
- Handle concurrent publish conflicts using the database uniqueness constraint and return the product's standard conflict response.
- Emit structured logs and metrics for successful publish, validation failure, conflict, and system error.

**Acceptance checks:**

- Admin can publish a valid immediate announcement.
- Admin can publish a future-scheduled announcement.
- Admin can publish an announcement with no end time.
- Invalid message, invalid link, invalid date, or end-before-start is rejected with field-level feedback.
- Publishing a new announcement replaces the previous active announcement.
- Two simultaneous publish attempts cannot leave two active announcements.
- Non-admin requests are rejected before business logic runs.

**Tests:**

- Backend route tests for valid publish variants.
- Backend validation tests for each rejected input.
- Authorization tests for unauthenticated, non-admin, and cross-workspace attempts.
- Transaction/conflict test for concurrent admin publish.
- Observability test or assertion following Kite's logging/metrics test conventions.

## Scenario 4: Return the Active Announcement for the Current User

**User value:** Each user can receive the correct banner state for their workspace without the frontend reconstructing business rules.

**Implementation scope:**

- Add an authenticated user-facing endpoint for the current active announcement.
- Resolve workspace and user from the authenticated request.
- Query only the caller's workspace.
- Apply server-side active-window filtering using database/server time.
- Include dismissal state for the caller in the same backend operation.
- Return no banner when there is no active announcement, the start time is in the future, the end time has passed, the announcement was removed, or the user has dismissed it.
- Return only display-safe fields needed by the frontend: announcement ID, message, link URL if present, and timing metadata if needed for client state.
- Treat poll failures as non-critical for the user-facing UI, while still logging and counting errors server-side.

**Acceptance checks:**

- A user sees an active announcement in their workspace.
- A user does not see announcements from another workspace.
- A future announcement is hidden until its start time.
- An expired or removed announcement is hidden.
- A dismissed announcement is hidden for that user only.
- A user who joins after publish sees the still-active announcement if they have not dismissed it.

**Tests:**

- Backend route tests for hit, miss, future, expired, removed, dismissed, and cross-workspace cases.
- Time-boundary tests using controllable server/database time where available.
- Security tests proving request-supplied workspace/user identifiers are ignored.
- Response-shape test confirming internal fields are not leaked.

## Scenario 5: Dismiss an Announcement Per User

**User value:** A user can close the banner once and not see the same announcement again across devices or sessions.

**Implementation scope:**

- Add an authenticated dismiss endpoint for a specific announcement.
- Record dismissal for the authenticated user only.
- Validate that the announcement belongs to the user's workspace.
- Make dismissal idempotent so double-clicks, retries, or repeated requests do not create duplicates or errors.
- Return success when the dismissal already exists.
- Log and count dismissal success and failure without logging announcement text.

**Acceptance checks:**

- A user can dismiss a visible announcement.
- After dismissal, the active-announcement endpoint no longer returns that announcement for that user.
- Dismissal survives a new session or another device because it is server-side.
- Dismissal by one user does not hide the announcement for another user.
- Repeated dismiss requests are harmless.
- Users cannot dismiss or probe announcements outside their workspace.

**Tests:**

- Backend route tests for first dismiss and repeated dismiss.
- Cross-workspace authorization test.
- Integration test covering active fetch, dismiss, then active fetch again.
- Retry/double-submit test confirming idempotency.

## Scenario 6: Edit the Active Announcement Without Resetting Dismissals

**User value:** An admin can correct or update announcement text while respecting users who already dismissed that announcement.

**Implementation scope:**

- Add an admin-only edit endpoint for the active announcement.
- Allow editing supported mutable fields from the design, at minimum message and link URL. If schedule edits are desired, validate them with the same date rules as publish.
- Keep the same announcement identity when editing.
- Do not delete or reset dismissal records.
- Enforce workspace scoping and admin authorization.
- Handle last-writer-wins admin edit behavior unless Kite already has an optimistic concurrency convention that should be reused.
- Emit structured edit logs and metrics.

**Acceptance checks:**

- Admin can edit the active announcement's message.
- Edited text appears for users who have not dismissed the announcement.
- Users who dismissed the announcement before the edit still do not see it.
- Non-admin edit requests are rejected.
- Cross-workspace edit requests cannot mutate another workspace's announcement.

**Tests:**

- Backend edit route tests for valid edits and invalid validation cases.
- Regression test for the blueprint deviation: dismiss, edit, then confirm the same user still does not see the banner.
- Authorization and workspace isolation tests.

## Scenario 7: Remove an Announcement Early

**User value:** An admin can stop showing an announcement before its scheduled end time.

**Implementation scope:**

- Add an admin-only remove endpoint.
- Mark the announcement removed according to the persistence model rather than relying on client-side hiding.
- Set the effective end time to the removal time if that is the chosen audit model.
- Ensure removed announcements are excluded from active-announcement lookup.
- Preserve historical data and dismissals unless retention policy says otherwise.
- Emit structured remove logs and metrics.

**Acceptance checks:**

- Admin can remove an active announcement.
- After removal, no users in the workspace receive the announcement.
- Removing an already removed or nonexistent active announcement returns the product's standard harmless or not-found response.
- Non-admin remove requests are rejected.

**Tests:**

- Backend remove route tests for active, already removed, and missing records.
- Active-fetch integration test before and after removal.
- Authorization and workspace isolation tests.

## Scenario 8: Build the Admin Announcements Settings UI

**User value:** Workspace admins have a clear, validated interface to publish, edit, and remove announcements.

**Implementation scope:**

- Add an Announcements entry/panel in admin settings following existing settings navigation patterns.
- Render the current active announcement state, including scheduled timing if applicable.
- Provide a form for message, optional link URL, optional start time, and optional end time.
- Enforce the 200-character limit in the UI with clear feedback.
- Validate end-after-start before submitting where possible, while still relying on backend validation as the source of truth.
- Submit publish, edit, and remove operations through the existing frontend API client pattern.
- Show loading, success, validation error, conflict, and system error states using existing UI conventions.
- On publish conflict, prompt the admin to reload or refetch the active announcement state.
- Hide or disable the UI for non-admins according to existing admin settings conventions, while relying on backend authorization for enforcement.

**Acceptance checks:**

- Admin can publish a valid announcement from the UI.
- Admin sees validation feedback for overlong text, missing text, invalid link, and invalid date order.
- Admin can edit the active announcement.
- Admin can remove the active announcement.
- Conflict and system errors are visible and actionable.
- Feature flag off hides the settings entry/panel.

**Tests:**

- Component tests for form validation and character limit.
- UI integration tests for publish, edit, remove, conflict, and backend validation errors.
- Permission/flag render tests.
- Accessibility checks for labels, error association, focus movement, and keyboard operation.

## Scenario 9: Render the User-Facing Banner in the App Shell

**User value:** Users see active workspace announcements consistently across the app and can dismiss them quickly.

**Implementation scope:**

- Add an `AnnouncementBanner` component at the established top-of-app layout insertion point.
- Fetch the active-announcement endpoint when the feature flag is enabled and the user is authenticated.
- Poll approximately every 30 seconds using Kite's existing polling/query abstraction if available.
- Back off polling after repeated fetch failures and resume the normal cadence after success.
- Render nothing for no-banner, dismissed, disabled-flag, unauthenticated, or failed-poll states.
- Render plain text safely, without HTML interpretation.
- Render the optional link using the validated URL and a clear link affordance.
- Provide an accessible dismiss button with an appropriate label.
- On dismiss, optimistically hide the banner only if that matches existing UX conventions; otherwise hide after success. If dismiss fails, show the product's transient error pattern and allow retry.
- Ensure layout remains stable and does not overlap app navigation or page content.

**Acceptance checks:**

- Active announcement appears at the top of the app for eligible users.
- No banner appears when there is no active announcement.
- Future, expired, removed, and dismissed announcements do not render.
- Dismiss hides the banner and persists through reload/new session.
- Optional link is usable and safe.
- Polling picks up a newly published announcement within the accepted short delay.
- The component is keyboard accessible and screen-reader friendly.

**Tests:**

- Component tests for render, no-render, link, and dismiss states.
- Integration test with mocked polling showing publish-to-visible flow.
- Accessibility test for dismiss button, focus behavior, and link semantics.
- Responsive layout checks for desktop and mobile app shell widths.

## Scenario 10: Handle Time Windows and Boundary Conditions End to End

**User value:** Scheduled announcements appear and disappear at the intended times without requiring background jobs.

**Implementation scope:**

- Use server/database time for active-window evaluation.
- Make the admin UI clear about the time zone used for scheduling.
- Confirm that start time equality is treated as active.
- Confirm that end time equality is treated as no longer active, matching the system design's exclusive end boundary.
- Avoid client-side clock decisions for banner visibility except for display formatting.

**Acceptance checks:**

- No-start announcement is immediately active.
- Future-start announcement is hidden before start and visible at/after start.
- No-end announcement remains active until removed or replaced.
- Ended announcement disappears after end time.
- End-before-start publish is rejected.

**Tests:**

- Backend time-window tests at before, exactly-at, between, exactly-end, and after boundaries.
- Admin UI date/time validation tests.
- End-to-end scheduled-banner test using controlled time if the test framework supports it.

## Scenario 11: Secure the Full API Surface

**User value:** Workspace boundaries and admin permissions are enforced even if clients are modified or requests are crafted manually.

**Implementation scope:**

- Ensure every route uses existing authentication middleware.
- Ensure write routes use existing workspace-admin authorization middleware.
- Ensure workspace ID is taken only from trusted request/session context.
- Ensure user ID for dismissal is taken only from trusted request/session context.
- Ensure route parameters are scoped to the caller's workspace before mutation or dismissal.
- Ensure the message is rendered as plain text and link schemes cannot create script execution.
- Confirm response bodies do not expose internal audit fields to normal users.

**Acceptance checks:**

- Non-admin cannot publish, edit, or remove.
- Unauthenticated users cannot read or dismiss.
- A user/admin from one workspace cannot affect another workspace's announcements or dismissals.
- Stored XSS through message is not possible through normal rendering.
- Unsafe link schemes are rejected on write.

**Tests:**

- Authorization matrix tests across unauthenticated, member, admin, and other-workspace admin.
- Input security tests for HTML-like message content and unsafe link schemes.
- Response privacy tests for user-facing read endpoint.

## Scenario 12: Add Observability and Operational Signals

**User value:** Operators can tell whether announcements are being published, shown, dismissed, and whether failures are preventing visibility.

**Implementation scope:**

- Add structured logs for publish, edit, remove, and backend errors.
- Avoid logging announcement message text.
- Add counters for poll requests by hit/miss/error, publish by success/conflict/error, and dismiss by success/error.
- Add an active-age gauge if Kite's metrics stack supports it.
- Add or document warning alerts for poll and dismiss error rates.
- Include workspace ID, announcement ID, and acting admin/user ID only where consistent with Kite privacy/logging conventions.

**Acceptance checks:**

- Successful publish/edit/remove emits expected non-sensitive logs.
- Poll, publish, and dismiss paths increment expected metrics.
- Error paths are observable without leaking banner content.
- Rollout dashboard or equivalent query can show poll error rate and dismiss error rate.

**Tests:**

- Unit or integration tests for metrics/log hooks if the codebase supports them.
- Manual verification checklist for dashboard/alert wiring if automated tests are not practical.

## Scenario 13: Roll Out Safely

**User value:** The feature reaches production with a clear rollback path and minimal risk.

**Implementation scope:**

- Deploy database migrations first.
- Deploy backend routes with the feature flag disabled.
- Deploy frontend UI with the feature flag disabled.
- Enable the flag for an internal/test workspace.
- Verify publish, visibility, dismiss, edit, remove, scheduling, and authorization end to end.
- Gradually enable for more workspaces while monitoring poll error rate, dismiss error rate, and publish conflicts.
- Use flag-off as the immediate rollback path.
- Keep database rollback reserved for schema incidents.

**Acceptance checks:**

- With the flag off in production, no user-visible changes appear.
- Internal workspace verification passes before broader rollout.
- Flag can be disabled to hide admin and user-facing surfaces without deleting data.
- Existing routes and tables outside this feature are unaffected.

**Tests and verification:**

- Migration verification in staging.
- Smoke test for admin publish to user display to dismissal.
- Negative smoke test for non-admin publish attempt.
- Rollback drill by disabling the flag and confirming UI/API behavior.

## Scenario 14: Follow-Up Hardening After Initial Release

**User value:** Known non-blocking risks are tracked without delaying the core feature.

**Implementation scope:**

- Consider admin publish idempotency keys if timeout/retry confusion appears in production.
- Add cleanup or archival for old announcements and dismissals if retention policy or table size requires it.
- Add a dismissal cleanup index only if implementing cleanup.
- Introduce short-lived shared caching for the active-announcement response only if poll load or DB latency justifies it.
- Clarify optional-link display text. If product wants custom link labels, add that as a separate behavior/schema change.
- Consider optimistic concurrency for admin edits if last-writer-wins becomes confusing.
- Confirm whether scheduling UI should display server time or workspace-local time.

**Acceptance checks:**

- Follow-up items are captured in the issue tracker with concrete triggers.
- None of the follow-ups are required for correctness of the blueprint's core behavior.

## Minimum End-to-End Test Matrix

Before marking the feature complete, run or add coverage for these flows:

| Flow | Expected result |
|---|---|
| Admin publishes immediate banner | Eligible users see it within the polling window |
| User dismisses banner | Same user does not see same announcement across reload/session |
| Another user has not dismissed | Other user still sees active announcement |
| Admin edits dismissed announcement | Dismissing user still does not see it |
| Admin publishes replacement | New announcement can appear even if prior announcement was dismissed |
| Admin schedules future start | Users do not see it before start; they see it after start |
| Admin sets end before start | Publish rejected with validation feedback |
| Admin removes active banner | Users stop seeing it |
| Non-admin crafts publish request | Request rejected and no data mutates |
| Cross-workspace read/dismiss/write attempt | Request cannot observe or mutate other workspace state |
| Feature flag disabled | UI hidden and backend routes do not expose feature behavior |

## Definition of Done

- New announcement and dismissal persistence is migrated, indexed, and tested.
- Backend publish, active read, dismiss, edit, and remove behavior is implemented with workspace scoping and authorization.
- Frontend admin settings UI supports publish, edit, remove, validation, and error handling.
- Frontend app shell banner supports polling, rendering, safe link display, dismissal, and accessible controls.
- Feature flag gates backend and frontend behavior and fails closed.
- Observability is in place for publish, poll, dismiss, edit, remove, and error paths.
- End-to-end verification covers happy path, scheduling, dismissal persistence, edit-with-dismissal, replacement, removal, authorization, and workspace isolation.
- Rollout and rollback steps are documented for the release owner.
