# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./weekly-digest-blueprint.md](./weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The weekly digest is a pure background-processing pipeline: a Sidekiq cron job fans out one Sidekiq worker job per timezone hour-bucket, each job fetches eligible users whose 8 AM local time falls in that window, queries their workspace activity from Postgres, and sends the assembled email via SendGrid. The single most important architectural choice is **idempotent per-user per-week delivery guarded by a `digest_sends` dedup table**: this one mechanism satisfies the "at most once per week" requirement, makes double-trigger safe, and gives the job safe retry semantics under failure—all without distributed locking. Email delivery failures are retried up to three times with exponential backoff, then permanently dropped for the week (a skipped digest is intentionally preferred over a late one per the blueprint). An unsubscribe token is a HMAC-signed, user-scoped value that cannot be forged or replayed against a different account.

---

## 2. System Placement

This feature lives entirely in the backend. There is no synchronous API surface and no frontend state change triggered by digest sends.

**Components touched:**

```
[Cron / Scheduler]
    └─► DigestSchedulerJob (Sidekiq cron, fires every hour on Monday)
            └─► DigestUserJob (Sidekiq worker, one per user)
                    ├─► DigestQueryService   (Postgres: fetch activity + permissions check)
                    ├─► DigestAssemblerService (build email content, cap items at 10)
                    ├─► DigestSendService    (SendGrid API call)
                    └─► digest_sends table   (dedup + audit log)

[HTTP] UnsubscribeController (GET/POST /digest/unsubscribe?token=…)
    └─► users table (flip digest_enabled flag)
```

**Data flow:**

1. `DigestSchedulerJob` runs hourly on Mondays. For the current UTC hour, it computes which timezone offsets correspond to 8 AM and enqueues one `DigestUserJob` per matching user who has `digest_enabled = true` and has not yet received a digest this ISO week.
2. `DigestUserJob` inserts a tentative `digest_sends` row (unique constraint on `(user_id, iso_week)`) — **this is the dedup gate**. If the insert fails (duplicate), the job exits successfully.
3. The job queries workspace activity for the rolling seven days ending Monday 00:00 local time, respects workspace visibility/permission, checks for non-empty content, assembles the email, and calls SendGrid.
4. On success, the `digest_sends` row is marked `sent`. On permanent failure, it is marked `dropped`.
5. `UnsubscribeController` validates the HMAC token, confirms the encoded user ID, and flips `users.digest_enabled` to `false`.

---

## 3. Architecture Decisions

### D1. Idempotent dedup via `digest_sends` table with unique constraint

- **Decision:** Before doing any work, `DigestUserJob` attempts to insert a row into `digest_sends(user_id, iso_week)`. A `UNIQUE(user_id, iso_week)` constraint makes a second insert fail atomically. The job treats a unique-violation as success and exits immediately.
- **Why:** Satisfies the "at most one digest per week" rule and the "job triggered twice" deviation scenario. Idempotent operations are retry-safe and eliminate the need for distributed locking (Principle 6: Idempotency & bounded operations). The database constraint makes the invariant unrepresentable to violate (Principle 9: Make illegal states unrepresentable). A flag on the user row would create a race between two concurrent scheduler runs; the insert-or-skip pattern is atomic.
- **Alternatives considered:**
  - *Redis distributed lock per user-week:* Adds an infrastructure dependency with its own TTL/expiry failure modes, and still requires a durable audit trail. Rejected — extra complexity without benefit (Principle 1: Simplicity first).
  - *Flag column on `users` table:* Not scoped to a week; would require weekly reset jobs; race-prone without a transaction. Rejected.
- **Trade-off accepted:** The `digest_sends` table grows by one row per user per week. At 100k users this is ~5M rows/year — manageable with a retention policy (see §4).

---

### D2. Fan-out architecture: scheduler → per-user worker jobs

- **Decision:** A single `DigestSchedulerJob` (cron, hourly on Monday) enqueues individual `DigestUserJob` tasks per eligible user per timezone window. No single job processes all users.
- **Why:** Keeps each job's scope bounded and independently retryable (Principle 6). A single monolithic job would process thousands of users with no partial-failure isolation — one bad user record would stall the rest. Fan-out through the queue also provides natural backpressure and parallelism matching worker concurrency. (Principle 3: High cohesion, loose coupling.)
- **Alternatives considered:**
  - *Single job processes all users in a loop:* Simple, but a failure mid-loop can't resume; a stalled SendGrid call holds up all subsequent users. Rejected.
  - *Batch processing by timezone group (one job per offset):* Reduces job count overhead but reintroduces partial-failure coupling within a batch. Rejected.
- **Trade-off accepted:** Job count is proportional to active users. At 100k users this is 100k Sidekiq jobs enqueued per week — well within Sidekiq's documented throughput. Scheduler overhead is acceptable.

---

### D3. Timezone bucketing in the scheduler

