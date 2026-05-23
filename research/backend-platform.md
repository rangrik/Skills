# Appsmith v2 / Kite platform backend architecture research

Research-only summary of the Python/FastAPI backend under `backend/`. Evidence anchors use `path:line` where available, or nearby symbol names for long modules.

## Executive summary

- The platform backend is a FastAPI application plus a separate Celery worker. `backend/main.py:17` runs Uvicorn with `app="app:make_app"`; `backend/worker_main.py:1` is the worker entrypoint and consumes workflow + generation queues with a thread pool at `worker_main.py:118`.
- Runtime layers follow the documented shape: routes -> services -> database modules -> SQLAlchemy models + Pydantic schemas. The platform context map states this directly at `agent-context/context-maps/platform-backend.md:16`, and `backend/AGENTS.md:53` through `backend/AGENTS.md:91` define DB, ORM, route, and auto-discovery conventions.
- Startup (`backend/app/__init__.py`) owns most process-wide singletons: DB migration/schema verification, workflow LISTEN/NOTIFY, channel dispatchers, analytics/PostHog, Redis circuit breaker state, zombie-task sweep, queue-drain sweep, OTel, middleware, and route registration (`lifespan` at `backend/app/__init__.py:31`, `register_routes` at `backend/app/__init__.py:110`, `make_app` at `backend/app/__init__.py:151`).
- PostgreSQL is central: SQL migrations are applied automatically on startup (`backend/app/utils/db_session.py:447`), schemas are verified against model columns (`backend/app/utils/db_session.py:505`), request sessions are function-scoped and cancellation-safe (`backend/app/utils/db_session.py:328`, `backend/app/utils/db_session.py:398`).
- Auth is WorkOS AuthKit session-cookie based, enforced by a global FastAPI dependency (`backend/app/services/authentication_checker.py:55`) with explicit excluded public/internal routes (`backend/app/services/authentication_checker.py:12`). Some excluded internal routes implement their own bearer/TOTP auth (`backend/app/utils/internal_auth.py:14`), while at least one debug route is unauthenticated and leaks token metadata (`backend/app/routes/internal_routes.py:91`).
- Long-running generation/edit work runs through Celery and E2B sandboxes. The custom Celery wrapper validates keyword args with generated Pydantic models, propagates OTel context and app/thread metadata, stores result metadata in Postgres, and retries when worker build timestamps lag sender timestamps (`backend/app/services/celery_host_service.py:100`, `backend/app/services/celery_host_service.py:187`, `backend/app/services/celery_host_service.py:380`).
- Real-time UX uses `workflow_events` rows plus Postgres `LISTEN/NOTIFY` and SSE (`backend/app/services/workflow_notification_service.py:1`, `backend/app/routes/chat_routes.py:63`, `backend/app/services/workflow_event_service.py:29`).
- Billing separates Stripe subscription/payment flows from Metronome usage/credits behind a billing adapter (`backend/app/services/billing_adapter.py:103`, `backend/app/services/billing_service.py:25`, `backend/app/services/meter_event_service.py:183`). LLM telemetry and billing converge on inline backend instrumentation plus sandbox proxy POSTs to `/internal/proxy-telemetry` (`backend/app/routes/meter_event_routes.py:63`).
- Deployment and domains are Vercel-centered: `deployment_service.create_deployment()` orchestrates URL selection, canonical rewrites, Pirsch, Vercel deploy, analytics, video capture, and GSC submission (`backend/app/services/deployment_service.py:457`), while `vercel_deploy_service.py` handles project/URL/env/CLI operations (`backend/app/services/vercel_deploy_service.py:659`, `backend/app/services/vercel_deploy_service.py:1924`, `backend/app/services/vercel_deploy_service.py:2043`).

## Canonical docs and repo rules

### Backend AGENTS/README

- `backend/CLAUDE.md:1` delegates to `backend/AGENTS.md`.
- `backend/AGENTS.md:53` requires sequential, idempotent SQL migrations and standardized timestamp triggers; `backend/AGENTS.md:62` requires `Mapped[]` + `mapped_column()` rather than legacy `Column()`.
- `backend/AGENTS.md:69` shows the route pattern; `backend/AGENTS.md:86` says routes are auto-discovered from `routes/*_routes.py`.
- `backend/AGENTS.md:92` says to prefer package-level imports via `__init__.py` and avoid direct module imports.
- `backend/AGENTS.md:102` bans direct PyYAML and points to `app.utils.yaml`; `backend/pyproject.toml:97` enforces banned module-level `yaml` imports.
- `backend/AGENTS.md:111` documents hierarchical env loading: `.env.common`, `.env`, then OS env.
- `backend/AGENTS.md:120` says feature flags should go through `feature_flag_service` and not direct `posthog_service`.
- `backend/AGENTS.md:130` through `backend/AGENTS.md:158` codify YAGNI/minimalism.
- `backend/AGENTS.md:165` through `backend/AGENTS.md:174` document pytest, shared DB, and `test_id` namespacing; `agent-context/AGENTS-testing.md:1` repeats that backend tests share one DB/schema.
- `backend/AGENTS.md:191` through `backend/AGENTS.md:229` define the module taxonomy and orchestrator tool rules.
- `backend/README.md:1` describes the backend as FastAPI for CRUD plus Celery long-running tasks. Its project tree at `backend/README.md:31` is useful historically but now stale in several file names (see tensions below).

### Docs/rules most relevant to backend architecture

- `backend/docs/rules/error-handling.md:1` says to minimize try scopes, catch specific exceptions, avoid log-and-reraise, avoid HTTPException in services, and let generic 5xx bubble from routes.
- `backend/docs/rules/celery-tasks.md:1` says Celery tasks use `@celery_host_service.task`, must be async, accept keyword-only Pydantic-compatible types, and are dispatched through the wrapper (`.call()` in current code, despite the doc snippet showing direct call).
- `backend/docs/rules/feature-flags.md:1` defines the three-layer flag architecture: constants, `feature_flag_service`, `posthog_service` provider. It also documents fail-open defaults at `backend/docs/rules/feature-flags.md:15`.
- `backend/docs/rules/agent-security.md:1` defines agent scope, blocked proxy/credential/server/provider-SDK requests, blocked disclosure categories, and programmatic enforcement points.
- `backend/docs/rules/module-taxonomy.md:1` classifies Service / LLM Routine / Agent / Tool / Skill and keeps deterministic business logic in `app/services/`.
- `backend/docs/rules/orchestrator-tools.md` and `backend/docs/rules/yaml-utilities.md:1` provide tool result contracts and the YAML utility API.

## Application structure and bootstrapping

### Top-level backend shape

Observed structure under `backend/app/`:

