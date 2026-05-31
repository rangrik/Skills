# Engineering Principles — Binding Contract

_Derived from the architecture research in this directory (`backend-platform.md`, `llm-orchestrator.md`, `frontend.md`, `app-template-sandbox.md`, `cross-cutting.md`, `architecture-patterns-study-guide.md`). Scope: the Kite / Appsmith v2 platform — the FastAPI modular monolith, the LLM orchestration system, the React product app, the generated-app template, the E2B sandbox runtime, and the surrounding deployment, billing, observability, and quality layers._

## How to read this document

This document has two parts.

**Part 1 — The Principle Catalogue.** Every design principle the platform is built around, named and explained once. A *principle* here means a heuristic or value that guides design decisions — not an architecture, an architectural pattern, or a framework. Where a principle is commonly realised through a known pattern (layered architecture, adapter, mediator, state machine, circuit breaker, and so on), the pattern is named so the principle stays concrete, but the entry itself describes the underlying principle.

**Part 2 — The Component Map.** Each meaningful part of the product — the orchestrator, the agents, the sandbox, the routes, the database layer, billing, deployment, the frontend, and so on — listed against the exact principles it follows, with a one-line note on how.

The intent is a shared, exhaustive reference so that every engineer and every agent making a change to this platform is working from the same set of design commitments.

---

# Part 1 — The Principle Catalogue

The principles are grouped into eight themes. Numbering is stable; Part 2 refers to principles by number.

## Theme I — Structure & Boundaries

**1. Separation of concerns through strict layering.**
Each layer of the system has one job and only talks to the layer directly beneath it. The platform backend is layered as routes → services → database modules → models/schemas; the generated-app backend layers Fastify composition → plugins/services/repositories → Drizzle/Postgres; the frontend layers routes → data (entity folders) → pages → components. A change to one concern (HTTP shape, business rule, persistence, rendering) should be possible without disturbing the others.

**2. Thin edges, thick core.**
The outermost adapters stay deliberately small and do no business logic. HTTP routes parse and delegate; orchestrator tools validate input, call one primary callee, and translate the result; Celery tasks are wrappers; the generated frontend scaffold delegates almost everything to platform packages. Logic of substance lives in services, agents, and routines — the "core" — never in the edges.

**3. High cohesion.**
Code that changes together lives together. The frontend groups everything for one entity into a single folder (`api.ts`, `queries.ts`, `types.ts`, `handlers.ts`, `factories.ts`); each LLM skill is a self-contained directory with its `SKILL.md`, tools, and references; backend persistence for one domain lives in one database module. A reader should find all of a concern in one place.

**4. Loose coupling.**
Components depend on each other as little as practical, and through stable seams rather than by reaching into internals. Subsystems communicate through typed contracts, durable events, and queues — not direct cross-module state access. The orchestrator and its specialist agents never call each other directly; they communicate through tool results and persisted state. Network boundaries are avoided where code boundaries suffice (this is a modular monolith, not microservices), but the module boundaries are still real.

**5. Single source of truth.**
Every fact, contract, and piece of grammar has exactly one authoritative home, and everything else is derived from it. The OpenAPI spec generates types and client hooks; `TOOL_NOTIFICATION_ACTIONS` is the one registry of tool notifications; `ToolResult`/`ToolError` is the one tool-output envelope; canonical-URL precedence lives in one small function; platform runtime behaviour lives in versioned packages, not copied into each app; feature-flag defaults live in one place. Duplicated truth is treated as a defect.

**6. Single responsibility — one reason to change.**
A module, service, tool, skill, or component should have one primary responsibility. One concern per skill; one primary callee per tool; deterministic business logic in services, not in prompts or tools. When a unit accumulates multiple reasons to change, it is a candidate to split.

**7. Explicit, typed contracts.**
Interfaces between parts of the system are written down and type-checked, never implied. Pydantic schemas for API and event payloads, strict TypeScript on the frontend, the `ToolResult` contract, the OpenAPI spec, generated API clients, SQLAlchemy models verified against the live schema. The boundary between two components is a typed artefact.

