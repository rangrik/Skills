# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have committed code paths; 0 of 5 satisfy the blueprint and system-design obligations.
- S1 — Creator requests an export: implemented in the wrong layer, synchronously assembles the zip in the route, skips the service/worker/state-machine design, and persists too little state to recover or report progress.
- S2 — Creator downloads a completed export: does not stream the artifact, does not check `ready`, does not mark `downloaded`, and exposes a filesystem path instead of a valid download response.
- S3 — Double-click / retried export request: unimplemented; there is no app version, idempotency key, create-or-return-existing behavior, or partial unique index.
- S4 — Export of an app the Creator does not own: unimplemented; both endpoints trust client-supplied identifiers and perform no server-side ownership check.
- S5 — Assembly fails partway: unimplemented; failures have no terminal `failed` state, no reason, no bounded retry path, and no protection against half-written or stale artifacts being treated as valid.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` and the inline `track_export(app_id, workspace_id)` route call — analytics, PostHog capture, and daily active creator rollups are not requested by the blueprint or system design. This widens scope, adds an external network dependency to export creation, writes to an unrelated table, and can make a successful export fail because an analytics provider or rollup insert failed. It also violates the `kite-arch-compass` governing ideas behind P11, "Isolate external dependencies behind adapters," P20, "Choose fail-open vs fail-closed deliberately," and P24, "Contain blast radius; isolate failure," because a third-party analytics call is made directly and synchronously from the route with no documented failure policy.

## Scenario reviews
### Scenario S1 — Creator requests an export
- Why the implementation is unacceptable: `create_export` puts almost the entire feature in `backend/app/routes/export_routes.py`: it walks the app file tree, builds a zip in memory, writes it to `/data/exports/{app_id}.zip`, inserts a row with raw SQL, and returns a local filesystem path. That contradicts the system design's placement decision that routes parse and delegate to `ExportService`, while slow assembly runs on a Celery worker. The migration also omits required state: there is no `app_version`, `status`, `failure_reason`, `idempotency_key`, or state transition trail. Because the DB row is written only after assembly and artifact write complete, a timeout or crash leaves no export job to resume, inspect, or report to the Creator. The endpoint also accepts `workspace_id` from the client instead of request-scoped identity, so even the happy path is built on untrusted ownership input.
- Principle violations (kite-arch-compass): P1, "Separation of concerns through strict layering," is violated because the route reaches directly into filesystem and database concerns instead of delegating to a service and database module. P2, "Thin edges, thick core," is violated because the HTTP handler contains business logic and zip assembly. P7, "Explicit, typed contracts," is violated because the request/response bodies are not Pydantic schemas. P16, "Model long or external flows as resumable state machines," is violated because export assembly is a single blocking call with no committed transitions. P19, "Do slow and fallible work asynchronously, with backpressure," is violated because the request path performs `os.walk`, zip compression, and file writes. P14, "Durable state for correctness," is violated because correctness-critical export status and failure information are not persisted.
- Impact: large or fallible exports will block HTTP workers, time out without a job record, consume unbounded request memory, and leave users with either a raw server path or no recoverable export state. The platform cannot truthfully tell the Creator whether the export is pending, assembling, ready, or failed.
- Failure scenario:
  ```gherkin
  Given a Creator owns an app with thousands of generated files
  When they click "Export"
  And the route spends longer than the client timeout walking and zipping the files
  Then no pending export row exists for the Creator to poll or retry safely
  And the zip assembly is not resumed by a worker
  And the Creator never receives the promised download link for a completed export job
  ```

### Scenario S2 — Creator downloads a completed export
- Why the implementation is unacceptable: `download_export` only selects `artifact_path` and returns `{"path": row[0]}`. It does not stream a zip, does not verify that the export is `ready`, does not mark the export as `downloaded`, and cannot distinguish `pending`, `assembling`, `failed`, `ready`, or already downloaded because the table has no `status` column. It also has no authorization check and does not handle a missing export row before indexing `row[0]`.
- Principle violations (kite-arch-compass): P7, "Explicit, typed contracts," is violated because the response is an ad hoc JSON object instead of a typed download response/streaming contract. P14, "Durable state for correctness," is violated because the `downloaded` state cannot be persisted. P16, "Model long or external flows as resumable state machines," is violated because the required `ready -> downloaded` transition does not exist. P28, "Make trust boundaries explicit and guarded," is violated because opening a download URL crosses a public trust boundary with no guarded ownership check. P5, "Single source of truth," is violated in the auth component because ownership is not resolved through the central access rule described by the checklist.
- Impact: users do not receive the zip through the API, failed or incomplete exports can be treated as downloadable, audit/state tracking is impossible, and any caller who guesses an export id can obtain the server-side artifact path.
- Failure scenario:
  ```gherkin
  Given an export row points at an artifact path but the export is not ready
  When the Creator opens `/exports/{export_id}/download`
  Then the API returns the filesystem path rather than streaming the zip
  And the export is not marked as downloaded
  And the caller is not prevented from using a non-ready or unauthorized export reference
  ```

### Scenario S3 — Double-click / retried export request
- Why the implementation is unacceptable: this scenario is not implemented at all. The POST endpoint always builds a new zip and inserts a new row. The schema lacks `app_version`, `idempotency_key`, and the required partial unique index on `(app_id, app_version)` for non-terminal exports. There is no create-or-return-existing query and no conflict handling. The artifact path is deterministic only by `app_id`, so duplicate requests can both create rows while racing to overwrite the same zip path.
- Principle violations (kite-arch-compass): P15, "Idempotency by design," is violated because a retried POST performs the expensive side effect again and creates another row instead of safely returning the existing export. P18, "Persisted contracts stay backward-compatible," is violated because the migration does not establish the durable schema contract the feature requires: no version column, no idempotency key, and no partial uniqueness rule. P19, "Do slow and fallible work asynchronously, with backpressure," is violated again because duplicate requests multiply synchronous zip work in HTTP workers rather than coalescing behind one queued job.
- Impact: double-clicks and client retries create duplicate export records, duplicate CPU/storage work, and races over `/data/exports/{app_id}.zip`. A user can receive multiple export ids that all claim to represent the same app version, with no reliable way to know which artifact is valid.
- Failure scenario:
  ```gherkin
  Given a Creator double-clicks "Export" for the same app version
  When the two POST `/exports` requests arrive close together
  Then both requests walk and zip the same app files
  And both insert separate `app_exports` rows
  And the later write can overwrite the first request's `/data/exports/{app_id}.zip`
  And the second response does not return the existing export as required
  ```

### Scenario S4 — Export of an app the Creator does not own
- Why the implementation is unacceptable: this scenario is not implemented. `create_export` accepts both `app_id` and `workspace_id` as caller-supplied parameters, uses them directly, and never resolves the requesting Creator's workspace from authenticated request context. `download_export` accepts only `export_id` and never verifies that the export belongs to the caller's workspace. The implementation therefore cannot enforce "a Creator may only export apps in their own workspace."
- Principle violations (kite-arch-compass): P28, "Make trust boundaries explicit and guarded," is violated because platform identifiers and workspace ownership cross from untrusted request input into filesystem and database operations without a guard. P26, "Defense in depth," is violated because there is no route-level auth/ownership layer backing up the endpoint. P27, "Least privilege," is violated because any caller can cause the route to read arbitrary app exportable files by id rather than being limited to apps they can access. P5, "Single source of truth," is violated because the auth checklist requires ownership to be resolved through the central access rule, not re-created from client-supplied `workspace_id`.
- Impact: this is a direct cross-workspace data exposure path. A Creator who can guess or obtain another app id can trigger zip assembly for that app and then use the returned path or export id to access data they do not own.
- Failure scenario:
  ```gherkin
  Given Creator A belongs to workspace A
  And Creator B owns app `victim_app` in workspace B
  When Creator A sends POST `/exports` with `app_id=victim_app` and any `workspace_id`
  Then the route reads `/data/apps/victim_app/files`
  And it creates an export row without checking Creator A's access
  And Creator A receives an export reference for another workspace's app
  ```

### Scenario S5 — Assembly fails partway
- Why the implementation is unacceptable: this scenario is not implemented. The table cannot represent `failed` and has no `failure_reason`. The assembly is not a Celery task, so there are no bounded retries, no retry exhaustion behavior, and no terminal failure transition. If `os.walk`, `zf.write`, or the artifact write fails, the route raises an error without recording a failed export. If the artifact write succeeds but the DB insert fails, the platform leaves an orphan artifact. Because downloads do not check status, any stale or partial artifact path that is present can still be treated as downloadable.
- Principle violations (kite-arch-compass): P21, "Bound every retry; define terminal states," is violated because failure has no terminal state and no bounded retry path. P16, "Model long or external flows as resumable state machines," is violated because the implementation has no `pending -> assembling -> ready/failed` transitions. P20, "Choose fail-open vs fail-closed deliberately," is violated because storage, filesystem, analytics, and database failures fall through as incidental exceptions rather than a designed failure policy. P24, "Contain blast radius; isolate failure," is violated because failed artifact writes and orphan files are not isolated from later downloads. P31, "Observability is built in and correlatable," is violated because failures are not persisted with request/user/app context that can be traced from user action to outcome.
- Impact: Creators cannot be shown that an export failed, operators cannot diagnose the failure from durable export state, retries are not bounded or resumable, and corrupted or stale artifacts can remain on disk without a trustworthy database status to suppress downloads.
- Failure scenario:
  ```gherkin
  Given an export starts for an app whose generated files include a missing source file
  When `zf.write` raises during route execution
  Then the request fails with an exception
  And no `app_exports` row records `status = failed`
  And no `failure_reason` is available to show the Creator
  And the platform has no terminal state that prevents a stale artifact from being offered later
  ```

## Missed corner cases
- Path traversal and malformed identifiers — `app_id` is interpolated into `/data/apps/{app_id}/files` and `/data/exports/{app_id}.zip` without a typed schema or validation, so a non-UUID or traversal-style id can point the route at unintended filesystem locations.
- Artifact collisions across workspaces and versions — the artifact key uses only `app_id`, so two workspaces, two versions, or two exports of the same app can overwrite each other's zip instead of producing versioned, ownership-scoped artifacts.
- Missing export id on download — `download_export` does not handle `SELECT ... WHERE id = :id` returning no row, so an unknown id becomes a server error instead of a controlled 404/403 response.
- Deleted or unreadable artifact at download time — the GET path never checks that the artifact exists and is readable before shaping a download response, so a missing file cannot become a clear failed/not-found state.
- Database insert failure after artifact write — the implementation writes the zip before inserting the export row, so a DB failure leaves an orphan artifact that no export state owns or can clean up.
- Analytics provider outage — the orphan `track_export` call can time out or raise in the export request path, making analytics availability part of export correctness even though the feature never required it.
- Memory pressure for large apps — the route builds the entire zip in `io.BytesIO()` before writing it, so a large generated app can exhaust worker memory rather than streaming assembly in a bounded worker process.
- Concurrent download/update races — the design requires marking `downloaded`, but the implementation has no state or transaction around download, so future attempts to add this could double-mark or miss audit state unless the blueprint specifies concurrency behavior.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, and S5 all need rework. S1 and S2 should be rebuilt around the designed route-service-db-worker split and persisted state machine. S3, S4, and S5 need actual implementation rather than planned status.
- Corner cases to promote into the blueprint: malformed/path-traversal app ids; artifact naming and retention across app versions/workspaces; missing export ids; deleted/unreadable artifacts; artifact cleanup when DB persistence fails; analytics/telemetry failure isolation if analytics is later requested; memory and size limits for large exports; concurrent download state updates.
