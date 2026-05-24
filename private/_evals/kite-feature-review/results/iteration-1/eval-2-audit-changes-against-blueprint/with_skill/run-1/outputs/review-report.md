# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have associated code changes (`S1`, `S2`); 0 of 5 satisfy the blueprint and agreed system design.
- S1 - Creator requests an export: implemented in the route, but the implementation is not the designed export job flow and is blocking, non-resumable, unauthorised, and path-leaking.
- S2 - Creator downloads a completed export: implemented as a path lookup, not a streamed, status-gated download, and it never marks the export downloaded.
- S3 - Double-click / retried export request: unimplemented; there is no idempotency key, app version, create-or-return lookup, status model, or partial unique index.
- S4 - Export of an app the Creator does not own: unimplemented; both endpoints trust client input or export id possession instead of request-scoped workspace ownership.
- S5 - Assembly fails partway: unimplemented; there is no failed terminal state, failure reason, bounded worker retry, or protection against stale or half-written artifacts.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` - This PostHog capture plus `active_creators_daily` rollup is not in the blueprint, system design, or any scenario. It adds cross-cutting analytics and a new database side effect to an export feature whose agreed scope is zip assembly, storage, download, idempotency, authorization, and failure state.
- Inline `track_export(app_id, workspace_id)` inside `create_export` - This makes a third-party network call and analytics write part of the export request path. It violates [P9] YAGNI because no scenario asks for analytics, [P11] adapter isolation because PostHog is called directly, and [P19]/[P20] because an unrelated provider timeout or failure can slow or fail export creation without any deliberate fail-open/fail-closed decision.

## Scenario reviews

### Scenario S1 - Creator requests an export (happy path)
- Why the implementation is unacceptable: The POST route builds the zip synchronously inside `export_routes.py`, walks the filesystem in the HTTP request, writes `/data/exports/{app_id}.zip`, and only then inserts a row. The agreed design required a thin route calling `ExportService`, creation of a `pending` export row, Celery assembly off the request path, committed state transitions, and a returned download link. The migration omits `app_version`, `status`, `failure_reason`, and `idempotency_key`, so there is no job state to return, resume, or correlate to a specific app version. The response returns an internal `artifact_path` instead of a creator-safe download link. The route also accepts `workspace_id` from the client rather than deriving ownership from request identity.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering and [P2] Thin edges, thick core are violated because the route owns business logic, filesystem assembly, and raw SQL. [P7] Explicit, typed contracts is violated because the endpoint uses loose query parameters and untyped response shapes rather than request/response schemas. [P16] Resumable state machines and [P19] Async work with backpressure are violated because long, fallible assembly is a blocking request call with no durable transitions. [P17] Explicit transaction boundaries is violated because route-level `engine.begin()` owns persistence directly rather than a service/database-module boundary. [P28] Guarded trust boundaries and [P30] Secure by default are violated by trusting client-supplied workspace data and returning a server filesystem path.
- Impact: Large exports can time out before any durable export job exists; a crash or cancellation leaves no recoverable `pending` or `assembling` state; the created artifact can represent an inconsistent file snapshot; and the client receives an internal path rather than a safe download link.
- Failure scenario:

```gherkin
Scenario: Large export times out before a durable job exists
  Given a Creator owns an app with thousands of generated files
  When they click "Export"
  And the HTTP request times out during in-route zip assembly
  Then an export job should exist in "pending" or "assembling" state
  And a worker should be able to resume or fail the assembly
  But the implementation has no durable job row yet
  And the Creator receives no valid download link
