# Implementation Plan: Admin Announcement Banner

## Purpose

Build a workspace-scoped admin announcement banner for Kite. A workspace admin can publish one short plain-text banner, optionally with a link and an active time window. Users in the workspace see the banner at the top of the app, can dismiss it once, and that dismissal persists across devices and sessions. Only one banner may be active for a workspace at any time.

This plan is intentionally source-code blind. Research should use it to find the existing conventions before implementation begins.

## Source Inputs

- Behavior blueprint: announcement-banner-blueprint.md, approved 2026-05-15.
- System design: announcement-banner-system-design.md, draft 2026-05-23.

## Core Product Invariants

- Only workspace admins can create, edit, or remove announcements.
- Any authenticated workspace user can read the active announcement for their workspace.
- A banner belongs to exactly one workspace.
- At most one active banner exists per workspace.
- Publishing a new banner replaces the previous active banner for that workspace.
- A banner message is plain text, non-empty, and at most 200 characters.
- The banner may include one optional HTTPS link.
- If no start time is provided, the banner is active immediately.
- If no end time is provided, the banner remains active until removed or replaced.
- If an end time is provided, it must be after the start time.
- Dismissal is keyed to the user and the announcement, not to browser storage or message text.
- Editing announcement text does not clear existing dismissals.
- Removing or expiring a banner hides it for everyone.
- No rich text, images, recurring schedules, audience targeting, or multiple simultaneous banners are in scope.

## Architecture Commitments From Design

- Use two new persistence tables: one for workspace announcements and one for user dismissals.
- Store dismissals server-side so they persist across devices and sessions.
- Enforce the one-active-banner invariant at the database layer with an active-per-workspace uniqueness rule.
- Use synchronous backend writes; no background worker is required for publish, edit, remove, or dismiss.
- Resolve active/expired state at query time using server/database time.
- Expose admin write endpoints, a user-aware active-announcement read endpoint, and a dismiss endpoint.
- Mount a frontend banner in the app shell and poll the active-announcement endpoint on a short interval, defaulting to about 30 seconds.
- Gate the feature behind an announcement-banner feature flag that fails closed.

## Research Brief

Before coding any scenario, research should identify the existing project conventions for:

- Database migration file format, naming, rollback style, UUID generation, timestamps, partial indexes, and check constraints.
- Existing workspace, user, and admin-role schema names and primary key types.
- Backend route organization for admin settings routes and app-level authenticated routes.
- Existing middleware for authentication, workspace resolution, admin authorization, feature flags, request validation, error responses, structured logging, and metrics.
- Existing service/repository/data-access patterns for transactional writes.
- Existing frontend admin settings navigation and page composition.
- Existing frontend app shell or layout injection point for a workspace-wide top banner.
- Existing data-fetching, polling, retry, toast, and loading/error UI patterns.
- Existing test framework and preferred locations for migration, backend, frontend, and end-to-end tests.
- Existing accessibility patterns for dismissible banners, links, icon buttons, focus management, and reduced-motion styling.

Research should not change behavior decisions unless the codebase makes a design assumption impossible. Any such conflict should be written down before implementation proceeds.

## Ordered Scenario Plan

### Scenario 0: Feature Flag And Persistence Foundation

**User-visible behavior:** None yet. This slice creates the safe foundation needed by every later scenario.

**Why first:** Every scenario depends on workspace-scoped banner state, server-side dismissals, and feature-gated rollout.

**Research tasks:**

- Find the migration conventions and the existing table names for workspaces and users.
- Confirm whether IDs are UUIDs or another type.
- Confirm whether database-level check constraints and partial unique indexes are used locally.
- Find feature-flag conventions and how disabled routes/UI should behave.

**Implementation tasks:**