- `routes/`: 37 `*_routes.py` modules currently auto-discovered, including auth, chat, domains, payments, metrics, internal, Slack, WhatsApp, website, website database/data/file/code, and Vercel webhook routes.
- `services/`: deterministic business logic plus infrastructure adapters (billing, deployment, E2B, Celery, WorkOS, telemetry, queueing, website/thread services, etc.).
- `database/`: function modules around SQLAlchemy queries and writes; examples: `website_db.py`, `thread_db.py`, `celery_task_db.py`, `website_database_db.py`.
- `models/`: SQLAlchemy ORM models exported from `backend/app/models/__init__.py:1`; representative models include `Application`, `Thread`, `Message`, `User`, `Subscription`, `Domain`, `CeleryTask`, `WorkflowEvent`, `AppDatabase`.
- `schemas/`: Pydantic API/event schemas. Several request models use `ConfigDict(extra="forbid")`, e.g. `backend/app/schemas/website_schema.py:84` and `backend/app/schemas/website_database_schema.py:10`.
- `migrations/`: sequential SQL migrations tracked in `migration_log` (`backend/app/migrations/001-migration-log.sql:1`).
- `llm/`: orchestrator/coding/infra layers, prompts, tools, and agent security boundaries.
- `utils/`: DB/session handling, middleware, logging, OTel, request context, internal auth, login utilities.

### Startup and route registration

- `backend/app/__init__.py:31` `lifespan()` initializes:
  - Startup cleanup/hang inspection (`startup_utils.setup()`).
  - DB migrations + schema sync via `init_db(settings)` at `backend/app/__init__.py:37`.
  - FFmpeg availability warning via `video_recording_service.check_ffmpeg_at_startup()` at `backend/app/__init__.py:41`.
  - Workflow notification singleton at `backend/app/__init__.py:44`.
  - Permanent channel dispatcher for WhatsApp/Slack at `backend/app/__init__.py:49`.
  - Segment analytics and PostHog feature flags at `backend/app/__init__.py:53` and `backend/app/__init__.py:56`.
  - Redis-backed circuit breakers at `backend/app/__init__.py:60`.
  - Zombie Celery sweep and queue drain sweep at `backend/app/__init__.py:63` and `backend/app/__init__.py:66`.
  - Symmetric shutdown for queue drain, zombie sweeper, PostHog, analytics flush, notification service, GSC/video tasks, GSC HTTP client, and Redis at `backend/app/__init__.py:70` through `backend/app/__init__.py:104`.
- `backend/app/__init__.py:110` `register_routes()` imports every sorted `app/routes/*_routes.py`, skips `_NON_API_ROUTES = {"preview_routes"}`, includes the router under `/api/v1`, mounts `/templates/assets`, separately includes preview, `/info`, and SPA fallback.
- `backend/app/__init__.py:151` `make_app()` disables docs/openapi outside debug mode (`backend/app/__init__.py:159`), adds global dependencies (`authentication_checker`, `enrich_span_context`) at `backend/app/__init__.py:166`, initializes OTel before middleware/routes (`backend/app/__init__.py:173`), then adds request-id and session middleware (`backend/app/__init__.py:176`, `backend/app/__init__.py:179`).
- `backend/main.py:17` uses a factory app and `get_logging_config()`. `backend/main.py:10` also ensures the GeoIP DB before serving.

### Configuration and dependency stack

- Settings are Pydantic settings with a cached getter: `_Settings` at `backend/app/config.py:58`, `get_settings()` at `backend/app/config.py:760`, `SettingsDep` at `backend/app/config.py:769`.
- Runtime requirements include Python >=3.13 (`backend/pyproject.toml:6`), FastAPI (`backend/pyproject.toml:20`), SQLAlchemy (`backend/pyproject.toml:55`), Celery/Redis (`backend/pyproject.toml:16`), OpenTelemetry packages (`backend/pyproject.toml:33`-`40`), PostHog (`backend/pyproject.toml:43`), Stripe (`backend/pyproject.toml:57`), and WorkOS (`backend/pyproject.toml:59`).
- Lint/test tasks include Ruff (`backend/Taskfile.dist.yml:26`), basedpyright (`backend/Taskfile.dist.yml:37`), a CI-style restriction that `@celery_host_service.task` only appears in `app/services` or `app/llm` (`backend/Taskfile.dist.yml:39`), prompt linting (`backend/Taskfile.dist.yml:49`), and pytest (`backend/Taskfile.dist.yml:100`).

## Routing, auth, and request lifecycle

### Route layer patterns

- `backend/app/routes/website_routes.py:32` declares `router = APIRouter(prefix="/applications", tags=["websites"])`, illustrating the route-module pattern.
- `backend/app/routes/website_routes.py:37` `POST /applications/with-thread` delegates to `website_service.create_website_with_thread()`; route-level code catches only `ValueError` as 400 (`backend/app/routes/website_routes.py:57`).
- `backend/app/routes/website_routes.py:183` marks `POST /{application_id}/deployments` as create-or-update and delegates to `deployment_service.create_deployment()` after a read gate.
- `backend/app/routes/chat_routes.py:63` streams SSE, `backend/app/routes/chat_routes.py:388` sends chat messages, and `backend/app/routes/chat_routes.py:308` centralizes send authorization for main-vs-draft thread writes.
- Public and internal routes are mixed into auto-discovery but auth behavior is controlled by the global dependency exclusion list plus route-specific auth.

### WorkOS session auth

- `agent-context/architecture/authentication.md:1` documents WorkOS AuthKit OAuth code flow and sealed session cookies.
- `backend/app/services/authentication_checker.py:12` lists exact excluded paths. It skips auth for WorkOS auth routes, health/pricing/email, webhooks, metrics, selected internal endpoints, preview, and fork preview/info.
- Prefix exclusions are at `backend/app/services/authentication_checker.py:64` through `backend/app/services/authentication_checker.py:85`.
- Non-excluded requests try WhatsApp auto-login session first (`backend/app/services/authentication_checker.py:88`), then `session_manager.authenticate()` (`backend/app/services/authentication_checker.py:117`). Unauthenticated API requests get 401; unauthenticated non-API requests redirect to WorkOS login (`backend/app/services/authentication_checker.py:121`).
- `backend/app/services/workos_service/session_manager.py:14` stores current user and org in `ContextVar`s. `authenticate()` sets context on successful session auth at `session_manager.py:22`; `login()` sets it after OAuth callback at `session_manager.py:36`.
- `backend/app/services/workos_service/auth.py:35` exchanges WorkOS code with `authenticate_with_code()` and stores `response.sealed_session` in `request.session` at `auth.py:41`. Existing session auth loads sealed sessions at `auth.py:75`, calls sync WorkOS auth in a thread at `auth.py:95`, refreshes if needed at `auth.py:98`, and returns anonymous users at `auth.py:150` when unauthenticated.
- `backend/app/routes/auth_workos_routes.py:187` is the OAuth callback. It sanitizes `next_url` to same-origin relative path at `auth_workos_routes.py:202`, retries login on expired codes at `auth_workos_routes.py:209`, detects signups via `_is_signup()` at `auth_workos_routes.py:126`, runs onboarding at `auth_workos_routes.py:232`, and handles WhatsApp upgrade/merge at `auth_workos_routes.py:279`.
- Test coverage includes malformed/expired WorkOS code flows, open redirect hardening, WhatsApp upgrade redirects, and error query preservation in `backend/tests/test_routes/test_auth_workos_callback.py:83` onward.

