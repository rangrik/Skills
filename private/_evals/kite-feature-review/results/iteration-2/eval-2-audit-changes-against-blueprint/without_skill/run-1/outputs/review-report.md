# Review Report: App Export Download

## Verdict

Do not merge. The implementation does not satisfy the committed S1/S2 scenarios and leaves every corner/edge case from the blueprint unimplemented. The biggest problems are security-critical authorization gaps, synchronous archive assembly in the route, missing export state, missing idempotency, and a download endpoint that does not actually stream or mark downloads.

## Scenario Coverage

| Scenario | Blueprint expectation | Review result |
|---|---|---|
| S1 - Creator requests an export | Create an export job, assemble current files, store the zip, return a download link (`blueprint.md:13-17`) | Fails. The route assembles the zip synchronously before inserting a DB row, has no job/worker, returns a server filesystem path instead of a download link, and bypasses the required service layer (`code-changes.diff:20-41`). |
| S2 - Creator downloads a completed export | Stream the completed zip and mark the export downloaded (`blueprint.md:19-22`) | Fails. The endpoint only returns `{"path": row[0]}`, does not stream bytes, does not check readiness, and cannot mark `downloaded` because the schema has no status column (`code-changes.diff:43-52`, `57-65`). |
| S3 - Double-click / retry | Return the existing export for the same app version instead of creating duplicates (`blueprint.md:24-30`) | Fails. There is no `app_version`, idempotency key, status, or unique index; every POST inserts a new row and writes the same deterministic artifact path (`code-changes.diff:30`, `37-40`, `57-65`, `100`). |
| S4 - Export app not owned | Refuse exports for apps outside the Creator's workspace (`blueprint.md:32-36`) | Fails. `workspace_id` is accepted from the client and neither POST nor GET checks request-scoped identity or ownership (`code-changes.diff:21`, `37-39`, `45-52`, `101-102`). |
| S5 - Assembly fails partway | Move to `failed` with a reason and never offer a half-written zip (`blueprint.md:38-44`) | Fails. There is no failed state, failure reason, worker retry policy, or cleanup/guard around partial artifacts (`code-changes.diff:21-32`, `57-65`, `103`). |

## Blocking Findings

### 1. Authorization is missing and client input is trusted for workspace ownership

Severity: Critical

The design requires both endpoints to enforce that the export workspace matches the requesting Creator's workspace, using request-scoped identity and never a client-supplied workspace id (`system-design.md:33-37`). The implementation accepts `workspace_id` as a route parameter and writes it straight into `app_exports` (`code-changes.diff:21`, `37-39`). The download endpoint selects by `export_id` only and returns the stored path without checking the caller's workspace (`code-changes.diff:45-52`).

Impact:

- A Creator can request an export for an app id they do not own, violating S4.
- A Creator who obtains or guesses an export id can access another workspace's export path.
- Because ownership is not checked before filesystem traversal, the server may assemble files for any app id reachable under the configured path.

This is not a planned-later concern. The blueprint says exports are tied to the requesting Creator's workspace (`blueprint.md:8-9`), and S4 explicitly requires refusal for another workspace's app (`blueprint.md:32-36`).

### 2. Export assembly runs synchronously in the route instead of as a worker-backed job

Severity: High

S1 and the design both require an export job: `POST /exports` creates a pending row, enqueues Celery work, and returns an export id while slow archive assembly runs on the worker (`blueprint.md:16-17`, `system-design.md:18-21`, `plan.md:24-31`). The implementation builds the whole zip inside `create_export` before inserting the row (`code-changes.diff:21-40`). The diff even notes the traversal can touch thousands of files (`code-changes.diff:26`).

Impact:

- Large exports can tie up web workers and time out before an export row exists.
- There is no resumable state if the process crashes during traversal or file writing.
- Callers do not get a job lifecycle; they get a completed-or-failed request path side effect.
- The route owns business logic and database writes directly, violating the agreed route/service layering (`system-design.md:5-8`).

The plan marks S1 committed with "assembly on a Celery worker, off the request path" (`plan.md:24-31`), but the diff implements the opposite.

### 3. The download endpoint does not perform a download and cannot mark the export downloaded

Severity: High

S2 requires the completed export to be streamed and then marked as downloaded (`blueprint.md:19-22`). The design tightens this: only `status == ready` may be streamed, then the row transitions to `downloaded`; failed or non-ready exports must not yield a zip (`system-design.md:28-31`). The implementation selects only `artifact_path` and returns it as JSON (`code-changes.diff:47-52`).

Impact:

- The user receives an internal server path, not a zip stream.
- The implementation leaks filesystem layout (`/data/exports/{app_id}.zip`) to clients.
- There is no readiness gate, so a non-ready, failed, stale, or partial artifact path would still be returned if present.
- The schema has no `status` column, so the implementation cannot mark `downloaded` (`code-changes.diff:57-65`).

This means the committed S2 scenario is not actually implemented despite the plan's pass record (`plan.md:39-54`).

### 4. Idempotency and app-version semantics are absent

Severity: High

S3 requires duplicate clicks or retry POSTs for the same app version to return the existing export instead of creating a duplicate job or stored artifact (`blueprint.md:24-30`). The design calls for `app_version`, `idempotency_key`, status, and a partial unique index on `(app_id, app_version)` for live exports (`system-design.md:10-16`). The migration omits all of those fields and indexes (`code-changes.diff:57-65`), and the route unconditionally inserts a row on every POST (`code-changes.diff:35-40`).

Impact:

- Double-clicks and client retries create duplicate database rows.
- Concurrent requests write to the same deterministic artifact path, `/data/exports/{app_id}.zip`, so one export can overwrite another (`code-changes.diff:30-32`).
- There is no way to distinguish exports for different app versions.
- There is no database-level protection against races.

The plan shows S3 as planned (`plan.md:56-67`), but this is required by the blueprint before merge, not optional scope.

### 5. Failure handling and terminal export states are missing

Severity: High

S5 requires a failed terminal state with a reason and no valid download for half-written zips (`blueprint.md:38-44`). The design requires `pending -> assembling -> ready` or `failed`, committed transitions, bounded retries, and `failure_reason` (`system-design.md:18-26`). The migration has no `status` or `failure_reason` (`code-changes.diff:57-65`), and the route has no exception handling around walking files, creating the zip, or writing the artifact (`code-changes.diff:21-32`).

Impact:

- Missing source files, storage errors, and write failures become request exceptions, not explicit export records.
- A partially written artifact can remain at the deterministic artifact path.
- The download endpoint has no status gate to prevent returning a path for a bad artifact (`code-changes.diff:51-52`).
- There is no bounded retry behavior or durable record of the failure.

This leaves the edge case completely unimplemented.

### 6. The returned POST response is not the promised download link

Severity: Medium

The blueprint says the Creator receives a link to download the export (`blueprint.md:16-17`). The route returns `{"export_id": row[0], "artifact_path": artifact_path}` (`code-changes.diff:41`). A local artifact path is not a usable public/API download link and exposes server internals.

Impact:

- Clients cannot reliably use the response as the specified download link.
- The response bypasses the intended `GET /exports/{id}/download` API shape.
- Internal storage layout becomes part of the external contract.

### 7. Out-of-scope analytics add new request-path side effects

Severity: Medium

Commit 2 adds a cross-cutting analytics module that is not referenced by the blueprint or system design (`code-changes.diff:67-76`). It performs a network call to PostHog and writes to `active_creators_daily`, called inline from the export route (`code-changes.diff:81-95`).

Impact:

- Export creation now depends on an external HTTP call in the request path.
- Analytics failures or latency can break or slow exports unless separately guarded, which the diff does not show.
- The extra database write expands the feature's blast radius beyond the agreed design.

This should not be merged as part of the export feature unless it is separately specified, reviewed, and made non-blocking.

## Plan Accuracy

The plan's implementation records for S1 and S2 say the architecture and scenario checks passed (`plan.md:33-37`, `50-54`), but the diff contradicts the recorded design references:

- S1 says assembly is on a Celery worker and off the request path (`plan.md:24-31`); the route assembles synchronously (`code-changes.diff:21-32`).
- S2 says downloads stream only when `status == ready` (`plan.md:43-48`); the endpoint has no status and returns a path (`code-changes.diff:47-52`, `57-65`).
- S3-S5 remain planned (`plan.md:56-89`), but the blueprint requires them for a correct feature.

Treat the plan status as stale or invalid for this review.

## Required Before Merge

- Add real server-side authorization for export creation and download using request-scoped Creator/workspace identity.
- Move export orchestration into `ExportService`; keep routes thin.
- Add the full `app_exports` state model: `app_version`, `status`, `failure_reason`, `artifact_path`, `idempotency_key`, timestamps, and the required uniqueness/idempotency constraint.
- Make POST create/return an export job and enqueue bounded worker assembly instead of building the zip inline.
- Implement ready-only zip streaming on GET and transition `ready -> downloaded`.
- Implement failure transitions to `failed` with a reason and ensure partial artifacts are never offered as valid downloads.
- Remove or separately scope the analytics change, and make any analytics side effect non-blocking.
