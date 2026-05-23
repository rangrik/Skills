# Behavior Blueprint: Saved Views

**Status:** Approved · **Date:** 2026-05-12

## Summary

Lets a user capture the current configuration of a data table — its
filters, sort order, and visible columns — as a named "view," then switch
between views with one click. A user can mark one view as their default and
share a view with teammates as read-only.

## Happy path

1. A user filters, sorts, and hides/shows columns on a data table until it
   looks the way they want.
2. They click "Save view," give it a name (e.g. "My open bugs"), and save.
3. The view appears in a "Views" dropdown above the table.
4. Selecting a view from the dropdown re-applies its filters, sort, and
   column configuration to the table.
5. The user can set any of their views as the default, which loads
   automatically when they open that table.

## Behaviors and rules

- A view stores: the filter set, the sort field and direction, the ordered
  list of visible columns, and the table it belongs to.
- A view belongs to the user who created it. Other users do not see it
  unless it is shared.
- A user may share a view with specific teammates or with their whole
  workspace. Shared views are **read-only** for recipients — they can
  select and use the view but cannot rename, edit, or delete it.
- A recipient of a shared view can "copy" it into one of their own views,
  which they then fully own.
- Each user has at most one default view per table. Setting a new default
  clears the previous one.
- View names must be unique per user per table.

## Edge cases

- **A column referenced by a saved view is later removed from the table:**
  the view loads and silently ignores the missing column.
- **A filter references a value that no longer exists** (e.g. a deleted
  label): the filter is kept but matches nothing; the user can edit it.
- **The owner of a shared view deletes it:** recipients lose access; if a
  recipient had it set as default, the table falls back to no view.
- **A user has no views:** the table opens in its plain default state and
  the dropdown shows only "Save view."

## Deviation scenarios

- **Two of the user's browser tabs save a view with the same name at once:**
  the second save is rejected with a "name already in use" message rather
  than creating a duplicate.
- **A shared view is updated by its owner:** recipients see the updated
  configuration the next time they select it.

## Adversarial scenarios

- A recipient of a read-only shared view must not be able to modify or
  delete the original through any request.
- A user must not be able to load or enumerate views belonging to users who
  have not shared with them.

## Out of scope

- Versioning or history of changes to a view.
- Scheduled or automated view switching.
- Saving per-row data — a view is only a configuration, never a snapshot.