### Internal auth and webhooks

- Internal bearer/TOTP validation lives in `backend/app/utils/internal_auth.py:14`; bearer comparisons use `secrets.compare_digest` (`internal_auth.py:40`) and may also validate a WorkOS JWT (`internal_auth.py:46`).
- WorkOS JWT internal auth uses cached JWKS, certifi SSL, RS256 verification, optional audience fallback for CLI tokens, and email-domain allow-listing (`backend/app/utils/workos_jwt.py:18`, `backend/app/utils/workos_jwt.py:51`, `backend/app/utils/workos_jwt.py:119`).
- Vercel webhooks verify HMAC-SHA1 signatures with `hmac.compare_digest` (`backend/app/routes/vercel_webhook_routes.py:35`, `vercel_webhook_routes.py:91`).
- WhatsApp webhook POST requires `WHATSAPP_APP_SECRET` and verifies `X-Hub-Signature-256` (`backend/app/routes/whatsapp_routes.py:44`, `whatsapp_routes.py:59`).
- Stripe webhook receives raw body and `Stripe-Signature`, delegates parsing/verification to `stripe_service.parse_webhook_event()` (`backend/app/routes/payment_routes.py:311`, `payment_routes.py:337`). Signature verification can be disabled by settings, per the route docstring at `payment_routes.py:319`.
- `backend/app/routes/shared_tool_routes.py:1` exposes internal shared-tool endpoints for sandbox callers; each handler validates `Authorization` with `validate_internal_api_token()` before delegating (`shared_tool_routes.py:36`, `shared_tool_routes.py:60`, `shared_tool_routes.py:88`, `shared_tool_routes.py:121`).

## Database, models, schemas, and migrations

### Session and transaction patterns

- `CancellationSafeAsyncSession` shields rollback/close/invalidate during cancellation (`backend/app/utils/db_session.py:33`).
- `get_async_engine()` converts `postgresql://` to `postgresql+asyncpg://`, strips pool params, sets pool pre-ping/recycle defaults for Neon-like idle behavior, and configures `idle_in_transaction_session_timeout = '1h'` (`backend/app/utils/db_session.py:264`).
- `async_db_session()` commits on clean exit and catches `BaseException` (not just `Exception`) so `asyncio.CancelledError` triggers rollback/cleanup (`backend/app/utils/db_session.py:328`). This is explicitly tied to Celery timeout cancellation in its docstring.
- `AsyncSessionDep` is function-scoped so cleanup/commit happens before responses are sent (`backend/app/utils/db_session.py:398`). This matters for FastAPI 0.128+ where default request-scoped dependency cleanup would occur after response.
- Manual sessions for background tasks/Celery use `get_async_session()` at `backend/app/utils/db_session.py:401`.
- Query timing and dirty-connection warnings are global SQLAlchemy listeners: dirty transaction check-in warning at `backend/app/utils/db_session.py:226`; slow-query warning threshold 200ms at `backend/app/utils/db_session.py:548`.
- Tests pin cancellation cleanup behavior in `backend/tests/test_utils/test_db_session.py:274` and `backend/tests/test_utils/test_db_session.py:292`.

### Migrations and schema verification

- Migrations live in `app/migrations/`, sorted by filename (`backend/app/utils/db_session.py:419`). `init_db()` calls `apply_migrations()` then `verify_schema_is_in_sync()` (`backend/app/utils/db_session.py:433`).
- `apply_migrations()` runs the full SQL file through the raw asyncpg driver connection and logs completion to `migration_log` in the same transaction (`backend/app/utils/db_session.py:447` through `db_session.py:483`).
- `verify_schema_is_in_sync()` checks model tables and columns against the DB and raises on missing/extra columns (`backend/app/utils/db_session.py:505` through `db_session.py:541`).
- Representative migrations:
  - `backend/app/migrations/001-migration-log.sql:1` creates `migration_log`.
  - `backend/app/migrations/002-create-thread-message-tables.sql` creates threads/messages foundation.
  - `backend/app/migrations/006-create-application-table.sql` creates applications.
  - `backend/app/migrations/071-create-celery-tasks-table.sql:1` creates Celery result tables and indexes.
  - `backend/app/migrations/071-add-composite-indexes-for-query-optimization.sql:1` adds a thread/application composite index.
  - `backend/app/migrations/072-notify-workflow-events-with-thread-id.sql:1` creates `pg_notify('workflow_events', NEW.thread_id::text)` trigger behavior.
  - `backend/app/migrations/076-convert-all-timestamps-to-timestamptz.sql:1` converts timestamp columns to `TIMESTAMPTZ`.
  - `backend/app/migrations/090-dedupe-app-databases-and-enforce-unique-application-id.sql:1` dedupes `app_databases` and creates a unique index on `application_id`.
  - `backend/app/migrations/109-create-message-queue-tables.sql:1` creates server-side message queue tables and queue-state table with partial unique position index.
  - `backend/app/migrations/111-celery-tasks-add-thread-id.sql:1` adds `thread_id` metadata to Celery tasks and documents cutover double-dispatch risk.
  - `backend/app/migrations/113-add-main-thread-id-to-applications.sql` makes canonical main thread explicit.
  - `backend/app/migrations/114-add-sender-to-messages.sql` adds message sender metadata.

### Models

- Model exports are centralized in `backend/app/models/__init__.py:1` and `__all__` at `models/__init__.py:38`.
- `Application` (`backend/app/models/application.py:13`) uses UUID PK, owner/creator/deployment/state/framework/canonical fields, `DateTime(timezone=True)` timestamps, soft delete via `deleted_at`, and runtime-only fields in `__init__()` (`application.py:162`). `is_app_generated` is explicitly deprecated but still a source of truth (`application.py:44`).
- `Thread` (`backend/app/models/thread.py:12`) links to `applications.id`, has status/source/sandbox/context-window fields, timezone timestamps, and relationships to application/messages/workflow events (`thread.py:39`).
- `Message` (`backend/app/models/message.py:13`) uses JSONB `additional_kwargs`, enum role/status, timezone timestamps, sender fields, and relationship back to thread (`message.py:39`).
- `AppDatabase` (`backend/app/models/app_database.py:10`) now has a unique `application_id` FK to `applications.id` and optional `server_key`, auth provider project, and connection URL.
- `CeleryTask` (`backend/app/models/celery_task.py:18`) maps Celery DB result backend rows and app/thread metadata (`celery_task.py:45`, `celery_task.py:48`).
- `WorkflowEvent`, `Domain`, `Subscription`, `User`, `Draft`, `Iteration`, `Slack*`, `WhatsAppUser`, SEO snapshot models, and others are also exported.

### Database modules