- **Decision:** `DigestSchedulerJob` runs every hour on Monday (via Sidekiq-Cron or a similar Sidekiq scheduler). On each run, it identifies UTC offsets for which 8 AM local falls within the current UTC hour, then queries users in those timezones.
- **Why:** The blueprint mandates per-user 8 AM local time delivery. Processing users by timezone hour-bucket means each user gets the email at approximately the right time without any per-user timer. Hourly granularity is coarse enough to be operationally simple and fine enough to satisfy the UX requirement (Principle 1: Simplicity first; Principle 14: Least surprise).
- **Alternatives considered:**
  - *One scheduler job that enqueues all users at Monday 00:00 UTC with per-user `scheduled_at` delay:* Sidekiq-Scheduler supports `at:` time on individual jobs. Feasible, but creates a large burst of 100k jobs with varying delays that are hard to introspect. Rejected in favor of hourly fan-out for simplicity.
  - *Scheduler fires once per timezone offset (24 jobs per week):* Cleaner but requires maintaining a 24-job cron schedule and misses timezone granularity finer than hourly. Rejected — hourly polling handles it naturally.
- **Trade-off accepted:** Users may receive their email up to 59 minutes later than exactly 8:00 AM local time (within the hourly window). The blueprint states "8:00 AM in each user's configured timezone" as the target; a sub-hour slip is acceptable for a non-time-sensitive weekly digest.

---

### D4. No email is sent for empty digests — checked at job time

- **Decision:** `DigestUserJob` queries the activity, and if the result set is empty (no new items, completed items, or mentions in the window), it marks the `digest_sends` row as `skipped` and exits without calling SendGrid.
- **Why:** The blueprint is explicit: "If a user had no relevant activity in the past week, no email is sent." Checking at job time (not at enqueue time) means the decision is made with the most current data and respects the rolling window accurately. Enqueue-time filtering could race with late-arriving activity. (Principle 5: Design for failure; Principle 9: Illegal states.)
- **Alternatives considered:**
  - *Filter at scheduler time:* Would require the scheduler to run the full activity query per user — defeats the purpose of fan-out by loading all the work onto the scheduler. Rejected.
- **Trade-off accepted:** Sidekiq jobs are enqueued for users who may ultimately have no activity; these jobs run cheaply (a single DB query) and exit. Acceptable overhead.

---

### D5. SendGrid integration: transactional send with retry-then-drop

- **Decision:** `DigestSendService` calls the SendGrid Mail Send API synchronously within the Sidekiq job. On failure, Sidekiq retries up to 3 times with exponential backoff. After exhausting retries, the job marks the `digest_sends` row as `dropped` and does not reschedule. The email is silently skipped for the week.
- **Why:** The blueprint is explicit: "a digest that arrives late is worse than one skipped." A retry-then-drop strategy honours this. Using Sidekiq's built-in retry mechanism reuses existing infrastructure and provides retries with backoff without custom timers (Principle 2: Match existing patterns; Principle 5: Design for failure).
- **Alternatives considered:**
  - *Retry indefinitely until Monday midnight, then drop:* More complex scheduling; risks sending a very late digest. Explicitly rejected by the blueprint.
  - *Dead-letter queue for manual replay:* Adds operational complexity for a feature the blueprint already says should be dropped on permanent failure. Out of scope for now.
- **Trade-off accepted:** Users who experience a transient SendGrid outage on their send window will not receive a digest that week. This is the explicit product decision in the blueprint's deviation scenarios.

---

### D6. Unsubscribe token: HMAC-signed, user-scoped, one-click

- **Decision:** Each digest email footer contains a URL of the form `/digest/unsubscribe?token=<hmac_token>`. The token is `HMAC-SHA256(secret_key, "unsubscribe:{user_id}:{iso_week}")` encoded as URL-safe Base64. The `UnsubscribeController` validates the HMAC, extracts `user_id` from the payload, and sets `users.digest_enabled = false`.
- **Why:** The blueprint's adversarial scenario requires the unsubscribe link to "act only on the account it was issued for and must not be guessable." HMAC with a server-side secret satisfies non-guessability. Encoding `user_id` inside the signed payload makes it account-specific without a database lookup for validation. Not storing tokens in the database keeps the design simple (Principle 1; Principle 11: Security & privacy by design).
- **Alternatives considered:**
  - *Random UUID token stored in DB:* Durable, revocable, but requires a DB table and lookup on every unsubscribe click. Adds migration and maintenance overhead. For weekly digests, a stateless HMAC is sufficient.
  - *User ID alone in query param (unsigned):* Trivially guessable. Rejected — directly violates the adversarial scenario.
  - *JWT:* More complex than needed; HMAC is sufficient. Rejected (Principle 1).
- **Trade-off accepted:** Tokens cannot be individually revoked (no revocation list). If the HMAC secret rotates, old links become invalid — this is acceptable since unsubscribe links are valid for one week. Include `iso_week` in the payload so old tokens don't persist indefinitely.

---

### D7. Permission-filtered activity query

