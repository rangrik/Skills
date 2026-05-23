# Run Notes — Saved Views System Design (Run 1, Iteration 2)

**Produced autonomously; no human interview was conducted.**

## Key decisions made autonomously

1. **Separate `saved_view_shares` table** (vs. JSON column) — chosen for referential integrity and clean authorization queries; the adversarial scenarios in the blueprint made a DB-level boundary essential.
2. **Unique index on `(user_id, table_id, name)`** — the only correct answer for the "two tabs" concurrent duplicate-name race; application-level check alone has a TOCTOU gap.
3. **JSONB for view config** — semi-structured, varies by table type; normalizing would require schema changes for every table type added later.
4. **No server-side cache** — low-read-frequency CRUD; Postgres with index is fast enough; cache invalidation complexity not warranted.
5. **Soft cap of 100 views per user per table** — blueprint silent on this; 100 chosen as a generous but safe default (flagged for PM confirmation).

## What I would have asked a human

- Confirm the view cap number (100 assumed).
- Confirm FK type for `tables` table (integer vs. UUID).
- Confirm user-deletion cascade contract (orphaned views risk).
- Confirm feature-flag delivery mechanism to the frontend.
- Confirm workspace membership query / association model.
