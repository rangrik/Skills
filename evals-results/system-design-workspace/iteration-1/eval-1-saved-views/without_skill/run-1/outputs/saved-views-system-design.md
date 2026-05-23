# System Design: Saved Views

**Status:** Draft  
**Date:** 2026-05-23  
**Stack:** Ruby on Rails · PostgreSQL · React

---

## 1. Overview

Saved Views allows users to capture a named snapshot of a data table's UI configuration — filters, sort order, and column visibility — and restore that configuration with a single click. Views belong to the creating user, can be shared read-only with teammates or a whole workspace, and support one default view per user per table.

This document covers the database schema, API design, backend service layer, frontend state management, authorization model, and operational concerns.

---

## 2. Goals and Non-Goals

### Goals
- Persist filter sets, sort configuration, and column layout per named view.
- Enforce per-user ownership with controlled read-only sharing.
- Allow one default view per user per table.
- Handle degraded-state edge cases gracefully (deleted columns, deleted filter values, deleted shared views).
- Prevent duplicate view names per user per table under concurrent writes.

### Non-Goals (per blueprint)
- View versioning or change history.
- Scheduled or automated view switching.
- Snapshotting row data — views store configuration only.

---

## 3. Data Model

### 3.1 Entity Relationship Summary

```
users ──< saved_views >── tables
saved_views ──< view_shares
users ──< user_default_views
```

### 3.2 Table: `saved_views`

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` PK | auto-increment |
| `user_id` | `bigint` FK → `users` | owner |
| `table_identifier` | `varchar(255)` | logical table key (see §3.6) |
| `name` | `varchar(255)` | display name |
| `filters` | `jsonb` | array of filter descriptors |
| `sort_field` | `varchar(255)` | nullable |
| `sort_direction` | `varchar(4)` | `'asc'` or `'desc'`, nullable |
| `column_order` | `jsonb` | ordered array of column keys |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

**Indexes:**
```sql
-- Unique name per user per table (enforces duplicate-name rule)
CREATE UNIQUE INDEX idx_saved_views_unique_name
  ON saved_views (user_id, table_identifier, name);

-- Fast lookup of all views owned by a user for a table
CREATE INDEX idx_saved_views_user_table
  ON saved_views (user_id, table_identifier);
```

### 3.3 Table: `view_shares`

Tracks who has been granted read-only access to a view.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` PK | |
| `saved_view_id` | `bigint` FK → `saved_views` ON DELETE CASCADE | |
| `scope` | `varchar(20)` | `'user'` or `'workspace'` |
| `recipient_user_id` | `bigint` FK → `users`, nullable | set when scope = `'user'` |
| `workspace_id` | `bigint` FK → `workspaces`, nullable | set when scope = `'workspace'` |
| `created_at` | `timestamptz` | |

**Constraint:** `(scope = 'user' AND recipient_user_id IS NOT NULL AND workspace_id IS NULL)` OR `(scope = 'workspace' AND workspace_id IS NOT NULL AND recipient_user_id IS NULL)` — enforced at the application layer and via a DB check constraint.

**Indexes:**
```sql
CREATE INDEX idx_view_shares_view_id ON view_shares (saved_view_id);
CREATE INDEX idx_view_shares_recipient ON view_shares (recipient_user_id) WHERE scope = 'user';
CREATE INDEX idx_view_shares_workspace ON view_shares (workspace_id) WHERE scope = 'workspace';
```

The `ON DELETE CASCADE` on `saved_view_id` means that when an owner deletes a view, all share records are automatically removed.

### 3.4 Table: `user_default_views`

Stores one default view per user per table. Using a separate table keeps the logic clean and makes "no default" the zero-row state rather than requiring a nullable column across many rows.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` PK | |
| `user_id` | `bigint` FK → `users` | |
| `table_identifier` | `varchar(255)` | |
| `saved_view_id` | `bigint` FK → `saved_views`, nullable | nullable to support "cleared default" without deleting the row |
| `updated_at` | `timestamptz` | |

**Assumption:** `saved_view_id` is nullable so the row can be retained as a tombstone when the default view is deleted, avoiding a re-create race. The application treats a `NULL` `saved_view_id` as "no default."

**Indexes:**
```sql
CREATE UNIQUE INDEX idx_user_default_views_unique
  ON user_default_views (user_id, table_identifier);