**8. A shared, explicit vocabulary.**
The system names its own categories and applies the names consistently. The module taxonomy — Service, LLM Routine, Agent, Tool, Skill — has precise definitions, and every unit of code is classifiable into exactly one. Stable port conventions, consistent route-module naming, consistent entity-folder file names. Shared vocabulary makes the architecture legible and reviewable.

## Theme II — Abstraction Discipline

**9. YAGNI — earn every abstraction.**
Build for the requirements that exist, not the ones imagined. Hard-code constants until real variability appears; remove unused parameters; write specific code before generalising; add flexibility only for a real use case, a real environment difference, or real user configuration. Abstraction is a cost paid only when it is justified — this is especially important because AI-assisted code sprawls easily.

**10. Progressive disclosure.**
Detail is loaded only when it is needed, never all at once. LLM skills are loaded on demand via `invoke_skill` rather than living in the always-on system prompt; deep reference files are read only when a skill needs them; frontend routes load their data as they are entered; SSE events update only the caches they touch. The default state is minimal; depth is pulled in just-in-time.

**11. Isolate external dependencies behind adapters.**
Third-party providers are wrapped behind a local seam so their details are contained and they remain swappable. The billing adapter abstracts Metronome/Stripe; the feature-flag service abstracts PostHog; the telemetry wrapper abstracts Langfuse; the canonical-URL service hides precedence logic. Provider-specific quirks must not leak across the platform.

**12. Convention over configuration.**
Where a consistent convention removes boilerplate, prefer the convention. Backend routes are auto-discovered from `*_routes.py`; the Celery worker auto-discovers tasks; entity data folders follow a fixed file layout; shared dependency aliases (`SettingsDep`, `AsyncSessionDep`) encode wiring once. Predictable structure replaces repetitive wiring.

**13. Centralise and version shared behaviour; never copy it.**
Behaviour used by many consumers lives in one versioned, publishable place so a fix reaches every consumer through a dependency bump rather than a manual migration. Platform infrastructure was deliberately extracted from the generated-app scaffold into versioned `kite-template-*` packages for exactly this reason. Copy-paste of platform behaviour is rejected as unmaintainable.

## Theme III — State & Correctness

**14. Durable state for correctness; memory only for speed.**
Anything whose loss would cause incorrect behaviour is persisted to durable storage — Postgres, EFS, Git, or the billing/deploy providers. Messages, workflow events, tasks, generation jobs, queue state, domains, drafts, checkpoints, failed billing events, and generated files are all durable. In-memory state is permitted only for best-effort caches, throttles, and UI performance — never as the final word on truth.

**15. Idempotency by design.**
An operation that runs twice must not cause harm twice. Idempotency keys on generation jobs, provider transaction IDs on billing events, webhook/event de-duplication, "create-or-return-existing" semantics, partial unique indexes on queue positions, and idempotent credit grants. Any operation that can be retried or redelivered is designed to be safely repeatable.

**16. Model long or external flows as resumable state machines.**
Multi-step work that crosses process boundaries or external services is not a single blocking call; it is an explicit sequence of states that commits each transition and can resume from where it stopped. Domain purchase (`pending → purchased → setup → active`), Search Console verification, and generation jobs all work this way. A crash mid-flow leaves a recoverable state, not a corrupt one.

**17. Make transaction and ownership boundaries explicit.**
Who opens, commits, and rolls back a transaction is a deliberate, documented decision. Database modules flush and leave the commit to the caller; request-scoped sessions commit at dependency teardown before the response is sent; queue dispatch and drain commit internally and say so; and a route or service commits explicitly when state must be durable before a background/Celery task reads it in a separate session, where the teardown commit would fire too late. Sessions are cancellation-safe so a cancelled request or task cannot contaminate the connection pool.

**18. Persisted contracts stay backward-compatible.**
Once data is written, future code must still be able to read it. Stored workflow events are reconstructed into typed models and must remain decodable across schema evolution; compatibility validators absorb field changes. Schema changes are sequential, idempotent migrations, verified against the models at startup. You may evolve a schema; you may not strand the rows already written under the old one.

## Theme IV — Reliability & Scale

**19. Do slow and fallible work asynchronously, with backpressure.**
The request path stays fast; long-running or failure-prone work is pushed onto queues and workers, and bursts are absorbed rather than dropped. Celery handles generation and orchestration jobs; a database-backed per-app message queue serialises chat bursts when an orchestrator turn is already active; deployment side effects run as tracked background tasks. The user-facing request never blocks on work that can be deferred.

