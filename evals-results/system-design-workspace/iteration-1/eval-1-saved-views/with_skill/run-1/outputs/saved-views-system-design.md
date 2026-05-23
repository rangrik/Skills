# System Design: Saved Views

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../../../../../inputs/saved-views-blueprint.md](../../../../../inputs/saved-views-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

Saved Views is a pure CRUD feature backed by a single `saved_views` table in Postgres (Rails app). A view record stores the table identifier, owner, and a JSON payload of the filter/sort/column configuration. Sharing is modeled via a separate `saved_view_shares` table (share targets can be a specific user or the whole workspace), keeping ownership unambiguous and authorization simple. The single most important architectural choice is **storing configuration as a validated JSON column rather than normalized filter rows**: it gives schema flexibility for future filter types without a migration, while a unique index on `(user_id, table_id, name)` and a DB-level constraint on a single default per user+table enforce the blueprint's invariants directly in the database. All operations are synchronous HTTP (no background jobs). The React frontend holds view list state in component-local state, uses optimistic UI for switching views, and invalidates on any write.

---

## 2. System Placement

This is a **Rails Service + Controller pair** within the existing backend. No new service boundary is introduced; no background workers are needed (all operations are bounded, fast, and user-synchronous).

**Components touched:**

- **Backend:** new `SavedView` and `SavedViewShare` ActiveRecord models + `SavedViewsController` (RESTful routes) + a `SavedViewsService` that owns the authorization and business-logic layer.
- **Database:** two new Postgres tables (`saved_views`, `saved_view_shares`) via Rails migrations.
- **Frontend (React):** a `SavedViewsDropdown` component + a `useSavedViews` hook that owns fetching, optimistic switching, and write invalidation.

**Data flow:**

```
User action (save / select / share / delete)
  → React component
    → REST API call (JSON over HTTPS)
      → SavedViewsController (authN check)
        → SavedViewsService (authZ + business rules)
          → SavedView / SavedViewShare ActiveRecord models
            → Postgres
  ← JSON response
← Optimistic UI commit or rollback
```

**No external services are required.** All data lives in the application's own Postgres database.

---

## 3. Architecture Decisions

### D1. Store view configuration as a validated JSON column (not normalized rows)

- **Decision:** The `config` payload (filters, sort, visible columns) is stored as a single `jsonb` column on `saved_views`, validated in the Rails model using a JSON Schema (or a hand-rolled validator) before persist.
- **Why:** Favors *simplicity first* (Principle 1) — a single column replaces three or more join tables for filters, sorts, and columns. The blueprint's edge case ("a column referenced by a saved view is later removed") is trivially handled by ignoring unknown keys at read time rather than cascading deletes or orphan rows. JSON also stays a two-way door (Principle 7): if a future filter type requires a shape change, only the validation schema updates, not the table structure.
- **Alternatives considered:**
  - *Normalized filter/sort/column rows:* more queryable, but the blueprint contains no requirement to query by filter contents; adds three join tables and complex migration surface for no present benefit. Rejected per YAGNI.
  - *Schemaless JSON with no validation:* saves code, but allows corrupt state to persist silently. Rejected per "make illegal states unrepresentable" (Principle 9).
- **Trade-off accepted:** `config` internals are opaque to SQL queries. If a future requirement needs "find all views using filter X," a migration to add a derived column or a GIN index on the jsonb would be required. That cost is accepted now; the trigger to revisit is any query that needs to introspect filter contents.

---

### D2. Ownership and sharing via a separate `saved_view_shares` join table (not a flag on the view)

- **Decision:** A `saved_view_shares` table records `(saved_view_id, share_target_type, share_target_id)` where `share_target_type` is an enum `user | workspace`. Reads check: is the requestor the owner, or does a matching share row exist?
- **Why:** Enforces the blueprint's authorization model cleanly (Principle 3 — high cohesion, Principle 9 — illegal states unrepresentable). A boolean `is_shared` flag can't represent "shared with specific user vs. whole workspace" without additional columns; a separate table scales naturally to both targets and future group sharing.
- **Alternatives considered:**
  - *Embedded `shared_with` array on the view row:* hard to index and query for "what views can I see?"; poor fit for an append-only authorization check. Rejected.
  - *Single `shared_with_workspace` boolean + separate `shared_with_users` table:* two mechanisms for one concern; less cohesive. Rejected.
- **Trade-off accepted:** Listing views visible to a user requires a JOIN or a UNION query instead of a simple `WHERE owner_id = ?`. At realistic view counts per table (tens to low hundreds per workspace), this is negligible cost.

---

### D3. Uniqueness and default constraints enforced at the database level

- **Decision:**
  1. A unique index on `(user_id, table_id, name)` prevents duplicate names per user per table.
  2. A partial unique index on `(user_id, table_id) WHERE is_default = true` ensures at most one default view per user per table.
- **Why:** Database-level constraints are the strongest, cheapest enforcement of invariants (Principle 9). The blueprint's deviation scenario ("two tabs save a view with the same name at once") is neutralized by the unique index: the second insert races and raises an ActiveRecord uniqueness error, which the service layer catches and returns as a 409/422 with a user-visible "name already in use" message. The `is_default` partial index makes the "setting a new default clears the previous one" logic a simple `UPDATE ... SET is_default = true WHERE id = ?` wrapped in a transaction — Postgres rejects a second `true` atomically.
- **Alternatives considered:**
  - *Application-level uniqueness check only:* vulnerable to the race condition the blueprint explicitly calls out. Rejected.
  - *Setting `is_default = false` on all other views then setting the new one:* two-step update inside a transaction is fine, but the partial unique index makes it single-step and race-proof. Chosen because it's simpler.
- **Trade-off accepted:** Migrations carry the constraint; removing it later requires a migration. Acceptable — these invariants are core to the feature and unlikely to be unwound.

---

### D4. Authorization enforced in the service layer, not the controller

- **Decision:** `SavedViewsController` handles only authentication (user must be signed in) and parameter permit-listing. `SavedViewsService` handles every authorization check: owner-only writes, share-recipient read-only access, workspace-scoped share visibility. Controllers never query `SavedView` directly.
- **Why:** High cohesion and loose coupling (Principle 3) — keeps authorization logic in one place, reducing the blast radius of rule changes. Also aligns with "match existing patterns" (Principle 2) — standard Rails pattern separating controller from business logic.
- **Alternatives considered:**
  - *Authorization in controller:* scatters policy logic across multiple actions; breaks if a route is added later. Rejected.
  - *Pundit or CanCanCan policy objects:* fine if the app already uses them; assumed absent (see Assumptions §11). If an authorization library is already in place, authorization belongs in a policy object in that library's style.
- **Trade-off accepted:** Service objects add a layer; for this feature the authZ complexity justifies it.

---

### D5. All operations are synchronous; no background jobs

- **Decision:** All API actions (create, update, delete, share, copy, set-default, list, apply) are synchronous HTTP request/response. No Sidekiq/background jobs are used.
- **Why:** Every operation is bounded (write one or a handful of small rows; read at most O(views per table)). There is no expensive work to defer. Simplicity first (Principle 1) and design for observable failure (Principle 5) — a synchronous 500 is easier to surface to the user than a failed background job.
- **Alternatives considered:**
  - *Background job for share fan-out (e.g. sending notifications):* the blueprint does not specify notification behavior; no fan-out is required. Scope is strictly data persistence. If notifications are added later, a job would be introduced at that point.
- **Trade-off accepted:** N/A — no meaningful trade-off.

---

### D6. Frontend state in component-local state with optimistic UI on view switching

- **Decision:** The `useSavedViews` hook fetches the view list from the API on table mount and stores it in component state (React `useState` / `useReducer`). Switching views is **optimistic**: the table re-renders immediately with the selected view's config, and the selection persists without a round-trip (nothing is written to the server on mere selection — the default is only persisted when the user explicitly "sets as default"). Writes (save, update, delete, share) call the API, then refresh the view list on success. On failure, the local state is rolled back.
- **Why:** Matches the simplest front-end pattern (Principle 1, Principle 2) without introducing a global state manager for a single-table concern. Switching views must feel instant (latency principle, A1) — optimistic rendering achieves this with zero server round-trips.
- **Alternatives considered:**
  - *Global Redux/Zustand store for views:* over-engineered for a scoped feature unless the app already uses a global store for similar things. Assumed not required (see Assumptions).
  - *Server-side state on every selection (persist last-used view):* not specified in the blueprint and adds write traffic on every selection event. Out of scope.
- **Trade-off accepted:** If two browser tabs are open on the same table, the view lists can diverge until the next mount/refresh. The blueprint does not require real-time cross-tab sync. Acceptable.

---

### D7. "Copy shared view" creates a fully independent row owned by the recipient

- **Decision:** When a recipient copies a shared view, the service creates a new `saved_views` row with `user_id = recipient`, copies the `config` payload, and assigns a name (original name or "Copy of …" if the name conflicts). No link is maintained to the original.
- **Why:** Blueprint states the recipient "then fully owns" the copy. A foreign-key link to the original would imply a derived relationship that doesn't exist after the copy and would complicate deletion semantics. Full independence is simpler (Principle 1).
- **Alternatives considered:**
  - *Maintain `copied_from_id` foreign key:* adds complexity with no present behavioral benefit. Rejected per YAGNI.
- **Trade-off accepted:** If the original changes after the copy, the copy does not reflect changes — consistent with "fully owned" semantics.

---

## 4. Data Model & Persistence

### Table: `saved_views`

| Column | Type | Constraints / Notes |
|---|---|---|
| `id` | `bigint` (PK) | Auto-increment |
| `user_id` | `bigint` (FK → users) | NOT NULL; indexed |
| `table_id` | `varchar(255)` | NOT NULL; identifier of the data table (see Assumption A3) |
| `name` | `varchar(255)` | NOT NULL |
| `config` | `jsonb` | NOT NULL; validated in model before save |
| `is_default` | `boolean` | NOT NULL DEFAULT false |
| `created_at` | `timestamp` | NOT NULL |
| `updated_at` | `timestamp` | NOT NULL |

**Indexes:**
- `UNIQUE (user_id, table_id, name)` — enforces unique name per user per table
- `UNIQUE (user_id, table_id) WHERE is_default = true` — partial index enforces single default
- Index on `user_id` (covered by above, but explicit for FK performance)

**`config` JSON schema (validated in model):**

```json
{
  "filters": [{ "field": "<string>", "operator": "<string>", "value": "<any>" }],
  "sort": { "field": "<string>", "direction": "asc|desc" } | null,
  "columns": ["<string>", ...]
}
```

All three keys are required; unknown keys are silently ignored at read time (forward-compatibility for future config extensions). `filters` and `columns` may be empty arrays; `sort` may be null.

---

### Table: `saved_view_shares`

| Column | Type | Constraints / Notes |
|---|---|---|
| `id` | `bigint` (PK) | Auto-increment |
| `saved_view_id` | `bigint` (FK → saved_views ON DELETE CASCADE) | NOT NULL; indexed |
| `target_type` | `varchar(20)` | NOT NULL; enum `'user'` or `'workspace'`; check constraint |
| `target_id` | `bigint` | Nullable; set when `target_type = 'user'`; holds `user_id` |
| `workspace_id` | `bigint` (FK → workspaces) | Nullable; set when `target_type = 'workspace'` |
| `created_at` | `timestamp` | NOT NULL |

**Indexes:**
- Index on `saved_view_id`
- Index on `(target_type, target_id)` for "what views can this user see?"
- Index on `(target_type, workspace_id)` for workspace-level shares
- `UNIQUE (saved_view_id, target_type, target_id)` (coalesce nulls appropriately) — prevents duplicate share rows

**Cascade:** `ON DELETE CASCADE` from `saved_views` — when a view is deleted, its share rows are automatically removed. Recipients lose access immediately, consistent with the blueprint's edge case.

---

### Migration shape

Two migrations:
1. `create_saved_views` — table, indexes, partial unique index on `is_default`.
2. `create_saved_view_shares` — table, indexes, FK with cascade.

No backfill required (new feature). Migrations are additive only. Reversible via `drop_table` in `down`.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| None | — | — | — | — | — |

No external services are required. All data is persisted in the application's own Postgres database. Email/notification integrations (if sharing triggers a notification) are explicitly out of scope for this design; if added later, treat as a separate integration concern.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| Load view list (table mount) | < 50 ms | < 150 ms | Single query with JOIN on shares; result set is small |
| Switch view (apply config) | < 20 ms | < 50 ms | Purely client-side; no server round-trip on selection |
| Save / rename / delete view | < 100 ms | < 300 ms | Single-row write + list re-fetch |
| Set default | < 100 ms | < 300 ms | Single-row UPDATE using partial unique index |
| Share / unshare | < 100 ms | < 300 ms | Insert/delete share row |

### Expected load

Assumed: a B2B SaaS with thousands of workspaces. Views per table per user: typically 1–20 (design is correct regardless up to several hundred). The feature is low-volume — view operations happen on deliberate user gestures, not on every table row render.

No hotspot expected: `user_id` + `table_id` scoping means writes are distributed across users. No fan-out on read.

### Caching

**No server-side cache is introduced.** Rationale (Principle 13 — cache invalidation is a design decision): the view list is tiny (< 2 KB per user per table), a plain Postgres query with indexed lookups is fast enough to hit the latency targets above, and the invalidation story for a shared cache (user deletes a view → everyone's cache must be purged) adds complexity that buys nothing measurable.

**Client-side:** the `useSavedViews` hook caches the view list in component state for the lifetime of the component. On any write (save, update, delete, share) the hook re-fetches. The browser's default HTTP cache (`ETag` / `Last-Modified`) can optionally be leveraged for the list GET if the app already uses it; this is not required for correctness.

**Freshness trade-off accepted:** A stale list between write actions in the same session is not possible (hook re-fetches on every write). Cross-tab staleness is accepted (see D6 trade-off).

---

## 7. Reliability & Failure Handling

### Failure scenarios

| Failure | Handling | User experience |
|---|---|---|
| DB unique constraint violation (duplicate name race) | Service catches `ActiveRecord::RecordNotUnique` → 422 | "A view with that name already exists." (blueprint deviation scenario) |
| DB connection failure on read | Rescue → 503 with Retry-After header | "Views couldn't be loaded. Try again." |
| DB write failure (transient) | No automatic retry at the HTTP layer; client shows error; user re-submits | "Couldn't save view. Try again." |
| Partial failure: set-default UPDATE race (two tabs) | Partial unique index makes the second UPDATE a constraint error → 409 | "Another session already updated your default. Refresh to see the latest." |
| Deleted shared view while recipient has it as default | Cascade delete removes shares; service returns empty-view state; frontend falls back to no-view | Table opens in plain state (blueprint edge case) |
| Recipient tries to write to a shared view | Service authZ check returns 403 before any DB write | "You don't have permission to edit this view." |

### Idempotency

- **Set default:** Idempotent — calling it twice produces the same state.
- **Save view:** Not idempotent by name (second call with same name → unique constraint error). Idempotent if client sends a request ID and service deduplicates (not required at this scale; note as future improvement if needed).
- **Delete:** Idempotent — deleting a non-existent ID returns 404, which the client treats the same as success (view is gone).
- **Share:** Insert-or-ignore semantics (upsert) makes re-sharing idempotent.

### Transactions

- **Set default:** Wrapped in a transaction: `UPDATE saved_views SET is_default = false WHERE user_id = ? AND table_id = ? AND is_default = true; UPDATE saved_views SET is_default = true WHERE id = ?`. The partial unique index makes the second step atomic with the constraint — but the explicit transaction is belt-and-suspenders.
- **Copy shared view:** Single INSERT (no transaction needed beyond the auto-commit).
- **Delete:** Single DELETE with cascade (atomic).

### Timeouts

Database query timeout: inherit the application's default (assumed 5 s). No custom timeout needed for these queries.

---

## 8. Security & Privacy

### Authentication

All endpoints require an authenticated session (existing Rails auth middleware). Unauthenticated requests → 401.

### Authorization (addressing blueprint adversarial scenarios)

| Check | Where enforced | Failure |
|---|---|---|
| Read own view | `SavedViewsService` — `WHERE user_id = current_user.id` scope | 404 (not 403, to avoid enumeration) |
| Read shared view | `SavedViewsService` — JOIN to `saved_view_shares` matching user or workspace | 404 if no share row found |
| Enumerate views | List endpoint scoped to `(current_user, table_id)` + joined shares; no cross-user leak | Only owned + explicitly shared views returned |
| Write (update/delete) | Service checks `owner? (current_user, view)` before any mutation | 403 |
| Recipient write attempt | Service returns 403 for any mutating action by a non-owner | 403 |

**Adversarial scenario A (blueprint):** A recipient cannot modify or delete the original view via any API request — enforced by the owner-check in the service layer before any write reaches the DB.

**Adversarial scenario B (blueprint):** A user cannot enumerate views they haven't been granted access to — enforced by scoped queries; a direct `GET /saved_views/:id` for an unshared view returns 404, not the view.

### Input validation

- `name`: stripped, max 255 characters, required.
- `table_id`: validated against known table identifiers in the application (prevent storing views for non-existent tables).
- `config` JSON: schema-validated in the model before persist (see §4). Unknown top-level keys are rejected (strict validation at write; lenient at read for forward-compat).
- All parameters run through Rails strong parameters (`permit`) in the controller before reaching the service.

### PII / data sensitivity

View configs may contain filter values that are business-sensitive (e.g. a filter on "assigned to: alice@example.com"). These are stored in the `config` jsonb column — the same sensitivity class as other user-authored data in the application. No PII beyond what the user explicitly includes in their own filter values. No special handling beyond standard DB encryption-at-rest (assumed to be the same as the rest of the application).

### Secrets

No new secrets. The feature uses only the existing DB connection.

---

## 9. Observability

### Logs

Standard Rails request logging covers all HTTP actions. Log the following additional context at `INFO` level per request:
- `saved_view_id`, `user_id`, `table_id` on every write action
- `action: save|update|delete|share|set_default|copy`
- On 403/404, log the attempted access (without leaking the target view's contents)

### Metrics

| Metric | Type | Tags | Alert threshold |
|---|---|---|---|
| `saved_views.save.count` | Counter | `status: success|error` | — |
| `saved_views.save.duration_ms` | Histogram | — | p95 > 500 ms for 5 min |
| `saved_views.apply.count` | Counter | `status: success|error` | — |
| `saved_views.share.count` | Counter | `target_type: user|workspace` | — |
| `saved_views.authz_denied.count` | Counter | `action` | Spike > 10/min (abuse signal) |

### The one signal that proves the feature is healthy

**`saved_views.save.count{status=success}` is non-zero and `saved_views.save.duration_ms p95 < 500 ms`** — views are being saved quickly. If this drops to zero or latency spikes, the feature is degraded.

### Traces

Instrument `SavedViewsService` methods with the app's existing APM tracer (assumed: Datadog/OpenTelemetry equivalent). Trace spans: `saved_views.list`, `saved_views.save`, `saved_views.share`, `saved_views.set_default`.

### No alerts for missing functionality

The blueprint includes no requirements for alerting on view count thresholds or anomaly detection. The authZ denial counter spike alert above is the only abuse-signal alert.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a feature flag: `saved_views_enabled` (boolean, default `false`). The flag is checked:
1. **Backend:** before any `SavedViewsController` action — returns 404 or an appropriate "feature not enabled" response if false.
2. **Frontend:** the `SavedViewsDropdown` component renders nothing (hides the dropdown) if the flag is false.

**Fail-closed:** if the flag check itself fails (flag service down), default to `false` — do not expose the feature unintentionally.

### Rollout order

1. Deploy migrations (additive only — no impact on existing tables).
2. Deploy backend code (flag defaulting to `false` — no user-visible change).
3. Deploy frontend code (hidden behind flag).
4. Enable flag for internal/test workspaces.
5. Gradual rollout to workspace cohorts (10% → 50% → 100%).
6. Remove flag once fully rolled out and stable.

### Reversibility

- Flag can be flipped to `false` at any time — the feature disappears from the UI and API calls return 404. Existing view data is preserved in the DB.
- Migrations are additive; no rollback of data is needed to flip the flag. If the migration itself must be rolled back (e.g. a bug), `drop_table` reverses cleanly since there are no existing foreign keys from other features into `saved_views`.

### Deploy coordination

No special coordination required between backend and frontend deploys. Backend can deploy with flag off; frontend deploy follows. Both can be deployed independently.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | A `table_id` is a stable, string identifier already defined in the application (e.g. a model name or an internal slug). | Standard pattern for multi-table apps; blueprint references "the table it belongs to." | Yes — confirm `table_id` is a stable identifier and how it is obtained from the frontend. |
| A2 | A `workspace_id` is available on the user session / user record; workspace membership is enforced by existing auth middleware. | B2B SaaS apps universally carry workspace context in session. | Yes — confirm workspace is available without an extra query. |
| A3 | The application does not already have an authorization library (Pundit / CanCanCan). If it does, authorization belongs in a policy class in that library's style, not in a bespoke service method. | Blueprint and task description give no indication of an auth library in use. | Yes — check if auth library exists before implementing service-layer authZ. |
| A4 | The application uses Rails `jsonb` on Postgres (not `json` type or MySQL JSON). | Task states "Rails + Postgres." | No — `jsonb` is the standard Postgres JSON column type for Rails. |
| A5 | View counts per user per table will remain in the single-digit hundreds at most, making unbounded list queries safe without pagination. | Typical B2B use case. | No — revisit if workspaces with large automated view creation emerge. |
| A6 | No cross-workspace sharing is required (the blueprint specifies "specific teammates or their whole workspace" — implying a single workspace). | Blueprint text supports this. | Yes — confirm sharing is always within one workspace. |
| A7 | The application already has a feature-flag mechanism (e.g. Flipper, LaunchDarkly, or an ENV flag pattern). | Standard for production Rails apps. | Yes — confirm flag mechanism and naming convention. |
| A8 | "Table" in the blueprint refers to a UI data table within the app, not a database table. `table_id` is an application-level concept, not a DB identifier. | Consistent with the product description ("filters, sort, visible columns"). | No — this reading is unambiguous from the blueprint. |
| A9 | The frontend does not use a global state manager (Redux/Zustand) for this feature. Component-local state is appropriate. | Blueprint and task description give no indication of a global store requirement. | Yes — confirm frontend state management approach before starting frontend implementation. |
| A10 | Notification/email to share recipients when a view is shared is out of scope for this design. | Not mentioned in the blueprint. Blueprint only specifies data access behavior for shared views. | No — blueprint is silent; out of scope. |
| A11 | The application uses standard Rails migration tooling and ActiveRecord models. | Task states "Rails + Postgres app." | No. |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | No server-side cache for view lists | Slightly higher DB load per table mount | Principle 12 (Cost as first-class constraint) | View lists are tiny; indexed query is < 5 ms at current scale; adding a cache layer adds invalidation complexity (Principle 13) for no measurable benefit | If DB load from saved-views queries appears in profiling (measure, don't guess — Principle 8) |
| C2 | No pagination on the view list endpoint | Unbounded response if a user creates hundreds of views | Principle 6 (Bounded operations) | At realistic view counts (< 100 per user per table), a single query + JSON payload is under 5 KB; pagination adds client complexity for a list unlikely to exceed this | If any workspace has users with > 200 views per table, add cursor pagination |
| C3 | Cross-tab view list staleness accepted | Two tabs can show different view lists until one remounts | Principle 14 (Least surprise) | The blueprint's only concurrent-tab scenario is the duplicate-name race (handled by DB constraint); real-time sync would require WebSocket/polling and is disproportionate complexity | If user research shows cross-tab confusion is a real pain point |
| C4 | `config` internals are opaque to SQL (stored as jsonb) | Can't query "all views using filter X" without GIN index | Principle 4 (Get the data model right) | No present requirement to query by filter contents; jsonb preserves flexibility for filter schema evolution | If a future requirement needs filter-content search, add a GIN index on `config` |

---

## 13. Open Risks & Callouts

1. **`table_id` stability:** If `table_id` values can change (e.g. a table is renamed), saved views referencing the old ID become orphaned. The service should either validate `table_id` on every write against the live list of tables, or establish a contract that `table_id` is immutable once assigned. This needs explicit confirmation (see A1).

2. **`config` schema evolution:** Adding a new filter operator or column type requires updating the JSON Schema validator. If the validator is too strict, older clients submitting views with new config fields will be rejected. Recommendation: validate required top-level keys (`filters`, `sort`, `columns`) strictly, but pass through unknown keys within nested objects to allow forward-compat. Define the validation boundary carefully before implementing.

3. **Authorization library conflict (A3):** If an auth library (Pundit, etc.) is already in use, a bespoke `SavedViewsService` authZ layer will be inconsistent with the codebase pattern. This is the highest-priority assumption to confirm before writing the service.

4. **Workspace scope of sharing:** If multi-workspace users exist (a user in multiple workspaces), "share with workspace" must be scoped to the correct workspace. The `workspace_id` column on `saved_view_shares` handles this, but the frontend must pass the correct `workspace_id` when initiating a workspace-wide share. Requires frontend/backend alignment on workspace context in the request.

5. **`name` deduplication on "Copy" action:** When copying a shared view, if the name "My open bugs" already exists for the recipient, the service must generate a non-conflicting name. The blueprint does not specify the fallback name format. Assumed: "Copy of My open bugs"; if that also conflicts, append a counter ("Copy of My open bugs (2)"). This should be confirmed or noted as a follow-up behavioral decision for the blueprint.

---

## 14. Out of Scope

The following are explicitly excluded from this design (per the blueprint's Out of Scope section, plus design-level exclusions):

- **View versioning / history:** no audit trail of config changes to a view.
- **Scheduled or automated view switching:** no time-based or event-based default changes.
- **Per-row data snapshots:** a view is a configuration only, never a data snapshot.
- **Notifications or emails** when a view is shared with a user (no notification pipeline designed here).
- **Real-time cross-tab sync** of view list changes.
- **Pagination of the view list** (covered in C2 — intentionally deferred).
- **Search or filter within the views dropdown** (not in the blueprint).
- **Bulk operations** on views (delete many, share many).
- **Export / import of views** between tables or workspaces.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets per action; optimistic UI for switching |
| A2 Throughput & scale | Assumed (A5) | §6 — low-volume, O(views per user per table) queries; no hotspot |
| A3 Concurrency & consistency | Resolved | §3 D3, §7 — DB unique constraints + partial index handle race; transactions for set-default |
| A4 Availability & reliability | Resolved | §7 — per-failure handling; no external deps to fail |
| A5 Data integrity & durability | Resolved | §4 — DB constraints, cascade deletes, JSON schema validation; §3 D3 |
| A6 Caching & freshness | Resolved | §6 — no server-side cache (justified); client-side component-state cache; cross-tab staleness accepted (C3) |
| A7 Cost | Resolved | §5 — no external services; DB-only cost is negligible at scale; C1 covers cache decision |
| A8 Security & privacy | Resolved | §8 — authN/Z, input validation, adversarial scenarios, PII scope |
| A9 Observability | Resolved | §9 — logs, metrics, traces, health signal, abuse alert |
| A10 Maintainability & simplicity | Resolved | §3 D1, D5 — fewest moving parts; follows existing Rails patterns; no new service boundary |
| A11 Testability | Resolved | §3 D4 — service layer is injectable; no external deps to mock; DB constraints testable with model specs; authZ fully unit-testable |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration-first rollout order, reversibility |
| A13 Backward compatibility | Assumed (A11) | New feature, no existing data or API contracts changed. Additive migrations only. |
| A14 Accessibility & device/env | Assumed | `SavedViewsDropdown` must follow the app's existing component library conventions (keyboard navigation, ARIA `role="listbox"`, screen-reader labels). No special offline behavior required — network errors surface via error state in the hook. Not addressed in depth here; deferred to frontend implementation conventions. |
| B1 Placement / module taxonomy | Resolved | §2 — new `SavedViewsController` + `SavedViewsService` + models; no new service boundary |
| B2 Data model & persistence | Resolved | §4 — two new tables, schema, indexes, constraints, migration shape |
| B3 API surface & schemas | Resolved | §3 D3, §4 — RESTful routes on `SavedViewsController`; request/response schemas defined in §4 |
| B4 Async / background work | Resolved | §3 D5 — all synchronous; no background jobs needed |
| B5 External services & contracts | Resolved (N/A) | §5 — no external services required |
| B6 Frontend integration | Resolved | §3 D6 — `useSavedViews` hook, component-local state, optimistic view switching, re-fetch on write |
| B7 Feature flags & rollout | Resolved | §10 — `saved_views_enabled` flag, fail-closed, staged rollout |
| B8 Error handling | Resolved | §7, §8 — per-layer error handling; unique constraint → 422; authZ denial → 403; not-found → 404; DB failure → 503 |

---

## Appendix A: Captured Inputs

> This design was produced autonomously (no human interview was available). The sections below record each decision fork, the recommendation made, the autonomous resolution, and the reasoning. Where the skill would normally ask a question, the best-reasoned answer was chosen from the blueprint and generic design principles, and any residual uncertainty is recorded as an Assumption or Open Risk.

---

### Topic 1: Configuration storage — JSON column vs. normalized rows

- **Question:** Should the filter/sort/column payload be stored as a single JSON column or normalized into relational rows (one row per filter, one per sort key, one per column)?
- **Recommendation given:** JSON column (`jsonb`) with schema validation in the model. Grounded in Principle 1 (simplicity first) and Principle 7 (reversible decisions) — normalization adds three join tables for no present query benefit, and jsonb preserves flexibility for config schema evolution.
- **Decision taken:** jsonb column. See D1.
- **Notes:** The blueprint's "silently ignore removed columns" edge case is trivially handled with JSON (just skip unknown keys); with normalized rows it would require cascading deletes or null handling across join tables.

---

### Topic 2: Sharing model — join table vs. flag on the view

- **Question:** Should sharing be modeled as a join table (`saved_view_shares`) or as a flag/array embedded in the view row?
- **Recommendation given:** Separate join table with `target_type` enum. Grounded in Principle 3 (high cohesion, loose coupling) and Principle 9 (make illegal states unrepresentable) — a boolean `is_shared` can't represent user-specific vs. workspace sharing without additional columns, and an embedded array is hard to query.
- **Decision taken:** Join table `saved_view_shares`. See D2.
- **Notes:** Join table also naturally supports future expansion (e.g. group sharing) without a schema change.

---

### Topic 3: Uniqueness and default invariant enforcement

- **Question:** Should uniqueness (name per user per table) and the single-default constraint be enforced at the application level only, or also at the DB level?
- **Recommendation given:** DB-level (unique index + partial unique index). Grounded in Principle 9 (make illegal states unrepresentable). The blueprint explicitly calls out the two-tab race condition — application-level checks alone cannot prevent it.
- **Decision taken:** Both constraints in the DB. See D3.
- **Notes:** The partial unique index `WHERE is_default = true` is the cleanest way to enforce single-default atomically without a two-step UPDATE sequence.

---

### Topic 4: Authorization placement

- **Question:** Should authZ logic live in the controller, in a service object, or in a policy library (Pundit/CanCanCan)?
- **Recommendation given:** Service layer (`SavedViewsService`), with a note to defer to an existing auth library if one is present. Grounded in Principle 3 (high cohesion) and Principle 2 (match existing patterns).
- **Decision taken:** Service layer, conditional on no existing auth library (Assumption A3). See D4.
- **Notes:** This is the most important assumption to confirm before implementation — if Pundit is already used, skip the service-level authZ and write a Pundit policy instead.

---

### Topic 5: Sync vs. async operations

- **Question:** Should any write operations (e.g. share fan-out) be deferred to a background job?
- **Recommendation given:** All synchronous. Grounded in Principle 1 (simplicity first) and Principle 5 (design for failure — a synchronous failure is easier to surface than a failed background job).
- **Decision taken:** All synchronous. See D5.
- **Notes:** The blueprint has no notification/fan-out requirement. If notifications are added later, a background job would be appropriate at that point.

---

### Topic 6: Frontend state management

- **Question:** Should view list state be global (Redux/Zustand) or component-local?
- **Recommendation given:** Component-local state in a `useSavedViews` hook. Grounded in Principle 1 (simplicity first) — global state for a scoped, single-table feature is over-engineered unless the app already uses it.
- **Decision taken:** Component-local. See D6.
- **Notes:** Optimistic UI for view switching means no server round-trip on selection — instant perceived performance without caching complexity.

---

### Topic 7: Caching

- **Question:** Should view lists be cached (server-side Redis, CDN, or HTTP cache)?
- **Recommendation given:** No server-side cache. Grounded in Principle 13 (cache invalidation is a design decision) — the invalidation story (every write by any user with access to a shared view) is complex; the query is fast enough without caching.
- **Decision taken:** No server-side cache; client-side component-state cache for session duration. See §6, C1.
- **Notes:** Client HTTP cache (`ETag`) is optionally usable but not required for correctness.

---

### Topic 8: "Copy shared view" behavior

- **Question:** Should the copy maintain a link (`copied_from_id`) to the original, or be fully independent?
- **Recommendation given:** Fully independent. Grounded in Principle 1 (simplicity first) — the blueprint says the recipient "then fully owns" the copy; a foreign key implies a derived relationship that has no behavioral use.
- **Decision taken:** Fully independent row, no `copied_from_id`. See D7.
- **Notes:** Name conflict on copy (recipient already has a view with the same name) is an open question for the blueprint. Autonomous decision: "Copy of <name>" with counter fallback.

---

### Topic 9: Pagination of view list

- **Question:** Should the list endpoint paginate?
- **Recommendation given:** No pagination initially (assume < 100 views per user per table). Accepted as compromise C2 with a trigger to revisit.
- **Decision taken:** No pagination. See C2, A5.
- **Notes:** If automation creates large numbers of views per user, pagination would be needed.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** No human available. The following were surfaced as residual risks by the autonomous review pass:
  - `table_id` stability contract (Open Risk 1)
  - `config` schema validation boundary (Open Risk 2)
  - Authorization library check (Open Risk 3, = Assumption A3)
  - Workspace scope for multi-workspace users (Open Risk 4)
  - Name deduplication on "Copy" action (Open Risk 5)