- **Decision:** The activity query for each user is scoped by a permission filter: items from deleted workspaces are excluded, and item visibility follows the user's access rights at query time.
- **Why:** The blueprint's adversarial scenario: "Digest content for a user must only include items that user is allowed to see." A deleted workspace edge case is also explicitly called out. The permission filter must be applied in the query, not post-hoc in the assembler, to avoid fetching and discarding data the user was never supposed to see. (Principle 11: Security & privacy by design.)
- **Alternatives considered:**
  - *Filter in assembler after fetching all activity:* Fetches data the user isn't allowed to see, exposing it to the application tier even if it's filtered before sending. Rejected on principle.
- **Trade-off accepted:** The query is more complex (join to workspace membership / permission tables). This is necessary complexity driven by security requirements.

---

### D8. New-user partial window

- **Decision:** The digest window lower bound is `MAX(Monday_00:00_local - 7 days, user.created_at)`. The query always uses the user's account creation date as the floor.
- **Why:** The blueprint edge case: "A brand-new user who joined mid-week: they receive a digest covering only the days since they joined." This requires a simple `MAX()` on the window lower bound in the query. (Principle 9: illegal states — a query that reaches before the user existed would return nothing anyway, but explicit bounding prevents confusion.)
- **Trade-off accepted:** No additional complexity. This is a trivially cheap query modification.

---

### D9. Feature flag for staged rollout

- **Decision:** The digest feature is gated behind a boolean feature flag `weekly_digest_enabled`. The scheduler job checks the flag before enqueuing any user jobs. Default state: disabled. Rollout proceeds by enabling the flag for a percentage of users, then fully.
- **Why:** A feature flag provides a clean kill switch if SendGrid behaves unexpectedly or a data bug is discovered at scale. It costs nothing to add and allows safe production validation (Principle 7: Prefer reversible decisions; Principle 12: Deployability & rollout).
- **Trade-off accepted:** The first few weeks of rollout will have partial coverage. Acceptable — the feature is opt-out, not opt-in, so gradual rollout means some users simply start receiving digests a week later than others.

---

## 4. Data Model & Persistence

### New table: `digest_sends`

```sql
CREATE TABLE digest_sends (
    id            BIGSERIAL PRIMARY KEY,
    user_id       BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    iso_week      CHAR(8)      NOT NULL,   -- e.g. "2026-W21"
    status        VARCHAR(16)  NOT NULL DEFAULT 'pending',
                                           -- pending | sent | skipped | dropped
    enqueued_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    resolved_at   TIMESTAMPTZ,
    error_detail  TEXT,                    -- last error message if dropped
    CONSTRAINT digest_sends_user_week_unique UNIQUE (user_id, iso_week)
);

CREATE INDEX digest_sends_user_id_idx ON digest_sends(user_id);
CREATE INDEX digest_sends_iso_week_idx ON digest_sends(iso_week);
```

**Invariants:**
- `(user_id, iso_week)` is globally unique — this is the dedup gate (D1).
- `status` transitions: `pending → sent | skipped | dropped`. No other transitions are valid.
- `error_detail` is only populated when `status = 'dropped'`.

**Retention:** Rows older than 90 days can be hard-deleted by a maintenance job. The table is an audit log, not a source of truth for user preferences.

### Modified table: `users`

Add two columns:

```sql
ALTER TABLE users
  ADD COLUMN digest_enabled   BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN digest_timezone  VARCHAR(64) DEFAULT NULL;  -- NULL => UTC
```

**Invariants:**
- `digest_enabled = false` means no digest is ever sent, regardless of other state.
- `digest_timezone = NULL` is treated as `UTC` at query time (blueprint edge case: "user whose timezone is not set").

### No other schema changes.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid Mail Send API** | Deliver the weekly digest HTML email to users | API key stored as environment secret (`SENDGRID_API_KEY`); passed as `Authorization: Bearer` header | Shared IP pool: ~100 emails/sec sustained; per-message cost ~$0.001 at volume; weekly burst of 100k emails is within standard plan | HTTP 4xx (bad request, invalid recipient): mark `dropped`, do not retry. HTTP 5xx or network timeout: Sidekiq retry (3 attempts, exponential backoff). After 3 failures: mark `dropped` per blueprint deviation D5. | Stub `DigestSendService` at the service boundary; inject a fake that records calls. Integration tests use SendGrid sandbox mode (no real delivery). Never call live API in unit tests. |

**External-system grammar note:** SendGrid's template substitution DSL, click-tracking parameters, and unsubscribe group IDs are external-system grammar that should be validated against the live API in a probe-tested skill rather than encoded in this document as immutable spec.

---

## 6. Performance, Scale & Caching

### Latency targets

This is a background job pipeline; there are no synchronous user-visible latency targets. The one user-visible action is unsubscribe:

- **Unsubscribe HTTP handler:** p95 < 200 ms (single DB write; no external calls).

### Expected load