```

### Scenario S2 - Creator downloads a completed export
- Why the implementation is unacceptable: The download route selects only `artifact_path` and returns `{"path": row[0]}`. It does not stream the zip, check `status == ready`, transition `ready -> downloaded`, or authorize the export against the requesting Creator's workspace. Because the table has no `status` column, the required downloaded marking cannot be implemented by this schema at all. The endpoint also has no not-found handling; a missing row will produce an internal error instead of a controlled response.
- Principle violations (kite-arch-compass): [P1] and [P2] are violated because the route performs direct raw SQL instead of delegating to `ExportService`. [P7] is violated because the response is an ad hoc JSON path, not the typed streaming contract expected by the feature. [P14] Durable state for correctness and [P16] Resumable state machines are violated because the downloaded state is not persisted and cannot be transitioned. [P20] Deliberate fail-open vs fail-closed, [P26] Defense in depth, [P28] Guarded trust boundaries, and [P30] Secure by default are violated because non-ready, failed, unauthorized, or guessed export ids are not blocked before exposing artifact paths.
- Impact: A Creator opening the link does not receive a streamed zip; completed exports remain indistinguishable from never-downloaded exports; unauthorized callers can learn artifact paths; and failed or not-ready artifacts are not rejected.
- Failure scenario:

```gherkin
Scenario: Completed export download does not stream or mark downloaded
  Given an export exists with id "exp-1", status "ready", and an artifact zip
  When the owning Creator opens "/exports/exp-1/download"
  Then the response should stream the zip file
  And the export status should become "downloaded"
  But the implementation returns a JSON server path
  And no downloaded status is persisted
```

### Scenario S3 - Double-click / retried export request (corner case)
- Why the implementation is unacceptable: This scenario has no implementation changes. The plan still marks it `planned`, and the diff explicitly says there is no idempotency handling. The schema has no `app_version`, `status`, `idempotency_key`, or partial unique index on `(app_id, app_version)`. The POST route always assembles and inserts a new export row; it never checks for an existing pending, ready, or otherwise live export for the same app version. The deterministic artifact path `/data/exports/{app_id}.zip` makes concurrent duplicate work especially dangerous because duplicate exports race on the same file.
- Principle violations (kite-arch-compass): [P15] Idempotency by design is violated because retries and redeliveries can create duplicate rows and duplicate side effects. [P16] is violated because there is no state machine that can define "pending", "ready", or terminal export states. [P19] is violated because repeated requests each do expensive synchronous assembly rather than enqueueing one worker job behind a durable state. [P18] Persisted contracts stay backward-compatible is violated at the design level of this migration because it omits the contract fields and index needed to enforce the scenario.
- Impact: A client retry after timeout or a double-click can run two full zip assemblies, insert two `app_exports` rows, overwrite the same artifact path, and return different export ids for the same requested app version.
- Failure scenario:

```gherkin
Scenario: Retry creates a duplicate export instead of returning the pending one
  Given a Creator starts an export for app "app-1" version "v1"
  And the first request is still assembling the zip
  When the client retries POST /exports for app "app-1" version "v1"
  Then the API should return the existing pending export id
  But the implementation starts another zip assembly
  And it inserts another app_exports row
  And both requests race to write "/data/exports/app-1.zip"
```

### Scenario S4 - Export of an app the Creator does not own (corner case)
- Why the implementation is unacceptable: This scenario has no implementation changes. The plan still marks it `planned`, and the diff states there is no ownership or workspace authorization check on either endpoint. `create_export(app_id, workspace_id)` trusts `workspace_id` from the client, zips files by `app_id`, and inserts whatever workspace id was supplied. `download_export(export_id)` accepts an export id and returns its artifact path without checking the requester's workspace.
- Principle violations (kite-arch-compass): [P5] Single source of truth is violated because ownership is not resolved through the central access/ownership mechanism. [P26] Defense in depth and [P27] Least privilege are violated because no server-side ownership layer limits export capability to the requesting Creator's workspace. [P28] Guarded trust boundaries and [P29] Never trust user input are violated because user-supplied `workspace_id` and `app_id` cross directly into filesystem and persistence behavior.
- Impact: Any Creator who knows or guesses another workspace's `app_id` or an export id can trigger an export or retrieve the artifact path, causing cross-workspace data disclosure. The deterministic artifact path also allows one workspace's export attempt to overwrite another artifact if identifiers collide or are reused.
- Failure scenario:

```gherkin
Scenario: Creator exports an app from another workspace
  Given Creator A belongs to workspace "workspace-a"
  And app "app-b" belongs to workspace "workspace-b"
  When Creator A calls POST /exports with app_id "app-b" and workspace_id "workspace-a"
  Then the platform should refuse the export
  But the implementation zips "/data/apps/app-b/files"
  And it returns an export id and artifact path
