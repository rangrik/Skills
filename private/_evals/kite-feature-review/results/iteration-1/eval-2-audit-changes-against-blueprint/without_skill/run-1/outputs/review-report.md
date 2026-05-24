# App Export Download Review Report

## Verdict

Do not merge. The implementation does not satisfy the blueprint or the agreed system design. It only adds a route-local synchronous zip routine and a minimal table, while omitting the required service layer, async worker flow, export status state machine, idempotency, authorization, failed terminal state, and real download semantics.

## Merge-Blocking Findings

### 1. S4 is completely broken: any caller can export another workspace's app

- Evidence: `create_export(app_id: str, workspace_id: str)` accepts `workspace_id` from the client and inserts it directly into `app_exports` (`code-changes.diff:20-40`).
- Evidence: `download_export(export_id: str)` looks up only by export id and does not compare the export workspace to request-scoped identity (`code-changes.diff:44-52`).
- Blueprint conflict: S4 requires refusing exports for apps outside the Creator's workspace (`blueprint.md:32-36`).
- Design conflict: both endpoints must enforce server-side workspace ownership from request-scoped identity, never client-supplied workspace ids (`system-design.md:33-37`).
- Impact: a Creator can craft a request for another workspace's app, assign any workspace id, create an export, and retrieve the artifact by id.

### 2. S2 is not implemented: the download endpoint does not stream a zip or mark the export downloaded

- Evidence: the route returns `{"path": row[0]}` instead of streaming the artifact bytes (`code-changes.diff:51-52`).
- Evidence: the migration has no `status` column, so there is no way to check `ready` or mark `downloaded` (`code-changes.diff:57-65`).
- Blueprint conflict: S2 requires the zip to be streamed and the export marked as downloaded (`blueprint.md:19-22`).
- Design conflict: downloads must stream only when `status == ready`, then transition to `downloaded`; failed or non-ready exports must never yield a zip (`system-design.md:28-31`).
- Impact: callers receive an internal filesystem path rather than a downloadable zip, and the system never records successful download completion.

### 3. S1 violates the core flow: assembly runs synchronously in the request route, not on a worker

- Evidence: `create_export` builds the zip inline using `os.walk`, `zipfile.ZipFile`, and `open(..., "wb")` before inserting the export row (`code-changes.diff:21-40`).
- Evidence: the patch adds no `ExportService`, no Celery task, and no worker-driven state transition (`code-changes.diff:98-103`).
- Blueprint conflict: S1 requires an export job to be created and the zip assembled from current files, stored, and exposed via a download link (`blueprint.md:13-17`).
- Design conflict: `POST /exports` should create a `pending` row, enqueue Celery, and return the export id while slow zip assembly runs on the worker, never in the request path (`system-design.md:18-21`).
- Plan conflict: the committed S1 record specifically references `ExportService`, a thin route, worker assembly, and a resumable state machine (`plan.md:20-31`).
- Impact: large apps can block or time out the API request, failures are not recoverable, and no durable job exists while assembly is in progress.

### 4. S3 is missing: duplicate export requests create duplicate rows and overwrite artifacts

- Evidence: the table lacks `app_version`, `idempotency_key`, and any unique index (`code-changes.diff:57-65`).
- Evidence: `create_export` always writes a new row and always writes the artifact to `/data/exports/{app_id}.zip` (`code-changes.diff:30-40`).
- Evidence: the patch explicitly states there is no idempotency handling (`code-changes.diff:98-100`).
- Blueprint conflict: a second request for the same app version while the first export is pending or complete must return the existing export rather than creating a duplicate job and artifact (`blueprint.md:24-30`).
- Design conflict: the model requires `app_version` and a partial unique index on `(app_id, app_version)` for non-terminal exports (`system-design.md:10-16`).
- Impact: double-clicks or client retries create multiple database rows and can race on the same artifact path, corrupting or replacing the file behind earlier export records.

### 5. S5 is missing: failures do not enter a failed terminal state and can leave inconsistent artifacts

- Evidence: the migration has no `status` or `failure_reason` columns (`code-changes.diff:57-65`).
- Evidence: zip assembly and artifact write happen before the database row is created (`code-changes.diff:22-40`).
- Evidence: the patch explicitly states there is no failure handling, failed state, or Celery task (`code-changes.diff:100-103`).
- Blueprint conflict: assembly failures must move the export to `failed` with a reason, show the Creator the failure, and never offer a half-written zip as valid (`blueprint.md:38-44`).
- Design conflict: worker transitions must commit `pending -> assembling -> ready` or `failed`, with bounded retries ending in `failed` (`system-design.md:22-26`).
- Impact: missing source files, zip errors, storage write errors, or DB insert failures surface as request exceptions or leave orphaned artifacts, with no user-visible failed export record and no reliable cleanup boundary.

