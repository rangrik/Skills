# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../inputs/weekly-digest-blueprint.md](../inputs/weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The Weekly Digest Email feature is a pure background-job concern: a Sidekiq cron job fires every minute, identifies users for whom the current moment is Monday 8:00 AM in their local timezone, and enqueues one `WeeklyDigestJob` per eligible user. Each job queries Postgres for that user's seven-day activity window, skips the send if the result is empty, renders an HTML email, and delivers it via SendGrid. A `digest_sends` table with a `(user_id, week_start_date)` unique constraint is the single idempotency gate — no digest is sent twice for the same user-week regardless of how many times the scheduler fires. The most important architectural choice is the **per-minute timezone fan-out pattern**: instead of one giant Monday morning batch, a narrow cron tick every minute enqueues only the users whose local clock just crossed 8:00 AM, spreading load across the 24 × 60 possible tick windows and eliminating the thundering-herd risk. Unsubscribe is implemented as an HMAC-signed URL token (user-scoped, non-guessable) with immediate Postgres effect, satisfying the blueprint's adversarial requirement without an extra token table.

---

## 2. System Placement

This feature touches three layers, all new:

```
[Sidekiq Cron — every 1 min]
        │
        ▼
WeeklyDigestSchedulerJob   (finds users whose local time == Mon 08:00)
        │  enqueues one job per user
        ▼
WeeklyDigestJob (per user)
  1. Check digest_sends for (user_id, week_start) → skip if exists
  2. Query activity tables (Postgres) for 7-day window
  3. Skip if empty result
  4. Render HTML email template
  5. POST to SendGrid Transactional API
  6. INSERT into digest_sends on success
        │
        ▼
SendGrid (email delivery)

[HTTP unsubscribe endpoint]
  GET /digest/unsubscribe?token=<hmac-token>
  → validates token → sets user.digest_enabled = false
```

**Components touched:**
- **New Sidekiq jobs:** `WeeklyDigestSchedulerJob`, `WeeklyDigestJob`
- **New HTTP route:** `GET /digest/unsubscribe`
- **New DB table:** `digest_sends`
- **New column on users:** `digest_enabled` (boolean), `timezone` (already exists per blueprint assumption — see §11 A1)
- **New email template:** `weekly_digest.html.erb`
- **No frontend changes** — the unsubscribe endpoint redirects to a static confirmation page; the email itself is generated server-side.

---

## 3. Architecture Decisions

### D1. Per-minute cron fan-out instead of a single Monday 00:00 batch job

- **Decision:** A Sidekiq cron job (via `sidekiq-cron`) runs every minute 24/7. Each tick queries for users where `EXTRACT(DOW FROM NOW() AT TIME ZONE user_timezone) = 1` (Monday) and the local hour/minute is 08:00. It enqueues one `WeeklyDigestJob` per matched user.
- **Why:** A single Monday-midnight batch would enqueue potentially all users at once, creating a thundering-herd spike on Sidekiq, the DB, and SendGrid. The per-minute fan-out spreads the load across up to 1,440 tick windows across the week. It also handles timezone diversity naturally — users in UTC-12 through UTC+14 each get picked up at their own 8:00 AM without special bucketing logic. Upholds **Principle 2 (match existing patterns)** — Sidekiq cron is the stack's standard scheduler — and **Principle 6 (bounded operations)** — each tick processes only the narrow slice of users whose local time just crossed the threshold.
- **Alternatives considered:**
  - *Single Monday cron at UTC midnight:* Simple, but creates O(all_users) spike and requires computing per-user offsets in the worker. Rejected: violates bounded operations and creates a fragile thundering-herd.
  - *Pre-bucketed queues per UTC-offset:* Pre-compute send times and place jobs on hour-specific queues. More complex scheduler logic, harder to handle mid-week timezone changes. Rejected: extra complexity without proportionate gain (Principle 1 — YAGNI).
- **Trade-off accepted:** The cron query runs every minute (525,600×/year). At low user counts this is negligible; at very high user counts the scheduler query itself could become a hotspot. Accepted for now; see §13 for scale trigger.

---

### D2. digest_sends table as the idempotency gate

- **Decision:** A dedicated `digest_sends` table with a `UNIQUE(user_id, week_start_date)` constraint is the canonical idempotency record. Before any work, `WeeklyDigestJob` attempts an `INSERT INTO digest_sends ... ON CONFLICT DO NOTHING` and aborts if the row already exists.
- **Why:** The blueprint's deviation scenario ("job triggered twice") requires exactly-once delivery per user-week. A DB-level unique constraint is the most reliable gate — it survives process restarts, job retries, and concurrent duplicate jobs. Upholds **Principle 6 (idempotency & bounded operations)** and **Principle 9 (make illegal states unrepresentable)** — the constraint makes a duplicate send structurally impossible.
- **Alternatives considered:**
  - *Redis-based lock (Sidekiq::UniqueJobs):* Protects at enqueue time but the lock expires and doesn't survive a scheduler re-run the next week. Insufficient as the sole gate.
  - *Check-then-insert (two-step):* Race-prone. Rejected: concurrent jobs can both pass the check before either inserts.