- Add a workspace announcements table with workspace ID, message, optional link URL, start time, optional end time, status, created-by user, created time, and updated time.
- Add a user dismissals table keyed by announcement ID and user ID, with dismissed time.
- Add a database-level uniqueness rule that prevents more than one active announcement per workspace.
- Add database constraints or application validations for message length and valid time windows, matching local conventions.
- Add indexes that support fast lookup of a workspace's current active announcement and a user's dismissal for that announcement.
- Add reversible migrations.
- Add or register the announcement-banner feature flag with a default disabled state.

**Verification:**

- Migration up creates both tables, constraints, and indexes.
- Migration down removes only this feature's schema.
- Database constraints reject duplicate active announcements for the same workspace.
- Dismissal duplicates for the same user and announcement are impossible.
- Feature flag defaults off in all environments unless explicitly enabled.

### Scenario 1: Admin Sees The Announcements Settings Surface

**User-visible behavior:** A workspace admin can open an Announcements settings page or panel. When the feature flag is off, the surface is not visible. When no active banner exists, the page shows the normal empty state and a publish form.

**Why now:** This establishes the admin entry point without requiring banner display across the whole app.

**Research tasks:**

- Find how admin settings pages are registered in navigation.
- Find form, validation, date/time input, link input, button, and toast patterns.
- Find the standard empty-state language and permissions handling for admin-only settings.

**Implementation tasks:**

- Add the Announcements settings page behind the feature flag.
- Restrict the page to workspace admins through existing frontend and backend access patterns.
- Add a publish form for message, optional HTTPS link, optional start time, and optional end time.
- Enforce client-side validation for non-empty message, 200-character maximum, valid HTTPS link, valid timestamps, and end time after start time.
- Keep validation messages specific enough for admins to fix the input.
- Display a normal no-active-banner state without treating it as an error.

**Verification:**

- Admin users with the flag enabled can reach the page.
- Non-admin users cannot reach the page through navigation and cannot use the underlying admin API.
- The page is absent or inaccessible when the feature flag is disabled.
- Empty state appears when there is no active announcement.
- Client-side validation catches invalid input before submit where practical.

### Scenario 2: Admin Publishes An Immediately Active Banner

**User-visible behavior:** An admin enters a message, leaves start and end blank, clicks Publish, and the banner becomes the workspace's active announcement immediately.

**Why now:** This is the core write path and the simplest happy path.

**Research tasks:**

- Find how admin POST routes are structured.
- Find existing request validation libraries or schemas.
- Find transaction helper patterns and error-response conventions.
- Find how workspace ID and admin user ID are read from the authenticated request.

**Implementation tasks:**

- Add an admin publish endpoint behind authentication, admin authorization, and the feature flag.
- Derive workspace ID and created-by user ID from the authenticated session, never from the request body.
- Validate message, link URL, start time, and end time on the server.
- Treat a missing start time as active immediately.
- In one transaction, archive any previous active announcement for the workspace and insert the new active announcement.
- Return the newly active announcement in the API response using the project's normal response shape.
- Connect the admin publish form to the endpoint.
- After successful publish, update the admin page to show the active announcement state.

**Verification:**

- A valid admin publish creates one active announcement for the workspace.
- A second publish archives or replaces the previous active announcement and leaves exactly one active announcement.
- Invalid message, invalid link, invalid dates, and end-before-start are rejected with validation errors.
- Workspace and created-by values cannot be spoofed by request body fields.
- Disabled feature flag prevents publish.

### Scenario 3: Users See The Active Banner Across The App

**User-visible behavior:** An authenticated user in the workspace sees the active banner across the top of the app within the accepted short polling delay.

**Why now:** This completes the core happy path from admin publish to user visibility.

**Research tasks:**

- Find the app shell or layout location that applies across the authenticated workspace app.
- Find existing lightweight polling or query refetch patterns.
- Find existing top-of-app banners, alerts, or layout-safe notification components.
- Find design-system styles for links, close buttons, and responsive single-line text.

**Implementation tasks:**