- DB modules are function-based, generally flush but leave commit to caller. Example: `website_db.create_website()` adds + flushes (`backend/app/database/website_db.py:71`) and `website_database_db.create_website_database()` adds + flushes (`backend/app/database/website_database_db.py:18`).
- `website_db.get_website()` has a safe default owner-only gate and explicit collaborator-widened read mode (`backend/app/database/website_db.py:102` through `website_db.py:171`). It also hydrates a runtime `website.thread_id` with latest non-external thread (`website_db.py:126`, `website_db.py:182`).
- `website_db.get_billing_owner()` centralizes app-owner resolution for billing/credit gates (`backend/app/database/website_db.py:45`).
- `website_database_db.get_website_database_by_website_id()` deterministically picks the canonical row and logs duplicate counts (`backend/app/database/website_database_db.py:40`), matching migration 090 ordering.
- `celery_task_db` centralizes active task checks, revocation marking, dead-worker cleanup, and thread-scoped task metadata. It defines terminal states at `backend/app/database/celery_task_db.py:17`, task lookback/time limit at `celery_task_db.py:22`, app-scoped active checks at `celery_task_db.py:30`, dead-worker transition at `celery_task_db.py:84`, thread-scoped checks at `celery_task_db.py:157`, and metadata update at `celery_task_db.py:220`.

### Schemas and event compatibility

- Pydantic schemas use current Pydantic v2 style (`model_config = ConfigDict(...)`) per `backend/AGENTS.md:128`.
- Website create/update schemas use strict extra-field rejection in places (`backend/app/schemas/website_schema.py:84`). Route tests assert extra fields are rejected for create-with-thread (`backend/tests/test_routes/test_website_with_thread.py:67`).
- Chat SSE event schemas are numerous subclasses of `ChatStreamSSE`; event type mapping is generated from subclasses at `backend/app/schemas/chat_schema.py:744`.
- Legacy/compatibility validators are present for schema-evolved event fields, e.g. `ChatStreamAgentSuggestions` validator at `backend/app/schemas/chat_schema.py:228` and discoverability score/list coercion at `chat_schema.py:664`, `chat_schema.py:676`, `chat_schema.py:690`, `chat_schema.py:697`.
- `workflow_event_service.events_to_sse()` reconstructs Pydantic event models from DB JSONB event data and must remain backward-compatible with stored events (`backend/app/services/workflow_event_service.py:216`). The platform context map explicitly warns about schema evolution at `agent-context/context-maps/platform-backend.md:69`.

## Core services and domain flows

### Website/thread/app creation

- `website_service.create_website()` creates an untitled app for the current WorkOS user and tracks analytics best-effort (`backend/app/services/website_service.py:461`).
- `website_service.create_website_with_thread()` performs first app + canonical main thread creation in one transaction (`backend/app/services/website_service.py:1283`). It sets `request_utils.set_application_id()` early for logging context (`website_service.py:1310`), creates the website and thread (`website_service.py:1312`, `website_service.py:1325`), sets `website.main_thread_id` (`website_service.py:1334`), saves fixtures, and schedules sandbox creation as a FastAPI background task (`website_service.py:1343`).
- `_required_website_checks()` combines app-limit checks and credit checks before create (`backend/app/services/website_service.py:1368`).
- `thread_service.create_sandbox()` provisions website directory, ensures template initialization, and gets/creates E2B sandbox in a background task with its own DB session (`backend/app/services/thread_service.py:83`).
- Tests cover success, extra-field rejection, and multi-user app creation at `backend/tests/test_routes/test_website_with_thread.py:32`.

### Chat/orchestrator request flow

- `chat_routes._enforce_send_authz()` (`backend/app/routes/chat_routes.py:308`) differentiates main-thread sends (owner-only) and draft-thread sends (active draft, matching app, caller has access). Tests cover each branch at `backend/tests/test_routes/test_chat_routes.py:707`.
- `chat_routes.message_handler()` (`backend/app/routes/chat_routes.py:388`) handles request validation, credit gates, busy/queue behavior, and orchestrator dispatch.
- Server-side message queue tables came in migration 109 (`backend/app/migrations/109-create-message-queue-tables.sql:1`). Queue service logic enforces `MAX_QUEUE_SIZE = 20`, position retry on unique conflicts, two-pass reorder, and failed/retry flows (`backend/app/services/message_queue/service.py:15`, `service.py:33`, `service.py:123`).
- Queue drain uses `SELECT ... FOR UPDATE SKIP LOCKED` to avoid double-dispatch and commits status transitions internally (`backend/app/services/message_queue/drain.py:1`, `drain.py:24`, `drain.py:84`). A background fallback sweep starts from FastAPI lifespan (`backend/app/services/message_queue/drain.py:268`).
- `dispatch_orchestrator()` owns transaction boundaries for message creation, task dispatch, and status updates, explicitly committing internally (`backend/app/services/message_queue/dispatch.py:53`, `dispatch.py:115`, `dispatch.py:199`, `dispatch.py:207`).

### Real-time workflow events

- `workflow_event_service.publish()` stores events through its own short-lived session and stamps `thread_id` into each event payload (`backend/app/services/workflow_event_service.py:29`).
- The DB trigger from migration 072 notifies listeners by thread id (`backend/app/migrations/072-notify-workflow-events-with-thread-id.sql:4`).
- `workflow_notification_service` keeps one asyncpg listener connection and per-thread `WeakSet` subscriber queues (`backend/app/services/workflow_notification_service.py:1`, `workflow_notification_service.py:27`). It supports persisted and ephemeral channels (`workflow_notification_service.py:21`), permanent callbacks for WhatsApp/Slack dispatch (`workflow_notification_service.py:31`), queue maxsize 100 (`workflow_notification_service.py:274`), and explicit shutdown cleanup (`workflow_notification_service.py:301`).
- `chat_routes.stream_chat_handler()` validates app/thread, uses short-lived internal sessions so SSE can outlive request DB scope, converts last-event epoch ms to datetime, and returns `StreamingResponse` (`backend/app/routes/chat_routes.py:63`).

### Billing and credits

- `agent-context/architecture/billing-and-credits.md:1` is the detailed architecture map.
- `BillingAdapter` is the abstraction (`backend/app/services/billing_adapter.py:103`) with provider exceptions at `billing_adapter.py:461`.
- `billing_service.get_billing_adapter()` returns `MetronomeBillingAdapter`; `billing_adapter_session()` guarantees `close()` (`backend/app/services/billing_service.py:25`, `billing_service.py:56`).
- `credit_service.resolve_billing_user()` centralizes owner vs actor resolution (`backend/app/services/credit_service.py:59`).
- Signup credit grant is idempotent and creates missing billing customers (`backend/app/services/credit_service.py:79`).
- `ensure_billing_setup()` self-heals missing Metronome customers (`backend/app/services/credit_service.py:724`).
- `is_credit_balance_sufficient()` is deliberately fail-open on billing provider errors (`backend/app/services/credit_service.py:793`, `credit_service.py:801`, `credit_service.py:855`). `check_is_credit_balance_required()` raises HTTP 402 only when the balance check returns false (`credit_service.py:863`).
- `MeterEventService.process_span_billing()` applies markup, dedupes by span-derived event id, sends usage to Metronome, handles duplicate/customer-not-found/error cases, and stores failed events for retry (`backend/app/services/meter_event_service.py:262`).
- `metronome_billing_adapter.py` has retry/backoff and alias-refresh behavior: retryable statuses at `backend/app/services/metronome_billing_adapter.py:76`, Retry-After parsing at `metronome_billing_adapter.py:212`, alias lookup retries at `metronome_billing_adapter.py:423`, and stale-ID refresh paths near `metronome_billing_adapter.py:526`.
- Tests cover Metronome 429/500/503/504 retries, alias refresh after 404, and logging levels at `backend/tests/test_services/test_metronome_billing_adapter.py:72`, `test_metronome_billing_adapter.py:98`, `test_metronome_billing_adapter.py:148`, `test_metronome_billing_adapter.py:240`.

