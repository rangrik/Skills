# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../inputs/weekly-digest-blueprint.md](../inputs/weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The weekly digest is a background-only feature: no synchronous user-request path is involved. A Sidekiq cron job fires once per minute, inspects a `digest_send_schedule` table to find users whose local 8:00 AM has arrived, enqueues a per-user `DigestEmailJob`, and marks each row as dispatched for the week. Each job queries Postgres for the past seven days of scoped workspace activity, skips users with no activity or digests disabled, assembles the email payload, and calls SendGrid's Mail Send API. Idempotency is enforced through a `digest_deliveries` table (unique constraint on `user_id + iso_week`), which prevents double-send even if the cron fires twice. **The single most important architectural choice is the two-table dispatch model** — separating "when to send" (`digest_send_schedule`) from "what was sent" (`digest_deliveries`) — because it isolates the timezone-fan-out scheduling concern from the idempotency/delivery-audit concern and keeps both simple.

---

## 2. System Placement

This feature lives entirely in the **backend service layer**. There is no new API route (no frontend interaction path), no LLM routine, and no frontend state change required. Components touched:

```
[Cron scheduler]
      │  fires every minute
      ▼
DigestSchedulerJob   (Sidekiq cron job)
  – reads digest_send_schedule
  – enqueues DigestEmailJob per eligible user
  – writes dispatch record to digest_send_schedule.dispatched_at
      │  per-user jobs
      ▼
DigestEmailJob       (Sidekiq worker)
  – queries Postgres for scoped activity (past 7 days)
  – checks digest enabled + activity non-empty
  – checks digest_deliveries for idempotency
  – renders email template
  – calls SendGrid Mail Send API
  – writes row to digest_deliveries on success
      │
      ▼
SendGrid Mail Send API  (external)
```

**Data flows in:** Postgres (user preferences, workspace activity, item permissions). **Data flows out:** SendGrid (email delivery).

**Modules touched:**
- New Sidekiq jobs: `DigestSchedulerJob`, `DigestEmailJob`
- New Postgres tables: `digest_send_schedule`, `digest_deliveries`
- New email template: `digest_email.html.erb` (or equivalent)
- Existing user/preferences model: read-only (add `digest_enabled` column + `timezone` column if not present)

---

## 3. Architecture Decisions

### D1. Per-user dispatch via background job fan-out, not a single batch query

- **Decision:** The cron job (`DigestSchedulerJob`) runs every minute and enqueues one `DigestEmailJob` per eligible user. Each job is independent: it fetches its own data, sends its own email, and records its own delivery.
- **Why:** Keeps each unit of work small, bounded, and independently retryable (Design for failure; Idempotency & bounded operations). A single large batch job that fails mid-way would require complex resumption logic; individual per-user jobs fail and retry independently without affecting others. This also naturally handles the timezone fan-out: different users become eligible at different minutes, and the cron simply enqueues whoever is due.
- **Alternatives considered:**
  - *Single SQL query that sends all emails in one job:* simpler code but a single failure kills all remaining sends; partial progress is opaque and resumption is fragile.
  - *One job per timezone group:* reduces job count but reintroduces partial-failure risk and adds unnecessary grouping logic.
- **Trade-off accepted:** Higher job count (one job per active user per week). At typical SaaS scale (tens of thousands of users), Sidekiq handles this trivially; at very large scale (millions), a batching layer would be warranted — see Open Risks.

---

### D2. Two-table model: `digest_send_schedule` + `digest_deliveries`

- **Decision:** Maintain two separate tables. `digest_send_schedule` holds one row per user with their next scheduled send time (derived from timezone) and a dispatched flag. `digest_deliveries` holds one immutable row per successfully sent digest (user + ISO week), enforced by a unique constraint.
- **Why:** Separates two distinct concerns (Get the data model right; High cohesion, loose coupling). The schedule table answers "who is due right now?" The deliveries table answers "was this user's digest for this week already sent?" — which is the idempotency gate. Mixing them would create a single row with complex state transitions; separating them keeps each table's invariants simple and independently queryable.
- **Alternatives considered:**
  - *Single `digest_records` table with a status enum:* tempting but conflates scheduling state with delivery state; a send that's "dispatched but not confirmed" becomes an ambiguous state that's hard to reason about.
  - *Redis-based idempotency key:* faster lookup but introduces another dependency and loses the audit trail; the deliveries table is also the history log.
- **Trade-off accepted:** Two tables to maintain instead of one. Migrations are additive; the extra table is lightweight.

---

### D3. Idempotency via unique constraint on `(user_id, iso_week)` in `digest_deliveries`