- Add an authenticated active-announcement endpoint behind the feature flag.
- Resolve the caller's workspace from the session.
- Return no banner when there is no active announcement.
- Return no banner when the active announcement has a future start time or an elapsed end time.
- Return the current active announcement fields needed for display: ID, message, optional link, and enough timing data for diagnostics if already standard.
- Include whether the current user has dismissed the announcement, or suppress dismissed announcements in the response, following whichever response style best matches local API conventions.
- Add an AnnouncementBanner component in the app shell behind the feature flag.
- Poll the active-announcement endpoint on the configured interval, defaulting to about 30 seconds.
- Render the message as plain text, never as HTML.
- Render the optional link safely and only when present.
- Ensure the banner does not cover or shift important app controls in an incoherent way on desktop or mobile.
- On poll failures, render no banner and retry with backoff rather than showing an app-wide error.

**Verification:**

- A user in the same workspace sees the active banner after publish.
- Users in other workspaces do not see the banner.
- No active banner produces no visible UI and no error state.
- Poll failure does not break the app shell.
- Message text containing HTML-like characters renders as text.
- Optional link renders only for valid stored HTTPS URLs.
- The banner is keyboard accessible and screen-reader understandable.

### Scenario 4: User Dismisses The Banner Persistently

**User-visible behavior:** A user clicks the dismiss control. The banner disappears and does not return for that user across reloads, sessions, or devices.

**Why now:** Dismissal persistence is a defining requirement and depends on the active read path.

**Research tasks:**

- Find existing POST action patterns for authenticated user actions.
- Find toast behavior for failed non-critical actions.
- Confirm whether optimistic UI updates are standard for dismissible UI.

**Implementation tasks:**

- Add a dismiss endpoint for an announcement ID behind authentication and the feature flag.
- Record dismissal for the authenticated user only.
- Make the dismiss write idempotent so double-clicks and retries do not create duplicate records or errors.
- Ensure dismissal cannot be written on behalf of another user.
- Ensure dismissal for an announcement outside the user's workspace is rejected or treated as not found according to local security conventions.
- Wire the banner dismiss button to the endpoint.
- Optimistically hide the banner after dismiss if that matches local UX patterns.
- If dismiss fails, show a transient error and allow retry; the banner may reappear on the next poll until dismissal is saved.

**Verification:**

- Dismiss creates exactly one dismissal for the current user and announcement.
- Repeated dismiss requests are harmless.
- Dismissed banner remains hidden after page reload.
- Dismissed banner remains hidden when the same user signs in on another device or browser.
- Another user in the same workspace still sees the banner until they dismiss it.
- A user cannot dismiss an announcement from another workspace.

### Scenario 5: Scheduled Start And End Times Control Visibility

**User-visible behavior:** A banner with a future start time does not show until that time. A banner with an end time stops showing after the end time. End-before-start is rejected.

**Why now:** Scheduling builds on publish and active-read behavior and avoids adding a background worker.

**Research tasks:**

- Confirm whether the backend standardizes on database time or application server time.
- Find date/time input timezone conventions in admin settings.
- Find test helpers for controlling time.

**Implementation tasks:**

- Apply active-window filtering on the server side using authoritative server/database time.
- Keep future-start announcements in active status if that is required by the one-active-banner invariant, while ensuring the active read endpoint hides them until the start time.
- Ensure end time filtering hides expired banners without requiring a scheduled status update.
- Ensure open-ended banners remain visible until removed or replaced.
- Present date/time inputs in a way consistent with existing timezone conventions.
- Reject invalid timestamps and end-before-start on both client and server.

**Verification:**

- Future-start banner is not returned before its start time.
- Future-start banner is returned after its start time.
- Banner is no longer returned after its end time.
- Banner without an end time remains visible.
- End-before-start cannot be published.
- Server-side time controls visibility; browser clock skew does not control whether a banner is visible.

### Scenario 6: A New User Joins After Publication