**20. Choose fail-open vs fail-closed deliberately.**
For every subsystem it is a conscious, documented decision whether a failure should still allow the action (fail-open) or block it (fail-closed). Availability-favouring paths fail open — credit checks pass during a billing-provider outage, feature flags fall back to Creator-level defaults. Security-critical paths fail closed — auth, SSRF host checks, protected-file checks. The unacceptable state is failing in an undecided direction.

**21. Bound every retry; define terminal states.**
Retries are finite, spaced with backoff, and end in an explicit terminal state. Celery deploy-skew retries, E2B operation retries, Metronome backoff honouring `Retry-After`, Search Console stepped backoff into `retry_exhausted`, generation-job retry caps. There is no unbounded retry and no silent infinite loop; exhaustion is itself a defined outcome.

**22. Bootstrap deterministically and self-heal.**
Startup verifies its own preconditions and repairs what it can rather than booting into a broken state. The backend applies migrations and verifies schema-in-sync on startup; the sandbox bootstrap prechecks required files, regenerates process config, and exits with a known code if generated files are missing so the backend can recover; stale-template sandboxes are killed and recreated; missing billing customers self-heal. A clean boot is a checked boot.

**23. Scale on observed pressure, not fan-out.**
Autoscaling and load decisions read a cheap, durable pressure signal rather than broadcasting to every worker. KEDA scales on queue backlog computed from Redis `LLEN` across the workflow and generation queues; Celery `inspect`-style pidbox broadcast was deliberately abandoned because it saturated the broker. Measure the queue, not the workers.

**24. Contain blast radius; isolate failure.**
A failure in one part must not cascade into the rest. Each generated app runs in its own isolated E2B sandbox; circuit breakers guard flaky dependencies; queues, ring buffers, and subscriber queues are bounded; per-app and per-thread scoping limits how far a fault can spread. Isolation boundaries are designed in, not hoped for.

**25. Cancellation is cooperative and idempotent.**
Stopping work is a first-class, well-behaved operation. Cancellation is checked cooperatively at safe checkpoints and can also race a cancel-watch that interrupts mid-tool; remote sandbox processes are killed on cancel; the terminate finaliser is idempotent — it writes synthetic tool responses for orphaned calls and can run more than once safely. Cancelled work ends in a clean, consistent state.

## Theme V — Security

**26. Defense in depth.**
Security never rests on a single control. Authentication, route-level internal auth, HMAC-verified webhooks, SSRF host allowlists, sandbox firewalling, secret-poor processes, agent prompt rules, dangerous-request screening, protected-file globs, output redaction, and CI secret scanning are layered so that one bypassed control still leaves others standing.

**27. Least privilege.**
Every process, token, and agent is given the minimum access it needs. Public-facing sandbox processes are kept secret-poor; master secrets are injected per-command, not into the long-lived process environment; the metadata-proxy port is firewalled to loopback; the local token-count endpoint exists so an Anthropic key never needs to enter the sandbox; agents may only write inside permitted file globs. Capability is granted narrowly and revoked by default.

**28. Make trust boundaries explicit and guarded.**
The system knows exactly where trusted and untrusted zones meet, and guards each crossing. The sandbox-agent boundary is mediated by one metadata proxy; platform identifiers reach tools through hidden request-scoped context, never as model-supplied arguments; internal routes are separated from public ones; iframe bridge messages are filtered by source. A boundary that is not named cannot be defended.

**29. Never trust model or user input — validate, screen, redact.**
Input from an LLM, an agent, or an end user is treated as untrusted until proven otherwise. Tool arguments are schema-validated; dangerous proxy/credential/server requests are screened and refused; untrusted content is passed via environment variables rather than shell interpolation; tool outputs are sanitised of internal metadata and redacted of host/path/env details before re-entering the model context.

**30. Secure by default; never leak secrets.**
The default posture is closed and quiet. Secrets are never logged — `set -x` is banned in CI because it leaks into process logs; comparisons of tokens and signatures are constant-time; webhooks are HMAC-verified; sandbox paths, env-var names, ports, and internal tool names are kept out of agent-visible output. Exposure is opt-in and justified, never accidental.

