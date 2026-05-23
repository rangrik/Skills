# Kite/Appsmith v2 Architecture Patterns and Study Guide

Researched: 2026-05-23  
Scope: whole repository: platform backend, LLM/orchestrator system, frontend product app, generated app template, sandbox runtime, deployment/ops, billing, auth, observability, QA/evals, and institutional engineering practices.

This document is intended as a durable artifact for learning the architecture this project is **trying** to follow. Some patterns are broken or in transition in parts of the codebase; those are called out separately so you can distinguish aspiration from legacy/local exceptions.

Companion deep-dive artifacts created during research:

- `architecture-research/backend-platform.md`
- `architecture-research/llm-orchestrator.md`
- `architecture-research/frontend.md`
- `architecture-research/app-template-sandbox.md`
- `architecture-research/cross-cutting.md`

## 0. One-sentence answer

Kite is primarily a **modular monolith** with **clean/layered architecture**, an **event-driven real-time UX**, **Celery/Redis asynchronous background workers**, and a specialized **agentic orchestration architecture** where an LLM orchestrator uses thin tools, skill-gated progressive disclosure, provider adapters, sandboxed code agents, deterministic services, and evals to generate, edit, deploy, and operate production websites.

It is not a classic microservices product. It is closer to:

> A FastAPI modular monolith + React SPA + generated-site runtime + E2B sandbox platform, glued by durable database state, Postgres notifications, Celery queues, and LLM agent/tool/skill boundaries.

## 1. Product/system mental model

The product takes a user from conversation to a generated, editable, deployable website.

The major subsystems are:

| Product area | Architectural role | Main evidence/files |
| --- | --- | --- |
| Platform backend | API, auth, persistence, orchestration, workers, deployment, billing, domains | `backend/app/{routes,services,database,models,schemas}`, `backend/AGENTS.md` |
| Frontend app | Authenticated product UI, chat, preview, design selection, editing, billing, analytics | `frontend/src/routes.tsx`, `frontend/src/data`, `frontend/src/pages/AppDetails` |
| LLM orchestrator | Central conversation agent; delegates side effects through tools/skills | `backend/app/llm/orchestrator_agent` |
| LLM routines/agents | Design generation, website editing, QA, SEO, image/logo, memory, scraping | `backend/app/llm/*`, `backend/app/llm/skills/*` |
| Generated app template | Runtime scaffold for customer websites | `app-template`, `nextjs-template`, `packages/kite-template-*` |
| E2B sandbox runtime | Isolated execution/edit/preview/QA/code-agent environment | `e2b`, `backend/app/services/e2b_service.py`, `sync_files_service.py` |
| Realtime channel | Persisted + ephemeral workflow events to SSE and channel adapters | `workflow_events`, Postgres `LISTEN/NOTIFY`, `frontend/src/data/Chat` |
| Deployment/domain layer | Vercel deploys, custom domains, DNS, GSC, canonical URLs, Pirsch | `deployment_service.py`, `vercel_deploy_service.py`, `domain_service.py` |
| Billing/credits | Metronome usage billing, Stripe payments, credit gates | `billing_adapter.py`, `credit_service.py`, `meter_event_service.py` |
| Observability/cost | Langfuse, OTel, Prometheus, Segment, PostHog, Mixpanel, Loki | `langfuse_service.py`, `otel_utils.py`, `celery_metrics.py` |
| Regression memory | Tests, eval harnesses, decision records, incident context maps | `backend/tests`, `frontend/src/**/*.test.*`, `backend/app/llm/*/evals`, `agent-context` |

## 2. The top-level architectural pattern

### 2.1 Modular monolith, not microservices

The backend is one deployable FastAPI application plus Celery worker processes. It has many modules, but most product behavior lives in one codebase and one primary database. The modules are separated by code boundaries rather than network boundaries.

Why this is maintainable here:

- Fast iteration: product, LLM orchestration, billing, deployment, and chat state can be changed together.
- Strong transactional consistency: app/thread/message/workflow/billing/domain state all live in Postgres.
- Lower operational overhead than many microservices while the product is still evolving quickly.
- Multiple worker processes can scale the expensive/long-running work without splitting domain ownership into services.

The modular monolith boundary is visible in:

- `backend/app/routes` — HTTP adapters.
- `backend/app/services` — deterministic business logic and provider adapters.
- `backend/app/database` — query/write modules.
- `backend/app/models` — SQLAlchemy ORM models.
- `backend/app/schemas` — Pydantic request/response/event schemas.
- `backend/app/llm` — LLM routines, agents, tools, and prompt/skill systems.

### 2.2 Layered/Clean Architecture inside the monolith

The intended platform backend shape is:

```text
HTTP route / orchestrator tool / Celery task
        ↓
Service / LLM routine / Agent
        ↓
Database module / external provider adapter / sandbox runner
        ↓
SQLAlchemy models, Postgres, filesystem/EFS, third-party APIs
```

The repo explicitly states this in `backend/README.md` and `backend/AGENTS.md`:

- Routes handle HTTP request/response and minimal validation.
- Services own business logic and orchestration.
- Database modules own CRUD/query operations.
- Models represent DB schema.
- Schemas represent API/event contracts.

This is not pure textbook Clean Architecture because framework types and direct imports appear in many places. But the aspiration is clear: **thin edges, thick services, explicit persistence modules, typed contracts.**

### 2.3 Event-driven + queue-backed architecture for responsiveness

The user experience is real-time and long-running. The system avoids blocking synchronous request/response flows by using:

- Celery queues for long-running orchestrator/generation/background jobs.
- Server-side message queue when the orchestrator is busy.
- Postgres `workflow_events` table as durable event log.
- Postgres `LISTEN/NOTIFY` to fan out changes to SSE connections.
- Ephemeral `workflow_events_ephemeral` for high-frequency transient stream chunks.
- Frontend EventSource + event bus + React Query cache updates.

