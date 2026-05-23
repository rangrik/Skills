# System Design: Admin Announcement Banner

**Author:** System Design Agent
**Date:** 2026-05-23
**Status:** Draft
**Source Blueprint:** announcement-banner-blueprint.md (approved 2026-05-15)

---

## 1. Overview

The Admin Announcement Banner feature lets a workspace admin post a short plain-text message that appears at the top of the application for every user in that workspace. Users can dismiss the banner persistently. The admin may set an optional start/end window and can edit or remove the banner at any time. Only one banner is active per workspace at a time.

This document covers the database schema, API design, backend service logic, frontend integration, and operational considerations for a standard Node/Express + PostgreSQL backend with a React frontend.

---

## 2. Requirements Summary

### Functional
- Admins can create, edit, and remove a banner (plain text, up to 200 chars, plus an optional URL).
- At most one banner is active per workspace at any given moment. Publishing a new banner replaces the previous one.
- Optional `starts_at` and `ends_at` timestamps. If `starts_at` is absent, the banner is active immediately. If `ends_at` is absent, the banner remains until explicitly removed.
- `ends_at` must be strictly after `starts_at` (or after now if no `starts_at` is provided); otherwise publishing is rejected.
- Per-user, per-banner dismissal. Dismissal is permanent across sessions and devices.
- Editing banner text does not un-dismiss it for users who already dismissed it.
- Users who join after publication see the banner (if still within its active window).

### Non-Functional
- Banner visibility must propagate to all active sessions within a few seconds of publishing.
- Dismissal must be recorded durably (survives server restart, re-login, new device).
- Only workspace admins may mutate banners. Authorization must be enforced server-side.

### Out of Scope
- Rich text, images, multiple simultaneous banners.
- Per-user or per-group targeting.
- Recurring schedules.

---

## 3. Data Model

### 3.1 `announcements` Table

```sql
CREATE TABLE announcements (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  UUID        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    message       VARCHAR(200) NOT NULL,
    link_url      TEXT,                       -- optional URL
    link_label    VARCHAR(100),               -- optional display text for the link
    starts_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at       TIMESTAMPTZ,                -- NULL = no expiry
    created_by    UUID        NOT NULL REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_at    TIMESTAMPTZ,                -- soft-delete / early removal
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE
                              -- set to FALSE when superseded by a new banner
);

CREATE INDEX idx_announcements_workspace_active
    ON announcements (workspace_id, is_active, starts_at, ends_at);
```

**Design notes:**
- `is_active = FALSE` marks banners that have been superseded by a newer publish within the same workspace. This lets old banners be kept for audit/history without surfacing them to users.
- `removed_at` records early admin removal. A removed banner is still queryable for history.
- `starts_at` defaults to `NOW()` so immediate publishing requires no extra logic.
- Only one row per workspace should have `is_active = TRUE` at any time; this invariant is maintained by the service layer (see §5.2).

### 3.2 `announcement_dismissals` Table

```sql
CREATE TABLE announcement_dismissals (
    announcement_id  UUID        NOT NULL REFERENCES announcements(id) ON DELETE CASCADE,
    user_id          UUID        NOT NULL REFERENCES users(id)          ON DELETE CASCADE,
    dismissed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (announcement_id, user_id)
);

CREATE INDEX idx_dismissals_user
    ON announcement_dismissals (user_id, announcement_id);
```

**Design notes:**
- Composite primary key guarantees idempotency: a second dismiss request for the same `(announcement_id, user_id)` pair is a no-op (via `INSERT ... ON CONFLICT DO NOTHING`).
- Rows are tied to the `announcement_id`, not to the banner text. Editing the text does not affect existing dismissals, satisfying the "edit does not un-dismiss" rule.

---

## 4. API Design

All endpoints are under `/api/v1`. Authentication is assumed to be handled by existing middleware that populates `req.user` (user ID + workspace membership + role).

### 4.1 Admin Endpoints

#### `GET /workspaces/:workspaceId/announcements`
Returns the current active banner (for the admin management page). No dismissal filtering — admins always see it.

**Authorization:** Workspace admin.

**Response 200:**
```json
{
  "announcement": {
    "id": "uuid",
    "message": "We're moving to a new data center this weekend.",
    "link_url": "https://status.example.com",
    "link_label": "Status page",
    "starts_at": "2026-05-24T09:00:00Z",
    "ends_at": "2026-05-25T18:00:00Z",
    "created_by": "uuid",
    "created_at": "...",
    "updated_at": "..."
  }
}
```
Returns `{ "announcement": null }` when no active banner exists.

---

#### `POST /workspaces/:workspaceId/announcements`
Publishes a new banner, deactivating any existing one.