## Theme VI — Observability & Cost

**31. Observability is built in and correlatable.**
Every unit of work can be traced from user action to outcome. A request ID, application ID, and user identity flow through context variables, OTel baggage, structured logs, and Celery metadata so a single user action can be followed through thread, message, worker, sandbox, and LLM call. Observability is part of the design of each path, not instrumentation added afterwards.

**32. One unified telemetry and billing pipeline.**
All LLM usage — backend inline calls and sandbox CLI calls alike — converges on a single telemetry-and-billing path, with one provider treated as the source of truth for cost, and failures stored locally for retry. There is one pipeline, not one per call site.

**33. Treat cost as a design constraint.**
Spend is engineered, not discovered. Billing events are idempotent and de-duplicated; markup is applied in one place; cost-drift monitors compare provider invoices against telemetry; CI jobs that invoke LLMs are time-capped to prevent runaway spend. Cost is a property the design is responsible for.

## Theme VII — Quality & Change Safety

**34. Prefer deterministic validation over judgment.**
Whenever a check can be made mechanical, it is. TypeScript typecheck, Ruff and basedpyright, Pydantic validation, SQL schema verification, generated OpenAPI code, axe-core accessibility, link checkers, deterministic eval assertions. LLM judges are used only where deterministic validation genuinely cannot reach. Determinism is the first choice; judgment is the fallback.

**35. Codify institutional memory.**
Hard-won knowledge becomes a durable, searchable artefact rather than living in people's heads. Recurring failure classes are written up as context maps and indexed; each one points at golden-path files. A bug that recurred once is documentation waiting to be written.

**36. Tests and evals are part of the architecture.**
Verification is designed alongside the feature, not bolted on. Conventional unit and route tests, orchestrator and coding-agent eval harnesses with persona simulations and deterministic checks, runtime QA and SEO validation, scheduled regression evals. The test and eval surface is a first-class component of the system.

**37. Record significant decisions.**
Architectural decisions are written down with their rationale and their rejected alternatives. Decision records capture *why* platform packages were extracted, *why* the Next.js overlay model was chosen, *why* a dispatcher routes platform routes. Future changes start from recorded intent, not guesswork.

## Theme VIII — Agentic-System Principles

These specialise the principles above for the LLM/agent parts of the platform, which are themselves first-class product components.

**38. Hub-and-spoke orchestration through a single mediator.**
One orchestrator agent owns the user conversation and is the only component that decides what happens next; specialised agents, routines, and services own implementation detail and never coordinate each other directly. This is the mediator principle: all coordination flows through one well-understood hub, keeping the spokes independent and replaceable.

**39. Context economy — the context diet.**
Whatever enters a model's context window is treated as a scarce, costed resource. The always-on system prompt carries only flow rules and a skill catalogue; skill bodies load on demand; history is trimmed past thresholds; internal metadata is stripped from tool results before they re-enter context. Minimising context is a deliberate, ongoing discipline, not an afterthought.

**40. Capability gating — least privilege for agents.**
An agent can do only what its current phase and unlocked skills permit. Skill-gated tools stay hidden until the relevant skill is invoked; tool visibility is filtered by workflow phase; coding tools are unavailable before a design is selected. An agent's power expands only as the task legitimately requires it.

**41. Skill-first extension.**
New capability is added at the lowest-power layer that can carry it. Prefer extending or adding a skill (instructions and routing) before writing new code; move deterministic logic into services and tools; reserve agent/loop code for genuinely iterative work. The question for any new capability is "can a skill do this?" before "what code do I write?".

**42. Funnel external integration through single chokepoints.**
Each class of external interaction has exactly one runner or proxy. One OpenCode CLI runner, one metadata proxy for all sandbox coding CLIs, one LLM service through which all chat/completion calls route for tracking and billing. A single chokepoint is where validation, telemetry, security, and fallback are enforced once.

**43. Parallelise independent work.**
Work with no dependency between its parts runs concurrently. Independent tool calls execute together with `asyncio.gather`; non-null design slots generate in parallel; batch image generation runs many images at once; background tasks handle naming, DB init, screenshots, and telemetry off the critical path. Sequential execution is reserved for genuine dependencies.