- **Users:** Baseline assumption of up to 100,000 active users (see Assumption A4). At full scale this means ~100k `DigestUserJob` tasks enqueued across the 24-hour Monday window.
- **Throughput:** ~4,200 jobs/hour average; peak ~8,000 jobs/hour around timezone clusters (US-ET and US-PT morning windows). This is comfortably within Sidekiq's documented throughput with standard concurrency settings.
- **SendGrid:** ~4,200 API calls/hour at peak. SendGrid's shared sending limit is well above this; no rate-limit mitigation needed at current scale.
- **Postgres activity query:** One query per user per week. Each query scans a bounded window (7 days) with a `LIMIT 10` for highlighted items. Index on `(workspace_id, created_at)` on the activity table should keep these sub-10ms.

### Caching

No cache layer is introduced. Each user's digest is assembled fresh from Postgres at send time. The data is inherently user-specific and time-scoped, making shared caching low-value (each entry would be used once and then stale). Caching the activity query result would save only one Postgres query per user per week — not worth the freshness risk or complexity (Principle 1: Simplicity first; Principle 13: Cache invalidation is a design decision — here the answer is "don't cache").

### Concurrency

The `digest_sends` unique constraint (D1) is the concurrency control. Multiple Sidekiq workers can safely process jobs for different users in parallel. Two workers racing on the same `(user_id, iso_week)` pair will see a unique constraint violation on the second insert and exit cleanly.

---

## 7. Reliability & Failure Handling

### SendGrid delivery failure

*Blueprint deviation: "email provider is down or rejects a message at send time"*

Sidekiq retries `DigestUserJob` up to 3 times with exponential backoff (e.g., 15s, 60s, 240s). If all retries fail, Sidekiq calls the `sidekiq_retries_exhausted` callback, which:
1. Updates `digest_sends.status = 'dropped'`
2. Populates `digest_sends.error_detail` with the last error message
3. Emits a structured log event and increments a `digest.delivery_dropped` counter metric

The user receives no email for the week. No late delivery is attempted. This matches the explicit blueprint decision: late > skip is false.

### Double-trigger (job fires twice)

*Blueprint deviation: "weekly job is triggered twice"*

Protected by the `digest_sends` unique constraint (D1). The second scheduler run will either find existing `digest_sends` rows (jobs already enqueued) or, if workers are concurrently running, the second `DigestUserJob` attempt will hit the unique constraint and exit. No duplicate emails.

### Late scheduler start

*Blueprint deviation: "job is delayed and starts late"*

The seven-day window is computed at the time the `DigestUserJob` runs (not when enqueued), based on the user's local Monday 00:00. A delay in job start does not affect window content — only send time slips. The blueprint explicitly states this is acceptable.

### Deleted workspace

*Blueprint edge case: "user with activity but in a workspace that was deleted"*

The activity query joins against workspaces with an existence/active filter. Activity from deleted workspaces is excluded at query time (D7). If this causes the activity set to be empty, the "no activity → no email" rule (D4) applies.

### Partial failure in fan-out

If `DigestSchedulerJob` fails mid-enqueue (e.g., Redis connection drop), already-enqueued jobs will run; not-yet-enqueued jobs will not be processed that week. The scheduler is idempotent: re-running it for the same week will attempt to enqueue remaining users. The unique constraint prevents double-sending already-queued users.

### Idempotency summary

| Operation | Idempotency mechanism |
|---|---|
| Scheduler re-run | Unique constraint check before enqueue |
| `DigestUserJob` retry | Unique constraint insert-or-exit pattern |
| Unsubscribe click | Idempotent: `UPDATE users SET digest_enabled = false WHERE id = ?` is safe to run multiple times |

---

## 8. Security & Privacy

### Unsubscribe token security

*Blueprint adversarial: "unsubscribe link must act only on the account it was issued for and must not be guessable"*

- Token is `HMAC-SHA256(DIGEST_UNSUBSCRIBE_SECRET, "unsubscribe:{user_id}:{iso_week}")` encoded as URL-safe Base64.
- `UnsubscribeController` validates the HMAC before taking any action. An invalid HMAC returns HTTP 400; no information about the user is leaked.
- Including `iso_week` in the signed payload limits token reuse: a token from week N will fail validation if replayed in week N+1 (the HMAC value will differ). Old tokens become inert — no revocation table needed.
- `DIGEST_UNSUBSCRIBE_SECRET` is a server-side secret in environment configuration, never exposed to clients.

### Activity permission filtering

*Blueprint adversarial: "Digest content for a user must only include items that user is allowed to see"*

The activity query is authored to apply the same authorization rules as the application's normal item-visibility logic. The permission filter is in the query (not post-fetch in the assembler). If a user's permissions change between their join date and send time, the query will reflect the current state.

### PII handling

Email addresses are passed to SendGrid only at send time; they are not stored in `digest_sends`. The `error_detail` column must not include email addresses or other PII — log only status codes and generic error descriptions.

### Input validation

