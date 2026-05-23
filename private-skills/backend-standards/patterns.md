# Backend Patterns — Concrete Templates

Code-verified templates for each axis. Each entry: the **rule**, a **template**,
a real **example** (`file:line`), and the **anti-pattern** the codebase avoids.
All paths are relative to `backend/`.

---

## 1. Directory layout & import direction

**Rule:** `app/` is split into hard layers that import only downward:
`routes/ → services/ → database/ → models/`, with `schemas/`, `utils/`, and
`config` as shared leaves.

| Layer | Path | Owns | Never imports |
| --- | --- | --- | --- |
| Routes | `app/routes/*_routes.py` | HTTP, deps, `HTTPException`, `commit()` | — |
| Services | `app/services/*_service.py` | business logic | `APIRouter`, `HTTPException` |
| Database | `app/database/*_db.py` | SQL, `flush()` | schemas, FastAPI |
| Models | `app/models/*.py` | ORM tables | services |
| Schemas | `app/schemas/*_schema.py` | Pydantic | DB, FastAPI |

Routes are auto-discovered from `app/routes/*_routes.py` — name the file with
the `_routes.py` suffix or it will not register.

**Anti-pattern avoided:** services importing `APIRouter`; `*_db.py` importing
schemas; models importing services.

---

## 2. Routes

**Rule:** One `router = APIRouter(prefix=..., tags=[...])` per file. Every
handler is `async def`, injects deps via type aliases, and annotates its
return type as the Pydantic response schema. Cross-cutting guards go on the
router via `dependencies=[...]`, not repeated per handler.

```python
import logging
from fastapi import APIRouter
from app.schemas import ThreadCreate, ThreadResponse
from app.services import thread_service
from app.utils import AsyncSessionDep
from app.config import SettingsDep

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/threads", tags=["threads"])

@router.post("", status_code=201)
async def create_thread(
    thread_data: ThreadCreate,
    db_session: AsyncSessionDep,
    settings: SettingsDep,
) -> ThreadResponse:
    thread = await thread_service.create_thread(db_session, thread_data.title)
    await db_session.commit()
    return ThreadResponse.model_validate(thread)
```

**Example:** `app/routes/website_routes.py:46-55` (router + typed handler),
`app/routes/draft_routes.py:44-48` (router-level guard via `dependencies=[...]`),
`app/routes/draft_routes.py:160` (route owns `commit()`).

**Anti-pattern avoided:** passing `request: Request` through handlers; raw
`dict` return types; `HTTPException` for 5xx (let those bubble — see
`docs/rules/error-handling.md`).

---

## 3. Services (module functions, not classes)

**Rule:** A service is a module of top-level `async def` functions. There is
**no** `class XService` and **no** `XServiceDep`. Callers import the module and
call its functions. Deterministic, no direct LLM calls (those are LLM Routines
/ Agents — see `docs/rules/module-taxonomy.md`).

```python
# app/services/thread_service.py
import logging
from app.database import thread_db
from app.utils import AsyncSessionDep

logger = logging.getLogger(__name__)

async def create_thread(db_session: AsyncSessionDep, title: str) -> Thread:
    user_id = ...  # business logic here
    return await thread_db.create_thread(db_session, user_id, title)
```

```python
# caller (route or another service)
from app.services import thread_service
thread = await thread_service.create_thread(db_session, title)
```

**Example:** `app/services/draft_service.py` (a module of `async def`
functions, module-level `logger`, no class). Verified: ~69 of 70 files in
`app/services/` use module functions; only `meter_event_service.py` uses a
class.

**Anti-pattern avoided:** `class ThreadService` with `__init__` wiring;
`Depends(ThreadService)`. The class examples in `AGENTS.md` /
`docs/rules/error-handling.md` are illustrative only — do not copy that shape.

---

## 4. Schemas (Pydantic v2)

**Rule:** Suffix by role: `*Base`, `*Create`, `*Update`, `*Response`. Response
schemas that map from ORM rows set `ConfigDict(from_attributes=True)`. Create
schemas set `ConfigDict(extra="forbid")`. Normalize input with
`@field_validator` (sync `@classmethod`).