### Deployment and domains

- `agent-context/architecture/deployment-and-domains.md:1` is the detailed architecture map.
- `canonical_url_service.compute_effective_canonical_url()` is the single small function for canonical precedence: connected custom domain > user override > deployment URL (`backend/app/services/canonical_url_service.py:1`, `canonical_url_service.py:16`).
- `deployment_service._apply_publish_url_rewrites()` applies canonical resolution and returns changed files plus Vite build env (`backend/app/services/deployment_service.py:409`).
- `deployment_service.create_deployment()` selects URL via Vercel service, persists it, rewrites canonical/site files, syncs to sandbox, initializes Pirsch, executes Vercel deploy, returns queued status, and tracks analytics (`backend/app/services/deployment_service.py:457`).
- `deployment_service.get_deployment_status()` maps Vercel state, resyncs actual URL, re-runs canonical rewrites if Vercel reassigns URL, schedules video capture and GSC submission when ready (`backend/app/services/deployment_service.py:582`, `deployment_service.py:638`, `deployment_service.py:681`, `deployment_service.py:727`).
- `vercel_deploy_service._get_or_create_project()` implements stable project reuse/creation, DB project-id persistence, local `.vercel/project.json` reuse when a user session exists, clean-name vs hashed-name collision handling, and stale-project clearing (`backend/app/services/vercel_deploy_service.py:659`).
- `vercel_deploy_service._sync_environment_variables()` reads `backend/.env` from the generated app via `dotenv_values()`, adds `VITE_DISABLE_KITE_BADGE` and `NODE_AUTH_TOKEN`, and upserts sensitive Vercel env vars in one API call (`backend/app/services/vercel_deploy_service.py:874`).
- Vercel deploy command passes transient `--build-env` values at `backend/app/services/vercel_deploy_service.py:1385`.
- `prepare_deployment_url()` priority is connected domains, custom alias, existing URL, default URL (`backend/app/services/vercel_deploy_service.py:1924`). `execute_deployment()` delegates the actual CLI deployment at `vercel_deploy_service.py:2043`.
- `domain_service.purchase_domain()` is an idempotent pending -> purchased -> setup -> active state machine with independent commits (`backend/app/services/domain_service.py:575`, `domain_service.py:652`, `domain_service.py:688`, `domain_service.py:699`, `domain_service.py:766`).
- `domain_service.get_entri_token()` prepares external-domain DNS/Resend/GSC/Entri state without creating orphaned records until connect (`backend/app/services/domain_service.py:971`). `connect_external_domain()` stores status `external` and verifies/setup email best-effort (`domain_service.py:1164`, `domain_service.py:1270`).
- Tests cover deployment URL persistence, reserved subdomain fallback, GSC custom domain submission, URL popup behavior, and canonical override preservation at `backend/tests/test_services/test_deployment_service.py:38`, `test_deployment_service.py:68`, `test_deployment_service.py:220`, `test_deployment_service.py:334`, `test_deployment_service.py:374`.

### Celery/background processing

- `agent-context/context-maps/celery.md:1` lists 9 incidents and golden-path files.
- `celery_host_service.Task.with_metadata()` binds application/thread metadata but mutates the Task wrapper instance (`backend/app/services/celery_host_service.py:114`). `Task.call()` validates Pydantic kwargs, serializes OTel trace/baggage, sender build timestamp, and app/thread metadata, then `.delay()` or `.apply_async(countdown=...)` (`celery_host_service.py:131`).
- `celery_host_service.task()` enforces async functions, rejects `__` param names, generates task names, creates kwargs Pydantic models, wraps Celery `shared_task` with timestamp retries, late acks, and OTel spans (`backend/app/services/celery_host_service.py:187`).
- Worker app discovery includes top-level `app.services/*.py`, `app.llm/*/__init__.py`, nested LLM subpackages, and service subpackages (`backend/app/services/celery_host_service.py:395`).
- Celery config uses DB result backend with custom table names, `task_track_started=True`, task time limit, two queues, routing for generation jobs, `worker_prefetch_multiplier=1`, `result_extended=True`, and task events (`backend/app/services/celery_host_service.py:420`).
- `revoke_task()` documents that `terminate=True` does not kill in-progress thread-pool tasks; cooperative cancellation is source of truth (`backend/app/services/celery_host_service.py:482`).
- `get_worker_backlog_per_slot()` uses Redis `LLEN` across workflow + generation queues instead of Celery pidbox inspect, avoiding worker event-loop wedges (`backend/app/services/celery_host_service.py:500`, `celery_host_service.py:555`). Tests assert no `inspect.active()` and both queues are summed (`backend/tests/test_routes/test_metrics_routes.py:75`, `test_metrics_routes.py:114`).
- `worker_main.py:30` initializes OTel, analytics, and PostHog in the worker process, `worker_main.py:56` gets the Celery app, and `worker_main.py:102` starts Prometheus metrics if configured.
- `celery_metrics.py` exposes Prometheus counters/gauges and registers Celery signal handlers with `weak=False` to prevent GC (`backend/app/utils/celery_metrics.py:20`, `celery_metrics.py:56`, `celery_metrics.py:82`).
- `zombie_task_sweeper.py` detects dead-worker `STARTED` tasks via `inspect.ping()`, marks rows `FAILURE`, revokes redelivery, and publishes SSE failure notifications (`backend/app/services/zombie_task_sweeper.py:1`, `zombie_task_sweeper.py:72`).
- Test coverage checks `.call(countdown=...)` uses `apply_async` (`backend/tests/test_services/test_celery_host_service.py:10`).

## Observability

