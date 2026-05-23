# Run Notes — Announcement Banner System Design (Autonomous Run)

**Mode:** Fully autonomous (no human interview). All P3 decisions resolved independently.

## Key decisions made autonomously

1. **Server-side dismissal storage** — the only option compatible with the blueprint's cross-device requirement; no real fork here.
2. **Partial unique index for one-active-banner invariant** — chosen over application-level locking because the blueprint's concurrent-publish deviation scenario requires a race-safe enforcement point.
3. **Short-polling at 30 s** — the blueprint's "within a short time" language left this open; 30 s was chosen as the simplest option consistent with an admin-announcement cadence.
4. **Query-time start/end filtering** — rejected scheduled-job expiry as unnecessary complexity (Principle 1).
5. **No Redis cache** — load analysis showed the DB query is cheap at expected scale; documented a scaling trigger for ~50 000 concurrent users.
6. **Fail-closed feature flag** — standard safety posture.

## What I would have asked a human

- Acceptable banner-appearance latency (confirmed 30 s is "within a short time"?).
- Whether a separate `link_label` field is needed alongside `link_url`.
- Current and projected concurrent-user counts to validate the no-cache decision.
- Existing Postgres version and UUID key convention.
- Idempotency-key appetite for the admin publish path.
- GDPR / data-retention policy for dismissal records.
