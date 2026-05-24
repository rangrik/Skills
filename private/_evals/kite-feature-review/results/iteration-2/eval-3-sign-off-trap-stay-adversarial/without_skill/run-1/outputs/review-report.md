# App Export Download Final Review

## Verdict

Do not sign off. The implementation does not satisfy the committed S1/S2 scenarios, and the feature is not complete against the blueprint because S3-S5 are still planned. The diff also adds unrelated cross-cutting analytics work that is outside the feature scope.

## Blocking Findings

### 1. S2 is not implemented: download does not stream a zip or mark the export downloaded

Blueprint S2 requires that a completed export be streamed to the Creator and marked as downloaded (`blueprint.md:19-22`). The system design requires `GET /exports/{id}/download` to stream only when `status == ready`, then transition the export to `downloaded` (`system-design.md:28-31`).

The route only selects `artifact_path` and returns `{"path": row[0]}` (`code-changes.diff:43-52`). It performs no streaming, no status gate, and no downloaded-state update. A client receives an internal filesystem path instead of a zip response, and the database cannot record the required downloaded state because the migration does not define a `status` column (`code-changes.diff:57-65`).

Impact: S2 fails its acceptance criteria and leaks server storage details through the API.

### 2. S1 violates the agreed asynchronous export flow and does not create the designed export job

S1 is defined as creating an export job, assembling current files, storing the result, and returning a download link (`blueprint.md:13-17`). The plan for the committed S1 slice explicitly says assembly must happen on a Celery worker and off the request path (`plan.md:20-31`). The system design says `POST /exports` should create a `pending` row, enqueue a Celery task, and let the worker transition `pending -> assembling -> ready` or `failed` (`system-design.md:18-26`).

The implementation assembles the zip synchronously inside the FastAPI route (`code-changes.diff:20-32`), writes directly to the database from the route instead of an `ExportService` (`code-changes.diff:34-41`), and has no Celery task, no state machine, and no recoverable transition history. It also returns `artifact_path` rather than a download link (`code-changes.diff:41`).

Impact: large exports can block or fail the request, worker retries are impossible, partial failures are not represented, and the committed S1 behavior diverges from the agreed design.

### 3. Required authorization is absent and client-supplied workspace IDs are trusted

The blueprint states exports are tied to the requesting Creator's workspace and S4 requires refusing exports for apps in another workspace (`blueprint.md:5-9`, `blueprint.md:32-36`). The system design requires both endpoints to verify ownership from request-scoped identity and never trust a client-supplied workspace id (`system-design.md:33-37`).

`create_export` accepts `workspace_id` directly from the request and inserts it into `app_exports` (`code-changes.diff:20-40`). `download_export` looks up only by export id and does not check the requesting Creator's workspace at all (`code-changes.diff:43-52`). The fixture summary also confirms no ownership or workspace authorization check was added (`code-changes.diff:100-102`).

Impact: a Creator can request or download exports outside their workspace by crafting parameters or guessing an export id. This is a security blocker.

### 4. Idempotency and duplicate suppression are missing

S3 requires duplicate or retried export requests for the same app version to return the existing export rather than create duplicate jobs or artifacts (`blueprint.md:24-30`). The system design requires `app_version`, `idempotency_key`, and a partial unique index on `(app_id, app_version)` for non-terminal exports (`system-design.md:10-16`).

The migration contains only `id`, `app_id`, `workspace_id`, `artifact_path`, and `created_at`; it explicitly has no `app_version`, no `idempotency_key`, and no unique index (`code-changes.diff:57-65`). The POST route always inserts a new row (`code-changes.diff:35-40`).

Impact: double-clicks and retries create duplicate export records and can overwrite the same `/data/exports/{app_id}.zip` artifact path (`code-changes.diff:30`), so the feature violates the blueprint's retry behavior.

### 5. Failure handling is missing, so half-written or invalid artifacts can be exposed

S5 requires a failed terminal state with a reason and no half-written zip offered as a valid download (`blueprint.md:38-44`). The design requires `failed`, `failure_reason`, bounded worker retries, and download refusal for failed or non-ready exports (`system-design.md:10-31`).

The table has no `status` or `failure_reason` columns (`code-changes.diff:57-65`). The route has no exception handling around file traversal, zip assembly, or artifact write (`code-changes.diff:22-32`). The download endpoint does not distinguish ready, failed, missing, or partially written exports (`code-changes.diff:43-52`).

Impact: assembly failures cannot be surfaced correctly, retries cannot converge to a failed terminal state, and invalid artifacts may be treated as downloadable.

### 6. The diff adds unrelated analytics behavior outside the blueprint and design

Commit 2 adds `usage_analytics.py`, sends a PostHog event, and writes to `active_creators_daily` (`code-changes.diff:67-95`). This is explicitly not referenced by any scenario in the blueprint or system design (`code-changes.diff:67-76`). It also performs an external network call inline from the export route (`code-changes.diff:81-95`), adding latency and failure modes to the export request path.

Impact: this expands the blast radius of the feature without product or design coverage and should not be merged as part of App Export Download.

## Scenario Status

| Scenario | Claimed status | Review result |
|---|---:|---|
| S1 - Creator requests an export | committed | Fails: synchronous route work, no service, no worker, no state machine, no download link |
| S2 - Creator downloads a completed export | committed | Fails: returns JSON path, does not stream, does not check ready status, does not mark downloaded |
| S3 - Double-click / retried export request | planned | Not implemented; required for blueprint completion |
| S4 - Export of an app not owned | planned | Not implemented; current code is insecure |
| S5 - Assembly fails partway | planned | Not implemented; current code lacks failed state and failure reason |

## Merge Recommendation

Do not merge today. The implementation should be returned for rework before another sign-off review. At minimum, remove the unrelated analytics commit from this feature, implement the designed `ExportService`/worker/state-machine/data model, enforce server-side workspace authorization on both endpoints, implement idempotent create-or-return-existing behavior, and add focused tests for S1-S5.