The only external input is the `token` query parameter on the unsubscribe endpoint. It is parsed as a Base64 string, HMAC-validated, and then used only to extract the `user_id` integer. No other user-supplied data enters the pipeline.

### Secret management

- `SENDGRID_API_KEY`: environment variable; not logged; rotatable without code change.
- `DIGEST_UNSUBSCRIBE_SECRET`: environment variable; rotation invalidates all outstanding unsubscribe links for the current week (acceptable — links expire weekly anyway).

---

## 9. Observability

### Metrics

| Metric | Type | Description |
|---|---|---|
| `digest.jobs_enqueued` | Counter | Total `DigestUserJob` tasks enqueued each scheduler run |
| `digest.sent` | Counter | Emails successfully delivered |
| `digest.skipped_empty` | Counter | Users with no activity — no email sent |
| `digest.dropped` | Counter | Emails dropped after retry exhaustion |
| `digest.send_duration_ms` | Histogram | Time taken to send one email (SendGrid latency) |
| `digest.query_duration_ms` | Histogram | Time taken for the activity query per user |

### Logs

Every `DigestUserJob` emits a structured log event at completion:

```json
{
  "event": "digest_job_completed",
  "user_id": 12345,
  "iso_week": "2026-W21",
  "status": "sent | skipped | dropped",
  "activity_count": 7,
  "send_duration_ms": 142,
  "error": null
}
```

`DigestSchedulerJob` logs total users enqueued per run and the timezone offset range processed.

### The one signal that proves the feature is healthy

`digest.sent / digest.jobs_enqueued` — the weekly delivery rate. A healthy week should show this ratio close to `1 - (fraction with no activity)`. A sharp drop in this ratio (e.g., below 80%) on Monday is the primary alert signal. Alert condition: `digest.dropped / digest.jobs_enqueued > 0.05` (more than 5% of sends dropped) within a 2-hour window on Monday.

### Traces

`DigestUserJob` should emit a trace span covering: activity query, email assembly, and SendGrid call. This allows pinpointing whether a slow digest is a DB query issue or a SendGrid latency issue.

---

## 10. Rollout & Operability

### Feature flag

Flag name: `weekly_digest_enabled`. Default: disabled. The `DigestSchedulerJob` checks this flag before enqueuing any jobs. If the flag is disabled mid-Monday-run, already-enqueued jobs complete; no new jobs are enqueued.

**Rollout stages:**
1. Enable flag for internal users / a small cohort (1–5%) to validate SendGrid integration, email rendering, and observability.
2. Expand to 25% → 50% → 100% over successive weeks, monitoring `digest.dropped` rate and SendGrid deliverability.
3. Remove flag after one full cycle at 100% with no incidents.

### Migration order

1. Deploy migration adding `users.digest_enabled`, `users.digest_timezone`, and creating `digest_sends` table.
2. Deploy application code with flag disabled.
3. Validate schema in production.
4. Enable flag for cohort.

Rollback: disable the feature flag. The scheduler immediately stops enqueuing jobs. Already-in-flight jobs complete normally. Schema changes are backward-compatible (additive only) — no rollback required.

### Operability