The main pattern is:

```text
User sends message
  → backend persists message / starts or queues orchestrator work
  → orchestrator/tool/worker publishes workflow events
  → Postgres NOTIFY wakes SSE subscribers
  → frontend EventSource receives events
  → frontend event bus routes events to entity cache handlers
  → UI updates without polling/refetching everything
```

This is a pragmatic event-driven architecture: not Kafka/event sourcing, but durable enough for missed-event replay and live UX.

## 3. Backend architecture patterns

### 3.1 Routes as adapters/controllers

Backend routes are intended to be thin HTTP adapters.

Patterns to preserve:

- Use `APIRouter(prefix=..., tags=...)`.
- Validate request schemas with Pydantic.
- Delegate to services.
- Keep route logic small; translate only expected domain errors to HTTP status codes.
- Let unexpected exceptions bubble to generic error handling unless the route has a specific reason to catch.

Examples and areas:

- `website_routes.py` delegates website creation/deploy/status to services.
- `chat_routes.py` is more complex because it coordinates send authz, queues, cancellation, SSE, and credits.
- `payment_routes.py`, `domain_routes.py`, `gsc_routes.py` are provider-heavy route surfaces and should still delegate domain behavior to services.

Learning topics:

- FastAPI dependency injection.
- Pydantic v2 models and `ConfigDict`.
- HTTP error mapping.
- API boundary design.

### 3.2 Services own deterministic business logic

The backend intentionally distinguishes **Service** from **LLM Routine** and **Agent**.

A service is deterministic non-LLM business logic:

- DB coordination.
- Validation.
- External API calls.
- File sync.
- Deployment steps.
- Billing setup.
- Domain state transitions.

Examples:

- `website_service.py` — website/thread creation and app initialization.
- `deployment_service.py` — publication orchestration.
- `vercel_deploy_service.py` — direct Vercel project/env/CLI integration.
- `domain_service.py` — domain purchase/connection state machine.
- `credit_service.py` — credit grant/check/self-healing.
- `meter_event_service.py` — LLM usage telemetry + billing.
- `e2b_service.py` — sandbox lifecycle.
- `workflow_event_service.py` — durable event publishing.
- `message_queue/*` — serialized chat backlog.

Principle: if something is deterministic and reusable, it should not live in an orchestrator tool or prompt.

### 3.3 Database modules isolate persistence

The intended shape is function-based DB modules that accept an `AsyncSession`, perform specific queries/writes, flush if needed, and leave transaction ownership to the caller.

Key ideas to study:

- SQLAlchemy async sessions.
- Explicit transaction boundaries.
- `flush()` vs `commit()`.
- `SELECT FOR UPDATE SKIP LOCKED` for safe queue draining.
- Partial unique indexes for queued message positions/idempotency.
- Timestamptz/timezone-aware datetime rules.
- Schema migrations as source of truth.

Important files:

- `backend/app/utils/db_session.py`
- `backend/app/database/website_db.py`
- `backend/app/database/thread_db.py`
- `backend/app/database/celery_task_db.py`
- `backend/app/database/workflow_event_db.py`
- `backend/app/migrations/*.sql`

### 3.4 Startup/lifespan as composition root

`backend/app/__init__.py` is the process composition root. It owns:

- DB migrations and schema verification.
- Workflow notification listener startup.
- Channel dispatchers.
- Analytics/PostHog lifecycle.
- Redis circuit breakers.
- Zombie task sweeper.
- Queue drain sweeper.
- OTel instrumentation.
- Route auto-discovery.
- Middleware.

Study topic: **composition root** — a central place that wires dependencies and process-wide lifecycle, rather than hiding startup side effects throughout the codebase.

### 3.5 Celery task wrapper as infrastructure pattern

Celery is not used raw everywhere. The repo has a wrapper in `celery_host_service.py`.

The wrapper provides:

- Async task enforcement.
- Pydantic-compatible keyword validation.
- Task metadata propagation (`application_id`, `thread_id`, user context).
- OTel trace propagation.
- Deployment-skew retry when old workers receive new tasks.
- DB result backend metadata.
- Queue routing.
- KEDA backlog metric support.

Pattern: **centralize infrastructure policy in a wrapper** so every task gets the same serialization, tracing, retries, and metadata.

Learning topics:

- Celery/Redis.
- Late acknowledgements.
- Time limits and cooperative cancellation.
- Result backends.
- Worker autoscaling with KEDA.
- Avoiding Celery `inspect`/pidbox at scale.

### 3.6 State machines and saga-like flows

Several product flows interact with external systems where partial failure is normal. The code usually models them as resumable state machines rather than one-shot functions.

Examples:

- Domain purchase: `pending → purchased → setup → active`.
- GSC verification: pending/retry/exhausted/verified states.
- Generation jobs: `pending → in_progress → success/failed` with idempotency keys and retry counts.
- Message queue: `queued → sending → sent/failed` plus drain suspension.
- Deployment status: queued/building/deploying/ready mapped from Vercel.
- Draft lifecycle: create/apply/undo/discard/abandoned.

Study topics:

- Saga pattern.
- Idempotent external integrations.
- Retriable state transitions.
- Compensating actions.
- Durable job state.

### 3.7 Adapter/Strategy pattern for providers

Provider-specific logic is supposed to sit behind service/adapters:

- Billing: `BillingAdapter`, `MetronomeBillingAdapter`, `MockBillingAdapter`.
- Feature flags: `feature_flag_service` wraps `posthog_service`.
- LLMs: `llm_service` and model fallback chains.
- Telemetry: `telemetry_service` wraps Langfuse.
- Background removal: multiple providers.
- Logo extraction: direct image, CDN probe, Firecrawl, Brandfetch.
- Deployment/domain providers: Vercel, Resend, Entri, Google Search Console.

Pattern: hide volatile external APIs behind internal contracts.

Study topics:

- Adapter pattern.
- Strategy pattern.
- Ports and adapters / hexagonal architecture.
- Provider fallback chains.
- Circuit breakers and retries.

## 4. LLM/orchestrator architecture patterns

This is the most unique part of the project.

### 4.1 Explicit taxonomy: Service vs LLM Routine vs Agent vs Tool vs Skill

The backend docs define a canonical vocabulary:

| Term | Intended meaning |
| --- | --- |
| Service | Deterministic non-LLM logic. |
| LLM Routine | Single bounded LLM call, no tool loop. |
| Agent | Tool-using loop or delegated iterative tool process. |
| Tool | Thin adapter exposed to an agent; validates and delegates to one callee. |
| Skill | Reusable markdown instruction bundle loaded on demand. |
| Infrastructure | Shared LLM/provider/loop/CLI plumbing. |

This taxonomy is critical. It prevents “everything with AI” from becoming a giant prompt or unstructured agent.

When contributing, ask:

1. Is this deterministic? Put it in a service.
2. Is this one LLM call with a schema? Make it an LLM routine.
3. Does it need iterative tools? Make it an agent.
4. Is this instruction/grammar/process knowledge? Put it in a skill.
5. Is it just exposing a service/routine/agent to the orchestrator? Make a thin tool.

### 4.2 Orchestrator as central hub / mediator

The orchestrator owns the user conversation. It decides what to do next and calls tools. It should not directly implement every capability.

Flow:

```text
process_chat_message()
  → build workflow context and history
  → run_orchestrator_agentic_loop()
      → select visible tools
      → call model with streaming
      → persist assistant/tool call message
      → execute tools in parallel
      → sanitize tool results
      → persist tool results
      → repeat until no more tools or return_direct UI
  → publish final events / checkpoint if needed
```

Architectural patterns:

- Mediator/orchestrator pattern.
- Tool-use agent loop.
- Hidden workflow context via `ContextVar` rather than LLM-visible arguments.
- Parallel tool execution for independent side effects.
- `ToolResult` as typed envelope.
- Sanitization boundary before tool outputs re-enter LLM context.

### 4.3 Progressive disclosure via skills

The orchestrator does not load every capability instruction all the time. Instead:

- Global system prompt contains core behavior and a skill catalog.
- Skill descriptions come from `SKILL.md` frontmatter.
- `invoke_skill` loads detailed skill body only when needed.
- Skill-gated tools remain hidden until the skill is invoked.
- Successful skill unlocks are rehydrated across turns from message history.

This is a maintainability and scaling pattern for LLM systems:

- Reduces prompt bloat.
- Keeps external-system grammar in one place.
- Allows capability-specific instructions to evolve independently.
- Reduces accidental tool use.

Study topics:

- Prompt architecture.
- Progressive disclosure.
- Tool gating.
- Retrieval/injection of instructions.
- Context-window management.

### 4.4 Thin tools and typed results

Orchestrator tools should:

1. Validate input.
2. Pull platform IDs from workflow context.
3. Delegate to exactly one primary service/routine/agent.
4. Return `ToolResult` with status/data/error.
5. Avoid UI notification publishing directly.
6. Avoid embedding business logic or external grammar.

This is basically **controller-adapter pattern for LLM tools**.

### 4.5 External-system grammar belongs in skills

The repo has a strong guardrail:

> External-system grammar — URL parts, API parameters, hostnames, escape rules, query DSLs — should not be duplicated in prompts/helpers/generated strings when it can live in a single probe-tested skill.

Examples:

- Cloudinary URL construction skill and validator.
- Image generation/edit recipes.
- HTML generation validation scripts.
- Next.js generation scripts.

Study topics:

- Why LLMs are bad at exact grammar without tools.
- Single source of truth for external APIs.
- Validator-backed prompting.
- Skills as operational runbooks for agents.

### 4.6 Sandbox agent boundary

Website creation/editing uses sandboxed coding agents, not direct backend file mutation.

Pattern:

```text
orchestrator tool
  → website create/edit service
  → ensure app files + sandbox
  → sync EFS files to E2B
  → run OpenCode/coding agent in sandbox
  → parse NDJSON/events/result
  → sync changed files back to EFS
  → checkpoint / screenshot / publish SSE
```

Important boundaries:

- Backend orchestrator sees typed summaries/results, not arbitrary sandbox logs.
- Sandbox agents are restricted by protected file globs and working directories.
- Secrets are not broadly injected into public PM2 processes.
- Metadata proxy handles model-provider traffic and telemetry.
- Sandbox can run browser/QA/code tools near the generated app.

Study topics:

- Sandboxing and least privilege.
- Remote execution boundaries.
- File synchronization design.
- Process supervision with PM2/Caddy.
- Agent permission models.

### 4.7 LLM fallback and reliability patterns

LLM calls use:

- Primary + fallback model chains.
- JSON parse retry with model feedback for structured output.
- Same-model retry for transient pre-stream errors.
- Streaming retry only before first chunk to avoid duplicated content.
- Provider-specific model selection by task type.
- Explicit evals and deterministic tests around failure modes.

Study topics:

- Resilient LLM application design.
- Structured output validation.
- Model routing by task.
- Cost/latency/reliability tradeoffs.

### 4.8 Evals as architecture, not afterthought

This repo treats LLM behavior as something that needs regression tests.

Layers:

- Unit tests for tool filtering, skill rehydration, stream handling, termination, OpenCode parsing.
- Orchestrator evals for multi-turn and scripted historical cases.
- Coding-agent evals for real edit prompts against fixture apps.
- LLM judges where deterministic checks are insufficient.
- Agent-context incident maps for recurring bug families.

Study topics:

- Evaluation-driven development for LLM products.
- Deterministic assertions vs LLM judges.
- Replay harnesses.
- Golden datasets.

## 5. Website generation/design architecture patterns

### 5.1 Pipeline architecture

The generation pipeline is mostly a staged pipeline, with some stages collapsed in the newer architecture.

