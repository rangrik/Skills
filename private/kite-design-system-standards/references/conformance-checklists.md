# Conformance Checklists — appsmith-v2 / Kite Platform

A review instrument for **conformance mode**. The standards themselves — the 43
principles and their rationale — live in `engineering-principles-contract.md`.
This file turns those principles into per-component yes/no review questions so a
review is mechanical and repeatable rather than dependent on what the reviewer
happens to remember.

## How to use this file

1. Identify which component(s) the code under review belongs to (the list below
   mirrors Part 2 of the contract).
2. Run that component's checklist. Each question is phrased so that **"yes" means
   conformant**.
3. Every **"no"** is a candidate deviation. Before flagging it, open the cited
   principle (`[P12]` → Principle 12 in the contract) and read the full entry —
   the principle text states the rationale and tells you whether a "no" is a real
   problem or a justified, deliberate exception.
4. A question that genuinely does not apply to this change is marked **N/A with a
   one-line reason** — never silently skipped. Silent omission is the failure
   conformance review exists to catch.

These questions are derived from the principles; they are not a substitute for
them. When in doubt, the contract is the source of truth.

## Component index

1. Backend HTTP Routes · 2. Backend Services · 3. Database Modules & Models ·
4. Application Startup / Lifespan · 5. LLM Orchestrator Agent ·
6. Specialised Agents · 7. Tools · 8. Skills · 9. Sandbox–Agent Boundary ·
10. E2B Sandbox Runtime · 11. Generated App Template & Platform Packages ·
12. Celery & Background Workers · 13. Realtime Eventing · 14. Billing & Credits ·
15. Deployment & Domains · 16. Authentication & Authorization ·
17. Observability Stack · 18. Frontend Product App · 19. CI, Quality Gates & Evals

A change often touches more than one component (e.g. a new endpoint backed by a
new service and a new table touches components 1, 2, and 3). Run every relevant
checklist.

---

## 1. Backend HTTP Routes — principles 1, 2, 5, 7, 8, 12, 28

- [ ] **[P1]** Does the route delegate downward to a service, never reaching past it into `database/` modules or models directly — including via a function-scoped `from app.database import ...` (a lazy import, even one tagged `# noqa: PLC0415`, is the same coupling, not an exception) or by importing model enums/constants to branch on at the edge (also a `[P2]` business-logic finding)?
- [ ] **[P2]** Is the handler limited to parsing, validation, authorization, one service call, and response shaping — where "response shaping" is a field-to-field map of that **single** service result, **not** multi-source assembly/enrichment — with no business logic and no side-effects (analytics emission, background-task spawn) at the edge?
- [ ] **[P2]** Does the handler let unexpected exceptions bubble to the centralized 500 handler — no broad `except Exception`-into-`HTTPException(500, detail=str(e))` wrap (which leaks the raw exception across the trust boundary), catching only to map a concrete service exception to a specific status (e.g. `ValueError`→400, `Timeout`/`Connection`→503), keeping any 500 `detail` a static message, and using `logger.exception` (not `logger.error`)? (per `docs/rules/error-handling.md`, which lists `detail=str(e)` under "What NOT to do"; exemplar `analytics_routes`)
- [ ] **[P7]** Are request, response, and event bodies declared as Pydantic schemas defined in `app/schemas` (not inline in the route module)? (`extra="forbid"` is a deliberate minority — its absence is **not** by itself a finding.)
- [ ] **[P7]** Is the **response** typed — an explicit `response_model=` / typed return, never `-> dict`/`dict[str, Any]`, `response_model=None`, or an inline dict literal — and does it never echo identifiers the caller didn't already own (`user_email`, `application_owner_email`, …)? (schema-less file/HTML/redirect edges are documented `-> Response` deviations; reference shape `slack_routes`)
- [ ] **[P7]** Does the called service hand back a **typed object** the handler maps field-to-field, rather than an untyped `dict[str, Any]` read with `.get()` + string-literal defaults?
- [ ] **[P8]** Does the file follow `*_routes.py` naming with a single `APIRouter(prefix=..., tags=[...])`?
- [ ] **[P12]** Is the router auto-discovered — no manual registration line added anywhere?
- [ ] **[P28]** Are internal routes kept explicitly separate from public ones, each carrying the correct auth dependency?
- [ ] **[P28]/[P5]** For every handler taking a caller-supplied resource id (`application_id`, `thread_id`, `message_id`, draft/website id), is that id bound to the caller before read or mutate — via the scoped `website_service.get_website` (`None`→404) or by resolving the owning `application_id` and calling `has_access()` (the `chat_routes._enforce_send_authz` pattern) — rather than `website_db.get_website(..., owner_email=None)`? (Being logged in is not authorization; a genuinely-public route is conformant only as a documented carve-out, as `preview_routes` does.)

