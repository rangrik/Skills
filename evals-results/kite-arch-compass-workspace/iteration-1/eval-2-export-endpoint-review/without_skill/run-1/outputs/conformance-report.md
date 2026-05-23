# PR Review: `backend/app/routes/export_routes.py`

Thanks for sending this over. The endpoint works for the happy path, but there are several issues I'd want addressed before this merges. I've grouped them by severity.

---

## Blocking issues

### 1. Authentication / authorization is missing — `user_id` is caller-controlled

The PR description says this should let "a signed-in user request an export of **their** data," but the endpoint takes `user_id` as a plain request parameter:

```python
async def create_export(user_id: str, export_format: str):
```

This means **any caller can export any user's data** by passing a different `user_id`. This is an IDOR (Insecure Direct Object Reference) vulnerability.

The `user_id` should come from the authenticated session/token, not from the request body or query string. Most FastAPI codebases do this with a dependency, e.g.:

```python
async def create_export(
    export_format: str,
    current_user: User = Depends(get_current_user),
):
    user_id = current_user.id
```

Whatever auth dependency the rest of the repo uses (`get_current_user`, `require_auth`, etc.) should be applied here. Please confirm this endpoint is reachable only by authenticated users and that it only ever operates on the caller's own data.

### 2. Database session is not managed correctly

```python
db = get_session()
```

The session is grabbed directly inside the function, never closed, and there's no rollback on failure. If `get_session()` is the raw session factory, this leaks a connection on every request and won't roll back a half-finished transaction when an exception is thrown between the two `commit()` calls.

In a FastAPI app the session should almost always be injected as a dependency so its lifecycle (open → use → commit/rollback → close) is handled for you:

```python
async def create_export(
    export_format: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_session),
):
```

Check how other route files in `backend/app/routes/` obtain their session and match that pattern exactly. Mixing a manual `get_session()` here with a dependency-injected session elsewhere is the kind of inconsistency that causes subtle connection-pool bugs.

### 3. The export is generated synchronously inside the request

```python
# generate the file right here so we can return a download URL in the response
rows = await db.execute(select(Export).where(Export.user_id == user_id))
url = write_export_file(export.id, rows.scalars().all())
```

Two problems:

- **`write_export_file` is a blocking call inside an async handler.** Unless it's actually async, calling it directly will block the event loop and stall every other request on that worker. If it must run inline, it should be wrapped (`await run_in_threadpool(...)` / `asyncio.to_thread(...)`). But really —
- **File generation doesn't belong in the request path.** Exports can be large and slow. The record is even created with `status="pending"`, which strongly implies the intended design is async processing (a background task / job queue) that flips the status to `done` later. The code then immediately overrides it to `done` in the same request, defeating the point of the status field. I'd expect this to enqueue a job and return `202 Accepted` with `status="pending"`, and a separate `GET /exports/{id}` endpoint for the client to poll. Please align this with however the repo handles other long-running work (Celery, RQ, FastAPI `BackgroundTasks`, etc.).

### 4. Wrong query when fetching rows to export

```python
rows = await db.execute(select(Export).where(Export.user_id == user_id))
url = write_export_file(export.id, rows.scalars().all())
```

This selects from the **`Export`** table — i.e. it's exporting the list of export records, not the user's actual data. This looks like a copy/paste of the quota query above. It should select whatever domain data the export is supposed to contain. As written, the feature doesn't do what it claims.

---

## Should fix before merge

### 5. Error handling doesn't use HTTP status codes

```python
if export_format not in ("csv", "xlsx", "json"):
    return {"error": "unsupported format"}
...
if len(todays) >= quota:
    return {"error": "daily quota exceeded"}
```

Both of these return **HTTP 200** with an error body. Clients (and any monitoring/alerting) can't distinguish success from failure. These should raise proper errors:

```python
raise HTTPException(status_code=400, detail="unsupported format")
raise HTTPException(status_code=429, detail="daily quota exceeded")
```

(Quota exceeded is specifically a `429 Too Many Requests`.) If the repo has a shared error/response convention — a custom exception class, an error envelope, an exception handler — use that instead so this endpoint is consistent with the others.

### 6. Quota enforcement has a race condition and is inefficient

```python
result = await db.execute(select(Export).where(Export.user_id == user_id))
todays = [e for e in result.scalars().all() if e.created_at.date() == _today()]
```

- **Race condition:** two concurrent requests both read a count below quota, both proceed, and the user exceeds the limit. If the quota matters, enforce it with a DB-level constraint or a `SELECT ... FOR UPDATE` / atomic insert-with-count.
- **Inefficiency:** it loads *every* export row the user has ever created into memory just to filter today's in Python. Push the date filter into the query and use `count()`:

  ```python
  from sqlalchemy import func
  today_count = await db.scalar(
      select(func.count()).select_from(Export)
      .where(Export.user_id == user_id, Export.created_at >= start_of_today)
  )
  ```

### 7. `_today()` is undefined in this file

Line 29 calls `_today()`, but it's never imported or defined here. Either this is a missing import (where does it live?) or the file won't run. Please make sure it's imported, and prefer comparing against a timezone-aware day boundary rather than a naive `.date()` so the quota window is correct across timezones.

### 8. `os.environ["MAX_EXPORTS_PER_DAY"]` will crash on a missing/invalid value

```python
quota = int(os.environ["MAX_EXPORTS_PER_DAY"])
```

- A missing env var raises `KeyError`; a non-numeric value raises `ValueError` — both unhandled, both surface as a 500.
- Reading config from `os.environ` directly inside a route handler is usually inconsistent with how the rest of the repo manages configuration. Most projects centralize this in a settings module (`app.config` / a Pydantic `Settings` object) with a typed default. Read the quota from there instead.

---

## Minor / consistency

- **No response model.** Other endpoints in this repo likely declare a Pydantic `response_model` and request schema. This one uses bare `dict`s and loose `str` parameters. Add request/response models for validation, OpenAPI docs, and consistency. `export_format` in particular is a great candidate for an `Enum`.
- **No router prefix/tags.** `APIRouter()` is created with no `prefix` or `tags`. Check how sibling routers are constructed — they probably set `APIRouter(prefix="/...", tags=[...])` so the OpenAPI docs stay organized.
- **No explicit status code on the route.** Once this becomes async, decorate with `status_code=status.HTTP_202_ACCEPTED` (or `201` if it stays synchronous and creates a resource).
- **No logging.** A create + file-generation endpoint should log key events (export requested, completed, failed) consistent with the repo's logging setup.
- **No tests included.** A new endpoint should ship with tests — at minimum: happy path, unsupported format, quota exceeded, and the auth check (a user cannot export another user's data).
- **Two `commit()` calls** with non-atomic work in between. If `write_export_file` fails, you're left with a stranded `status="pending"` row and no cleanup/rollback path.

---

## Summary

The core idea is fine, but I can't approve it as-is. The **blocking** items are: the missing auth (anyone can export anyone's data), the unmanaged DB session, the synchronous/blocking file generation that contradicts the `pending` status design, and the query that exports the wrong table. The error-handling and quota items should also be fixed for this to be consistent with how endpoints are built elsewhere in the repo.

One overarching note: several of my suggestions (session handling, config access, error envelope, router prefix, response models) depend on the **existing conventions in `backend/app/routes/`**. Please diff this file against a couple of established route modules and make it match — consistency with the existing codebase matters as much as any individual fix here.
