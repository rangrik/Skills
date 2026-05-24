# Implementation Plan: Admin Announcement Banner

## Purpose

Build the Kite admin announcement banner described by the approved behavior blueprint and draft system design. The feature lets a workspace admin publish one plain-text announcement banner, optionally with a link and start/end schedule. All authenticated users in the workspace can see the banner, dismiss it per user, and keep that dismissal across devices and sessions.

This plan is written for research first, then implementation. It is code-blind and names the intended behavior, architecture, sequencing, research questions, and acceptance checks without assuming exact files or existing local abstractions.

## Source Behavior

The implementation must satisfy these product rules:

- Workspace admins can create, edit, and remove a workspace announcement banner.
- Non-admin users cannot create, edit, or remove banners, including by crafted requests.
- The banner is one line of plain text up to 200 characters, plus an optional link.
- At most one banner is active per workspace.
- Publishing a new banner replaces the previous active banner.
- If no start time is provided, the banner is active immediately.
- If no end time is provided, the banner remains active until removed.
- A future start time suppresses the banner until that time arrives.
- An end time before the start time is rejected with a validation message.
- Users see the banner across the top of the app within a short time after it becomes active.
- A user's dismissal is per announcement and persists across devices and sessions.
- Editing the active banner does not make it reappear for users who already dismissed that announcement.
- Users who join after publication see the banner if it is still active and they have not dismissed it.
- No banner active is a normal state and should render no banner.

## Target Architecture

Implement the feature as an additive CRUD/display flow in the existing backend, database, and React frontend.

Backend and persistence:

- Add a `workspace_announcements` persistence model with workspace ownership, message, optional link URL, optional active window, status, creator, and timestamps.
- Add an `announcement_dismissals` persistence model keyed by announcement and user.
- Enforce one active banner per workspace at the database layer, not only in application logic.
- Filter banner visibility server-side using authenticated workspace, active status, start time, end time, and per-user dismissal state.
- Keep publish, edit, remove, active fetch, and dismiss operations synchronous.

API surface:

- Admin create/replace announcement endpoint.
- Admin edit active announcement endpoint.
- Admin remove announcement endpoint.
- Authenticated active announcement fetch endpoint.
- Authenticated announcement dismiss endpoint.

Frontend:

- Add an admin settings Announcements page or panel for composing, publishing, editing, and removing the active banner.
- Add an app-shell announcement banner component above the main content area.
- Poll the active announcement endpoint on a short interval, defaulting to the system design's 30 seconds unless the existing app has a standard configurable polling pattern.
- Store no dismissal authority in browser-only storage. The frontend can optimistically hide after dismiss, but the server dismissal record is authoritative.

Rollout and operations:

- Gate the backend routes, admin navigation, and app-shell component behind `announcement_banner_enabled`.
- Default the flag off and fail closed if flag evaluation is unavailable.
- Deploy database migration first, then backend, then frontend, then enable for a test workspace.
- Add logs, metrics, and alert hooks for poll, publish, dismiss, edit, remove, conflicts, and errors using existing observability patterns.

## Research Handoff

Before implementation, research should answer these questions from the actual codebase:

1. Where do new platform database migrations live, and what naming, transaction, rollback, and constraint patterns are standard?
2. What existing repository/service/model layer should own announcement reads and writes?
3. How are workspace-scoped authenticated requests represented in backend handlers?
4. What middleware enforces workspace admin authorization?
5. What feature flag mechanism should back `announcement_banner_enabled`, and how do routes/components fail closed?
6. What route groups and response envelope conventions should the new admin and user endpoints follow?
7. What validation library or helper is used for request bodies, timestamps, URL fields, and string length?
8. What existing pattern handles unique-constraint conflicts and maps them to HTTP 409?
9. Where should app-shell banners mount so they appear across the app without covering navigation or content?
10. What data fetching/polling helper is standard in the React app, and how are backoff and cancellation handled?
11. What admin settings navigation pattern should expose the Announcements page?
12. What component, toast, form, date/time picker, button, icon, and empty-state conventions should the UI reuse?
13. What accessibility standards exist for dismissible global banners, keyboard focus, aria labels, and reduced motion?
14. What backend, frontend, and end-to-end test frameworks should cover the scenarios below?
15. How are structured logs, metrics, and alerts declared for new user-facing backend paths?

