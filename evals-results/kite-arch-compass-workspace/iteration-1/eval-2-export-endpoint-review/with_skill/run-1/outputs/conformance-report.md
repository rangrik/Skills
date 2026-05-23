# Conformance Report — `backend/app/routes/export_routes.py` (new export endpoint)

Reviewed against the Kite Architecture Compass (43 engineering principles + component map). This is a conformance review (Mode B) of a PR before merge.

Component(s) reviewed:
- **1. Backend HTTP Routes** — the file itself.
- **2. Backend Services** — the handler does substantive business logic that belongs in a service.
- **3. Database Modules & Models** — the handler queries and commits the ORM directly.
- **12. Celery & Background Workers** — file generation is long/fallible work done synchronously on the request path.

**Verdict: Non-conformant.** Do not approve as-is. The endpoint works, but it breaks layering, skips request/response typing, does slow work on the request path, swallows errors, and depends on auto-discovery conventions it does not follow. Several issues are blocking. Concrete remediations below.

---

## Deviations

### 1. [P1] Separation of concerns through strict layering — Backend HTTP Routes / Database Modules
- **Observed:** The route imports `get_session`, the `Export` model, and `select` directly, runs `select(...)` queries, calls `db.add()`, and calls `await db.commit()` inside the handler. It reaches straight past the service layer into `database/` and `models/`.
- **Standard:** Routes are the top layer — they accept a request and delegate downward to a service; they never reach past services into persistence. DB access lives in `*_db.py` modules, called only by services (Component 1; Component 3, [P1]).
- **Severity:** Blocking — this is the central layering rule for the backend, and every other structural problem below follows from it.
- **Remediation:** Create `app/services/export_service.py` to own the flow, and an `app/database/export_db.py` for the queries/writes. The route should do only: parse + validate input, resolve the authenticated user, make one service call, shape the response.

### 2. [P2] Thin edges, thick core — Backend HTTP Routes
- **Observed:** The handler contains the format-validation rule, the daily-quota computation (fetch-all + filter-by-date + compare against an env quota), record creation, file generation, and status transitions — all inline.
- **Standard:** HTTP routes parse and delegate; substantive business logic lives in services, not in the edge. Quota enforcement, record lifecycle, and file generation are business logic ([P2], Component 1 + 2).
- **Severity:** Blocking — it is the same defect as #1 seen from the logic side; the handler is a thick edge.
- **Remediation:** Move format validation, quota enforcement, and the export lifecycle into `export_service.py`. The handler keeps only request parsing, auth, the single service call, and response shaping.

### 3. [P7] Explicit, typed contracts — Backend HTTP Routes
- **Observed:** Inputs `user_id` and `export_format` are bare function arguments (so they bind as query parameters). The success and both error responses are returned as ad-hoc untyped `dict`s.
- **Standard:** Request, response, and event bodies are declared as Pydantic schemas; strict inputs use `extra="forbid"`. The boundary is a typed artefact ([P7], Component 1).
- **Severity:** Should-fix.
- **Remediation:** Add a `CreateExportRequest` Pydantic model (`extra="forbid"`) for the body and a `CreateExportResponse` model for the result, and declare them on the route. Make `export_format` an `Enum` so the allowed-values check is a type constraint, not a hand-rolled `if`.

### 4. [P28] Trust boundaries — `user_id` supplied by the caller — Backend HTTP Routes / Auth
- **Observed:** `user_id` is accepted as a request parameter. Any signed-in caller can pass any other user's ID and export — or count the quota of — their data.
- **Standard:** Platform identifiers reach handlers/tools through request-scoped auth context, never as caller-supplied arguments; public and internal routes carry the correct auth dependency ([P28], Components 1 + 16). Although the PR says "lets a signed-in user request an export of their data," nothing here ties the export to the *authenticated* identity.
- **Severity:** Blocking — this is a Theme V (Security) violation and an authorization bypass / IDOR.
- **Remediation:** Remove the `user_id` parameter. Resolve the user from the session/auth dependency (the standard auth dependency used elsewhere in `routes/`) and pass that identity into the service. Never trust a client-supplied user ID.

### 5. [P8] Shared vocabulary — `APIRouter` structure — Backend HTTP Routes
- **Observed:** `router = APIRouter()` — no `prefix`, no `tags`. The route path is the literal `"/exports"`.
- **Standard:** Route files use a single `APIRouter(prefix=..., tags=[...])` with consistent structure ([P8], Component 1).
- **Severity:** Minor.
- **Remediation:** `router = APIRouter(prefix="/exports", tags=["exports"])` and register the handler on `""` / `"/"`.