**User-visible behavior:** A user who joins the workspace after a banner was published sees the banner if it is still within its active window and they have not dismissed it.

**Why now:** This validates that visibility derives from current workspace membership and dismissal state rather than from any fan-out at publish time.

**Research tasks:**

- Find how tests create workspace membership or authenticated users.
- Confirm how workspace membership is resolved for active app requests.

**Implementation tasks:**

- Do not create per-user banner records at publish time.
- Ensure the active read endpoint uses the caller's current workspace membership.
- Ensure a missing dismissal row means the banner is visible when the active window matches.

**Verification:**

- A newly added workspace user sees an already-published active banner.
- A newly added user has no inherited dismissal state.
- If the banner has expired or been removed, the newly added user sees no banner.

### Scenario 7: Admin Edits Active Banner Text Without Reviving Dismissals

**User-visible behavior:** An admin edits the active banner's text. Users who have not dismissed the banner see the new text. Users who already dismissed that announcement still do not see it.

**Why now:** This depends on both dismissal being keyed to announcement ID and the active read path joining dismissal state.

**Research tasks:**

- Find existing PATCH route conventions and optimistic conflict handling.
- Find admin form patterns for editing an existing record.
- Confirm whether the first implementation should edit only message text or also allow link/time-window edits.

**Implementation tasks:**

- Add an admin edit endpoint for the active announcement behind authentication, admin authorization, and the feature flag.
- Validate edited message with the same plain-text and length rules as publish.
- Preserve the announcement ID during edit so existing dismissals remain attached.
- Do not delete or reset dismissal rows during edit.
- If the targeted announcement is no longer active because another admin replaced or removed it, return a conflict or not-found response using local conventions.
- Add edit controls to the admin page for the current active announcement.
- Refresh active state after a successful edit.

**Verification:**

- Edit changes the active banner text for users who have not dismissed it.
- A user who dismissed the banner before the edit still does not see it.
- Edit does not create a new announcement row unless local conventions require versioned records; if it does, dismissal semantics must still stick to the same logical announcement.
- Non-admin edit attempts are rejected.
- Editing a stale or replaced announcement cannot overwrite the newer active announcement.

### Scenario 8: Admin Removes A Banner Early

**User-visible behavior:** An admin clicks Remove. The banner stops showing for everyone before its scheduled end time.

**Why now:** This completes the admin lifecycle after publish and edit.

**Research tasks:**

- Find delete/remove route conventions and whether destructive admin actions require confirmation.
- Find admin toast and empty-state refresh patterns after removal.

**Implementation tasks:**

- Add an admin remove endpoint behind authentication, admin authorization, and the feature flag.
- Mark the announcement removed and set the effective end time to now, or otherwise apply the design's selected soft-remove state.
- Ensure the active read endpoint excludes removed announcements.
- Add a Remove control to the active announcement UI.
- After successful removal, return the admin page to the no-active-banner state.

**Verification:**

- Removed announcement is not returned by the active read endpoint.
- All users stop seeing the banner after the next poll or refresh.
- Remove is safe if repeated or if the announcement has already been replaced, following local conflict conventions.
- Non-admin remove attempts are rejected.
- Historical dismissal rows do not affect future replacement banners.

### Scenario 9: Publishing A Replacement Banner Resets Visibility Correctly

**User-visible behavior:** When an admin publishes a new banner while another banner exists, the new banner replaces the old one. Users who dismissed the old banner can see the new banner because it is a different announcement.

**Why now:** This validates the difference between editing an existing banner and publishing a replacement banner.

**Research tasks:**

- Confirm transaction and unique-constraint error handling conventions.
- Confirm how archived/replaced records should appear or not appear in admin UI.

**Implementation tasks:**

- Ensure publish replacement archives the previous active announcement and inserts a new announcement with a new identity.
- Ensure the active read endpoint returns only the replacement announcement.
- Ensure dismissal rows for the old announcement do not suppress the new announcement.
- Ensure old announcements are retained for audit if that matches the local retention policy.