Research should produce concrete file/module targets for each scenario, identify reusable helpers, and call out any mismatch between the system design and existing platform conventions.

## Implementation Sequence

Implement in vertical scenario slices. Each scenario should leave the system in a coherent state and should include tests appropriate to the touched layer. Do not defer cross-device dismissal, authorization, or one-active-banner enforcement to late cleanup; those are core requirements.

## Scenario 1: Persistence Foundation and Feature Flag Off State

### Goal

Create the additive database and feature-flag foundation while keeping the feature invisible and inert by default.

### Research Inputs

- Migration framework and rollback conventions.
- Existing UUID, timestamp, enum/status, foreign-key, and partial-index patterns.
- Feature flag lookup semantics and fail-closed behavior.
- Existing route registration behavior when a feature is disabled.

### Implementation Scope

- Add migrations for announcement records and dismissal records.
- Add constraints for message length, optional expiry, and one active announcement per workspace.
- Add indexes needed for active-banner lookup and dismissal lookup.
- Add typed/domain model definitions or repository methods if the codebase uses them.
- Add the `announcement_banner_enabled` feature flag with default off behavior.
- Register backend route shells only if consistent with local routing patterns, returning the existing disabled-feature response while the flag is off.

### Acceptance Criteria

- With the flag off, no admin navigation entry appears and no banner component mounts.
- With the flag off, backend endpoints cannot create or expose announcement data.
- Migrations apply cleanly to an empty database and roll back cleanly.
- The database cannot represent two active announcements for the same workspace.
- The dismissal store cannot contain duplicate dismissal rows for the same user and announcement.

### Tests

- Migration test or schema assertion for both new tables and key constraints.
- Feature flag test showing backend routes fail closed.
- Feature flag test showing frontend surfaces remain hidden when disabled.

## Scenario 2: No Active Banner Is a Normal User State

### Goal

Add the authenticated user read path and app-shell banner component in the simplest visible state: no active banner.

### Research Inputs

- App-shell layout location for global UI above main content.
- Existing authenticated fetch hook and polling conventions.
- Existing loading, null, and error handling patterns for non-critical shell widgets.
- Existing endpoint response shape conventions.

### Implementation Scope

- Add the active announcement read endpoint for authenticated users.
- Resolve workspace from the session, never from a client-supplied workspace ID.
- Return an empty/null banner response when no currently visible, non-dismissed announcement exists.
- Add the app-shell banner component behind the feature flag.
- Start polling only when the user is authenticated and the flag is enabled.
- Render nothing for loading, empty, unauthenticated, disabled, or recoverable poll-error states.

### Acceptance Criteria

- Authenticated users in a workspace with no active banner see no banner and no error UI.
- Polling a no-banner workspace remains lightweight and does not spam errors.
- Unauthenticated requests receive the existing unauthorized response.
- The frontend does not shift layout repeatedly while polling returns no banner.

### Tests

- Backend test for authenticated no-banner response.
- Backend test for unauthenticated read rejection.
- Frontend test for hidden app-shell banner when response is empty.
- Frontend test that poll failures degrade silently for regular users while logging through existing mechanisms.

## Scenario 3: Admin Publishes an Immediate Banner

### Goal

Let a workspace admin publish a plain-text announcement that becomes visible to users in that workspace within the polling interval.

### Research Inputs

- Admin settings page registration and form patterns.
- Existing workspace admin authorization middleware.
- Existing request validation and form error display conventions.
- Existing frontend time-zone handling for date/time inputs.

### Implementation Scope