- **Decision:** Before calling SendGrid, `DigestEmailJob` attempts an `INSERT INTO digest_deliveries (user_id, iso_week) VALUES (...)`. If the row already exists (unique violation), the job exits cleanly without sending. The row is only inserted after a successful SendGrid response.
- **Why:** The blueprint's deviation scenario requires exactly-once delivery even if the weekly job fires twice (Idempotency & bounded operations). A database unique constraint is the simplest, most reliable enforcement point — it works across multiple workers and survives process restarts. It does not rely on job-level deduplication (which Sidekiq's pro-tier uniqueness feature would provide, but cannot be assumed here).
- **Alternatives considered:**
  - *Sidekiq unique jobs middleware:* effective but requires Sidekiq Pro or an additional gem; not assumed available.
  - *Application-level check-then-insert (SELECT then INSERT):* subject to a race condition between two concurrent jobs for the same user.
- **Trade-off accepted:** There is a narrow window where two jobs can both pass the pre-check query before either inserts; the unique constraint is the backstop, so the second job will hit a constraint violation and exit cleanly. One extra DB round-trip per send.

---

### D4. Activity query scoped to the 7-day window ending Monday 00:00 local time

- **Decision:** The activity query uses `WHERE created_at >= :window_start AND created_at < :window_end`, where `window_start = monday_00_00_local - 7.days` and `window_end = monday_00_00_local`. Both are computed in UTC before the query. The job receives the user's `scheduled_send_at` timestamp from which to derive the window.
- **Why:** Matches the blueprint's "rolling seven days ending Monday 00:00 local time" rule exactly. Computing window bounds in the job (rather than in SQL) keeps the query simple and the bounds auditable in logs (Observability from day one; Principle of least surprise).
- **Alternatives considered:**
  - *Compute in SQL using PostgreSQL timezone functions:* more opaque, harder to test, depends on database timezone configuration.
- **Trade-off accepted:** The window is computed at job execution time, not at schedule time; for a delayed job start, the window shifts slightly (the blueprint explicitly accepts this: "content is unaffected").

---

### D5. Permission-scoped activity query

- **Decision:** The activity query joins through workspace membership: only items the user is a member of (directly or via workspace) are included. Deleted workspaces are excluded via an `EXISTS` check on the workspace table.
- **Why:** The blueprint's adversarial scenario requires that digest content only include items the user is authorized to see (Security & privacy by design; Make illegal states unrepresentable). Over-fetching and then filtering in application code would be risky; the join ensures the DB enforces visibility.
- **Alternatives considered:**
  - *Fetch all activity then filter in Ruby:* simpler query but risky — a bug in the filter layer could leak items across user/workspace boundaries.
- **Trade-off accepted:** The query is more complex (several joins). It must be covered by a query plan / index strategy (see §6).

---

### D6. Unsubscribe token: signed, user-scoped, durable

- **Decision:** Each email's unsubscribe link contains a signed token generated as `HMAC-SHA256(secret_key, "digest-unsubscribe:#{user_id}")`. The token is deterministic for a given user (no expiry), checked on arrival, and on valid match sets `users.digest_enabled = false`.
- **Why:** The blueprint's adversarial scenario requires the link act only on the account it was issued for and not be guessable (Security & privacy by design). A deterministic HMAC means no extra table row to store the token, is not guessable without the key, and does not expire (so links in old emails still work). The trade-off of no expiry is acceptable because the action is benign (unsubscribing yourself).
- **Alternatives considered:**
  - *Random token stored in DB:* more flexible (revocable) but requires a new table and a lookup join on every unsubscribe click.
  - *Signed JWT with expiry:* adds JWT dependency and creates confusing UX if old links expire. Expiry is not necessary for unsubscribe.
  - *SendGrid's native unsubscribe groups:* delegates the action to SendGrid, which means the opt-out state lives outside our DB — risky for correctness on re-send checks.
- **Trade-off accepted:** Tokens don't expire. Changing `secret_key` invalidates all outstanding links — must be treated as a one-way door.

---

### D7. Failure handling: finite retries, drop-on-exhaustion (no late delivery)

- **Decision:** `DigestEmailJob` uses Sidekiq's built-in retry with a cap of 5 attempts (exponential backoff, max ~20 minutes of retries). If all retries are exhausted, the job is moved to Sidekiq's dead queue and a structured log entry is emitted. The email is **not** delayed to a later day.
- **Why:** The blueprint is explicit: "a digest that arrives late is worse than one skipped." Honoring this means we must not re-enqueue failed jobs outside the Monday window (Design for failure; Principle of least surprise). Finite retries with drop-on-exhaustion is also the safest choice for an email feature — an email that arrives Tuesday claiming to be a "Monday digest" degrades trust more than silence.
- **Alternatives considered:**
  - *Unlimited retries:* violates the blueprint's drop-vs-late-delivery rule.
  - *Alerting and manual re-send:* operationally heavy; acceptable as a manual escape hatch but not the default path.
- **Trade-off accepted:** A user affected by sustained SendGrid downtime (>20 min) will miss their digest for the week. The dead queue provides an audit trail for operations.

---

### D8. Email rendering: server-side HTML template, no client-side logic

