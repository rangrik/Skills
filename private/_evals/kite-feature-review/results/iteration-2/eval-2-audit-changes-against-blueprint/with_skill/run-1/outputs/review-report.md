# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have any associated implementation changes; 0 of 5 scenarios satisfy the blueprint and system design.
- S1 — Creator requests an export: implemented in name only; the route performs synchronous zip assembly, writes directly to the database, skips the service/worker/state-machine design, and returns a filesystem path instead of a durable download link.
- S2 — Creator downloads a completed export: implemented as a path lookup, not a download; it does not stream the artifact, verify `ready`, authorize access, or mark the export as `downloaded`.
- S3 — Double-click / retried export request: unimplemented; the migration omits `app_version`, `idempotency_key`, and the partial unique index, so retries create duplicate rows and race on the same artifact path.
- S4 — Export of an app the Creator does not own: unimplemented; both endpoints trust client-supplied identifiers and perform no request-scoped ownership check.
- S5 — Assembly fails partway: unimplemented; there is no `failed` state, no `failure_reason`, no bounded worker retry, and no guard preventing a partial artifact from being offered.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` — the blueprint and system design do not request export analytics, PostHog capture, or an `active_creators_daily` rollup. This is scope creep and it introduces a new third-party call and database write without a scenario, data model, migration, adapter, retry policy, or failure contract.
- Inline `track_export(app_id, workspace_id)` from `create_export` — this makes the export request path depend on unrelated analytics. If PostHog is slow or the rollup table is missing, the export can fail for a reason not present in the feature spec. It also violates kite-arch-compass P11, "Isolate external dependencies behind adapters," because the new service calls PostHog directly, and P32, "One unified telemetry and billing pipeline," because it adds another telemetry path instead of using the established wrapper.

## Scenario reviews

### Scenario S1 — Creator requests an export
- Why the implementation is unacceptable: The plan marks S1 committed, but the diff does not create the designed `ExportService`, database module, Celery task, or resumable state machine. `create_export` performs `os.walk`, zip creation, artifact writing, and raw SQL inside the FastAPI route. The system design required `POST /exports` to create a `pending` row, enqueue worker assembly, and return an export id/download link while slow work runs off the request path. The migration also omits `status`, `app_version`, `failure_reason`, `idempotency_key`, and the partial unique index that the service flow depends on. The returned `artifact_path` is a local server path, not a Creator-safe download link.
- Principle violations (kite-arch-compass): P1, "Separation of concerns through strict layering," and P2, "Thin edges, thick core," are violated because the route contains business logic and direct persistence instead of delegating to a service. P7, "Explicit, typed contracts," is violated because the endpoint uses loose query parameters and raw response dictionaries rather than Pydantic request/response contracts. P16, "Model long or external flows as resumable state machines," and P19, "Do slow and fallible work asynchronously, with backpressure," are violated because zip assembly blocks the request and commits no recoverable state transitions. P17, "Make transaction and ownership boundaries explicit," is violated because the route owns raw `engine.begin()` database writes directly. P28, "Make trust boundaries explicit and guarded," is violated because `workspace_id` is supplied by the client rather than request-scoped identity.
- Impact: Large exports can time out the HTTP request, tie up API workers, and leave the Creator without a usable export record or download link. The platform also cannot resume, observe, retry, or accurately report export state because the correctness-critical state machine was not implemented.
- Failure scenario:
  ```gherkin
  Given a Creator owns an app with thousands of generated files
  When they click "Export"
  Then the API request performs the whole zip assembly synchronously
  And the request times out before a worker job or pending export state is created
  And the Creator does not receive a valid download link for a completed export
  ```

### Scenario S2 — Creator downloads a completed export
- Why the implementation is unacceptable: The plan marks S2 committed, but `download_export` only selects `artifact_path` and returns `{"path": row[0]}`. It does not stream a zip, verify the export has reached `ready`, update the row to `downloaded`, handle a missing export id, or authorize the requesting Creator against the export workspace. Because the table has no `status` column, the required `ready -> downloaded` transition is impossible.
- Principle violations (kite-arch-compass): P1 and P2 are violated again because the route reaches into persistence and contains download behavior instead of delegating to the service layer. P7, "Explicit, typed contracts," is violated because the API response exposes an implementation path instead of a typed download response. P14, "Durable state for correctness," is violated because downloaded state is not persisted. P20, "Choose fail-open vs fail-closed deliberately," is violated because non-ready and failed artifacts are not rejected. P26, "Defense in depth," P27, "Least privilege," P28, "Make trust boundaries explicit and guarded," and P5, "Single source of truth" for ownership through `has_access()`, are violated because no access check protects the download endpoint.
- Impact: The endpoint leaks internal storage paths, does not actually deliver the zip, cannot record that the export was consumed, and can disclose another workspace's artifact if the caller guesses or obtains an export id.
- Failure scenario:
  ```gherkin
  Given an export row points at an artifact that is still being assembled
  When a Creator opens `/exports/{id}/download`
  Then the route returns the artifact path without checking `status == ready`
  And the export is not marked as downloaded
  And the Creator does not receive a streamed zip file
  ```

### Scenario S3 — Double-click / retried export request
- Why the implementation is unacceptable: The plan still lists S3 as planned and the diff contains no idempotency implementation. The schema lacks `app_version`, `idempotency_key`, `status`, and the partial unique index on `(app_id, app_version)` for non-terminal exports. The route always inserts a new row and writes to `/data/exports/{app_id}.zip`, so duplicate POSTs create duplicate database records while racing to overwrite the same artifact.
- Principle violations (kite-arch-compass): P15, "Idempotency by design," is directly violated because a retried operation causes duplicate rows and repeated side effects. P14, "Durable state for correctness," is violated because the state needed to identify one live export per app version is not persisted. P18, "Persisted contracts stay backward-compatible," is violated by introducing a table that cannot represent the design's required contract. P16 and P19 are also violated because duplicate slow work is performed synchronously instead of being serialized through a worker-backed state machine.
- Impact: A double-click or client retry can produce multiple export rows, corrupt the artifact by concurrent writes to the same path, and return different export ids for the same app version. The Creator may download whichever request wrote last, not the export corresponding to the returned row.
- Failure scenario:
  ```gherkin
  Given a Creator double-clicks "Export" for the same app version
  When the two POST requests arrive at nearly the same time
  Then each request inserts a separate `app_exports` row
  And both requests write `/data/exports/{app_id}.zip`
  And the platform returns duplicate exports instead of returning the existing export
  ```

### Scenario S4 — Export of an app the Creator does not own
- Why the implementation is unacceptable: The plan lists S4 as planned and the diff does not add authorization to either endpoint. `create_export` accepts both `app_id` and `workspace_id` from the request, never resolves ownership from the authenticated Creator, and never checks that the app belongs to the Creator's workspace. `download_export` fetches by export id alone and performs no workspace check before exposing the artifact path.
- Principle violations (kite-arch-compass): P26, "Defense in depth," is violated because there is no route-level authorization layer protecting the operation. P27, "Least privilege," is violated because any caller who can reach the endpoint can ask for any app id/export id. P28, "Make trust boundaries explicit and guarded," is violated because workspace identity is trusted from user input instead of hidden request-scoped context. P5, "Single source of truth," is violated because ownership is not resolved through the centralized access check. P20, "Choose fail-open vs fail-closed deliberately," is violated because the security path fails open.
- Impact: A Creator can export another workspace's app files or retrieve another workspace's export by crafting an `app_id`, `workspace_id`, or export id. This is a cross-workspace data leak and should block merge.
- Failure scenario:
  ```gherkin
  Given Creator A belongs to workspace A
  And app `app_b` belongs to workspace B
  When Creator A posts `/exports?app_id=app_b&workspace_id=workspace_a`
  Then the route assembles files for `app_b`
  And no server-side ownership check refuses the export
  And Creator A receives an export record or artifact path for another workspace's app
  ```

### Scenario S5 — Assembly fails partway
- Why the implementation is unacceptable: The plan lists S5 as planned and the implementation has none of the required failure semantics. There is no `status` column, no `failed` terminal state, no `failure_reason`, no worker retry policy, no transition commits, and no cleanup or quarantine of partially written artifacts. Exceptions during file walking, zip creation, or artifact writing surface as request failures rather than persisted export outcomes. The download route has no status gate, so any row with an artifact path can be offered even if the underlying file is incomplete or invalid.
- Principle violations (kite-arch-compass): P16, "Model long or external flows as resumable state machines," is violated because failure cannot be represented as a committed transition. P21, "Bound every retry; define terminal states," is violated because no worker retries or terminal failure state exist. P14, "Durable state for correctness," is violated because failure reason and artifact validity are not persisted. P20, "Choose fail-open vs fail-closed deliberately," is violated because invalid artifacts are not rejected on download. P25, "Cancellation is cooperative and idempotent," is violated for interrupted request-path assembly because there is no safe checkpoint or finalizer.
- Impact: A source-file or storage failure leaves the Creator with a generic HTTP error or a misleading path, not an export marked failed with a reason. Operators cannot distinguish transient assembly failures from missing records, and the product can expose a half-written zip as if it were valid.
- Failure scenario:
  ```gherkin
  Given an export begins writing `/data/exports/app_1.zip`
  And the storage write fails halfway through
  When the Creator later opens the download endpoint for the export
  Then the route has no failed state or failure reason to check
  And it returns the artifact path instead of refusing the invalid zip
  ```

## Missed corner cases
- Missing export id on download — `download_export` calls `row[0]` without checking whether the query returned a row, so an unknown id becomes a server error instead of a controlled 404 or fail-closed response.
- Artifact collision across app versions — artifacts are named only by `app_id`, and the schema has no `app_version`, so a later export overwrites an earlier export even when both should remain distinguishable.
- Client disconnect or request cancellation during export — because assembly runs in the request handler, cancellation can interrupt the operation without a cooperative checkpoint, persisted terminal state, or cleanup of filesystem side effects.
- Analytics dependency failure — the orphan PostHog/rollup call can fail or time out inside export creation, making a nonessential analytics outage block the core export workflow.
- Internal path exposure — returning `artifact_path` leaks backend filesystem layout and gives clients a value they cannot safely use as a product download link.
- Missing storage existence/readability check — the download route trusts the stored path and does not verify that the file exists, is readable, and is a complete zip before exposing it.
- No deterministic verification surface — the diff adds no route, service, worker, database, authorization, idempotency, or failure-state tests despite kite-arch-compass P36 treating tests and evals as part of the architecture.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, and S5.
- Corner cases to promote into the blueprint: missing export id handling; artifact collision across app versions; client disconnect/cancellation during assembly; nonessential analytics/provider outage during export; internal storage-path exposure; artifact existence/readability validation before streaming; deterministic tests for idempotency, authorization, worker failure, and status-gated download.