- Add the admin Announcements page or panel behind the feature flag.
- Add form fields for message, optional link URL, optional start time, and optional end time.
- Enforce plain text, non-empty message, and 200-character limit.
- Validate optional link as an allowed safe URL according to the system design.
- Use session workspace and admin user identity for creation.
- Publish in a transaction that archives any prior active banner and inserts the new active banner.
- Return the published announcement in the admin response using existing response conventions.
- Make the user active-banner endpoint return the announcement when the active window includes the current server time and no dismissal exists for the user.
- Render the banner as escaped text, with the optional link rendered safely.

### Acceptance Criteria

- An admin can publish a valid immediate banner.
- Users in the same workspace see the banner across the top of the app within the configured poll interval.
- Users in other workspaces do not see the banner.
- The banner message renders as text, not HTML.
- The optional link cannot execute script or use a disallowed scheme.
- The admin UI clearly shows the active banner after publish.

### Tests

- Backend publish success test for admin.
- Backend active-fetch hit test for a user in the same workspace.
- Backend workspace-isolation test.
- Frontend admin form publish test.
- Frontend app-shell render test for message and link.
- Security test for HTML/script-like message content and unsafe link input.

## Scenario 4: Validation and Authorization Rejections

### Goal

Prevent invalid or unauthorized writes before they can mutate announcement state.

### Research Inputs

- Standard validation error response format.
- Standard frontend display for field-level and form-level errors.
- Existing authorization test helpers for admin and non-admin users.

### Implementation Scope

- Reject missing, blank, or over-200-character messages.
- Reject invalid timestamps.
- Reject `ends_at` less than or equal to `starts_at`.
- Reject unsafe or malformed link URLs.
- Reject create, edit, and remove attempts from non-admin users.
- Ensure client-side validation mirrors server-side rules but does not replace them.

### Acceptance Criteria

- Invalid form submissions show actionable validation messages and do not create or alter a banner.
- Non-admin crafted requests receive forbidden responses and do not create, edit, or remove banners.
- Validation failures preserve the admin's draft input in the UI.
- Server-side validation remains authoritative even if the client is bypassed.

### Tests

- Backend validation tests for message, link, and dates.
- Backend authorization tests for non-admin create, edit, and remove.
- Frontend form validation tests for common invalid inputs.
- Regression test proving no database mutation after rejected writes.

## Scenario 5: User Dismisses a Banner Across Sessions and Devices

### Goal

Persist dismissal per user and announcement on the server so a dismissed banner does not return for that user on any device or later session.

### Research Inputs

- Existing mutation patterns for user actions.
- Existing toast/error handling for failed user mutations.
- Existing retry/backoff behavior for transient network failures.

### Implementation Scope

- Add the authenticated dismiss endpoint.
- Record dismissal for the authenticated user only.
- Make dismissal idempotent so repeated clicks, retries, and double submits are harmless.
- Make the active-banner endpoint suppress announcements dismissed by the current user.
- Optimistically hide the banner on successful dismissal, and reconcile with the next poll.
- On dismissal failure, keep or restore the banner and show the existing transient error treatment.

### Acceptance Criteria

- A user can dismiss a visible banner.
- After dismissal, the same user does not see that announcement again in the same session.
- After logging in on another device or session, the same user still does not see that announcement.
- Another user in the same workspace who has not dismissed the announcement still sees it.
- Repeated dismiss requests do not create duplicate state or fail noisily.

### Tests

- Backend dismiss success and idempotency tests.
- Backend active-fetch suppression test for dismissed user.
- Backend active-fetch visibility test for a different user.
- Frontend dismiss interaction test.
- End-to-end test or integration test covering dismissal persistence across a simulated new session.

## Scenario 6: Admin Edits the Active Banner Without Resetting Dismissals

### Goal

Allow admins to update the active banner while keeping dismissal tied to the announcement identity, not the message text.

### Research Inputs

- Existing update form patterns and optimistic/stale data handling.
- Existing conventions for concurrent form edits, reload prompts, or last-writer-wins updates.

### Implementation Scope

- Add admin edit behavior for the active announcement's editable fields.
- Preserve the announcement identity when editing.
- Keep existing dismissal rows intact.
- Refresh the admin UI after a successful edit.
- Make non-dismissed users receive updated content on the next poll.
- Keep dismissed users suppressed after the edit.

