# System Design: Admin Announcement Banner

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../inputs/announcement-banner-blueprint.md](../inputs/announcement-banner-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The announcement banner is implemented as two new Postgres tables (`workspace_announcements` and `announcement_dismissals`), a small set of REST endpoints in the existing admin-settings service (or equivalent Express router), and a React component that short-polls a single lightweight GET endpoint to decide whether to show the banner. The single most important architectural choice is **dismissal stored server-side** (in a join table keyed to user + announcement ID rather than in `localStorage` or a cookie), which is the only way to satisfy the blueprint's requirement that dismissal persists across devices and sessions. Everything else follows from that decision: the poll endpoint joins the dismissals table per-user and returns at most one active banner record plus a "dismissed" flag, keeping the frontend stateless.

---

## 2. System Placement

This is a standard CRUD feature sitting entirely within the existing Node/Express backend and React frontend. No new service tier, background worker, or message bus is required.

```
Admin UI (React)
  ├── AdminAnnouncementsPage  →  POST /api/admin/announcements       (create/replace)
  │                           →  PATCH /api/admin/announcements/:id  (edit text)
  │                           →  DELETE /api/admin/announcements/:id (remove early)
  │
  └── AnnouncementBanner       →  GET /api/announcements/active       (poll, ~30 s)
       (shown to all users)    →  POST /api/announcements/:id/dismiss (dismiss)
```

**Components touched:**

| Component | Change |
|---|---|
| Express router (admin settings) | New `admin/announcements` route group |
| Express router (app-level) | New `announcements/active` + `announcements/:id/dismiss` routes |
| Postgres (platform DB) | Two new tables: `workspace_announcements`, `announcement_dismissals` |
| React (admin settings page) | New "Announcements" settings panel |
| React (app shell / layout) | `AnnouncementBanner` component injected above the main content area |

No changes to existing tables, no new external services, no new workers.

---

## 3. Architecture Decisions

### D1. Dismissal stored server-side (Postgres join table)

- **Decision:** A user's dismissal is recorded in `announcement_dismissals` (columns: `announcement_id`, `user_id`, `dismissed_at`), not in the browser (`localStorage`, cookie, or session).
- **Why:** The blueprint requires dismissal to survive across devices and sessions. Client-side storage cannot satisfy this invariant. Storing it server-side also means the poll endpoint can answer "should this user see the banner?" in a single query, keeping the frontend logic trivial. Upholds *Principle 9 — Make illegal states unrepresentable* (the "dismissed for this user" fact lives exactly once, in the authoritative store) and *Principle 4 — Get the data model right* (data outlives code; client storage is reconstructable, but this fact is not).
- **Alternatives considered:** `localStorage` — fails cross-device; cookie — fails cross-device and is awkward for multi-workspace setups; per-user JSON blob in user profile row — violates high-cohesion (dismissal data embedded in an unrelated record).
- **Trade-off accepted:** The dismissals table can grow large in workspaces with many users and frequent banner rotation. This is mitigated by scoping the index to `(announcement_id, user_id)` and adding an archival/cleanup job (see §7).

### D2. One-active-banner invariant enforced at the database layer

- **Decision:** The `workspace_announcements` table has a partial unique index on `(workspace_id) WHERE status = 'active'`, ensuring at most one active announcement per workspace at the DB level, not just in application logic.
- **Why:** The blueprint's deviation scenario states "most recent publish wins." A race between two admins publishing simultaneously must produce exactly one winner; the DB constraint makes the illegal state unrepresentable without application-level locks. Upholds *Principle 9 — Make illegal states unrepresentable* and *Principle 3 — High cohesion, loose coupling* (the invariant lives at the layer that owns it).
- **Alternatives considered:** Application-level transaction (SELECT + UPDATE + INSERT) — vulnerable to TOCTOU race between concurrent publishes even inside a transaction at the default READ COMMITTED isolation level; a `status` enum with no DB constraint — relies entirely on correct application logic, which has been wrong before.
- **Trade-off accepted:** The partial unique index requires Postgres 9.5+ (assumed satisfied by any current deployment). The "publish replaces old" operation requires two steps: UPDATE the previous active row to `status = 'archived'`, then INSERT the new one — wrapped in a single transaction. A partial-unique-index constraint violation on concurrent publish is surfaced as a 409 to the losing admin ("Another banner was just published; please reload").

### D3. Frontend fetches the active banner by short-polling (not SSE or WebSocket)

- **Decision:** The `AnnouncementBanner` React component polls `GET /api/announcements/active` every 30 seconds. No server-sent events or WebSocket channel is added.
- **Why:** Banners are low-frequency, low-urgency state. The blueprint says users see the banner "within a short time" — 30-second latency is acceptable for an admin announcement. SSE or WebSocket would add infrastructure complexity (connection management, reconnect logic, load-balancer keepalive config) for a feature that fires perhaps once a day. Upholds *Principle 1 — Simplicity first / YAGNI* and *Principle 14 — Principle of least surprise* (polling is the established pattern for slow-changing state in this app).
- **Alternatives considered:** SSE — real-time delivery, but requires persistent connections and complicates horizontal scaling; WebSocket — same concerns, even heavier; long-polling — slightly more complex than plain polling with marginal benefit at this update frequency.
- **Trade-off accepted:** Up to 30 seconds between a publish and a user seeing the banner. Acceptable per the blueprint ("within a short time"). The poll interval is configurable via an env var (`ANNOUNCEMENT_POLL_INTERVAL_MS`, default 30 000) so it can be tuned without a deploy.

### D4. The poll endpoint is workspace-scoped and user-aware (single combined query)

- **Decision:** `GET /api/announcements/active` authenticates the caller, resolves their workspace, and returns a single JSON object: the active banner (if any) plus a `dismissed: boolean` field computed by checking `announcement_dismissals`. The client renders or suppresses the banner from this one response.
- **Why:** Avoids a second client-side request for dismissal state, keeps all "should this user see the banner?" logic in one place, and makes the response trivially cacheable at the edge for the common case (no active banner). Upholds *Principle 3 — High cohesion, loose coupling* (one seam, one contract) and *Principle 10 — Observability from day one* (one endpoint to monitor for errors).
- **Alternatives considered:** Two endpoints (banner content + dismissal check) — double the requests, requires client orchestration; embedding dismissal in user-profile fetch — couples unrelated concerns.
- **Trade-off accepted:** If the workspace has no active banner, the response is a lightweight `{ banner: null }` — still a round-trip. Mitigated by the 30-second poll interval; the absolute request volume is negligible.

### D5. Admin writes are synchronous (no background job)

- **Decision:** Publish, edit, and remove operations complete synchronously in the request/response cycle. No job queue or worker is involved.
- **Why:** The operations are cheap DB writes (one or two row mutations). There is no fan-out, no notification dispatch, and no expensive computation. Adding a queue would add a moving part with no benefit. Upholds *Principle 1 — Simplicity first / YAGNI*.
- **Alternatives considered:** Background job — justified only if the write needed to fan out to many users synchronously (e.g., push notifications), which it does not; the poll-based fetch model means no fan-out is needed.
- **Trade-off accepted:** None material. The synchronous write either succeeds or returns an error immediately, which is the best UX for the admin.

### D6. Start/end date filtering applied server-side at query time

- **Decision:** `GET /api/announcements/active` filters by `starts_at <= NOW() AND (ends_at IS NULL OR ends_at > NOW())` in the SQL query. No scheduled job flips a `status` column at banner expiry time.
- **Why:** A scheduled job would add cron infrastructure and introduce a gap between the scheduled expiry and the job execution. Filtering in the query is simpler, always correct, and consistent. Upholds *Principle 1 — Simplicity first / YAGNI* and *Principle 9 — Make illegal states unrepresentable* (the banner's effective window is a derived fact from the timestamps, not a separate mutable flag).
- **Alternatives considered:** Background job that sets `status = 'expired'` on a schedule — adds infra, introduces a race window, requires the job to be idempotent and monitored; client-side expiry check — requires the client to receive and trust server time, complicates clock-skew handling.
- **Trade-off accepted:** The `status` column is useful for admin UI queries ("show me past banners") and for the partial unique index (D2), but it does not gate visibility — `starts_at`/`ends_at` are the authority. On "Remove" the admin explicitly sets `status = 'removed'` and `ends_at = NOW()`. This keeps both the invariant index and the time-window query correct simultaneously.

---

## 4. Data Model & Persistence

### Table: `workspace_announcements`

```sql
CREATE TABLE workspace_announcements (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id    UUID        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    message         VARCHAR(200) NOT NULL CHECK (char_length(message) BETWEEN 1 AND 200),
    link_url        TEXT,                       -- optional; validated as a URL at app layer
    starts_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at         TIMESTAMPTZ,               -- NULL = no expiry
    status          TEXT        NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'archived', 'removed')),
    created_by      UUID        NOT NULL REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforce one active banner per workspace at the DB layer (D2)
CREATE UNIQUE INDEX uix_workspace_announcements_one_active
    ON workspace_announcements (workspace_id)
    WHERE status = 'active';

-- Fast lookup for the active-banner poll (D4, D6)
CREATE INDEX ix_workspace_announcements_active
    ON workspace_announcements (workspace_id, starts_at, ends_at)
    WHERE status = 'active';
```

**Invariants:**
- `ends_at > starts_at` enforced at the application layer on write (validated in the route handler); the DB stores whatever is passed, so a constraint can also be added: `CHECK (ends_at IS NULL OR ends_at > starts_at)`.
- At most one row with `status = 'active'` per `workspace_id` (partial unique index).
- `message` is capped at 200 characters (matches blueprint).

**"Publish replaces old" transaction:**
```
BEGIN;
  UPDATE workspace_announcements
     SET status = 'archived', updated_at = NOW()
   WHERE workspace_id = $1 AND status = 'active';
  INSERT INTO workspace_announcements (...) VALUES (...);
COMMIT;
```
If two concurrent publishes race, the second INSERT hits the partial unique index and throws a unique-violation error, which is surfaced as HTTP 409.

### Table: `announcement_dismissals`

```sql
CREATE TABLE announcement_dismissals (
    announcement_id UUID        NOT NULL REFERENCES workspace_announcements(id) ON DELETE CASCADE,
    user_id         UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dismissed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (announcement_id, user_id)
);
```

**Invariants:**
- Composite PK prevents duplicate dismissals from double-clicks / retry storms.
- `ON DELETE CASCADE` from `workspace_announcements` keeps the dismissals table tidy when banners are hard-deleted (for GDPR / data-retention purposes).

### Migration shape

Two `UP` migrations, one `DOWN` each:
1. `create_workspace_announcements` — table + indexes.
2. `create_announcement_dismissals` — table.

No backfill required (new feature, no existing data). Both migrations are non-destructive and reversible.

### Retention

Archived/removed announcements and their dismissal records are retained indefinitely by default (they are useful for audit). A soft-delete model (`status = 'removed'`) is already in place. If retention must be bounded, add a scheduled cleanup job that deletes rows where `ends_at < NOW() - INTERVAL '90 days'` — this is flagged as a follow-up (see §13).

---

## 5. External Services & Integration Contracts

No external services. All data is stored in the existing platform Postgres database. No third-party APIs, email services, or push-notification providers are involved.

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| *None* | — | — | — | — | — |

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| GET /api/announcements/active (poll) | < 20 ms | < 80 ms | Simple indexed SELECT + LEFT JOIN on small tables |
| POST /api/admin/announcements (publish) | < 100 ms | < 300 ms | Two-row transaction |
| POST /api/announcements/:id/dismiss | < 50 ms | < 150 ms | Single INSERT with composite PK upsert |
| PATCH /api/admin/announcements/:id (edit) | < 100 ms | < 300 ms | Single UPDATE |

### Expected load

- One active banner at a time per workspace; banners are updated at most a few times per day.
- Poll frequency: one request per active user every 30 seconds. For a workspace with 1 000 concurrent users: ~33 requests/second against one endpoint. For 10 000 users: ~333 req/s. Both are trivially handleable by the existing Express + Postgres stack.
- Dismiss: at most one dismissal per user per banner; burst occurs when a banner is first shown (everyone dismisses within the first few minutes). Peak burst at 1 000 users: ~17 dismissals/second — well within Postgres's write capacity.

### Caching

| What | Where | TTL | Invalidation | Trade-off |
|---|---|---|---|---|
| `GET /api/announcements/active` response | **No shared cache added** (see note) | — | — | Each poll hits Postgres; query is cheap (< 5 ms on indexed tables) |

**Note on caching:** A shared cache (Redis) for the active-banner response could reduce DB load further, but given the load numbers above the DB query is cheap enough that adding a cache layer would add operational complexity (cache invalidation on publish/remove, Redis dependency) without a measurable benefit at current scale. If the workspace grows to 100 000+ concurrent users, introduce a short (10–15 s) Redis TTL on the active-banner payload keyed by `workspace_id`, invalidated on every publish/edit/remove. This is flagged as a scaling trigger in §13.

**Freshness trade-off explicitly accepted:** Short-poll at 30 s means users may see a banner up to 30 s after it goes live. This is consistent with the blueprint's "within a short time" language. No stricter freshness guarantee is given.

---

## 7. Reliability & Failure Handling

### Failure scenarios

| Failure | User-visible behavior | Handling |
|---|---|---|
| Postgres unavailable during poll | Banner silently absent (component renders nothing) | Poll catches the error, logs it, returns `{ banner: null }` — UI degrades gracefully; users don't see an error for a non-critical display widget |
| Postgres unavailable during dismiss | Dismiss request fails; banner stays visible | HTTP 503 returned; client shows a transient toast "Could not save dismissal, please try again"; banner reappears on next poll until dismissed successfully |
| Postgres unavailable during admin publish | Admin sees a clear error message; no banner is published | HTTP 503 returned with user-facing message "Could not publish banner — please try again" |
| Concurrent publish (two admins) | Losing admin sees HTTP 409 | App layer catches unique-violation, returns 409 with message "Another banner was just published. Reload to see it." |
| `ends_at` in the past by the time the poll runs | Banner naturally absent (query filters it out) | No action needed; handled by D6 |

### Idempotency

- **Dismiss:** `INSERT INTO announcement_dismissals … ON CONFLICT (announcement_id, user_id) DO NOTHING` — safe to retry; double-taps and network retries are harmless.
- **Publish:** Idempotent within a transaction; the unique-index constraint ensures exactly one active row. A retry of a failed publish (after a network timeout) should include an idempotency key (suggested: `X-Idempotency-Key` header, checked against a short-lived in-memory or Redis set) to prevent accidental double-publish. Flagged as a follow-up in §13.

### Retries & timeouts

- Client poll: on fetch error, back off to 60 s for the next attempt (exponential back-off with max 5 min), then resume normal 30 s cadence on success. No visible error shown to the user (banner widget is non-critical).
- Dismiss: one automatic retry after 2 s on network error; if it still fails, surface the toast and let the user retry manually.
- Admin write routes: no automatic client retry (the admin can see the error and retry explicitly).

### Archival / cleanup

Dismissed records accumulate over time. A lightweight cleanup job (or scheduled SQL) should periodically hard-delete `workspace_announcements` rows (and their dismissals via cascade) that have `status IN ('archived', 'removed') AND updated_at < NOW() - INTERVAL '90 days'`. This is low-urgency — it does not affect correctness, only table size.

---

## 8. Security & Privacy

### Authorization

- **Admin writes** (`POST`, `PATCH`, `DELETE` on `/api/admin/announcements`): protected by the existing admin-role middleware. Any request without a valid session token scoped to `workspace_admin` or equivalent is rejected with HTTP 403 before the handler runs.
- **User reads** (`GET /api/announcements/active`): requires a valid authenticated session (any role). Unauthenticated requests return 401.
- **Dismiss** (`POST /api/announcements/:id/dismiss`): requires authentication; the dismissal is recorded for `req.user.id`, never for a user ID supplied by the client.

### Input validation

| Field | Validation | Where |
|---|---|---|
| `message` | Non-empty string, max 200 characters, plain text (no HTML/markdown parsed — treat as raw text) | Route handler, before DB write |
| `link_url` | Optional; if present, must be a well-formed `https://` URL; reject other schemes to prevent `javascript:` injection | Route handler using a URL-parsing check |
| `starts_at` / `ends_at` | Valid ISO 8601 timestamps; `ends_at > starts_at` if both provided | Route handler |
| `workspace_id` | Taken from the authenticated session — never from the request body | Middleware |

**XSS mitigation:** The banner message is stored as plain text and rendered via React's text interpolation (`{banner.message}`) — never `dangerouslySetInnerHTML`. The `link_url` is rendered as an `<a href={banner.linkUrl}>` attribute; React escapes it, and the server-side URL validation (https-only) prevents `javascript:` payloads.

### Least privilege

The dismiss endpoint writes only to `announcement_dismissals`; it cannot modify announcement text, status, or any other user's data. The banner query returns only fields needed for display (`id`, `message`, `link_url`); it does not expose `created_by`, internal IDs of other users, or workspace configuration.

### PII

`created_by` (user UUID) is stored in `workspace_announcements` for audit. It is not returned to non-admin callers. No banner message is expected to contain PII by design; no special handling is required beyond standard data-retention policy.

### Abuse vectors (from blueprint adversarial scenarios)

- **Non-admin publish via crafted request:** blocked by the admin-role middleware check described above — the check happens before any business logic.
- **Banner message as stored XSS:** mitigated by plain-text storage + React text interpolation (see XSS mitigation above).
- **Link URL as `javascript:` payload:** blocked by server-side URL scheme validation.

---

## 9. Observability

### Logs

- **Structured log on every banner publish/edit/remove:** `{ event: "announcement.published" | "announcement.edited" | "announcement.removed", workspace_id, announcement_id, admin_user_id, message_length }` — no banner text in the log to avoid accidental PII/sensitive-content leakage.
- **Error log on DB failure** in the poll endpoint: include `workspace_id` and error details.

### Metrics

| Metric | Type | Why |
|---|---|---|
| `announcement_poll_requests_total` (labeled `workspace_id`, `result: hit|miss|error`) | Counter | Volume and error rate of poll endpoint |
| `announcement_dismiss_total` (labeled `result: ok|error`) | Counter | Confirm dismissals are landing |
| `announcement_publish_total` (labeled `result: ok|conflict|error`) | Counter | Admin usage and concurrent-publish rate |
| `announcement_active_age_seconds` | Gauge (per workspace) | How long the current banner has been active |

### Alerts

| Alert | Condition | Severity |
|---|---|---|
| Poll endpoint error rate high | `error` label > 1 % of poll requests over 5 min | Warning |
| Dismiss error rate high | `error` result > 5 % over 5 min | Warning |

### Health signal

**The one signal that proves the feature is healthy:** `announcement_poll_requests_total{result="error"}` stays at zero. If the poll endpoint is returning errors, users are not seeing the banner — the most visible part of the feature.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a flag `announcement_banner_enabled` (default: `false`). The flag controls:
- Whether the admin "Announcements" page is visible in the settings nav.
- Whether the `AnnouncementBanner` component mounts in the app shell.
- Whether the backend routes respond (they return 404 when the flag is off, to prevent accidental data creation).

**Fail-closed:** if the flag service is unavailable, default to `false` (feature off). Banner absence is a graceful degradation; showing an unintended banner would be more disruptive.

### Deploy order

1. **Run DB migrations** (create tables + indexes). The tables are new and unused; this is safe to run ahead of code deploy.
2. **Deploy backend** (new routes appear; flag is `false` by default — routes exist but return 404).
3. **Deploy frontend** (new component and settings page behind the flag; renders nothing while flag is off).
4. **Enable flag** for a test workspace, verify end-to-end behavior.
5. **Gradual rollout**: enable for increasing % of workspaces, monitor poll error rate and dismiss error rate.
6. **Full rollout**: flip flag to `true` globally.

### Reversibility

- **Flag off** is the immediate rollback: all user-visible changes disappear instantly. No data is lost; existing announcements remain in the DB.
- **DB rollback:** running the `DOWN` migrations drops the two new tables. Only needed if the schema itself is problematic; the flag provides a sufficient operational escape hatch for most incidents.
- **No breaking changes to existing endpoints or tables.** This is purely additive.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | The app runs Node/Express on top of Postgres; there is an existing admin-role middleware that gates routes by role | Stated in the task description; consistent with the blueprint's "only admins can create/edit/remove" requirement | No |
| A2 | The existing auth system provides `req.user.id` and `req.user.workspaceId` (or equivalent) on authenticated requests | Standard shape for this stack; banner queries are workspace-scoped | No |
| A3 | `gen_random_uuid()` (pgcrypto) is available on the Postgres instance | Available by default in Postgres 13+; widely used in this class of app | Low — confirm Postgres version |
| A4 | The React frontend uses a standard `fetch`/`axios` data-fetching pattern; no GraphQL layer is in place for this feature | Generic assumption for Node/Express + React stack; no GraphQL mentioned | Low |
| A5 | 30-second poll latency for banner appearance is acceptable ("within a short time" per blueprint) | Blueprint text is permissive; no sub-second requirement stated | No |
| A6 | Plain-text display (no markdown, no HTML rendering) is correct for the message field | Blueprint says "plain text"; no rich-text formatting needed | No |
| A7 | A feature-flag system exists (env var or simple DB toggle is sufficient if no dedicated system is in place) | Standard for this class of app; even a single env var satisfies the rollout requirement | Low — confirm flag mechanism |
| A8 | No email or push-notification delivery of banners is required | Blueprint mentions no notification; users see the banner by opening the app | No |
| A9 | Workspace UUIDs and user UUIDs are already the primary key shape used by existing tables | Standard for Node/Express + Postgres apps; needed for FK references | Low — confirm UUID vs integer keys |
| A10 | No retention/GDPR policy mandates an expiry period shorter than the default 90-day cleanup suggested in §7 | No policy requirement mentioned; 90 days is a conservative reasonable default | Low — confirm with data team |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Short-polling at 30 s instead of SSE/WebSocket | Real-time delivery; users may see banner up to 30 s late | *Principle 1 — Simplicity first / YAGNI* (polling is simpler; SSE/WebSocket would be "building for an imagined future") | Blueprint says "within a short time," not "immediately"; banners are low-urgency admin announcements | If product requirement changes to near-real-time (< 5 s) delivery |
| C2 | No shared cache (Redis) for the poll endpoint | Extra DB query per poll request; doesn't scale to very large user counts | *Principle 12 — Cost as a first-class constraint* (slightly higher DB load than necessary at scale) | Load analysis shows the DB query is cheap at current and near-future user counts; adding Redis would be over-engineering | If concurrent user count exceeds ~50 000 per workspace, or DB query latency degrades |
| C3 | No idempotency key on admin publish | Duplicate-publish on network retry is possible (though mitigated by the unique-index 409) | *Principle 6 — Idempotency & bounded operations* | Frequency is very low (admin action, not a hot path); the 409 response is user-visible and prompts the admin to verify before retrying | If publish duplication incidents are reported in production |
| C4 | Dismissal records are retained indefinitely (no automated cleanup) | Table grows unboundedly over time | *Principle 6 — Idempotency & bounded operations* (unbounded growth) | Scale is low (one dismissal row per user per banner); correctness is unaffected; cleanup is a follow-up task | When `announcement_dismissals` row count exceeds 10 M or DB storage becomes a concern |

---

## 13. Open Risks & Callouts

1. **Idempotency key for admin publish (see C3):** If the admin's publish request times out on the client side, a retry could (in theory) create a second banner if the first request succeeded silently. The unique-index constraint prevents two simultaneous active banners, but a scenario where the first succeeded and `status` was set to `'active'`, then an immediate network hiccup causes a retry, would result in a 409 rather than a silent duplicate — so correctness is preserved, but UX is mildly confusing. Consider adding `X-Idempotency-Key` support as a follow-up.

2. **Clock skew:** `starts_at`/`ends_at` filtering uses `NOW()` on the DB server. If the admin's browser clock is significantly skewed from the server clock, a banner set to "start now" might appear to not activate immediately. Mitigation: display the server's current time in the admin publish UI (or document that times are server-relative).

3. **Dismissals table growth (see C4):** Not a current concern but should be monitored. Add an index on `dismissed_at` if a cleanup job is implemented.

4. **`link_url` rendering:** The blueprint mentions an "optional link" but does not specify display text. Assumption: the link URL itself is the display text (or a fixed label like "Learn more"). If a separate link-label field is needed, the data model needs a `link_label VARCHAR(80)` column. This is a behavior question for the blueprint, flagged here.

5. **Concurrent admin edit race:** Two admins editing the active banner's text simultaneously will both write successfully (last-writer-wins at the DB level). This is consistent with the blueprint's deviation scenario ("most recent publish wins"), but text edits do not go through the publish-replaces path — they are a simple UPDATE. If this becomes a pain point, an optimistic-lock version column (`updated_at` as a precondition) can be added.

---

## 14. Out of Scope

Per the blueprint, the following are explicitly out of scope for this design:

- Rich text, markdown, images, or HTML in the banner message.
- Multiple simultaneous banners per workspace.
- Targeting a banner to a subset of users (role-based, group-based, etc.).
- Scheduling a recurring banner.
- Push notifications or email delivery of banner content.
- A banner history / audit log UI (the data is retained in the DB but no admin UI for past banners is designed here).
- Analytics on banner views or click-through rates.
- Multi-tenant isolation beyond the existing workspace model (assumed already in place).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets per action; poll < 20 ms p50 |
| A2 Throughput & scale | Resolved | §6 — load analysis; ~33 req/s at 1 000 concurrent users |
| A3 Concurrency & consistency | Resolved | D2 (partial unique index), D5 (sync writes), §7 (concurrent-publish 409) |
| A4 Availability & reliability | Resolved | §7 — failure modes table; graceful degradation for non-critical poll |
| A5 Data integrity & durability | Resolved | §4 — DB constraints, transaction for publish-replaces, CASCADE on delete |
| A6 Caching & freshness | Resolved | D3 (30-s poll), §6 (no shared cache; scaling trigger documented) |
| A7 Cost | Assumed (A2, A6) | No external services; DB queries are cheap; no incremental cloud cost |
| A8 Security & privacy | Resolved | §8 — admin-role middleware, input validation, XSS mitigation, least privilege |
| A9 Observability | Resolved | §9 — logs, metrics, alerts, and health signal |
| A10 Maintainability & simplicity | Resolved | D1–D6 all favor simplicity; fits existing Express + Postgres + React pattern |
| A11 Testability | Resolved | §4 seams (route handler, service layer, DB); dismiss is idempotent and deterministic; no external mocks needed |
| A12 Deployability & rollout | Resolved | §10 — feature flag, deploy order, reversibility |
| A13 Backward compatibility | Assumed (A1) | Purely additive (new tables, new routes); no existing contracts changed |
| A14 Accessibility & device/env | Resolved | §8 XSS note; banner is a standard React text + link component; keyboard-dismissible (`<button>` with `aria-label="Dismiss announcement"`); reduced-motion: CSS `transition` should respect `prefers-reduced-motion` |
| B1 Placement / module taxonomy | Resolved | §2 — admin Express router + app-level router; React app-shell component |
| B2 Data model & persistence | Resolved | §4 — two new tables, indexes, invariants, migration shape |
| B3 API surface & schemas | Resolved | §2 route table; §4 field-level schema; §8 input validation |
| B4 Async / background work | Resolved | D5 — all synchronous; no background job needed |
| B5 External services & contracts | N/A | No external services (§5) |
| B6 Frontend integration | Resolved | D3 (polling), D4 (combined response); §6 (poll interval as env var); §7 (client retry/back-off) |
| B7 Feature flags & rollout | Resolved | §10 — `announcement_banner_enabled` flag, fail-closed, staged rollout |
| B8 Error handling | Resolved | §7 — per-failure behavior; §8 — admin 403/401; D2 — concurrent-publish 409 |

---

## Appendix A: Captured Inputs

*This design was produced autonomously (no human interview was conducted). The following records the decisions that would have been put to the user in a P3 interview, the recommendation made, the resolution chosen autonomously, and the rationale. A human reviewer can challenge any item here.*

---

### Dismissal persistence: server-side vs client-side

- **Question:** Where should a user's dismissal be stored — server-side (Postgres) or client-side (localStorage/cookie)?
- **Recommendation given:** Server-side (new `announcement_dismissals` table). Dismissal must survive across devices and sessions per the blueprint; client storage cannot satisfy this. Upholds *Principle 9 — Make illegal states unrepresentable* and *Principle 4 — Get the data model right*.
- **Autonomous resolution:** Server-side. No alternative is compatible with the blueprint's cross-device requirement.
- **Notes:** This is the single most consequential data-model decision; the table design follows directly from it.

---

### One-active-banner invariant: DB constraint vs application logic

- **Question:** Should the "at most one active banner per workspace" invariant be enforced at the DB layer (partial unique index) or only in application code?
- **Recommendation given:** DB-layer partial unique index. Application logic is vulnerable to race conditions on concurrent publish; the DB is the authoritative source of truth. Upholds *Principle 9 — Make illegal states unrepresentable*.
- **Autonomous resolution:** Partial unique index on `(workspace_id) WHERE status = 'active'`. Concurrent-publish races surface as a 409 to the losing admin.
- **Notes:** The "most recent publish wins" deviation scenario in the blueprint guided this — a 409 is the correct behavior for the loser, not a silent overwrite.

---

### Banner delivery model: polling vs SSE vs WebSocket

- **Question:** How should the frontend learn that a new banner is available — short-polling, server-sent events, or WebSocket?
- **Recommendation given:** Short-polling every 30 seconds. The blueprint says "within a short time" (no real-time requirement); SSE/WebSocket adds infrastructure complexity for very low update frequency. Upholds *Principle 1 — Simplicity first / YAGNI*.
- **Autonomous resolution:** Short-polling at 30 s (configurable via `ANNOUNCEMENT_POLL_INTERVAL_MS`).
- **Notes:** Would have asked the user: "Is 30-second delivery delay acceptable, or is there a tighter latency requirement for banner appearance?"

---

### Start/end date enforcement: scheduled job vs query-time filtering

- **Question:** Should banners expire via a background job that updates `status`, or via a `WHERE NOW() BETWEEN starts_at AND ends_at` filter in the query?
- **Recommendation given:** Query-time filtering. Simpler, always correct, no cron infrastructure needed. Upholds *Principle 1 — Simplicity first / YAGNI*.
- **Autonomous resolution:** Query-time filtering (D6). `status` column remains useful for admin queries but does not gate visibility.
- **Notes:** The `status` column is kept for the partial unique index and for admin history queries; it is not the source of truth for "is this visible now?"

---

### Shared cache for poll endpoint

- **Question:** Should the active-banner response be cached in Redis (or equivalent) to reduce DB load?
- **Recommendation given:** No cache at current scale. The query is cheap (indexed, small tables); adding Redis would add operational complexity without a measurable benefit. Upholds *Principle 1 — Simplicity first / YAGNI* and *Principle 8 — Measure, don't guess*.
- **Autonomous resolution:** No shared cache. Scaling trigger documented: introduce Redis cache if concurrent user count exceeds ~50 000 per workspace (see C2, §13).
- **Notes:** Would have confirmed current and projected user counts with the user to validate this threshold.

---

### Feature flag behavior: fail-open or fail-closed

- **Question:** If the feature-flag service is unavailable, should the banner feature default to on (fail-open) or off (fail-closed)?
- **Recommendation given:** Fail-closed (feature off). A missing banner is a graceful degradation; an unintended banner (e.g., an old one re-appearing) could be more disruptive.
- **Autonomous resolution:** Fail-closed (§10).
- **Notes:** Standard safety posture for display-only features gated by flags.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** *No human available. The following items were self-identified as worth flagging:*
  - `link_url` display text: blueprint says "optional link" but doesn't specify a label field. If a separate label is needed, the schema requires an additional column. Flagged in §13.
  - Idempotency key on admin publish: not critical but worth a follow-up (§13, C3).
  - Retention/GDPR policy for old dismissal records: assumption made (90-day default); needs confirmation with the data team (A10).
  - Postgres UUID support (`gen_random_uuid`): minor assumption on Postgres version (A3).
