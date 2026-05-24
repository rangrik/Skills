# Feature Review: App Export Download

## Summary
- Coverage: 2 of 5 scenarios have code changes associated with them; 0 of 5 satisfy the blueprint and system design as implemented.
- S1 - Creator requests an export: unacceptable; the route performs synchronous zip assembly, writes local files, writes SQL directly, trusts client workspace input, and does not create the designed worker-backed state machine.
- S2 - Creator downloads a completed export: unacceptable; it returns a server file path instead of streaming, skips status and ownership checks, and never marks the export downloaded.
- S3 - Double-click / retried export request: unimplemented; there is no app_version, idempotency_key, create-or-return-existing behavior, or unique index.
- S4 - Export of an app the Creator does not own: unimplemented; both endpoints trust client-supplied workspace_id or perform no workspace check.
- S5 - Assembly fails partway: unimplemented; there is no status column, failed terminal state, failure_reason, cleanup path, or bounded worker retry.

## Orphan changes (not traceable to any scenario)
- `backend/app/services/usage_analytics.py` - This is a new cross-cutting analytics module, PostHog network call, and active-creators rollup write that neither the blueprint nor the system design requested. It adds external failure modes, persistence side effects, and product analytics behavior outside the reviewed feature scope.
- Inline `track_export(app_id, workspace_id)` call from `create_export` - This turns the export route into a synchronous analytics dispatcher. It is not part of S1 or S2, blocks the export request on an unrelated third-party call, and is not covered by any scenario.
- Direct `requests.post("https://app.posthog.com/capture/")` - This bypasses the platform's adapter/telemetry conventions and creates a second observability path instead of using the established wrapper or provider seam.

## Scenario reviews

### Scenario S1 - Creator requests an export
- Why the implementation is unacceptable: `POST /exports` builds the zip inside the FastAPI handler with `os.walk`, stores the whole archive in memory via `BytesIO`, writes to `/data/exports/{app_id}.zip`, and only then inserts a database row. This contradicts the agreed design: the route was supposed to be thin, call `ExportService`, create a `pending` row, enqueue a Celery assembly task, and return a download link backed by a resumable state machine. The migration omits `status`, `app_version`, `failure_reason`, and `idempotency_key`, so the row cannot represent the designed lifecycle. The route also trusts `workspace_id` from the request, exposes a server artifact path in the response, has no Pydantic request/response contract, and has no service or database module boundary.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering - the route reaches directly into SQL and filesystem persistence instead of delegating routes -> services -> database modules. [P2] Thin edges, thick core - business logic and archive assembly live in the HTTP adapter. [P7] Explicit, typed contracts - query parameters and response are untyped ad hoc values rather than Pydantic schemas. [P14] Durable state for correctness - correctness-critical state is not fully persisted because the lifecycle state, app version, failure reason, and idempotency metadata do not exist. [P16] Model long or external flows as resumable state machines - the export is a single blocking call, not `pending -> assembling -> ready/failed`. [P17] Make transaction and ownership boundaries explicit - raw `engine.begin()` in the route owns persistence implicitly. [P19] Do slow and fallible work asynchronously, with backpressure - zip assembly and file IO run in the request path. [P28] Make trust boundaries explicit and guarded - workspace identity is accepted from user input rather than request-scoped identity. [P29] Never trust user input - `app_id` and `workspace_id` are used directly for filesystem paths and authorization-sensitive state.
- Impact: A realistic export can time out, exhaust memory, or leave a zip file without a corresponding durable lifecycle row. A Creator can request an export for any `app_id` and choose any `workspace_id`, and the returned value leaks a server-local path rather than a safe download URL.
- Failure scenario:
  ```gherkin
  Given a Creator exports an app with thousands of generated files
  When POST /exports handles zip assembly in the request process
  Then the request blocks until the archive is complete
  And the platform cannot report pending, assembling, ready, or failed state
  And a timeout or process crash can leave an artifact with no recoverable export state
  ```