- **Trade-off accepted:** One extra DB write per user per week. Negligible cost; durability benefit is high.

---

### D3. HMAC-signed unsubscribe token (no extra token table)

- **Decision:** The unsubscribe link is `GET /digest/unsubscribe?token=<hmac>` where the token is `HMAC-SHA256(secret_key, "unsubscribe:#{user_id}:#{week_start_date}")` Base64-URL-encoded. On receipt, the endpoint recomputes and compares the HMAC, then sets `users.digest_enabled = false`.
- **Why:** The blueprint's adversarial requirement is that an unsubscribe link must act only on the issuing account and must not be guessable. HMAC-signed tokens satisfy both: they are user-scoped (user_id is in the payload) and non-guessable (requires knowledge of the app secret). Including `week_start_date` in the input limits token reuse across weeks. Upholds **Principle 11 (security & privacy by design)** and avoids a token storage table (Principle 1 — YAGNI; Principle 7 — reversible, fewer moving parts).
- **Alternatives considered:**
  - *Random opaque token stored in DB:* Standard pattern, but adds a token table, a lookup on every unsubscribe click, and a cleanup job for old tokens. Acceptable but heavier.
  - *JWT:* Verifiable without storage, but larger payload, more library surface. HMAC-SHA256 is simpler for this use case.
- **Trade-off accepted:** Tokens are not revocable mid-week (the HMAC for a given user-week is always the same). Acceptable: the blueprint says unsubscribe takes effect "before the next Monday," and the user can also unsubscribe in-app if they need faster action. If a token needs invalidation (e.g., account compromise), a DB-stored token would be needed — noted in §13.

---

### D4. Activity query runs at send time against live Postgres (no pre-aggregation)

- **Decision:** `WeeklyDigestJob` executes a direct Postgres query against the relevant activity tables (items, comments, completions) at the moment the job runs, filtering by `user_id` and `created_at BETWEEN week_start AND week_end`. No materialized view or pre-computed aggregate.
- **Why:** Upholds **Principle 1 (YAGNI)** — pre-aggregating activity adds write-time overhead and schema complexity that isn't justified until query latency is measured to be a problem. The query runs in a background job (not user-facing), so a multi-second Postgres query is acceptable. Upholds **Principle 8 (measure, don't guess)**.
- **Alternatives considered:**
  - *Event stream / append-only activity log table:* Clean aggregation but requires new write-path instrumentation across all activity types. Premature for v1.
  - *Materialized view refreshed weekly:* Reduces per-job query cost but adds stale-data risk and a refresh job dependency.
- **Trade-off accepted:** Query latency may grow with data volume. Mitigated by indexes on `(user_id, created_at)` on each activity table. Revisit if p95 job duration exceeds 10s (see §13).

---

### D5. On send failure: retry up to 3 times within ~5 minutes, then discard for the week

- **Decision:** `WeeklyDigestJob` uses Sidekiq's built-in retry mechanism with `sidekiq_options retry: 3` and an exponential back-off capped at ~5 minutes per retry. After 3 failures, the job goes to Sidekiq's Dead queue (not retried). The `digest_sends` row is only written on success; a failed-then-dead job leaves no row, so the idempotency gate does not prevent a manual re-run if ops chooses to drain the Dead queue.
- **Why:** The blueprint is explicit: "a digest that arrives late is worse than one skipped." This rules out unbounded retries or rescheduling to the afternoon. Upholds **Principle 5 (design for failure)** and directly honors the blueprint's stated failure policy.
- **Alternatives considered:**
  - *Retry indefinitely:* Violates blueprint constraint. Rejected.
  - *No retry (fire once):* Transient SendGrid 500s are common enough to warrant at least one retry.
- **Trade-off accepted:** Users whose digest fails after 3 retries receive no email that week. Acceptable per blueprint; engineers can inspect the Dead queue and manually replay if the outage was short.

---

### D6. Email rendered server-side with an ERB HTML template

- **Decision:** A single `weekly_digest.html.erb` template (plus a plain-text counterpart `weekly_digest.text.erb` for email clients that prefer it) is rendered inside the Sidekiq worker using Rails' `ActionMailer` (or equivalent renderer). The mailer is called `WeeklyDigestMailer`.
- **Why:** ActionMailer is the standard Rails email abstraction; using it keeps the code consistent with any existing mailers in the project (Principle 2). It handles multipart (HTML + plain-text) automatically and provides a clean seam for testing via `ActionMailer::Base.deliveries` in test mode (Principle 15).
- **Alternatives considered:**
  - *SendGrid dynamic templates (template stored in SendGrid):* Moves rendering responsibility to a third party, making it harder to version-control, preview, and test locally. Rejected: violates Principle 3 (high cohesion — template logic belongs with the code that owns the email).