```

### Scenario S5 - Assembly fails partway (edge case)
- Why the implementation is unacceptable: This scenario has no implementation changes. The table has no `status` or `failure_reason`, there is no Celery task, no bounded retry policy, and no failure transition. Assembly exceptions in the route become unmodeled request failures. Storage failures can leave no export row, an orphaned artifact, or a stale deterministic artifact path. The download route has no status check, so it cannot refuse half-written, stale, failed, or non-ready artifacts.
- Principle violations (kite-arch-compass): [P16] Resumable state machines is violated because there are no committed transitions such as `pending -> assembling -> ready` or `-> failed`. [P21] Bound every retry; define terminal states is violated because there are no worker retries and no explicit `failed` terminal state. [P19] is violated because fallible file assembly and storage writes are synchronous. [P14] Durable state for correctness is violated because the failure reason and state are not persisted. [P20] Deliberate fail-open vs fail-closed is violated because failed and non-ready downloads are not explicitly blocked.
- Impact: A source-file miss, zip error, cancellation, disk error, or database failure cannot be represented to the Creator as a failed export. The system can leave stale or partial files under the same artifact path and still return that path later as if it were valid.
- Failure scenario:

```gherkin
Scenario: Failed assembly leaves no failed export state and can expose a bad artifact
  Given an existing export for app "app-1" points at "/data/exports/app-1.zip"
  And a Creator starts a new export for "app-1"
  When storage fails while writing "/data/exports/app-1.zip"
  Then the export should be marked "failed" with a failure_reason
  And no half-written zip should be offered as a valid download
  But the implementation records no failed state
  And GET /exports/{existing_export_id}/download can still return that artifact path without checking status
```

## Missed corner cases
- Path traversal through `app_id` - `app_id` is interpolated into `/data/apps/{app_id}/files` and `/data/exports/{app_id}.zip` without validation. An id containing `../` or path separators can escape the intended app/export directories or write an artifact outside the expected location.
- File mutation during assembly - The code walks live files without an `app_version` snapshot. If generated files change while `os.walk` is zipping, the export can mix old and new file contents while still being presented as the current app export.
- Artifact overwrite across versions - The artifact path is keyed only by `app_id`, not export id, workspace id, or app version. A later export overwrites the earlier artifact, so old download links can point at new or partially written content.
- Large export memory pressure - The entire zip is buffered in `io.BytesIO()` in the web request. A large app can exhaust worker memory or stall the API process instead of being handled by a background worker with backpressure.
- Missing row and missing file handling - `download_export` assumes the row exists and that the artifact path is usable. A guessed id, deleted file, moved artifact, or failed storage write becomes a 500 or a leaked path instead of a controlled 404/failed response.
- Analytics provider failure - The orphan PostHog call runs inline and can time out or fail during export creation, making an unrelated analytics dependency part of export availability.
- No deterministic verification surface - The diff contains no route/service/worker tests for duplicate retry, authorization failure, failed assembly, non-ready download refusal, or downloaded-state transition, violating [P36] Tests and evals are part of the architecture.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, and S5.
- Corner cases to promote into the blueprint: path traversal in `app_id`, file mutation during export assembly, artifact path overwrite across versions/workspaces, large-export memory pressure, missing-row/missing-file download handling, inline analytics failure, and deterministic tests for retry/auth/failure/download state behavior.
