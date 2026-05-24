# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have associated implementation changes; 0 of 5 are acceptable for sign-off. S1 and S2 are committed but contradict the agreed design; S3, S4, and S5 are still only planned and have no implementation.
- S1 — Creator requests an export: unacceptable; the route performs synchronous zip assembly, writes files, writes SQL directly, returns an internal artifact path, and never creates the designed worker-backed export state machine.
- S2 — Creator downloads a completed export: unacceptable; the endpoint returns a server file path instead of streaming a ready zip, performs no status check, and never marks the export downloaded.
- S3 — Double-click / retried export request: unimplemented; there is no app version, idempotency key, create-or-return-existing behavior, or partial unique index.
- S4 — Export of an app the Creator does not own: unimplemented; both endpoints trust client-supplied identifiers and perform no server-side ownership check.
- S5 — Assembly fails partway: unimplemented; there is no `failed` state, failure reason, bounded retry path, or protection from half-written artifacts.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` and the inline `track_export(app_id, workspace_id)` call from `export_routes.py` — analytics, PostHog capture, and the `active_creators_daily` rollup are not in the blueprint or system design. This adds a third-party network call and unrelated database write to the export path, directly from the route, without an adapter or any stated fail-open/fail-closed behavior. It violates the agreed scope and introduces a new failure mode where analytics can delay or break export creation.

## Scenario reviews
### Scenario S1 — Creator requests an export (happy path)
- Why the implementation is unacceptable: The blueprint requires an export job and the design requires `POST /exports` to create a `pending` row, enqueue Celery assembly, and return a download link once the worker-backed flow reaches `ready`. The implementation instead builds the entire zip inside the FastAPI handler using `os.walk`, writes `/data/exports/{app_id}.zip` in the request path, inserts only `app_id`, `workspace_id`, and `artifact_path`, and returns an internal filesystem path. There is no `ExportService`, no database module, no Celery task, no status, no app version, no idempotency key, no failure state, and no response contract that represents a job or a download link.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering and [P2] Thin edges, thick core are violated because the HTTP route owns business logic, filesystem assembly, and persistence. [P7] Explicit, typed contracts is violated because inputs and outputs are untyped function parameters and ad hoc dictionaries instead of Pydantic request/response schemas. [P19] Do slow and fallible work asynchronously, with backpressure is violated because large zip assembly blocks the request. [P16] Model long or external flows as resumable state machines and [P14] Durable state for correctness are violated because export state is not persisted as `pending -> assembling -> ready`.
- Impact: A normal large app can tie up the request worker for the full assembly duration, fail with a raw server error, and leave the platform with no durable export state to resume, inspect, or show to the Creator.
- Failure scenario:
```gherkin
Given a Creator owns an app with thousands of generated files
And one source file is removed while export assembly is walking the app directory
When the Creator clicks "Export"
Then the POST handler raises during inline zip creation
And no export row records a pending, ready, or failed state
And the Creator receives no valid download link or recoverable export job
```

### Scenario S2 — Creator downloads a completed export
- Why the implementation is unacceptable: The blueprint requires the completed zip to be streamed and the export to be marked as downloaded. The implementation selects only `artifact_path` by `export_id` and returns `{"path": row[0]}`. It does not stream bytes, set a content type, check that the export is `ready`, mark the row `downloaded`, handle a missing row, or enforce that the requesting Creator can access the export. Because the migration has no `status` column, this endpoint cannot implement the designed `ready`-only download rule.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering and [P2] Thin edges, thick core are violated by direct SQL in the route. [P14] Durable state for correctness is violated because the completed/downloaded distinction is not persisted. [P20] Choose fail-open vs fail-closed deliberately is violated because non-ready and missing exports fall through to unsafe behavior rather than failing closed. [P28] Make trust boundaries explicit and guarded is violated because the route exposes export data by caller-supplied id with no guarded ownership boundary.
- Impact: A Creator does not actually download a zip from the API; they receive an internal server path. Failed, partial, stale, or unauthorized artifacts can be exposed because readiness and ownership are never checked.
- Failure scenario:
```gherkin
Given an export row exists with `artifact_path` pointing at a partially written zip
When the Creator opens `/exports/{export_id}/download`
Then the handler returns the server path without checking `status == ready`
And the zip is not streamed to the Creator
And the export is not marked as downloaded
```

### Scenario S3 — Double-click / retried export request (corner case)
- Why the implementation is unacceptable: This scenario is still marked `planned` and the diff confirms there is no idempotency handling. The table has no `app_version`, no `idempotency_key`, no status, and no partial unique index on `(app_id, app_version)`. The route always creates a new row and always writes to `/data/exports/{app_id}.zip`; concurrent retries can duplicate rows while racing on the same artifact path.
- Principle violations (kite-arch-compass): [P15] Idempotency by design is violated because a repeated export request can cause duplicate rows and duplicate assembly work. [P14] Durable state for correctness is violated because the schema cannot record the app version or live export state needed to find the existing export. [P18] Persisted contracts stay backward-compatible is violated by introducing a schema that lacks the durable contract the feature immediately requires.
- Impact: A double-click or client retry can create multiple exports for the same app version, overwrite an in-progress artifact, and return different export ids for the same user action.
- Failure scenario:
```gherkin
Given a Creator double-clicks "Export" for the same app version
When two POST requests reach the server at nearly the same time
Then both requests build a zip and insert an `app_exports` row
And both write to `/data/exports/{app_id}.zip`
And the second request does not return the existing export
```

### Scenario S4 — Export of an app the Creator does not own (corner case)
- Why the implementation is unacceptable: This scenario is still marked `planned`, and the code performs no ownership check on either endpoint. `create_export` accepts `workspace_id` directly from the client and uses it in the insert. `download_export` accepts only `export_id` and returns the stored path for any matching row. The agreed design explicitly required workspace ownership to come from request-scoped identity, never from client-supplied workspace ids.
- Principle violations (kite-arch-compass): [P5] Single source of truth is violated because ownership is not resolved through the centralized access rule (`has_access()` in the checklist). [P26] Defense in depth and [P28] Make trust boundaries explicit and guarded are violated because there is no route-level auth/ownership guard and untrusted client parameters cross directly into filesystem and database operations. [P20] Choose fail-open vs fail-closed deliberately is violated because a security-critical path fails open.
- Impact: A Creator who can guess or obtain another app id or export id can create or retrieve an export outside their workspace.
- Failure scenario:
```gherkin
Given Creator A belongs to workspace A
And app B belongs to workspace B
When Creator A sends `POST /exports` with app B's id and any `workspace_id`
Then the route zips `/data/apps/{app_b}/files`
And inserts an export row without verifying workspace ownership
And Creator A receives the artifact path for an app they do not own
```

### Scenario S5 — Assembly fails partway (edge case)
- Why the implementation is unacceptable: This scenario is still marked `planned`, and the committed code cannot represent failure. The table has no `status` or `failure_reason`; assembly is not wrapped in a worker task; there are no bounded retries; and the download endpoint cannot distinguish ready, failed, or partial artifacts. A filesystem error while writing the artifact can leave a truncated file at the same path used by prior exports.
- Principle violations (kite-arch-compass): [P16] Model long or external flows as resumable state machines is violated because assembly is a single blocking call with no committed transitions. [P21] Bound every retry; define terminal states is violated because no retry exhaustion or `failed` terminal state exists. [P14] Durable state for correctness is violated because failure reason and readiness are not persisted. [P19] Do slow and fallible work asynchronously, with backpressure is violated because the fallible assembly work runs in the request path.
- Impact: A failed export appears only as a request failure, not as an export in `failed` state that the product can show to the Creator. Worse, a partially written or stale artifact can still be returned by the download endpoint because readiness is never checked.
- Failure scenario:
```gherkin
Given an existing export row points to `/data/exports/app-1.zip`
And the Creator requests a new export for the same app
When the server opens that path for writing and the disk fills partway through the write
Then the artifact can be left truncated
And no export row is marked `failed` with a reason
And `/exports/{export_id}/download` can still return the path without detecting the bad zip
```

## Missed corner cases
- Missing or unknown `export_id` — `download_export` calls `.first()` and then `row[0]`; a missing row becomes an unhandled server error instead of a deliberate 404 or access-denied response.
- Artifact path collision across versions and retries — every export for an app writes `/data/exports/{app_id}.zip`, so a new export can overwrite a previous ready export even if the previous download link is still in use.
- App id filesystem containment — `app_id` is accepted as an untyped string and interpolated into `/data/apps/{app_id}/files`; there is no schema validation or centralized lookup that confines exports to a known app record and source directory.
- Missing app directory or empty source tree — `os.walk(base)` can produce an empty zip if the source directory is absent, and the code will still insert an export row and return an artifact path.
- Analytics provider outage — the orphan PostHog call runs inline from the route with no adapter and no explicit fail-open/fail-closed behavior; a telemetry timeout or exception can delay or fail an otherwise unrelated export request.
- Deleted artifact after a ready row exists — the download route returns the stored path without checking file existence, status, or streaming errors, so the product has no way to surface a controlled failed-download state.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, and S5. S1 and S2 need to be rebuilt against the agreed service, state-machine, worker, schema, and authorization design; S3, S4, and S5 must be implemented before final review.
- Corner cases to promote into the blueprint: missing export id, artifact deletion, artifact path collision across app versions/retries, app id validation and filesystem containment, missing source directory behavior, analytics/provider outage behavior if analytics remains in scope, and repeat-download semantics after an export is marked downloaded.