### Acceptance Criteria

- An admin can edit the active banner text and optional link.
- A user who already dismissed the announcement does not see it again after the edit.
- A user who has not dismissed it sees the updated text/link after polling.
- Editing does not create a second active announcement.
- Non-admin edit attempts are rejected.

### Tests

- Backend edit success test preserving announcement ID.
- Backend test that dismissed users remain suppressed after edit.
- Backend test that non-dismissed users see edited content.
- Frontend admin edit flow test.
- Regression test for one-active-banner invariant after edit.

## Scenario 7: Admin Removes a Banner Early

### Goal

Let admins end an active banner immediately so no users continue to see it.

### Research Inputs

- Existing destructive-action confirmation patterns.
- Existing soft-delete/status patterns.
- Existing admin audit/log conventions.

### Implementation Scope

- Add admin remove behavior for the active announcement.
- Mark the announcement removed and end its visible window using server time.
- Refresh the admin page to show no active banner.
- Make the active-banner endpoint return no banner after removal.
- Keep historical announcement and dismissal records according to the retention approach.

### Acceptance Criteria

- An admin can remove the active banner.
- All users stop seeing the banner by the next poll.
- Removing when no active banner exists is handled gracefully according to existing API conventions.
- Non-admin remove attempts are rejected.
- Removal does not delete unrelated announcement history.

### Tests

- Backend remove success test.
- Backend active-fetch miss test after removal.
- Frontend admin remove flow test.
- End-to-end test showing visible banner disappears after remove and poll/refresh.
- Authorization test for non-admin remove.

## Scenario 8: Scheduled Start and End Windows

### Goal

Respect start and end times using server-side visibility rules.

### Research Inputs

- Existing date/time picker and timezone display patterns.
- Test helpers for freezing or controlling server time.
- Existing conventions for server-time display or clock-skew messaging.

### Implementation Scope

- Let admins publish with no start time, a future start time, no end time, or a future end time.
- Normalize omitted start time to immediate server-side activation.
- Store omitted end time as no expiry.
- Filter visibility at query time using server time.
- Avoid client-side-only expiry authority.
- Present date/time fields in a way that matches app conventions and avoids timezone ambiguity.

### Acceptance Criteria

- A banner with no start time is visible immediately.
- A banner with a future start time is hidden before that time and visible after it arrives.
- A banner with no end time remains visible until removed.
- A banner with an end time is hidden after that time passes.
- A user who joins after publication sees a still-active, non-dismissed banner.
- A user who joins after expiry sees no banner.

### Tests

- Backend time-window tests for immediate, future-start, no-end, and expired cases.
- Backend test for new user visibility on still-active banner.
- Frontend display test for scheduled active state in admin UI.
- End-to-end or integration test using controlled time for start and expiry behavior.

## Scenario 9: Publishing a New Banner Replaces the Previous Active Banner

### Goal

Ensure only one active banner exists per workspace and that publishing a new one replaces the prior active banner.

### Research Inputs

- Existing transaction helper patterns.
- Existing conflict/error mapping for database uniqueness failures.
- Existing admin UI reload behavior after stale/conflicting writes.

### Implementation Scope

- Implement publish as a single transaction that archives the current active banner for the workspace and creates the new active banner.
- Ensure previous dismissal rows remain tied to the previous announcement and do not suppress the new announcement.
- Surface uniqueness conflicts in the existing conflict-response style.
- Refresh admin and user views after successful publish.

### Acceptance Criteria

- Publishing a second valid banner makes it the only visible active banner.
- Users who dismissed the previous banner still see the new banner, because dismissal is tied to announcement identity.
- The previous banner no longer appears to users.
- The database invariant prevents two active banners for one workspace even if application logic regresses.
- Replacing a banner in one workspace does not affect another workspace.

### Tests