---

# Part 2 — The Component Map

Each meaningful part of the product is listed below against the exact principles it follows. Principle numbers refer to Part 1.

## 1. Backend HTTP Routes

_The thin HTTP adapter edge of the platform API (`backend/app/routes/*_routes.py`)._

- **1 — Separation of concerns.** The top layer; they accept a request and delegate downward, never reaching past services into persistence.
- **2 — Thin edges.** Parse, validate, authorize, delegate to **one** service, shape the response — where "shape" is a field-to-field map of that one service's typed result, never multi-source enrichment, envelope decoding, or untyped-dict re-parsing at the edge. No business logic and no side-effects (analytics, background-task spawn) from the handler. Error translation is part of shaping: map known service exceptions to specific statuses with a static `detail` and let everything else bubble to the centralized 500 handler — never a broad `except Exception`, never `str(e)` in client-facing `detail`. `fork_routes` is the reference shape; `analytics_routes` for error handling (see `docs/rules/error-handling.md`).
- **5 — Single source of truth.** Object-level ownership is resolved through the one centralised `has_access()` / scoped `website_service.get_website` (owner or active collaborator), not re-derived per handler.
- **7 — Typed contracts.** Request, response, and event bodies are Pydantic schemas (`extra="forbid"` only on the inputs that must be strict — not the norm). Responses declare an explicit `response_model=` / typed return, never `-> dict`, `response_model=None`, or an inline dict literal, and never echo user/owner identifiers; `slack_routes` is the reference shape (schema-less file/HTML/redirect edges are documented `-> Response` deviations).
- **8 — Shared vocabulary.** Consistent `*_routes.py` naming and `APIRouter(prefix=..., tags=...)` structure.
- **12 — Convention over configuration.** Auto-discovered from `routes/*_routes.py`; no manual registration.
- **28 — Trust boundaries.** Public and internal routes are explicitly separated; internal routes carry their own bearer/JWT/TOTP auth. A caller-supplied resource id (`application_id`/`thread_id`) is untrusted input: authentication is not authorization, so a resource-scoped handler must bind that id to the caller through the centralized ownership gate — the scoped `website_service.get_website` or `has_access()` (P5) — not resolve it unscoped.

## 2. Backend Services

_The deterministic business-logic core (`backend/app/services/`)._

- **1 — Separation of concerns.** The middle layer; they orchestrate database modules and provider adapters.
- **2 — Thick core.** Substantive logic lives here, not in routes, tools, or prompts.
- **6 — Single responsibility.** Each service is scoped to one domain (website, deployment, billing, domain).
- **9 — YAGNI.** The backend conventions codify minimalism — hard-coded constants until variability is real, specific code before premature abstraction.
- **11 — Adapter isolation.** Provider details are wrapped — billing adapter, telemetry wrapper, feature-flag service, canonical-URL service.
- **16 — Resumable state machines.** Domain purchase and GSC verification are committing, resumable flows.
- **20 — Deliberate fail-open/closed.** Credit checks fail open on provider outage; security and SSRF checks fail closed.

## 3. Database Modules & Models

_The persistence layer — query/write modules (`backend/app/database/`) over SQLAlchemy models (`backend/app/models/`)._

- **1 — Separation of concerns.** Only services call into them; they own CRUD and queries exclusively.
- **5 — Single source of truth.** Canonical-row selection is centralised; model definitions are the schema's authoritative shape.
- **7 — Typed contracts.** Modern `Mapped[]` / `mapped_column()` models; the live schema is verified against them at startup.
- **14 — Durable state.** Postgres is the home of all correctness-critical state.
- **17 — Transaction boundaries.** Modules flush and leave commits to the caller; sessions are cancellation-safe.
- **18 — Backward-compatible contracts.** Sequential, idempotent migrations; the timestamptz doctrine; startup schema-sync verification.

## 4. Application Startup / Lifespan

_The composition root — `make_app()`, `lifespan()`, and the worker bootstrap._