```

### 3.5 JSONB Schemas

**`filters` column** — array of filter objects:
```json
[
  {
    "field": "status",
    "operator": "eq",
    "value": "open"
  },
  {
    "field": "assignee_id",
    "operator": "in",
    "value": [42, 87]
  }
]
```

**`column_order` column** — ordered array of column key strings:
```json
["id", "title", "status", "assignee", "created_at"]
```

No schema migration is required when new operators are added; JSONB is intentionally schemaless here.

### 3.6 `table_identifier`

A stable string key that identifies which data table a view belongs to (e.g., `"issues"`, `"projects"`, `"contacts"`). It is defined by the frontend and must never change after views are saved against it. Renaming a table's identifier would orphan existing views. Treat it as an enum maintained in a constants file on both sides of the API.

---

## 4. API Design

All endpoints are under `/api/v1/`. Authentication is assumed via session cookies or a bearer token — the existing app auth mechanism applies. All responses are JSON.

### 4.1 Saved Views CRUD

#### `GET /api/v1/tables/:table_identifier/views`

Returns all views the current user can see for a given table: their own views plus any views shared with them (individually or via workspace).

**Response:**
```json
{
  "views": [
    {
      "id": 12,
      "name": "My open bugs",
      "owned_by_me": true,
      "is_default": true,
      "filters": [...],
      "sort_field": "created_at",
      "sort_direction": "desc",
      "column_order": [...]
    },
    {
      "id": 34,
      "name": "Team's sprint view",
      "owned_by_me": false,
      "owner": { "id": 5, "name": "Alice" },
      "is_default": false,
      "filters": [...],
      "sort_field": "priority",
      "sort_direction": "asc",
      "column_order": [...]
    }
  ]
}
```

`owned_by_me: false` indicates a shared read-only view. The frontend uses this flag to hide Edit/Delete/Rename controls.

#### `POST /api/v1/tables/:table_identifier/views`

Creates a new view for the current user.

**Request body:**
```json
{
  "name": "My open bugs",
  "filters": [...],
  "sort_field": "created_at",
  "sort_direction": "desc",
  "column_order": [...]
}
```

**Responses:**
- `201 Created` — returns the new view object.
- `422 Unprocessable Entity` — `{ "error": "name_taken", "message": "A view with that name already exists." }` — returned when the unique index raises a conflict.

#### `PATCH /api/v1/views/:id`

Updates a view (name, filters, sort, columns). Only the owner may call this.

**Response:** `200 OK` with updated view, or `403 Forbidden` if the caller is not the owner.

#### `DELETE /api/v1/views/:id`

Deletes a view. Only the owner may call this. Cascades to `view_shares`. Recipients who had this view as their default will have their `user_default_views.saved_view_id` set to `NULL` (handled by a `before_destroy` callback or DB foreign key with `SET NULL`).

**Response:** `204 No Content`, or `403 Forbidden`.

### 4.2 Default View

#### `PUT /api/v1/tables/:table_identifier/default_view`

Sets the current user's default view for a table. Pass `view_id: null` to clear.

**Request body:**
```json
{ "view_id": 12 }
```

**Behavior:** Upserts a row in `user_default_views`. If `view_id` is not null, validates that the user can see that view (owns it or it's shared with them).

**Response:** `200 OK`.

### 4.3 View Sharing

#### `POST /api/v1/views/:id/shares`

Shares the view. Only the owner may call this.

**Request body (user-scoped share):**
```json
{ "scope": "user", "recipient_user_id": 99 }
```

**Request body (workspace-scoped share):**
```json
{ "scope": "workspace", "workspace_id": 3 }
```

**Response:** `201 Created` with the share record, or `422` on invalid input, or `403` if the caller is not the owner.

#### `DELETE /api/v1/views/:id/shares/:share_id`

Revokes a share. Only the owner may call this.

**Response:** `204 No Content`.

### 4.4 Copy a Shared View

#### `POST /api/v1/views/:id/copy`

Creates a new view owned by the current user, with the same configuration as the source view. The source must be visible to the current user (shared with them). The caller may optionally supply a new name.

**Request body:**
```json
{ "name": "My copy of Alice's sprint view" }
```

**Response:** `201 Created` with the new view (caller now owns it).

---

## 5. Backend Service Layer

### 5.1 `SavedViewsQuery`

Encapsulates the visibility query: "all views the user can see for a table." The SQL:

```sql
SELECT sv.*
FROM saved_views sv
WHERE sv.user_id = :current_user_id
  AND sv.table_identifier = :table_identifier

UNION

SELECT sv.*
FROM saved_views sv
JOIN view_shares vs ON vs.saved_view_id = sv.id
WHERE sv.table_identifier = :table_identifier
  AND (
    (vs.scope = 'user'      AND vs.recipient_user_id = :current_user_id)
    OR
    (vs.scope = 'workspace' AND vs.workspace_id = :user_workspace_id)
  )