- **Decision:** The digest email is rendered entirely on the server using a static HTML template (e.g., ERB or equivalent). No JavaScript. Item links are absolute URLs pointing to the app. The "+N more" count is computed server-side.
- **Why:** Email clients strip JavaScript; server-side rendering is the only reliable approach (Simplicity first). Absolute URLs ensure links work regardless of how the email client renders them (Principle of least surprise).
- **Alternatives considered:**
  - *MJML or similar email DSL:* adds a build step and dependency; acceptable if the team already uses it, but not assumed.
- **Trade-off accepted:** Email HTML must be tested across major clients (Outlook, Gmail, Apple Mail) manually or with a tool like Litmus — this is a launch task, not captured in this design.

---

## 4. Data Model & Persistence

### Table: `digest_send_schedule`

Holds one row per user. Updated when the user's timezone changes.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `user_id` | bigint NOT NULL FK → users | unique |
| `timezone` | varchar(64) NOT NULL | IANA timezone string; defaults to `'UTC'` if user has none |
| `next_send_at` | timestamptz NOT NULL | Next Monday 8:00 AM in the user's timezone, stored as UTC |
| `dispatched_at` | timestamptz | Set when `DigestSchedulerJob` enqueues the job for this cycle; NULLed after the window passes and `next_send_at` is advanced |
| `created_at` | timestamptz NOT NULL | |
| `updated_at` | timestamptz NOT NULL | |

**Indexes:**
- `UNIQUE (user_id)`
- `INDEX (next_send_at) WHERE dispatched_at IS NULL` — the scheduler's hot query

**Invariants:**
- `next_send_at` always points to a future Monday 8:00 AM local (in UTC).
- `dispatched_at IS NOT NULL` means the job for this cycle has been enqueued; prevents the cron from enqueueing twice.
- After each cycle completes (regardless of delivery outcome), a cleanup sweep advances `next_send_at` to the following Monday and resets `dispatched_at` to NULL.

**When to advance `next_send_at`:** A second background job (`DigestScheduleAdvancerJob`) runs each Tuesday at 00:00 UTC, finds rows where `next_send_at < NOW()`, advances them by exactly 7 days, and clears `dispatched_at`. This keeps the schedule current.

---

### Table: `digest_deliveries`

Immutable delivery log. One row per successfully sent digest.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `user_id` | bigint NOT NULL FK → users | |
| `iso_week` | varchar(8) NOT NULL | Format: `YYYY-WNN` (e.g. `2026-W21`) — identifies the calendar week |
| `sent_at` | timestamptz NOT NULL | Timestamp of successful SendGrid acceptance |
| `sendgrid_message_id` | varchar(255) | SendGrid's `X-Message-Id` response header for tracing |
| `created_at` | timestamptz NOT NULL | |

**Indexes:**
- `UNIQUE (user_id, iso_week)` — idempotency constraint (D3)
- `INDEX (user_id)` — for user-facing audit queries (future)

---

### Column additions to `users` (assumed existing table)

| Column | Type | Notes |
|---|---|---|
| `digest_enabled` | boolean NOT NULL DEFAULT true | Whether this user receives digests |
| `timezone` | varchar(64) | IANA timezone; NULL means use UTC (edge case in blueprint) |

If `timezone` already exists on the `users` table in the codebase, this column addition is skipped. The assumption is that it may not exist (see §11, A2).

---

### Migration shape

1. Add `digest_enabled` (boolean, default true) to `users`. Non-breaking, no backfill needed.
2. Add `timezone` to `users` if absent. Non-breaking.
3. Create `digest_send_schedule` table with indexes.
4. Create `digest_deliveries` table with unique constraint.
5. Backfill `digest_send_schedule`: for every user where `digest_enabled = true`, compute their next Monday 8:00 AM local and insert a row. This backfill runs once, can be a Rake task or migration.

Migrations are strictly additive and reversible except for the backfill (which can be undone by truncating the schedule table).

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid Mail Send API** (`POST /v3/mail/send`) | Deliver the weekly digest email to each user | API key stored in application secrets / environment variable (`SENDGRID_API_KEY`); never in code or logs | Free tier: 100 emails/day; Essentials: 50k–100k/month. At typical SaaS scale, well within plan. No per-call cost beyond plan tier. Rate limit: 3,000 requests/second (SendGrid limit — well above our burst). | HTTP 4xx (bad request / invalid address): log, record in dead queue, do not retry (permanent failure). HTTP 5xx / timeout: retry up to 5× via Sidekiq backoff. On all-retries-exhausted: drop, log to dead queue, emit alert metric. | Wrap the SendGrid client behind a `DigestMailer` interface; inject a stub/mock in tests. Use SendGrid's sandbox mode (`mail_settings.sandbox_mode.enable: true`) in CI to exercise the real HTTP path without actual delivery. |

**External-system grammar note:** SendGrid's `mail/send` payload structure (personalizations, content types, tracking settings) carries enough surface area that a probe-tested skill would be the right home for encoding it. This is called out as a follow-up rather than fully enumerated here.