- **1 — Separation of concerns.** One place assembles process-wide singletons, middleware, and routes.
- **12 — Convention over configuration.** Route and worker task discovery happen here without manual wiring.
- **22 — Deterministic bootstrap & self-heal.** Applies migrations, verifies schema-in-sync, sweeps zombie tasks, and drains queues on boot.
- **24 — Blast-radius containment.** Initialises Redis-backed circuit breakers.
- **31 — Observability built-in.** Initialises OTel before middleware and routes; installs request-id middleware.

## 5. The LLM Orchestrator Agent

_The central conversation agent — the hub of the agentic system._

- **38 — Hub-and-spoke.** Owns the user conversation and is the only component that decides what happens next.
- **2 — Thin edges.** Delegates all implementation to specialised agents, routines, and services.
- **10 — Progressive disclosure.** Loads skill bodies via `invoke_skill` only when a task needs them.
- **39 — Context economy.** Static prompt plus a dynamic skill catalogue; trims history past thresholds; strips internal metadata from tool results.
- **40 — Capability gating.** `get_filtered_tools()` hides skill-gated tools and phase-gates coding tools until a design is selected.
- **28 — Trust boundaries.** Receives platform identifiers through hidden `workflow_context`, never as model-supplied arguments.
- **25 — Cooperative cancellation.** Checkpoint cancellation plus a cancel-watch; an idempotent terminate finaliser.
- **43 — Parallelism.** Executes independent tool calls concurrently with `asyncio.gather`.

## 6. Specialised Agents

_Implementation-owning agents — coding/website-change, QA, SEO/discoverability, design generation, platform router._

- **38 — Hub-and-spoke.** They are the spokes; invoked through orchestrator tools, never coordinating each other.
- **6 — Single responsibility.** Each owns exactly one capability.
- **4 — Loose coupling.** They communicate via tool results and persisted state, not direct calls.
- **21 — Bounded retry.** Model fallback chains trigger only on model-unavailable, and are bounded.
- **24 — Blast-radius containment.** They run inside isolated sandboxes.
- **34 — Deterministic validation.** The coding agent runs typecheck preflight; the SEO agent validates JSON output with a single retry; the platform router uses `tool_choice="required"` with a safe `ForwardToOrchestrator` fallback.

## 7. Tools

_Thin callable adapters exposed to agents (`orchestrator_agent/tools/`, `skills/*/tools/`)._

- **2 — Thin edges.** Validate input, delegate to one primary callee, translate the result.
- **6 — Single responsibility.** One primary callee; no accumulated business logic.
- **7 — Typed contracts.** Every tool returns the `ToolResult` / `ToolError` envelope.
- **5 — Single source of truth.** Notifications are declared in `TOOL_NOTIFICATION_ACTIONS`; registration fails fast without an entry.
- **29 — Never trust input.** Tool arguments are schema-validated; dangerous proxy/credential/server requests are screened and refused.

## 8. Skills

_Reusable markdown instruction bundles (`SKILL.md` plus tools and references)._

- **10 — Progressive disclosure.** Bodies load on demand; deeper reference files are read only when needed.
- **3 — High cohesion.** Each skill is a self-contained directory.
- **6 — Single responsibility.** One concern per skill.
- **41 — Skill-first extension.** The preferred place to add capability before writing new code.
- **5 — Single source of truth.** Frontmatter `description` is the one input to the system-prompt skill catalogue.

## 9. Sandbox–Agent Boundary

_The metadata proxy and the single OpenCode CLI runner mediating sandbox coding CLIs._

- **28 — Trust boundaries.** One mediated crossing between the sandbox and platform/providers.
- **42 — Single chokepoint.** One metadata proxy for all sandbox CLIs; one OpenCode runner.
- **27 — Least privilege.** A local token-count endpoint means no Anthropic key needs to enter the sandbox.
- **29 / 30 — Validate and redact.** Protected-file globs block edits to config/server/proxy files; host/path/env details are redacted from output.
- **32 — Unified telemetry.** The proxy posts all usage onto the single telemetry-and-billing pipeline.

## 10. E2B Sandbox Runtime

_Isolated per-app compute for generation, editing, preview, and QA._

