# Cross-cutting architecture patterns: operations, infra, quality, security

Scope: repository-local research only. This summary focuses on production-grade scaling primitives and guardrails across the platform backend, frontend, generated-app template, CI, and E2B sandbox runtime.

## Executive synthesis

Kite's cross-cutting architecture is service-centered: routes/tools are thin, long-running or fallible work is pushed into Celery, database-backed queues, Postgres events, sandbox-local runners, or tracked fire-and-forget tasks. The strongest production patterns are:

- **Async execution + backpressure:** Celery/Redis queues for workflows and generation jobs, plus a server-side per-app chat message queue when an orchestrator turn is already active.
- **Autoscaling:** KEDA polls a backlog-per-worker-slot endpoint derived from Redis `LLEN` across both workflow and generation queues.
- **Eventing:** workflow events are persisted in Postgres and fanned out with `LISTEN/NOTIFY`; transient SSE events use a separate ephemeral channel.
- **Idempotency/retry:** billing event IDs, generation idempotency keys, domain/GSC state machines, Slack webhook dedup, message queue partial unique indexes, and ordered submission upserts.
- **Security/authz:** WorkOS sealed sessions, middleware-level auth, route-level internal token/JWT/TOTP checks, collaboration checks, HMAC webhooks, sandbox port firewalling, and agent-level prompt/code guardrails.
- **Observability/cost:** Langfuse + Metronome unified LLM telemetry/billing, OTEL distributed traces, Prometheus worker metrics, structured logs, Segment/PostHog/Mixpanel, and scheduled infra/vendor cost monitors.
- **Regression capture:** conventional CI gates, dedicated orchestrator/coding eval harnesses, scheduled evals, QA/SEO checks, Trivy secret scanning, prompt linting/scoring, and documented incident context maps.

Key risks to keep visible:

- Several blast-radius controls are **per process** rather than distributed (notably fork-preview E2B wake throttling).
- Some user-facing gates intentionally **fail open** to preserve availability (credit checks, feature flags), which is good for uptime but can allow temporary overuse/premium access.
- There are explicit authz/cancellation TODOs around chat SSE subscription and draft-thread cancellation in `chat_routes.py`.
- Some background work uses bare `asyncio.create_task`; tracked-task sets are used in critical places (GSC/video/telemetry), but not universally.

---

## Operations patterns

### 1. Celery as the main long-running-work substrate

Evidence:

- `backend/app/services/celery_host_service.py:187` defines the standard `task()` decorator. It requires async functions, builds a Pydantic kwargs model from the function signature, and wraps task execution with deployment timestamp checks, OTEL context propagation, application/user context, DB metadata persistence, span status, and async resource cleanup.
- The Celery wrapper configures `max_retries`, `autoretry_for=(WorkerTooOldError,)`, `retry_backoff=True`, `retry_backoff_max=15`, and `acks_late=True` in the shared task registration (`backend/app/services/celery_host_service.py:244-256`).
- `get_celery_app()` wires Redis broker + SQLAlchemy result backend, JSON serializers, DB result tables (`celery_tasks`, `celery_groups`), `task_track_started=True`, task time limits, queue routing, `worker_prefetch_multiplier=1`, `worker_concurrency=settings.celery_worker_concurrency`, and worker task events (`backend/app/services/celery_host_service.py:380-471`).
- Two queues are first-class: default workflow queue and `generation_queue_name`; `generation_job_service.run_generation_job_task` is routed to the generation queue with a longer time limit (`backend/app/services/celery_host_service.py:430-455`).
- Worker bootstrap initializes OTEL before logging, Segment analytics, PostHog flags, Prometheus metrics, and Redis queue-length collection (`backend/worker_main.py:51-59`, `backend/worker_main.py:128-134`).

Operational implications:

- The wrapper is the repo's control plane for task serialization, trace continuity, deploy-skew retry, and cooperative cancellation metadata.
- Tasks should live under `app/services` or `app/llm`; CI enforces this (`.github/workflows/platform-code-quality.yml:75-85`).
- Risk: `Task.with_metadata()` mutates the `Task` object before `.call()`; the code comments warn not to cache task instances between dispatches (`backend/app/services/celery_host_service.py:104-116`).

### 2. Chat backpressure via a database-backed per-app message queue

Evidence:

- If an orchestrator task is already active for a thread, `stream_chat_handler` credit-checks then enqueues instead of dispatching another orchestrator run, returning HTTP 202 with queue position (`backend/app/routes/chat_routes.py:431-470`).
- Queue state is stored in `message_queue` and `queue_state`, with indexes and a partial unique index on `(application_id, queue_position) WHERE status='queued'` (`backend/app/migrations/109-create-message-queue-tables.sql:4-35`).
- Queue size is soft-capped at 20 active messages (`backend/app/services/message_queue/service.py:15-20`, `MAX_QUEUE_SIZE`).
- `enqueue()` retries on position-constraint contention (`backend/app/services/message_queue/service.py:40-83`).
- `drain_next()` recovers stale `sending` rows, respects `drain_suspended`/`awaiting_user_input`, selects the next queued row with `FOR UPDATE SKIP LOCKED`, marks it durable `sending`, dispatches, then deletes the row on success (`backend/app/services/message_queue/drain.py:29-157`).
- A 30-second sweep finds drainable apps and drains one message per app; multiple sweep workers are safe because of `SKIP LOCKED` (`backend/app/services/message_queue/drain.py:238-289`).

Operational implications:

- This queue converts user burst/concurrent messages into serialized orchestrator work.
- The queue deliberately tolerates brief over-capacity under concurrent enqueues; structural integrity is maintained by the partial unique index and retry loop.

### 3. Resumable internal generation jobs

Evidence:

- `GenerationJob` stores `idempotency_key`, `status`, `application_id`, `started_at`, `retry_count`, and output fields (`backend/app/models/generation_job.py:8-25`).
- The DB enforces a partial unique idempotency index for non-null keys (`backend/app/migrations/089-create-generation-jobs-table.sql:19-21`).
- `create_job()` returns an existing pending/in-progress/success job for the same idempotency key, clears the key for failed jobs to permit retry, and handles insertion races via `IntegrityError` rollback (`backend/app/services/generation_job_service.py:58-105`).
- The Celery `run_generation_job_task` persists org/app/thread state early so retries can resume against an existing app/thread (`backend/app/services/generation_job_service.py:209-325`).
- Stuck jobs are detected after 30 minutes and persisted as failed (`backend/app/services/generation_job_service.py:50`, `backend/app/services/generation_job_service.py:107-126`).
- `_handle_failure()` retries up to 3 times with exponential-ish countdowns of 30/60/... seconds, except missing iteration artifacts fail terminally (`backend/app/services/generation_job_service.py:497-542`).

### 4. Deployment side effects are intentionally asynchronous or best-effort

Evidence:

- Generated app deployments use Vercel `--prod --no-wait`; docs state clients poll the GET deployment endpoint instead of tying deployment completion to the HTTP request lifecycle (`APP_DEPLOYMENT.md:35`).
- `create_deployment()` prepares/stores the deployment URL, rewrites canonical/sitemap/robots values, syncs publish-time file changes to sandbox in the background, initializes Pirsch best-effort, and triggers Vercel (`backend/app/services/deployment_service.py:457-532`).
- `get_deployment_status()` syncs actual Vercel URLs if aliases drift, reruns publish rewrites best-effort, triggers video capture in a tracked background task, and schedules Search Console sitemap submission in a tracked task (`backend/app/services/deployment_service.py:582-744`).
- GSC and video tasks are held in module-level sets with done callbacks to avoid garbage collection and surface failures (`backend/app/services/deployment_service.py:49-81`, `backend/app/services/deployment_service.py:85-134`).

### 5. Domain and Search Console flows are state machines, not one-shot calls

Evidence:

- `purchase_domain()` is explicitly idempotent and resumable, tracking `pending -> purchased -> setup -> active` (`backend/app/services/domain_service.py:575-586`).
- It validates an existing domain belongs to the same creator/app, returns immediately if already active, creates a pending row and commits before calling Vercel, then commits after each external state transition (`backend/app/services/domain_service.py:618-649`, `backend/app/services/domain_service.py:653-768`).
- Search Console verification uses `RETRY_DELAYS` and `MAX_RETRIES=10`, with terminal status classifications and retry-exhausted states (`backend/app/services/gsc_verification_service.py:25-33`).
- `_handle_retryable_failure()` commits retry state before scheduling the next Celery retry with `countdown` (`backend/app/services/gsc_verification_service.py:480-513`).
- Sitemap submission uses `upsert_submission()` with a deployment-created-at ordering rule to reject stale updates while allowing same-deployment transitions (`backend/app/database/search_console_db.py:132-190`).