- Re-running `DigestSchedulerJob` manually for a missed week is safe: the unique constraint prevents double-sends for already-processed users.
- Clearing a `digest_sends` row for a user (e.g., to force a re-send in testing) requires a manual `DELETE FROM digest_sends WHERE user_id = ? AND iso_week = ?`. This is an operator action, not a user-facing operation.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Sidekiq is already in use for background jobs in this stack | The task specification lists Sidekiq as part of the stack | No |
| A2 | SendGrid is already the email delivery provider | The task specification lists SendGrid as part of the stack | No |
| A3 | The `users` table exists and is in Postgres | Fundamental to the stack | No |
| A4 | Active user base is up to 100,000 users | Reasonable SaaS baseline; design scales well beyond this | Yes — confirm if already at 1M+ scale |
| A5 | There is an existing `activity` or equivalent table tracking workspace events | The blueprint presupposes queryable workspace activity; the exact schema is undetermined here | Yes — confirm table name, columns, and existing indexes |
| A6 | Sidekiq-Cron or equivalent (e.g., `sidekiq-scheduler` gem) is available for scheduling recurring jobs | Standard Sidekiq ecosystem; commonly bundled | Yes — confirm which scheduler library is in use |
| A7 | No existing digest or notification system exists that this would conflict with | No conflicting patterns mentioned in the task | Yes — confirm no prior digest table or notification infrastructure |
| A8 | Users have a `timezone` or `digest_timezone` field that stores IANA timezone strings (e.g., "America/New_York") | Necessary for per-user 8 AM send time; assumed from blueprint | Yes — confirm existing timezone storage or if this column is net new |
| A9 | The application has an existing secrets management pattern (ENV vars or similar) for API keys | Standard for any Sidekiq+Postgres+SendGrid stack | No |
| A10 | Hourly timezone bucket granularity is acceptable (users may receive email up to 59 min past 8:00 AM) | Blueprint says "8:00 AM" without sub-hour precision requirements; weekly digest is not time-sensitive | Low — would ask human to confirm |
| A11 | `iso_week` format "YYYY-Www" is used consistently throughout the system for weekly scoping | Standard ISO 8601; unambiguous | No |
| A12 | The 90-day retention policy for `digest_sends` is acceptable (rows older than 90 days deleted) | Audit trail is operational, not a compliance record | Yes — confirm retention requirements |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Up to 59-minute send-time slip within the hourly scheduling window | Exact 8:00:00 AM delivery per user | Principle 14: Least surprise | Weekly digest is not time-sensitive; users will not notice a sub-hour variance. Exact-time scheduling would require per-user job scheduling (complex) or 1-minute cron granularity (noisy). | If business requires SLA-level delivery time guarantees |
| C2 | Retry-then-drop: no late delivery attempt after 3 retries | Some users lose their digest for the week if SendGrid is down at their send time | Principle 5: Design for failure (full recovery) | Explicitly required by the blueprint: late digest is worse than skipped. This is the product decision, not a system compromise. | If the product team reconsiders the "late > skipped" decision |
| C3 | Stateless HMAC unsubscribe tokens (no revocation table) | Cannot individually invalidate a specific token before it expires | Principle 11: Security & privacy by design | Tokens expire weekly by design (iso_week in payload). The attack surface — redirecting a token to a different account — is blocked by the HMAC. Individual revocation not required by the blueprint. | If the security model is elevated (e.g., compliance requirements) or tokens must be revocable |
| C4 | No caching of activity query results | Re-queries Postgres on every job run; no cross-user result sharing | Principle 12: Cost as a first-class constraint | Each user's query is unique and used exactly once per week. A cache would have 100% eviction rate in practice. The simplicity gain outweighs the marginal DB load. | If DB query costs become significant at higher scale (>1M users) |
| C5 | Partial fan-out on scheduler failure (mid-run crash means some users are not enqueued) | Users not yet enqueued when the scheduler crashes skip the week | Principle 4: Data integrity & durability | Re-running the scheduler is safe (idempotent). Ops can manually re-trigger. Weekly digest is a non-critical notification — one missed week is acceptable. | If SLO requires guaranteed delivery to all users every week |

---

## 13. Open Risks & Callouts

1. **Activity table schema unknown.** The exact table name, columns, and indexes for workspace activity have not been confirmed. The query design in D7/D8 assumes a well-indexed activity table. If the activity data is denormalized, aggregated, or spread across multiple tables, the query strategy may need revisiting. This is the highest-risk unknown.

2. **SendGrid deliverability at Monday peak.** Sending ~100k emails within a Monday morning window may trigger SendGrid's IP warming or deliverability thresholds if this is a new sending pattern. Staged rollout (C5 mitigation) and monitoring delivery rates in the first weeks is essential.

3. **Timezone data quality.** If a significant fraction of users have `NULL` or invalid timezone values, all will receive the email at 8:00 AM UTC, creating an unexpected email spike at one absolute time. Audit timezone coverage before enabling at full scale.

4. **Scheduler library choice.** If Sidekiq-Cron is not available and a simple `cron` expression or external scheduler (e.g., Heroku Scheduler) is used, the hourly Monday trigger needs special handling to avoid running on other days.

5. **Large workspace activity sets.** For users in very active workspaces, the uncapped activity query (before the LIMIT 10) may return many rows. The query should use `LIMIT` early (not post-fetch) to avoid fetching thousands of rows per user. Confirm query plan.

---

## 14. Out of Scope