- **24 — Blast-radius containment.** One isolated sandbox per generated app.
- **22 — Deterministic bootstrap & self-heal.** Startup prechecks required files, regenerates PM2 config, and exits with code 64 to trigger backend recovery rather than booting incomplete.
- **27 — Least privilege.** Secret-poor PM2 processes; `blockedSecrets`; master secrets injected per-command.
- **26 — Defense in depth.** The metadata-proxy port is firewalled to loopback with iptables drop rules.
- **8 — Shared vocabulary.** Stable port conventions (3001, 4321, 8080, 8787, iteration ranges).
- **14 — Durable state.** Files are synced to EFS and committed to a git repo so diffs survive.

## 11. Generated App Template & Platform Packages

_The runtime scaffold for customer websites (`app-template`, `nextjs-template`, `kite-template-*`)._

- **13 — Centralise & version shared behaviour.** Platform infrastructure was extracted into versioned packages so fixes ship by dependency bump, not per-app migration.
- **2 — Thin edges.** Generated app roots stay small and declarative, delegating to platform packages.
- **5 — Single source of truth.** The OpenAPI spec generates types; `OpenAPIServiceHandlers` is the only home for business routes.
- **1 — Separation of concerns.** Fastify composition → plugins/services/repositories → Drizzle/Postgres.
- **34 — Deterministic validation.** Build-time JS syntax validation, typecheck preflight, and OpenAPI codegen reduce model drift.

## 12. Celery & Background Workers

_The long-running-work substrate._

- **19 — Async with backpressure.** Long and fallible work is pushed off the request path onto queues.
- **21 — Bounded retry.** `max_retries`, `autoretry_for`, `retry_backoff`, and deploy-skew retries with a cap.
- **15 — Idempotency.** Generation-job idempotency keys; `acks_late` for safe redelivery.
- **23 — Scale on pressure.** KEDA scales on queue backlog read from Redis `LLEN`, not worker fan-out.
- **25 — Cooperative cancellation.** `terminate=True` is documented as insufficient; cooperative cancellation is the source of truth.
- **31 — Observability.** OTel context is propagated into workers; task metadata is persisted; Prometheus metrics are exposed.

## 13. Realtime Eventing

_Workflow events, Postgres `LISTEN/NOTIFY`, the per-app message queue, and SSE._

- **14 — Durable state.** `workflow_events` is a durable event log; queue state is persisted.
- **19 — Async with backpressure.** The per-app message queue serialises chat bursts, returning HTTP 202 with a queue position.
- **15 — Idempotency.** `FOR UPDATE SKIP LOCKED` draining and a partial unique position index prevent double-dispatch.
- **24 — Blast-radius containment.** Subscriber queues and dedup ring buffers are bounded.
- **18 — Backward-compatible contracts.** Stored events are reconstructed into typed models across schema evolution.
- **10 — Progressive disclosure.** SSE events update only the caches they touch.

## 14. Billing & Credits

_Usage billing, payments, and credit gates._

- **11 — Adapter isolation.** `BillingAdapter` abstracts Metronome and Stripe behind one seam.
- **15 — Idempotency.** Event and transaction IDs prevent double-charges; credit grants are idempotent.
- **20 — Deliberate fail-open.** Credit checks fail open during provider outages; HTTP 402 is raised only on a real non-positive balance.
- **32 — Unified telemetry & billing.** Usage converges on one pipeline with Metronome as the source of truth.
- **33 — Cost as a constraint.** Markup is applied once; failed events are stored for retry; cost-drift monitors run on a schedule.
- **22 — Self-heal.** `ensure_billing_setup()` recreates missing billing customers.

## 15. Deployment & Domains

_Vercel deploys, custom domains, DNS, Search Console, and canonical URLs._

- **16 — Resumable state machines.** Domain purchase and GSC verification commit each transition and can resume.
- **19 — Async / best-effort.** Deploys run `--prod --no-wait`; side effects are tracked background tasks; clients poll for status.
- **5 — Single source of truth.** Canonical-URL precedence lives in one small function.
- **21 — Bounded retry.** Transient CLI/API retries; GSC stepped backoff into a terminal state.
- **22 — Self-heal.** Vercel projects are reused or recreated by stable project ID.
- **37 — Recorded decisions.** The Next.js overlay and scaffold-pruning model is captured in decision records.

## 16. Authentication & Authorization

_WorkOS sessions, internal auth, and collaboration/ownership checks._