- `agent-context/architecture/observability.md:1` maps Langfuse, OTel, Prometheus, PostHog, Segment, Mixpanel, and Grafana Alloy/Loki.
- `RequestIdMiddleware` sets a contextvar-backed request id and returns `X-Request-ID` (`backend/app/utils/middleware.py:16`, `middleware.py:41`; contextvars in `backend/app/utils/request_utils.py:9`).
- Structured logging config and noise filters live in `backend/app/utils/logging_utils.py`; it loads additional YAML logging config at `logging_utils.py:371` and provides server/worker logging config at `logging_utils.py:263`, `logging_utils.py:386`.
- OTel base setup uses resource attrs, `ParentBasedTraceIdRatio`, OTLP exporter, batch processor with failure backoff, and opt-in kill switch (`backend/app/utils/otel_utils.py:282`).
- FastAPI OTel instruments FastAPI, exception middleware, logging, HTTPX, and LangChain (`backend/app/utils/otel_utils.py:407`). Worker OTel instruments HTTPX/LangChain/logging without FastAPI (`otel_utils.py:337`).
- `create_span_from_remote_context()` reconstructs Celery worker child spans from serialized parent trace/span ids (`backend/app/utils/otel_utils.py:507`).
- `telemetry_service.py` is the thin wrapper over Langfuse for custom operations, LLM spans, and generation output updates (`backend/app/services/telemetry_service.py:1`, `telemetry_service.py:17`, `telemetry_service.py:53`, `telemetry_service.py:143`).
- `langfuse_service.detect_server_info()` auto-detects deploy-preview namespace/hostname and caches environment/base-url detection (`backend/app/services/langfuse_service.py:35`).
- `langfuse_service.log_custom_operation()` groups custom operations by `application_id` as trace id/session id (`backend/app/services/langfuse_service.py:82`, `langfuse_service.py:120`).
- `langfuse_service.log_llm_span()` creates `trace-create` + `generation-create`, writes usage and `costDetails`, and groups under application trace/session (`backend/app/services/langfuse_service.py:204`, `langfuse_service.py:242`, `langfuse_service.py:344`, `langfuse_service.py:424`).
- `llm_service.py` schedules inline telemetry + billing for backend LLM calls (`backend/app/llm/infra/llm_service.py:397`, `llm_service.py:522`, `llm_service.py:1388`). Sandbox OpenCode/Codex/Claude proxy metadata posts to `/api/v1/internal/proxy-telemetry` and converges at `meter_event_routes.proxy_telemetry_handler()` (`backend/app/routes/meter_event_routes.py:63`).
- Segment analytics lifecycle is in `analytics_service.py` (`backend/app/services/analytics_service.py:30`, `analytics_service.py:120`, `analytics_service.py:171`, `analytics_service.py:201`).
- Feature flags use PostHog via `feature_flag_service.get_feature_flag_value()` and fail-open defaults (`backend/app/services/feature_flag_service.py:18`).
- KEDA metrics route returns backlog per worker slot and surfaces 503 for broker issues (`backend/app/routes/metrics_routes.py:14`, `metrics_routes.py:47`).

## Security architecture and guardrails

- `backend/docs/rules/agent-security.md:1` is the key agent security policy. It blocks proxy/relay infrastructure, credential access, server creation, provider SDK proxying, infrastructure/auth/path/system disclosure, and social-engineering bypasses.
- Programmatic guardrails include `_DANGEROUS_REQUEST_PATTERNS` and `_is_dangerous_request()` in `backend/app/llm/orchestrator_agent/tools/trigger_coding_agent.py:18`, `trigger_coding_agent.py:34`, with refusal wiring at `trigger_coding_agent.py:107`.
- OpenCode file-write protections deny critical config, package/lock files, server/proxy files, agent config dirs, and PM2/Caddy/Procfile surfaces (`backend/app/llm/infra/opencode_cli.py:354`).
- E2B sandbox startup deliberately keeps master OpenRouter/Cloudinary/Gallery secrets out of PM2 bootstrap env and injects them per command instead (`backend/app/services/e2b_service.py:3284`). `INTERNAL_API_TOKEN` remains in startup env only to render metadata-proxy `TELEMETRY_TOKEN` (`e2b_service.py:3322`); `ANTHROPIC_API_KEY` is explicitly not injected (`e2b_service.py:3332`).
- Seed/source cloning has SSRF host allowlists in `backend/app/services/seed_service.py:40`, enforced by `_validate_source_host()` at `seed_service.py:57` and used when parsing source URLs at `seed_service.py:70`.
- Sandbox and prompt-abuse historical maps are high-value risk context:
  - `agent-context/context-maps/sandbox-secret-leak.md:1` documents E2B auto-exposed ports, PM2 env leakage, and metadata-proxy mitigations.
  - `agent-context/context-maps/heredoc-shell-injection.md:1` documents heredoc delimiter-collision RCE and the requirement to pass untrusted content via envs, not shell interpolation.
  - `agent-context/context-maps/llm-prompt-abuse.md:1` documents social engineering, infrastructure recon, scope escape, static regex limits, and output redaction defenses.

## Tests and validation posture

- Test app fixture constructs `make_app()` but overrides lifespan to no-op (`backend/tests/conftest.py:157`), so tests do not start process-wide services by default.
- Test DB is recreated once per session, migrations are applied, engine caches are cleared/disposed (`backend/tests/conftest.py:175`). `async_db_session` shares the session-scoped engine and commits after each test (`backend/tests/conftest.py:233`).
- `async_client` overrides `authentication_checker` to bypass auth for route tests (`backend/tests/conftest.py:262`), so authz/security-sensitive tests must test guards directly or avoid relying on global auth.
- Autouse fixtures mock session-manager current user and PostHog (`backend/tests/conftest.py:136`, `conftest.py:147`) and detect unawaited coroutines in teardown (`conftest.py:83`).
- Shared DB isolation is a real constraint: `agent-context/AGENTS-testing.md:1` and `agent-context/context-maps/test-isolation.md:1` require namespacing with `test_id` and, for app-creation tests, often a UUID suffix to avoid per-user app-limit collisions.
- Representative coverage:
  - Website create-with-thread route and schema strictness: `backend/tests/test_routes/test_website_with_thread.py:32`, `test_website_with_thread.py:67`.
  - Chat queue/credit/cancellation/authz behavior: `backend/tests/test_routes/test_chat_routes.py:47`, `test_chat_routes.py:167`, `test_chat_routes.py:246`, `test_chat_routes.py:707`.
  - Metrics/KEDA failure semantics and no pidbox inspect: `backend/tests/test_routes/test_metrics_routes.py:14`, `test_metrics_routes.py:75`, `test_metrics_routes.py:114`.
  - Metronome adapter retries/alias refresh: `backend/tests/test_services/test_metronome_billing_adapter.py:72`, `test_metronome_billing_adapter.py:148`, `test_metronome_billing_adapter.py:240`.
  - Deployment URL/GSC/canonical behavior: `backend/tests/test_services/test_deployment_service.py:38`, `test_deployment_service.py:220`, `test_deployment_service.py:374`.
  - App DB uniqueness/canonical legacy duplicate handling: `backend/tests/test_database/test_website_database_db.py:14`.
  - DB session cancellation cleanup: `backend/tests/test_utils/test_db_session.py:274`, `test_db_session.py:292`.

## Maintainability and scalability patterns already in use

