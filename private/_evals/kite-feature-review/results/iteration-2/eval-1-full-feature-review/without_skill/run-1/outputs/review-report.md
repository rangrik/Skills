# Final Review: App Export Download

## Verdict

Not ready for merge. The implementation does not satisfy the required feature behavior. S1 and S2 are only superficially present and fail core requirements; S3, S4, and S5 are unimplemented. The plan also still marks S3-S5 as `planned`, not committed (`plan.md:16-18`, `plan.md:56-89`), which conflicts with the premise that all scenarios are complete.

## Reviewed inputs

- `blueprint.md`
- `system-design.md`
- `plan.md`
- `code-changes.diff`

## Blocking findings

### 1. Export creation is synchronous route work, not a durable export job

Severity: Critical

Scenarios affected: S1, S5

The design requires `POST /exports` to create a `pending` export row, enqueue Celery assembly, and run slow zip assembly on the worker (`system-design.md:18-26`). The route instead walks the app files, builds the zip in memory, and writes it to disk directly in the request handler (`code-changes.diff:21-32`). The database row is inserted only after the artifact write succeeds (`code-changes.diff:35-40`).

Impact:

- Large apps can block or time out the request path.
- A file read or storage write failure has no persisted export row, no `failed` state, and no `failure_reason`.
- There is no resumable state machine and no bounded worker retry behavior.
- The implementation does not create the export job described by S1 (`blueprint.md:13-17`).

### 2. Cross-workspace authorization is missing

Severity: Critical

Scenarios affected: S1, S2, S4

The blueprint requires exports to be tied to the requesting Creator's workspace (`blueprint.md:5-9`) and to refuse exports for apps in another workspace (`blueprint.md:32-36`). The design requires both endpoints to check request-scoped identity and never trust client-supplied workspace ids (`system-design.md:33-37`).

The POST route accepts `workspace_id` directly from the caller (`code-changes.diff:21`) and writes it to the database (`code-changes.diff:37-40`). The download route looks up exports only by `export_id` (`code-changes.diff:45-50`). The diff explicitly states that no ownership or workspace authorization check was added (`code-changes.diff:100-102`).

Impact:

- A Creator can request an export for an app outside their workspace if they know or guess the app id.
- A Creator can download another workspace's export if they know or guess the export id.
- This is a tenant isolation failure, not just a missing edge case.

### 3. Download does not stream the zip, check readiness, or mark downloaded

Severity: Critical

Scenarios affected: S2, S5

S2 requires the completed export zip to be streamed to the Creator and marked downloaded (`blueprint.md:19-22`). The design says download is allowed only when `status == ready`, then transitions the export to `downloaded`; failed or non-ready exports must never yield a zip (`system-design.md:28-31`).

The implemented route only reads `artifact_path` and returns `{"path": row[0]}` (`code-changes.diff:46-52`). The migration has no `status` column at all (`code-changes.diff:57-65`).

Impact:

- The API returns a server filesystem path instead of streaming the zip.
- Downloads are never marked as `downloaded`.
- Pending, failed, missing, or half-written artifacts cannot be distinguished from ready artifacts.
- Failed exports cannot be blocked from download because the system has no failed state.

### 4. Idempotency and duplicate suppression are absent

Severity: High

Scenarios affected: S3

S3 requires a double-click or retried POST to return the existing export for the same app version rather than creating duplicate work or artifacts (`blueprint.md:24-30`). The design requires `app_version`, an idempotency mechanism, and a partial unique index on `(app_id, app_version)` (`system-design.md:10-16`).

The route unconditionally inserts a new row on every request (`code-changes.diff:35-40`). The migration omits `app_version`, `idempotency_key`, and the unique index (`code-changes.diff:57-65`). The diff explicitly confirms there is no idempotency handling (`code-changes.diff:100`).

Impact:

- Retries and double-clicks create duplicate export rows.
- Concurrent requests can race.
- Because artifact paths are derived only from `app_id`, duplicate exports for the same app write to the same file path (`code-changes.diff:30`), creating overwrite and corruption risk.

### 5. Required export state model is missing

Severity: High