Conceptual flow:

```text
requirements / conversation / uploaded assets / memory
  → brand/content/sitemap/visual design context
  → 3 design iterations
  → user selects one
  → generated app enters edit state
  → future edits use coding agent
  → publish/deploy
```

The current HTML path uses an OpenCode/Gemini generation flow that produces complete designs in parallel. The Next.js path uses a plan/generate/validate skill.

### 5.2 Parallel design iteration pattern

The product generates three design options. This is an architectural product pattern, not just UI:

- Three slots are explicit in the `generate_designs` tool.
- Each design has independent requirements/variation instructions.
- Designs are generated in parallel.
- Incremental SSE updates publish design cards as they complete.
- Iterations are persisted so historical design rounds survive on-disk cleanup.

Study topics:

- Parallel fan-out/fan-in workflows.
- Partial success handling.
- User choice as a product state transition.

### 5.3 Next.js plan/generate/validate pattern

Next.js generation is intentionally more deterministic:

1. `plan_files.py` — decide files and image manifest.
2. `generate_files.py` — generate all planned files and images.
3. `validate_files.py` — run TypeScript validation.
4. Allow one recovery action after validation failure.

This is a strong pattern for LLM codegen:

- Planning separates structure from code emission.
- Image URLs are predetermined to avoid model-authored URL drift.
- Typecheck is a hard deterministic validator.
- Template invariants protect platform-owned files.

Study topics:

- Plan-then-execute LLM workflows.
- Static validation in generation loops.
- Template invariants.
- Controlled recovery loops.

### 5.4 Workpad + memory as persistent context

The platform uses two kinds of long-lived context:

| Mechanism | Purpose |
| --- | --- |
| `workpad.json` on EFS | Current app/site build requirements and working state. |
| Mem0 memories | Longer-term user/app facts, preferences, constraints, content decisions. |

The workpad is app-local and concrete. Memory is semantic/searchable and scoped by user/app.

Study topics:

- Short-term vs long-term memory in AI apps.
- Scoped semantic retrieval.
- Memory extraction/observer agents.
- Avoiding unbounded prompt history.

## 6. Frontend architecture patterns

### 6.1 React SPA with typed router and server-state authority

The frontend is a Vite React TypeScript SPA.

Core stack:

- React 19.
- TanStack Router.
- TanStack Query.
- Zustand.
- Tailwind CSS v4.
- Radix/shadcn-style UI primitives.
- MSW + Vitest.

The key architectural separation:

```text
routes.tsx       → route tree, auth guards, search-param validation
src/data/*       → API calls, queries, types, transformers, handlers, factories
src/pages/*      → route components and page-specific orchestration
src/components/* → shared reusable UI primitives/components
src/lib/*        → integrations, bridges, API client, analytics, hooks
```

### 6.2 Entity data folders

Each backend entity should have a folder under `frontend/src/data/<Entity>` with:

- `api.ts` — raw HTTP calls.
- `queries.ts` — TanStack Query hooks/keys/mutations.
- `types.ts` — TypeScript API shapes.
- `transformers.ts` — pure data transformations.
- `factories.ts` — mock test data.
- `handlers.ts` — MSW handlers.
- `index.ts` — barrel exports.

This is a **feature/entity module pattern**. It scales better than dumping all API calls into one file.

### 6.3 Three-layer state model

Frontend state is intentionally split:

| State type | Tool | Examples |
| --- | --- | --- |
| Server state/cache | TanStack Query | apps, threads, messages, billing, flags, domains |
| URL/navigation state | TanStack Router search params | app id, draft id, preview path, code file/table |
| Local ephemeral UI state | Zustand/context | preview UI, grab mode, pending edits, modal state |

Study topics:

- Server state vs client state.
- Query invalidation and cache updates.
- URL as state.
- Avoiding prop drilling.

### 6.4 Frontend event bus for realtime updates

SSE events do not directly mutate random UI components. They flow through:

```text
EventSource
  → parser/deduper/frame batcher
  → ChatEventBus
  → domain-specific handlers
  → TanStack Query cache
  → UI re-renders from cache
```

This decouples transport from state mutations.

Important details:

- Ring buffer dedupes event IDs.
- Conversation updates are batched per animation frame.
- `thread_id` guard prevents draft cross-contamination.
- Domain handlers live with entities (`Thread`, `Application`, `AppCode`).

Study topics:

- Event bus pattern.
- Client-side cache normalization/updates.
- SSE/EventSource.
- Real-time UI consistency.

### 6.5 Component architecture and design system

Components are categorized:

| Component type | Location | Rule |
| --- | --- | --- |
| Global reusable UI | `src/components` | Generic, prop-driven, no page business logic. |
| Primitive/library wrappers | `src/components/ui` | Radix/shadcn-based primitives. |
| Page-specific components | `src/pages/<Page>/components` | Feature-specific logic and data. |

Design-system principles:

- Semantic Tailwind tokens instead of raw colors.
- `surface-*` utilities for containers.
- `bg-*` tokens for fills inside containers.
- Foreground hierarchy tokens (`text-fg`, `text-fg-emphasis`, `text-fg-subtle`).
- Responsive interaction primitives: desktop popover/modal, mobile bottom sheet/fullscreen.
- Accessibility via semantic HTML, ARIA, Radix primitives, visible labels, keyboard support.

Study topics:

- Design systems.
- Semantic tokens.
- Accessibility.
- Responsive interaction patterns.
- Component API design.

### 6.6 Iframe bridge capability pattern

The preview/editor UI injects capabilities into generated-app iframes:

- Scroll bridge.
- Scroll restore bridge.
- URL change bridge.
- Overscroll control bridge.
- Grab/edit bridge.
- PostHog/Mixpanel replay bridges.

Pattern:

- Each bridge is self-contained.
- Core runtime must not import external modules because it is stringified/injected.
- Capability object advertises name/version/code.
- Parent injects via `postMessage` when iframe signals readiness.

