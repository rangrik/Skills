# Decision Taxonomy — the forcing function

This is the *what to decide*. Walk **every** dimension below during **P2**. For each, evaluate the candidate against the governing standard (the routing note below says where to look) and classify it:

- **Assumption** — a safe default; state it so the user can correct it.
- **Decision** — a genuine fork; queue it for the P3 interview (with a recommendation).
- **N/A** — doesn't apply to this feature; record why.

Every dimension must end the session marked Resolved / Assumed / N/A in the document's **Decision Coverage Checklist**. Nothing is silently skipped.

Each entry below gives the **probing questions**, **where to look** (the appsmith-v2 / Kite repo paths are examples — use the equivalent in another repo), and is the basis for one checklist row.

**Route through `kite-arch-compass` first (Kite repo).** For every dimension, look up the governing standard via `kite-arch-compass` (Mode A): find the relevant component in its Component Map, read the governing principle(s), and ground the recommendation in them — citing principle numbers. The file pointers under "Look:" are the underlying detail the compass draws on. Off-repo, use the generic lens in `design-principles.md`.

**On the numbering.** Parenthetical references below like "(Principle 13)" point at the **generic** `design-principles.md` — the cross-project gap-filler — not the compass's numbering. In the Kite repo the compass's principle for that concern governs and is what you cite; treat the generic number as a fallback pointer for when the compass is silent or you're off-repo.

---

## Part A — Architect's lens (quality attributes)

### A1. Performance & latency
Probing: What's the p50/p95 latency target for each user-visible action? Is the work synchronous (user waits) or background? Where does perceived latency come from, and can we hide it (optimistic UI, streaming, skeleton)?
Look: blueprint's happy-path timing expectations; how similar flows in the repo handle sync vs async.

### A2. Throughput & scale
Probing: Expected request volume now and at plausible growth? Hotspots or fan-out? Any operation that scales with data size (and is it bounded)?
Look: existing load patterns; whether there's a queue/worker tier already.

### A3. Concurrency & consistency
Probing: What happens on concurrent or duplicate actions (double-submit, two refreshes, two tabs)? Is there a race on shared state? What ordering guarantees are needed? Is the write idempotent?
Look: blueprint deviation scenarios for duplicate/concurrent/out-of-order; repo's idempotency/locking patterns.

### A4. Availability & reliability
Probing: What's the availability expectation? On each dependency failure, do we retry, time out, circuit-break, or degrade? What does the user see? Is there an SLO worth stating?
Look: repo error-handling rules; existing retry/circuit-breaker utilities.

### A5. Data integrity & durability
Probing: What are the transactional boundaries? Can a partial failure leave inconsistent state? Retention/expiry? Backups or is it reconstructible?
Look: how the repo scopes transactions and migrations.

### A6. Caching & freshness
Probing: What is cached, where (memory / shared cache / DB), with what TTL, invalidated how? What freshness-vs-cost trade-off are we accepting? Any manual-refresh/cooldown semantics from the blueprint?
Look: blueprint's caching/refresh behavior; repo's existing cache layers. (See principle 13 — answer all five.)

### A7. Cost
Probing: Per-request and per-third-party-call cost? Ceilings/quotas? What stops runaway cost? Does it consume credits/billing?
Look: repo's billing/metering and quota patterns.