### 6. [P12] Convention over configuration — auto-discovery — Backend HTTP Routes
- **Observed:** Cannot confirm from the file alone, but the filename `export_routes.py` and a module-level `router` match the `routes/*_routes.py` auto-discovery convention. The PR adds no manual registration line, which is correct *if* the discovery mechanism picks up this exact shape.
- **Standard:** Routers are auto-discovered from `routes/*_routes.py`; no manual registration ([P12], Component 1).
- **Severity:** Minor — verify, not necessarily fix.
- **Remediation:** Confirm the discovery loader picks this file up (correct directory, exported symbol name matches what the loader scans for). If it does, no change. If not, conform the file to the loader's expectations rather than adding a manual `include_router` call.

### 7. [P19] Do slow and fallible work asynchronously, with backpressure — Celery & Background Workers
- **Observed:** `write_export_file(...)` runs synchronously inside the request handler ("generate the file right here so we can return a download URL in the response"). File generation is unbounded, fallible work (large datasets, I/O, upload), and it blocks the HTTP request for its full duration.
- **Standard:** Long-running or failure-prone work is pushed onto a queue/worker; the request path stays fast. Exports are the canonical example of deferrable work ([P19], Component 12; the Compass even uses "email a user when their export is ready" as its worked example).
- **Severity:** Should-fix (high priority — it caps throughput and will time out on large exports).
- **Remediation:** The endpoint should create the `Export` row with `status="pending"`, enqueue a Celery task to generate the file, and return `202` with the export `id` and `status: "pending"`. The client polls (or is notified) for completion. The route should not block on `write_export_file`.