Study topics:

- Browser iframe boundaries.
- `postMessage` protocols.
- Capability injection.
- Cross-origin security.

## 7. Generated app/template architecture patterns

### 7.1 Generated apps are product artifacts with platform runtime packages

The generated website is not just raw output. It sits on a scaffold:

- `app-template` for Vite/Fastify HTML apps.
- `nextjs-template` for Next.js apps.
- `packages/kite-template-*` for shared platform runtime behavior.

The important architectural decision: **shared platform behavior should live in versioned packages, not copied generated app files**, so existing generated apps can receive fixes via dependency bumps rather than risky EFS migrations.

Packages:

- `@appsmithorg/template-frontend`
- `@appsmithorg/template-backend`
- `@appsmithorg/template-shared`

Study topics:

- Template/scaffold architecture.
- Runtime package extraction.
- Dependency versioning for generated artifacts.
- Backward compatibility.

### 7.2 Generated app backend uses Fastify plugin composition

`app-template/backend` uses:

- Fastify app composition.
- Decorated plugins/repositories/services.
- OpenAPI glue for business API handlers.
- Drizzle migrations.
- Static site fallback.
- Contact form route.

This is a smaller generated-app architecture separate from the platform backend.

Pattern: **composition root + plugins + OpenAPI-driven handlers**.

### 7.3 Generated app frontend delegates platform Vite behavior

The Vite generated app frontend is intentionally thin:

- `app-template/frontend/vite.config.js` calls `defineKiteConfig`.
- Platform Vite plugins live in `packages/kite-template-frontend`.
- Plugins provide script injection, content resolution, JS syntax validation, runtime error capture, analytics/meta injection, etc.

Pattern: keep generated app files minimal; move shared behavior into package code.

### 7.4 Marker-file branching during Vite → Next.js transition

The codebase is transitioning from HTML/Vite to Next.js. During transition:

- Every app may still be seeded with Vite scaffold because sandbox bootstrap expects it.
- Next.js iterations live under `iter1/iter2/iter3` during design phase.
- Selection overlays one Next.js iteration to the app root.
- Deployment prunes legacy Vite scaffold for Next.js roots.
- `next.config.js` acts as a layout marker.

This is a migration architecture pattern: keep old and new stack compatible through marker detection and careful pruning.

## 8. Sandbox/runtime architecture patterns

### 8.1 E2B sandbox as isolated compute boundary

E2B sandboxes provide per-app runtime environments for:

- Live preview.
- Generated app dev servers.
- Coding agents.
- Browser QA.
- SEO analysis/improvement.
- File sync.

Core runtime:

- PM2 supervises processes.
- Caddy routes public ports and iteration previews.
- Metadata proxy centralizes model-provider traffic.
- Firewall limits metadata proxy access.
- File sync uses zip-based copy + git state.
- Stable port conventions keep frontend/backend previews predictable.

Study topics:

- Remote sandboxes.
- Process supervision.
- Reverse proxies.
- File synchronization.
- Runtime secret isolation.

### 8.2 Stable public port convention

Important conventions:

- `3001` Fastify backend.
- `4321` main frontend/Next preview.
- `8080` public Caddy entry.
- `4401-4403` iteration preview ports.
- `4501-4503` Next.js iteration dev servers.
- `8787` metadata proxy.

These conventions are part of the architecture. Changing them is cross-cutting.

### 8.3 Secret-poor public processes

Sandbox startup intentionally avoids putting master secrets into PM2 child processes. Provider traffic is routed through metadata proxy and internal token mechanisms.

Pattern: **least privilege for runtime processes**.

Study topics:

- Secret isolation.
- Environment variable blast radius.
- Proxy patterns.
- Runtime hardening.

## 9. Deployment, domains, and publishing patterns

### 9.1 Deployment service as orchestration layer

Publishing converges on `deployment_service.create_deployment()`.

Flow:

1. Prepare URL/project.
2. Persist deployment URL.
3. Rewrite canonical/site URLs.
4. Sync changed files to sandbox if needed.
5. Initialize Pirsch analytics best-effort.
6. Execute Vercel deploy with build env.
7. Track analytics.
8. Poll status separately.
9. On READY, record video and submit sitemap/GSC if appropriate.

Pattern: **orchestrate side effects in a service, make slow external completion pollable/asynchronous**.

### 9.2 Canonical URL precedence pattern

Canonical URL is resolved centrally:

1. Connected custom domain.
2. User canonical override.
3. Deployment URL.

This avoids each caller inventing precedence rules.

Pattern: **single-purpose deterministic service for cross-cutting policy**.

### 9.3 Vercel project self-healing

The Vercel service tries multiple resolution strategies:

- Stored project ID.
- Local `.vercel/project.json`.
- Clean name lookup.
- Hashed name creation.
- Conflict recovery.
- Project settings patching on reuse.

Pattern: **external provider drift self-healing**.

### 9.4 Domain purchase/connection as resumable workflow

Domain flows use state machines and independent commits because Vercel/Resend/Entri/GSC can fail independently.

Study topics:

- DNS and domain lifecycle.
- External provider idempotency.
- Resumable workflows.
- Custom domain + SSL + email + GSC interaction.

## 10. Auth, authorization, collaboration, and channels

### 10.1 WorkOS sealed session auth

Auth uses WorkOS AuthKit OAuth code flow:

- Browser redirects to WorkOS.
- Backend callback exchanges code for sealed session.
- Sealed session stored in cookie.
- Global dependency validates on future requests.
- Expired JWTs refresh transparently.
- API routes return 401; non-API routes redirect.

Study topics:

- OAuth authorization code flow.
- Cookie sessions.
- Sealed/encrypted sessions.
- Auth middleware/dependencies.

### 10.2 Route-level internal auth and webhooks

Some routes are excluded from user auth and must authenticate themselves:

- Internal bearer token.
- WorkOS JWT fallback for internal tooling.
- TOTP-style internal token for some triage/download flows.
- HMAC webhooks for Vercel/WhatsApp/Slack/Stripe.

Pattern: **auth boundary differs by caller type**.

### 10.3 Collaboration and drafts

The app supports collaboration/drafts through:

- App owner vs collaborator access checks.
- Draft records and dedicated draft threads.
- Git branches/worktrees for isolated edits.
- Apply/undo/discard draft operations.
- Thread-scoped orchestrator locking.

Pattern: **branch/worktree isolation + thread-scoped conversation state**.

Study topics:

- Git worktrees as application versioning primitive.
- Collaboration access control.
- Isolated draft workflows.

### 10.4 Channel gateway architecture

The Channel Gateway supports WhatsApp/SMS/Slack-style conversational surfaces.

Pattern:

```text
Webhook
  → normalizer/dedup/user-session resolution
  → gateway intent classification/routing
  → orchestrator or platform operation
  → workflow events
  → dispatcher
  → channel adapter
```

Important principles:

- Channel-specific I/O hidden behind adapters.
- Incoming messages normalized into platform concepts.
- Outbound events consolidated into channel-friendly messages.
- Cross-worker dedup via Redis when possible.
- Channel sessions track active app per user/channel.

Study topics:

- Adapter pattern.
- Webhook idempotency.
- Multi-channel messaging architecture.
- Event-to-message consolidation.

## 11. Billing, usage metering, and cost architecture

### 11.1 Billing adapter pattern

Billing goes through `BillingAdapter`:

- Create customer.
- Create subscription.
- Create wallet.
- Send usage event.
- Get wallet balance.
- Top up wallet.
- Get usage by application.

Metronome is production; mock adapter is used for tests.

Pattern: **ports/adapters for critical vendor dependency**.

### 11.2 Credit wallet model

Credit grants have type/priority:

1. Signup credits.
2. Monthly paid credits.
3. Purchased credits.

Credit checks are performed before expensive work, but intentionally fail open on provider errors to preserve availability.

This is a product/architecture tradeoff:

- Availability > perfect enforcement during outages.
- Cost monitoring and billing retry pipelines must catch drift later.

### 11.3 Unified LLM usage telemetry and billing

Both backend LLM calls and sandbox CLI model calls converge into the same span pipeline:

```text
LLM call / sandbox proxy
  → ParsedOpenRouterSpan-style metadata
  → Langfuse trace/generation logging
  → Metronome usage event with idempotent transaction id
  → failed billing events persisted for retry
```

Pattern: **single metering pipeline across runtime surfaces**.

Study topics:

- Usage-based billing.
- Idempotent event ingestion.
- Cost attribution.
- LLM telemetry.

## 12. Observability architecture patterns

The project uses multiple observability backends, each with a clear purpose:

| Tool | Purpose |
| --- | --- |
| Langfuse | LLM trace/generation/cost metadata. |
| OpenTelemetry | Distributed traces across FastAPI/Celery/HTTPX/LangChain. |
| Prometheus | Worker metrics and queue backlog. |
| Grafana Loki/Alloy | Logs, including sandbox logs. |
| Segment | Product analytics. |
| PostHog | Feature flags and cohorts. |
| Mixpanel | Session replay. |
| Faro | Frontend error reporting. |

Architectural patterns:

- Request/application/user contextvars for log correlation.
- OTel trace propagation into Celery.
- Langfuse traces grouped by application id.
- Worker metrics tied to autoscaling.
- Fire-and-forget telemetry where user latency matters, but strong refs to tasks to avoid GC.

Study topics:

- Distributed tracing.
- Structured logging.
- Metrics vs traces vs logs.
- LLM observability.
- Cost monitoring.

## 13. Quality, QA, and regression architecture

### 13.1 Conventional tests

Backend:

- pytest.
- Async DB fixtures.
- Shared DB with `test_id` namespacing.
- Route/service/database/util tests.

Frontend:

- Vitest + jsdom.
- React Testing Library.
- MSW network mocks.
- Semantic queries.
- Colocated tests.

Generated app/template:

- Typecheck/build/test across workspaces.
- OpenAPI generation tests.

### 13.2 Runtime QA/SEO

QA evaluator:

- Browser data collection inside E2B sandbox.
- Deterministic link checks.
- LLM video evaluator for motion/design quality.
- Artifacts persisted for debugging.

SEO/discoverability:

- Read-only analysis agent.
- Structured JSON validation.
- Improvement agent constrained to SEO/static metadata files.
- Re-analysis after fix.

### 13.3 LLM evals

LLM features use eval harnesses:

- Orchestrator persona/simulated multi-turn evals.
- Scripted historical bug replay.
- Deterministic assertions for tool calls/UI blocks/arguments.
- LLM judges for tone/goal/fidelity where needed.
- Coding-agent edit evals.

### 13.4 Institutional memory

`agent-context` is an architectural asset:

- `patterns.md` indexes failure families.
- `context-maps/` summarize recurring fragile areas.
- `entries/` record fixes/investigations.
- `architecture/` has stable system references.
- Decision records explain why the system changed.

This is a **knowledge flywheel** architecture: incidents become context maps, which make future work faster and safer.

## 14. Cross-cutting principles the repo is aspiring to follow

### 14.1 Keep scope minimal / YAGNI

Backend docs explicitly prefer:

- Hard-coded constants until real variability exists.
- Removing unused parameters.
- Specific code before premature abstraction.
- Flexibility only for real use cases/environment differences/user configuration.

This matters because AI-heavy code can easily sprawl.

### 14.2 Single source of truth

Examples:

- Tool notifications centralized in `TOOL_NOTIFICATION_ACTIONS`.
- `ToolResult` as common tool envelope.
- Feature flag defaults centralized in constants/service.
- Canonical URL precedence centralized.
- Cloudinary grammar in a skill/validator.
- Generated app platform behavior in packages.
- Frontend entity API/query handlers colocated.