```

This is encapsulated in a query object / scope so all endpoints use the same visibility logic.

### 5.2 `SavedViewsController` (Rails)

Thin controller: authenticate, authorize via `SavedViewPolicy` (Pundit), delegate to service objects, render JSON via a serializer (e.g., `SavedViewSerializer` using `jsonapi-serializer` or a plain Ruby serializer).

### 5.3 `DefaultViewService`

Handles the upsert for `user_default_views` and the "set new default clears the previous one" rule. Uses `upsert` (Rails 6+) on the `(user_id, table_identifier)` unique index to avoid a race between read-then-write.

```ruby
UserDefaultView.upsert(
  { user_id: current_user.id, table_identifier: table_identifier, saved_view_id: view_id },
  unique_by: [:user_id, :table_identifier]
)
```

### 5.4 `SavedViewCopyService`

Reads the source view, authorizes visibility, creates a new `SavedView` with `user_id = current_user.id` and an optional new name. Raises `ActiveRecord::RecordInvalid` if the name is taken, surfaced as a 422.

### 5.5 Handling the Deleted-View Default Fallback

When `saved_views` is deleted, the foreign key on `user_default_views.saved_view_id` is set to `NULL` via `ON DELETE SET NULL`. The API then returns `is_default: false` for all views, and the frontend table opens in plain default state.

```sql
ALTER TABLE user_default_views
  ADD CONSTRAINT fk_user_default_view
  FOREIGN KEY (saved_view_id) REFERENCES saved_views(id)
  ON DELETE SET NULL;
```

---

## 6. Authorization Model

Uses Pundit policies.

**`SavedViewPolicy`:**

| Action | Allowed when |
|---|---|
| `index?` | always (scoped by `SavedViewsQuery`) |
| `create?` | always authenticated |
| `update?` | `record.user_id == current_user.id` |
| `destroy?` | `record.user_id == current_user.id` |
| `copy?` | user can see the view (owner or recipient) |
| `share?` | `record.user_id == current_user.id` |

Recipients of shared views have no write path to the original. The `update?` and `destroy?` checks ensure a 403 is returned even if a recipient constructs a raw request to `PATCH /api/v1/views/:id`.

---

## 7. Frontend Design

### 7.1 State Management

The views list lives in a React context (or Redux slice if the app already uses Redux) scoped to the table component. Shape:

```ts
interface ViewsState {
  views: SavedView[];
  defaultViewId: number | null;
  activeViewId: number | null;   // currently applied view (null = no view)
  status: 'idle' | 'loading' | 'error';
}
```

`activeViewId` is local UI state and is not persisted to the server — applying a view is a client-side operation. Only the default view choice is persisted.

### 7.2 Applying a View

When the user selects a view from the dropdown, the frontend:

1. Reads the view's `filters`, `sort_field`, `sort_direction`, and `column_order` from the local `views` array.
2. Dispatches these values to the table's filter/sort/column state.
3. The table re-renders with the new configuration.

No additional network request is needed to apply a view. The view data was already fetched in the initial `GET /views` call.

### 7.3 Grace-Degradation for Missing Columns/Filters

When applying a view, the frontend filters `column_order` against the table's current registered columns. Unknown column keys are silently dropped (matching the blueprint's edge-case rule). Similarly, when filters reference values that no longer exist, the filter is applied as-is; a zero-result set is a valid outcome and the user can edit the filter.

### 7.4 Unsaved-Changes Guard

If the user modifies filters or columns while a view is active, `activeViewId` is set to `null` (or an "unsaved" sentinel) to indicate the table state diverges from any saved view. The "Save view" button and a "Save changes to current view" affordance appear.

### 7.5 Views Dropdown

```
[ Views ▼ ]
  ✓ My open bugs         (default indicator + checkmark = active)
    Team's sprint view   (shared, read-only — no edit/delete icons)
    ─────────────────
    + Save current view
