# System Design: Admin Announcement Banner

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./announcement-banner-blueprint.md](../../../../inputs/announcement-banner-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The announcement banner is a thin CRUD feature sitting inside the existing admin settings service on the backend and rendered via a React component pinned to the app shell on the frontend. The single most important architectural choice is **server-authoritative banner state with short-TTL polling**: the frontend fetches the active banner (and per-user dismissal state) from a lightweight REST endpoint on every page load plus a background interval, rather than pushing state via WebSocket. This keeps the implementation to two new database tables, three API routes, and one React context provider — no new infrastructure, no queue, no real-time layer. Dismissal is stored server-side (not in localStorage) so it persists across devices and sessions as required by the blueprint.

---

## 2. System Placement

This feature is a **standard HTTP Service** — a thin service layer backed by Postgres, exposed via REST API routes, consumed by the React frontend. It touches no agent, LLM, background worker, or external third-party service.

**Components touched:**

- **Backend — new module:** `announcements` service (under the admin settings service namespace)
  - Two new Postgres tables: `announcement_banners` and `banner_dismissals`
  - Three new REST routes (admin-gated write routes + one authenticated read route)
- **Frontend — new component:** `AnnouncementBanner` React component added to the app shell layout
  - `AnnouncementContext` provider wraps the shell; fetches from the read endpoint
  - `AdminAnnouncementsPage` component for the admin settings UI

**Data flow:**

```
Admin UI
  → POST /api/admin/banners          (publish / replace active banner)
  → PATCH /api/admin/banners/:id     (edit text)
  → DELETE /api/admin/banners/:id    (remove early)

App shell (all users)
  → GET /api/banners/active          (fetch active banner + own dismissal state)
  ← { banner: {...} | null, dismissed: bool }

User dismisses
  → POST /api/banners/:id/dismiss    (write dismissal record)
```

---

## 3. Architecture Decisions

### D1. Single active banner enforced at the database level

- **Decision:** A `is_active` boolean column with a **partial unique index** (`WHERE is_active = TRUE`) on `(workspace_id, is_active)` ensures at most one active banner per workspace at any time. Publishing a new banner deactivates the previous one in the same transaction.
- **Why:** Encodes the "at most one active banner" invariant in the schema rather than relying on application logic (Principle 9 — make illegal states unrepresentable; Principle 4 — get the data model right). A runtime check can be bypassed; a unique constraint cannot.
- **Alternatives considered:**
  - *Application-layer enforcement only:* cheaper to write, but a bug or race could leave two rows active. Rejected — the invariant is too load-bearing to leave unguarded.
  - *Soft-delete + `published_at` ordering:* treat the latest published row as "active" with no flag; simpler schema but makes reads more complex and the "remove early" operation harder to model cleanly.
- **Trade-off accepted:** Requires a partial index (supported in Postgres; not universally portable, but this stack is Postgres-only).

### D2. Publish replaces the previous banner in a single transaction

- **Decision:** The `POST /api/admin/banners` handler opens a transaction, sets `is_active = FALSE` on any existing active banner for the workspace, then inserts the new banner with `is_active = TRUE`.
- **Why:** Eliminates the window where zero or two banners are active concurrently (Principle 3 — high cohesion, loose coupling; Principle 6 — idempotency and bounded operations). This is the natural implementation of "publishing a new one replaces the previous active banner."
- **Alternatives considered:**
  - *Two separate calls (deactivate then insert):* exposes a gap where no banner is active, and is not atomic — a crash between steps leaves stale state.
- **Trade-off accepted:** The transaction is a short, locked write; contention risk is negligible at this feature's scale.

### D3. Dismissal stored server-side (Postgres), not in localStorage

- **Decision:** A `banner_dismissals` table records `(user_id, banner_id)` pairs. The read endpoint checks this table to decide whether to return `dismissed: true`.
- **Why:** The blueprint requires dismissal to persist across devices and sessions. localStorage is per-device and per-origin — it cannot satisfy that requirement (Principle 9 — encode invariants; Principle 4 — data model correctness). Server-side dismissal also means the dismissal survives session clearing and incognito tabs.
- **Alternatives considered:**
  - *localStorage / cookie:* fails the cross-device requirement. Rejected.
  - *`dismissed_user_ids` array column on the banner:* simple but unbounded; scales poorly as a workspace grows (Principle 6 — bounded operations). Rejected.
- **Trade-off accepted:** One extra table and one extra DB read on every banner fetch. Acceptable — this table is small and the query is indexed.

### D4. Dismissal sticks to banner_id, not banner text

- **Decision:** `banner_dismissals` records the `banner_id` (the row PK), not a hash of the text. Editing a banner's text does not change its `banner_id`, so dismissal records are preserved through an edit.
- **Why:** The blueprint is explicit: "an admin edits the active banner's text; an edit does **not** bring it back for users who already dismissed it." Tying dismissal to identity (ID) rather than content satisfies this rule naturally (Principle 9).
- **Alternatives considered:**
  - *Re-key on text hash:* editing text changes the hash, implicitly un-dismissing for all users — exactly the wrong behavior.
- **Trade-off accepted:** None materially. The natural choice.

### D5. Frontend polls for active banner with a short TTL; no WebSocket push

- **Decision:** `AnnouncementContext` fetches `GET /api/banners/active` on mount and then every 60 seconds (configurable). No WebSocket or SSE channel is opened.
- **Why:** The blueprint states "within a short time, every user sees the banner" — it does not require instant propagation. Polling at 60 s delivers adequate freshness with zero new infrastructure (Principle 1 — simplicity first / YAGNI; Principle 2 — match existing patterns). The feature's scale (one banner per workspace, low write frequency) does not justify the operational cost of a persistent connection layer.
- **Alternatives considered:**
  - *WebSocket / SSE push:* sub-second delivery, but requires either a new pub/sub infrastructure or extending an existing one. The blueprint's "within a short time" wording does not warrant the complexity. Rejected.
  - *Poll on every route change only (no interval):* delivers the banner eventually but misses the case where a user stays on a long-lived page. Rejected.
- **Trade-off accepted:** A user who has the app open at publish time will see the banner within up to 60 seconds, not immediately. Acceptable given the blueprint's wording. See Accepted Compromises C1.

### D6. Read endpoint combines active-banner lookup and per-user dismissal check in one response

- **Decision:** `GET /api/banners/active` returns `{ banner: BannerObject | null, dismissed: boolean }` in a single call. The backend joins `banner_dismissals` for the requesting user.
- **Why:** Avoids a second round-trip from the client (Principle 1 — fewer moving parts). The two pieces of data are always needed together; separating them adds latency and coordination complexity.
- **Alternatives considered:**
  - *Two endpoints (GET /api/banners/active + GET /api/banners/:id/dismissed):* doubles the round-trips for every poll cycle. Rejected.
- **Trade-off accepted:** The endpoint is user-context-sensitive (requires auth); it cannot be publicly cached at a CDN layer. Acceptable — the response payload is tiny and the DB query is fast.

### D7. Admin routes are separate from the user-facing read route

- **Decision:** Write routes (`POST`, `PATCH`, `DELETE`) live under `/api/admin/banners` and are gated by admin-role middleware. The read route lives under `/api/banners/active` and requires only authentication (any workspace member).
- **Why:** Least-privilege separation — non-admins cannot reach write routes even if they craft requests manually (Principle 11 — security and privacy by design; blueprint adversarial scenario: "A non-admin must not be able to publish a banner by crafting a request"). Separate URL namespaces also make the authorization rules unambiguous.
- **Alternatives considered:**
  - *Single endpoint with role-based branching inside:* harder to audit, easier to introduce a privilege-escalation bug. Rejected.
- **Trade-off accepted:** Two route registrations instead of one; minimal overhead.

### D8. Start/end date window enforced at the read endpoint, not via a background job

- **Decision:** `GET /api/banners/active` applies `WHERE start_at <= NOW() AND (end_at IS NULL OR end_at > NOW())` in its query. No cron job toggles banner state.
- **Why:** Eliminates a class of bugs where a background job fails to run and a banner stays live past its end date (Principle 5 — design for failure; Principle 1 — simplicity first). The window is always evaluated at read time against a real clock; the system can't drift.
- **Alternatives considered:**
  - *Background cron that flips `is_active = FALSE` at end_at:* adds a scheduler dependency and a failure mode where a banner stays live if the job is late. Rejected.
- **Trade-off accepted:** The DB query is slightly more complex (date filter), and `is_active = TRUE` no longer means "currently visible" without also checking the window. This is mitigated by the data model's single query path; the read endpoint is the only place the visibility logic lives (Principle 3 — cohesion).

---

## 4. Data Model & Persistence

### Table: `announcement_banners`

```sql
CREATE TABLE announcement_banners (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id  UUID          NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  message       VARCHAR(200)  NOT NULL,
  link_url      TEXT          ,             -- optional URL from blueprint "optional link"
  link_label    TEXT          ,             -- optional link display text
  start_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  end_at        TIMESTAMPTZ   ,             -- NULL means "no end date"
  is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
  created_by    UUID          NOT NULL REFERENCES users(id),
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- At most one active banner per workspace (enforced at DB level)
CREATE UNIQUE INDEX uq_one_active_banner_per_workspace
  ON announcement_banners (workspace_id)
  WHERE is_active = TRUE;

-- Fast lookup of the active banner for a workspace
CREATE INDEX idx_banners_workspace_active
  ON announcement_banners (workspace_id, is_active, start_at, end_at);
```

**Invariants:**
- `message` is capped at 200 characters (matches blueprint).
- `end_at > start_at` enforced by a CHECK constraint (blueprint: "end date before start date is rejected").
- At most one row with `is_active = TRUE` per `workspace_id` (partial unique index).
- `link_url` and `link_label` are both nullable; if `link_url` is set, `link_label` defaults to the URL itself in the application layer.

```sql
ALTER TABLE announcement_banners
  ADD CONSTRAINT chk_end_after_start
  CHECK (end_at IS NULL OR end_at > start_at);
```

### Table: `banner_dismissals`

```sql
CREATE TABLE banner_dismissals (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  banner_id  UUID        NOT NULL REFERENCES announcement_banners(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  dismissed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (banner_id, user_id)
);

-- Lookup: has this user dismissed this banner?
CREATE INDEX idx_dismissals_banner_user
  ON banner_dismissals (banner_id, user_id);
```

**Invariants:**
- `(banner_id, user_id)` is unique — one dismissal record per user per banner; duplicate dismiss requests are idempotent (upsert / ignore on conflict).
- `ON DELETE CASCADE` from both `announcement_banners` and `users` — no orphaned dismissal rows.

### Migration shape

Two new migrations:
1. `create_announcement_banners` — table + indexes + check constraint.
2. `create_banner_dismissals` — table + unique constraint + index.

Both are additive (no existing tables modified). Rollback: drop both tables.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| None | This feature has no third-party integrations | — | — | — | — |

N/A — the announcement banner requires no external service. All data is stored and served from the application's own Postgres instance.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| `GET /api/banners/active` (poll) | < 50 ms | < 150 ms | Single indexed query + one join; no heavy computation |
| `POST /api/admin/banners` (publish) | < 200 ms | < 500 ms | Transaction with two writes (deactivate + insert) |
| `POST /api/banners/:id/dismiss` | < 100 ms | < 300 ms | Single upsert |
| `PATCH /api/admin/banners/:id` | < 200 ms | < 400 ms | Single row update |

### Expected load

- At most one active banner per workspace; write frequency is very low (admins publish/edit rarely).
- Read frequency: each user polls every 60 seconds. At 10,000 concurrent users, that is ~167 requests/second — all hitting a single indexed query. Well within standard Postgres capacity.
- Dismissal writes are fire-once per user per banner; no sustained write pressure.

### Caching

The `GET /api/banners/active` response is **not cached** at the application layer (see D6 — it is user-context-sensitive). The database query is indexed and fast; adding a shared cache would require per-user cache keying or a separate "banner changed" invalidation signal — complexity not warranted at this scale (Principle 1 — YAGNI; Principle 13 — answer all five before adding a cache).

**Cache answer for Principle 13:**
- *What:* Nothing is application-level cached.
- *Where:* N/A.
- *TTL:* N/A.
- *Invalidation:* N/A.
- *Freshness-vs-cost trade-off:* The 60-second poll interval is the freshness knob. Up to 60 s stale is accepted. The trade-off: no cache complexity, at the cost of ~167 DB reads/second at 10k users. Acceptable.

### Concurrency

The partial unique index prevents two concurrent publishes from leaving two active banners — the second transaction will get a unique-constraint violation and the application should return a 409 (the last publish wins; if two admins publish simultaneously, one will receive an error and can retry).

---

## 7. Reliability & Failure Handling

### Failure modes

| Failure | User experience | Handling |
|---|---|---|
| DB unavailable during poll | Banner not visible / stale for poll interval | Client catches error silently; last known state is retained. No user-visible error — absence of banner is a normal state. |
| DB unavailable during publish | Admin sees an error message | 500 returned; admin retried manually. Transaction rolled back. |
| DB constraint violation on concurrent publish | Second admin gets a 409 | Client surfaces "Another banner was published while you were editing. Please refresh." |
| DB unavailable during dismiss | Dismiss fails silently on retry; banner may re-appear after next poll | Dismiss is best-effort: UI hides the banner optimistically; a background retry is attempted once. If the server never confirms, the banner may reappear on next page load. Acceptable edge case — not a data-loss scenario. |
| Dismiss duplicate request (user double-clicks) | No visible effect | Upsert (`ON CONFLICT DO NOTHING`) makes dismiss idempotent. |

### Retry policy

- **Admin writes (publish/edit/remove):** No automatic retry. The admin retries manually on a visible error. Automatic retry on admin mutations risks double-publish.
- **Dismiss POST:** Single silent retry after 2 s. After that, the UI keeps the banner hidden locally but does not try again until the next page load poll confirms state.
- **Poll GET:** No retry between intervals; the next poll fires in 60 s. Network errors are swallowed silently.

### Graceful degradation

If `GET /api/banners/active` errors, the app shell renders without a banner (fails silent). The app continues to function. This is safe because the banner is informational; its absence is not a blocking failure.

---

## 8. Security & Privacy

### Authorization

- **Write routes** (`POST`, `PATCH`, `DELETE` under `/api/admin/banners`): gated by admin-role middleware that verifies the authenticated user holds the `admin` role for the workspace. A non-admin request receives 403. This directly addresses the blueprint adversarial scenario: "A non-admin must not be able to publish a banner by crafting a request."
- **Read route** (`GET /api/banners/active`): requires authentication (any workspace member). Returns 401 for unauthenticated requests.
- **Dismiss route** (`POST /api/banners/:id/dismiss`): requires authentication; the `user_id` is taken from the session token, not from the request body — prevents a user from dismissing a banner on behalf of another user.

### Input validation

All inputs validated at the route layer before the service is called:

| Field | Validation |
|---|---|
| `message` | Required; max 200 characters; plain text (strip any HTML/Markdown); not empty after trimming |
| `link_url` | Optional; must be a valid URL if present (URL parse check); max 2048 characters |
| `link_label` | Optional; max 100 characters |
| `start_at` | Optional ISO-8601 datetime; defaults to `NOW()` |
| `end_at` | Optional ISO-8601 datetime; must be > `start_at` if provided (validated before DB) |
| `banner_id` (URL param) | Must be a valid UUID; route returns 404 if the banner does not belong to the requesting workspace |

**XSS:** `message` and `link_label` are rendered as plain text in the React component (`textContent` / React's default escaping), never as `dangerouslySetInnerHTML`. `link_url` is validated to be a legitimate URL and rendered as an `<a href>` — no `javascript:` URLs permitted (enforced by URL validation).

### Workspace isolation

All queries include `workspace_id` scoped from the authenticated user's session. An admin of workspace A cannot read, edit, or remove a banner belonging to workspace B.

### PII

The `banner_dismissals` table records `user_id` per banner. This is low-sensitivity workspace-internal data and is not exposed outside the workspace scope. No PII is stored in the banner itself (plain text message set by admin).

### Secrets

No secrets required. The feature uses the application's existing database connection and session auth.

---

## 9. Observability

### Logs

Structured log events:

| Event | Level | Fields |
|---|---|---|
| `banner.published` | INFO | `workspace_id`, `banner_id`, `admin_user_id`, `start_at`, `end_at` |
| `banner.edited` | INFO | `workspace_id`, `banner_id`, `admin_user_id` |
| `banner.removed` | INFO | `workspace_id`, `banner_id`, `admin_user_id` |
| `banner.dismissed` | INFO | `workspace_id`, `banner_id`, `user_id` |
| `banner.publish_conflict` | WARN | `workspace_id`, `admin_user_id` (concurrent publish collision) |
| `banner.validation_failed` | WARN | `workspace_id`, `admin_user_id`, `field`, `reason` |

### Metrics

| Metric | Type | Labels |
|---|---|---|
| `banner_active_fetches_total` | Counter | `workspace_id` (sampled — not per-workspace in prod if cardinality is high), `result` (hit/miss/error) |
| `banner_publishes_total` | Counter | `workspace_id` |
| `banner_dismissals_total` | Counter | `workspace_id` |
| `banner_fetch_duration_ms` | Histogram | `p50`, `p95`, `p99` |

### The one health signal

> **"Is the active-banner endpoint returning 200 within 150 ms p95?"**

A latency spike or error-rate rise on `GET /api/banners/active` is the single signal that the feature is degraded for users.

### Alerts

- Error rate on `GET /api/banners/active` > 1% for 5 minutes → page on-call.
- p95 latency on `GET /api/banners/active` > 500 ms for 5 minutes → notify.
- Any 5xx on admin write routes → notify (low-volume, high-visibility).

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a flag `announcement_banner_enabled` (boolean, default `false`). When disabled:
- The admin settings page does not render the Announcements section.
- The frontend poll does not fire.
- The API routes return 404 (or the route is simply not registered when the flag is off — preferred).

**Default state:** off. **Fail-closed** (flag unavailable → feature disabled). This is the safe default — an un-announced announcement is invisible, not broken.

### Rollout order

1. Deploy backend migrations (`announcement_banners`, `banner_dismissals` tables). Tables exist but are empty; no user impact.
2. Deploy backend routes (behind flag, which is `false`). Safe — routes are unreachable.
3. Deploy frontend bundle (banner component rendered conditionally on flag).
4. Enable flag for internal workspaces → smoke test.
5. Staged rollout: enable for N% of workspaces; monitor error rates and latency.
6. Full rollout.

### Reversibility

- **Flag off:** immediately stops all frontend activity and hides the admin page.
- **Schema rollback:** drop `banner_dismissals`, then drop `announcement_banners`. Both are new tables with no dependencies from existing tables (existing tables reference them via FK, but `ON DELETE CASCADE` is outward-only from workspaces/users). Reversible cleanly.

### No backward-compatibility risk

This is an entirely new feature with new tables and new routes. Existing API contracts and data shapes are not modified.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | The app already has a `workspaces` table and a `users` table with a workspace-membership relationship | Standard for a multi-tenant Node/Express + Postgres app; blueprint refers to "workspace admin" and "users in the workspace" | No — safe default for this stack |
| A2 | An admin-role middleware already exists and can be reused for the write routes | Blueprint mentions "workspace admin" as a defined role; most admin-settings pages already require this | No — safe default; if it doesn't exist, creating it is a dependency that must be flagged during implementation |
| A3 | The frontend has an app shell / layout component that wraps all pages and is the right place to render the banner | Blueprint says the banner appears "across the top of the app" for every user | Yes — the exact shell component should be confirmed during implementation |
| A4 | The stack uses a session token / JWT that includes `user_id` and `workspace_id` and is available server-side on each request | Standard for this class of app | No — safe default |
| A5 | Postgres partial unique indexes are supported (they are standard Postgres, not an extension) | Yes — standard Postgres feature | No |
| A6 | A 60-second poll interval is acceptable for "within a short time" as stated in the blueprint | Blueprint does not specify a tighter SLA; 60 s is a reasonable interpretation of "short time" for an informational banner | Yes — product team should confirm if a tighter window is needed |
| A7 | The optional link in the banner is a raw URL + optional label; no rich embed or preview is required | Blueprint says "plain text plus an optional link"; no richer behavior is described | No — out of scope per blueprint |
| A8 | No data-retention policy beyond the application's standard backup policy is needed for banners or dismissal records | Banner content is low-sensitivity; dismissal records are workspace-internal | No — safe default; can be revisited if compliance requirements surface |
| A9 | The feature flag system is already in place (the app can gate features by flag) | Standard for a mature Node/Express app; referenced in the rollout design | Yes — if no flag system exists, rollout is behind a deploy toggle instead |
| A10 | `gen_random_uuid()` (pgcrypto or pg 13+) is available for UUID generation | Common in Postgres 13+ apps | No — safe default; can fall back to `uuid_generate_v4()` with pgcrypto extension |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | 60-second poll instead of WebSocket push for banner delivery | Instant banner visibility; users may see the banner up to 60 s after publish | Principle 5 (design for failure / be explicit about freshness cost) | Blueprint says "within a short time" — not "instantly". The operational and infrastructure cost of a real-time push channel is not justified for an informational banner with low publish frequency | If the product requirement tightens to "within seconds", or if a real-time channel is added for other features (then free-riding on it is appropriate) |
| C2 | Dismiss fails silently after one retry; banner may reappear on next page load | Guaranteed dismissal durability | Principle 6 (idempotency — we attempt it but don't guarantee delivery) | Dismiss is a UI preference, not a business-critical write. A user seeing a dismissed banner once more is a minor UX degradation, not a data-loss or security issue | If user complaints about re-appearing banners surface, harden to a retry loop with local persistence fallback |
| C3 | `is_active` flag used alongside the date window; two admins publishing concurrently results in a constraint error (one must retry) | Zero-friction concurrent admin publishing | Principle 14 (least surprise — a 409 may surprise an admin) | Concurrent admin publishes are extremely rare; the blueprint's stated behavior is "most recent publish wins", and the constraint error + retry satisfies that | If concurrent publishing becomes a real use case (e.g., multiple admins posting in quick succession), introduce an optimistic-lock retry loop in the service layer |

---

## 13. Open Risks & Callouts

1. **App shell component identity (A3):** The exact React component that wraps every page and is the right mount point for the banner must be confirmed before implementation. Mounting in the wrong place could cause the banner to appear on some pages but not others, or to flash on navigation.

2. **Admin-role middleware existence (A2):** If no reusable admin-role middleware exists, it must be created as a dependency of this feature. Implementation planning should check this first.

3. **60-second poll at high workspace concurrency:** At very large workspace sizes (100k+ concurrent users), ~1,667 req/s on a single indexed query could become noticeable. At current scale this is fine; the metric `banner_active_fetches_total` should be monitored, and a shared cache (keyed by `workspace_id`, invalidated on publish/remove, TTL ≤ 60 s) added if the query load grows.

4. **`link_url` XSS surface:** The optional link URL is the one field that escapes plain-text rendering and becomes an `<a href>`. The URL validation (reject `javascript:`, `data:` schemes; require `http`/`https`) must be enforced both at the route layer and in the React component (`rel="noopener noreferrer"` on the anchor).

5. **Blueprint gap — link label behavior:** The blueprint says "plain text plus an optional link" but does not specify whether the link has a display label or always shows the raw URL. The data model supports `link_label` as optional; the product team should confirm the desired UX before the admin form is built.

---

## 14. Out of Scope

Per the blueprint's explicit "Out of scope" section, and as design constraints:

- Rich text, images, or HTML in the banner message.
- Multiple simultaneous active banners per workspace.
- Targeting a banner to a subset of users.
- Scheduling a recurring banner.
- Banner analytics (view counts, click-through rates).
- Per-banner notification emails or push notifications.
- Banner versioning or history/audit trail (beyond standard DB row history).
- Real-time / WebSocket push delivery (polling is the chosen approach per D5).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets per action; poll interval rationale |
| A2 Throughput & scale | Resolved | §6 — load estimate at 10k users; scale note in §13 |
| A3 Concurrency & consistency | Resolved | D1, D2, §6 — partial unique index + transactional publish; concurrent-publish 409 in §7 |
| A4 Availability & reliability | Resolved | §7 — failure modes, retry policy, graceful degradation |
| A5 Data integrity & durability | Resolved | §4 — constraints, CHECK, unique index, ON DELETE CASCADE; §7 — transaction boundaries |
| A6 Caching & freshness | Resolved | D5, §6 — no app-level cache; 60 s poll is the freshness knob; all five cache questions answered |
| A7 Cost | N/A | No third-party services; no per-call cost. Postgres query cost is negligible at this scale. |
| A8 Security & privacy | Resolved | D7, §8 — admin-role gate, input validation, workspace isolation, XSS mitigations |
| A9 Observability | Resolved | §9 — structured logs, metrics, health signal, alert thresholds |
| A10 Maintainability & simplicity | Resolved | D1–D8 all prefer existing patterns; two tables, three routes, one context — minimal surface area (Principle 1, 2) |
| A11 Testability | Resolved | Assumed (A4) — standard seams; see note below |
| A12 Deployability & rollout | Resolved | §10 — feature flag, staged rollout, migration order, reversibility |
| A13 Backward compatibility | Resolved | §10 — no existing tables or contracts modified; entirely additive |
| A14 Accessibility & device/env | Resolved (Assumed) | A14-note below |
| B1 Placement / module taxonomy | Resolved | §2 — new `announcements` service module under admin settings namespace |
| B2 Data model & persistence | Resolved | §4 — full schema, indexes, constraints, migration shape |
| B3 API surface & schemas | Resolved | §2 data flow + §8 input validation table |
| B4 Async / background work | Resolved | D5, D8 — no background jobs; date-window logic at read time; dismiss is synchronous |
| B5 External services & contracts | N/A | No external services (§5) |
| B6 Frontend integration | Resolved | D5, D6, §2, §7 (dismiss UX), §13 (shell mount point) |
| B7 Feature flags & rollout | Resolved | §10 — `announcement_banner_enabled` flag, default false, fail-closed |
| B8 Error handling | Resolved | §7 — per-failure table; constraint violation → 409; DB error → 500; dismiss failure → silent retry |

**A11 testability note:** The service layer is pure functions over a DB interface; the DB can be stubbed with a test Postgres instance or an in-memory mock. The poll interval is injectable (accept as a parameter) so tests can advance time. The dismiss endpoint is idempotent and trivially testable. No LLM or external service mocking is required.

**A14 accessibility note:** The banner component should be implemented with `role="banner"` or `role="alert"` (depending on urgency), keyboard-dismissible (`Escape` key or focus + `Enter` on the × button), and screen-reader-announced on appearance (`aria-live="polite"` for informational banners). The dismiss button must have an accessible label (e.g. `aria-label="Dismiss announcement"`). Mobile: the banner is a single-line strip that reflows naturally. These are implementation-time requirements; no architectural decision gates on them.

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Admin opens "Announcements" page in admin settings | Behavior | §2, D7 | Admin-gated settings page; admin routes under `/api/admin/banners` |
| Message: plain text, up to 200 characters | Behavior | §4, §8 | `VARCHAR(200)` column + route validation; `textContent` rendering |
| Optional link | Behavior | §4, §8 | `link_url` + `link_label` nullable columns; URL validation |
| Optional start date/time | Behavior | §4, D8 | `start_at` column; defaults to `NOW()` if omitted |
| Optional end date/time | Behavior | §4, D8 | `end_at` column; NULL = no end |
| Within a short time, every user sees the banner | Behavior | D5, §6 | 60-second poll delivers banner within one poll cycle (see C1) |
| User dismisses banner with "x" | Behavior | D3, D4, §7 | `POST /api/banners/:id/dismiss`; upsert into `banner_dismissals` |
| Dismissal does not come back for that user | Behavior | D3, D4 | Server-side dismissal record keyed on `(banner_id, user_id)` |
| End date passes → banner stops showing for everyone | Behavior | D8 | Read endpoint applies date-window filter at query time |
| At most one active banner per workspace | Behavior | D1, D2 | Partial unique index + transactional deactivate-then-insert |
| Publishing a new banner replaces the previous active one | Behavior | D2 | Same transaction: set old `is_active = FALSE`, insert new |
| No start date → active immediately | Behavior | §4 | `start_at` defaults to `NOW()` |
| No end date → active until admin removes it | Behavior | §4, D8 | `end_at IS NULL` condition in query; NULL = no end |
| Dismissal is per user, across devices and sessions | Behavior | D3 | Server-side `banner_dismissals` table (not localStorage) |
| Admin can edit active banner's text | Behavior | §2 | `PATCH /api/admin/banners/:id` |
| Edit does not un-dismiss for users who dismissed | Behavior | D4 | Dismissal keyed on `banner_id` (stable), not on message text |
| Admin can remove banner early ("Remove" button) | Behavior | §2 | `DELETE /api/admin/banners/:id` sets `is_active = FALSE` |
| User who joins after publish sees the banner (if active window) | Edge case | D3, D8 | No dismissal record exists for new user; read endpoint returns banner if within window |
| Start date in the future → banner not shown until then | Edge case | D8 | `start_at <= NOW()` filter in the read query |
| End date before start date → rejected with validation message | Edge case | §4, §8 | CHECK constraint + route-layer validation; returns 422 with message |
| No active banner → users see nothing (normal case) | Edge case | D6 | `GET /api/banners/active` returns `{ banner: null }` |
| Admin publishes while another admin is editing old one → most recent publish wins | Deviation | D2, D1 | Transactional publish; concurrent publish results in 409 for the loser, who can retry (see C3) |
| User dismisses, admin edits text → user still does not see it | Deviation | D4 | Dismissal is on `banner_id` not text; edit does not change `banner_id` |
| Only admins may create, edit, or remove banners | Adversarial | D7, §8 | Admin-role middleware on all write routes; returns 403 for non-admins |
| Non-admin cannot publish by crafting a request | Adversarial | D7, §8 | Role check is server-side from session token; not bypassable by altering the request body |

---

## Appendix A: Captured Inputs

*Note: This design was produced autonomously (no human interview was conducted). The following records the decisions made, the options considered, and the reasoning applied — serving the same role as a captured interview. Every fork that would have been put to a human is recorded here, with the rationale for the autonomous choice.*

---

### Banner delivery: polling vs. real-time push

- **Question:** Should the frontend receive new banners via a polling endpoint or a real-time push channel (WebSocket / SSE)?
- **Recommendation given:** Poll at 60-second intervals. The blueprint says "within a short time" — not "instantly". No real-time infrastructure exists yet (assumption), and the operational cost of adding it for an informational banner is not justified (Principle 1 — YAGNI).
- **Decision made autonomously:** Polling at 60 seconds.
- **Notes:** If a real-time channel is added for other features, free-riding on it for banner delivery would be appropriate at that point.

---

### Dismissal storage: server-side vs. localStorage

- **Question:** Should dismissal be stored server-side (Postgres) or in the browser (localStorage / cookie)?
- **Recommendation given:** Server-side (Postgres). The blueprint explicitly requires dismissal to persist across devices and sessions — localStorage is per-device and cannot satisfy this.
- **Decision made autonomously:** Server-side `banner_dismissals` table.
- **Notes:** No ambiguity here — the blueprint requirement forecloses localStorage.

---

### "At most one active banner" invariant: DB constraint vs. application logic

- **Question:** Should the single-active-banner invariant be enforced in the DB (partial unique index) or purely in application code?
- **Recommendation given:** DB constraint (partial unique index on `(workspace_id) WHERE is_active = TRUE`). The invariant is load-bearing and should be unbypassable (Principle 9).
- **Decision made autonomously:** Partial unique index.
- **Notes:** Application logic remains as a first line of defense (deactivate-then-insert transaction), but the DB constraint is the backstop.

---

### Date-window enforcement: read-time filter vs. background cron

- **Question:** Should the start/end date window be enforced by filtering at query time, or by a background job that flips `is_active` at the scheduled moment?
- **Recommendation given:** Read-time filter (`WHERE start_at <= NOW() AND (end_at IS NULL OR end_at > NOW())`). Eliminates the background-job failure mode where a banner stays live past its end date if the job is late (Principle 5).
- **Decision made autonomously:** Read-time filter.
- **Notes:** The trade-off is that `is_active = TRUE` alone does not mean "currently visible" — the date window also matters. This is contained to the read endpoint, which is the single path for visibility queries.

---

### Poll interval: how short is "short"?

- **Question:** The blueprint says "within a short time, every user sees the banner" — what interval?
- **Recommendation given:** 60 seconds. This is a conventional background-refresh interval for informational UI, is well within any reasonable interpretation of "short time" for an announcement banner, and keeps DB load negligible.
- **Decision made autonomously:** 60 seconds (configurable).
- **Notes (would have asked a human):** If the product team requires a tighter window (e.g., < 10 seconds), the architecture can accommodate by reducing the interval, or the feature could free-ride on a real-time channel if one is added. This is the most likely question to have been challenged in a real interview.

---

### Optional link modeling

- **Question:** The blueprint mentions "plain text plus an optional link" — should the link be stored as a raw URL only, or as URL + display label?
- **Recommendation given:** Store both `link_url` (required if link is present) and `link_label` (optional display text). This matches common product patterns and the display label adds negligible complexity.
- **Decision made autonomously:** `link_url` + `link_label` nullable columns.
- **Notes (would have asked a human):** The blueprint does not specify whether a display label is part of the feature. This is a minor product gap flagged in §13.

---

### Feature flag default and fail behavior

- **Question:** Should the feature flag default to on or off? What happens if the flag service is unavailable?
- **Recommendation given:** Default off; fail-closed (flag unavailable → feature disabled). An un-announced announcement banner is invisible and harmless; accidentally showing an un-configured banner would be worse.
- **Decision made autonomously:** Default off, fail-closed.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **Response (autonomous):** The main gaps surfaced during P2 review:
  1. The exact shell component mount point (A3 / §13 risk 1) — flagged as open risk.
  2. The `link_label` product ambiguity (§13 risk 5) — flagged.
  3. The 60-second poll interval assumption (A6) — flagged for product confirmation.
  4. XSS surface of `link_url` (§13 risk 4) — captured in §8.
  Nothing else was found to be missing from the design coverage.