**Authorization:** Workspace admin.

**Request body:**
```json
{
  "message": "string (1–200 chars, required)",
  "link_url": "string (optional, must be a valid URL if present)",
  "link_label": "string (optional, max 100 chars)",
  "starts_at": "ISO 8601 datetime (optional)",
  "ends_at":   "ISO 8601 datetime (optional)"
}
```

**Validation:**
- `message` required, 1–200 characters.
- If both `starts_at` and `ends_at` are given: `ends_at > starts_at`.
- If only `ends_at` is given: `ends_at > NOW()`.
- `link_url` must be a valid absolute URL if present.

**Response 201:** Created announcement object (same shape as GET above).
**Response 400:** Validation failure with `{ "error": "ends_at must be after starts_at" }`.
**Response 403:** Not a workspace admin.

---

#### `PATCH /workspaces/:workspaceId/announcements/:announcementId`
Edits the active banner's message, link, or schedule.

**Authorization:** Workspace admin.

**Request body:** Same optional fields as POST (only provided fields are updated).

**Behavior:** Updates `message`, `link_url`, `link_label`, `starts_at`, `ends_at`, and bumps `updated_at`. Does not alter existing dismissals.

**Response 200:** Updated announcement object.
**Response 404:** Banner not found or not the current active banner for this workspace.
**Response 400:** Validation failure.

---

#### `DELETE /workspaces/:workspaceId/announcements/:announcementId`
Removes the active banner early.

**Authorization:** Workspace admin.

**Behavior:** Sets `removed_at = NOW()` and `is_active = FALSE`. Users will no longer see the banner on next poll.

**Response 204:** No content.
**Response 404:** Banner not found or not the current active banner.

---

### 4.2 User Endpoints

#### `GET /workspaces/:workspaceId/active-announcement`
Returns the current visible announcement for the requesting user. Applies all filtering logic:

- `is_active = TRUE`
- `starts_at <= NOW()`
- `ends_at IS NULL OR ends_at > NOW()`
- `removed_at IS NULL`
- No dismissal record exists for `(announcement_id, user_id)`

**Authorization:** Any workspace member.

**Response 200:**
```json
{
  "announcement": {
    "id": "uuid",
    "message": "...",
    "link_url": "...",
    "link_label": "..."
  }
}
```
Returns `{ "announcement": null }` when nothing to show.

---

#### `POST /workspaces/:workspaceId/announcements/:announcementId/dismiss`
Records that the requesting user has dismissed this banner.

**Authorization:** Any workspace member (must belong to the workspace).

**Behavior:** `INSERT INTO announcement_dismissals ... ON CONFLICT DO NOTHING`. Always returns 204 regardless of whether a record already existed (idempotent).

**Response 204:** No content.
**Response 404:** Announcement not found in this workspace.

---

## 5. Backend Service Logic

### 5.1 Directory / Module Layout

```
src/
  features/
    announcements/
      announcements.router.ts      -- Express routes
      announcements.controller.ts  -- Request parsing, response shaping
      announcements.service.ts     -- Business logic
      announcements.repository.ts  -- SQL queries (Postgres via pg / knex)
      announcements.types.ts       -- TypeScript interfaces
      announcements.validation.ts  -- Zod/Joi schemas
```

### 5.2 Publish Logic (Transaction)

Publishing a new banner must atomically deactivate the previous one. The service executes this inside a single database transaction:

```
BEGIN;
  UPDATE announcements
     SET is_active = FALSE, updated_at = NOW()
   WHERE workspace_id = $workspaceId
     AND is_active = TRUE;

  INSERT INTO announcements (workspace_id, message, link_url, link_label,
                             starts_at, ends_at, created_by)
  VALUES (...)
  RETURNING *;
COMMIT;
```

The UPDATE may affect 0 or 1 row; both outcomes are acceptable. This single transaction ensures there is never a moment with two active banners and never a gap where neither is active within the same request cycle.

### 5.3 Edit Logic

`PATCH` only updates the existing row. No dismissal records are touched. The `updated_at` column is bumped so clients can detect staleness if they cache the banner.

### 5.4 Authorization Middleware

A shared Express middleware `requireWorkspaceAdmin(req, res, next)` checks that `req.user.workspaceRoles[workspaceId]` includes `'admin'`. This middleware is applied to the `POST`, `PATCH`, and `DELETE` admin routes. The user-facing `GET` and `POST /dismiss` endpoints only require workspace membership.

### 5.5 Scheduling / Expiry

There is no background job for expiry. Expiry is enforced purely at query time: the `GET /active-announcement` query filters `ends_at IS NULL OR ends_at > NOW()`. This means:

- No cron job or worker is needed.
- A banner will stop appearing naturally when `ends_at` passes, on the next poll.
- The `starts_at` constraint is likewise enforced at query time.

**Assumption:** near-real-time propagation (within the polling interval) is acceptable; truly instantaneous expiry is not required. See §6 for polling frequency.

---

## 6. Frontend Design

### 6.1 Polling Strategy

The frontend polls `GET /workspaces/:workspaceId/active-announcement` every **60 seconds** while the app is in focus. This means:

- A newly published banner appears for all users within ~60 seconds.
- An expired or removed banner disappears within ~60 seconds.

**Rationale:** A banner is not a real-time chat message. 60-second latency is acceptable per the blueprint's "within a short time" wording. A WebSocket push could reduce latency but adds significant complexity for a low-urgency feature; the simpler polling approach is preferred.

**Implementation:** Use a `setInterval` inside a React custom hook (`useActiveBanner`). Pause polling when the document is hidden (`document.visibilityState === 'hidden'`).

### 6.2 `useActiveBanner` Hook

```typescript
// Pseudocode
function useActiveBanner(workspaceId: string) {
  const [banner, setBanner] = useState<Banner | null>(null);
  const [dismissed, setDismissed] = useState(false);

  // Poll every 60 s
  useEffect(() => {
    if (dismissed) return;
    const fetchBanner = async () => {
      const data = await api.get(`/workspaces/${workspaceId}/active-announcement`);
      setBanner(data.announcement);
    };
    fetchBanner();
    const id = setInterval(fetchBanner, 60_000);
    return () => clearInterval(id);
  }, [workspaceId, dismissed]);

  const dismiss = useCallback(async () => {
    if (!banner) return;
    await api.post(`/workspaces/${workspaceId}/announcements/${banner.id}/dismiss`);
    setDismissed(true);
    setBanner(null);
  }, [banner, workspaceId]);

  return { banner, dismiss };
}
```

**Dismissed state:** After a successful `dismiss` API call, the hook sets `dismissed = true` and stops polling. On next page load the banner won't appear because the server won't return it for that user.

**New banner detection:** If the server returns a different `banner.id` than the one currently displayed (e.g., admin published a new one), the hook updates `banner`. The `dismissed` flag is reset to `false` because the new banner has a new ID and the user has not dismissed it yet.

### 6.3 Banner Component

```tsx
// AnnouncementBanner.tsx (simplified)
function AnnouncementBanner({ workspaceId }: { workspaceId: string }) {
  const { banner, dismiss } = useActiveBanner(workspaceId);
  if (!banner) return null;

  return (
    <div role="banner" aria-live="polite" className="announcement-banner">
      <span>{banner.message}</span>
      {banner.link_url && (
        <a href={banner.link_url} target="_blank" rel="noopener noreferrer">
          {banner.link_label ?? banner.link_url}
        </a>
      )}
      <button onClick={dismiss} aria-label="Dismiss announcement">
        &times;
      </button>
    </div>
  );
}
```

This component sits at the top of the main app layout, rendered for every authenticated workspace route.

### 6.4 Admin Management UI

Located at `/settings/announcements`. Key elements:

- A form with: message textarea (character counter, 200-char limit), optional link URL + label fields, optional start date/time picker, optional end date/time picker.
- "Publish" button: calls `POST`. On success, refreshes the displayed active banner.
- If a banner is currently active, the form is pre-populated for editing; "Save Changes" calls `PATCH`.
- "Remove" button: calls `DELETE`; clears the form on success.
- Inline validation: shows "End date must be after start date" before submission if the client-side check fails. Server-side validation is the authoritative check.

---

## 7. Security Considerations

| Threat | Mitigation |
|---|---|
| Non-admin publishes a banner via crafted HTTP request | `requireWorkspaceAdmin` middleware enforces the check server-side; client role checks are cosmetic only. |
| Cross-workspace data leak | All queries are scoped by `workspace_id`, and the service verifies `req.user` belongs to that workspace before proceeding. |
| XSS via banner message | Message is stored as plain text. React's default JSX rendering escapes all string values; no `dangerouslySetInnerHTML` is used. |
| XSS via link URL | `link_url` is validated as an absolute `https://` or `http://` URL on the server. The frontend renders it as an `<a href>` — React escapes the attribute value, and the URL scheme whitelist prevents `javascript:` URIs. |
| Dismissal spoofing | The dismiss endpoint uses the authenticated `req.user.id`; a user cannot dismiss on behalf of another user. |
| Concurrent admin publishes | Handled by the transactional deactivation in §5.2; last write wins, consistent with the blueprint's "most recent publish wins" rule. |

---

## 8. Database Considerations