### 8. [P15] / [P21] / [P25] Idempotency, bounded retry, cooperative cancellation — Celery & Background Workers
- **Observed:** Because generation is inline, there is no idempotency key, no bounded-retry/terminal-state handling, and no cancellation behaviour. A retried request creates a *second* export row and regenerates the file; a failure mid-`write_export_file` leaves a row stuck at `status="pending"` forever with no terminal state.
- **Standard:** Background work must be idempotent (idempotency keys, `acks_late`), bounded in retries (`max_retries`, `retry_backoff`) ending in an explicit terminal state, and cooperatively cancellable ([P15], [P21], [P25], Component 12).
- **Severity:** Should-fix — becomes required once the work moves to a worker (#7); flagged together because the fix is the same change.
- **Remediation:** In the Celery task: design an idempotency key (e.g. user + day + format, or reuse a still-valid `pending`/`done` export — see #11), set `max_retries` with `retry_backoff` and `autoretry_for`, and define a terminal `status` (e.g. `"failed"`) so a crashed generation does not strand the row at `"pending"`.

### 9. [P20] Choose fail-open vs fail-closed deliberately — error handling — Backend HTTP Routes / Services
- **Observed:** Failures are returned as `{"error": "..."}` dicts with an implicit HTTP `200`. The quota-exceeded and unsupported-format cases — and any unexpected exception — are not surfaced as real error statuses. `write_export_file` is not wrapped; if it throws, the row is left at `status="pending"` and the client gets a `500` with no record cleanup.
- **Standard:** Each failure path makes a deliberate fail-open/fail-closed choice and surfaces it correctly. The unacceptable state is failing in an undecided direction ([P20], Component 2). Errors at the HTTP edge are expressed through proper status codes (e.g. `HTTPException`).
- **Severity:** Should-fix (the silent `200`-with-`error`-body is a correctness and contract problem for every client).
- **Remediation:** Raise `HTTPException` with correct codes — `422`/`400` for unsupported format (or let Pydantic/Enum reject it), `429` for quota exceeded. Wrap generation so a failure transitions the row to a terminal `"failed"` state rather than leaving it `"pending"`.

### 10. [P9] YAGNI / config handling — `os.environ` read in the handler — Backend HTTP Routes / Services
- **Observed:** `int(os.environ["MAX_EXPORTS_PER_DAY"])` is read directly in the request path. A missing or non-integer env var raises `KeyError`/`ValueError` as an unhandled `500` on every request.
- **Standard:** Configuration is wired once through shared settings/dependency aliases (`SettingsDep` and similar), not read ad hoc at call sites ([P9] and the convention-over-configuration practice, Component 2/4).
- **Severity:** Minor.
- **Remediation:** Read `MAX_EXPORTS_PER_DAY` from the central settings object, with validation/typing at load time, and have the service consume it from there.

### 11. [P5] Single source of truth / [P15] Idempotency — quota logic and the export query
- **Observed:** Two concerns here. (a) The quota is computed by loading **every** `Export` row for the user and filtering in Python by `created_at.date()` — this re-derives "today's exports" in the caller and does not scale. (b) Line 40 re-runs `select(Export).where(Export.user_id == user_id)` and passes *Export records* into `write_export_file` as `rows` — the data being exported appears to be the user's list of exports, which is almost certainly not the intended payload and looks like a copy-paste bug.
- **Standard:** Each fact has one authoritative home; canonical selection is centralised, not re-derived in callers ([P5]). Repeated identical queries and Python-side filtering belong in a single `*_db.py` query ([P1], [P5], Component 3).
- **Severity:** (a) should-fix; (b) blocking if it is indeed exporting the wrong data — confirm with the author what `write_export_file` is meant to receive.
- **Remediation:** Put a single `count_exports_today(db, user_id)` (a `SELECT COUNT(*)` with a date filter) in `export_db.py`. Fix line 40 to fetch the *actual* data the user is exporting, not the `Export` table. Consider "create-or-return-existing" semantics so a repeated request within the quota window does not silently create duplicate rows ([P15]).

### 12. [P17] Explicit transaction boundaries — Database Modules
- **Observed:** The handler calls `await db.commit()` twice and obtains the session via a bare `get_session()` rather than the request-scoped session dependency. There is no rollback path if generation fails between the two commits.
- **Standard:** DB modules `flush()` and leave `commit()` to the caller; the request-scoped session commits at dependency teardown; transaction ownership is explicit and sessions are cancellation-safe ([P17], Component 3).
- **Severity:** Should-fix.
- **Remediation:** Use the standard `AsyncSessionDep` request-scoped session. Let `export_db.py` functions `flush()`; let the service/route own the commit boundary (committed once at teardown). Do not hand-roll `get_session()` in the handler.

---

## Conformant

- The file uses `async def` for the handler — consistent with the async backend.
- The filename `export_routes.py` follows the `*_routes.py` naming convention ([P8] naming — though the `APIRouter` construction itself does not, see #5).
- No manual router registration line was added, which is correct *if* auto-discovery picks the file up (see #6).
- A `status` field exists on the `Export` model, giving the lifecycle a place to live — the right shape for the resumable-state remediation in #8, once a terminal `"failed"` state is added.

## Not applicable

- **[P16] Resumable state machine** (Component 2/15) — N/A: a single-step generate-and-store export does not need a multi-state machine; the `pending → done` (`+ failed`) status field from #8 is sufficient. Flagged only so it is not silently skipped.
- **[P11] Adapter isolation** — N/A from this file: no third-party provider is called directly here. If `write_export_file` uploads to an external store (S3 etc.), that belongs behind an adapter, but it is not visible in this file.
- **[P18] Migrations / backward compatibility** — N/A to this file: no migration is included in the diff. Note for the reviewer: the `Export` model with `status` / `download_url` / `created_at` columns presumably needs a migration — confirm one ships in the same PR.
- **[P23] Scale on observed pressure** — N/A: autoscaling signals are not in scope for a single endpoint.

---

## Summary for the PR author

The endpoint is functionally close but should not merge in its current form. Three blocking items:

1. **Authorization bypass ([P28]):** drop the `user_id` parameter; derive the user from the auth session. (Security — fix first.)
2. **Layering ([P1]/[P2]):** route must delegate to an `export_service.py` + `export_db.py`; no ORM access or business logic in the handler.
3. **Confirm the export payload ([P5]):** line 40 currently exports the `Export` table itself — verify what `write_export_file` should actually receive.

Then the should-fix items: move file generation to a Celery task and return `202` ([P19], with [P15]/[P21]/[P25] following), add typed Pydantic request/response schemas ([P7]), use proper HTTP error statuses instead of `200`-with-`error`-body ([P20]), use the request-scoped session and explicit commit ownership ([P17]). Minor: `APIRouter(prefix/tags)` ([P8]) and central settings for the quota ([P9]).
