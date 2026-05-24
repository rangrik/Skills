# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have code changes attached; 0 of 5 satisfy the blueprint and system design.
- S1 — Creator requests an export: implemented in the route, but the route performs the entire export synchronously, bypasses the service/db/worker design, and returns a server file path instead of a durable download link.
- S2 — Creator downloads a completed export: implemented as a database lookup that returns `artifact_path`; it does not stream the zip, check `ready`, mark `downloaded`, or enforce ownership.
- S3 — Double-click / retried export request: unimplemented; there is no app version, status, idempotency key, unique index, or create-or-return-existing path.
- S4 — Export of an app the Creator does not own: unimplemented; both endpoints trust caller-supplied identifiers and perform no server-side workspace authorization.
- S5 — Assembly fails partway: unimplemented; there is no worker, no failed terminal state, no failure reason, no bounded retry, and no protection against exposing a bad artifact.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` — this new cross-cutting analytics service is not requested by the blueprint, system design, or plan. It adds a PostHog call and a daily active-creator rollup write as part of export delivery, which creates new provider, database, latency, and failure behavior outside the reviewed feature.
- Inline `track_export(app_id, workspace_id)` from `backend/app/routes/export_routes.py` — the route now performs an unrequested analytics side effect in the export request path. This is scope creep and also violates the platform boundary model: external providers should be isolated behind local adapter seams, and export behavior should not fail because an unrelated analytics call times out.

## Scenario reviews

### Scenario S1 — Creator requests an export
- Why the implementation is unacceptable: `POST /exports` builds the zip directly inside the FastAPI handler with `os.walk`, writes the artifact synchronously to `/data/exports/{app_id}.zip`, and performs raw SQL through `engine.begin()` from the route. The system design required a thin route calling `ExportService`, a persisted `pending` row, Celery assembly off the request path, state transitions, and a returned download link. The migration omits the required `status`, `app_version`, `failure_reason`, and `idempotency_key` fields, so the request cannot create the durable state machine the design depends on. The response exposes an internal filesystem path rather than a stable download link.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering and [P2] Thin edges, thick core are violated because the route owns business logic, file assembly, and persistence. [P7] Explicit, typed contracts is violated because request and response bodies are implicit query parameters/dicts instead of Pydantic schemas. [P16] Model long or external flows as resumable state machines and [P19] Do slow and fallible work asynchronously, with backpressure are violated because zip assembly blocks the HTTP request and has no committed transitions. [P14] Durable state for correctness is violated because correctness-critical export status is absent from Postgres. [P17] Make transaction and ownership boundaries explicit is violated because transaction ownership is embedded ad hoc in the route instead of the service/db layering. [P31] Observability is built in and correlatable is violated because there is no request-to-worker correlation or worker metadata for the export job.
- Impact: large exports will tie up request workers, time out, or leave the user with no recoverable export record. Because no worker job or status exists, the platform cannot resume, poll, retry, or explain the export outcome. The returned `artifact_path` is a server-local path, not a browser-usable download link.
- Failure scenario:
```gherkin
Given a Creator owns an app with thousands of generated files
When they click "Export"
Then the HTTP request spends the full zip assembly time inside the route
And no pending export job is committed for a worker to resume
And the response contains a server filesystem path instead of a download link
```

### Scenario S2 — Creator downloads a completed export
- Why the implementation is unacceptable: `GET /exports/{export_id}/download` only selects `artifact_path` and returns it as JSON. It never verifies `status == ready`, never streams file bytes, never marks the export as `downloaded`, and has no handling for a missing export row. Since the schema has no status column, the implementation cannot distinguish `pending`, `assembling`, `ready`, `downloaded`, or `failed` exports at all.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering and [P2] Thin edges, thick core are violated again by raw persistence logic in the route. [P7] Explicit, typed contracts is violated by the untyped response. [P14] Durable state for correctness is violated because download state is not persisted. [P17] Make transaction and ownership boundaries explicit is violated because the route owns direct transaction behavior. [P28] Make trust boundaries explicit and guarded and [P20] Choose fail-open vs fail-closed deliberately are violated because a public download endpoint is exposed without an authorization boundary and without a deliberate fail-closed check. [P30] Secure by default; never leak secrets is violated because internal filesystem paths are returned to the client.
- Impact: a Creator opening the download link will not receive a zip stream, and audit/state will never move to `downloaded`. A non-ready or failed export cannot be blocked because that state does not exist. Missing or guessed export IDs degrade into runtime errors rather than controlled responses.
- Failure scenario:
```gherkin
Given an export has finished assembling and should be ready to download
When the Creator opens `/exports/{export_id}/download`
Then the endpoint returns `{"path": "/data/exports/<app_id>.zip"}` instead of streaming the zip
And the export is not marked as downloaded
```

### Scenario S3 — Double-click / retried export request
- Why the implementation is unacceptable: there is no idempotency implementation. `POST /exports` always rebuilds the zip and inserts a new row. The migration explicitly lacks `app_version`, `idempotency_key`, `status`, and the partial unique index on `(app_id, app_version)` that the design required. The artifact path is keyed only by `app_id`, so duplicate requests race on the same output file while producing duplicate database rows.
- Principle violations (kite-arch-compass): [P15] Idempotency by design is violated because retried or double-clicked requests are not safe to repeat. [P14] Durable state for correctness is violated because the durable record lacks app version and live-export state. [P18] Persisted contracts stay backward-compatible is violated because the migration does not create the contract the feature needs to read and evolve. [P17] Make transaction and ownership boundaries explicit is violated because there is no concurrency-safe create-or-return-existing transaction boundary around export creation.
- Impact: client retries after a timeout will create additional export rows and can overwrite the artifact for the first request. The user may receive a different export ID for the same app version, and two requests can corrupt or race the same `/data/exports/{app_id}.zip` path.
- Failure scenario:
```gherkin
Given a Creator clicks "Export" and the client times out before receiving the response
When the client retries `POST /exports` for the same app version
Then the route inserts a second `app_exports` row
And rebuilds the zip into the same artifact path
And returns a different export id instead of the existing export
```

### Scenario S4 — Export of an app the Creator does not own
- Why the implementation is unacceptable: neither endpoint authenticates ownership from request-scoped identity. `create_export` accepts `workspace_id` from the client and writes it directly to the database, and `download_export` fetches by export ID alone. There is no lookup proving the app belongs to the requesting Creator's workspace and no centralized `has_access()` style check.
- Principle violations (kite-arch-compass): [P28] Make trust boundaries explicit and guarded is violated because platform identifiers and workspace ownership are accepted from the request instead of guarded by request-scoped identity. [P27] Least privilege is violated because any caller who can name an app/export gets export/download capability. [P20] Choose fail-open vs fail-closed deliberately is violated because a security-critical path defaults open. [P5] Single source of truth is violated because ownership is not resolved through the platform's central access rule.
- Impact: a Creator can craft an export for another workspace's app, store the resulting row under an arbitrary workspace ID, and later retrieve the artifact path by export ID. The feature turns app export into a cross-workspace data disclosure path.
- Failure scenario:
```gherkin
Given Creator A knows the app id for an app owned by Workspace B
When Creator A calls `POST /exports` with that app id and their own `workspace_id`
Then the server zips Workspace B's app files
And records the export without refusing the cross-workspace request
```

### Scenario S5 — Assembly fails partway
- Why the implementation is unacceptable: failure handling is absent. Zip assembly runs before any meaningful export state is created, exceptions escape the request handler, and the schema has no `failed` state or `failure_reason`. There is no Celery task, no bounded retry policy, no terminal transition on retry exhaustion, and no cleanup/atomic-publish step to prevent a bad artifact from being treated as valid.
- Principle violations (kite-arch-compass): [P16] Model long or external flows as resumable state machines is violated because assembly is a single blocking call with no recoverable transitions. [P21] Bound every retry; define terminal states is violated because there are no bounded retries and no explicit failed terminal state. [P19] Do slow and fallible work asynchronously, with backpressure is violated because storage and file traversal failures occur in the request path. [P14] Durable state for correctness is violated because failure state is not persisted. [P18] Persisted contracts stay backward-compatible is violated because the schema lacks the failure fields specified by the design. [P31] Observability is built in and correlatable is violated because failures are not tied to worker/task metadata or a persisted reason.
- Impact: a missing source file or storage write error becomes an HTTP 500 with no export record the UI can poll and no reason the Creator can see. A partial or stale artifact at the deterministic path may still be returned later because download does not check status.
- Failure scenario:
```gherkin
Given an export starts while one source file is deleted during assembly
When `zf.write()` raises an error in the route
Then the request fails without moving an export to `failed`
And no failure reason is persisted
And no status prevents a stale or partial artifact path from being returned later
```

## Missed corner cases
- Unknown export id — `download_export` dereferences `row[0]` without checking for no result, so a missing or deleted export becomes a server error instead of a controlled 404 or authorization-safe response.
- Path traversal through `app_id` — `app_id` is interpolated into `/data/apps/{app_id}/files` without schema validation or canonical path checks, so a malicious identifier can attempt to walk outside the intended app directory.
- Concurrent download during artifact write — artifacts are written directly to the final path, with no temporary file plus atomic rename and no `ready` transition, so a download can observe a partial file.
- Exporting a new app version — the schema and artifact path do not include `app_version`, so a legitimate later export overwrites the earlier version and makes old export IDs ambiguous.
- Re-opening a downloaded export — the blueprint does not define whether a link may be downloaded more than once after status becomes `downloaded`; the design says downloads stream only when `status == ready`, so repeat-download semantics need an explicit product decision.
- Analytics provider failure — the orphan PostHog call is inline with export creation. If analytics remains part of the product, the blueprint must define whether analytics failures fail open, run asynchronously, or are retried separately.
- Artifact retention and cleanup — failed, stale, and superseded artifacts have no lifecycle rule, so the implementation has no way to prevent abandoned files from accumulating or being confused with valid downloads.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, and S5.
- Corner cases to promote into the blueprint: unknown export IDs; validated/canonical app IDs and path traversal prevention; atomic artifact publication under concurrent reads; app-versioned artifact identity; repeat-download semantics; analytics failure isolation if analytics is in scope; artifact retention and cleanup behavior.