```python
from pydantic import BaseModel, ConfigDict, field_validator

class ThreadCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str

class ThreadResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    title: str
```

**Example:** `app/schemas/website_schema.py:87-88` (`extra="forbid"`),
`:196-199` (`from_attributes=True`), `:116-165` (`@field_validator`).

**Anti-pattern avoided:** Pydantic-v1 `class Config: orm_mode = True`; mixing
one model for both request and response.

---

## 5. Models (SQLAlchemy)

**Rule:** Extend `Base` from `app.models.base`. Declare columns with
`Mapped[T]` + `mapped_column()` only. UUID primary keys. Timestamps are
`Mapped[datetime]` with `DateTime(timezone=True)` and a server default.

```python
import uuid
from datetime import datetime
from sqlalchemy import DateTime
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column
from app.models.base import Base

class Thread(Base):
    __tablename__ = "threads"
    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default="CURRENT_TIMESTAMP"
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default="CURRENT_TIMESTAMP",
        server_onupdate="CURRENT_TIMESTAMP",
    )
```

**Example:** `app/models/base.py:3` (`Base = declarative_base()`),
`app/models/draft.py:35` (UUID PK), `:59-66` (timestamps).

**Anti-pattern avoided:** the legacy `Column()` API (banned in `AGENTS.md`);
naive (tz-unaware) timestamps.

Migrations: sequential numbered files in `app/migrations/`, idempotent (safe to
re-run). Applied automatically on startup.

---

## 6. Database access layer

**Rule:** One `*_db.py` per entity. Standalone `async def` functions take
`db_session` as the first argument, perform `select`/`insert`/`update`, and
call `await db_session.flush()` — **never `commit()`**. The route (or service)
commits the transaction.

```python
# app/database/thread_db.py
async def create_thread(db_session: AsyncSessionDep, user_id: uuid.UUID, title: str) -> Thread:
    thread = Thread(user_id=user_id, title=title)
    db_session.add(thread)
    await db_session.flush()   # populates PK/defaults; route commits
    return thread
```

**Example:** `app/database/draft_db.py:54,109,211` (all `flush()`),
`app/routes/draft_routes.py:160` (route `commit()`).

**Anti-pattern avoided:** `commit()` inside `*_db.py` (narrow upsert
exceptions aside); repository classes — plain functions only.

---

## 7. Imports & `__init__.py`

**Rule:** Cross-package imports go through the package `__init__.py`
re-exports, with a sorted `__all__`. Import service/database **modules**, not
their inner functions.

```python
from app.schemas import ThreadCreate, ThreadResponse   # good
from app.services import thread_service                 # good (module)
from app.services.thread_service import create_thread   # avoid (deep import)
```

**Example:** `app/schemas/__init__.py:240` (sorted `__all__`),
`app/database/__init__.py` (re-exports `*_db` modules).

**Anti-pattern avoided:** deep imports that bypass `__init__.py`; `__all__`
declared outside `__init__.py` files.

---

## 8. Logging

**Rule:** Module-level `logger = logging.getLogger(__name__)`. Inside an
`except`, use `logger.exception(...)` (captures the stack trace). Use
positional `%s` args or f-strings. Never `print()`.

```python
logger = logging.getLogger(__name__)
try:
    ...
except IntegrityError:
    logger.exception("Failed to create thread")
    raise
```

**Example:** `app/services/metronome_billing_adapter.py:202` (`logger.exception`),
`app/routes/website_routes.py:131` (positional `%s` warning).

**Anti-pattern avoided:** `print()`; `logger.error(f"...{e}")` in an `except`
when `logger.exception(...)` would attach the trace; catch-just-to-log-and-reraise.

---

## 9. Type hints

**Rule:** Annotate every parameter and return type. Use `Annotated[...,
Depends(...)]` for DI and `TypeAlias` for named dependency aliases. `T | None`
is preferred over `Optional[T]` in new code.