### 14.3 Progressive disclosure everywhere

Not just prompts:

- Skills loaded on demand.
- Frontend routes load data as needed.
- SSE events update only relevant caches.
- Template package behavior is imported by generated apps.
- Context maps are read on demand.

### 14.4 Durable state for correctness; memory only for optimization

Correctness-critical state goes to Postgres/EFS/Git/Metronome/Vercel:

- Messages/events/tasks/jobs/domains/drafts/checkpoints.
- Queue state.
- Billing event failures.
- App files and generated artifacts.

In-memory caches are used for best-effort throttles or UI performance, not final truth.

### 14.5 Idempotency and retry are first-class

Recurring mechanisms:

- Idempotency keys.
- Provider transaction IDs.
- External state-machine resumption.
- Duplicate webhook/event dedup.
- Retry with bounded backoff.
- Stale worker/sandbox recovery.

### 14.6 Fail open vs fail closed is a deliberate product choice

Examples:

- Credit checks often fail open on provider outage.
- Feature flags use Creator-level defaults to avoid locking out paid customers.
- Internal/shared tools should fail closed on auth.
- Security/SSRF/protected file checks should fail closed.

The important thing is to know which side each subsystem chooses.

### 14.7 Security in layers

Defense-in-depth layers:

- WorkOS sessions.
- Route-level internal auth.
- Webhook HMAC signatures.
- SSRF-safe fetches.
- Sandbox firewall.
- Secret-poor PM2 processes.
- Agent prompt rules.
- Dangerous request regexes.
- Protected file globs.
- Output redaction.
- CI secret scanning and `set -x` bans.

### 14.8 Validate with deterministic checks whenever possible

The repo prefers:

- TypeScript typecheck.
- Ruff/basedpyright.
- Pydantic schemas.
- SQL migrations/schema verification.
- Axe-core accessibility.
- Link checkers.
- OpenAPI generation.
- Cloudinary URL validator.
- `pnpm typecheck` for Next.js.

LLM judges are used when deterministic validation is insufficient.

## 15. Known pattern breaks / tensions to be aware of

These are not reasons to distrust the architecture; they are places to be careful.

| Area | Tension |
| --- | --- |
| Backend docs | Some README/context-map file paths are stale. Prefer source + current rule docs. |
| Imports | Docs prefer package-level imports, but direct module imports are common. Follow local precedent unless refactoring intentionally. |
| Services | Docs imply module-style services, but adapter/classes exist where lifecycle/provider state makes sense. |
| Feature flags | Most code uses `feature_flag_service`, but some code imports PostHog directly. |
| Error handling | Some routes catch generic exceptions and expose details despite stricter docs. |
| Chat SSE authz | Send path has strong authz; SSE subscription has a documented TODO for owner/collaborator gating. |
| Draft cancellation | Cancellation historically targets main thread; draft-thread cancellation has TODOs. |
| Internal debug route | Token debug route metadata exposure is risky if not ingress-blocked. |
| Celery metadata | `Task.with_metadata()` mutates wrapper state; avoid caching task instances. |
| Zombie sweeper | Some paths may still publish failures to imprecise thread despite `thread_id` migration. |
| Large modules | `vercel_deploy_service.py`, `e2b_service.py`, and some routes are large operational modules; review carefully. |
| Frontend style | Some `any`, enums, hardcoded colors remain; new code should follow current guide. |
| Frontend SSE | Event union/parser/listener/handlers have drift risk; update all together. |
| Iframe bridge | Some `postMessage('*')` usage relies on source filtering; origin handling should be reviewed for arbitrary origins. |
| Next.js transition | Vite scaffold remains load-bearing for Next.js sandbox bootstrap; do not remove casually. |
| Platform packages | Some exported package surfaces are dormant/not wired yet. |
| Rate limiting | Fork-preview wake throttling is per process, not distributed. |

## 16. What to study to contribute meaningfully

### Track A — Foundation: modular monolith + clean architecture

Learn:

- Layered architecture.
- Clean Architecture / Hexagonal Architecture.
- Ports and adapters.
- Repository/data mapper patterns.
- Dependency injection.
- Transaction boundaries.

Apply in this repo:

- Routes/tools stay thin.
- Services own deterministic logic.
- Provider-specific code gets adapters.
- DB modules own query shape.
- Schemas/types define contracts.

### Track B — Async backend and production Python

Learn:

- FastAPI async request lifecycle.
- SQLAlchemy async sessions.
- Pydantic v2.
- Celery and Redis.
- Cancellation handling.
- `asyncio.gather`, `create_task`, task references.
- Idempotency and retries.

Apply in this repo:

- Avoid sharing `AsyncSession` across parallel tasks.
- Be explicit about commits.
- Do not block event loop with sync SDK calls; use `asyncio.to_thread` where needed.
- Use the Celery wrapper, not raw Celery tasks.

### Track C — Event-driven UX

Learn:

- Server-Sent Events.
- Postgres `LISTEN/NOTIFY`.
- Event logs vs ephemeral events.
- Client-side event buses.
- Cache updates vs refetch.

Apply in this repo:

- Backend publishes typed `ChatStreamSSE` events.
- Frontend parser/types/handlers must stay in sync.
- Use `thread_id` guards for draft/collab isolation.

### Track D — LLM application architecture

Learn:

- Tool-using agents.
- Prompt architecture.
- Skill/progressive-disclosure systems.
- Structured outputs and validation.
- LLM evals.
- Model fallback and cost tradeoffs.
- Sandboxed code agents.

Apply in this repo:

- Use taxonomy: Service vs LLM Routine vs Agent vs Tool vs Skill.
- Put external grammar in skills with validators.
- Add deterministic eval cases for reported orchestrator/coding bugs.
- Keep tools as adapters.

### Track E — Frontend architecture

Learn:

- React 19.
- TanStack Router.
- TanStack Query.
- Zustand.
- MSW/Vitest/React Testing Library.
- Tailwind v4 semantic tokens.
- Radix accessibility primitives.
- `postMessage` iframe APIs.

Apply in this repo:

- Use entity data folders.
- Keep server state in Query.
- Use URL params for shareable navigation state.
- Use Zustand for complex local UI state.
- Prefer semantic tokens and responsive primitives.

### Track F — Generated app/runtime/sandbox

Learn:

- Vite and Next.js deployment differences.
- Fastify plugin architecture.
- OpenAPI-first handlers.
- PM2/Caddy process supervision.
- E2B or remote sandbox execution.
- File sync and Git checkpointing.
- Vercel CLI deployment.

Apply in this repo:

- Shared generated-site runtime behavior belongs in packages.
- Be careful with scaffold files because existing generated apps may depend on them.
- Keep E2B scripts and backend startup upload maps in sync.

### Track G — Security and operations

Learn:

- OAuth and session cookies.
- HMAC webhook verification.
- SSRF prevention.
- Secret management.
- Kubernetes/EKS/Helm/ArgoCD basics.
- KEDA autoscaling.
- OpenTelemetry/Prometheus/logs.
- Usage-based billing systems.

Apply in this repo:

- Know fail-open vs fail-closed boundaries.
- Add authz tests when touching chat/drafts/internal routes.
- Do not introduce sandbox listeners/secrets without security review.
- Preserve observability metadata.

## 17. Contribution checklist by change type

### Adding/changing a backend API

1. Add/update Pydantic schema.
2. Keep route thin.
3. Put business logic in service.
4. Put DB access in database module.
5. Add migration if schema changes.
6. Add route/service/db tests.
7. Consider authz and billing/feature flag implications.

### Adding/changing an orchestrator capability

1. Decide taxonomy: skill, tool, service, routine, or agent.
2. If instruction/grammar: skill.
3. If side effect: thin tool + service/agent.
4. Add `ToolResult` contract.
5. Register notification action.
6. Add tests for tool filtering/skill gating.
7. Add eval case for behavior regressions.
8. Avoid duplicating tool contracts in prompt + docstring + skill.

### Adding/changing frontend data flow

1. Add/update `src/data/<Entity>` API/types/queries/handlers/factories.
2. Use typed query keys.
3. Update SSE parser/types/handlers together if event-driven.
4. Add MSW tests.
5. Keep page state in URL/Query/Zustand according to ownership.

### Adding/changing generated-app behavior

1. Decide if it belongs in `packages/kite-template-*` or scaffold templates.
2. Preserve backward compatibility for existing generated apps.
3. Update app-template/nextjs-template and lockfiles if package versions change.
4. Update E2B and deployment packaging if runtime files change.
5. Run template code-quality checks.

### Adding/changing deployment/domain/billing/security code

1. Identify external provider contracts.
2. Use adapter/service boundaries.
3. Make operations idempotent and resumable.
4. Add retry/backoff where appropriate.
5. Add tests for provider failure modes.
6. Preserve telemetry/cost attribution.
7. Review fail-open/fail-closed behavior.

## 18. Quick code-reading map

Start here:

- `AGENTS.md` — repo-wide development rules.
- `agent-context/architecture/system-overview.md` — product/system overview.
- `backend/AGENTS.md` — backend conventions and taxonomy.
- `frontend/agents.md` — frontend conventions.
- `frontend/src/components/agents.md`, `frontend/src/data/agents.md`, `frontend/src/pages/agents.md` — frontend sub-area guides.
- `agent-context/architecture/*.md` — stable architecture maps.
- `backend/docs/rules/*.md` — backend rule docs.
- `docs/decisions/*.md` — historical design decisions.
- `agent-context/patterns.md` — recurring failure families.

Then follow the specific product area:

| If touching... | Read first |
| --- | --- |
| Chat/orchestrator | `system-overview.md`, `chat-and-conversation.md`, `backend/app/llm/orchestrator_agent`, `frontend/src/data/Chat` |
| Website generation | `generation-pipeline.md`, `design-value-chain.md`, `website_create_opencode`, `skills/html-generation`, `skills/nextjs-generation` |
| Editing | `editing-experience.md`, `coding/agent.py`, `website_change_agent`, `opencode_cli.py` |
| Frontend UI | `frontend/agents.md`, component/page guides, relevant page/data folder |
| Generated apps | `app-template`, `nextjs-template`, `packages/kite-template-*`, `e2b` |
| Deployment/domains | `deployment-and-domains.md`, `deployment_service.py`, `vercel_deploy_service.py`, `domain_service.py` |
| Billing | `billing-and-credits.md`, `billing_adapter.py`, `credit_service.py`, `meter_event_service.py` |
| Auth | `authentication.md`, `authentication_checker.py`, `workos_service`, route auth tests |
| Observability | `observability.md`, `otel_utils.py`, `langfuse_service.py`, `celery_metrics.py` |
| Images/logos | `image-and-logo-pipeline.md`, Cloudinary skill, image generator services |
| QA/SEO | `quality-and-seo.md`, QA evaluator, discoverability agents |
| Channels | `channel_gateway`, WhatsApp/Slack decisions/context maps |

## 19. Final mental model

If you remember only one thing, remember this:

> Kite’s maintainability strategy is to keep deterministic product logic in typed services, expose side effects to LLMs only through thin tools, load capability instructions progressively through skills, run generated-code work inside isolated sandboxes, persist correctness-critical state durably, and drive the frontend from typed server state plus event streams.

The project is production-grade not because every module is perfect, but because the architecture repeatedly applies the same survival patterns:

- durable state,
- explicit contracts,
- provider adapters,
- idempotent workflows,
- event-driven UI,
- sandbox isolation,
- progressive LLM context,
- deterministic validation,
- eval/regression capture,
- and operational observability.