**Verification:**

- After replacement, exactly one active announcement exists for the workspace.
- Users see the replacement even if they dismissed the previous announcement.
- Users who dismiss the replacement do not see that replacement again.
- The previous announcement is not visible to any user after replacement.

### Scenario 10: Admin Race Conditions Preserve A Single Active Banner

**User-visible behavior:** If admins act at nearly the same time, the system never ends up with two active banners. Stale admin screens receive a clear reload/conflict path.

**Why now:** This hardens the already-built publish/edit/remove lifecycle against the blueprint's deviation scenarios.

**Research tasks:**

- Find how the backend maps database uniqueness conflicts to HTTP responses.
- Find whether the app has optimistic-locking conventions for stale updates.
- Confirm whether product prefers automatic last-writer-wins retry or explicit conflict messaging when concurrent publish transactions collide.

**Implementation tasks:**

- Keep the one-active-banner rule enforced by the database, not only in application logic.
- Ensure publish replacement runs in one transaction.
- Catch active-per-workspace uniqueness conflicts and return a clear conflict response.
- Ensure an edit for an announcement that is no longer active cannot revive or overwrite an announcement published by another admin.
- Ensure a remove for a stale announcement cannot remove a newer active announcement.
- Show admin-facing conflict messaging that asks the admin to reload the latest banner state.

**Verification:**

- Two concurrent publish attempts cannot produce two active announcements.
- A stale edit after another admin publishes a replacement does not change the replacement.
- A stale remove after another admin publishes a replacement does not remove the replacement.
- Admin UI handles conflict responses without losing unsaved user input unnecessarily.

### Scenario 11: Crafted Non-Admin Requests Are Rejected

**User-visible behavior:** Non-admins cannot create, edit, or remove announcements even if they manually craft requests.

**Why now:** Authorization should be present from the first admin route, but this scenario makes the adversarial requirement explicit and testable.

**Research tasks:**

- Find existing negative authorization tests.
- Find standard 401 versus 403 response conventions.
- Confirm whether disabled feature-flag routes return 404 as specified by design.

**Implementation tasks:**

- Apply admin authorization middleware to every admin write route.
- Apply authentication to active-read and dismiss routes.
- Ensure the backend checks authorization before business logic runs.
- Ensure no request body field can override workspace ID, user ID, role, or created-by user.
- Ensure route behavior when the feature flag is disabled follows the design: unavailable rather than partially active.

**Verification:**

- Unauthenticated admin writes are rejected.
- Authenticated non-admin admin writes are rejected.
- Non-admin requests cannot publish by adding role or workspace fields to the body.
- Authenticated users can only read and dismiss announcements scoped to their own workspace.
- Disabled feature flag prevents reads and writes according to the chosen route behavior.

### Scenario 12: Optional Link And Plain-Text Safety

**User-visible behavior:** An admin can add a safe optional link to the banner. The message remains plain text. Unsafe links and rich content are rejected or rendered harmlessly.

**Why now:** This completes the banner content model and protects against stored XSS.

**Research tasks:**

- Confirm local URL validation helpers.
- Confirm external-link rendering conventions, including target and rel attributes if applicable.
- Confirm product expectation for link display text.

**Implementation tasks:**

- Validate optional link URLs server-side with a strict HTTPS-only rule unless the codebase has an approved allowlist pattern.
- Mirror link validation client-side for faster feedback.
- Render message through normal React text interpolation.
- Do not support Markdown, HTML, images, or rich text.
- Render the optional link with accessible text according to the confirmed product behavior.

**Verification:**

- Valid HTTPS link can be published and rendered.
- Empty link is allowed.
- JavaScript, data, malformed, and non-HTTPS links are rejected.
- Message containing markup-like text is shown as text and never executed.
- Banner remains usable with keyboard navigation and assistive technology.

### Scenario 13: Observability, Rollout, And Operational Behavior