- **Route auto-discovery:** Adding `*_routes.py` modules is low-boilerplate and keeps registration centralized (`backend/app/__init__.py:110`).
- **Central dependency aliases:** `SettingsDep` and `AsyncSessionDep` reduce route/service boilerplate and encode cleanup timing (`backend/app/config.py:769`, `backend/app/utils/db_session.py:398`).
- **Cancellation-safe DB cleanup:** `BaseException` rollback plus shielded rollback/close/invalidate prevents connection-pool contamination during request/SSE/Celery cancellations (`backend/app/utils/db_session.py:33`, `db_session.py:328`).
- **Schema drift detection on startup:** `verify_schema_is_in_sync()` catches model/table column mismatches early (`backend/app/utils/db_session.py:505`).
- **Incident context maps:** Recurring bug classes are documented and linked to golden paths: Celery (`agent-context/context-maps/celery.md:1`), datetime (`agent-context/context-maps/datetime-handling.md:1`), AsyncSession concurrency (`agent-context/context-maps/sqlalchemy-asyncsession-concurrency.md:1`), app DB uniqueness (`agent-context/context-maps/app-database-application-id-uniqueness.md:1`), missing telemetry (`agent-context/context-maps/missing-telemetry.md:1`), security maps cited above.
- **Adapter seams:** Billing adapter (`backend/app/services/billing_adapter.py:103`), `billing_adapter_session()` (`billing_service.py:56`), telemetry wrapper (`telemetry_service.py:1`), canonical URL service (`canonical_url_service.py:1`), feature-flag service (`feature_flag_service.py:1`) keep provider details mostly contained.
- **Fail-open where business wants availability:** Feature flags default to Creator-level values (`backend/docs/rules/feature-flags.md:15`); credit checks allow workflows through during provider outage (`backend/app/services/credit_service.py:801`).
- **Idempotency and self-healing:** Signup/monthly credit grants check for prior grants; billing setup self-heals missing customers; Vercel project settings are re-ensured/reused; domain purchase state machine commits each transition and can resume (`credit_service.py:79`, `credit_service.py:724`, `vercel_deploy_service.py:659`, `domain_service.py:575`).
- **Scalable queueing primitives:** Message queue uses DB constraints, retry loops, `FOR UPDATE SKIP LOCKED`, and background sweeps (`message_queue/service.py:15`, `message_queue/drain.py:24`). Celery KEDA metric switched from global pidbox inspect to local Redis `LLEN` reads (`celery_host_service.py:500`).
- **Observability-first metadata threading:** Request id/app id/user email contextvars, OTel baggage, Celery metadata persistence, Langfuse application trace grouping, and proxy telemetry all aim to correlate user action -> app/thread/message -> LLM cost/trace (`request_utils.py:9`, `celery_host_service.py:131`, `langfuse_service.py:120`, `meter_event_routes.py:63`).
- **Defense in depth for sandboxes/agents:** Prompt rules, regex screeners, protected write globs, redaction, PM2 env scoping, SSRF allowlists, and internal bearer/TOTP auth are layered rather than relying on a single control.

## Tensions, stale docs, and broken/risky spots

1. **Stale backend README and context maps.**
   - `backend/README.md:50` still lists `application_routes.py`, `app_database_routes.py`, `approval_request.py`, `tool_call.py`, and `app_database_service.py`, but actual current files include `website_database_routes.py`, `website_database_service.py`, and no `application_routes.py`/`app_database_service.py` found.
   - `agent-context/context-maps/platform-backend.md:27` through `platform-backend.md:36` references `app/llm/infra/multi_iteration.py`, `app/services/orchestrator_service.py`, `app/services/orchestrator_tools_service.py`, and `app/services/app_database_service.py`; these were not present in this checkout. Treat that map as historically valuable but stale for exact file paths.

2. **Import-boundary drift.**
   - `backend/AGENTS.md:92` prefers package-level imports and says to avoid direct module imports. In practice, many routes/services use direct imports for concrete modules/functions, e.g. `backend/app/routes/website_routes.py:15` imports schemas and services from concrete modules and `backend/app/routes/website_routes.py:24` imports `check_can_create_website` directly.
   - This is not necessarily harmful, but the stated convention and actual style differ, so future refactors should follow local precedent in the touched module or intentionally move toward the documented boundary.

3. **“Services are modules, not classes” is only partly true.**
   - The context map says services are modules (`agent-context/context-maps/platform-backend.md:20`). Many are. But `MeterEventService` is class-based (`backend/app/services/meter_event_service.py:183`), billing uses abstract/class adapters (`backend/app/services/billing_adapter.py:103`, `metronome_billing_adapter.py`), and several service modules define dataclasses/stateful adapters. The real rule is closer to “deterministic business logic in `app/services/`, classes allowed when they wrap provider state/lifecycle.”

4. **Feature-flag provider abstraction is leaky.**
   - Docs say never import `posthog_service` directly (`backend/docs/rules/feature-flags.md:10`, `backend/AGENTS.md:120`). `feature_flag_service.py` correctly imports the provider internally (`backend/app/services/feature_flag_service.py:14`), and app startup owns provider lifecycle (`backend/app/__init__.py:17`).
   - `payment_service.py` also imports and calls `posthog_service.identify_user()` directly (`backend/app/services/payment_service.py:36`, `payment_service.py:581`, `payment_service.py:731`), which makes provider swaps harder.

5. **Error-handling rules vs route reality.**
   - `backend/docs/rules/error-handling.md:1` says avoid generic `Exception` catches that convert to 500/detail strings.
   - `domain_routes.py` repeatedly catches generic `Exception` and returns client-visible details (`backend/app/routes/domain_routes.py:81`, `domain_routes.py:233`, `domain_routes.py:296`, `domain_routes.py:345`). `payment_routes.py` returns error detail strings in webhook failure paths (`backend/app/routes/payment_routes.py:418`). `shared_tool_routes.py` also turns generic exceptions into detailed 500s for internal endpoints (`backend/app/routes/shared_tool_routes.py:49`, etc.). Some internal detail may be intentional, but it deviates from the documented general rule.

6. **SSE subscription authorization gap is explicitly documented in code.**
   - `chat_routes.stream_chat_handler()` validates the app exists and, for explicit thread ids, that the thread belongs to the app. But it has a TODO: “any authenticated user knowing a websiteId+threadId pair can subscribe” and should be owner/collaborator gated (`backend/app/routes/chat_routes.py:95`).
   - Send-path authorization is much stronger (`backend/app/routes/chat_routes.py:308`) and has tests (`backend/tests/test_routes/test_chat_routes.py:707`), so the main gap is streaming visibility rather than writes.

7. **Termination/cancellation remains main-thread biased for drafts.**
   - `chat_routes` derives termination target from website’s main/latest thread and has TODOs saying draft collaborator tasks use draft `thread_id`, so cancellation/revocation will not reach them (`backend/app/routes/chat_routes.py:566`, `chat_routes.py:577`).

8. **Unauthenticated internal debug token route leaks token metadata.**
   - `authentication_checker.EXCLUDED_PATHS` excludes `/api/v1/internal/debug/token` (`backend/app/services/authentication_checker.py:42`). The route returns whether a token exists, token length, and first 10 chars (`backend/app/routes/internal_routes.py:91`). Even if intended for development, it is a risky production surface unless ingress blocks it.