---

## Infrastructure and scaling patterns

### 1. KEDA autoscaling uses queue backlog, not worker RPC fanout

Evidence:

- `/api/v1/metrics/workers/utilization` is documented as an ingress-blocked KEDA endpoint, not a public API (`backend/app/routes/metrics_routes.py:18-25`).
- The metric is `(LLEN(workflow_queue) + LLEN(generation_queue)) / worker_concurrency`; docs explain the route name is stable but semantics changed from active utilization to backlog-per-slot (`backend/app/routes/metrics_routes.py:25-39`).
- `get_worker_backlog_per_slot()` makes two Redis `LLEN` calls with a 2-second socket timeout and avoids Celery `inspect.active()` fanout because pidbox broadcasts previously saturated Redis and froze workers (`backend/app/services/celery_host_service.py:503-585`).
- Prometheus worker metrics expose task totals, active task gauges, configured concurrency, up/down, and queue backlog (`backend/app/utils/celery_metrics.py:20-53`).

Scaling implications:

- Autoscaling follows queue pressure rather than current busy count, which is more robust under Redis/Celery fanout at DP scale.
- KEDA fallback behavior matters if Redis `LLEN` fails; the endpoint returns 503 on metric failures (`backend/app/routes/metrics_routes.py:51-65`).

### 2. Runtime deployment model: EKS/Helm/ArgoCD, Docker image promotion, DP isolation

Evidence:

- Auto deploy runs backend tests, builds an image, then patches deployment; releases deploy production, pushes to `main` default to staging (`.github/workflows/auto-deploy.yml:13-33`, `.github/workflows/auto-deploy.yml:72-84`).
- `update-deployment` validates the Docker image exists, configures the EKS environment, then patches ArgoCD's `kite` Application image tag (`.github/workflows/update-deployment.yml:69-106`).
- Deploy previews always use environment `dp`, create a per-PR database, install/update a per-PR Helm release/namespace, and poll `/info` for matching `GITHUB_SHA` (`.github/workflows/deploy-preview.yml:70`, `.github/workflows/deploy-preview.yml:160-190`).
- Production/staging secrets are AWS Secrets Manager values synced by External Secrets Operator; Reloader restarts pods after synced secret changes (`DEPLOYMENT.md:28`, `DEPLOYMENT.md:222`).
- The platform Docker image runs as non-root `app` (`Dockerfile:73`), uses frozen uv installs and bytecode compilation, and installs Playwright Chromium for video recording (`Dockerfile:84-86`).

### 3. E2B sandboxes are versioned infrastructure with startup self-healing

Evidence:

- The image build computes `TEMPLATE_SHA` as the latest commit touching `e2b/` or `nextjs-template/` and bakes it into `/top/info.json`; backend uses it to kill stale sandboxes rather than silently reusing wrong templates (`.github/workflows/build-docker-image.yml:101-124`).
- E2B template workflow builds staging templates on `main` E2B changes and production templates on release, with fixed memory/CPU and template IDs (`.github/workflows/e2b-template.yml:1-13`, `.github/workflows/e2b-template.yml:74-78`).
- Sandbox startup waits for required generated files under EFS and exits with code 64 if they do not become visible, forcing backend retry/recovery rather than booting an incomplete app (`e2b/start-with-generation.sh:25-70`).
- PM2 home is pinned and old metadata proxy entries are deleted to avoid resumed-sandbox port collisions (`e2b/start-with-generation.sh:72-100`).
- Metadata proxy port 8787 is firewalled to loopback; failures warn loudly but do not abort sandbox boot (`e2b/firewall.sh:1-37`).

### 4. Eventing uses persisted state plus Postgres notifications

Evidence:

- Workflow events are stored in `workflow_events` with indexed `thread_id`, `event_type`, `created_at`, and JSONB payload (`backend/app/models/workflow_event.py:16-36`).
- `workflow_event_service.publish()` writes events to the DB and stamps `thread_id` into payloads for routing (`backend/app/services/workflow_event_service.py:29-73`).
- Migration 072 adds a trigger that calls `pg_notify('workflow_events', NEW.thread_id::text)` after workflow event inserts (`backend/app/migrations/072-notify-workflow-events-with-thread-id.sql:4-14`).
- `workflow_notification_service` keeps one asyncpg listener connection, maps `thread_id` to weakly-held subscriber queues, supports permanent callbacks, and separate persisted/ephemeral channels (`backend/app/services/workflow_notification_service.py:21-44`, `backend/app/services/workflow_notification_service.py:150-245`).
- `subscribe_to_events()` creates bounded subscriber queues (`maxsize=100`) and cleans them up on disconnect (`backend/app/services/workflow_notification_service.py:274-328`).
- `publish_ephemeral_event()` sends transient notifications over `workflow_events_ephemeral` without DB persistence (`backend/app/services/workflow_notification_service.py:339-350`).

---

## Idempotency, retry, and rate-limiting patterns

### Idempotency and replay safety

- **Billing:** `BillingAdapter.send_usage_event()` requires an `event_id` for duplicate-charge prevention (`backend/app/services/billing_adapter.py:277-283`). `meter_event_service` derives `event_id = f"or-{trace_id}-{span_id}"` (`backend/app/services/meter_event_service.py:300`), and Metronome maps it to `transaction_id` (`backend/app/services/metronome_billing_adapter.py:861-905`). Failed billing rows have a unique `helicone_request_id`/event key and a partial retry index (`backend/app/migrations/052-create-meter-events-table.sql:22`, `backend/app/migrations/052-create-meter-events-table.sql:57`).
- **Generation jobs:** partial unique index on `idempotency_key` and `create_job()` returning existing non-failed jobs (`backend/app/migrations/089-create-generation-jobs-table.sql:19-21`, `backend/app/services/generation_job_service.py:58-105`).
- **Domains:** purchase flow validates existing row identity and resumes from the recorded status (`backend/app/services/domain_service.py:618-638`).
- **Search Console:** submission upserts skip older deployments (`backend/app/database/search_console_db.py:132-190`).
- **Slack inbound:** `slack_webhook_service._dedup_event()` uses shared Redis `SET NX EX` on Slack `event_id`; if Redis is absent, dedup falls back/weakens (`backend/app/services/slack_webhook_service.py:64-76`).
- **Message queue:** partial unique queued position prevents duplicate positions per app (`backend/app/migrations/109-create-message-queue-tables.sql:33-35`).

### Retry/backoff

- Celery deploy-skew retry: tasks from a newer sender requeue up to 8 times with exponential backoff before old workers process them (`backend/app/services/celery_host_service.py:87-90`, `backend/app/services/celery_host_service.py:250-254`, `backend/app/services/celery_host_service.py:306-331`).
- E2B operations retry up to 3 times; rate-limit errors are recognized via `RateLimitException`, HTTP 429, or message signatures, and 429 retry delays start at 5 seconds (`backend/app/services/e2b_service.py:61-62`, `backend/app/services/e2b_service.py:407-415`, `backend/app/services/e2b_service.py:496-543`).
- Metronome balance lookups retry on 429/5xx and honor `Retry-After` capped at 10 seconds (`backend/app/services/metronome_billing_adapter.py:73-77`, `backend/app/services/metronome_billing_adapter.py:212-239`).
- GSC verification uses bounded stepped backoff then `retry_exhausted` (`backend/app/services/gsc_verification_service.py:25-33`, `backend/app/services/gsc_verification_service.py:480-513`).

### Rate limiting / blast-radius controls

- Public `/fork-preview` can wake E2B, so it has a bounded per-process `TTLCache` cooldown of 60 seconds per website plus a 300-second successful-response cache; comments explicitly note the effective cap is N workers per cooldown and a global lock would require Redis `SET NX EX` (`backend/app/services/fork_service.py:63-87`).
- `_try_claim_fork_preview_wake_slot()` atomically claims the per-process wake slot (`backend/app/services/fork_service.py:104-114`), and cached responses are health-probed before reuse (`backend/app/services/fork_service.py:338-389`).
- Prompt scoring CI is capped at 10 minutes to prevent runaway LLM costs (`.github/workflows/prompt-quality-scorer.yml:21-23`).

---

## Observability and cost-control patterns

### Unified LLM telemetry + billing

Evidence:

- `meter_event_service.py` states inline backend LLM calls and sandbox CLI metadata proxies converge on the same `log_telemetry_for_span()` + `process_span_billing()` pipeline, with Metronome as source of truth and failed events stored locally for retry (`backend/app/services/meter_event_service.py:1-18`).
- Langfuse logging is fire-and-forget via background tasks with done callbacks; billing is awaited and persisted on failure (`backend/app/services/meter_event_service.py:47-56`, `backend/app/services/meter_event_service.py:262-477`).
- `process_span_billing()` bills the application owner when possible, applies markup, sends usage with idempotent event ID, self-heals missing billing setup, retries once, and persists failures (`backend/app/services/meter_event_service.py:284-477`).
- Sandbox proxy telemetry is also fire-and-forget so backend billing latency does not hold open CLI responses; strong task references avoid Python GC loss (`e2b/proxy_telemetry.py:59-139`).
- The unified metadata proxy narrows HTTP methods: Gemini allows GET/POST, all non-Gemini/OpenRouter paths require POST and return 405 otherwise (`e2b/metadata_proxy.py:581-599`).

### Observability stack

Evidence:

- Langfuse service uses REST ingestion rather than SDK, auto-detects deploy preview environment from Kubernetes namespace/hostname, and batches trace/span/generation events (`backend/app/services/langfuse_service.py:36-75`, `backend/app/services/langfuse_service.py:82-185`, `backend/app/services/langfuse_service.py:204-358`).
- OTEL setup configures resource attributes, sampling, OTLP exporter, batch processor, and a backoff wrapper that drops trace exports briefly after collector failures to avoid retry storms (`backend/app/utils/otel_utils.py:101-133`, `backend/app/utils/otel_utils.py:282-335`).
- FastAPI/worker OTEL setup instruments FastAPI, HTTPX, LangChain, and logging; Celery remote parent context is reconstructed for distributed traces (`backend/app/utils/otel_utils.py:337-459`, `backend/app/utils/otel_utils.py:507-570`).
- Structured logs include request ID, application ID, user email, and OTEL trace/span IDs (`backend/app/utils/logging_formatters/structured_formatter.py:15-83`).
- Prometheus worker metrics track active/running tasks and Redis queue backlog (`backend/app/utils/celery_metrics.py:20-53`, `backend/app/utils/celery_metrics.py:93-152`).
- Deployment docs point operators to Grafana Loki queries for backend, worker, and sandbox logs (`DEPLOYMENT.md:37-52`).
- Frontend Mixpanel session replay records at 100% when enabled and integrates replay IDs into Segment middleware (`frontend/src/lib/analytics/services/mixpanel.ts:23-64`, `frontend/src/lib/analytics/services/mixpanel.ts:140-181`).

### User-credit and infra/vendor cost controls

Evidence:

- Credit grants are idempotent: signup credits check existing `kite_signup` wallets before creating a new one (`backend/app/services/credit_service.py:136-176`).
- `ensure_billing_setup()` self-heals missing Metronome customers and validates cached IDs when an adapter is available (`backend/app/services/credit_service.py:724-790`).
- `is_credit_balance_sufficient()` fail-opens on missing customer, billing adapter errors, or unexpected exceptions, but returns false on real non-positive balance; `check_is_credit_balance_required()` turns false into HTTP 402 (`backend/app/services/credit_service.py:793-881`).
- Chat queue and direct dispatch check credits before adding work (`backend/app/routes/chat_routes.py:440-456`, `backend/app/routes/chat_routes.py:494-503`).
- Infrastructure monitoring doc describes a scheduled Appsmith workflow every 30 minutes for Neon limits, Firecrawl/Remove.bg credits, and daily OpenRouter-vs-Langfuse cost drift outside ±10% (`agent-context/operations/infrastructure-cost-monitoring-workflow.md:18-32`).
- Repo-level scheduled workflows clean stale Cloudinary images daily, clean inactive Neon projects daily, and monitor Crustdata credits hourly with daily Slack dedup via Actions cache (`.github/workflows/cloudinary-stale-image-cleanup.yml:6-68`, `.github/workflows/neon-database-cleanup.yml:6-70`, `.github/workflows/crustdata-credits-monitor.yml:1-59`).

Risk/trade-off:

- Billing and feature flags intentionally fail open for availability. Feature flags use Creator-level defaults when PostHog is down, temporarily granting premium access rather than locking out paid customers (`backend/docs/rules/feature-flags.md:24-29`).

---

## Security and authorization patterns

### Authentication and route gating

Evidence:

- Auth architecture uses WorkOS AuthKit OAuth code flow and sealed session cookie validated on subsequent requests (`agent-context/architecture/authentication.md:1-20`).
- `auth.py` exchanges OAuth code with `authenticate_with_code()`, seals the session with `settings.appsmith_session_secret_key`, and stores it in the request session (`backend/app/services/workos_service/auth.py:35-40`).
- Sealed session authentication runs WorkOS' sync method in a thread and refreshes expired JWTs before falling back to anonymous user (`backend/app/services/workos_service/auth.py:88-111`).
- `authentication_checker` centralizes excluded unauthenticated paths, explicitly notes HMAC-authenticated webhooks and route-level internal auth, and returns 401 for unauthenticated API requests (`backend/app/services/authentication_checker.py:14-48`, `backend/app/services/authentication_checker.py:55-127`).
- Internal APIs validate `Authorization: Bearer INTERNAL_API_TOKEN` via constant-time compare, with WorkOS JWT fallback (`backend/app/utils/internal_auth.py:14-46`). Internal download/hijack/seed endpoints additionally accept a TOTP-style `x-internal-token` with `secrets.compare_digest` (`backend/app/routes/internal_routes.py:51-72`).
- WhatsApp auto-login tokens are HMAC-SHA256 signed with a 7-day default TTL and constant-time signature verification (`backend/app/utils/whatsapp_login_token.py:1-50`).

### Authz and ownership

Evidence:

- Collaboration service owns owner-only invite/collaboration management and `has_access()` = owner or active collaborator (`backend/app/services/website_collaboration_service.py:1-40`).
- Chat sends enforce main-thread owner-only and active-draft owner/collaborator semantics before clearing queue blocks, credit checks, or dispatch (`backend/app/routes/chat_routes.py:308-384`, `backend/app/routes/chat_routes.py:416-424`).
- Message queue routes verify app/message ownership before reads/mutations; comments note `website_service.get_website` scopes by current user's email (`backend/app/services/message_queue/routes.py:29-47`, `backend/app/services/message_queue/routes.py:93-191`).
- Slack webhooks verify HMAC-SHA256 signatures with `hmac.compare_digest` and dedup events using Redis (`backend/app/services/slack_webhook_service.py:36-76`).

Known authz gaps / follow-ups:

- `stream_chat_sse` has a TODO: any authenticated user who knows `websiteId+threadId` can currently subscribe; now that thread ID is caller-supplied, it should be owner/collaborator gated (`backend/app/routes/chat_routes.py:90-114`).
- Workflow termination has TODOs that cancellation/revoke only target the main thread, so draft-thread cancellation needs caller-supplied thread ID plus ownership check (`backend/app/routes/chat_routes.py:560-580`).

### Agent/sandbox security

Evidence:

- Agent security rules block proxy/relay infrastructure, credential access, custom servers/process managers, AI provider SDK proxying, infrastructure/auth/system disclosure, and social-engineering bypass claims (`backend/docs/rules/agent-security.md:15-50`).
- Programmatic enforcement points include dangerous request screening, infrastructure-question filters, output sanitization, protected file globs, and sandbox env isolation (`backend/docs/rules/agent-security.md:53-61`).
- Sandbox metadata proxy port 8787 is loopback-only by iptables/ip6tables (`e2b/firewall.sh:1-37`).
- CI bans `set -x` in backend Python and app-template scripts because it leaks secrets into PM2 logs and observability (`.github/workflows/platform-code-quality.yml:86-100`).
- Trivy secret scan runs on PRs for CRITICAL/HIGH secrets and fails on findings, while skipping generated/dependency dirs and one known env file (`.github/workflows/trivy-scan.yaml:1-28`, `.trivy.yaml:1-45`).

---

## Quality and regression-capture patterns

### CI gates

Evidence:

- Platform code quality runs backend `ruff check --fix`, `ruff format`, `git diff --exit-code`, `basedpyright`, Celery task placement check, secret-leak `set -x` ban, prompt linter, frontend Prettier/ESLint/TypeScript, and workflow formatting (`.github/workflows/platform-code-quality.yml:49-107`, `.github/workflows/platform-code-quality.yml:108-160`).
- Backend tests run with Postgres 16, `pytest -v --tb=short --timeout=120 --maxfail=10 -m "not eval"` (`.github/workflows/platform-backend-tests.yml:8-58`).
- Trivy secret scan is PR-gated (`.github/workflows/trivy-scan.yaml:1-28`).
- Prompt scorer comments LLM quality feedback on PRs for prompt/doc changes and has a 10-minute job timeout (`.github/workflows/prompt-quality-scorer.yml:1-23`).