Per the blueprint's explicit out-of-scope list and this design's scope:

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering of the digest.
- Email template design and HTML/CSS (this design covers the data pipeline; template implementation is a separate concern).
- Preference UI for users to toggle digests on/off within the app (this design covers the backend unsubscribe mechanism only).
- A/B testing of digest content or send time.
- Digest analytics (open rates, click rates) beyond what SendGrid provides by default.
- Manual backfill of historical weeks.
- Multi-language / i18n of the digest email content.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Assumed (A10) | §6 — background pipeline; unsubscribe p95 < 200ms; no user-visible latency |
| A2 Throughput & scale | Resolved | §6 — 100k users, ~4–8k jobs/hour peak; within Sidekiq + SendGrid limits |
| A3 Concurrency & consistency | Resolved (D1) | §7, D1 — unique constraint on `(user_id, iso_week)` is the concurrency control |
| A4 Availability & reliability | Resolved (D5) | §7 — 3-retry + drop strategy per blueprint deviation |
| A5 Data integrity & durability | Resolved (D1, D4) | §4 — unique constraint + status transitions; 90-day retention |
| A6 Caching & freshness | Resolved (C4) | §6 — no cache; freshness is fully preserved; cost acceptable |
| A7 Cost | Resolved | §6, §5 — ~$100/week at 100k users on standard SendGrid plan; no runaway risk |
| A8 Security & privacy | Resolved (D6, D7) | §8 — HMAC unsubscribe, permission-filtered query, PII handling |
| A9 Observability | Resolved | §9 — metrics, structured logs, primary alert on drop rate |
| A10 Maintainability & simplicity | Resolved | §2, §3 — fan-out follows existing Sidekiq patterns; no novel components introduced |
| A11 Testability | Resolved | §5 — injectable `DigestSendService`; SendGrid sandbox for integration tests; deterministic time seams for scheduler |
| A12 Deployability & rollout | Resolved (D9) | §10 — feature flag, staged rollout, additive migrations |
| A13 Backward compatibility | Resolved | §4 — additive schema changes only; no existing contracts changed |
| A14 Accessibility & device/env | N/A | Email rendering is handled by email client; HTML email accessibility is a template concern, out of scope for this design |
| B1 Placement / module taxonomy | Resolved | §2 — `DigestSchedulerJob`, `DigestUserJob` (Sidekiq workers), `DigestQueryService`, `DigestAssemblerService`, `DigestSendService`, `UnsubscribeController` |
| B2 Data model & persistence | Resolved | §4 — `digest_sends` table, `users` column additions, schema and invariants defined |
| B3 API surface & schemas | Resolved | §2 — one HTTP endpoint: `GET/POST /digest/unsubscribe?token=…`; no other API surface |
| B4 Async / background work | Resolved (D2, D3) | §2, D2, D3 — Sidekiq fan-out with hourly timezone-bucket scheduler |
| B5 External services & contracts | Resolved (D5) | §5 — SendGrid auth, rate limits, failure modes, test strategy |
| B6 Frontend integration | N/A | No frontend state changes. The digest email links open existing app URLs; unsubscribe is a standalone HTTP endpoint. No new frontend components. |
| B7 Feature flags & rollout | Resolved (D9) | §10 — `weekly_digest_enabled` flag, staged rollout plan |
| B8 Error handling | Resolved (D5) | §7 — per-layer: DB (unique constraint violation handled); Sidekiq (retry-then-exhausted callback); SendGrid (4xx drop, 5xx retry) |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Every Monday morning, each user receives a digest covering the previous seven days | Behavior | D2, D3, §2 | Hourly scheduler on Monday enqueues per-user jobs; window is rolling 7 days to Monday 00:00 local |
| Email contains: headline summary, counts (new/completed/commented), up to ten highlighted items with links | Behavior | D4, §4 | Assembler caps highlighted items at 10; "+N more" note if excess; count fields in email |
| Clicking item link opens that item in the app | Behavior | N/A | Link URL construction is a template implementation detail; design ensures items are selected with their IDs available for link generation |
| Each email has a one-click unsubscribe link in the footer | Behavior | D6, §8 | HMAC-signed token in footer URL |
| Digest covers rolling seven days ending Monday 00:00 local time | Behavior | D3, D8 | Window computed at job-run time using user's local timezone |
| Send time is 8:00 AM in each user's configured timezone | Behavior | D3, §6 | Hourly bucket scheduler; ±59min precision (Compromise C1) |
| Different timezones receive email at different absolute times | Behavior | D3 | Timezone bucketing means each offset is processed at its appropriate UTC hour |
| User with digests turned off receives nothing | Behavior | D2, §2 | Scheduler filters `digest_enabled = true`; unsubscribe sets this to false |
| No email sent if user had no relevant activity in the past week | Behavior | D4 | Job checks activity count; exits with `skipped` status if empty |
| Each user receives at most one digest email per week | Behavior | D1 | Unique constraint on `(user_id, iso_week)` enforces this |
| Highlighted items chosen by recency, capped at 10; "+N more" if there were more | Behavior | D4, §4 | `ORDER BY created_at DESC LIMIT 10` in query; assembler adds "+N more" count if `total_count > 10` |
| Unsubscribing is immediate and takes effect before the next Monday | Behavior | D6, §2 | `UnsubscribeController` writes `digest_enabled = false` synchronously; scheduler reads this flag fresh each run |
| Brand-new user joined mid-week | Edge case | D8 | Window lower bound is `MAX(Monday - 7 days, user.created_at)` |
| User with activity but in a deleted workspace | Edge case | D7 | Activity query filters out deleted workspaces |
| User whose timezone is not set | Edge case | A8, §4 | `digest_timezone = NULL` → treated as UTC in query and scheduler bucketing |
| User changes timezone on Sunday night | Edge case | D3 | Scheduler reads current timezone at job-run time; new timezone used for next Monday |
| Email provider down or rejects at send time → retry then drop for the week | Deviation | D5, §7 | Sidekiq retry (3 attempts); `sidekiq_retries_exhausted` marks `dropped` |
| Weekly job triggered twice → user still receives only one digest | Deviation | D1, §7 | Unique constraint prevents second send regardless of re-trigger |
| Job delayed and starts late → content unaffected, send time may slip | Deviation | D3, §7 | Window computed at run time; late start only affects send time |
| Unsubscribe link must act only on account it was issued for; must not be guessable | Adversarial | D6, §8 | HMAC-signed token encoding `user_id`; validation rejects tampered tokens |
| Digest content must only include items the user is allowed to see | Adversarial | D7, §8 | Permission filter applied in the activity query |