- **Trade-off accepted:** Template changes require a code deploy rather than a SendGrid dashboard edit. Acceptable: version control and testability are more valuable than operator convenience here.

---

### D7. Feature flag for staged rollout

- **Decision:** A global boolean feature flag `weekly_digest_rollout_enabled` (checked in `WeeklyDigestSchedulerJob`) gates whether the scheduler enqueues any jobs. Independently, each user has `users.digest_enabled` (boolean, default `true`) controlling their personal subscription. The global flag is the kill-switch for ops; the user flag is the opt-out.
- **Why:** Upholds **Principle 7 (prefer reversible decisions)** — the flag allows instant rollback if the feature causes unexpected load or SendGrid cost overruns. The two-level design (global + per-user) keeps concerns separate.
- **Alternatives considered:**
  - *Percentage rollout on user population:* Useful for gradual ramp but adds complexity for an async background feature. Operator can manually ramp by enabling for a subset via the global flag pattern. Can be added later.
- **Trade-off accepted:** No percentage-based gradual ramp in v1. Rollout is binary (off → all users). Acceptable for a low-risk email feature; can be refined before GA.

---

## 4. Data Model & Persistence

### New table: `digest_sends`

```sql
CREATE TABLE digest_sends (
  id             BIGSERIAL PRIMARY KEY,
  user_id        BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start_date DATE        NOT NULL,  -- Monday 00:00 in user's local timezone
  sent_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  send_status    VARCHAR(20) NOT NULL DEFAULT 'sent',  -- 'sent' | 'skipped_empty'
  CONSTRAINT uq_digest_user_week UNIQUE (user_id, week_start_date)
);

CREATE INDEX idx_digest_sends_user_id ON digest_sends(user_id);
```

**Invariants:**
- `(user_id, week_start_date)` is unique — the idempotency guarantee.
- `week_start_date` is always a Monday (enforced by application logic; a CHECK constraint can be added: `EXTRACT(DOW FROM week_start_date) = 1`).
- Row is written only after a successful SendGrid delivery (or explicit `skipped_empty`).
- `ON DELETE CASCADE` ensures no orphaned send records if a user is deleted.

**Retention:** Rows are cheap (one per user per week). Retain indefinitely for audit/debugging; add a cleanup job after 90 days if storage becomes a concern.

### Changes to existing table: `users`

```sql
ALTER TABLE users ADD COLUMN digest_enabled BOOLEAN NOT NULL DEFAULT true;
-- timezone column assumed already present (see §11, assumption A2)
```

**Invariants:**
- `digest_enabled = false` means no digest is sent, regardless of activity.
- Default `true` — opt-out model, consistent with the blueprint's "unsubscribing is the action."

### Indexes required on activity tables

The activity query (D4) filters on `(user_id, created_at)`. The following indexes must exist (or be created as part of this migration):

```sql
-- Applied to whichever tables hold the relevant activity; exact names depend on existing schema
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_items_user_created
  ON items(user_id, created_at);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comments_user_created
  ON comments(user_id, created_at);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_completions_user_created
  ON completions(user_id, created_at);
```

> **Schema gap flagged for blueprint:** The blueprint references "new items, completed items, comments mentioning them" but does not name the underlying tables. The design assumes `items`, `completions`, and `comments` tables exist with `user_id` and `created_at` columns. If the actual table/column names differ, the activity query must be adjusted — this is a blueprint behavior gap, not a system design decision.

### Migration shape

1. `add_column :users, :digest_enabled, :boolean, default: true, null: false`
2. `create_table :digest_sends` (as above)
3. `add_index` on activity tables (CONCURRENTLY — safe on live DB)

All migrations are backward-compatible: no existing column is altered; no existing query breaks.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid** (Transactional API v3) | Deliver weekly digest emails | API key stored in `SENDGRID_API_KEY` env var, never in code or DB | 100 emails/s on free tier; paid plans scale higher. Cost ~$0.001–0.003/email. Weekly batch cost ≈ `n_users × $0.002`. | HTTP 429 → respect `Retry-After`; HTTP 5xx → Sidekiq retry (max 3, D5); persistent failure → Dead queue, no send that week. | `ENV["SENDGRID_API_KEY"] = "test"` triggers SendGrid's sandbox mode; ActionMailer `delivery_method :test` in test environment captures emails in `ActionMailer::Base.deliveries`. |

**Cost ceiling:** At 10,000 active users, ~10,000 emails/week ≈ $20/week. At 100,000 users ≈ $200/week. Add a `MAX_DIGEST_BATCH_SIZE` env cap (default: unlimited) as an emergency brake. Alert if weekly send count exceeds expected × 1.5 (see §9).

**External-system grammar note:** SendGrid's Mail Send API (`POST /v3/mail/send`) has a detailed parameter schema (personalizations, content types, tracking settings). This grammar is best maintained in a probe-tested integration skill or integration tests rather than encoded verbatim here.

