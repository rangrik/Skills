---
name: backend-standards
description: >
  Use this skill before writing, extending, or reviewing Python code in the
  platform backend — adding or changing an API route, a service, a Pydantic
  schema, a SQLAlchemy model, a database-access function, a migration, or a
  test. Fires on intents like "add an endpoint for X", "write a service that
  does Y", "create a model/table for Z", "wire up a new schema", "is this
  backend code idiomatic / up to our conventions", or "review this backend
  diff" — even when the user does not name the layer. It encodes the real,
  code-verified conventions of the platform backend (layering, dependency
  injection, schemas, models, db access, logging, async, config, testing,
  error handling) and points to the authoritative rule docs for deep topics.
  Skip it for the TypeScript app-template backend, for the React frontend, and
  for authoring agent prompts or skills (use the prompt guide and
  skill-authoring skill respectively).
---

# Backend Standards

Restate: the source of truth for *how to write Python backend code* in
`backend/app/` so a change matches the existing codebase rather than a
plausible-looking invention. The concrete templates live in
[patterns.md](patterns.md); the deep topics live in `backend/docs/rules/`.
This file is the decision surface and the checklist.

## When to use

Load this before touching any file under `backend/app/` or `backend/tests/`:
adding an endpoint, a service function, a schema, a model, a `*_db.py`
function, a migration, or a test. Also load it when reviewing a backend diff
for convention adherence.

Do **not** use it for: the TypeScript app-template (`app-template/`), the
frontend, writing agent prompts (`backend/app/llm/agent-prompt-guide.md`), or
authoring skills (`skill-authoring`).

## The one rule that governs everything: layered, downward-only imports

```
routes/  →  services/  →  database/  →  models/
              ↑ schemas/ (Pydantic, imported by routes & services)
              ↑ utils/, config (shared leaves)
```

- **routes/** — HTTP boundary only. Injects deps, calls services, maps to a
  response schema, owns `HTTPException` and the transaction `commit()`.
- **services/** — deterministic business logic. **Module-level `async def`
  functions, not classes.** Never imports `APIRouter`/`HTTPException`.
- **database/** (`*_db.py`) — SQL only. Functions take `db_session` first,
  use `flush()` (the route/service commits). No business logic, no schemas.
- **models/** — SQLAlchemy ORM only. No business logic.
- **schemas/** — Pydantic only. No DB or FastAPI references.

A layer may only import downward. Services importing FastAPI types, or
`*_db.py` calling `commit()`, is a smell. See [patterns.md](patterns.md) for
the per-layer templates and `file:line` examples.

> **Doc discrepancy to know:** `backend/AGENTS.md` and
> `docs/rules/error-handling.md` show a class-based `ThreadService` /
> `self.thread_db` style. That shape is illustrative only — the real codebase
> uses **module-level functions** (~69 of 70 service files). Follow the code,
> not those snippets.

## Per-axis rules (one line each — full templates in patterns.md)

1. **Routes** — one `APIRouter(prefix=..., tags=[...])`, all handlers `async def`, inject `AsyncSessionDep` / `SettingsDep`, annotate the response schema as the return type.
2. **Services** — module of `async def` functions; routes do `from app.services import x_service` then `await x_service.fn(...)`.
3. **Schemas** — `model_config = ConfigDict(from_attributes=True)` on responses, `ConfigDict(extra="forbid")` on `*Create`; suffix `*Create` / `*Update` / `*Response` / `*Base`; never Pydantic-v1 `class Config`.
4. **Models** — `Mapped[T]` + `mapped_column()` only (never legacy `Column()`); UUID PKs; tz-aware `created_at`/`updated_at`; extend `Base`.
5. **DB layer** — `*_db.py` standalone `async def`, `db_session` first arg, `flush()` not `commit()`.
6. **Imports** — cross-package imports go through `__init__.py`; keep `__all__` sorted; import service modules, not their inner functions.
7. **Logging** — `logger = logging.getLogger(__name__)`; `logger.exception()` inside `except`; never `print()`.
8. **Type hints** — annotate every param and return; `Annotated` for DI; `TypeAlias` for Dep aliases.
9. **Async** — `async def` for handlers, DB access, and I/O; sync `def` is fine for validators and pure computation.
10. **Config** — inject `SettingsDep` inside handlers; call `get_settings()` only outside DI (Celery, scripts); never scatter `os.environ`.
11. **Testing** — mirror app layout under `tests/`; use `async_db_session` / `async_client`; namespace every name/email with the `test_id` fixture; no `@pytest.mark.asyncio`.
12. **Minimalism (YAGNI)** — hard-code constants, drop unused params, double-quoted strings. Add flexibility only with 2+ real use cases.

## Pre-write / pre-review checklist

- [ ] Change lives in the right layer; imports only go downward.
- [ ] New service logic is a module-level `async def`, not a class.
- [ ] Route handler is `async`, injects deps, returns a typed response schema; `commit()` is here (or in the service), not in `*_db.py`.
- [ ] `*_db.py` functions take `db_session` first and `flush()`.
- [ ] Response schemas set `ConfigDict(from_attributes=True)`; create schemas set `extra="forbid"`.
- [ ] Models use `Mapped[]`/`mapped_column()`, UUID PK, tz-aware timestamps.
- [ ] New public symbols are exported via the package `__init__.py` and added to a sorted `__all__`.
- [ ] Module has `logger = logging.getLogger(__name__)`; exceptions logged with `logger.exception()`; no `print()`.
- [ ] Settings read via `SettingsDep` (handlers) or `get_settings()` (outside DI) — not raw `os.environ`.
- [ ] Tests namespace resources with `test_id`; no hardcoded emails/names.
- [ ] `task fmt && task test` pass before committing.

## Deep topics → authoritative docs (do not duplicate here)

| Topic | Read |
| --- | --- |
| Error handling per layer, anti-patterns, tool error contracts | `backend/docs/rules/error-handling.md` |
| Service / LLM Routine / Agent / Tool / Skill classification | `backend/docs/rules/module-taxonomy.md` |
| Adding orchestrator tools (verb_object, notifications, return types) | `backend/docs/rules/orchestrator-tools.md` |
| Celery background tasks (decorator, serialization, dispatch) | `backend/docs/rules/celery-tasks.md` |
| Feature flags (three-layer, fail-open, adding flags) | `backend/docs/rules/feature-flags.md` |
| YAML (`app.utils.yaml`, never PyYAML directly) | `backend/docs/rules/yaml-utilities.md` |
| Agent security | `backend/docs/rules/agent-security.md` |
| Writing/reviewing agent prompts | `backend/app/llm/agent-prompt-guide.md` |
| Runtime skills (`app/llm/skills/`) and dev-time skills | `backend/docs/rules/skills-authoring.md`, `skill-authoring` skill |