---

## 6. Performance, Scale & Caching

### Latency targets

This feature has **no synchronous user-visible latency**. All work is background. The implicit SLO is:

- **Scheduling jitter:** users receive their email within ±1 minute of 8:00 AM local (the cron fires every minute). Acceptable per blueprint ("send time may slip but content is unaffected").
- **Job end-to-end time (enqueue → sent):** target < 30 seconds p95 per user, dominated by the activity query and the SendGrid API call. No explicit user-facing target; this informs queue sizing.

### Expected load

| Dimension | Estimate | Notes |
|---|---|---|
| Users receiving digest per week | ~10,000 (initial) | Grows with user base |
| Peak job rate | ~2,000 jobs/hour | Clustered around Monday 8 AM in major timezones (UTC, US/Eastern, US/Pacific, EU/Berlin); not perfectly spread |
| Activity query per job | 1 Postgres query | Scoped join; bounded result set |
| SendGrid calls per week | Same as user count | One per successfully sent digest |

No fan-out concern: each job touches exactly one user's data.

### Concurrency

- `DigestSchedulerJob` is a short-running cron job that only does reads + enqueues. It should run on a **dedicated low-concurrency queue** (`digest_scheduler`) to avoid blocking other work.
- `DigestEmailJob` workers run on a separate `digest_email` queue with concurrency tuned to the SendGrid rate limit headroom. Starting at 10 concurrent workers is safe; increase with observation.
- Sidekiq queue priorities: `default > digest_email > digest_scheduler` (digest work should not starve product jobs).

### Caching

There is **no application-layer cache** in this design. Reasons:
- The activity query runs once per user per week — there is no repeated fetch to amortize.
- Email content is assembled once and immediately handed to SendGrid; it is never stored or re-used.
- Postgres performance for the scoped activity query is addressed via indexes (see §4) rather than a cache layer.

**Freshness:** not applicable — there is no cached data.

### Database indexes (performance-critical)

- `digest_send_schedule (next_send_at) WHERE dispatched_at IS NULL` — the scheduler runs this every minute; must be fast.
- Activity tables: the activity query joins on `user_id` and `workspace_id` with a `created_at` range filter. Indexes on `(workspace_id, created_at)` and `(user_id, created_at)` on the relevant activity tables are assumed to exist or must be added. If they don't exist, this is a launch blocker.

---

## 7. Reliability & Failure Handling

| Failure scenario | Detection | Behavior | Blueprint reference |
|---|---|---|---|
| SendGrid returns 5xx or times out | Sidekiq retry count increments | Retry up to 5× with exponential backoff; if all fail, job → dead queue, metric emitted | Deviation: "retried; if still fails, dropped for the week" |
| SendGrid returns 4xx (bad address / policy reject) | HTTP status code | Do not retry (permanent failure); log error with user_id and SendGrid error code; job completes | Deviation: same |
| `DigestSchedulerJob` fires twice in same cycle | `dispatched_at IS NOT NULL` check | Second fire finds row already dispatched; skips enqueue. No duplicate jobs. | Deviation: "job triggered twice" |
| `DigestEmailJob` runs twice for same user+week | `INSERT ... ON CONFLICT` on `digest_deliveries` | Second job detects unique constraint, exits cleanly without calling SendGrid | Deviation: "job triggered twice" |
| Workspace deleted before send | `EXISTS` check in activity query | No workspace → no activity rows → empty digest → no email sent | Edge case: "workspace deleted" |
| User disables digest between schedule and send | `digest_enabled` check at job start | Job exits early; no email | Rule: "digest turned off → receives nothing" |
| Activity query returns zero rows | Row count check | Job exits early; no email sent | Rule: "no relevant activity → no email" |
| `DigestSchedulerJob` starts late | Window bounds computed at job runtime | Content window is unaffected; only send time slips | Deviation: "job delayed" |
| Postgres connection failure | Exception bubbles to Sidekiq | Job retries with standard backoff | — |

**Idempotency keys:** The `(user_id, iso_week)` unique constraint in `digest_deliveries` is the system-wide idempotency guarantee. It is the backstop for all double-send scenarios.

**Retry cap enforcement:** `sidekiq_options retry: 5` on `DigestEmailJob`. The dead queue is monitored (see §9).

**No circuit breaker:** Not warranted at this scale. If SendGrid is broadly down, all jobs will fail and retry, and the dead queue will grow — an alert fires (see §9). A circuit breaker could be added later if the SendGrid integration grows in scope.

---

## 8. Security & Privacy

### Authentication & authorization

- The scheduler and email jobs run as internal Sidekiq workers — no user-facing auth path. No API route is exposed.
- The **unsubscribe endpoint** (`GET /digest/unsubscribe?token=<token>`) is the only new public-facing route. It must:
  - Accept only GET (action is idempotent and bookmarkable).
  - Validate the HMAC token before taking any action (`ActiveSupport::SecurityUtils.secure_compare` to prevent timing attacks).
  - Look up the user by `user_id` embedded in the token and set `digest_enabled = false`.
  - Return a simple confirmation page (no login required — the token is the credential).
  - Be rate-limited (e.g., 20 requests/minute per IP) to prevent token enumeration brute-force attempts.

