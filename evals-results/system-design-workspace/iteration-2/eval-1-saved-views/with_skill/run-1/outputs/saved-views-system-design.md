# System Design: Saved Views

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./saved-views-blueprint.md](./saved-views-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

Saved Views is a pure CRUD feature implemented as a new Rails service layer backed by two new Postgres tables (`saved_views` and `saved_view_shares`), surfaced through six RESTful JSON endpoints, and integrated into the React frontend via a lightweight client-side store. The single most important architectural choice is encoding the ownership and sharing model directly in the database schema — via a `user_id` owner column and a separate `saved_view_shares` join table with a `scope` discriminator — rather than in application logic. This makes the authorization boundary clear, makes illegal states (e.g. a recipient modifying an owner's view) unrepresentable at the data layer, and keeps all authorization checks one SQL join away. Every write is protected by a unique index that enforces the "one name per user per table" invariant and prevents concurrent duplicate-name races at the database level.

> **Note on authoritative standard:** `kite-arch-compass` is not available for this project (not the Kite / appsmith-v2 repo). All recommendations below cite the generic design principles by name from `references/design-principles.md`.

---

## 2. System Placement

This feature lives entirely within the existing Rails + Postgres + React stack. No new infrastructure is introduced.

**Backend:**
- A new `SavedViewsController` (RESTful, JSON) handles all HTTP surface.
- A new `SavedViewsService` (plain Ruby service object) owns business logic: name-uniqueness enforcement, default-view management, share resolution, copy-on-fork.
- `SavedView` and `SavedViewShare` ActiveRecord models map to the new tables.
- Authorization is enforced in the service layer (and double-checked at the controller via a `before_action`).

**Database:**
- Two new Postgres tables: `saved_views`, `saved_view_shares` (see §4).

**Frontend:**
- A new `SavedViewsStore` (React context + `useReducer`, or a small Zustand/Redux slice — whichever the app already uses) holds the current user's view list for a given table.
- The Views dropdown and "Save view" dialog are new React components.
- All data fetches are synchronous request/response (no WebSocket or SSE needed).

**Data flow (happy path):**

```
User action (browser)
  → React component
    → fetch/axios call
      → Rails route
        → SavedViewsController (auth check)
          → SavedViewsService (business logic)
            → ActiveRecord / Postgres
          ← response (view JSON or error)
        ← HTTP response
      ← resolved promise
    ← store update
  ← re-render (dropdown, table state)
```

---

## 3. Architecture Decisions

### D1. Encode ownership and sharing in the data model, not application code

- **Decision:** Owner is a `user_id` FK on `saved_views`. Sharing is a separate `saved_view_shares` table with a `recipient_type` discriminator (`'user'` or `'workspace'`). Read-only nature of shared views is enforced by checking ownership at every mutating endpoint — only the row's `user_id` may write.
- **Why:** *Get the data model right* (Principle 4) — data outlives code; encoding the invariant in schema makes it the cheapest place to enforce it. *Make illegal states unrepresentable* (Principle 9) — a recipient can never "become" an owner through a code path bug because the `user_id` field is set at creation and never exposed for update.
- **Alternatives considered:** Single `saved_views` table with a nullable `owner_id` and a JSON `shared_with` column — rejected because it buries the authorization edge in application code, is hard to query, and can't enforce referential integrity.
- **Trade-off accepted:** Two tables means every "load views visible to me" query is a JOIN. At this scale that is negligible and the clarity gain is worth it.

### D2. Unique index enforces the "one name per user per table" invariant and prevents concurrent duplicate-name races

- **Decision:** Postgres unique index on `(user_id, table_id, name)` on `saved_views`. The service layer checks for name conflicts before insert (friendly error message), but the index is the authoritative guard.
- **Why:** *Make illegal states unrepresentable* (Principle 9) — a database-level unique constraint is the only guard that holds under concurrent requests from two browser tabs. *Idempotency & bounded operations* (Principle 6) — the second of two concurrent same-name saves gets a clean constraint violation, not a silent duplicate. Blueprint deviation scenario "two tabs save a view with the same name at once" is handled by this index.
- **Alternatives considered:** Application-level uniqueness check only — rejected because it has a TOCTOU race under concurrent requests.
- **Trade-off accepted:** A constraint violation error must be caught and translated to a user-visible "name already in use" message. That translation lives in the service layer.

### D3. Default view is a nullable boolean flag on `saved_views`, cleared atomically via a single UPDATE

- **Decision:** A `is_default` boolean column on `saved_views` (nullable, default false). Setting a new default runs: `UPDATE saved_views SET is_default = false WHERE user_id = ? AND table_id = ?; UPDATE saved_views SET is_default = true WHERE id = ?` — both in a single transaction.
- **Why:** *Get the data model right* (Principle 4) — the invariant "at most one default per user per table" must be enforced transactionally. *Idempotency & bounded operations* (Principle 6) — wrapping both UPDATEs in a transaction makes the operation atomic and retry-safe.
- **Alternatives considered:** Separate `user_table_defaults` table with a FK — slightly more relational purity, but extra complexity for a simple scalar flag; rejected per *Simplicity first* (Principle 1).
- **Trade-off accepted:** The `is_default` flag can go stale if a view is deleted without clearing the flag — handled by the soft-or-hard delete logic (see §4 and §7).

### D4. Shared-view updates are live: recipients see the owner's current config on next selection

- **Decision:** No snapshot / versioning. `saved_views.config` stores the current (mutable) view configuration. When a recipient selects a shared view, the frontend fetches the view's current `config` from the server.
- **Why:** *Simplicity first* (Principle 1) — versioning is explicitly out of scope per the blueprint. *Match existing patterns* (Principle 2) — a Rails app with a single mutable JSONB config column is the simplest correct model.
- **Alternatives considered:** Snapshot the config at share time — rejected because the blueprint explicitly states "recipients see the updated configuration the next time they select it."
- **Trade-off accepted:** A recipient who has a shared view selected will not see mid-session live updates; they see the latest version on the next explicit selection. This is consistent with the blueprint.

### D5. View configuration stored as JSONB, not normalized columns

- **Decision:** `saved_views.config` is a `jsonb` column containing `{ filters: [...], sort: { field, direction }, columns: [...] }`. The schema is validated at the API boundary (strong params + JSON Schema or a plain Ruby validator).
- **Why:** *Simplicity first* (Principle 1) — a table configuration is heterogeneous and varies by table type; normalizing it into columns would require schema changes for every table type added in the future. *Get the data model right* (Principle 4) — JSONB is Postgres-native, indexable, and queryable; it is the right tool for a semi-structured payload.
- **Alternatives considered:** Separate columns (`filter_json text`, `sort_field varchar`, `sort_direction varchar`, `columns_json text`) — rejected because it's effectively JSONB without the benefits (no indexing, no operators, harder to evolve).
- **Trade-off accepted:** Config shape is not enforced by the DB schema itself — must be validated in the service layer. Missing or extra keys in JSONB are silently tolerated by Postgres, so the service layer's validator is the only gate. See §8 (input validation).

### D6. Copy-on-fork: recipient creates their own independent view

- **Decision:** A `POST /saved_views/:id/copy` endpoint creates a new `saved_view` owned by the requesting user, with the current `config` of the source view. The copy has no link back to the original.
- **Why:** *Simplicity first* (Principle 1) — no bidirectional link means no synchronization problem, no dangling reference if the original is deleted. Blueprint states the copy is "fully owned" by the recipient, implying independence.
- **Alternatives considered:** "Forked from" FK for provenance — interesting for UX but out of scope per the blueprint; rejected per YAGNI.
- **Trade-off accepted:** The copy diverges immediately; changes the owner makes to the original are not reflected in the copy. This is the intended behavior.

### D7. All endpoints are synchronous; no background jobs

- **Decision:** Every operation (save, update, delete, set-default, share, copy) is handled inline in the request/response cycle. No background jobs or queues.
- **Why:** *Simplicity first* (Principle 1) — saved views are small, pure CRUD operations with no expensive compute. Adding a job queue would be complexity paid for by no real requirement. *Match existing patterns* (Principle 2) — background jobs are appropriate for expensive async work; a sub-millisecond Postgres write does not qualify.
- **Alternatives considered:** Background job for share fan-out notification — N/A because the blueprint does not specify notifications.
- **Trade-off accepted:** If the Postgres write is slow (e.g. lock contention), the user waits. Given the expected volume, this is acceptable.

### D8. No server-side caching; rely on HTTP-level and client-side store

- **Decision:** No Rails fragment cache, no Redis cache for view data. The client store holds the loaded view list for the current table session. A full page load or explicit navigation re-fetches from Postgres.
- **Why:** *Simplicity first* (Principle 1) — saved views are small, low-read-frequency data; a cache layer adds complexity with negligible latency benefit. *Cache invalidation is a design decision* (Principle 13) — rather than accept a stale-cache correctness risk, the correct trade-off here is to skip the cache.
- **Alternatives considered:** Redis cache keyed by `user_id + table_id` — adds cache invalidation complexity on every write; not warranted at this scale.
- **Trade-off accepted:** Every page load hits Postgres. Given the expected volume (see §6), this is fine.

---

## 4. Data Model & Persistence

### Table: `saved_views`

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK, auto-increment | |
| `user_id` | `bigint` | NOT NULL, FK → users | Owner; never updated |
| `table_id` | `bigint` | NOT NULL, FK → tables | The table this view belongs to |
| `name` | `varchar(255)` | NOT NULL | Unique per (user, table) — see index below |
| `config` | `jsonb` | NOT NULL | `{ filters, sort: {field, direction}, columns: [] }` |
| `is_default` | `boolean` | NOT NULL, DEFAULT false | At most one true per (user, table) — enforced transactionally |
| `created_at` | `timestamp` | NOT NULL | |
| `updated_at` | `timestamp` | NOT NULL | |

**Indexes:**
- `UNIQUE INDEX ON saved_views (user_id, table_id, name)` — enforces name uniqueness and prevents concurrent duplicate-name races (D2).
- `INDEX ON saved_views (user_id, table_id)` — covers the "load my views for this table" query.
- `INDEX ON saved_views (user_id, table_id) WHERE is_default = true` — partial index for fast default-view lookup.

### Table: `saved_view_shares`

| Column | Type | Constraints | Notes |
|---|---|---|---|
| `id` | `bigint` | PK, auto-increment | |
| `saved_view_id` | `bigint` | NOT NULL, FK → saved_views ON DELETE CASCADE | Cascade ensures recipients lose access when owner deletes |
| `recipient_type` | `varchar(20)` | NOT NULL, CHECK IN ('user', 'workspace') | `'workspace'` = whole workspace share |
| `recipient_id` | `bigint` | NULLABLE | NULL when `recipient_type = 'workspace'`; user id otherwise |
| `workspace_id` | `bigint` | NOT NULL, FK → workspaces | Scopes workspace-level shares |
| `created_at` | `timestamp` | NOT NULL | |

**Indexes:**
- `INDEX ON saved_view_shares (saved_view_id)` — covers cascade and share lookups.
- `INDEX ON saved_view_shares (recipient_id, workspace_id)` — covers "what shared views can this user see?" query.
- `UNIQUE INDEX ON saved_view_shares (saved_view_id, recipient_type, COALESCE(recipient_id, 0))` — prevents duplicate share records.

### Invariants & constraints

- A view's `user_id` is set at creation and is never updated (ownership is immutable).
- `is_default = true` for at most one row per `(user_id, table_id)` — enforced transactionally, not by DB constraint (see D3).
- When a `saved_view` is deleted, all its `saved_view_shares` are deleted by `ON DELETE CASCADE`.
- When the default view is deleted, the cascade removes the row; the frontend falls back to "no view" on next load (blueprint edge case: "if a recipient had it set as default, the table falls back to no view" — handled identically for the owner's deletion of their own default).

### Migration shape

Two migrations, run in order:
1. `create_saved_views` — creates `saved_views` table with all columns and indexes.
2. `create_saved_view_shares` — creates `saved_view_shares` table with FK and indexes.

No backfill required (net-new feature with no existing data).

### Retention / expiry

No expiry policy. Views persist until deleted by their owner. If the owning user is deleted, views are deleted by FK cascade (assuming `users` table has cascading deletes or a cleanup job — **assumption A5**).

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| *None* | — | — | — | — | — |

No external third-party services are required. This feature is entirely served by the application's own Postgres database.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| Load view list for a table | < 50 ms | < 200 ms | Single indexed query; result set bounded by assumption A2 |
| Save / update a view | < 100 ms | < 300 ms | Single insert/update + index check |
| Set default view | < 100 ms | < 300 ms | Two UPDATEs in a transaction |
| Delete a view | < 100 ms | < 300 ms | Single DELETE + cascade |
| Copy a shared view | < 100 ms | < 300 ms | Single INSERT |

These targets are assumed reasonable for a low-traffic CRUD feature on an indexed Postgres table. They should be validated with production metrics after launch (Principle 8 — *Measure, don't guess*).

### Expected load

Assumption: this is a team productivity feature, not a high-frequency operational path. A user saves or switches views at most a handful of times per session. Expected peak: tens of requests/second across all users, not hundreds. No fan-out, no scatter-gather, no N+1 concern.

### Concurrency model

- Write contention is addressed by the unique index (D2) and the transactional default-swap (D3).
- No row-level locking beyond what Postgres provides by default for single-row updates.
- The "two tabs" concurrent duplicate-name race is fully handled by the unique index — the losing request receives a `409 Conflict` with a "name already in use" message.

### Caching

No server-side cache (D8). The client-side store holds the view list for the current table session and is updated optimistically on successful writes (see §B6 / frontend). All cache invalidation complexity is avoided.

### Bounding

- Max views per user per table: **assumption A2** (100 as a safe default, enforced at the service layer). This bounds the result set of every list query and prevents pathological UI states.
- Config JSONB size: no hard limit imposed at DB level, but the service layer validates structure; malformed or oversized configs are rejected at the API boundary.

---

## 7. Reliability & Failure Handling

### Failure modes

| Failure | What the system does | What the user sees |
|---|---|---|
| Postgres write fails (transient) | Controller returns `503`; no retry at server side | Toast: "Could not save view, please try again" |
| Concurrent duplicate name (unique index violation) | Service catches `PG::UniqueViolation`, returns `409` | "A view with that name already exists" (blueprint deviation scenario) |
| View not found (e.g. deleted by owner mid-session) | `404` from controller | Frontend drops the view from the dropdown; if it was active, clears to no-view state |
| Shared view deleted by owner | `ON DELETE CASCADE` removes share records; next fetch returns `404` | Recipient's dropdown re-fetches and no longer shows the view; if it was their default, table opens in plain state (blueprint edge case) |
| Default view references a deleted view | View row is gone (hard delete); `is_default` flag deleted with it | On next table open, no default is found; table opens in plain state |
| Column referenced by view no longer exists | View loads normally; missing column is absent from `columns` array | Frontend silently skips unknown columns (blueprint edge case) |
| Filter references a deleted value | View loads; filter is applied as-is; matches nothing | Empty result set; user can edit the filter (blueprint edge case) |

### Idempotency

- `POST /saved_views` (create): NOT idempotent by nature; protected by unique index — duplicate creates return `409` rather than creating a duplicate.
- `PUT /saved_views/:id` (update): Idempotent — same payload applied twice produces the same state.
- `DELETE /saved_views/:id`: Idempotent — deleting an already-deleted view returns `404` (harmless).
- `POST /saved_views/:id/set_default`: Idempotent — setting the same default twice is a no-op.
- `POST /saved_views/:id/copy`: NOT idempotent — each call creates a new view. The unique-name constraint on the copy's name prevents accidental duplicates if the user clicks twice.

### Retries

No server-side retry logic. Transient DB errors surface as `5xx` and the client can retry. No compensating transactions are needed — all operations are single-transaction.

### Timeouts

Postgres query timeout inherits the application's default (assumption A6 — assumed ~5s). No special timeout needed for this feature.

---

## 8. Security & Privacy

### Authentication & authorization

- All endpoints require an authenticated session (existing Rails `authenticate_user!` before_action or equivalent). Unauthenticated requests receive `401`.
- **Ownership check:** every mutating operation (`update`, `delete`, `set_default`, `share`) verifies `saved_view.user_id == current_user.id` before proceeding. A mismatch returns `403` — never `404` (to avoid leaking existence).
  - *Exception:* `copy` is allowed by any user with read access to the view (owner or recipient).
- **Read check:** `show` and `index` return only views where `user_id = current_user.id` OR a valid `saved_view_shares` record grants access. No view is ever returned to a user who hasn't been explicitly granted access.
- This directly addresses the blueprint's adversarial scenarios:
  - "A recipient must not be able to modify or delete the original" — `403` on any mutating endpoint if `user_id != current_user.id`.
  - "A user must not be able to load or enumerate views belonging to users who have not shared with them" — `index` and `show` queries are scoped to `current_user.id` plus valid share records.

### Input validation

- `name`: stripped, length-validated (1–255 chars), no special sanitization needed (stored as text, not rendered as HTML).
- `config`: validated against an expected JSON structure in the service layer (required keys: `filters`, `sort`, `columns`; type checks on values). Invalid config returns `422`.
- `table_id`, `id` params: cast to integer; invalid values return `400`.
- All params go through Rails strong parameters.

### PII / data privacy

- View names are user-supplied strings and may contain PII. They are stored in Postgres alongside the user's `user_id`. Access is already gated by auth. No special PII handling beyond existing data protection posture (assumption A7).
- View `config` may encode column names and filter values from the underlying table data — treated the same as other user-generated table configuration in the app.

### Abuse vectors

- A user sharing a view with an entire workspace exposes the view config to all workspace members. The owner makes this choice explicitly. No rate limiting on share creation is needed at this scale (assumption A8).
- No SSRF, injection, or file-upload surface — this is pure structured CRUD.

---

## 9. Observability

### Logs

- Standard Rails request logs for all endpoints (method, path, status, duration, `user_id`).
- Service layer logs a structured event for each write operation: `{ event: "saved_view_created", user_id:, table_id:, view_id: }` etc. This enables audit without full query logging.
- Constraint violation (duplicate name) logged at `INFO` level with `{ event: "saved_view_duplicate_name_rejected", user_id:, table_id: }`.

### Metrics

| Metric | Type | Purpose |
|---|---|---|
| `saved_views.created.count` | Counter | Feature adoption |
| `saved_views.applied.count` | Counter | Feature engagement (selecting a view) |
| `saved_views.shared.count` | Counter | Sharing adoption |
| `saved_views.copy.count` | Counter | Copy-on-fork usage |
| `saved_views.duplicate_name_rejected.count` | Counter | Concurrency / UX signal |
| `saved_views.api.latency_ms` | Histogram, by endpoint | Latency tracking |
| `saved_views.errors.count` | Counter, by status code | Error rate |

### The one health signal

**`saved_views.api.latency_ms` p95 < 300 ms** across all endpoints, combined with **`saved_views.errors.count` for 5xx = 0**, proves the feature is healthy. An alert fires if either crosses threshold for 5 minutes.

### Traces

Standard Rails/APM distributed tracing (e.g. Datadog, New Relic, or OpenTelemetry — assumption A9) automatically spans all endpoints. No custom spans needed beyond what the framework provides.

---

## 10. Rollout & Operability

### Feature flag

- Gate the entire feature behind a feature flag (e.g. `saved_views_enabled`), default **off**.
- The flag is checked in the Rails router (or a `before_action`) — flagged-off state returns `404` on all `/saved_views` routes.
- The frontend conditionally renders the Views dropdown based on the same flag value (returned in an existing feature-flag payload or a dedicated endpoint — assumption A10).
- **Fail-closed:** if the flag state cannot be read, the feature is off. This prevents a flag infrastructure failure from accidentally exposing an incomplete feature.

### Migration / deploy order

1. **Database migration first** (in a separate deploy or migration run): create `saved_views` and `saved_view_shares` tables. These are additive — no existing table is altered. Safe to run against production before any code deploys.
2. **Backend deploy**: `SavedViewsController`, `SavedViewsService`, models, routes — all behind the feature flag. Flag is **off**.
3. **Frontend deploy**: Views dropdown, store — hidden behind the flag check. No UI impact while flag is off.
4. **Flag on for internal users** → smoke test.
5. **Staged rollout** (e.g. 10% → 50% → 100%).

### Reversibility

- **Reversible.** Turning the flag off instantly hides the feature from all users.
- The database tables can be dropped if the feature is fully reverted, but this is a one-way door after users have saved views. The flag provides a soft revert; table removal is a hard one and requires a separate migration.

### No coordination complexity

Backend, frontend, and database deploys are all additive and independent. The feature flag provides the coordination seam — there is no window where a user could be on a new frontend talking to an old backend or vice versa, as long as the flag is off during the deploy window.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | The app has a `users` table and a `tables` table with integer PKs, both accessible as FK targets. | Standard Rails app structure; the blueprint describes "a data table" as an existing concept. | No — but schema of `tables` table should be confirmed before migration. |
| A2 | A soft cap of 100 views per user per table is reasonable UX and prevents pathological queries. | No cap is stated in the blueprint; 100 is a generous limit that no realistic user will hit. | Yes — confirm acceptable cap with PM before enforcing. |
| A3 | "Workspace" is an existing first-class entity with its own table and integer PK. | The blueprint describes workspace-level sharing as a feature. | No — but the `workspaces` table and its user-membership model must be confirmed before implementing workspace share lookup. |
| A4 | The app uses Rails strong parameters and a standard `current_user` auth helper. | Standard Rails convention; described as a "Rails app" in the task. | No. |
| A5 | Deleting a user cascades to delete their `saved_views` (or a cleanup job handles it). | Without this, orphaned views accumulate. If the app does not cascade-delete, the service must handle it. | Yes — confirm the user-deletion cleanup contract. |
| A6 | The app has a default Postgres statement timeout (~5 s) that is appropriate for these queries. | These queries are trivial indexed reads/writes; no special timeout is needed. | No. |
| A7 | View names and config values are treated the same as other user-generated table configuration for data privacy purposes. | Standard posture for a B2B SaaS app; no special PII category. | No — but confirm if the app has a stricter data classification policy. |
| A8 | No rate limiting on share creation is needed at this scale. | Share is a deliberate, low-frequency action. | No — revisit if abuse is observed. |
| A9 | The app already uses a distributed tracing / APM tool that auto-instruments Rails controllers. | Standard for a production Rails app. | No — but confirm which APM tool to align metric names. |
| A10 | Feature flag values are already delivered to the frontend (e.g. as part of a bootstrap payload). | Standard pattern for flagged features. | Yes — confirm the flag delivery mechanism before frontend work begins. |
| A11 | "Table" in the blueprint refers to a first-class entity in the app's data model with a stable integer ID. If table IDs change (e.g. are UUID-based), the FK type must change. | The task describes a Rails + Postgres app; integer PKs are the Rails default. | Yes — confirm PK type for `tables`. |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | `is_default` enforced transactionally, not by DB unique partial index | A partial unique index (`WHERE is_default = true`) would be the strongest guarantee. A partial unique index on a mutable boolean is error-prone in Rails (requires careful migration); transactional enforcement is nearly equivalent in practice. | *Make illegal states unrepresentable* (Principle 9) | The transaction window is tiny (two sequential UPDATEs); concurrent default-swaps on the same `(user_id, table_id)` are extremely rare and the worst outcome is a momentary double-default that the next read resolves. | If double-default bugs are observed in production, add the partial unique index. |
| C2 | No server-side cache | At higher read volumes, repeated "load views for table" calls all hit Postgres. | *Cost as a first-class constraint* (Principle 12) | The feature is low-read-frequency CRUD; Postgres with an index is fast enough. | Revisit if list-views endpoint appears in the top-10 slow queries after launch. |
| C3 | JSONB config is validated in the service layer, not by a Postgres check constraint or a typed schema | The DB will accept any JSONB, so schema drift is caught only at the API boundary. | *Make illegal states unrepresentable* (Principle 9) | Check constraints on JSONB structure are complex, brittle, and hard to evolve. Service-layer validation is the standard Rails pattern and is tested. | Revisit if config schema drift causes silent bugs in production. |
| C4 | Copy-on-fork creates a fully independent view with no provenance link | There is no way to know a view was copied from another, which may limit future "view lineage" UX. | *Prefer reversible decisions* (Principle 7) | Blueprint states the copy is "fully owned"; provenance is explicitly out of scope. | If a "view lineage" feature is requested, add a nullable `copied_from_id` FK. |

---

## 13. Open Risks & Callouts

1. **Schema of `tables` table is unknown.** The design assumes `tables.id` is an integer PK. If the app uses UUIDs or composite keys for tables, the FK type and the unique index on `saved_views` must change. Confirm before writing the migration.

2. **User-deletion cleanup contract is unknown.** If `users` does not cascade-delete to `saved_views`, orphaned views will accumulate. This must be resolved before launch to avoid data retention issues.

3. **Feature-flag delivery to frontend.** If the app does not already have a flag-delivery mechanism for the frontend, a small bootstrap infrastructure change is needed. This could block the frontend deploy.

4. **Workspace membership query for workspace-level shares.** The "shared with whole workspace" check requires a query like "is `current_user` a member of the workspace that owns this view?" The workspace membership model must be confirmed before implementing this code path.

5. **"View applies to a specific table" semantics.** The blueprint says a view "belongs to" a table. If the app has multiple table types (with different column schemas), the JSONB config's column list may contain columns that are only valid for one table type. The silent-ignore behavior for unknown columns (blueprint edge case) handles this gracefully, but the `table_id` FK semantics must be confirmed.

---

## 14. Out of Scope

The following are explicitly excluded from this design (from the blueprint and task scope):

- Versioning or history of changes to a view (blueprint: "Out of scope").
- Scheduled or automated view switching (blueprint: "Out of scope").
- Saving per-row data — a view is only a configuration, never a snapshot (blueprint: "Out of scope").
- Notifications to share recipients when a view is shared with them (not mentioned in the blueprint).
- Audit log of share/unshare events beyond application-level structured logs.
- View search or tagging.
- Cross-table or cross-workspace view portability.
- Admin-level view management (bulk delete, impersonation).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets per action; all sync, no background work |
| A2 Throughput & scale | Assumed (A2, A8) | §6 — low-frequency CRUD; soft cap of 100 views per user per table assumed |
| A3 Concurrency & consistency | Resolved | D2 (unique index for duplicate-name race), D3 (transactional default-swap), §7 |
| A4 Availability & reliability | Resolved | §7 — failure modes, fallbacks, idempotency per operation |
| A5 Data integrity & durability | Resolved | §4 — FK constraints, CASCADE, transactional invariants, migration shape |
| A6 Caching & freshness | Resolved | D8 — no server-side cache; client store; explicit trade-off stated |
| A7 Cost | Resolved | §5, D8 — no external services; no per-request cost; Postgres only |
| A8 Security & privacy | Resolved | D1, §8 — ownership check, scoped queries, adversarial scenarios addressed |
| A9 Observability | Resolved | §9 — structured logs, metrics, health signal, APM tracing |
| A10 Maintainability & simplicity | Resolved | D1, D7, D8 — fewest moving parts; fits Rails CRUD conventions |
| A11 Testability | Resolved | §B6 note, §3 decisions — pure service layer with injected AR; standard Rails model/controller/service specs; no external mocks needed |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, reversibility |
| A13 Backward compatibility | Resolved | §10, §4 — additive tables only; no existing schema or API contracts changed |
| A14 Accessibility & device/env | Assumed (A12) | Blueprint has no device/env scenarios; Views dropdown and dialog should follow the app's existing a11y conventions (keyboard navigation, ARIA). Assumed standard; not designed here. |
| B1 Placement / module taxonomy | Resolved | §2 — new `SavedViewsController` + `SavedViewsService` + AR models; no new infrastructure |
| B2 Data model & persistence | Resolved | §4 — full schema, indexes, invariants, migration shape |
| B3 API surface & schemas | Resolved | §3 (D5), §8 — six RESTful endpoints; JSONB config validated at API boundary |
| B4 Async / background work | Resolved | D7 — all sync; no background jobs; rationale stated |
| B5 External services & contracts | N/A | §5 — no external services |
| B6 Frontend integration | Resolved | §2 (data flow), D4, D6, D8 — client store; optimistic updates on write; loading/error states per §7 |
| B7 Feature flags & rollout | Resolved | §10 — `saved_views_enabled` flag; fail-closed; staged rollout |
| B8 Error handling | Resolved | §7, §8 — per-layer error contracts; `403`/`404`/`409`/`422`/`503` mapped to user-visible messages |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| A view stores: filter set, sort field/direction, ordered list of visible columns, table it belongs to | Behavior | §4 (JSONB config schema), D5 | All four fields stored in `config` JSONB + `table_id` FK |
| A view belongs to the user who created it; others don't see it unless shared | Behavior | D1, §8 | `user_id` FK; `index` query scoped to owner + valid shares |
| A user may share with specific teammates or whole workspace; shared views are read-only for recipients | Behavior | D1, §4 (`saved_view_shares`), §8 | `recipient_type` discriminator; mutating endpoints 403 for non-owners |
| A recipient can "copy" a shared view into their own | Behavior | D6 | `POST /saved_views/:id/copy`; independent new row |
| Each user has at most one default view per table | Behavior | D3, §4 | Transactional two-UPDATE swap |
| View names must be unique per user per table | Behavior | D2, §4 | Unique index on `(user_id, table_id, name)` |
| Selecting a view re-applies its filters, sort, and column config | Behavior | D4, §6 (frontend) | Client reads `config` JSONB on selection; applies to table state |
| Default view loads automatically when user opens the table | Behavior | D3, §6 (frontend) | Client fetches views on table open; applies the `is_default = true` row |
| A column referenced by a saved view is later removed: silently ignored | Edge case | D5, §7 | Config stored as-is; frontend skips unknown column names |
| A filter references a value that no longer exists: kept but matches nothing | Edge case | D5, §7 | Config stored as-is; no server-side validation of filter values at load time |
| Owner deletes a shared view: recipients lose access; if recipient's default, table falls back to no view | Edge case | §4 (ON DELETE CASCADE), §7 | Cascade removes share records; 404 on next fetch; frontend falls back to no-view |
| A user has no views: table opens in plain state, dropdown shows only "Save view" | Edge case | §6 (frontend), §7 | `index` returns empty array; frontend renders empty-state dropdown |
| Two tabs save a view with the same name at once: second is rejected with "name already in use" | Deviation | D2, §7 | Unique index on `(user_id, table_id, name)`; constraint violation → 409 → user-visible message |
| A shared view updated by owner: recipients see updated config next time they select it | Deviation | D4, §4 | Single mutable `config` column; no snapshot; recipients fetch current state on selection |
| Recipient must not be able to modify or delete the original through any request | Adversarial | D1, §8 | `user_id` ownership check on every mutating endpoint; 403 on mismatch |
| User must not be able to load or enumerate views belonging to users who haven't shared | Adversarial | D1, §8 | `index` and `show` queries scoped to `current_user.id` + valid share records; no view ID enumeration possible |

---

## Appendix A: Captured Inputs

> **Note:** This design was produced autonomously (no human interview was conducted). The following records the decisions, recommendations, and rationale that would normally be captured from the interview. Every fork was resolved by the designer using the behavior blueprint and the generic design principles. Anything that would have been asked of a human is flagged explicitly.

### Decision: Data model shape (ownership + sharing)

- **Question:** Should the sharing model be encoded in the data (a separate `saved_view_shares` table) or in application logic (e.g. a JSON `shared_with` column on `saved_views`)?
- **Recommendation given:** Separate table — enforces referential integrity, enables clean authorization queries, and makes the ownership invariant clear. (Principles 4, 9.)
- **User's answer:** Resolved as "separate table" by designer; no human override.
- **Notes / intent:** The blueprint's adversarial scenarios (no enumeration, no modification by recipients) make a clean DB-level boundary important. The separate table also makes cascade-on-delete trivial.

### Decision: Unique index vs. application-level name uniqueness

- **Question:** Should name uniqueness be enforced by a DB unique index, or by an application-level check before insert?
- **Recommendation given:** DB unique index as the authoritative guard, with an application-level check for the friendly error message. (Principles 6, 9.) Blueprint deviation scenario "two tabs" makes the DB-level guard mandatory.
- **User's answer:** Resolved as "unique index" by designer.
- **Notes / intent:** Application-level check alone has a TOCTOU race under concurrent requests. The index is the only correct answer.

### Decision: `is_default` as a column vs. a separate defaults table

- **Question:** Should the default-view relationship be a boolean column on `saved_views` or a separate `user_table_defaults` table?
- **Recommendation given:** Boolean column, cleared transactionally. Simpler; the invariant is enforced by the transaction, not by schema uniqueness. (Principle 1.)
- **User's answer:** Resolved as "boolean column" by designer.
- **Notes / intent:** Principle 1 (Simplicity first) — the extra table adds structure without buying anything at this scale.

### Decision: JSONB vs. normalized columns for view config

- **Question:** Should `filters`, `sort`, and `columns` be stored as separate columns or as a single JSONB blob?
- **Recommendation given:** JSONB. View config is heterogeneous and will vary by table type; normalizing it would require schema changes for every table type. (Principles 1, 4.)
- **User's answer:** Resolved as "JSONB" by designer.
- **Notes / intent:** JSONB is Postgres-native and indexable. The trade-off is that structure is not enforced by the DB — accepted as C3.

### Decision: Shared-view update semantics (live vs. snapshot)

- **Question:** When an owner updates a shared view, should recipients see the update immediately (live) or only at the time of sharing (snapshot)?
- **Recommendation given:** Live (mutable config). Blueprint explicitly states "recipients see the updated configuration the next time they select it."
- **User's answer:** Resolved as "live" by designer — blueprint is unambiguous.
- **Notes / intent:** No design choice here; the blueprint decides it.

### Decision: Caching

- **Question:** Should view list results be cached (e.g. in Redis), or should every request hit Postgres?
- **Recommendation given:** No cache. Low read frequency + indexed Postgres = fast enough; cache invalidation adds complexity without benefit at this scale. (Principles 1, 13.)
- **User's answer:** Resolved as "no cache" by designer.
- **Notes / intent:** Accepted as C2; revisit if list-views appears in slow query logs.

### Decision: Background jobs

- **Question:** Should any write operations be deferred to a background job?
- **Recommendation given:** No. All operations are sub-millisecond DB writes with no expensive compute. (Principle 1.)
- **User's answer:** Resolved as "no background jobs" by designer.
- **Notes / intent:** No notifications, no fan-out, no heavy computation — nothing to defer.

### Decision: Feature flag

- **Question:** Should the feature be gated behind a feature flag?
- **Recommendation given:** Yes, fail-closed, default off. Enables safe staged rollout and instant rollback. (Principle 7.)
- **User's answer:** Resolved as "yes, feature flag" by designer.
- **Notes / intent:** The flag delivery mechanism to the frontend is an open assumption (A10) that needs confirmation.

### Decision: View cap (max views per user per table)

- **Question:** Should there be a hard cap on views per user per table?
- **Recommendation given:** Yes — soft cap of 100, enforced at the service layer. Blueprint does not specify one, but an uncapped list is a denial-of-service vector and a UX problem. (Principle 6.)
- **User's answer:** Resolved as "100" by designer; **would have asked PM to confirm** (flagged as A2).
- **Notes / intent:** 100 is generous; no realistic user will hit it. The cap number is the thing most likely to be overridden by a human.

### Items that would have been asked of a human

1. **View cap number** — is 100 correct, or does PM want a different limit?
2. **FK type for `tables`** — integer or UUID? (Assumption A11)
3. **User-deletion cascade contract** — does the app cascade-delete user data? (Assumption A5)
4. **Feature flag delivery mechanism** — how does the frontend receive flag values? (Assumption A10)
5. **Workspace membership query** — what table/association models workspace membership? (Risk item 4)

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** No human available. Design proceeds on the basis of the blueprint and assumptions documented above. Open risks in §13 capture the items most likely to surface in a real last-call conversation.