### 6. The data model is materially incomplete for every committed and planned scenario

- Evidence: `app_exports` only contains `id`, `app_id`, `workspace_id`, `artifact_path`, and `created_at` (`code-changes.diff:57-63`).
- Missing required fields: `app_version`, `status`, `failure_reason`, and `idempotency_key` (`system-design.md:10-13`).
- Missing required index: partial unique index on `(app_id, app_version)` for non-terminal exports (`system-design.md:14-16`).
- Impact: the implementation cannot represent pending, assembling, ready, downloaded, or failed exports; cannot distinguish app versions; cannot implement retry-safe create-or-return-existing behavior; and cannot safely gate downloads.

### 7. The route owns business logic and storage concerns instead of delegating to `ExportService`

- Evidence: `export_routes.py` imports `io`, `zipfile`, `os`, raw SQL, and `engine`, then performs filesystem traversal, archive creation, artifact writes, and database inserts directly (`code-changes.diff:12-40`).
- Design conflict: routes must parse and delegate only; export logic belongs in `ExportService`, with routes calling services, services calling database modules, and models below that (`system-design.md:5-8`).
- Impact: the implementation bypasses the agreed layering, making the core export behavior harder to test, retry, authorize consistently, and move onto a worker.

### 8. The returned POST payload exposes an internal artifact path instead of a download link

- Evidence: `create_export` returns `{"export_id": row[0], "artifact_path": artifact_path}` (`code-changes.diff:41`).
- Blueprint conflict: S1 says the Creator receives a download link (`blueprint.md:13-17`).
- Impact: clients are coupled to server filesystem layout and still cannot perform the specified download workflow through `GET /exports/{id}/download`.

### 9. The added analytics side effect is out of scope and can break exports

- Evidence: `usage_analytics.py` posts to PostHog and writes to `active_creators_daily` on every export (`code-changes.diff:71-90`).
- Evidence: `create_export` calls `track_export` inline from the route (`code-changes.diff:92-95`).
- Blueprint/design conflict: analytics and active-creator rollups are not part of any scenario or the agreed system design (`blueprint.md:46-48`, `system-design.md:39-40`).
- Impact: a slow or failing analytics request can delay or fail export creation, and the feature introduces unrelated cross-cutting database writes that were not reviewed as part of this behavior.

## Scenario Coverage

| Scenario | Plan status | Review result |
|---|---:|---|
| S1 - Creator requests an export | committed | Fails. It does not create a pending job, does not use a worker, does not use `ExportService`, and does not return a proper download link. |
| S2 - Creator downloads a completed export | committed | Fails. It returns a path, does not stream bytes, does not check `ready`, and cannot mark `downloaded`. |
| S3 - Double-click / retried export request | planned | Not implemented. There is no app version, idempotency key, create-or-return-existing logic, or partial unique index. |
| S4 - Export of an app the Creator does not own | planned | Not implemented. The implementation trusts client-supplied workspace id and does not authorize either endpoint. |
| S5 - Assembly fails partway | planned | Not implemented. There is no failed state, failure reason, bounded retry flow, or prevention of invalid artifact exposure. |

## Additional Review Notes

- `download_export` does not handle a missing export row; `row[0]` will raise instead of returning a controlled 404 or authorization-safe response (`code-changes.diff:46-52`).
- Artifact paths are derived directly from `app_id` (`code-changes.diff:25`, `code-changes.diff:30`), which increases risk around path construction and artifact collisions.
- The committed plan records say S1 and S2 passed checks (`plan.md:33-54`), but the actual diff contradicts the stated architecture and scenario behavior.

## Required Before Merge

The feature needs a substantial rework before it can be considered for merge: implement the agreed `ExportService`, complete the `app_exports` model and indexes, move assembly to a bounded-retry Celery task, enforce workspace ownership from request identity on both endpoints, implement idempotent create-or-return-existing behavior, gate downloads on `ready`, transition to `downloaded`, and represent failures as terminal `failed` exports with reasons. The unrelated analytics change should be removed from this feature review unless it is separately specified and reviewed.
