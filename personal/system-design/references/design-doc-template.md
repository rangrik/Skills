# System-Design Document Template

Write the output to `<feature>-system-design.md`, next to the paired `<feature>-blueprint.md` (repo root). The **synthesized design** goes up top; the **captured interview** goes in Appendix A.

Rules:
- Fill every section. If a section is N/A, say so in one line and why.
- Assumptions and accepted compromises live in their own tables (§11, §12) — never bury them in prose.
- Each architecture decision (§3) cites the governing principle it upholds — the **Kite principle number** (e.g. `[P<n>]`, looked up in `kite-arch-compass`) in the Kite repo, or the generic principle by name off-repo.
- §15 (Decision Coverage Checklist) must account for **every** row in `decision-taxonomy.md`.
- §16 (Blueprint Coverage Checklist) must account for **every** behavior rule, edge case, and deviation/adversarial scenario in the blueprint — each mapped to where the design handles it, or marked N/A with a reason.
- Appendix A must faithfully capture what the user actually said — decisions, intent, callouts, and notes — so a reader can reconstruct *why* the design is what it is.

Replace every `<…>` placeholder. Delete this instruction block from the final file.

---

```markdown
# System Design: <Feature Name>

**Status:** Draft · **Date:** <YYYY-MM-DD> · **Blueprint:** [./<feature>-blueprint.md](./<feature>-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

## 1. Summary
<One paragraph: the technical shape of the solution and the single most important architectural choice — the thing a reviewer must understand first.>

## 2. System Placement
<Where this lives in the existing architecture — which Service / Routine / Agent / Tool / Skill, new or existing. How data flows in and out. Which components are touched. A small diagram or bullet flow is welcome.>

## 3. Architecture Decisions
<The core of the document. One ADR-style block per load-bearing decision, ordered by dependency.>

### D1. <Decision title>
- **Decision:** <what we're doing>
- **Why:** <rationale, citing the governing principle(s). Kite repo: cite the principle number looked up in the compass, e.g. "`[P<n>]` idempotency by design + `[P<n>]` async work with backpressure". Off-repo: cite by name, e.g. "keeps the data model simple; favors reversibility".>
- **Alternatives considered:** <options and why each was rejected>
- **Trade-off accepted:** <what we give up by choosing this>

### D2. <Decision title>
<…>

## 4. Data Model & Persistence
<Tables/columns, schema, ownership (platform vs per-app store), invariants/constraints, migration shape, retention/expiry. State "no persistence changes" if none.>

## 5. External Services & Integration Contracts
<For each third-party dependency:>

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| <name> | <why> | <how> | <limits, $/call, ceiling> | <what happens on failure> | <how it's tested> |

<If a service carries an external-system grammar that belongs in a probe-tested skill, note it here as a follow-up rather than encoding the grammar.>

## 6. Performance, Scale & Caching
<Latency targets (p50/p95) per action; expected load and growth; concurrency model; caching — what / where / TTL / invalidation / cooldown; cost ceilings. Be explicit about the freshness-vs-cost trade-off.>

## 7. Reliability & Failure Handling
<Retries, timeouts, circuit breakers, idempotency keys, graceful degradation. For each failure, what the user sees — cross-referenced to the blueprint's deviation scenarios.>

## 8. Security & Privacy
<AuthN/Z, input validation at trust boundaries, secret handling, PII exposure, abuse mitigation (tie to the blueprint's adversarial scenarios).>

## 9. Observability
<Logs, metrics, traces, and the few alerts that matter. The one signal that proves the feature is healthy in production.>

## 10. Rollout & Operability
<Feature flag(s) and default state; migration/backfill order; reversibility; any backend/frontend/data deploy coordination.>

## 11. Assumptions
<Everything defaulted rather than decided. The reader can challenge any row.>

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | <…> | <…> | <yes/no> |

## 12. Accepted Compromises
<Trade-offs taken on purpose. Name the principle each one bends. This follows `kite-arch-compass`'s **deviation rule**: a departure from a standard must be named (Kite principle number in-repo), justified, and recorded — an *undocumented* deviation is itself a finding. These records also satisfy the compass's "record significant decisions" principle and can seed a decision record.>

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | <…> | <…> | <e.g. `[P<n>]` YAGNI — earn every abstraction> | <…> | <when to reconsider> |

## 13. Open Risks & Callouts
<Anything unresolved, risky, or explicitly flagged by the user that isn't yet a decision.>

## 14. Out of Scope
<What this design deliberately does not address — to prevent scope creep and set reviewer expectations.>

## 15. Decision Coverage Checklist
<Every row from the decision taxonomy, accounted for. This is the completeness gate.>

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved / Assumed (A#) / N/A | §6 / … |
| A2 Throughput & scale | … | … |
| A3 Concurrency & consistency | … | … |
| A4 Availability & reliability | … | … |
| A5 Data integrity & durability | … | … |
| A6 Caching & freshness | … | … |
| A7 Cost | … | … |
| A8 Security & privacy | … | … |
| A9 Observability | … | … |
| A10 Maintainability & simplicity | … | … |
| A11 Testability | … | … |
| A12 Deployability & rollout | … | … |
| A13 Backward compatibility | … | … |
| A14 Accessibility & device/env | … | … |
| B1 Placement / module taxonomy | … | … |
| B2 Data model & persistence | … | … |
| B3 API surface & schemas | … | … |
| B4 Async / background work | … | … |
| B5 External services & contracts | … | … |
| B6 Frontend integration | … | … |
| B7 Feature flags & rollout | … | … |
| B8 Error handling | … | … |

## 16. Blueprint Coverage Checklist
<Every behavior rule, edge case, and deviation/adversarial scenario named in the blueprint, mapped to where this design handles it. §15 proves the *architectural dimensions* were all considered; this proves the *product behavior* was. A feature can satisfy every taxonomy row and still silently drop a blueprint item that maps to no single dimension — a partial-window edge case, a stated cap like "show up to ten items", a specific deviation. Walk the blueprint top to bottom. If an item genuinely needs no system-design treatment, mark it N/A with a reason.>

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| <behavior / edge case / scenario — quoted or closely paraphrased> | Behavior / Edge case / Deviation / Adversarial | §<n> / D<n> | <how it's handled, or N/A + why> |

---

## Appendix A: Captured Inputs
<A faithful record of the interview — the raw material the synthesized sections above were built from. For each decision discussed, capture the question, the recommendation given, the user's answer, and any intent/notes/constraints they expressed in their own words. Preserve facts and rationale, not just the verdict, so a future reader understands *why*.>

### <Topic / Decision 1>
- **Question:** <what was asked>
- **Recommendation given:** <the option recommended and the principle-based reason>
- **User's answer:** <what they chose>
- **Notes / intent:** <anything they said about why, constraints, or preferences>

### <Topic / Decision 2>
<…>

### Last-call (P4)
- **Asked:** "Anything we've missed — any concern or constraint not yet captured?"
- **User's response:** <what surfaced, or "nothing further">
```