9. **Timezone doctrine vs domain route comment.**
   - TIMESTAMPTZ is the doctrine (`agent-context/context-maps/datetime-handling.md:1`, migration 076 at `backend/app/migrations/076-convert-all-timestamps-to-timestamptz.sql:1`).
   - `domain_routes.py:144` still comments “Database stores naive UTC timestamps” and calls `.replace(tzinfo=timezone.utc)` manually (`domain_routes.py:146`). This may be a stale comment or a real edge-case workaround; either way it conflicts with current timestamp rules.

10. **Transaction-boundary exceptions need care.**
    - The standard `AsyncSessionDep` pattern commits/rolls back at dependency cleanup (`backend/app/utils/db_session.py:328`).
    - Message queue dispatch/drain explicitly commits internally (`backend/app/services/message_queue/dispatch.py:53`, `message_queue/drain.py:31`). Callers must not wrap these in broader uncommitted workflows. This is documented locally, but it is a common source of surprise.

11. **Celery Task metadata binding is mutable.**
    - `Task.with_metadata()` mutates the Task wrapper and warns callers not to cache it because metadata can leak between dispatches (`backend/app/services/celery_host_service.py:114`). The TODO suggests passing metadata directly to `.call()` would be safer. This is a concurrency footgun for future task dispatch code.

12. **Zombie sweeper can still publish to the wrong thread.**
    - `zombie_task_sweeper._get_active_thread_id_for_website()` comments that it picks the thread with most recent message activity and can publish failure events to the wrong place; it says a precise fix would require storing `thread_id` on `celery_tasks` (`backend/app/services/zombie_task_sweeper.py:55`). Migration 111/model support now store `thread_id` (`backend/app/migrations/111-celery-tasks-add-thread-id.sql:1`, `backend/app/models/celery_task.py:48`), but `mark_dead_worker_tasks_as_failed()` still returns only `(application_id, task_id)` (`backend/app/database/celery_task_db.py:84`). This looks like a stale implementation gap.

13. **Large “god modules” concentrate risk.**
    - `backend/app/services/vercel_deploy_service.py` is thousands of lines and owns API client, project discovery, env sync, CLI deploy, aliases, DNS, logs, deletion, and URL prep. `backend/app/routes/internal_routes.py` is similarly broad (debug, downloads, hijack, inspector, seed, iterations). These are useful operationally but harder to review safely.

14. **AsyncSession concurrency remains a known hazard.**
    - `agent-context/context-maps/sqlalchemy-asyncsession-concurrency.md:1` warns that fan-out paths must not share one `AsyncSession` across concurrent tasks. This is especially relevant to image generation/file metadata/app DB URL lookup flows.

15. **Sandbox/LLM security controls require continual upkeep.**
    - Static regex guards in `trigger_coding_agent.py` and prompt rules can miss new abuse phrasings (`agent-context/context-maps/llm-prompt-abuse.md:1`). Sandbox maps warn E2B exposes listening TCP ports publicly and PM2/env inheritance can leak secrets (`agent-context/context-maps/sandbox-secret-leak.md:1`). Any new sandbox listener, CLI runner, or agent prompt must be audited against those maps.

## High-value file map for future backend work

### Startup/config/routing

- `backend/app/__init__.py` — app factory, lifespan, route auto-discovery, global dependencies/middleware.
- `backend/main.py` — Uvicorn factory startup.
- `backend/worker_main.py` — Celery worker entrypoint and metrics server.
- `backend/app/config.py` — Pydantic settings and DI alias.
- `backend/Taskfile.dist.yml`, `backend/pyproject.toml` — validation/lint/type/package constraints.

### Auth/security

- `backend/app/services/authentication_checker.py` — global auth dependency and excluded paths.
- `backend/app/services/workos_service/auth.py`, `session_manager.py`, `client.py` — sealed-session WorkOS auth.
- `backend/app/routes/auth_workos_routes.py` — OAuth/CLI/WhatsApp auth routes and onboarding side effects.
- `backend/app/utils/internal_auth.py`, `backend/app/utils/workos_jwt.py`, `backend/app/utils/whatsapp_login_token.py` — internal/token auth utilities.
- `backend/docs/rules/agent-security.md`, `agent-context/context-maps/sandbox-secret-leak.md`, `agent-context/context-maps/llm-prompt-abuse.md`, `agent-context/context-maps/heredoc-shell-injection.md` — security guardrails and incident context.

### Database/models/migrations

- `backend/app/utils/db_session.py` — engine/session/migrations/schema verification.
- `backend/app/models/application.py`, `thread.py`, `message.py`, `celery_task.py`, `workflow_event.py`, `app_database.py`, `domain.py`, `subscription.py`, `user.py` — core entities.
- `backend/app/database/website_db.py`, `thread_db.py`, `celery_task_db.py`, `website_database_db.py`, `workflow_event_db.py` — core persistence modules.
- Migrations: `001`, `002`, `006`, `071-*`, `072`, `076`, `090`, `109`, `111`, `113`, `114` are especially architecture-relevant.

### Routes/services by domain

- Website/app: `backend/app/routes/website_routes.py`, `backend/app/services/website_service.py`, `thread_service.py`.
- Chat/realtime: `backend/app/routes/chat_routes.py`, `backend/app/services/workflow_event_service.py`, `workflow_notification_service.py`, `message_queue/*`.
- Celery/background: `backend/app/services/celery_host_service.py`, `zombie_task_sweeper.py`, `backend/app/utils/celery_metrics.py`.
- Billing: `backend/app/routes/payment_routes.py`, `meter_event_routes.py`, `backend/app/services/billing_adapter.py`, `billing_service.py`, `credit_service.py`, `meter_event_service.py`, `metronome_billing_adapter.py`, `payment_service.py`, `stripe_service.py`.
- Deployment/domains: `backend/app/services/deployment_service.py`, `vercel_deploy_service.py`, `domain_service.py`, `canonical_url_service.py`, `google_search_console_service.py`, plus `backend/app/routes/domain_routes.py`, `gsc_routes.py`, `vercel_webhook_routes.py`.
- Observability: `backend/app/utils/otel_utils.py`, `logging_utils.py`, `request_utils.py`, `backend/app/services/telemetry_service.py`, `langfuse_service.py`, `analytics_service.py`, `posthog_service.py`, `feature_flag_service.py`.
- E2B/LLM/sandbox: `backend/app/services/e2b_service.py`, `backend/app/llm/infra/opencode_cli.py`, `backend/app/llm/infra/llm_service.py`, `backend/app/llm/orchestrator_agent/tools/trigger_coding_agent.py`.

### Tests

- `backend/tests/conftest.py` — app/test DB fixtures and auth mocking.
- `backend/tests/test_routes/test_chat_routes.py`, `test_website_with_thread.py`, `test_auth_workos_callback.py`, `test_metrics_routes.py` — route behavior.
- `backend/tests/test_services/test_deployment_service.py`, `test_metronome_billing_adapter.py`, `test_credit_service.py`, `test_celery_host_service.py` — service behavior.
- `backend/tests/test_database/test_website_database_db.py`, `test_app_database_db.py` — DB invariants.
- `backend/tests/test_utils/test_db_session.py` — DB session/cancellation lifecycle.