- Backend replace-publish transaction test.
- Backend test that old dismissal does not suppress the new announcement.
- Backend invariant test for one active announcement per workspace.
- Frontend admin test showing the new active banner after publish.
- Workspace isolation test for replacement.

## Scenario 10: Concurrent Admin Writes

### Goal

Handle overlapping admin actions without producing impossible state.

### Research Inputs

- Existing concurrency test patterns.
- Existing optimistic locking, stale data, or last-writer-wins conventions.
- Exact database behavior for the planned unique active announcement constraint.

### Implementation Scope

- Make simultaneous publish attempts leave exactly one active banner.
- Map database uniqueness conflicts to a clear reload/retry response.
- Ensure edit and remove operations handle stale announcement IDs consistently.
- Keep admin-facing messages concise and aligned with existing UI patterns.

### Acceptance Criteria

- Two admins publishing at the same time cannot create two active banners.
- One publish succeeds; any conflict is visible to the losing admin with guidance to reload.
- If one admin removes a banner while another edits it, the final state is either a valid active edited banner or no active banner, never a partially visible or duplicated banner.
- The admin UI refreshes or prompts reload after conflict/stale-state responses.

### Tests

- Backend concurrent-publish test.
- Backend stale edit/remove tests.
- Frontend conflict message test.
- Regression test that every race outcome preserves one-active-banner invariant.

## Scenario 11: Polling, Backoff, and Non-Critical Failure Behavior

### Goal

Make banner delivery reliable without making the rest of the app feel broken when the banner endpoint fails.

### Research Inputs

- Existing polling intervals and environment configuration patterns.
- Existing fetch cancellation behavior on logout, workspace switch, or unmount.
- Existing structured logging for frontend or backend fetch failures.

### Implementation Scope

- Poll the active endpoint at the configured interval while the feature is enabled.
- Cancel polling on logout, workspace switch, or component unmount.
- Back off after repeated poll failures and resume the normal interval after success.
- Do not show regular users an error if polling fails; render no banner.
- For dismiss failure, show the existing transient error UI and leave the user able to retry.

### Acceptance Criteria

- Users see new or changed banners within the configured polling interval under normal conditions.
- Polling stops when it is no longer relevant.
- Poll errors do not break the page or show noisy UI.
- Dismiss errors are visible enough for the user to understand that dismissal was not saved.
- No memory leaks or duplicate pollers appear after navigation.

### Tests

- Frontend polling interval test with fake timers.
- Frontend poll cancellation test.
- Frontend poll failure/backoff test.
- Frontend dismiss failure test.
- Backend poll error logging test where supported by local test harness.

## Scenario 12: Observability, Audit, and Rollout Readiness

### Goal

Ship the feature with enough operational visibility and a safe rollout path.

### Research Inputs

- Existing structured log event names and field conventions.
- Existing metric declaration and dashboard conventions.
- Existing alert routing and severity standards.
- Existing feature rollout checklist.

### Implementation Scope

- Add structured logs for publish, edit, remove, conflict, and backend errors.
- Avoid logging banner text; log message length and IDs instead.
- Add counters for poll hit/miss/error, dismiss success/error, publish success/conflict/error, and edit/remove results if supported.
- Add or document alert conditions for elevated poll and dismiss error rates.
- Document deploy order: migrations, backend with flag off, frontend with flag off, test workspace enablement, gradual rollout, global enablement.
- Confirm rollback behavior by turning the flag off.

### Acceptance Criteria

- Operators can tell whether polls, dismissals, and publishes are succeeding.
- Sensitive banner text is not emitted into logs or metrics.
- Turning the flag off removes user-visible feature surfaces without dropping data.
- The deploy sequence is additive and reversible.
- A test workspace can validate the full publish-view-dismiss-remove loop before broad rollout.

### Tests

- Unit or integration tests for log/metric emission where existing harnesses support it.
- Manual or automated rollout smoke test in a flagged test workspace.
- Rollback smoke test showing the feature disappears when the flag is off.

## Cross-Scenario Test Matrix

Backend coverage:

- Migrations and rollback.
- Admin authorization for create, edit, and remove.
- Authenticated user authorization for active fetch and dismiss.
- Validation for message, link, start time, and end time.
- Active-window filtering using server time.
- Workspace isolation.
- One-active-banner invariant.
- Publish replacement transaction.
- Dismiss idempotency and per-user suppression.
- Edit preserves dismissal semantics.
- Remove suppresses visibility.
- Concurrent publish conflict behavior.

Frontend coverage:

- Admin navigation hidden when flag is off.
- Admin Announcements page form states, validation, publish, edit, and remove.
- App-shell banner hidden for no active banner, visible for active banner, and absent after dismiss.
- Optional link rendering.
- Polling interval, cancellation, backoff, and silent poll failure.
- Dismiss success and dismiss failure.
- Accessibility for the dismiss button, keyboard operation, focus behavior, and text/link semantics.

End-to-end coverage:

- Admin publishes an immediate banner, user sees it, user dismisses it, and it stays dismissed after a new session.
- Admin edits a dismissed banner and the same user still does not see it.
- Admin publishes a new banner and users who dismissed the old one see the new one.
- Admin schedules future start and end times, and visibility changes with server time.
- Admin removes the active banner and users stop seeing it.
- Non-admin crafted write attempts fail.

## Accessibility and UI Requirements

- The banner must not overlap navigation, modals, or primary content.
- The dismiss control must be a real button with an accessible label.
- The optional link must be keyboard reachable and visibly distinct.
- The banner must be readable at supported viewport widths without text overflow.
- The component must work with screen readers as a global announcement without repeatedly interrupting users on every poll.
- Any animation should respect reduced-motion preferences.
- The admin form must expose validation messages in an accessible way.

## Security Requirements

- Never trust workspace ID, user ID, creator ID, or dismissed user ID from request bodies.
- Authorize all admin writes before validation or mutation.
- Treat message as plain text and render through safe text interpolation.
- Reject unsafe link schemes.
- Return only display fields to regular user reads.
- Keep admin/audit-only fields out of the user active-banner response.
- Do not log full banner message contents.

## Data and API Contract Summary

Announcement record:

- Stable announcement ID.
- Workspace ID from authenticated context.
- Message, required, plain text, max 200 characters.
- Optional safe link URL.
- Start timestamp, defaulting to immediate activation.
- Optional end timestamp.
- Status for active, archived, or removed lifecycle.
- Creator/admin ID for audit.
- Created and updated timestamps.

Dismissal record:

- Announcement ID.
- User ID from authenticated context.
- Dismissed timestamp.
- Unique by announcement and user.

User active-banner response:

- Null/empty banner when nothing should be shown.
- Banner ID, message, and optional link when one should be shown.
- No unrelated user, creator, or workspace internals.

Admin responses:

- Follow existing response envelope conventions.
- Include enough current active-banner state for the admin page to refresh after publish, edit, or remove.

## Rollout Checklist

1. Research confirms concrete modules, helpers, and test harnesses.
2. Migrations are added and verified forward/backward.
3. Backend routes and services are implemented behind the disabled feature flag.
4. Admin UI is implemented behind the disabled feature flag.
5. App-shell banner and polling are implemented behind the disabled feature flag.
6. Scenario tests pass locally.
7. Observability hooks are added or documented.
8. Code deploys with the flag off.
9. Flag is enabled for a test workspace.
10. End-to-end smoke verifies publish, view, dismiss, edit, replace, schedule, and remove.
11. Rollout expands gradually while monitoring poll and dismiss error rates.
12. Rollback path is verified by disabling the flag.

## Deferred Follow-Ups

These are not required for the first implementation unless research discovers existing platform requirements that make them mandatory:

- Admin publish idempotency keys for network-timeout retry UX.
- Automated cleanup of old archived/removed announcements and dismissal rows.
- Redis or shared-cache optimization for very large workspaces.
- Separate link label field if product requires display text other than the URL or a fixed label.
- Admin history/audit UI for past banners.
- Click-through analytics or banner view analytics.