```python
AsyncSessionDep: TypeAlias = Annotated[AsyncSession, Depends(_async_db_session, scope="function")]
SettingsDep = Annotated[_Settings, Depends(get_settings)]
```

**Example:** `app/utils/db_session.py:398` (`AsyncSessionDep`),
`app/config.py:769` (`SettingsDep`).

**Anti-pattern avoided:** untyped `def` in route/service layers.

---

## 10. Async

**Rule:** `async def` for route handlers, all DB-access functions, and any I/O.
Pure computation (validators, formatters, config helpers) stays sync `def`.

**Example:** `app/database/draft_db.py:23` (async DB fn); Pydantic
`@field_validator` methods are sync `@classmethod`.

**Anti-pattern avoided:** sync blocking I/O inside `async def`; `asyncio.run()`
inside a handler.

---

## 11. Config / settings

**Rule:** All env vars are declared once on `_Settings(BaseSettings)` in
`app/config.py` with `Field(...)`. Get the singleton via the cached
`get_settings()`. Inside FastAPI, inject `SettingsDep`; outside DI (Celery,
scripts) call `get_settings()`. Never read `os.environ` ad hoc in services.

```python
@functools.cache
def get_settings() -> _Settings: ...
SettingsDep = Annotated[_Settings, Depends(get_settings)]
```

**Example:** `app/config.py:760-769`. Env layering: `.env.common` (committed)
< `.env` (local, gitignored) < OS env.

**Anti-pattern avoided:** `os.environ.get("FOO")` in services; module-level
`settings = _Settings()` outside `config.py`.

---

## 12. Testing

**Rule:** Tests mirror app layout (`tests/test_routes/`, `test_services/`,
`test_database/`, `test_llm/`). All test functions are `async def` with **no**
`@pytest.mark.asyncio` (configured globally). Use `async_db_session` for DB and
`async_client` for HTTP. Namespace every email/name with the `test_id` fixture
(`= request.node.name`) so the shared DB has no cross-test collisions.

```python
async def test_create_draft(async_db_session, test_application, test_id):
    draft = await draft_db.create_draft(
        async_db_session, branch_name=f"draft/{test_id}-applied", ...
    )
    assert draft.id is not None
```

**Example:** `tests/conftest.py:77-79` (`test_id`), `:232-258`
(`async_db_session`), `:261-273` (`async_client` auth override),
`tests/test_database/test_draft_db.py:8-33` (namespacing).
See `agent-context/AGENTS-testing.md` for the shared-DB rationale.

**Anti-pattern avoided:** shared mutable state; hardcoded emails/names;
`@pytest.mark.asyncio` decorators.

---

## 13. Error handling, YAGNI, style (summary — full rules in docs)

- **Errors:** minimize `try` scope; catch specific types; raise stdlib
  exceptions; log at the top of the stack with `logger.exception()`; don't
  catch-just-to-log. `HTTPException` only in routes, only for 4xx. Full
  per-layer guide and orchestrator `ToolResult`/`ToolError` contracts:
  `docs/rules/error-handling.md`.
- **YAGNI / minimalism:** hard-code constants, remove unused params, avoid
  premature abstraction. Add flexibility only with 2+ real use cases or
  per-environment values (`AGENTS.md` → Design Principles).
- **Style:** double-quoted strings; `model_config = ConfigDict(...)` over
  `class Config`; `app.utils.yaml` instead of PyYAML
  (`docs/rules/yaml-utilities.md`).

---

## Canonical reference files

| Axis | File |
| --- | --- |
| Routes | `app/routes/website_routes.py`, `app/routes/draft_routes.py` |
| Services (functions) | `app/services/draft_service.py` |
| DB layer | `app/database/draft_db.py` |
| `AsyncSessionDep` | `app/utils/db_session.py:398` |
| `SettingsDep` / settings | `app/config.py:760-769` |
| Models | `app/models/base.py`, `app/models/draft.py` |
| Schemas | `app/schemas/website_schema.py`, `app/schemas/draft_schema.py` |
| Package exports | `app/schemas/__init__.py`, `app/models/__init__.py` |
| Test fixtures | `tests/conftest.py` |
