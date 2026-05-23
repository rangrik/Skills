# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./weekly-digest-blueprint.md](../../iteration-1/eval-2-weekly-digest-email/inputs/weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

> **Note on authority:** The `kite-arch-compass` skill was not consulted (this design is off-repo). Every decision is grounded in the generic lens from `references/design-principles.md`. Principle references below use the generic numbering from that file.

---

## 1. Summary

The weekly digest is a pure background-job feature. A Sidekiq scheduled job fires once per UTC minute, queries Postgres for all users whose local 8 AM Monday falls within that minute's window, and for each eligible user enqueues an individual `DigestDeliveryJob`. That per-user job queries activity, skips users with no activity or digests disabled, records a sent-digest row for idempotency, then delivers via SendGrid. The single most important architectural choice is the **two-level job structure** (scheduler + per-user delivery job): it prevents an unbounded per-user loop inside one job, makes each delivery independently retriable and idempotent, and keeps the scheduler thin and safe to re-run. The idempotency record (`digest_deliveries` table) is the guard against the blueprint's explicit constraint that a user receives at most one digest per week even if the scheduler fires twice.

---

## 2. System Placement

This feature is a pure backend concern — no new HTTP routes and no frontend changes required. It touches three layers:

```
[Sidekiq Cron / Scheduler]
        |
        v
DigestSchedulerJob          (Sidekiq job — fires every minute)
  — queries users whose local 8 AM Monday is NOW
  — enqueues one DigestDeliveryJob per user
        |
        v (per user, async)
DigestDeliveryJob           (Sidekiq job — one per user)
  — checks digest_deliveries for idempotency
  — queries activity (WorkspaceActivity or equivalent)
  — checks permission / workspace existence
  — renders email template
  — calls SendGrid API
  — writes digest_deliveries record on success
        |
        v
SendGrid                    (external email delivery)
        |
        v
digest_deliveries           (Postgres — idempotency + audit log)
users                       (Postgres — timezone, digest opt-out flag)
workspace_activities        (Postgres — source of digest content)
```

**Components touched:**
- New: `DigestSchedulerJob`, `DigestDeliveryJob`, `digest_deliveries` table, email template, unsubscribe token mechanism.
- Existing (read-only): `users` table (timezone, digest preference), activity/workspace tables (digest content).
- New column on `users`: `digests_enabled` boolean (default `true`), `digest_unsubscribe_token` (unique secure token).

---

## 3. Architecture Decisions

### D1. Two-level job architecture (scheduler + per-user delivery job)

- **Decision:** A thin `DigestSchedulerJob` runs every minute and enqueues a separate `DigestDeliveryJob` per eligible user. The scheduler does no email work itself.
- **Why:** Principle 6 (idempotency & bounded operations) — the scheduler must not hold an unbounded per-user loop. Principle 5 (design for failure) — a failure in one user's delivery must not abort all others. Principle 3 (high cohesion, loose coupling) — scheduling concern (who is due?) is cleanly separated from delivery concern (build and send this user's email).
- **Alternatives considered:**
  - Single job iterates all users and sends inline: rejected because one failure poisons the batch, retrying re-sends to users already processed, and the job duration grows with user count.
  - One job per timezone offset fired by cron: rejected as over-engineered (Principle 1, YAGNI); a minute-granularity scheduler is simpler and correct.
- **Trade-off accepted:** Slightly higher scheduler overhead (one Sidekiq enqueue per eligible user per minute) — negligible at any realistic user count.

---

### D2. Idempotency via `digest_deliveries` table

- **Decision:** Before sending, `DigestDeliveryJob` checks for an existing row in `digest_deliveries` with `(user_id, week_start_date)`. If a row exists, the job exits immediately without sending. On successful send, it inserts that row. The check-then-insert uses a unique index + INSERT ON CONFLICT DO NOTHING (or equivalent advisory-lock pattern) to prevent race conditions if the scheduler fires twice.
- **Why:** Blueprint deviation scenario explicitly requires that a user receive at most one digest per week even if the scheduler is triggered twice. Principle 6 (idempotency) and Principle 5 (design for failure). The `digest_deliveries` table is the authoritative source of truth for "has this user been sent this week."
- **Alternatives considered:**
  - Redis-based dedup key: rejected because Postgres is already the durable store; adding Redis for a rarely-written key adds a dependency without benefit (Principle 1).
  - Unique constraint only, rely on exception: acceptable, but an explicit SELECT before INSERT is cleaner and avoids exception-driven control flow.