```

Shared read-only views are labeled; their context menus omit Rename/Edit/Delete and show only "Copy to my views."

### 7.6 Optimistic UI

`POST /views` and `DELETE /views/:id` are sent optimistically: the local `views` array is updated immediately, then rolled back if the server returns an error. `PATCH /views/:id` is not optimistic (the form stays open until confirmation).

---

## 8. Concurrency and Consistency

### 8.1 Duplicate-Name Race

Two tabs submitting the same name simultaneously both hit `POST /views`. The database unique index on `(user_id, table_identifier, name)` ensures only one insert succeeds. Rails rescues `ActiveRecord::RecordNotUnique` and re-raises it as a `422` with `error: "name_taken"`. This satisfies the blueprint's deviation scenario without any application-level locking.

### 8.2 Default View Upsert

Using `upsert` (a single `INSERT ... ON CONFLICT DO UPDATE` statement) makes setting a new default atomic. No two concurrent requests can both "win" and leave two defaults in place.

---

## 9. Key Migrations

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_saved_views.rb
create_table :saved_views do |t|
  t.references :user, null: false, foreign_key: true
  t.string  :table_identifier, null: false
  t.string  :name, null: false
  t.jsonb   :filters,      null: false, default: []
  t.string  :sort_field
  t.string  :sort_direction
  t.jsonb   :column_order, null: false, default: []
  t.timestamps
end
add_index :saved_views, [:user_id, :table_identifier, :name], unique: true
add_index :saved_views, [:user_id, :table_identifier]

# db/migrate/YYYYMMDDHHMMSS_create_view_shares.rb
create_table :view_shares do |t|
  t.references :saved_view, null: false, foreign_key: { on_delete: :cascade }
  t.string  :scope, null: false
  t.bigint  :recipient_user_id
  t.bigint  :workspace_id
  t.timestamp :created_at, null: false
end
add_index :view_shares, :saved_view_id
add_index :view_shares, :recipient_user_id
add_index :view_shares, :workspace_id

# db/migrate/YYYYMMDDHHMMSS_create_user_default_views.rb
create_table :user_default_views do |t|
  t.references :user, null: false, foreign_key: true
  t.string  :table_identifier, null: false
  t.bigint  :saved_view_id  # nullable; FK added separately for ON DELETE SET NULL
  t.timestamp :updated_at, null: false
end
add_index :user_default_views, [:user_id, :table_identifier], unique: true
add_foreign_key :user_default_views, :saved_views,
                column: :saved_view_id, on_delete: :nullify
```

---

## 10. Performance Considerations

- The `GET /tables/:table_identifier/views` query uses indexed lookups on both `saved_views` and `view_shares`; even at thousands of views per table the query is fast.
- JSONB columns are stored inline in the row; no secondary tables are needed for filter/column data.
- Response payloads for the views list are small (each view is a few hundred bytes). No pagination is required unless a user accumulates an unusual number of views; 50–100 is the expected realistic ceiling.
- No caching layer is required at launch. If read frequency warrants it, a short-lived Rails cache keyed on `(user_id, table_identifier, updated_at_max)` can be added later.

---

## 11. Security Considerations

- All endpoints require authentication; unauthenticated requests receive `401`.
- `GET /tables/:table_identifier/views` uses `SavedViewsQuery` which scopes results to the current user — no view belonging to a non-sharing user can leak into the response.
- `PATCH` and `DELETE` on views are gated by `user_id == current_user.id` in the Pundit policy; a shared-view recipient receives `403`.
- `table_identifier` is treated as a safe string (alphanumeric + underscores); it is parameterized in SQL and never interpolated.
- JSONB filter content is stored and returned as-is and never evaluated server-side; XSS risk is mitigated by the React frontend escaping user-provided strings in filter values during render.

---

## 12. Testing Plan

### Unit / Model Tests
- `SavedView` validations: name uniqueness per user+table.
- `DefaultViewService`: upsert replaces previous default; `view_id: nil` clears default.
- `SavedViewCopyService`: copy sets correct owner; inherits configuration; fails if name taken.

### Policy Tests (Pundit)
- Owner can update/delete their own views.
- Recipient cannot update/delete a shared view.
- User cannot see views belonging to others if not shared.

### Integration / Request Tests
- `POST /views` with duplicate name returns 422.
- Concurrent duplicate-name test (two requests in the same DB transaction boundary) verifies the unique index holds.
- `DELETE /views/:id` by owner nullifies `user_default_views.saved_view_id` for recipients.
- `GET /views` does not return views from users who have not shared with the caller.

### Frontend Tests
- Applying a view with a missing column silently drops that column.
- Applying a view with a stale filter value renders the table with zero results (no crash).
- `owned_by_me: false` hides edit/delete controls in the dropdown.

---

## 13. Open Questions (resolved as assumptions)

| Question | Assumption Made |
|---|---|
| Is there one workspace per account or many? | One workspace per account; `workspace_id` matches the user's `workspace_id`. Sharing "with the workspace" means all members of that workspace. |
| Does the app already have a `workspaces` table? | Yes; `workspace_id` is an existing foreign key on `users`. |
| How are table identifiers defined? | Stable string constants defined in a shared constants file. The frontend sends the same string the Rails routes use. |
| What JSON serializer is in use? | Assumed `jsonapi-serializer` (fast, common in Rails apps); plain Ruby serializers are equally valid. |
| Does the app use Pundit or another authz library? | Pundit assumed; if CanCanCan is in use, the policy logic is identical — only the DSL changes. |
| Should `view_shares` support team/group sharing? | Out of scope for this iteration; only `user` and `workspace` scopes are implemented. |