## 2. Backend Services — principles 1, 2, 6, 9, 11, 16, 20

- [ ] **[P1]** Does the service orchestrate database modules and provider adapters without importing HTTP types (`APIRouter`, `HTTPException`)?
- [ ] **[P2]** Does the substantive business logic live here, rather than leaking up into routes or down into db modules, tools, or prompts?
- [ ] **[P6]** Is the service scoped to a single domain, with one clear reason to change?
- [ ] **[P9]** Is every abstraction, parameter, and configuration point earned by a real, present use case rather than a speculative one?
- [ ] **[P11]** Are third-party providers reached through a local adapter seam, not called directly?
- [ ] **[P16]** If the service drives a long or external multi-step flow, is it a committing, resumable state machine rather than one blocking call?
- [ ] **[P20]** For each failure path, is the fail-open vs fail-closed choice deliberate and matched to its risk (availability paths open, security paths closed)?

## 3. Database Modules & Models — principles 1, 5, 7, 14, 17, 18

- [ ] **[P1]** Are `*_db.py` modules called only by services, containing only CRUD and queries — no business logic, no schemas?
- [ ] **[P5]** Does each fact have one authoritative home (e.g. canonical-row selection is centralised, not re-derived in callers)?
- [ ] **[P7]** Do models use `Mapped[]` / `mapped_column()`, and will the live schema still verify against them at startup?
- [ ] **[P14]** Is all correctness-critical state persisted to Postgres, with memory used only for best-effort caches?
- [ ] **[P17]** Do db modules `flush()` and leave `commit()` to the caller, with transaction ownership explicit and sessions cancellation-safe?
- [ ] **[P18]** Are schema changes sequential, idempotent migrations that keep rows already written under the old schema readable?

## 4. Application Startup / Lifespan — principles 1, 12, 22, 24, 31

- [ ] **[P1]** Are process-wide singletons, middleware, and routes assembled in this one composition root?
- [ ] **[P12]** Does route and worker-task discovery happen automatically here, with no manual wiring?
- [ ] **[P22]** Does startup verify its own preconditions (migrations applied, schema in sync) and repair recoverable state instead of booting broken?
- [ ] **[P24]** Are isolation mechanisms such as circuit breakers initialised at boot?
- [ ] **[P31]** Is observability (OTel, request-id middleware) initialised before routes begin serving traffic?

## 5. LLM Orchestrator Agent — principles 2, 10, 25, 28, 38, 39, 40, 43

- [ ] **[P38]** Does the orchestrator remain the single component that decides what happens next, with specialists kept as independent spokes?
- [ ] **[P2]** Is all implementation delegated to specialised agents, routines, and services rather than done inline in the orchestrator?
- [ ] **[P10]** Are skill bodies loaded on demand via `invoke_skill`, not pinned into the always-on system prompt?
- [ ] **[P39]** Is everything entering the context window treated as costed — history trimmed past thresholds, internal metadata stripped from tool results?
- [ ] **[P40]** Are tools filtered by workflow phase and unlocked skills, so the agent's capability expands only as the task legitimately requires?
- [ ] **[P28]** Do platform identifiers reach tools through hidden request-scoped `workflow_context`, never as model-supplied arguments?
- [ ] **[P25]** Is cancellation cooperative (checked at safe checkpoints, plus a cancel-watch) with an idempotent terminate finaliser?
- [ ] **[P43]** Do independent tool calls execute concurrently (`asyncio.gather`) rather than serially?

## 6. Specialised Agents — principles 4, 6, 21, 24, 34, 38

- [ ] **[P38]** Is the agent invoked only through orchestrator tools, never coordinating other agents directly?
- [ ] **[P6]** Does the agent own exactly one capability?
- [ ] **[P4]** Does the agent communicate via tool results and persisted state, not direct calls into other agents?
- [ ] **[P21]** Are model fallback chains and retries bounded, ending in an explicit terminal state?
- [ ] **[P24]** Does the agent run inside an isolated sandbox so a failure cannot cascade?
- [ ] **[P34]** Does the agent lean on deterministic validation (typecheck preflight, schema validation, `tool_choice="required"` with a safe fallback) before trusting model output?

## 7. Tools — principles 2, 5, 6, 7, 29