- **Trade-off accepted:** An extra read per delivery job (negligible cost; this is not a hot path).

---

### D3. Per-user `week_start_date` is the idempotency key (not a job-run ID)

- **Decision:** The idempotency key is `(user_id, week_start_date)` where `week_start_date` is the Monday (in the user's timezone) of the digest period. It is computed from the user's timezone at job execution time.
- **Why:** Principle 4 (get the data model right) — tying idempotency to the logical business week (not a job run) means that even if the scheduler misfires across a week boundary, correctness is preserved. A job-run ID would require additional bookkeeping.
- **Alternatives considered:** Job-run UUID as dedup key: rejected because it doesn't survive a scheduler restart with a different run ID.
- **Trade-off accepted:** If a user's timezone changes between two scheduler runs in the same week, the `week_start_date` could differ by one day, theoretically allowing a second send. This is an accepted edge case (blueprint says "a small shift in send time is acceptable" for timezone changes); the one-week dedup window makes a double-send vanishingly unlikely in practice.

---

### D4. Activity query is synchronous inside `DigestDeliveryJob` (no separate aggregation step)

- **Decision:** `DigestDeliveryJob` queries the activity tables at send time. There is no pre-aggregated or materialized digest table.
- **Why:** Principle 1 (YAGNI) — pre-aggregation adds a third job, a separate table, and a scheduling dependency for a weekly batch that touches at most tens of thousands of users. Principle 8 (measure, don't guess) — at weekly cadence the query load is trivially low; optimizing speculatively would be waste.
- **Alternatives considered:**
  - Nightly aggregation job writes to a `digest_content_cache` table: over-engineering for a weekly send; adds staleness risk and a new failure mode.
- **Trade-off accepted:** If activity tables are very large and unindexed, the per-user query could be slow. Mitigated by ensuring standard indexes on `(workspace_id, created_at)` and `(user_id, created_at)` on activity tables (assumed to already exist). Revisit if query p95 exceeds 2 s for large workspaces.

---

### D5. Delivery failure: retry up to 3 times, then drop for the week

- **Decision:** `DigestDeliveryJob` retries up to 3 times with exponential back-off (Sidekiq default). After exhaustion, the job is moved to the dead queue and the digest is skipped for that week. No compensating send is attempted later.
- **Why:** Blueprint deviation scenario is explicit: "a digest that arrives late is worse than one skipped." Principle 5 (design for failure) — the failure must not cascade; the dead queue provides an audit trail for operators. Principle 10 (observability) — dead-queue size is a metric to alert on.
- **Alternatives considered:**
  - Retry for 24 hours: violates blueprint's stated preference for skip-over-late.
  - Store-and-retry next day: new state machine complexity with no product value.
- **Trade-off accepted:** A user may miss a digest if SendGrid is down for an extended period. Acceptable per the blueprint.

---

### D6. Unsubscribe via signed token in email footer

- **Decision:** Each email footer contains a URL of the form `/digest/unsubscribe?token=<token>` where `token` is a unique, opaque, per-user value stored in `users.digest_unsubscribe_token`. Clicking it sets `users.digests_enabled = false` (no login required). Tokens are generated once (or regenerated on each unsubscribe-then-resubscribe) and are not time-limited.
- **Why:** Blueprint adversarial scenario: the link must act only on the account it was issued for and must not be guessable. Principle 11 (security by design) — a cryptographically random token stored in the DB is unforgeable without access to that row. Principle 7 (reversibility) — re-subscribing (out of scope for this feature but anticipated) simply regenerates the token and sets `digests_enabled = true`.
- **Alternatives considered:**
  - HMAC-signed token with user_id embedded (no DB storage): acceptable but requires the signing key to be stable; a DB token is simpler and does not leak user identity in the URL.
  - Login-required unsubscribe: violates "one-click" requirement in the blueprint's happy path.
- **Trade-off accepted:** Tokens do not expire. If a user's email is compromised, an attacker could unsubscribe them. Accepted as proportionate risk for a low-sensitivity action (unsubscribing from a digest).

---

### D7. Timezone-bucketing via per-minute scheduler (not per-timezone cron)

- **Decision:** One Sidekiq cron entry fires `DigestSchedulerJob` every minute. The job computes which users have their 8 AM Monday local-time falling within a ±30-second window of the current UTC instant and enqueues delivery jobs for them. No per-timezone cron entries.
- **Why:** Principle 1 (simplicity) — a single cron entry is simpler than one per timezone (the world has ~400 IANA timezone offsets). Principle 2 (match existing patterns) — a per-minute scheduler is a standard pattern in Sidekiq-based systems.
- **Implementation note:** The query is `WHERE timezone IS NOT NULL AND next_monday_8am_utc(timezone) BETWEEN NOW() - INTERVAL '30 seconds' AND NOW() + INTERVAL '30 seconds'` (or equivalent computed column). Users with no timezone set are bucketed as UTC 8 AM Monday.
- **Alternatives considered:**
  - One cron job per offset group: combinatorial explosion, hard to maintain as new offsets appear.
  - Fire once at UTC 8 AM and send to all users regardless of timezone: violates the blueprint's timezone requirement.
- **Trade-off accepted:** The ±30 s window means delivery time has up to 60 s jitter, which is acceptable. A per-minute cron entry must be idempotent (covered by D2).

---

### D8. Email template rendering in Ruby (server-side, not SendGrid templates)

- **Decision:** The HTML and plain-text email bodies are rendered server-side in Ruby (e.g. ERB / Haml) before being passed to SendGrid's `POST /v3/mail/send` API as pre-rendered content.
- **Why:** Principle 3 (loose coupling) — keeping rendering logic in the application avoids coupling business logic to SendGrid's templating DSL. Principle 15 (design seams for testing) — Ruby templates are testable without making API calls. Principle 7 (reversibility) — switching email providers does not require porting templates.
- **Alternatives considered:**
  - SendGrid Dynamic Templates with handlebars: locks template logic to SendGrid; harder to test locally; version management is external.
- **Trade-off accepted:** Template rendering adds a small amount of per-job CPU work (negligible at weekly cadence).

---

## 4. Data Model & Persistence

### New table: `digest_deliveries`

```sql
CREATE TABLE digest_deliveries (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start_date DATE        NOT NULL,  -- Monday in the user's timezone
  status          VARCHAR(20) NOT NULL DEFAULT 'sent',  -- 'sent' | 'skipped_no_activity' | 'skipped_disabled'
  sent_at         TIMESTAMPTZ,
  sendgrid_message_id VARCHAR(255),      -- for delivery tracking
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT digest_deliveries_user_week_unique UNIQUE (user_id, week_start_date)
);

CREATE INDEX idx_digest_deliveries_user_id ON digest_deliveries(user_id);
CREATE INDEX idx_digest_deliveries_week_start_date ON digest_deliveries(week_start_date);
```

**Invariants:**
- `(user_id, week_start_date)` is unique — enforces the one-per-week guarantee.
- `status = 'skipped_*'` rows record why a digest was not sent (observability; see §9).
- `ON DELETE CASCADE` — if a user is deleted, their delivery history is cleaned up automatically.

**Retention:** No automated expiry required initially; rows are small (~100 bytes each). At 100 k users, 52 rows/year/user = ~5.2 M rows/year. Revisit archival after 2 years.

---

### New columns on `users`

```sql
ALTER TABLE users
  ADD COLUMN digests_enabled         BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN digest_unsubscribe_token VARCHAR(64) UNIQUE,  -- cryptographically random, set on first digest send
  ADD COLUMN timezone                VARCHAR(64);           -- IANA tz string; NULL = UTC assumed
```

**Note:** `timezone` may already exist; if so, only `digests_enabled` and `digest_unsubscribe_token` are new.

**Migration shape:**
1. Add columns with defaults (non-blocking).
2. Backfill `digest_unsubscribe_token` for all existing users (can run as a background job post-deploy).
3. Create `digest_deliveries` table.

No destructive migration. All steps are reversible.

---

### Existing tables (read-only for this feature)

The digest content query reads from existing activity tables (e.g. `workspace_items`, `comments`, or similar). The exact table names are assumed to follow existing conventions; `DigestDeliveryJob` queries them with a `WHERE workspace_id = ? AND created_at >= ? AND created_at < ?` filter. Permission enforcement relies on existing workspace membership checks.

**Assumed indexes exist:**
- `workspace_items(workspace_id, created_at)`
- `comments(mentioned_user_id, created_at)`

If these indexes do not exist, they should be added in the same migration (non-blocking on Postgres with `CREATE INDEX CONCURRENTLY`).

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid** | Transactional email delivery | API key stored in environment variable / secrets manager (`SENDGRID_API_KEY`); never in source | 100 req/s per API key (default); ~$0.001–$0.0014/email on standard plan; set a monthly send ceiling alert | HTTP 4xx on bad request → log and move to dead queue (no retry). HTTP 5xx or timeout → Sidekiq retry (up to 3×). After exhaustion, digest dropped for the week (per blueprint). | `SendGrid::API` client wrapped behind a `DigestMailer` interface; test environment uses a stub/null mailer that records calls without sending. Integration tests use SendGrid's sandbox mode (sends are accepted but not delivered). |

**External-system grammar note:** SendGrid's `POST /v3/mail/send` parameter structure (personalizations, content types, tracking settings) should be validated in a probe-tested skill or integration test rather than encoded as prose in this document.

---

## 6. Performance, Scale & Caching

### Latency targets

This is a background feature with no user-synchronous latency. The relevant target is **email delivery lag** — the time between a user's scheduled 8 AM local time and the email arriving in their inbox:

| Segment | Target | Notes |
|---|---|---|
| Scheduler to job enqueue | < 60 s | Per-minute cron granularity |
| Job enqueue to job start | < 5 min | Sidekiq queue depth dependent; digest queue should be low-priority but not starved |
| Job execution (query + render + API call) | < 10 s p95 per user | Activity query + SendGrid HTTP call |
| SendGrid delivery | ~ 1–5 min | Outside our control |
| **Total end-to-end** | **< 15 min** | Acceptable for a weekly digest |

### Expected load

| Metric | Value | Notes |
|---|---|---|
| Users per minute (peak scheduler window) | ~0–500 | Depends on timezone distribution; most users cluster in UTC-8 to UTC+5 |
| Delivery jobs enqueued per Monday | Total active users | At 100 k users, 100 k jobs spread across 24 hours = ~70/min average, far below Sidekiq capacity |
| SendGrid API calls | 1 per user per week | No batching needed at typical scale; revisit at 500 k+ users |
| DB writes per delivery | 1 (digest_deliveries insert) | Negligible |

### Caching

No caching is introduced. The digest content query runs once per user per week — there is nothing to cache. Activity data is read directly from Postgres at send time.

**Freshness trade-off:** The digest covers the rolling 7-day window ending Monday 00:00 local time. Data is current at query time (no staleness), which is the correct behavior.

### Concurrency

The Sidekiq digest queue should be configured with a concurrency limit to avoid saturating the Postgres connection pool and the SendGrid rate limit. Recommended: `concurrency: 20` for the digest queue, giving a maximum of 20 simultaneous delivery jobs. At 20 jobs × 10 s each, throughput is ~120 users/min — sufficient for any realistic population without hitting SendGrid's 100 req/s limit.

---

## 7. Reliability & Failure Handling

| Failure scenario | Behavior | Blueprint reference |
|---|---|---|
| SendGrid returns 4xx (bad request / invalid email) | Log the error with user_id and error body; write `status = 'failed_permanent'` to `digest_deliveries`; do not retry. | Deviation: email provider rejects message |
| SendGrid returns 5xx or timeout | Sidekiq automatic retry (3 attempts, exponential back-off ~15 min apart). After 3 failures, job goes to dead queue; digest dropped for the week. | Deviation: email provider down |
| Scheduler fires twice in same week | Second `DigestDeliveryJob` per user finds existing `digest_deliveries` row; exits without sending. Exactly-once enforced. | Deviation: job triggered twice |
| Scheduler delayed / starts late | `week_start_date` computed from user's timezone at run time; content window is unchanged. Send time may slip; blueprint explicitly accepts this. | Deviation: job delayed |
| User workspace deleted before send | Activity query returns zero results (workspace filtering); job writes `status = 'skipped_no_activity'`; no email sent. | Edge case: deleted workspace |
| User has no activity | Job writes `status = 'skipped_no_activity'`; no email sent. | Blueprint rule: no empty digest |
| User has digests disabled | Job exits early; writes `status = 'skipped_disabled'`; no email sent. | Blueprint rule: opt-out respected |
| Postgres down during scheduler | Scheduler job fails; Sidekiq retries the scheduler job itself. No delivery jobs enqueued. Operators alerted by dead-queue growth. | General infrastructure failure |

**Idempotency design:** `DigestDeliveryJob` is idempotent: duplicate enqueues produce at most one sent email per `(user_id, week_start_date)`. The unique constraint on `digest_deliveries` is the last line of defense.

**No circuit breaker initially:** At 1 delivery/user/week, the SendGrid call volume is low enough that a circuit breaker is unnecessary complexity (Principle 1). Revisit if the feature is extended to higher-frequency digests.

---

## 8. Security & Privacy

### Authentication & authorization

- The scheduler and delivery jobs run in the server process with service-level credentials — no user-session token involved.
- Activity query **must** filter by workspace membership using the same permission check used elsewhere in the application. The design assumes a `WorkspacePermission.visible_items_for(user)` (or equivalent) helper exists and is called by the delivery job. **This is a hard requirement, not an assumption** — digest content for a user must only include items they are authorized to see (blueprint adversarial scenario).

### Unsubscribe token security

- `digest_unsubscribe_token` is generated using `SecureRandom.urlsafe_base64(48)` (64-char token, 288 bits of entropy — not guessable).
- The token is stored in plain text in the DB (it is not a secret to the user — it is their identifier).
- The unsubscribe endpoint validates the token against the DB before acting. No other authentication required.
- Tokens are single-purpose (unsubscribe only) and cannot be used to access account data.

### PII handling

- Email addresses and user names are passed to SendGrid in the API payload. This is necessary for delivery.
- Digest content (item titles, comment excerpts) may contain PII. No additional masking is applied — users only receive content they can already see in the app.
- SendGrid is configured with click/open tracking **disabled** by default (tracking pixels are PII-sensitive and not necessary for this feature). This is a recommendation; confirm with your privacy policy.

### Input validation

- The unsubscribe endpoint accepts only the token parameter; all other inputs are ignored.
- Email content is rendered from trusted DB data; no user-supplied HTML is rendered unescaped.

### Secrets management

- `SENDGRID_API_KEY` stored in the application's secrets manager / environment variable system. Never logged, never committed.

---

## 9. Observability

### Key metrics (emit via StatsD / Prometheus / equivalent)

| Metric | Type | Description |
|---|---|---|
| `digest.jobs_enqueued` | Counter | Users enqueued per scheduler run |
| `digest.delivery.success` | Counter | Successful sends per run |
| `digest.delivery.skipped_no_activity` | Counter | Users skipped (no activity) |
| `digest.delivery.skipped_disabled` | Counter | Users skipped (opt-out) |
| `digest.delivery.failed_retryable` | Counter | Delivery failures going to retry |
| `digest.delivery.failed_permanent` | Counter | Deliveries dropped (dead queue) |
| `digest.delivery.duration_ms` | Histogram | Per-job execution time |
| `digest.sendgrid_api.latency_ms` | Histogram | SendGrid API call latency |

### Logs

Each `DigestDeliveryJob` execution should log at INFO level:
- `user_id`, `week_start_date`, `status` (sent / skipped / failed), `duration_ms`

On failure: full error class, message, and SendGrid response body (redacted of PII if necessary).

### Alerts

| Alert | Condition | Severity |
|---|---|---|
| Digest dead queue growing | Dead queue size > 100 on Monday | Warning |
| Digest delivery failure rate high | `failed_permanent` / `jobs_enqueued` > 5% in a Monday window | Critical |
| Scheduler not firing | No `digest.jobs_enqueued` event on any Monday morning UTC window | Critical |
| SendGrid API latency spike | p95 latency > 5 s sustained 10 min | Warning |

### The one signal that proves the feature is healthy

**`digest.delivery.success` count on Monday morning is within 20% of the prior week's value.** A drop below this threshold indicates a scheduler failure, a SendGrid outage, or a data problem.

### Traces

Wrap `DigestDeliveryJob#perform` in a trace span. Include `user_id` (hashed for privacy in public trace stores) and `week_start_date` as span attributes.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a boolean flag `weekly_digest_email_enabled` (default: `false`). The `DigestSchedulerJob` reads this flag at runtime and exits immediately if the flag is off. This provides a kill switch without a code deploy.

**Rollout sequence:**
1. Deploy DB migration (add columns to `users`, create `digest_deliveries`) — non-blocking.
2. Deploy application code (scheduler job, delivery job, email template, unsubscribe endpoint) behind flag = `false`.
3. Enable flag for internal users / seed accounts for one Monday cycle; verify emails received, metrics look correct.
4. Enable flag for 10% of users; monitor dead-queue growth and delivery success rate.
5. Ramp to 100%.

### Reversibility

- Turning the flag off immediately stops all future digest sends.
- The `digest_deliveries` table and `users` columns are safe to leave in place while the flag is off.
- A full rollback (removing columns and the table) is a separate migration and only warranted if the feature is abandoned entirely.

### Backfill

No backfill required. The `digest_unsubscribe_token` backfill job can run asynchronously after deploy; users who receive a digest before the token is backfilled get a token generated lazily at send time.

### Operational runbook notes

- If a Monday send is found to have gone to the wrong users, turn the flag off immediately; the `digest_deliveries` unique constraint prevents re-sending to users already delivered.
- Dead-queue jobs can be inspected (they carry `user_id` and `week_start_date`) and either retried or discarded by operators.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Sidekiq is already in use for background jobs | The task states "Sidekiq for background jobs" as the stack | No |
| A2 | SendGrid is the email provider | The task states "SendGrid for email delivery" | No |
| A3 | Postgres is the primary datastore | The task states "Postgres" as the stack | No |
| A4 | A `users` table exists with an `id`, email address, and `timezone` column (or equivalent) | Standard for any user-management system | Yes — confirm `timezone` column name and format (IANA string assumed) |
| A5 | Activity / workspace event data is already stored in Postgres in queryable form | The blueprint references "workspace activity"; common for apps of this type | Yes — confirm exact table/column names and that appropriate indexes exist |
| A6 | A `WorkspacePermission` or equivalent helper enforces item-level visibility | Blueprint adversarial scenario requires this; assumed to exist in application | Yes — confirm the exact authorization helper to call in `DigestDeliveryJob` |
| A7 | Sidekiq cron (via `sidekiq-cron` gem or equivalent) is available or can be added | Standard Sidekiq extension | Yes — confirm gem availability |
| A8 | An HTTP route layer exists to add the `/digest/unsubscribe` endpoint | Standard for any Rails/Sinatra/Rack application | No |
| A9 | `SecureRandom.urlsafe_base64(48)` is available (Ruby stdlib) | Standard Ruby | No |
| A10 | SendGrid tracking (open/click pixels) will be disabled for privacy | Privacy-conservative default | Yes — confirm against privacy policy |
| A11 | User count is < 500 k at launch | Informs concurrency sizing; above this, SendGrid batching and higher queue concurrency are needed | Yes — confirm current and 12-month projected user count |
| A12 | Item links in the email use absolute URLs (not relative paths) | Emails are rendered outside the browser context | No |
| A13 | The "highlighted items" sort order (recency) is implemented as `ORDER BY created_at DESC LIMIT 10` | Blueprint specifies "chosen by recency, capped at ten" | No |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Digest dropped after 3 retries; no late send | A user may miss a week's digest if SendGrid is down for hours | Principle 5 (design for failure — one could argue a delayed send is better than no send) | Blueprint explicitly states "a digest that arrives late is worse than one skipped." Blueprint governs. | If product position changes and late delivery becomes acceptable |
| C2 | No pre-aggregated digest content table | Extra per-user DB query at send time | Principle 8 (measure, don't guess — pre-aggregation would optimize a path not yet proven hot) | Weekly cadence; query load is trivially low at any realistic user count | If query p95 > 2 s for large workspaces, or if user count exceeds 1 M |
| C3 | No circuit breaker for SendGrid calls | N+1 failures accumulate before an operator notices | Principle 5 (systematic failure handling) | At 1 call/user/week, circuit breaking adds complexity without meaningful benefit at current volume | If digest frequency increases or SendGrid incidents are recurring |
| C4 | Unsubscribe tokens do not expire | An old email in a compromised mailbox could be used to unsubscribe the user | Principle 11 (security by design — expiring tokens are more secure) | Unsubscribing from a digest is a low-sensitivity action; rotating tokens on a schedule adds a management task with marginal benefit | If the unsubscribe mechanism is extended to higher-sensitivity actions |
| C5 | Timezone jitter of ±60 s | Users don't receive the email at precisely 8:00:00 AM | Principle 14 (least surprise) | The per-minute scheduler granularity produces at most 60 s jitter, imperceptible for a weekly email | If send-time precision becomes a product requirement |

---

## 13. Open Risks & Callouts

1. **Permission helper not confirmed (A6):** If the delivery job does not correctly call the application's permission layer, users could receive digest items for workspaces they were removed from. This is the highest-risk item. Confirm the exact authorization API before writing `DigestDeliveryJob`.

2. **Activity table schema unknown (A5):** The design assumes activity data is queryable in Postgres. If it is stored in a separate service or a different store, the delivery job's data-fetching layer needs redesign.

3. **Timezone computation correctness:** Computing `next_monday_8am_utc(timezone)` correctly for all IANA timezone strings (including DST transitions) requires careful handling. Use a battle-tested library (e.g. Ruby's `TZInfo` / Rails `ActiveSupport::TimeZone`) and add unit tests covering DST edge cases (e.g. a user in a timezone where Monday 8 AM doesn't exist or occurs twice due to DST).

4. **SendGrid monthly cost ceiling:** At launch, email cost is low. If user count grows rapidly (>500 k), monthly SendGrid costs could exceed $500/month. A cost alert should be configured in the SendGrid dashboard before launch.

5. **`digest_deliveries` row for "skipped" states:** Recording skipped rows (A3, A5 assumption) ensures the idempotency key is always set regardless of send outcome, preventing a re-run from sending to users who were legitimately skipped. This is important to implement correctly.

6. **Blueprint gap — resubscribe flow:** The blueprint specifies that unsubscribing is one-click, but does not define how a user resubscribes (likely via account settings UI). This is noted as a follow-up for the product/frontend team; the data model supports it (`digests_enabled` can be set to `true` again).

---

## 14. Out of Scope

The following are explicitly not addressed in this design:

- Daily or monthly digest frequencies (blueprint out-of-scope).
- User customization of which activity types appear in the digest (blueprint out-of-scope).
- In-app rendering of the digest (blueprint out-of-scope).
- Resubscribe UI or flow (not specified in the blueprint; data model supports it, but the flow is a separate feature).
- Email open/click analytics dashboard (not requested; tracking pixels are recommended disabled for privacy).
- A/B testing of email content or subject lines.
- Multi-language / localization of email content.
- Sending digest summaries via other channels (Slack, push notification, etc.).
- Admin tooling to manually trigger a digest for a specific user.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets defined; background feature, no sync latency |
| A2 Throughput & scale | Resolved | §6 — load sizing, concurrency limit, scale ceiling identified |
| A3 Concurrency & consistency | Resolved | §3 D2, D3 — idempotency key + unique constraint prevents double-send |
| A4 Availability & reliability | Resolved | §7 — per-scenario failure behavior, retry policy, dead queue |
| A5 Data integrity & durability | Resolved | §4 — unique constraint, cascade delete, migration shape, retention note |
| A6 Caching & freshness | Assumed (A2, C2) | §6 — no caching; query-at-send is correct for weekly cadence |
| A7 Cost | Resolved | §5, §13 risk 4 — SendGrid cost model, ceiling alert recommended |
| A8 Security & privacy | Resolved | §8 — token security, permission enforcement, PII handling, secrets |
| A9 Observability | Resolved | §9 — metrics, logs, alerts, key health signal defined |
| A10 Maintainability & simplicity | Resolved | §3 D1, D4, D8 — two-level job, no pre-aggregation, server-side templates |
| A11 Testability | Resolved | §5 — null mailer stub + SendGrid sandbox; seams designed into DigestMailer interface |
| A12 Deployability & rollout | Resolved | §10 — feature flag, staged rollout, reversibility, backfill plan |
| A13 Backward compatibility | Assumed | §4 — additive-only schema changes; no existing contracts changed |
| A14 Accessibility & device/env | N/A | Email rendering; HTML email clients handle accessibility differently. Plain-text alternative included in SendGrid payload (standard practice). No frontend UI changes. |
| B1 Placement / module taxonomy | Resolved | §2 — two Sidekiq jobs (`DigestSchedulerJob`, `DigestDeliveryJob`), one HTTP endpoint (`/digest/unsubscribe`) |
| B2 Data model & persistence | Resolved | §4 — `digest_deliveries` table, `users` columns, migration shape, invariants |
| B3 API surface & schemas | Resolved | §2, §8 — one new HTTP route (`/digest/unsubscribe?token=`); no new internal API routes |
| B4 Async / background work | Resolved | §3 D1, D5, D7 — Sidekiq cron scheduler + per-user delivery job; retry policy; idempotency |
| B5 External services & contracts | Resolved | §5 — SendGrid: auth, rate limits, cost, failure modes, test strategy |
| B6 Frontend integration | N/A | No frontend changes. Email links open existing item URLs. Unsubscribe is a server-side redirect with no frontend component. |
| B7 Feature flags & rollout | Resolved | §10 — `weekly_digest_email_enabled` flag; default off; staged rollout sequence |
| B8 Error handling | Resolved | §7 — per-layer error handling (DB, job, SendGrid); dead queue; skip vs retry policy |

---

## Appendix A: Captured Inputs

*This design was produced autonomously (no live interview). The questions below are those that would have been asked in P3; each is resolved by the architect using the blueprint, the stated stack, and the generic design principles. All decisions and assumptions are recorded in §11 and §12 above.*

---

### Job architecture shape

- **Question:** Should the weekly send be a single job that iterates all users, or a scheduler that fans out to per-user jobs?
- **Recommendation given:** Two-level architecture (scheduler + per-user jobs), citing Principle 6 (bounded operations) and Principle 5 (failure isolation). A single iterating job cannot be safely retried without re-sending to already-processed users.
- **Decision (autonomous):** Two-level architecture adopted. See D1.
- **Notes:** The fan-out means each user's delivery is independently retryable and the scheduler is thin.

---

### Idempotency mechanism

- **Question:** How should we ensure a user receives at most one digest per week, even if the scheduler fires twice?
- **Recommendation given:** `digest_deliveries` table with a `(user_id, week_start_date)` unique constraint, checked before each send. Cited Principle 6 (idempotency) and the blueprint's explicit deviation scenario.
- **Decision (autonomous):** `digest_deliveries` table adopted. See D2, D3.
- **Notes:** Using a business-week key (not a job-run key) makes the guarantee robust across scheduler restarts.

---

### Failure handling for SendGrid outage

- **Question:** If SendGrid is down at send time, should we retry until it comes back (even into the afternoon), or drop the digest for the week?
- **Recommendation given:** Retry 3 times (exponential back-off), then drop. The blueprint explicitly states "a digest that arrives late is worse than one skipped."
- **Decision (autonomous):** Drop after 3 retries. See D5, C1.
- **Notes:** The blueprint is the authority here; no design override is warranted.

---

### Unsubscribe mechanism

- **Question:** Should the unsubscribe link be login-required or one-click (token-based)?
- **Recommendation given:** Token-based (cryptographically random per-user token in DB), one-click, no login required. Blueprint requires one-click. Cited Principle 11 (security by design — unforgeable token).
- **Decision (autonomous):** Token-based unsubscribe. See D6.
- **Notes:** Tokens are not time-limited; tradeoff (C4) is recorded and accepted as proportionate risk.

---

### Email template rendering

- **Question:** Should email templates live in SendGrid (Dynamic Templates) or be rendered server-side in Ruby?
- **Recommendation given:** Server-side rendering (ERB/Haml). Cited Principle 3 (loose coupling — avoid locking to SendGrid's DSL) and Principle 15 (testable seams).
- **Decision (autonomous):** Server-side rendering. See D8.
- **Notes:** Switching email providers in future does not require porting templates.

---

### Activity data aggregation

- **Question:** Should digest content be pre-aggregated nightly, or queried at send time?
- **Recommendation given:** Query at send time. Cited Principle 1 (YAGNI) and Principle 8 (measure, don't guess). Weekly cadence makes the query load trivially low.
- **Decision (autonomous):** Query at send time. See D4, C2.
- **Notes:** Revisit if query p95 exceeds 2 s for large workspaces.

---

### Timezone scheduling

- **Question:** How should we send to users in different timezones at their local 8 AM?
- **Recommendation given:** Single per-minute cron job with a ±30 s UTC window query. Cited Principle 1 (simpler than one cron per timezone).
- **Decision (autonomous):** Per-minute scheduler. See D7.
- **Notes:** ±60 s jitter is imperceptible for a weekly email. Compromise C5 is recorded.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** N/A — autonomous mode. The following concerns were self-surfaced and addressed: DST transition edge cases (§13 risk 3), permission enforcement (§13 risk 1), SendGrid cost ceiling (§13 risk 4), `digest_deliveries` rows for skipped states (§13 risk 5), and the missing resubscribe flow (§13 risk 6).