### A8. Security & privacy
Probing: Who can invoke this and are they authorized? What input crosses a trust boundary and how is it validated? Secrets handling? PII exposure? Abuse vectors (from the blueprint's adversarial scenarios)?
Look: repo auth/security rules; blueprint's adversarial/abuse section.

### A9. Observability
Probing: How will we know it's working / failing in production? What logs, metrics, traces, and alerts? What's the one signal that proves the feature is healthy?
Look: repo's telemetry/observability conventions.

### A10. Maintainability & simplicity
Probing: Does this fit existing patterns or invent a new shape? What's the blast radius of a change? Is there a simpler design with fewer parts?
Look: adjacent features in the repo. (Principles 1 & 2.)

### A11. Testability
Probing: How is each layer tested? How are third parties mocked/stubbed? Are there deterministic seams? Does this need an eval rather than a unit test?
Look: repo test conventions and mocking utilities. (Principle 15.)

### A12. Deployability & rollout
Probing: Behind a feature flag? Migration/backfill order? Is the rollout reversible? Any coordination between backend/frontend/data deploys?
Look: repo feature-flag and migration practices.

### A13. Backward compatibility
Probing: Does this change existing data shapes, API contracts, or client expectations? Are there in-flight records or older clients to support?
Look: existing schemas/contracts the change touches.

### A14. Accessibility & device/environment
Probing (when user-facing): Mobile and small-screen behavior? Keyboard/screen-reader? Reduced-motion? Offline/poor-connectivity (from blueprint deviations)?
Look: blueprint's environment/device scenarios; repo frontend a11y conventions.

---

## Part B — Concrete build dimensions (this codebase)

**`kite-arch-compass` component for each dimension** (Kite repo — look these up in the Component Map for the governing principles):

| Dimension | Compass component(s) |
|---|---|
| B1 Placement / module taxonomy | Backend HTTP Routes; Backend Services; (or Tools / Skills / Specialised Agents per the taxonomy) |
| B2 Data model & persistence | Database Modules & Models |
| B3 API surface & schemas | Backend HTTP Routes; Tools (orchestrator tool contracts) |
| B4 Async / background work | Celery & Background Workers; Realtime Eventing |
| B5 External services & contracts | Sandbox–Agent Boundary; "funnel external integration through single chokepoints" |
| B6 Frontend integration | Frontend Product App |
| B7 Feature flags & rollout | Billing & Credits / Deployment & Domains (flags + rollout) |
| B8 Error handling | Backend Services; Database Modules & Models (error/transaction contracts) |

### B1. Placement / module taxonomy
Probing: Is this a Service, an LLM Routine, an Agent, a Tool, or a Skill? Which existing module owns it, or is it new?
Look: `backend/docs/rules/module-taxonomy.md`; `agent-context/architecture/system-overview.md`.

### B2. Data model & persistence
Probing: New tables/columns? Platform Postgres vs per-app database? Migration shape and ownership?
Look: repo's data-layer conventions and migration tooling. (Principle 4.)

### B3. API surface & schemas
Probing: New routes? Request/response schemas? SSE/streaming events? If it's an orchestrator tool, what's the input-validation and return-type contract?
Look: `backend/docs/rules/orchestrator-tools.md`; existing route/schema patterns.

### B4. Async / background work
Probing: Sync inline, deferred, or a background job? If background, how is completion surfaced to the user? Idempotent on retry?
Look: `backend/docs/rules/celery-tasks.md`; repo's defer-ops / job patterns.

### B5. External services & integration contracts
Probing: For each third party — purpose, auth/secrets, rate limits, cost, failure modes, fallback, and mock strategy? Does it carry an external-system grammar (URL parts, params, query DSL) that belongs in a probe-tested skill rather than inline?
Look: repo's integration patterns and prior incident entries for that service. (Principles 5, 12, 15 + external-system-grammar guardrail.)

### B6. Frontend integration
Probing: Where does state live? Polling vs push? Optimistic UI? Loading/empty/error states (cross-check the blueprint)? Token/styling rules?
Look: `frontend/claude.md`; existing data-fetching patterns.

### B7. Feature flags & rollout
Probing: Which flag gates this? Default state and fail-open/closed behavior? Staged rollout?
Look: `backend/docs/rules/feature-flags.md`.

### B8. Error handling
Probing: How are errors handled at each layer (db / service / route / tool), and what's surfaced vs swallowed? Does it match the repo's layer-specific contract?
Look: `backend/docs/rules/error-handling.md`. (Principle 5.)
