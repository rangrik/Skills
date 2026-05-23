# Implementation Plan: App Export Download

## Feature
- Blueprint: blueprint.md
- System design: system-design.md
- Summary: Creators export a generated app as a downloadable .zip. An export
  job assembles the app's files on a worker, stores the artifact, and the
  Creator downloads it via a link. Per-app, per-workspace, idempotent, with an
  explicit failed state.

## Scenario order & status
| # | ID | Title                              | Status     |
|---|----|------------------------------------|------------|
| 1 | S1 | Creator requests an export         | committed  |
| 2 | S2 | Creator downloads a completed export | committed  |
| 3 | S3 | Double-click / retried export      | planned    |
| 4 | S4 | Export of an app not owned         | planned    |
| 5 | S5 | Assembly fails partway             | planned    |

## Scenario S1 — Creator requests an export
- Order: 1
- Type: happy_path
- Status: committed
- Design references: ExportService + thin export_routes.py; assembly on a
  Celery worker, off the request path; resumable state machine.

### Gherkin
Given a Creator viewing an app they own
When they click "Export"
Then an export job is created, the zip is assembled on a worker, stored, and a
download link is returned.

### Implementation record (written by kite-implementation)
- Changed files: backend/app/routes/export_routes.py, migrations/0042_app_exports.sql
- Architecture check (kite-arch-compass): pass
- Scenario check verdict: pass
- Commit: commit 1

## Scenario S2 — Creator downloads a completed export
- Order: 2
- Type: happy_path
- Status: committed
- Design references: GET /exports/{id}/download streams only when status==ready.

### Gherkin
Given an export that has finished assembling
When the Creator opens the download link
Then the zip is streamed and the export is marked downloaded.

### Implementation record
- Changed files: backend/app/routes/export_routes.py
- Architecture check (kite-arch-compass): pass
- Scenario check verdict: pass
- Commit: commit 1

## Scenario S3 — Double-click / retried export request
- Order: 3
- Type: corner_case
- Status: planned
- Design references: partial unique index on (app_id, app_version) for
  non-terminal exports; create-or-return-existing.

### Gherkin
Given a Creator who clicks Export twice in quick succession
When the second request arrives while the first is pending or complete
Then the existing export is returned, not a duplicate.

## Scenario S4 — Export of an app the Creator does not own
- Order: 4
- Type: corner_case
- Status: planned
- Design references: server-side workspace check from request-scoped identity.

### Gherkin
Given a Creator crafting an export request for another workspace's app
When the request is received
Then the platform refuses the export.

## Scenario S5 — Assembly fails partway
- Order: 5
- Type: edge_case
- Status: planned
- Design references: explicit failed terminal state with reason; no half-written
  zip offered as valid.

### Gherkin
Given an export whose assembly fails partway
When the failure occurs
Then the export moves to failed with a reason and no valid download is offered.