### Unsubscribe token security (D6)

- Token: `Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', DIGEST_HMAC_SECRET, "digest-unsubscribe:#{user_id}"))`
- `DIGEST_HMAC_SECRET` stored in application secrets, never hardcoded.
- Token is deterministic for a given user — a future rotate of the secret invalidates all outstanding links (document this operational procedure).

### PII handling

- Email addresses are passed to SendGrid and are subject to SendGrid's data processing agreement (DPA). Ensure the DPA is in place.
- Digest content (item titles, comment snippets) is PII. It travels only in the SendGrid API call (TLS enforced). It is **not** stored locally after send.
- `digest_deliveries` stores `user_id` + `iso_week` only — no content, no email address.
- Logs must not contain email body content or full item titles. Log `user_id`, `iso_week`, `sendgrid_message_id`, and error codes only.

### Input trust boundaries

- The only untrusted input is the `token` query parameter on the unsubscribe endpoint. Validation: HMAC check before any DB write.
- Activity query parameters (user_id, date bounds) are system-internal (set by the job, not user-supplied). No injection risk.

### Digest content authorization

- The activity query joins through workspace membership (D5). A user can only see items in workspaces they belong to, and only if that workspace is not deleted. This is enforced at query time, not in application code.

---

## 9. Observability

### Logs (structured, per job)

| Event | Level | Fields |
|---|---|---|
| Job enqueued | INFO | `user_id`, `iso_week`, `scheduled_send_at` |
| Job skipped (no activity) | INFO | `user_id`, `iso_week`, `reason: "no_activity"` |
| Job skipped (digest disabled) | INFO | `user_id`, `iso_week`, `reason: "digest_disabled"` |
| Job skipped (already sent — idempotency) | INFO | `user_id`, `iso_week`, `reason: "already_delivered"` |
| Email sent successfully | INFO | `user_id`, `iso_week`, `sendgrid_message_id`, `duration_ms` |
| SendGrid permanent failure (4xx) | ERROR | `user_id`, `iso_week`, `sendgrid_status`, `sendgrid_error` |
| Job exhausted retries | ERROR | `user_id`, `iso_week`, `attempt_count` |
| Scheduler cycle summary | INFO | `eligible_count`, `enqueued_count`, `already_dispatched_count`, `duration_ms` |

### Metrics (increment/histogram)

| Metric | Type | Notes |
|---|---|---|
| `digest.jobs.enqueued` | counter | Per scheduler cycle |
| `digest.jobs.sent` | counter | Successful sends per week |
| `digest.jobs.skipped` | counter | Tagged by reason |
| `digest.jobs.failed_permanent` | counter | 4xx from SendGrid |
| `digest.jobs.dead` | counter | All retries exhausted |
| `digest.send_duration_ms` | histogram | p50/p95 per job |
| `digest.activity_query_duration_ms` | histogram | DB query time |

### Alerts

| Alert | Condition | Severity |
|---|---|---|
| **Dead queue growth** | `digest.jobs.dead` > 0 in any Monday window | WARNING |
| **Send rate collapse** | `digest.jobs.sent` < 50% of `digest.jobs.enqueued` on a Monday | CRITICAL |
| **Scheduler silence** | No `digest.jobs.enqueued` logged between 07:55–08:05 UTC on Monday | CRITICAL |
| **High permanent failure rate** | `digest.jobs.failed_permanent` > 5% of enqueued | WARNING |

### The one signal that proves this feature is healthy

> **`digest.jobs.sent` count on each Monday morning is within 10% of the expected eligible-user count** (eligible = digest enabled + has activity). If this metric is healthy, the entire pipeline — scheduler, queue, activity query, SendGrid, idempotency — is functioning.

### Traces

Each `DigestEmailJob` should emit a trace span covering: activity query, email render, SendGrid call. This allows p95 breakdown per step without log parsing.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a boolean flag `weekly_digest_enabled` (default: `false`). The `DigestSchedulerJob` checks this flag at the top of its run and exits immediately if disabled. This makes the feature fully reversible at the scheduler level.

Flag rollout plan:
1. Deploy migrations (additive only — safe at any time).
2. Run backfill for `digest_send_schedule`.
3. Enable flag for internal users / beta cohort (e.g., 5%).
4. Monitor metrics and dead queue for one full Monday cycle.
5. Ramp to 25%, 50%, 100% on successive Mondays.

### Migration / backfill order

1. Run DB migrations (steps 1–4 from §4 migration shape). Zero downtime — all additive.
2. Run `digest_send_schedule` backfill as a Rake task (`rake digest:backfill_schedule`). Idempotent (upsert). Can be run before or after the flag is enabled.
3. Deploy the Sidekiq job code.
4. Enable the feature flag.

