# Final Feature Review: App Export Download

## Verdict

Not ready to ship.

The submitted implementation does not satisfy the App Export Download blueprint or the system design. It implements a synchronous route-level zip writer and a JSON path-returning download endpoint, but the required service layer, worker-based assembly, export state machine, authorization checks, idempotency, failure handling, and download semantics are missing. Several planned scenarios are still marked only as `planned` in the plan file, and the code changes confirm that they were not implemented.

## Reviewed Inputs

- Blueprint: `files/blueprint.md`
- System design: `files/system-design.md`
- Plan: `files/plan.md`
- Code changes: `files/code-changes.diff`

## Blocking Findings

### 1. Export requests perform slow zip assembly synchronously in the route

Affected scenarios: S1, S5

The system design requires `POST /exports` to create a pending export row, enqueue a Celery assembly task, and return without doing slow or fallible zip work in the request path. The implementation builds the full zip inside `create_export` by walking `/data/apps/{app_id}/files`, writing the archive to memory, and then writing it to `/data/exports/{app_id}.zip`.

This violates the required route -> service -> worker flow and makes large exports request-bound. It also means worker retries, resumable transitions, and bounded failure handling cannot happen.

### 2. The required export state machine and data model are absent

Affected scenarios: S1, S2, S3, S5

The design requires `app_exports` to include `app_version`, `status`, `failure_reason`, `artifact_path`, `idempotency_key`, timestamps, and a partial unique index for live exports. The migration only creates `id`, `app_id`, `workspace_id`, `artifact_path`, and `created_at`.

Because there is no `status`, the implementation cannot represent `pending`, `assembling`, `ready`, `downloaded`, or `failed`. It cannot enforce ready-only downloads, mark an export as downloaded, surface failed exports to the Creator, or distinguish live exports from terminal exports.

### 3. Download does not stream the zip, does not check readiness, and does not mark downloaded

Affected scenario: S2

The blueprint says opening the download link streams the zip and marks the export as downloaded. The implementation selects `artifact_path` and returns `{"path": row[0]}`.

This is not a download stream. It exposes an internal filesystem path to the client, performs no `status == ready` check, and never updates the export to `downloaded`. A failed, half-written, stale, or otherwise invalid artifact path would still be returned if present.

### 4. Duplicate export requests are not idempotent

Affected scenario: S3

The blueprint requires the second request for the same app version to return the existing export while a matching export is pending or complete. The design calls for create-or-return-existing behavior backed by a partial unique index on `(app_id, app_version)`.

The implementation has no `app_version`, no idempotency key, no uniqueness constraint, and no lookup for an existing export. Each `POST /exports` inserts a new row after rebuilding the artifact. Because the artifact path is only `/data/exports/{app_id}.zip`, repeated requests can also overwrite the same stored artifact while creating multiple database records that point at the same path.

### 5. Ownership and workspace authorization are missing

Affected scenario: S4

The blueprint requires the platform to refuse exports for apps outside the Creator's workspace. The design explicitly says ownership must be checked from request-scoped identity and never from a client-supplied workspace id.

The implementation accepts both `app_id` and `workspace_id` as request parameters and inserts the supplied `workspace_id` directly. Neither `POST /exports` nor `GET /exports/{id}/download` verifies that the requesting Creator owns the app or that the export belongs to their workspace. A crafted request can create or retrieve exports across workspaces.

### 6. Assembly failure does not produce a failed terminal export

Affected scenario: S5

The blueprint requires assembly failures to move the export to an explicit `failed` terminal state with a reason and to prevent any half-written zip from being offered as valid. The implementation has no `failed` state, no `failure_reason`, no exception handling around file traversal, zip creation, or artifact writing, and no cleanup path.

Some failure modes leave no export record at all. Others may leave a partial or stale artifact on disk. A missing source directory can also silently produce an empty zip because `os.walk` over a nonexistent path yields no files, so the Creator may receive a "successful" empty artifact instead of a failed export.

### 7. The implementation bypasses the required service layering

Affected scenarios: S1 through S5

The design requires a thin `export_routes.py` delegating to `ExportService`, with persistence handled through database modules and domain behavior outside the route. The route currently imports `engine`, executes raw SQL directly, performs filesystem traversal, creates zip files, writes artifacts, and imports analytics inline.

This concentrates business logic, persistence, I/O, and integration side effects in the HTTP route, making the required state machine and scenario behavior difficult to test or evolve.

### 8. Out-of-scope analytics were added and can break exports

Affected scenarios: S1, S3, S5

`backend/app/services/usage_analytics.py` is not referenced by the blueprint or system design. It performs a synchronous PostHog request and writes to `active_creators_daily`, then the export route calls it inline.

This adds an unrelated external dependency to export creation. A network error, timeout, missing analytics table, or analytics database error can cause an export request to fail for reasons outside the feature's contract. It also adds product behavior and data writes that were not part of the reviewed design.

## Scenario Review

### S1: Creator requests an export

Fail.

An export row is inserted only after synchronous zip assembly completes. No pending job is created, no worker is enqueued, no service layer is used, no app version is captured, and the route returns an internal artifact path rather than a proper download link. The implementation does not match the required async export workflow.

### S2: Creator downloads a completed export

Fail.

The endpoint returns a JSON object containing the artifact path instead of streaming the zip. It does not require `status == ready` and cannot mark the export as downloaded because the schema has no status field.

### S3: Double-click / retried export request

Fail.

There is no idempotency behavior. Duplicate requests create duplicate database records and may overwrite the same artifact path. The required partial unique index and create-or-return-existing logic are absent.

### S4: Export of an app the Creator does not own

Fail.

The request trusts client-supplied `workspace_id` and performs no server-side ownership check. The download endpoint also lacks workspace enforcement.

### S5: Assembly fails partway

Fail.

The implementation has no failed terminal state, no failure reason, no retry exhaustion behavior, no cleanup for invalid artifacts, and no ready-only download guard. Failures either bubble out of the request, disappear without a persisted export state, or can leave invalid artifacts accessible by path.

## Plan Status Mismatch

The plan claims only S1 and S2 were committed; S3, S4, and S5 remain `planned`. The task prompt says all scenarios are committed and ready for final review, but the plan and code changes show otherwise. The final review should treat the feature as incomplete.

## Residual Risks

- `app_id` is interpolated into filesystem paths without visible validation, creating path traversal and artifact overwrite risk if route parameter validation elsewhere does not constrain it.
- `download_export` does not handle a missing export row before indexing `row[0]`, so unknown ids can cause a server error instead of a controlled response.
- The artifact path is deterministic per `app_id`, so exports for different app versions cannot be preserved independently.
- The implementation does not show route registration, response headers, content type, filename handling, storage abstraction, worker configuration, tests, or migrations for the analytics rollup table.

## Review Conclusion

This implementation should be rejected for the current feature. It does not merely miss edge-case polish; it omits the core architecture and behavior required by the blueprint and system design. The feature needs a complete implementation of the export service, persisted state model, worker assembly flow, idempotency enforcement, authorization checks, failure transitions, and real download streaming before another final review.