### Runtime QA/SEO validation

Evidence:

- QA evaluator runs browser data collection inside E2B with `qa_runner.py`, then backend evaluates visual video with LLM and links deterministically; accessibility shifted to synchronous axe-core in the HTML generation pipeline (`agent-context/architecture/quality-and-seo.md:10-24`, `agent-context/architecture/quality-and-seo.md:63-139`, `agent-context/architecture/quality-and-seo.md:224-294`).
- QA tool caches `qa_report.md`, distinguishes completed vs running placeholder vs stale running placeholder, and supports force rerun (`agent-context/architecture/quality-and-seo.md:31-44`).
- SEO analysis is read-only OpenCode (`Read`, `Glob`, `Grep`) with structured JSON validation and one retry; improvement is constrained to static metadata files and reruns analysis for before/after measurement (`agent-context/architecture/quality-and-seo.md:327-417`, `agent-context/architecture/quality-and-seo.md:421-464`).

### Evals and regression harnesses

Evidence:

- Orchestrator eval harness drives persona multi-turn simulations against the production orchestrator loop, captures traces, runs deterministic checks, and uses LLM judges for tone/drift/persona/goal plus optional handover fidelity (`backend/app/llm/orchestrator_agent/evals/README.md:1-31`).
- PR slash command workflow runs evals against a fresh Postgres service, comments results, uploads `report.json`, `report.html`, and trace artifacts, and pushes to a dashboard (`backend/app/llm/orchestrator_agent/evals/README.md:68-84`, `.github/workflows/run-orchestrator-eval.yml:154-231`).
- Evals stub sub-agent LLM calls and external deployment/OpenCode surfaces so orchestration code and persisted preconditions remain real while avoiding Vercel/sandbox LLM spend (`backend/app/llm/orchestrator_agent/evals/README.md:225-296`).
- Deterministic checks cover required/forbidden tools, skill ordering, UI blocks, arg fragments, verbatim handover preservation, reference resolution, adjective injection, and JSONPath assertions (`backend/app/llm/orchestrator_agent/evals/deterministic.py:1-20`, `backend/app/llm/orchestrator_agent/evals/schemas.py:82-160`).
- Coding-agent evals run real edit prompts against fixture apps and judge in parallel with deterministic validation plus Claude Code/Playwright visual review (`backend/app/llm/coding/evals/README.md:1-4`, `backend/app/llm/coding/evals/README.md:112-129`).
- Scheduled coding evals run nightly/default apps, upload artifacts/screenshots, and publish dashboard data without cancelling in-progress nightly runs (`.github/workflows/scheduled-evals.yml:1-58`, `.github/workflows/scheduled-evals.yml:105-183`).

### Institutional regression memory

Evidence:

- `agent-context/patterns.md` indexes high-frequency failure families such as vercel-deployment, llm-response-handling, sandbox-file-sync, observability, Celery, Metronome billing, sandbox-secret-leak, etc., with area-specific context maps (`agent-context/patterns.md:7-107`).
- This codifies recurring production defects into searchable investigation entry points rather than relying only on tests.

---

## Cross-cutting design constraints and production risks

1. **Prefer durable state over in-memory state for correctness.** Durable examples: Celery SQL result backend, `generation_jobs`, `message_queue`, `workflow_events`, `meter_events`, domain/GSC rows. In-memory examples are used only for best-effort throttles/caches (`fork-preview`, tracked background tasks).
2. **Background work must be tracked if correctness depends on it.** GSC/video/telemetry hold strong task refs; some file-sync calls are bare `asyncio.create_task`, so failures may only surface through logs.
3. **Fail-open is deliberate but should be visible.** Credit checks and feature flags favor uptime; cost dashboards and Metronome reconciliation are needed to detect abuse/drift after the fact.
4. **Distributed rate limiting is incomplete.** Fork-preview cooldown is bounded and useful but explicitly per-process, not global.
5. **Authz has strong write-path checks but known read-stream gaps.** Chat send is owner/collaborator gated; SSE subscription still has an acknowledged TODO.
6. **CI covers many mechanical invariants.** The strongest non-test guards are task-placement enforcement, `set -x` leak ban, prompt linting, secret scan, and eval workflows for LLM behavior regressions.