---

## 6. Performance, Scale & Caching

### Latency targets

This is a fully background feature — no user-synchronous latency target. However:
- **Scheduler tick:** p95 < 500ms (it must complete within the 60-second cron interval).
- **Per-user job:** p95 < 30s end-to-end (query + render + SendGrid POST). Jobs that exceed Sidekiq's default 25s timeout should be given `sidekiq_options timeout: 60`.

### Expected load

| Metric | Estimate | Basis |
|---|---|---|
| Users receiving digest | 1,000–100,000 | Unknown; assumed from typical SaaS trajectory |
| Jobs enqueued per minute | ~0–70 (peak ~0.7/min avg across the week's 1,440 ticks) | Spread across timezones |
| Scheduler DB query | 1 query/min, O(users) scan or index seek | Indexed on `timezone` + filter |
| SendGrid calls | 1 per non-empty active user per week | ~1,000–100,000/week |
| Peak Sidekiq throughput | < 10 jobs/min typical | Negligible vs normal background load |

The per-minute fan-out (D1) ensures no single tick enqueues more than a small fraction of users. The only timezone with meaningful concentration is UTC (many servers default to UTC), which could spike if many users have no timezone set. The UTC default path is bounded because it's a constant — not a growth concern unless the user base is very large and timezone-unset.

### Caching

No caching is applied to digest data. Each job queries fresh data at send time, which is both correct and necessary (the 7-day window must reflect the actual state at send time). The cost of the activity query is low enough at current scale that caching would add invalidation complexity for no user-visible benefit (Principle 13 — no cache without justification). This decision must be revisited if query p95 exceeds 5s.

### Concurrency

The scheduler job is safe to run concurrently with itself (idempotent via D2). Individual digest jobs are independent (one per user) and can run in parallel across Sidekiq workers without contention.

---

## 7. Reliability & Failure Handling

| Failure scenario | Behavior | Blueprint cross-reference |
|---|---|---|
| SendGrid returns 5xx | Sidekiq retries up to 3 times, ~5-minute window. After 3 failures, job goes to Dead queue; no digest sent that week. | "Dropped for the week rather than delayed" |
| SendGrid returns 429 (rate limit) | Sidekiq respects `Retry-After` header via `sidekiq-throttled` or manual rescue block; counts as a retry attempt. | Implicit: service behavior |
| Scheduler job runs twice (deploy re-triggers) | Both ticks query the scheduler check; duplicate `WeeklyDigestJob` entries are fine — the `digest_sends` unique constraint absorbs the second attempt. | "Job triggered twice → one digest" |
| Scheduler delayed / starts late | `week_start_date` is computed from the user's local Monday midnight, not from the scheduler's run time. Content window is unaffected. | "Job delayed → correct 7-day window" |
| Activity query returns no rows | Job inserts `(user_id, week_start_date, send_status='skipped_empty')` into `digest_sends` and exits without sending. Prevents re-send if job is retried after an empty check. | "No activity → no email" |
| Workspace deleted | The activity query JOINs through workspace_id; items in a deleted workspace return no rows (assuming soft-delete with a `deleted_at` flag, or the FK cascade removes them). Job skips. | "Workspace deleted → no email" |
| User deleted | `ON DELETE CASCADE` on `digest_sends.user_id` cleans up records. Scheduler query filters `WHERE users.deleted_at IS NULL`. | Implicit |
| Sidekiq process restart during job | Job re-enters the queue via Sidekiq's at-least-once semantics. `digest_sends` unique constraint prevents duplicate send. | Idempotency by design (D2) |

**Idempotency guarantee:** The combined `(scheduler deduplication + digest_sends unique constraint)` ensures exactly-once behavior per user-week, even under at-least-once job delivery.

---

## 8. Security & Privacy

### Authorization

- **Unsubscribe endpoint:** Authenticated by HMAC-SHA256 token (D3). No session cookie or login required — appropriate for email link clicks. Token scope: `"unsubscribe:#{user_id}:#{week_start_date}"`. Validation: server recomputes HMAC with the same inputs and compares with constant-time comparison (`ActiveSupport::SecurityUtils.secure_compare`) to prevent timing attacks.
- **No other HTTP endpoints added** by this feature are user-reachable except the unsubscribe route.

### Content authorization

- The activity query for user `U` must be scoped to items/workspaces that `U` has permission to see. The WHERE clause must include the same visibility conditions applied to in-app item listings (e.g., `workspace_id IN (SELECT workspace_id FROM memberships WHERE user_id = U.id AND deleted_at IS NULL)`). This is a **critical security invariant**: a digest must not surface items from workspaces the user has left or been removed from.

### PII & data handling

- Emails contain the user's name, workspace content snippets, and item titles — all PII.
- SendGrid receives the user's email address and rendered content. Ensure the SendGrid account's data-processing agreement (DPA) covers this use.
- Logs must not include email body content or full item titles. Log only `user_id`, `week_start_date`, `status`, and `SendGrid message_id`.

### Secret handling

- `SENDGRID_API_KEY` and the HMAC signing key (`DIGEST_HMAC_SECRET`) must be environment variables, rotatable without code changes, and never logged.

### Abuse vectors

- **Mass unsubscribe via token guessing:** Prevented by HMAC — requires knowledge of `DIGEST_HMAC_SECRET`. Token space is 256-bit HMAC output.
- **Unsubscribing another user:** HMAC includes `user_id`; a token for user A cannot unsubscribe user B.
- **Email address harvesting via timing:** The unsubscribe endpoint should return the same response (200 + confirmation page) for valid and invalid tokens, logging the mismatch server-side. This prevents oracle attacks to confirm whether a user_id exists.

---

## 9. Observability

### Metrics (emit via StatsD / Prometheus counters)

| Metric | Description | Alert condition |
|---|---|---|
| `digest.scheduler.tick_duration_ms` | Duration of each scheduler tick | p95 > 500ms |
| `digest.jobs.enqueued_total` | Jobs enqueued per tick | Sudden spike (> 2× weekly average) |
| `digest.send.success_total` | Successful deliveries this week | Falls to 0 for > 90 min after Monday 08:00 UTC |
| `digest.send.skipped_empty_total` | Users skipped for no activity | Informational |
| `digest.send.failed_total` | Jobs exhausted retries, went to Dead queue | Any nonzero value triggers alert |
| `digest.send.duration_ms` | Per-job wall time | p95 > 30s |
| `digest.unsubscribe.count` | Unsubscribe events | Unusual spike (> 5% of sends in 24h) |

### Logs

Each `WeeklyDigestJob` should emit structured log lines at key transitions:

```
{event: "digest.job.start",      user_id: X, week_start: "2026-05-18"}
{event: "digest.job.skip_empty", user_id: X, week_start: "2026-05-18"}
{event: "digest.job.sent",       user_id: X, week_start: "2026-05-18", sg_message_id: "..."}
{event: "digest.job.failed",     user_id: X, week_start: "2026-05-18", error: "...", attempt: N}
```

### The one signal that proves the feature is healthy

**`digest.send.success_total` must be nonzero within the two-hour window following the first Monday 8:00 AM UTC tick.** An alert on this signal catches: scheduler not running, Sidekiq not running, SendGrid outage, or code regression — all at once.

### Tracing

Tag all jobs and HTTP requests with `feature: weekly_digest` for easy filtering. Sidekiq job traces should include `user_id` and `week_start_date` as span attributes.

---

## 10. Rollout & Operability

### Feature flag

- **Global flag:** `WEEKLY_DIGEST_ROLLOUT_ENABLED` (env var or feature-flag system, default: `false`). Checked in `WeeklyDigestSchedulerJob` before any enqueuing.
- **User flag:** `users.digest_enabled` (default: `true`). Controls individual subscription. Added in the migration.

### Rollout sequence

1. **Deploy DB migration** (add `users.digest_enabled`, create `digest_sends` — backward-compatible, safe on live DB).
2. **Deploy code** with global flag `false` — scheduler runs but enqueues nothing.
3. **Smoke test:** Manually enqueue `WeeklyDigestJob` for a test user; verify email received, `digest_sends` row written, idempotency gate works on re-run.
4. **Enable flag for internal users:** Set `digest_enabled = true` only for a known test cohort for one Monday cycle.
5. **Enable globally:** Flip `WEEKLY_DIGEST_ROLLOUT_ENABLED = true`. All opted-in users receive digests the following Monday.

### Reversibility

- **Disable immediately:** Set `WEEKLY_DIGEST_ROLLOUT_ENABLED = false`. In-flight jobs finish; no new ones enqueue.
- **Data rollback:** `digest_sends` rows can be deleted if a bad run must be replayed. `users.digest_enabled` column drop is a one-migration rollback.
- **No frontend deploy coordination required** — this is purely a backend/email feature.

### Operational notes

- Monitor Sidekiq Dead queue for failed digest jobs every Monday.
- `digest_sends` can be queried to audit which users received/skipped a digest for any given week.
- The unsubscribe endpoint must be excluded from CSRF protection (it is a GET link from email, carries its own token-based auth).

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | A `timezone` column exists on the `users` table (storing IANA timezone string, e.g. `"America/New_York"`). | The blueprint states users have a "configured timezone" and references the UTC fallback. A column is the standard storage for this. | Yes — confirm column name and type |
| A2 | Activity tables (`items`, `completions`, `comments`) have `user_id` and `created_at` columns, and are scoped by `workspace_id`. | These are standard Rails conventions for the described domain. | Yes — confirm actual table/column names |
| A3 | Comments are associated to a `user_id` representing the mentionee (not only the author), or a separate `comment_mentions` table exists. | The blueprint says "comments mentioning them" — needs a mentionee FK to query correctly. | Yes — confirm mention storage |
| A4 | A Rails/ActionMailer stack is in use (consistent with Sidekiq). | The task specifies Sidekiq; Rails is the conventional pair. ActionMailer is the standard mailer abstraction in this stack. | Low risk; confirm if the project uses a different mailer layer |
| A5 | SendGrid is configured as the ActionMailer delivery adapter via `sendgrid-ruby` or `action_mailer_sendgrid_v3`. | Specified in the task prompt. | Confirm the specific gem/adapter in use |
| A6 | The `sidekiq-cron` gem (or equivalent, e.g. `whenever` + system cron) is available for recurring job scheduling. | Sidekiq is specified; `sidekiq-cron` is the standard extension. | Confirm gem availability |
| A7 | Workspaces have a `deleted_at` soft-delete column (or equivalent), allowing items to be excluded if workspace is deleted. | Common Rails pattern; blueprint calls out "workspace deleted → no email." | Confirm soft-delete strategy |
| A8 | User scale is O(10,000–100,000) active users. The per-minute scheduler query is lightweight at this scale. | Typical early-to-mid SaaS. At >500,000 users the scheduler query design should be revisited. | Low risk |
| A9 | The app has an existing HMAC signing key (e.g., `Rails.application.secret_key_base`) or a separate `DIGEST_HMAC_SECRET` can be added. | Standard Rails practice. | Confirm secret availability and rotation policy |
| A10 | Item links in the email use a stable public URL pattern (e.g., `/items/:id`) that works without login (or requires login on click, which is acceptable). | The blueprint says clicking opens the item in the app — a redirect-to-login flow is standard. | Low risk |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Activity query runs live against Postgres at send time (no pre-aggregation) | Query latency grows with data volume; heavy queries during job burst | Principle 8 (measure, don't guess) — skipping optimization without evidence of need | Background jobs tolerate multi-second queries; correctness is preserved; avoids write-path complexity | If per-job p95 query time > 5s, add covering indexes or a weekly activity summary table |
| C2 | No per-percentage gradual rollout — global flag is on/off | Inability to ramp digest delivery gradually (e.g., 10% → 50% → 100%) | Principle 7 (prefer reversible) — a staged ramp is more cautious | Low-risk email feature; instant kill-switch via global flag is sufficient mitigation | If the feature causes unexpected cost or load at full rollout |
| C3 | HMAC tokens are not stored/revocable mid-week | An issued unsubscribe token for user U cannot be invalidated before Monday | Principle 11 (security & privacy by design) — full revocability would require a token store | Unsubscribe is a low-risk action; user can also opt out in-app; risk of token misuse is minimal | If in-app revocation or account-compromise scenarios demand it |
| C4 | Duplicate scheduler ticks both enqueue jobs (dedup at DB layer, not at enqueue) | Extra Sidekiq job entries before the DB constraint fires; minor queue bloat | Principle 6 (bounded operations) — enqueue-time dedup would be cleaner | The DB constraint is the reliable gate; enqueue-time dedup via Redis locks adds complexity | If scheduler double-fires become frequent (e.g., noisy cron infrastructure) |
| C5 | Plain-text fallback email is provided but not extensively styled | Plain-text version is a basic strip of HTML content | Principle 14 (least surprise) — some email clients prefer plain text | Digest content is simple enough that unstyled plain text is readable; polish is a follow-up | If user complaints about plain-text rendering emerge |

---

## 13. Open Risks & Callouts

1. **Activity table schema unknown:** The design assumes `items`, `completions`, `comments` with standard Rails columns. If the actual schema differs significantly (e.g., activity is stored in a single polymorphic `events` table), the query design in D4 must be revised. **Action required: confirm schema before implementation.**

2. **Comment "mentioning" query:** The blueprint specifies "comments mentioning them" but the storage for mentions is unspecified. If mentions are parsed from comment body text (e.g., `@username`), the query is more complex than a simple `WHERE user_id = ?`. **Action required: clarify mention storage.**

3. **Scheduler query at high user count:** The every-minute query `SELECT id FROM users WHERE digest_enabled = true AND ... (timezone filter)` must be indexed. If `users` grows beyond ~500K rows and timezone distribution is wide, a partial index on `(timezone)` WHERE `digest_enabled = true` is needed. Currently classified as a future concern (assumption A8).

4. **SendGrid cost overrun:** No hard ceiling on SendGrid calls exists in v1 (beyond the `MAX_DIGEST_BATCH_SIZE` env var). If a bug causes the scheduler to loop or re-enqueue at high volume, cost could spike. The `digest_sends` unique constraint prevents duplicate *sends*, but not duplicate *enqueues* that are then rejected. A per-week circuit breaker (e.g., max 1.5× expected sends alerts ops) is noted in §9 but not hard-enforced.

5. **Token reuse across weeks:** The HMAC token uses `week_start_date` as an input, so a token issued in week N is invalid in week N+1. However, if a user forwards their digest email weeks later and clicks unsubscribe, the token from week N will validate correctly (the HMAC doesn't expire). This is intentional — the token should remain valid for unsubscribe purposes indefinitely. It is not a security risk since the action (unsubscribe) is user-intended.

6. **Timezone edge: DST transition on Sunday night:** The blueprint acknowledges "a small shift in send time is acceptable." The implementation uses the user's stored timezone string at the time the scheduler tick runs. If DST shifts the user's Monday 8:00 AM window by an hour, the email is sent at 7:00 or 9:00 AM local time for that one week. No special handling needed; this is an accepted property of IANA timezone rules.

---

## 14. Out of Scope

The following are explicitly out of scope for this design, consistent with the blueprint's Out of Scope section and scope decisions made autonomously:

- **Daily or monthly digest frequencies** — blueprint exclusion.
- **User customization of activity types** — blueprint exclusion.
- **In-app rendering of the digest** — blueprint exclusion.
- **Per-percentage gradual rollout logic** — deferred to post-launch (see C2).
- **Unsubscribe token revocation infrastructure** — not required for v1 (see C3).
- **Email open/click tracking analytics** — not mentioned in blueprint; can be added via SendGrid's tracking features without design changes, but not part of this design.
- **Digest preview in app settings** — a useful UX feature but out of scope here; requires frontend work beyond this design.
- **Bounce/spam handling and list hygiene** — important for deliverability long-term but not a v1 requirement. SendGrid handles bounce suppression automatically.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — background only; scheduler < 500ms p95; per-job < 30s p95 |
| A2 Throughput & scale | Resolved | §6 — per-minute fan-out; 1,000–100,000 users; no thundering herd |
| A3 Concurrency & consistency | Resolved | §7, D2 — `digest_sends` unique constraint; scheduler idempotent |
| A4 Availability & reliability | Resolved | §7, D5 — retry 3×; dead-queue on exhaustion; drop for week |
| A5 Data integrity & durability | Resolved | §4 — unique constraint; ON DELETE CASCADE; migration shape documented |
| A6 Caching & freshness | Resolved | §6 — no cache; live query; freshness is a correctness requirement; revisit at 5s p95 |
| A7 Cost | Resolved | §5, §6 — ~$0.002/email; cost ceiling via `MAX_DIGEST_BATCH_SIZE`; alert at 1.5× baseline |
| A8 Security & privacy | Resolved | §8 — HMAC unsubscribe token; content authorization scoping; PII log hygiene; secret handling |
| A9 Observability | Resolved | §9 — structured logs; 7 metrics; 4 alerts; health signal defined |
| A10 Maintainability & simplicity | Resolved | D1–D7 — all decisions prefer existing patterns; no novel abstractions introduced |
| A11 Testability | Resolved | D6, §5 — ActionMailer test mode; `delivery_method :test`; HMAC token testable with fixed secret; Sidekiq test mode |
| A12 Deployability & rollout | Resolved | §10 — 5-step rollout sequence; global flag; backward-compatible migrations |
| A13 Backward compatibility | Assumed (A4, A6) | Additive-only schema changes; new tables; no existing API or schema modified |
| A14 Accessibility & device/env | Resolved | D6 — multipart email (HTML + plain-text); no app UI changes; unsubscribe is a plain GET link |
| B1 Placement / module taxonomy | Resolved | §2 — `WeeklyDigestSchedulerJob`, `WeeklyDigestJob`, `WeeklyDigestMailer`; new Sidekiq job module |
| B2 Data model & persistence | Resolved | §4 — `digest_sends` table; `users.digest_enabled`; activity table indexes |
| B3 API surface & schemas | Resolved | §2 — single new route: `GET /digest/unsubscribe?token=…`; no new JSON API routes |
| B4 Async / background work | Resolved | D1, D5 — Sidekiq cron + per-user jobs; retry policy; idempotency |
| B5 External services & contracts | Resolved | §5 — SendGrid; auth, rate limits, cost, failure, mock strategy documented |
| B6 Frontend integration | N/A | No frontend changes; unsubscribe redirects to a static confirmation page; feature is email-only |
| B7 Feature flags & rollout | Resolved | D7, §10 — `WEEKLY_DIGEST_ROLLOUT_ENABLED` global flag + `users.digest_enabled` user flag |
| B8 Error handling | Resolved | D5, §7 — per-layer failure table; Sidekiq retry; Dead queue; `skipped_empty` path; no silent swallowing |

---

## Appendix A: Captured Inputs

*This section records the autonomous decisions made in lieu of a live user interview. For each decision fork, the reasoning, recommendation, and resolution are captured as they would be in a human interview. A future reader can reconstruct why the design is what it is.*

---

### Topic 1: Scheduler architecture — per-minute cron vs. single Monday batch

- **Question:** Should the digest scheduler be a single cron job that fires once on Monday (e.g., at 00:00 UTC) and enqueues all users, or a per-minute cron that continuously picks up users whose local time is 8:00 AM Monday?
- **Recommendation given:** Per-minute fan-out. Reasoning: single Monday batch creates a thundering-herd spike; per-minute spread is bounded and handles timezone diversity naturally. Upholds Principle 6 (bounded operations).
- **Decision:** Per-minute cron fan-out (D1).
- **Notes / intent:** The minute-granularity cron ticker is a well-known pattern for timezone-aware scheduled emails. The scheduler query cost is acceptable at O(10K–100K) users queried per minute with a proper index.

---

### Topic 2: Idempotency mechanism — Redis lock vs. DB constraint

- **Question:** How should we prevent a user from receiving two digests in the same week if the job is enqueued or triggered twice?
- **Recommendation given:** DB-level unique constraint on `(user_id, week_start_date)`. More reliable than Redis locks (which expire) or application-level check-then-insert (race-prone). Upholds Principle 9 (make illegal states unrepresentable).
- **Decision:** `digest_sends` unique constraint (D2).
- **Notes / intent:** The constraint is the *only* durable guarantee. Redis deduplication at enqueue time is a complementary nice-to-have but not the primary gate.

---

### Topic 3: Unsubscribe token design — stored token vs. HMAC

- **Question:** How should unsubscribe tokens be implemented to satisfy the adversarial requirement (account-scoped, non-guessable)?
- **Recommendation given:** HMAC-SHA256 token with `user_id` and `week_start_date` in the message. Avoids a token table (Principle 1), is cryptographically non-guessable (Principle 11), and is user-scoped by construction.
- **Decision:** HMAC-signed token (D3).
- **Notes / intent:** The `week_start_date` in the HMAC input means tokens differ across weeks, limiting any replay scope. The token does not expire (intentionally — unsubscribe should work from old emails). If revocability is needed in future, migrate to stored tokens.

---

### Topic 4: Activity data query — live query vs. pre-aggregation

- **Question:** Should the digest content be computed at job execution time via a live Postgres query, or pre-aggregated into a summary table on write?
- **Recommendation given:** Live query at job time. Pre-aggregation adds write-path complexity and a new table without measured need. Background job context tolerates higher query latency. Upholds Principle 1 (YAGNI) and Principle 8 (measure, don't guess).
- **Decision:** Live Postgres query (D4).
- **Notes / intent:** Requires covering indexes on `(user_id, created_at)` on activity tables. This assumption surfaces a schema-gap risk (table names unknown — §13).

---

### Topic 5: Send-failure policy — retry with backoff vs. indefinite retry vs. reschedule

- **Question:** When SendGrid rejects a delivery, should we retry indefinitely, retry briefly and drop, or reschedule to later in the day?
- **Recommendation given:** Retry up to 3 times within ~5 minutes, then drop for the week. The blueprint is explicit that a late digest is worse than a missed one. Upholds Principle 5 (design for failure) and honors the blueprint's stated policy.
- **Decision:** 3 retries, then Dead queue (D5).
- **Notes / intent:** The Dead queue provides a manual recovery path for ops if the outage was short and they want to replay. This is a deliberate human-in-the-loop escape valve.

---

### Topic 6: Email rendering — server-side template vs. SendGrid dynamic templates

- **Question:** Should the email HTML be rendered by the application (ActionMailer + ERB) or by a SendGrid dynamic template stored in the SendGrid dashboard?
- **Recommendation given:** Server-side ActionMailer template. Keeps rendering in version control, testable via ActionMailer test mode, and avoids coupling the feature's view logic to a third-party dashboard. Upholds Principle 3 (high cohesion) and Principle 15 (design seams for testing).
- **Decision:** ActionMailer with ERB templates (D6).
- **Notes / intent:** A plain-text counterpart template is included for email clients that prefer it (accessibility / least-surprise).

---

### Topic 7: Feature flag design — global only vs. global + per-user

- **Question:** Is a single global kill-switch sufficient, or should there be both a global flag and a per-user opt-out?
- **Recommendation given:** Both. The global flag is an ops kill-switch; the per-user `digest_enabled` is the user's subscription preference (required by the blueprint's unsubscribe behavior). These are separate concerns and should be separate controls. Upholds Principle 3 (high cohesion).
- **Decision:** `WEEKLY_DIGEST_ROLLOUT_ENABLED` global + `users.digest_enabled` per-user (D7).
- **Notes / intent:** No percentage-based gradual ramp in v1 — binary on/off is sufficient for an email feature with a kill-switch.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** *[Running autonomously — no human available. Final review performed internally.]*
  - Confirmed: all 22 decision-taxonomy dimensions are covered in §15.
  - Flagged schema gap (activity table names) as an open risk in §13.
  - Flagged comment-mention storage ambiguity as an open risk in §13.
  - No additional concerns identified. Proceeding to write.