- [ ] **[P2]** Does the tool validate input, delegate to one primary callee, and translate the result — with no accumulated business logic?
- [ ] **[P5]** Is every tool notification declared in `TOOL_NOTIFICATION_ACTIONS`, the one registry (registration should fail fast without an entry)?
- [ ] **[P6]** Does the tool have a single primary callee and one responsibility?
- [ ] **[P7]** Does the tool return the `ToolResult` / `ToolError` envelope?
- [ ] **[P29]** Are tool arguments schema-validated, and are dangerous proxy/credential/server requests screened and refused?

## 8. Skills — principles 3, 5, 6, 10, 41

- [ ] **[P10]** Does the skill load its body on demand, keeping deep reference files separate and read only when needed?
- [ ] **[P3]** Is the skill a self-contained directory (its `SKILL.md`, tools, and references colocated)?
- [ ] **[P6]** Does the skill cover exactly one concern?
- [ ] **[P41]** Was a skill considered as the lowest-power place to add this capability before reaching for new code?
- [ ] **[P5]** Is triggering driven solely by the frontmatter `description` (the one input to the system-prompt skill catalogue)?

## 9. Sandbox–Agent Boundary — principles 27, 28, 29, 30, 32, 42

- [ ] **[P28]** Is the sandbox↔platform crossing mediated by the single metadata proxy, with the trust boundary named explicitly?
- [ ] **[P42]** Does all sandbox-CLI traffic funnel through the one metadata proxy and one OpenCode runner?
- [ ] **[P27]** Does the sandbox receive only the minimum it needs (e.g. a local token-count endpoint so no Anthropic key enters the sandbox)?
- [ ] **[P29] / [P30]** Are protected config/server/proxy files blocked from edits, and are host/path/env details redacted from agent-visible output?
- [ ] **[P32]** Does the proxy post all sandbox LLM usage onto the single telemetry-and-billing pipeline?

## 10. E2B Sandbox Runtime — principles 8, 14, 22, 24, 26, 27

- [ ] **[P24]** Does each generated app run in its own isolated sandbox?
- [ ] **[P22]** Does the sandbox precheck required files, regenerate process config, and exit with a known code (rather than booting incomplete) when generated files are missing?
- [ ] **[P27]** Are sandbox processes kept secret-poor, with master secrets injected per-command rather than into the long-lived environment?
- [ ] **[P26]** Is the metadata-proxy port firewalled to loopback?
- [ ] **[P8]** Does the runtime use the stable port conventions (3001, 4321, 8080, 8787, iteration ranges)?
- [ ] **[P14]** Are sandbox files synced to EFS and committed to a git repo so diffs survive a restart?

## 11. Generated App Template & Platform Packages — principles 1, 2, 5, 13, 34

- [ ] **[P13]** Does shared platform behaviour live in a versioned `kite-template-*` package, reachable by a dependency bump — never copy-pasted into each app?
- [ ] **[P2]** Are generated app roots small and declarative, delegating to platform packages?
- [ ] **[P5]** Are types generated from the OpenAPI spec, with business routes living only in `OpenAPIServiceHandlers`?
- [ ] **[P1]** Does the generated backend keep the Fastify composition → plugins/services/repositories → Drizzle/Postgres layering?
- [ ] **[P34]** Is model-generated code gated by build-time JS syntax validation, typecheck preflight, and OpenAPI codegen?

## 12. Celery & Background Workers — principles 15, 19, 21, 23, 25, 31

- [ ] **[P19]** Is long-running or failure-prone work pushed onto a queue/worker rather than blocking the request path?
- [ ] **[P21]** Are retries bounded (`max_retries`, `autoretry_for`, `retry_backoff`) and ended in an explicit terminal state?
- [ ] **[P15]** Is the task idempotent (idempotency keys, `acks_late`) so a retry or redelivery does no double harm?
- [ ] **[P23]** Does autoscaling read a cheap, durable pressure signal (queue backlog via Redis `LLEN`) rather than broadcasting to workers?
- [ ] **[P25]** Is cancellation cooperative, rather than relying on `terminate=True` alone?
- [ ] **[P31]** Is OTel context propagated into the worker and task metadata persisted?

## 13. Realtime Eventing — principles 10, 14, 15, 18, 19, 24

- [ ] **[P14]** Is event and queue state persisted durably (the `workflow_events` log), not held only in memory?
- [ ] **[P19]** Are chat bursts serialised through the per-app message queue with backpressure (HTTP 202 plus a queue position)?
- [ ] **[P15]** Does queue draining use `FOR UPDATE SKIP LOCKED` and a partial unique position index to prevent double-dispatch?
- [ ] **[P18]** Can stored events still be reconstructed into typed models after schema evolution?
- [ ] **[P24]** Are subscriber queues and dedup ring buffers bounded?
- [ ] **[P10]** Do SSE events update only the caches they actually touch?