**User-visible behavior:** No new feature behavior. Operators can safely roll out, monitor, and roll back the feature.

**Why last:** This wraps the completed user scenarios with release safety.

**Research tasks:**

- Find existing structured logging and metrics conventions.
- Find rollout documentation and feature-flag release process.
- Find alerting conventions for endpoint error rates.

**Implementation tasks:**

- Add structured logs for publish, edit, remove, and backend errors without logging banner text.
- Add metrics for poll requests, publish results, dismiss results, and active banner age if matching local metrics conventions.
- Add alert definitions or dashboard updates for poll and dismiss error rates if this project keeps them in code.
- Ensure deploy order is migration first, backend second, frontend third, flag enablement last.
- Document rollback through disabling the feature flag.
- Confirm no existing endpoint or table behavior changes.

**Verification:**

- Logs include workspace ID, announcement ID, admin user ID where appropriate, and message length, but not message content.
- Metrics distinguish success, miss, conflict, and error outcomes where feasible.
- With the feature flag disabled, all user-visible UI disappears without dropping data.
- Migrations can remain deployed while the flag is off.
- A test workspace can be enabled before global rollout.

## Suggested Test Matrix

### Backend And Persistence

- Migration up/down.
- Announcement validation: empty message, overlong message, invalid link, invalid timestamps, end-before-start.
- Admin publish creates a current active announcement.
- Publish replacement leaves exactly one active announcement.
- Active read hides no-banner, future-start, expired, removed, other-workspace, and dismissed announcements.
- Active read returns current same-workspace not-dismissed announcement.
- Dismiss insert is idempotent and user-scoped.
- Edit preserves announcement identity and dismissal state.
- Remove hides announcement for everyone.
- Non-admin and unauthenticated negative cases for every route.
- Concurrent publish attempts cannot create two active announcements.
- Stale edit/remove cannot mutate a newer active announcement.

### Frontend

- Admin settings nav/page hidden when flag disabled.
- Admin settings page visible to admins when flag enabled.
- Publish form validation and success state.
- Active announcement edit and remove flows.
- Conflict and backend validation messages.
- App-shell banner renders message, optional link, and dismiss button.
- Banner hides after successful dismiss.
- Banner remains absent for dismissed response.
- Poll failure degrades silently in the shell.
- Layout behaves on desktop and mobile widths.
- Keyboard and screen-reader checks for banner, link, and dismiss button.

### End-To-End

- Admin publishes immediate banner; regular user sees it.
- User dismisses; reload and second browser session still hide it.
- Second user still sees the banner until they dismiss.
- Future-start banner appears only after start time.
- Ended or removed banner disappears after refresh or poll.
- Replacement banner appears even for users who dismissed the previous banner.
- Non-admin crafted publish request is rejected.

## Implementation Order Summary

1. Add feature flag and persistence foundation.
2. Add admin settings surface with no-active state.
3. Add admin publish path for immediate banners.
4. Add active read endpoint and app-shell banner display.
5. Add persistent dismissal.
6. Add scheduled start and end visibility.
7. Add new-user-after-publication coverage.
8. Add edit behavior without reviving dismissals.
9. Add remove behavior.
10. Add replacement-banner semantics.
11. Harden concurrent admin races.
12. Harden adversarial authorization.
13. Finish link/plain-text safety.
14. Add observability and rollout support.

## Definition Of Done

- All blueprint happy-path, edge-case, deviation, and adversarial scenarios are covered by implementation and tests.
- Dismissal persistence is server-side and works across sessions and devices.
- At most one active announcement per workspace is enforced by persistence, not just by UI.
- Admin write routes are protected by admin authorization and feature flagging.
- User read and dismiss routes are authenticated and workspace-scoped.
- Active-window behavior uses server/database time.
- The app shell degrades gracefully when polling fails.
- The feature can be enabled for a test workspace, monitored, disabled without data loss, and rolled out gradually.