### Scenario S2 - Creator downloads a completed export
- Why the implementation is unacceptable: `GET /exports/{id}/download` fetches only `artifact_path` and returns `{"path": row[0]}`. It does not stream the zip, does not require `status == ready`, does not mark the export as `downloaded`, does not check workspace ownership, and does not handle missing rows. Because the schema has no `status`, the endpoint cannot distinguish pending, ready, downloaded, or failed exports at all.
- Principle violations (kite-arch-compass): [P1] Separation of concerns through strict layering - direct SQL in the route bypasses the service and database-module layers. [P2] Thin edges, thick core - download eligibility and state transition logic belongs in a service, not the HTTP handler. [P7] Explicit, typed contracts - the response is an ad hoc JSON object rather than a typed file response or schema. [P14] Durable state for correctness - downloaded state is not persisted. [P17] Make transaction and ownership boundaries explicit - the state transition that should mark `downloaded` is absent. [P20] Choose fail-open vs fail-closed deliberately - the endpoint fails open by serving whatever path is present without a ready-state check. [P28] Make trust boundaries explicit and guarded - no request-scoped identity or workspace boundary is enforced.
- Impact: A Creator can obtain a server path for an export that is not ready, failed, or belongs to another workspace. The product cannot audit or enforce single-download semantics because `downloaded` is never written.
- Failure scenario:
  ```gherkin
  Given an export row exists for another workspace and its artifact_path points to a zip
  When a Creator guesses the export id and opens GET /exports/{id}/download
  Then the endpoint returns the artifact path without checking workspace ownership
  And the export is not marked downloaded
  ```

### Scenario S3 - Double-click / retried export request
- Why the implementation is unacceptable: There is no implementation for retries or double-clicks. The plan still marks S3 as planned, the diff explicitly says there is no idempotency handling, and the migration has no `app_version`, no `idempotency_key`, and no partial unique index on `(app_id, app_version)` for live exports. Each POST inserts a new row and rewrites the same `/data/exports/{app_id}.zip` path.
- Principle violations (kite-arch-compass): [P15] Idempotency by design - repeated export requests are not create-or-return-existing and can cause duplicate rows and duplicated work. [P14] Durable state for correctness - the database lacks the version and state fields needed to identify the existing live export. [P18] Persisted contracts stay backward-compatible - the new schema is under-specified for the required persisted contract and would need a corrective migration before the scenario can be represented. [P19] Do slow and fallible work asynchronously, with backpressure - retried requests duplicate expensive synchronous archive work instead of collapsing onto one queued job.
- Impact: A double-click or client retry can create multiple export rows, run multiple expensive zip assemblies, and race two writers against the same artifact path. The second request does not return the existing export as required.
- Failure scenario:
  ```gherkin
  Given a Creator double-clicks Export for the same app version
  When two POST /exports requests arrive close together
  Then both requests assemble zip files synchronously
  And both insert app_exports rows
  And the platform does not return the existing live export for the second request
  ```

### Scenario S4 - Export of an app the Creator does not own
- Why the implementation is unacceptable: There is no ownership enforcement on either endpoint. `create_export` accepts `workspace_id` directly from the client and stores it, while `download_export` does not read or compare workspace identity at all. The design required both endpoints to enforce the export workspace against request-scoped Creator identity and never trust a client-supplied workspace id.
- Principle violations (kite-arch-compass): [P26] Defense in depth - the implementation has no route-level authorization layer and no service-level ownership check. [P27] Least privilege - a Creator can request or download exports outside their workspace if they know or guess identifiers. [P28] Make trust boundaries explicit and guarded - trusted workspace identity is not taken from request context; it is either client-supplied or ignored. [P5] Single source of truth - ownership is not resolved through the central `has_access()` style access check described for Authentication & Authorization. [P20] Choose fail-open vs fail-closed deliberately - an authorization-sensitive path fails open.
- Impact: This is a blocking security defect. A Creator can export another workspace's app by passing that app id and an arbitrary workspace id, and can download another workspace's export by id.
- Failure scenario:
  ```gherkin
  Given Creator A belongs to workspace A
  And app B belongs to workspace B
  When Creator A calls POST /exports with app_id for app B and workspace_id set to workspace A
  Then the route creates an export instead of refusing the request
  ```