**Reversibility:** Disabling the flag stops all scheduling immediately. The tables remain but no jobs are enqueued. No data is deleted. Fully reversible (two-way door) until the unsubscribe token secret is rotated or the tables are dropped.

### Deployment coordination

- No frontend changes required.
- No new API routes required except the unsubscribe endpoint (must be deployed before the first email send).
- Sidekiq queues `digest_scheduler` and `digest_email` must be added to the worker configuration before deploy.

### Operability runbook items (to create at launch)

- How to manually re-send a missed digest for a user.
- How to drain and inspect the digest dead queue.
- How to rotate `DIGEST_HMAC_SECRET` and communicate new links to affected users.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Sidekiq cron (e.g., `sidekiq-cron` or `sidekiq-scheduler` gem) is already configured in the application | Common in Sidekiq-based Rails apps; most apps using Sidekiq for background jobs have cron support | **Yes** — confirm the gem is available |
| A2 | A `timezone` field on the `users` table either exists or can be added non-breakingly | Blueprint states timezone-based send is a requirement; some form of timezone storage must exist | **Yes** — confirm existing column name/presence |
| A3 | `digest_enabled` is a new boolean column on `users`, defaulting to `true` | Blueprint says "a user with digests turned off receives nothing" — this implies a per-user toggle | Low risk assumption |
| A4 | The application has an IANA timezone library available (e.g., `ActiveSupport::TimeZone` in Rails) | Standard in Rails; required for computing 8:00 AM in user-local time | **Yes** if not Rails |
| A5 | Workspace activity (new items, completed items, comments) is stored in queryable Postgres tables with `created_at` timestamps and `workspace_id` / `user_id` foreign keys | The blueprint's happy path requires querying past-week activity; standard schema shapes support this | **Yes** — confirm table names and schema |
| A6 | "Items the user is allowed to see" can be determined via a workspace membership join, without a more complex ACL system | Blueprint says "only items that user is allowed to see"; a membership join is the simplest correct model | **Yes** — confirm if there is a more complex permission model |
| A7 | SendGrid is already integrated in the application (API key provisioned, HTTP client present) | Stack was specified as SendGrid; reasonable to assume basic integration exists | **Yes** — confirm or note if greenfield |
| A8 | Email volume at launch is below 100,000/week (SendGrid plan assumption) | Initial SaaS scale; the design is not optimized for millions of users | Low risk at launch; revisit at scale |
| A9 | The application uses Rails (or an equivalent Ruby framework where ERB templates and ActiveSupport are available) | Postgres + Sidekiq stack strongly implies a Ruby/Rails app | **Yes** — confirm if not Rails |
| A10 | The feature flag system is a simple DB-backed or environment-variable boolean; no complex targeting required for the initial rollout | Standard for most apps at this stage | Low risk |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Drop failed digests rather than delay them | Users who experience a sustained SendGrid outage on their Monday morning miss their digest entirely for that week | Design for failure — we're not retrying indefinitely | Blueprint explicitly prefers silence over late delivery: "a digest that arrives late is worse than one skipped." Honoring the product intent outweighs maximum delivery rate. | Reconsider if user complaints about missed digests are a significant support driver |
| C2 | No application-layer cache for activity queries | Each job re-queries Postgres fresh | Caching would reduce DB load | Activity is queried once per user per week; the re-query cost is negligible and caching would add complexity without benefit | Re-evaluate if digest is extended to daily frequency or query volume spikes measurably |
| C3 | Deterministic (non-expiring) unsubscribe tokens | Cannot invalidate an individual user's token without rotating the global secret (which invalidates everyone's tokens) | Prefer reversible decisions — per-user token revocation is not possible | The action (unsubscribing) is benign and self-directed; the inability to expire individual tokens is not a meaningful security risk in this context | Add per-user token storage if: (a) a future feature needs to revoke specific tokens, or (b) audit requirements demand it |
| C4 | `DigestScheduleAdvancerJob` runs on Tuesday, not immediately after send | There is a ~48-hour window each week where the schedule row's `next_send_at` is in the past but `dispatched_at` is set — the row is "stale" until Tuesday | Simplicity first — immediate advancement would require per-job completion callbacks | The scheduler guards on `dispatched_at IS NOT NULL`; stale rows are never re-enqueued. Risk is zero. | No trigger — this is intentional |
| C5 | No circuit breaker on SendGrid | Under sustained SendGrid outage, Sidekiq retries will accumulate and eventually fill the dead queue | Design for failure — a circuit breaker would stop the noise earlier | At current scale, dead queue growth is a monitoring signal, not a capacity risk. Adding a circuit breaker adds complexity. | Add circuit breaker if: digest volume grows to >50k jobs/week, or dead queue growth causes operational pain |

---

## 13. Open Risks & Callouts

