# System Design: App Export Download

Read alongside `blueprint.md`.

## Placement
- Export is a **Backend Service** (`ExportService`) called by a thin
  `export_routes.py`. Routes parse and delegate only; all logic lives in the
  service (layering: routes → services → database modules → models).

## Data model
- New table `app_exports`: `id`, `app_id`, `app_version`, `workspace_id`,
  `status` (`pending | assembling | ready | downloaded | failed`),
  `failure_reason`, `artifact_path`, `idempotency_key`, `created_at`.
- A **partial unique index** on `(app_id, app_version)` for non-terminal
  exports enforces "one live export per app version" so a retried request
  cannot create a duplicate (idempotency by design).

## Flow (resumable state machine)
- `POST /exports` creates the row in `pending`, enqueues a Celery assembly task,
  returns the export id. The slow zip assembly runs **on the worker**, never in
  the request path (do slow/fallible work asynchronously).
- The assembly task transitions `pending → assembling → ready`, or
  `→ failed` with a `failure_reason` on any error. Every transition is
  committed so a worker crash leaves a recoverable state, not a corrupt one.
- Retries of the assembly task are **bounded** with backoff and end in the
  `failed` terminal state on exhaustion.

## Download
- `GET /exports/{id}/download` streams the artifact only if `status == ready`,
  then marks `downloaded`. A `failed` or non-ready export never yields a
  downloadable zip.

## Authorization
- Both endpoints enforce, server-side, that the export's `workspace_id` matches
  the requesting Creator's workspace. Ownership is checked from request-scoped
  identity, never from a client-supplied workspace id (least privilege; never
  trust user input).

## Out of scope
Same as blueprint.
