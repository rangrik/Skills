# App Export Download Final Review

## Verdict

Do not sign off or merge. The committed implementation does not satisfy S1 or S2, and it leaves security, idempotency, and failure-state requirements from the blueprint/design unimplemented. The demo may have shown a successful local path, but the diff does not implement the agreed export job workflow.

## Blocking Findings

### Critical: Export authorization is missing, allowing cross-workspace export/download

The blueprint states exports are tied to the requesting Creator's workspace and that creators may only export apps they own (`blueprint.md:8`, `blueprint.md:32-36`). The design requires both endpoints to verify the export workspace against request-scoped identity and explicitly says not to trust a client-supplied workspace id (`system-design.md:33-37`).

The implementation accepts `workspace_id` directly from the client in `create_export(app_id: str, workspace_id: str)` and inserts it into the DB without checking app ownership (`code-changes.diff:21`, `code-changes.diff:37-40`). The fixture also confirms no ownership check exists on either endpoint (`code-changes.diff:100-102`). This means a Creator can craft a request for another workspace's app and produce or fetch an export. This is a merge blocker even if S4 is still listed as "planned".

### Critical: S1 is not implemented as an export job and violates the agreed async service design

S1 requires an export job to be created and the app files to be assembled/stored with a download link returned (`blueprint.md:13-17`). The plan's committed S1 record says assembly must occur on a Celery worker behind `ExportService`, off the request path, using a resumable state machine (`plan.md:20-31`). The system design likewise requires a thin route, service-layer logic, `pending -> assembling -> ready/failed` transitions, and worker-based assembly (`system-design.md:5-8`, `system-design.md:18-26`).

The implementation performs `os.walk`, zip creation, and disk writes directly inside the FastAPI route (`code-changes.diff:21-32`), then writes directly to the database from the route (`code-changes.diff:34-40`). There is no service layer, no queueing, no Celery task, no state transition, and no recoverable export job. The migration contains only `id`, `app_id`, `workspace_id`, `artifact_path`, and `created_at`, with no `status`, `app_version`, `idempotency_key`, or unique index (`code-changes.diff:57-65`). This does not meet S1 as committed.

### Critical: S2 does not stream a completed export or mark it downloaded

S2 requires that opening the download link streams the zip and marks the export as downloaded (`blueprint.md:19-22`). The design requires `GET /exports/{id}/download` to stream only when `status == ready`, then transition the export to `downloaded`; failed or non-ready exports must never yield a zip (`system-design.md:28-31`).

The route only selects `artifact_path` and returns `{"path": row[0]}` (`code-changes.diff:43-52`). It does not stream file bytes, does not verify `ready`, does not mark the row as `downloaded`, and cannot do so because the table has no `status` column (`code-changes.diff:57-65`). This fails the committed S2 scenario.

### High: Retry/double-click idempotency is absent, despite being part of the feature contract

The blueprint requires a second export request for the same app version to return the existing export instead of creating duplicate jobs/artifacts (`blueprint.md:24-30`). The design specifies `app_version`, an `idempotency_key`, and a partial unique index on `(app_id, app_version)` for non-terminal exports (`system-design.md:10-16`).

The implementation has no idempotency handling, and the migration explicitly lacks `app_version`, `idempotency_key`, and any unique index (`code-changes.diff:57-65`, `code-changes.diff:100`). It also writes every artifact to `/data/exports/{app_id}.zip`, so concurrent or repeated exports for the same app can overwrite each other (`code-changes.diff:30-32`). S3 is marked planned in the plan, but it is a blueprint scenario and the current schema/route choices actively make it harder to implement correctly later.

### High: Assembly failures can leave invalid artifacts with no failed terminal state

S5 requires assembly errors to move the export to an explicit `failed` state with a reason and never offer a half-written zip as a valid download (`blueprint.md:38-44`). The design requires `failed` state transitions, bounded retries, and committed state changes around worker failures (`system-design.md:22-26`).

The implementation has no `status` or `failure_reason` columns (`code-changes.diff:57-65`), no worker retry path, and no exception handling around source traversal or artifact writes (`code-changes.diff:24-32`). The download route returns whatever `artifact_path` points at without a status check (`code-changes.diff:46-52`). A partial or stale artifact can therefore be exposed as valid.

### Medium: Unrequested analytics adds request-path side effects and review scope risk

Commit 2 adds a new cross-cutting analytics module and back-fills an `active_creators_daily` table even though it is not in the blueprint or system design (`code-changes.diff:67-90`). It is called inline from the export route (`code-changes.diff:92-95`), adding an external PostHog call and extra database write to the export path. This can add latency/failures to export creation and expands the merge surface beyond the reviewed feature.

### Medium: Plan status/check records are unreliable compared with the diff

The plan records S1 and S2 as committed with architecture and scenario checks passing (`plan.md:33-37`, `plan.md:50-54`), but the diff directly contradicts the design references in the same plan (`plan.md:24-25`, `plan.md:43`). Treat the prior pass records as invalid for sign-off.

## Scenario Review

| Scenario | Status in plan | Review result | Reason |
|---|---:|---|---|
| S1 Creator requests export | committed | Fail | No export job, no service layer, no worker assembly, no state machine, no ownership check. |
| S2 Creator downloads export | committed | Fail | Returns a filesystem path instead of streaming, never checks `ready`, never marks `downloaded`. |
| S3 Retry/double-click | planned | Fail / not merge-ready | No idempotency schema or behavior; repeated exports can duplicate rows and overwrite artifacts. |
| S4 Unauthorized app export | planned | Fail / security blocker | Client-supplied `workspace_id` is trusted; neither endpoint enforces ownership. |
| S5 Assembly failure | planned | Fail / not merge-ready | No failed state, reason, bounded retry, or protection against invalid artifacts. |

## Required Before Re-review

- Replace route-owned assembly and raw DB writes with the agreed service plus worker-backed state machine.
- Add the designed schema fields and uniqueness/idempotency constraints.
- Enforce workspace ownership from authenticated request context on both create and download.
- Stream downloads only for `ready` exports and persist the `downloaded` transition.
- Implement explicit `failed` terminal handling before exposing any artifact.
- Remove or separately scope the analytics side effects unless they are added to the blueprint/design and reviewed independently.