Scenarios affected: S1, S2, S3, S5

The data model requires `app_version`, `status`, `failure_reason`, `artifact_path`, and `idempotency_key` (`system-design.md:10-16`). The migration creates only `id`, `app_id`, `workspace_id`, `artifact_path`, and `created_at` (`code-changes.diff:57-63`), with a comment noting that `status`, `app_version`, `idempotency_key`, and the unique index are absent (`code-changes.diff:64-65`).

Impact:

- The system cannot represent `pending`, `assembling`, `ready`, `downloaded`, or `failed`.
- It cannot record a failure reason.
- It cannot enforce per-version idempotency.
- It cannot safely decide whether an artifact is downloadable.

### 6. Failure handling does not satisfy S5

Severity: High

Scenarios affected: S5

S5 requires assembly failures to transition the export to an explicit `failed` terminal state with a reason, and no half-written zip may be offered as valid (`blueprint.md:38-44`). The implementation has no exception handling around file walking, zip writing, or artifact persistence (`code-changes.diff:21-32`), no status field (`code-changes.diff:57-65`), and no status check on download (`code-changes.diff:46-52`). The diff explicitly says there is no failure handling, failed state, or Celery task (`code-changes.diff:103`).

Impact:

- Source file errors and storage write errors surface as request failures rather than durable export failures.
- Partial artifacts may remain on disk without any database state marking them invalid.
- The Creator cannot be shown a persisted export failure with a reason.

### 7. Business logic is placed in the route instead of `ExportService`

Severity: Medium

Scenarios affected: All

The system design requires a thin `export_routes.py` delegating to `ExportService`, with layering through services, database modules, and models (`system-design.md:5-8`). The route currently owns zip assembly, filesystem paths, database SQL, and download behavior directly (`code-changes.diff:21-52`).

Impact:

- The implementation bypasses the intended service boundary.
- The export state machine, authorization, idempotency, and failure handling have no cohesive place to live.
- Route-level SQL and filesystem behavior will be harder to test and evolve.

### 8. Out-of-scope analytics were added inline to export creation

Severity: Medium

Scenarios affected: S1 and overall release scope

Commit 2 adds a new analytics service that is explicitly not referenced by the blueprint or design (`code-changes.diff:67-76`). It sends export data to PostHog and writes an `active_creators_daily` rollup (`code-changes.diff:81-90`), then calls this inline from the export route (`code-changes.diff:92-95`).

Impact:

- This adds unreviewed product, privacy, reliability, and schema assumptions outside the feature scope.
- Network failures or analytics latency can now affect export creation.
- The export route gains another cross-cutting responsibility while already violating the service layering requirement.

## Scenario review

| Scenario | Result | Notes |
|---|---|---|
| S1 - Creator requests an export | Fail | No durable job, no worker, no pending state, no service layer, no authorization, and the response returns a filesystem artifact path rather than a download link. |
| S2 - Creator downloads completed export | Fail | The endpoint returns a path, does not stream the zip, does not check `ready`, and does not mark `downloaded`. |
| S3 - Double-click / retried export | Fail | No app version, idempotency key, unique index, or create-or-return-existing logic. |
| S4 - Export of unowned app | Fail | No server-side workspace ownership check; `workspace_id` is caller supplied. |
| S5 - Assembly fails partway | Fail | No failed state, no failure reason, no bounded retries, no worker task, and no guard against serving invalid artifacts. |

## Required before acceptance

- Implement the designed `ExportService` and keep routes thin.
- Add the full `app_exports` schema, including `app_version`, `status`, `failure_reason`, `idempotency_key`, and the required uniqueness constraint.
- Move zip assembly to a Celery task with explicit state transitions and bounded retry behavior.
- Enforce request-scoped workspace ownership checks on create and download.
- Implement create-or-return-existing idempotency for the same app version.
- Stream downloads only for `ready` exports and mark them `downloaded`.
- Persist `failed` terminal state and `failure_reason` for assembly failures.
- Remove or separately scope the analytics change.
- Add scenario coverage for S1-S5, including retry, cross-workspace denial, failed assembly, and non-ready download denial.
