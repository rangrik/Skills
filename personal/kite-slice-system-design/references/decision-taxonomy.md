# Decision Taxonomy — the architect's lens (the forcing function)

This is the *what to consider* — the senior-architect coverage that keeps the
design from silently skipping a concern. The data-movement entry lens (source /
travel / actors & effects) is the *way in*; this is the *coverage*. Walk **every**
dimension below during **P2**, at a **high-level system-design altitude** (which
subsystem owns it, the rough data shape and integrity, the posture — *not* column
DDL, migration SQL, or function signatures). For each, evaluate the slice against
the governing standard and classify it into one of **four** buckets:

- **Assumption** — a safe default; state it so the user can correct it.
- **User-answerable unknown (Decision)** — a genuine intent/approach fork only the
  user can settle; queue it for the P3 interview (with a recommendation). These
  are what block autonomous implementation, so resolving them is the heart of the
  skill.
- **Codebase question** — a fact only the code can settle (*does X exist? where is
  Y? what shape is Z?*). You do **not** investigate it and you do **not** ask the
  user to play compiler — you **record it** in §10 Open Questions for the Codebase
  for the research stage. Any "we already have it" claim from the user lands here.
- **N/A** — doesn't apply to this slice; record why.

Every dimension must end the session marked Resolved / Assumed / Codebase-question
/ N/A in the **Decision Coverage Checklist**. Nothing is silently skipped — and
"Codebase-question" is a fully valid *covered* status, not a dodge.

Each entry below gives the **probing questions** and **how to resolve it without
reading code**. Because this skill never opens the codebase, "resolve" means one
of: answer it from the slice, the taxonomy, or the standards; settle it with the
user in the interview; or convert it into a codebase question. The phrasing
throughout is *Resolve by:* rather than *Look:* for exactly this reason.

**Route through `kite-design-system-standards` first.** For every dimension, look up the governing standard via `kite-design-system-standards` (Mode A): find the relevant component in its Component Map, read the governing principle(s), and ground the recommendation in them — citing principle numbers. That is also the basis on which you push back when the user's intent would bend a principle.

**On the numbering.** Parenthetical references below like "(Principle 13)" point at the **generic** `design-principles.md` — the gap-filler — not the standards skill's numbering. In the Kite repo the standards skill's principle for that concern governs and is what you cite; treat the generic number as a fallback pointer for when the standard is silent.

---

## Part A — Architect's lens (quality attributes)

### A1. Performance & latency
Probing: What's the p50/p95 latency target for each user-visible action in this slice? Is the work synchronous (user waits) or background? Where does perceived latency come from, and can we hide it (optimistic UI, streaming, skeleton)?
Resolve by: the slice's happy-path timing expectations; the standard's guidance on sync vs async work; ask the user for a target if it's a genuine fork. Whether a *similar flow already exists* is a research question, not something to design around.

### A2. Throughput & scale
Probing: Expected request volume now and at plausible growth? Hotspots or fan-out along the data path? Any operation that scales with data size (and is it bounded)?
Resolve by: ask the user for volume expectations; apply the standard's bounded-operations principle. Whether a queue/worker tier already exists is a research question.

### A3. Concurrency & consistency
Probing: What happens on concurrent or duplicate actions (double-submit, two refreshes, two tabs)? Is there a race on shared state along the data path? What ordering guarantees are needed? Is the write idempotent?
Resolve by: the slice's deviation scenarios for duplicate/concurrent/out-of-order; the standard's idempotency principle (grill the user if they want to skip it). Whether a locking/idempotency helper already exists is a research question.

### A4. Availability & reliability
Probing: What's the availability expectation? On each dependency failure on the data path, do we retry, time out, circuit-break, or degrade? What does the user see? Is there an SLO worth stating?
Resolve by: the standard's failure-handling principles; the slice's deviation scenarios. Whether retry/circuit-breaker utilities exist is a research question.

### A5. Data integrity & durability
Probing: What are the transactional boundaries on the write path? Can a partial failure leave inconsistent state? Retention/expiry? Backups or is it reconstructible?
Resolve by: the standard's transaction-boundary principle; ask the user about retention. The current shape of the table involved is a research question.

### A6. Caching & freshness
Probing: What is cached, where (memory / shared cache / DB), with what TTL, invalidated how? What freshness-vs-cost trade-off are we accepting? Any manual-refresh/cooldown semantics from the slice?
Resolve by: the slice's caching/refresh behavior; the standard. Never accept a cache without all five answers (See generic principle 13). Whether a cache layer already exists is a research question.