- **26 — Defense in depth.** Sealed sessions, route-level internal auth, and HMAC-verified webhooks are layered.
- **28 — Trust boundaries.** A global auth dependency with an explicit excluded-path list separates public from internal.
- **30 — Secure by default.** Constant-time token and signature comparison; HMAC-verified webhooks.
- **27 — Least privilege.** Internal tokens are scoped; sensitive internal routes add TOTP-style checks.
- **5 — Single source of truth.** Ownership is resolved through one centralised `has_access()` (owner or active collaborator).

## 17. Observability Stack

_Langfuse, OTel, Prometheus, structured logs, and product analytics._

- **31 — Observability built-in.** Request ID, application ID, and user identity are threaded through logs, traces, and OTel baggage.
- **32 — Unified telemetry.** Inline backend and sandbox LLM usage converge on one logging-and-billing pipeline.
- **5 — Single source of truth.** One telemetry wrapper; Langfuse groups traces by application.
- **24 — Blast-radius containment.** The OTel exporter backs off after collector failures to avoid retry storms.
- **33 — Cost as a constraint.** Provider invoices are reconciled against telemetry to catch cost drift.

## 18. Frontend Product App

_The authenticated React / Vite product UI._

- **1 — Separation of concerns.** Layered as routes → data (entity folders) → pages → components.
- **3 — High cohesion.** Entity data folders colocate `api`, `queries`, `types`, `handlers`, and `factories`.
- **5 — Single source of truth.** Query-key factories; TanStack Query as the single server-state authority.
- **7 — Typed contracts.** Strict TypeScript; typed router search-param validation.
- **4 — Loose coupling.** SSE events are routed through an event bus to entity handlers, not by components mutating caches directly.
- **10 — Progressive disclosure.** Routes load their data on entry.
- **20 — Deliberate fail-closed.** `useCanAccessFeature` fails closed; route guards gate on backend-provided roles.
- **28 — Trust boundaries.** Iframe bridges filter incoming messages by source.

## 19. CI, Quality Gates & Evals

_The change-safety surface._

- **34 — Deterministic validation.** Lint, typecheck, schema checks, generated-code gates, and secret scanning.
- **36 — Tests and evals as architecture.** Backend tests, orchestrator and coding-agent eval harnesses, and scheduled regression evals.
- **35 — Institutional memory.** Incident context maps are indexed and linked to golden-path files.
- **30 — Secure by default.** The `set -x` ban and a Trivy secret-scan PR gate.
- **8 — Shared vocabulary.** CI enforces task-placement and import conventions.
- **33 — Cost as a constraint.** CI jobs that invoke LLMs are time-capped to prevent runaway spend.

---

## Component coverage summary

| Component | Core principles |
| --- | --- |
| Backend HTTP Routes | 1, 2, 5, 7, 8, 12, 28 |
| Backend Services | 1, 2, 6, 9, 11, 16, 20 |
| Database Modules & Models | 1, 5, 7, 14, 17, 18 |
| Application Startup / Lifespan | 1, 12, 22, 24, 31 |
| LLM Orchestrator Agent | 2, 10, 25, 28, 38, 39, 40, 43 |
| Specialised Agents | 4, 6, 21, 24, 34, 38 |
| Tools | 2, 5, 6, 7, 29 |
| Skills | 3, 5, 6, 10, 41 |
| Sandbox–Agent Boundary | 27, 28, 29, 30, 32, 42 |
| E2B Sandbox Runtime | 8, 14, 22, 24, 26, 27 |
| Generated App Template & Packages | 1, 2, 5, 13, 34 |
| Celery & Background Workers | 15, 19, 21, 23, 25, 31 |
| Realtime Eventing | 10, 14, 15, 18, 19, 24 |
| Billing & Credits | 11, 15, 20, 22, 32, 33 |
| Deployment & Domains | 5, 16, 19, 21, 22, 37 |
| Authentication & Authorization | 5, 26, 27, 28, 30 |
| Observability Stack | 5, 24, 31, 32, 33 |
| Frontend Product App | 1, 3, 4, 5, 7, 10, 20, 28 |
| CI, Quality Gates & Evals | 8, 30, 33, 34, 35, 36 |