### Scenario S5 - Assembly fails partway
- Why the implementation is unacceptable: Failure handling is absent. The archive is built before any export state is inserted, so there is no row to move to `failed` if `os.walk`, `zf.write`, or `open(artifact_path, "wb")` fails. The schema has no `status` or `failure_reason`, there is no Celery task, no bounded retry, no terminal failure transition, and no rule preventing half-written artifacts from later being returned.
- Principle violations (kite-arch-compass): [P16] Model long or external flows as resumable state machines - failure-prone assembly is not a committed state machine. [P21] Bound every retry; define terminal states - there are no retries and no explicit `failed` terminal state. [P14] Durable state for correctness - failure state and reason are not persisted. [P19] Do slow and fallible work asynchronously, with backpressure - fallible filesystem work runs in the request path. [P20] Choose fail-open vs fail-closed deliberately - download has no failed/non-ready guard, so invalid artifacts are not denied by design. [P24] Contain blast radius; isolate failure - an assembly failure occurs inside the serving request process and can consume memory or leave local filesystem residue.
- Impact: A missing source file or storage error becomes an HTTP exception instead of a recoverable export state. Users do not see a durable failed export with a reason, operators cannot retry or inspect the failure cleanly, and a partial file at the artifact path may still be exposed by the download route.
- Failure scenario:
  ```gherkin
  Given zip assembly starts for an app
  And writing one source file raises an error after the output file has been opened
  When the request handler fails
  Then no export row is moved to failed with a failure_reason
  And a later download request has no status check preventing a partial artifact from being offered
  ```

## Missed corner cases
- Malicious `app_id` path traversal - Because `app_id` is interpolated into `/data/apps/{app_id}/files` and `/data/exports/{app_id}.zip`, an input containing path separators or `..` can make the route walk or write outside the intended app/export directories. This violates [P29] input validation and [P30] secure-by-default handling of sensitive paths.
- Missing export id on download - `download_export` calls `.first()` and immediately indexes `row[0]`; an unknown id will produce a server error instead of a controlled 404. This leaves the API contract undefined and violates [P7] explicit typed contracts.
- Non-ready export download - Even if later code adds pending rows, the current download path has no `status == ready` guard and will return any stored path. A pending, assembling, failed, or already downloaded export is indistinguishable.
- Large app memory exhaustion - The route buffers the entire zip in memory before writing it. A large app can exhaust worker memory or block the API process, which is exactly the class of work [P19] requires moving to a queue.
- Artifact overwrite across app versions - The artifact path is only `/data/exports/{app_id}.zip`; without `app_version`, later exports overwrite earlier ones and S3 cannot return the correct existing export for a specific app version.
- Analytics outage blocks export - The orphan `track_export` call runs in the request path with a third-party HTTP call. A PostHog slowdown adds latency or failure to export creation even though analytics was not part of the feature contract.
- No deterministic verification surface - The diff contains no tests or schema/model verification updates for route behavior, idempotency, authorization, worker transitions, or failure states. This violates [P34] deterministic validation and [P36] tests and evals as architecture.

## Recommended actions
- Scenarios needing rework: S1, S2, S3, S4, S5. S1 and S2 should not be signed off; S3 through S5 are not implemented at all.
- Corner cases to promote into the blueprint: invalid or path-traversal `app_id`; unknown export id; non-ready and already-downloaded export download behavior; large export size/backpressure limits; artifact naming per app version; analytics/provider outage isolation if analytics is later requested; deterministic test coverage for auth, idempotency, state transitions, and failure cleanup.