### Indexes
The indexes defined in §3 cover:
- Fast lookup of the active banner for a workspace (used by the user-facing GET endpoint, called up to every 60 s per user).
- Fast dismissal lookup by user (used in the same GET query via `NOT EXISTS`).

### Query for `GET /active-announcement`

```sql
SELECT a.id, a.message, a.link_url, a.link_label
  FROM announcements a
 WHERE a.workspace_id = $1
   AND a.is_active    = TRUE
   AND a.starts_at   <= NOW()
   AND (a.ends_at IS NULL OR a.ends_at > NOW())
   AND a.removed_at  IS NULL
   AND NOT EXISTS (
       SELECT 1
         FROM announcement_dismissals d
        WHERE d.announcement_id = a.id
          AND d.user_id         = $2
   )
LIMIT 1;
```

This is a point-read on the workspace's single active banner, then a secondary EXISTS check scoped by `(announcement_id, user_id)`. Both use indexed paths.

### Volume Estimate
At moderate scale (e.g., 10,000 concurrent users polling every 60 s), this endpoint receives ~167 RPS. Each query is a narrow indexed lookup against at most one active banner row per workspace. This is well within Postgres capacity without caching.

---

## 9. Error Handling

| Scenario | Server Response | Frontend Behavior |
|---|---|---|
| Banner publish validation fails | 400 + error message | Show inline form error |
| User not admin tries to publish | 403 | Show generic permission error |
| Dismiss fails (network) | 5xx / network error | Retry once silently; if still failing, leave banner visible (it will re-appear on next poll anyway) |
| Poll fails (network) | — | Log warning; keep showing current banner state; retry on next interval |
| Admin edits banner while another admin just published | PATCH returns 404 (old ID is no longer active) | Admin UI shows "This banner has been replaced" and reloads current banner |

---

## 10. Testing Plan

### Unit Tests (Service Layer)
- `publishBanner`: verify deactivation of existing banner, correct row insertion, validation errors (end before start, message too long).
- `editBanner`: verify only the target row is updated; verify dismissals are unchanged.
- `removeBanner`: verify `removed_at` and `is_active` are set correctly.
- `getActiveBannerForUser`: verify filtering by `starts_at`, `ends_at`, `removed_at`, and dismissal status.

### Integration Tests (API)
- `POST /announcements` as admin: 201 and banner is retrievable.
- `POST /announcements` as non-admin: 403.
- `POST /announcements` with `ends_at` before `starts_at`: 400.
- `DELETE /announcements/:id` ends early; subsequent `GET /active-announcement` returns null.
- `POST /dismiss` is idempotent; second call returns 204 with no error.
- After dismiss, `GET /active-announcement` returns null for that user.
- After edit, dismissed users still do not see the banner.
- New user (no dismissal record) sees banner within active window.

### Frontend Tests
- `useActiveBanner` re-polls and updates when a new banner ID appears.
- `useActiveBanner` stops polling after dismiss.
- `AnnouncementBanner` renders null when no banner.
- Admin form shows validation error for invalid date range.

---

## 11. Migration

```sql
-- Migration: 20260523_add_announcement_banner.sql

CREATE TABLE announcements (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  UUID        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    message       VARCHAR(200) NOT NULL,
    link_url      TEXT,
    link_label    VARCHAR(100),
    starts_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at       TIMESTAMPTZ,
    created_by    UUID        NOT NULL REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    removed_at    TIMESTAMPTZ,
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_announcements_workspace_active
    ON announcements (workspace_id, is_active, starts_at, ends_at);

CREATE TABLE announcement_dismissals (
    announcement_id  UUID        NOT NULL REFERENCES announcements(id) ON DELETE CASCADE,
    user_id          UUID        NOT NULL REFERENCES users(id)          ON DELETE CASCADE,
    dismissed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (announcement_id, user_id)
);

CREATE INDEX idx_dismissals_user
    ON announcement_dismissals (user_id, announcement_id);
```

Rollback:

```sql
DROP TABLE IF EXISTS announcement_dismissals;
DROP TABLE IF EXISTS announcements;
```

---

## 12. Open Questions / Future Work

1. **Push instead of poll:** If the product later requires truly instant propagation (< 5 s), a WebSocket or Server-Sent Events channel could push new banner events to connected clients.
2. **Banner history:** The current schema retains superseded banners (`is_active = FALSE`). A history view in admin settings could be added with no schema changes.
3. **Soft-delete retention policy:** Old banner rows and dismissal records accumulate over time. A cleanup job or partition strategy could be added if volume becomes a concern.
4. **Rate limiting:** The dismiss and publish endpoints could be rate-limited per user/admin if abuse is a concern.