---

## Appendix A: Captured Inputs

*This session was run autonomously — no human was available to answer questions. The following records the decisions made, the recommendations applied, and what would have been asked of a human interviewer if one had been present. Assumptions are resolved using the generic design principles lens, as this is an off-repo task (kite-arch-compass is not applicable).*

---

### System shape: fan-out vs. single job
- **Question:** Should the digest pipeline be a single batch job processing all users, or fan out individual worker jobs per user?
- **Recommendation given:** Fan-out per user via Sidekiq — independent retryability, natural backpressure, partial-failure isolation. Principle 6 (idempotency and bounded operations) and Principle 3 (high cohesion, loose coupling).
- **Autonomous decision:** Fan-out adopted (D2).
- **Notes:** At 100k users this creates 100k Sidekiq jobs per week — an acceptable overhead given Sidekiq's throughput characteristics.

---

### Idempotency / dedup mechanism
- **Question:** How do we prevent a user receiving more than one digest per week, including on job-triggered-twice scenarios?
- **Recommendation given:** Insert-or-skip on `digest_sends(user_id, iso_week)` with a unique constraint. Atomic, durable, no distributed lock needed. Principle 6 (idempotency) + Principle 9 (illegal states unrepresentable).
- **Autonomous decision:** Unique constraint pattern adopted (D1).
- **Notes:** Alternative of a Redis distributed lock was considered and rejected for adding an infrastructure dependency without benefit.

---

### Timezone scheduling granularity
- **Question:** Should the scheduler fire once per minute, once per hour, or some other cadence to hit each user's 8 AM local time?
- **Recommendation given:** Hourly cadence. Delivers within a 59-minute window of the target; operationally simple; no per-user job scheduling required.
- **Autonomous decision:** Hourly bucket scheduler adopted (D3). Send-time precision compromise recorded (C1).
- **Would have asked human:** "Is up to 59-minute precision acceptable for this weekly digest, or do you need closer to exact 8:00 AM delivery?" Assumed yes given the digest is non-time-sensitive.

---

### Empty digest handling
- **Question:** At what point do we check whether a user has activity — at enqueue time or at job-run time?
- **Recommendation given:** At job-run time. Avoids loading the full query into the scheduler; handles edge cases like activity arriving after enqueue.
- **Autonomous decision:** Check at job-run time (D4).

---

### Retry-then-drop vs. retry indefinitely
- **Question:** If SendGrid is down at a user's send time, do we retry into the afternoon or simply drop?
- **Recommendation given:** Retry up to 3 times (Sidekiq default), then drop. The blueprint makes the product decision explicit: late is worse than skipped.
- **Autonomous decision:** 3-retry-then-drop adopted (D5). Compromise recorded (C2) noting this is product-driven, not a system compromise.

---

### Unsubscribe token design
- **Question:** How should unsubscribe tokens be structured to satisfy non-guessability and account-specificity?
- **Recommendation given:** HMAC-SHA256 stateless token encoding `user_id` and `iso_week`. No database table required; tokens auto-expire weekly.
- **Autonomous decision:** HMAC token design adopted (D6).
- **Notes:** Would have asked human: "Do you have a compliance or regulatory requirement for revocable unsubscribe tokens?" Assumed no. If yes, a DB-backed token table would be needed.

---

### Activity permission filtering
- **Question:** Where in the pipeline should the permission filter be applied — in the SQL query or post-fetch in the assembler?
- **Recommendation given:** In the SQL query. Never fetch data the user isn't authorized to see, even if it will be filtered later. Principle 11 (security by design).
- **Autonomous decision:** Query-level filter adopted (D7).

---

### Feature flag
- **Question:** Should this feature launch behind a flag?
- **Recommendation given:** Yes — provides a kill switch and enables staged rollout. Principle 7 (reversible decisions).
- **Autonomous decision:** `weekly_digest_enabled` flag adopted (D9).

---

### Caching
- **Question:** Should activity query results be cached (e.g., in Redis) to reduce DB load?
- **Recommendation given:** No. Each user's query is unique, time-scoped, and used exactly once per week. A cache would have near-100% eviction rate. Principle 1 (simplicity) and Principle 13 (cache invalidation is a design decision — answered here as "don't cache").
- **Autonomous decision:** No cache layer (C4).

---

### Last-call (P4)
- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **Response:** No human available. The following items were identified as open risks for a human reviewer: (1) activity table schema unknown — highest-risk assumption; (2) SendGrid deliverability warming at scale; (3) timezone data quality audit; (4) Sidekiq-Cron library availability confirmation. All recorded in §13.