### A7. Cost
Probing: Per-request and per-third-party-call cost along the data path? Ceilings/quotas? What stops runaway cost? Does it consume credits/billing?
Resolve by: ask the user for cost ceilings; the standard's billing/metering component. Whether a metering helper exists is a research question.

### A8. Security & privacy
Probing: Who can invoke this and are they authorized? What input crosses a trust boundary on the data path and how is it validated? Secrets handling? PII exposure? Abuse vectors (from the slice's adversarial scenarios)?
Resolve by: the standard's security principles; the slice's adversarial section. Whether an auth helper for this surface exists, and where, is a research question (the classic "we already have auth" claim).

### A9. Observability
Probing: How will we know this slice is working / failing in production? What logs, metrics, traces, and alerts? What's the one signal that proves the feature is healthy?
Resolve by: the standard's observability conventions; ask the user which signal matters. Whether a telemetry pattern exists is a research question.

### A10. Maintainability & simplicity
Probing: Does this fit existing patterns or invent a new shape? What's the blast radius along the data path? Is there a simpler design with fewer parts?
Resolve by: the standard + generic principles 1 & 2. Whether an adjacent feature already solved this shape is a research question.

### A11. Testability
Probing: How is each step on the data path tested? How are third parties mocked/stubbed? Are there deterministic seams? Does this need an eval rather than a unit test?
Resolve by: the standard's testing-seam principle (generic principle 15). Whether mocking utilities exist is a research question.

### A12. Deployability & rollout
Probing: Behind a feature flag? Migration/backfill order? Is the rollout reversible? Any coordination between backend/frontend/data deploys for this slice?
Resolve by: the standard's feature-flag/rollout component; ask the user about flag default state. Whether a specific flag already exists is a research question.

### A13. Backward compatibility
Probing: Does this slice change existing data shapes, API contracts, or client expectations? Are there in-flight records or older clients to support?
Resolve by: reason from the slice's `Builds on:` context and the standard. The current shape of the contract being changed is a research question.

### A14. Accessibility & device/environment
Probing (when user-facing): Mobile and small-screen behavior? Keyboard/screen-reader? Reduced-motion? Offline/poor-connectivity (from the slice's deviations)?
Resolve by: the slice's environment/device scenarios; the standard's frontend conventions. Whether an a11y pattern exists is a research question.

---

## Part B — Concrete build dimensions (this codebase)

**`kite-design-system-standards` component for each dimension** (look these up in the Component Map for the governing principles):

| Dimension | Standards component(s) |
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
Probing: Is this a Service, an LLM Routine, an Agent, a Tool, or a Skill? Which existing module (in `SYSTEM_TAXONOMY.md` terms) owns it, or is it new?
Resolve by: reason from the taxonomy's named subsystems and the standard's module-taxonomy principles. *Which existing module currently owns the closest thing* is a research question.

### B2. Data model & persistence
Probing: New tables/columns? Platform Postgres vs per-app database? Migration shape and ownership?
Resolve by: the standard's data-layer principles (generic principle 4); ask the user about ownership. The current schema is a research question.

### B3. API surface & schemas
Probing: New routes? Request/response schemas? SSE/streaming events? If it's an orchestrator tool, what's the input-validation and return-type contract?
Resolve by: the standard's route/tool-contract principles. Whether a route for this surface already exists is a research question.

### B4. Async / background work
Probing: Sync inline, deferred, or a background job? If background, how is completion surfaced to the user along the data path? Idempotent on retry?
Resolve by: the standard's Celery/eventing principles; the slice's behavior. Whether a job/worker pattern exists is a research question.

### B5. External services & integration contracts
Probing: For each third party on the data path — purpose, auth/secrets, rate limits, cost, failure modes, fallback, and mock strategy? Does it carry an external-system grammar (URL parts, params, query DSL) that belongs in a probe-tested skill rather than inline?
Resolve by: ask the user about the integration's contract; the standard's chokepoint principle (generic principles 5, 12, 15). Whether an integration client exists is a research question.

### B6. Frontend integration
Probing: Where does state live? Polling vs push? Optimistic UI? Loading/empty/error states (cross-check the slice)? Token/styling rules?
Resolve by: the standard's frontend principles; the slice's UI scenarios. Whether a data-fetching pattern exists is a research question.

### B7. Feature flags & rollout
Probing: Which flag gates this slice? Default state and fail-open/closed behavior? Staged rollout?
Resolve by: the standard's feature-flag component; ask the user about default state. Whether a specific flag exists is a research question.

### B8. Error handling
Probing: How are errors handled at each layer on the data path (db / service / route / tool), and what's surfaced vs swallowed? Does it match the standard's layer-specific contract?
Resolve by: the standard's error-handling principles (generic principle 5). The current error-handling pattern in the touched module is a research question.