1. **Activity table schema unknown.** The design assumes queryable Postgres tables for workspace activity with standard foreign keys. If the schema is non-standard (e.g., event-sourced, denormalized, or sharded), the activity query in `DigestEmailJob` may need significant adaptation. This is the highest-risk assumption (A5).

2. **Timezone handling edge cases.** Computing "Monday 8:00 AM local time" in UTC requires reliable IANA timezone data. Edge cases include DST transitions, invalid/deprecated timezone strings, and the UTC fallback for users without a timezone. The backfill and schedule-advance jobs must handle these without raising.

3. **Large user bases in the same timezone.** If a significant percentage of users are in the same timezone (e.g., UTC), job fan-out will be concentrated in a short window. At very large scale (>500k users), the scheduler loop may itself become a bottleneck. Consider chunked enqueue or Sidekiq batch at that scale.

4. **`DIGEST_HMAC_SECRET` rotation procedure.** Rotating this secret invalidates all unsubscribe links embedded in previously sent emails. An operational procedure is needed (e.g., notify users, send a new digest with a fresh link). This is not addressed in the current design.

5. **Email rendering across clients.** HTML email compatibility (Outlook, Gmail, Apple Mail, mobile) is not part of this design. Template testing (Litmus or equivalent) is a launch task.

6. **SendGrid DPA.** If the application does not already have a Data Processing Agreement with SendGrid, this must be in place before user PII (email addresses, item content) is transmitted to them.

7. **Item link deep-linking format.** The blueprint says "clicking any item link opens that item in the app." The URL format for these deep links is not specified here and must be agreed with the frontend team before email template work begins.

---

## 14. Out of Scope

Per the blueprint, the following are explicitly out of scope for this design:

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering or preview of the digest.
- Digest analytics (open rates, click rates) — not blocked, but not designed here.
- Admin tools for viewing or re-sending digests — noted as a future operational runbook item.
- Multi-workspace digests (the design handles workspace-scoped activity; cross-workspace aggregation is not addressed).
- Email template A/B testing.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — no synchronous path; background-only; scheduling jitter ±1 min acceptable |
| A2 Throughput & scale | Resolved | §6 — per-job fan-out model; peak ~2,000 jobs/hour; index strategy documented |
| A3 Concurrency & consistency | Resolved | §3 D3, §7 — unique constraint idempotency; `dispatched_at` guard prevents double-enqueue |
| A4 Availability & reliability | Resolved | §7 — 5-retry cap, drop-on-exhaustion, dead queue with alert |
| A5 Data integrity & durability | Resolved | §4 — `digest_deliveries` unique constraint; transactions scoped per job; additive migrations |
| A6 Caching & freshness | Resolved (N/A — no cache) | §6 — one query per user per week; no cache warranted; freshness trade-off documented in C2 |
| A7 Cost | Resolved | §5, §6 — SendGrid plan cost noted; no per-call compute cost; runaway risk is low (one call/user/week) |
| A8 Security & privacy | Resolved | §8 — HMAC unsubscribe tokens, permission-scoped query, PII in logs prohibited, DPA noted |
| A9 Observability | Resolved | §9 — structured logs, metrics, alerts, health signal defined |
| A10 Maintainability & simplicity | Resolved | §3 D1 — per-job fan-out fits existing Sidekiq patterns; two simple tables; no novel abstractions |
| A11 Testability | Resolved | §5 — `DigestMailer` interface for SendGrid; sandbox mode in CI; deterministic window bounds; seams documented |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, backfill rake task, reversibility documented |
| A13 Backward compatibility | Assumed (A3) | §4 — additive columns and new tables only; no existing schema changes; no API contract changes |
| A14 Accessibility & device/env | Resolved (partial) | §3 D8 — server-rendered HTML email, no JS; email client compatibility testing flagged as launch task (§13 risk 5) |
| B1 Placement / module taxonomy | Resolved | §2 — two Sidekiq jobs + one HTTP route (unsubscribe); no new service layer required |
| B2 Data model & persistence | Resolved | §4 — full schema, indexes, migration shape, invariants documented |
| B3 API surface & schemas | Resolved | §2, §8 — one new route: `GET /digest/unsubscribe?token=`; no other API surface |
| B4 Async / background work | Resolved | §3 D1, §6 — `DigestSchedulerJob` (cron) + `DigestEmailJob` (per-user worker); queue names and concurrency documented |
| B5 External services & contracts | Resolved | §5 — SendGrid: auth, rate limits, cost, failure modes, test strategy; grammar follow-up noted |
| B6 Frontend integration | N/A | Feature is backend-only; no frontend state, no polling, no push events. The unsubscribe page is a minimal server-rendered confirmation. |
| B7 Feature flags & rollout | Resolved | §10 — `weekly_digest_enabled` flag, default false, staged rollout plan |
| B8 Error handling | Resolved | §7 — per-failure-mode table; Sidekiq retry cap; dead queue; permanent vs transient failure distinction |

---

## Appendix A: Captured Inputs