## 14. Billing & Credits — principles 11, 15, 20, 22, 32, 33

- [ ] **[P11]** Are Metronome and Stripe reached only through the `BillingAdapter` seam?
- [ ] **[P15]** Are billing events and credit grants idempotent, de-duplicated by event and provider transaction IDs?
- [ ] **[P20]** Do credit checks fail open during a provider outage, raising HTTP 402 only on a real non-positive balance?
- [ ] **[P32]** Does usage converge on the one telemetry-and-billing pipeline, with one provider as the source of truth for cost?
- [ ] **[P33]** Is markup applied in exactly one place, and are failed billing events stored for retry?
- [ ] **[P22]** Does missing billing setup self-heal (`ensure_billing_setup()`) rather than erroring?

## 15. Deployment & Domains — principles 5, 16, 19, 21, 22, 37

- [ ] **[P16]** Are domain-purchase and Search Console verification flows committing, resumable state machines?
- [ ] **[P19]** Do deploys run asynchronously (`--prod --no-wait`) with side effects as tracked background tasks and clients polling for status?
- [ ] **[P5]** Does canonical-URL precedence live in one small function?
- [ ] **[P21]** Are transient retries bounded, with stepped backoff into an explicit terminal state (e.g. `retry_exhausted`)?
- [ ] **[P22]** Are external projects (e.g. Vercel) reused or recreated by stable project ID rather than duplicated?
- [ ] **[P37]** Is any significant deployment-model decision captured in a decision record with its rationale and rejected alternatives?

## 16. Authentication & Authorization — principles 5, 26, 27, 28, 30

- [ ] **[P26]** Is auth layered (sealed sessions, route-level internal auth, HMAC-verified webhooks) so one bypassed control still leaves others standing?
- [ ] **[P28]** Is public vs internal separated by a global auth dependency with an explicit excluded-path list?
- [ ] **[P30]** Are token and signature comparisons constant-time, and are webhooks HMAC-verified?
- [ ] **[P27]** Are internal tokens scoped, with extra TOTP-style checks on sensitive internal routes?
- [ ] **[P5]** Is ownership resolved through the one centralised `has_access()` (owner or active collaborator)?

## 17. Observability Stack — principles 5, 24, 31, 32, 33

- [ ] **[P31]** Are request ID, application ID, and user identity threaded through structured logs, traces, and OTel baggage?
- [ ] **[P32]** Do inline backend and sandbox LLM calls converge on the one logging-and-billing pipeline?
- [ ] **[P5]** Is there one telemetry wrapper, rather than instrumentation re-implemented per call site?
- [ ] **[P24]** Does the OTel exporter back off after collector failures to avoid retry storms?
- [ ] **[P33]** Are provider invoices reconciled against telemetry to catch cost drift?

## 18. Frontend Product App — principles 1, 3, 4, 5, 7, 10, 20, 28

- [ ] **[P1]** Is the code in the right layer — routes → data (entity folders) → pages → components?
- [ ] **[P3]** Does everything for one entity live in one folder with the fixed file layout (`api`, `queries`, `types`, `handlers`, `factories`)?
- [ ] **[P5]** Is server state owned solely by TanStack Query, with query keys produced by query-key factories?
- [ ] **[P7]** Is the code strictly typed, including typed router search-param validation?
- [ ] **[P4]** Do SSE updates flow through the event bus to entity handlers, rather than components mutating caches directly?
- [ ] **[P10]** Do routes load their own data on entry rather than over-fetching upfront?
- [ ] **[P20]** Do feature-access checks fail closed (`useCanAccessFeature`), gating on backend-provided roles?
- [ ] **[P28]** Do iframe bridges filter incoming messages by source?

## 19. CI, Quality Gates & Evals — principles 8, 30, 33, 34, 35, 36

- [ ] **[P34]** Is the change covered by deterministic gates (lint, typecheck, schema verification, generated-code checks) rather than judgment alone?
- [ ] **[P36]** Is verification — unit/route tests and/or eval harnesses — designed alongside the feature rather than bolted on afterward?
- [ ] **[P35]** Are recurring failure classes written up as indexed context maps linked to their golden-path files?
- [ ] **[P30]** Is secret leakage prevented (no `set -x` in CI, a secret-scan PR gate)?
- [ ] **[P8]** Does the change respect the conventions CI enforces (task placement, import rules)?
- [ ] **[P33]** Are CI jobs that invoke LLMs time-capped to prevent runaway spend?
