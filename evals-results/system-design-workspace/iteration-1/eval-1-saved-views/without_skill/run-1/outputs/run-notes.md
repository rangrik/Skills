# Run Notes

**Date:** 2026-05-23  
**Task:** Saved Views system design (autonomous run, no human clarification)

## Key Decisions and Assumptions

**Table identifier as string constant.** The blueprint says views belong to "a table" but does not specify how tables are identified. I assumed a stable string key (e.g., `"issues"`) defined as a shared constant on both frontend and backend, rather than a FK to a `tables` DB table, because the app appears to have a fixed set of data tables rather than user-defined ones.

**Separate `user_default_views` table.** Instead of a `is_default` boolean on `saved_views`, I used a separate table with a `(user_id, table_identifier)` unique index. This makes the "at most one default per user per table" invariant enforced by the database rather than application logic, and lets `ON DELETE SET NULL` cleanly handle the deleted-shared-view fallback.

**`ON DELETE SET NULL` for default views.** When the owning user deletes a shared view, recipients who had it as their default fall back to no-default state. This is handled via a FK constraint rather than a Rails callback.

**`upsert` for default view changes.** Setting a new default uses a single `INSERT ... ON CONFLICT DO UPDATE` statement to avoid the read-modify-write race.

**Workspace membership assumed.** "Share with workspace" is interpreted as all users sharing the owner's `workspace_id`.