*This appendix records the autonomous reasoning process used in place of a live interview (P3). Since no human was available, all decisions were resolved from the blueprint and the stack description. Each entry records: the decision faced, the recommendation applied, the resolution taken, and the reasoning. The P4 last-call check is also noted.*

---

### Scheduling model: cron + fan-out vs. single batch job

- **Question:** Should the weekly digest be sent by a single batch job that loops over all users, or by a cron that enqueues one job per eligible user?
- **Recommendation given:** Per-user fan-out via Sidekiq jobs. Rationale: Design for failure + Idempotency & bounded operations. Individual failure isolation; each job retries independently.
- **Resolution:** Per-user fan-out adopted (D1).
- **Notes:** Single batch was simpler to write but created an unacceptable single point of failure. Fan-out is the standard Sidekiq pattern for this class of problem.

---

### Idempotency mechanism: DB constraint vs. Sidekiq unique jobs vs. app-level check

- **Question:** How do we prevent a user from receiving two digests if the scheduler fires twice?
- **Recommendation given:** Database unique constraint on `(user_id, iso_week)` in `digest_deliveries`. Rationale: most reliable; doesn't depend on Sidekiq Pro.
- **Resolution:** DB unique constraint adopted (D3). `dispatched_at` guard added in `digest_send_schedule` as a first-line defense to prevent even enqueueing duplicate jobs.
- **Notes:** App-level check-then-insert would have a race condition. Sidekiq unique jobs was appealing but assumed a gem not confirmed available.

---

### Unsubscribe token design: HMAC vs. random DB token vs. JWT

- **Question:** How should the unsubscribe link token be designed to satisfy the blueprint's adversarial constraint (token must not be guessable; must act only on the issuing account)?
- **Recommendation given:** Deterministic HMAC-SHA256 token. Rationale: no extra table; not guessable without the secret; no expiry complexity.
- **Resolution:** HMAC token adopted (D6).
- **Notes:** Random DB token was more flexible but added table complexity. JWT with expiry was rejected because expiry creates bad UX for unsubscribe links and JWT is unnecessary for this narrow use case. SendGrid native unsubscribe groups were rejected because they move opt-out state outside the application database, creating a correctness risk.

---

### Failure handling: drop vs. delay

- **Question:** If SendGrid fails and retries are exhausted on Monday morning, should we delay delivery to later in the day or week, or drop the digest?
- **Recommendation given:** Drop. The blueprint is unambiguous: "a digest that arrives late is worse than one skipped."
- **Resolution:** 5-retry cap with drop-on-exhaustion adopted (D7). Dead queue + alert is the operational escape hatch.
- **Notes:** This is a rare case where the blueprint itself resolved a design fork. No further deliberation needed.

---

### Caching: cache the activity query result or not

- **Question:** Should the per-user activity query result be cached to reduce DB load?
- **Recommendation given:** No cache. Rationale: one query per user per week is not a repeated fetch; no amortization benefit; adds complexity without measurable gain (Simplicity first; Measure, don't guess).
- **Resolution:** No cache (C2).
- **Notes:** Caching is the right tool when the same data is fetched repeatedly in a short window. Weekly digest queries do not exhibit that pattern.

---

### Data model: one table vs. two tables for scheduling + delivery

- **Question:** Should scheduling state and delivery history live in one table or two?
- **Recommendation given:** Two tables. Rationale: High cohesion, loose coupling + Get the data model right. Mixing mutable scheduling state with immutable delivery history creates complex state transitions in a single row.
- **Resolution:** Two-table model adopted (D2).
- **Notes:** The single-table approach would have required a status enum with transitions (pending → dispatched → delivered → failed) and would have made idempotency queries awkward. Separation keeps each table's invariants clean.

---

### Last-call (P4)

- **Asked:** "Anything we've missed — any concern or constraint not yet captured?"
- **Response (autonomous):** Reviewed all blueprint sections against the design:
  - New-user mid-week edge case: covered by D4 (window bounded by user join date — assumption: `created_at` on the user or a `workspace_memberships.joined_at` date is used as the lower bound for brand-new users). **Flagged as a minor gap:** the activity query as designed uses a fixed 7-day lookback; for new users, the query would naturally return only items since they joined if workspace membership is the join condition. This should be verified during implementation.
  - Timezone-change-on-Sunday edge case: covered by §4 — `next_send_at` is recomputed when timezone changes; the advancer job and any user-timezone-update hook must update `digest_send_schedule.next_send_at` accordingly. **Flagged as an implementation note:** a hook or callback on `users.timezone` update must refresh the schedule row.
  - Deleted workspace edge case: covered by D5 (permission-scoped query with workspace existence check).
  - UTC fallback for missing timezone: covered by A1/A4 in assumptions (NULL timezone → UTC).
  - One digest per week invariant: covered by D3 (unique constraint).
  - No empty digest rule: covered in `DigestEmailJob` logic (zero-activity check before send).
  - Nothing further identified.
