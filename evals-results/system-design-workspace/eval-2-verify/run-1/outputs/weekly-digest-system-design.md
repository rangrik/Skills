# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./weekly-digest-blueprint.md](./weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The weekly digest is a purely background, write-once-per-user-per-week email pipeline. A Sidekiq cron job fires each hour, picks up every user whose local Monday 08:00 has arrived, assembles activity data from Postgres, and dispatches a per-user Sidekiq worker that queries the digest content, renders an HTML email, and sends it through SendGrid. Idempotency is the central architectural commitment: a `digest_sends` table records each week's send keyed to `(user_id, week_start)`, so job re-runs, deploys, or retries can never double-send. The single most important architectural choice is this idempotency record — without it the blueprint's "at most one digest per week" rule cannot survive the stated scenario of a job being triggered twice.

---

## 2. System Placement

This feature lives entirely in the background-job tier. There is no synchronous HTTP request path; no frontend component is added for the sending pipeline itself. The unsubscribe link is the only user-facing HTTP endpoint added.

**Components touched:**

```
[Sidekiq Cron — hourly]
    │
    ▼
DigestSchedulerJob          (new Sidekiq job — orchestrator)
    │  queries: users whose local 08:00 Monday has arrived and who
    │  have no digest_sends record for the current week
    │
    ├─► DigestSendJob (per user)   (new Sidekiq job — worker)
    │       │
    │       ├─ Queries Postgres: activity data for the rolling 7-day window
    │       ├─ Skips send if zero activity (blueprint rule: no empty digest)
    │       ├─ Inserts digest_sends row (idempotency lock, before send)
    │       ├─ Renders HTML email template
    │       └─ Calls SendGrid API
    │
    └─► (on unsubscribe click)
         UnsubscribeController#show   (new HTTP route — GET/POST)
             └─ validates HMAC token, sets user digest_enabled = false

[Postgres]
    ├─ users table (add: timezone, digest_enabled columns)
    ├─ digest_sends (new: idempotency + audit log)
    └─ existing activity tables (workspace items, comments, completions)

[SendGrid]
    └─ Transactional email delivery (single integration point)
```

Data flow summary:
1. Cron fires `DigestSchedulerJob` every hour.
2. Scheduler queries users whose current UTC time equals their local Monday 08:00 (within the current hour), joined to exclude users with a `digest_sends` record for the current `week_start`.
3. For each eligible user, enqueues a `DigestSendJob`.
4. `DigestSendJob` queries workspace activity, checks for zero activity, inserts the idempotency record, renders the email, and calls SendGrid.
5. On unsubscribe link click, `UnsubscribeController` validates the HMAC token and sets `digest_enabled = false`.

---

## 3. Architecture Decisions

### D1. Timezone-aware scheduling via hourly fan-out cron

- **Decision:** Run one Sidekiq cron job every hour. It queries users whose configured timezone places them at Monday 08:00–08:59 UTC at that moment, filtered to those who have not yet received a digest for the current `week_start`. Enqueue one `DigestSendJob` per qualifying user.
- **Why:** Satisfies the blueprint rule that each user receives the email at 08:00 in *their* timezone. A single Monday-morning cron at a fixed UTC time cannot do this. An hourly sweep with a per-user timezone check is the minimal mechanism that works. Upholds "simplicity first" — an hourly job is a standard Sidekiq pattern; no exotic scheduler is needed.
- **Alternatives considered:**
  - *One cron per timezone:* dozens of cron entries, hard to manage, fragile when DST offsets change.
  - *Minute-level cron:* unnecessary precision (sub-hour accuracy) increases scheduling overhead without user benefit.
  - *Pre-schedule all jobs on Sunday:* adds complexity; doesn't survive a deploy/restart cleanly; idempotency is harder to reason about.
- **Trade-off accepted:** Send time can slip by up to 59 minutes relative to the user's exact 08:00 (the job fires at most once per hour). The blueprint explicitly accepts "send time may slip" for late jobs, and sub-hour precision has no material user value for a weekly digest.

---

### D2. Idempotency via digest_sends table (insert-before-send)

- **Decision:** Before calling SendGrid, each `DigestSendJob` inserts a row into `digest_sends(user_id, week_start, status, created_at)` with a unique constraint on `(user_id, week_start)`. If the insert fails due to a conflict, the job exits cleanly without sending. On a successful insert, it proceeds to send and updates `status` to `sent` or `failed` on completion.
- **Why:** The blueprint explicitly requires "at most one digest per week" and names job double-trigger as a deviation scenario. This is the authoritative guard. Upholding "idempotency & bounded operations" (Principle 6) and "design for failure" (Principle 5): the record survives process crashes, retries, and re-deploys. The insert-before-send ordering ensures that even if the worker crashes after insert but before send, the user doesn't receive a duplicate on retry — at the cost of a single possible miss (see Accepted Compromises, C1).
- **Alternatives considered:**
  - *Check-then-send without a unique constraint:* race condition between two concurrent workers for the same user.
  - *Deduplicate in the scheduler only:* doesn't protect against retries of `DigestSendJob` itself after a partial failure.
  - *Redis-based lock:* not durable across restarts; adds a second store.
- **Trade-off accepted:** Insert-before-send means a crash between insert and send leaves `status = pending` with no email sent. Addressed in the retry / reconciliation logic (§7). A missed digest is acceptable per the blueprint's "a digest that arrives late is worse than one skipped" preference.

---

### D3. Activity query with a hard cap of ten highlighted items

- **Decision:** A single Postgres query (or a small set of queries) fetches new items, completed items, and comments mentioning the user in the rolling 7-day window. Counts are computed in the database. The top ten most recent items are selected for the highlight list using `ORDER BY created_at DESC LIMIT 10`. An `+N more` count is computed as `total_count - 10` when the total exceeds ten.
- **Why:** Satisfies the blueprint cap exactly. Doing the cap in SQL keeps the worker stateless and the query predictable. Upholds "get the data model right" (Principle 4) and "idempotency & bounded operations" (Principle 6): no unbounded fetches.
- **Alternatives considered:**
  - *Fetch all items, truncate in Ruby:* wasteful for active workspaces; risks large in-memory payloads.
  - *Pre-aggregate a materialized view:* over-engineering; digest is weekly and the query runs once per user, not on a hot path.
- **Trade-off accepted:** Recency-ordering is the only ranking criterion (blueprint specifies "chosen by recency"). No relevance ranking; this is an explicit out-of-scope item.

---

### D4. Permission-scoped activity query

- **Decision:** The activity query is always scoped to items the user is authorized to see: filtered by `workspace_id` values the user belongs to (standard workspace-membership join). Items in deleted workspaces are excluded by joining on `workspaces WHERE deleted_at IS NULL`.
- **Why:** The blueprint's adversarial scenario requires that digest content only includes items the user may see. Upholds "security & privacy by design" (Principle 11). The workspace-deletion edge case is also captured here.
- **Alternatives considered:**
  - *Trust that background jobs only see valid data:* not acceptable for a multi-tenant system; violates least-privilege.
- **Trade-off accepted:** Slightly more complex join; no material cost.

---

### D5. Signed HMAC unsubscribe token

- **Decision:** Each email's unsubscribe link is of the form `/digest/unsubscribe?token=<hmac>` where `<hmac>` is `HMAC-SHA256(secret_key, "unsubscribe:#{user_id}:#{week_start_epoch}")`. The controller validates the HMAC, extracts the `user_id`, and sets `digest_enabled = false`. No session or auth cookie is required. The token is scoped to the user and week; a past token cannot be replayed to unsubscribe again (it's already unsubscribed, so the operation is idempotent).
- **Why:** The blueprint's adversarial scenario requires the link to "act only on the account it was issued for and not be guessable." HMAC prevents enumeration. Upholds "security & privacy by design" (Principle 11). One-click unsubscribe does not require the user to be logged in — consistent with standard email unsubscribe UX.
- **Alternatives considered:**
  - *Signed JWT:* heavier; no benefit over HMAC for a single-field operation.
  - *UUID stored in DB:* requires a new table or column; HMAC achieves the same without state.
  - *Require login to unsubscribe:* breaks one-click UX; friction for an opt-out is a dark pattern.
- **Trade-off accepted:** If the HMAC secret rotates, old unsubscribe links in already-sent emails become invalid. Rotation policy must consider this window (see Open Risks, §13).

---

### D6. Empty-digest short-circuit before insert

- **Decision:** Before inserting the idempotency row, `DigestSendJob` queries for activity counts. If all counts are zero, the job exits without inserting into `digest_sends` and without sending an email.
- **Why:** Blueprint rule: "if a user had no relevant activity in the past week, no email is sent." Checking before the idempotency insert (rather than after) means a no-activity user won't consume an idempotency slot — if they somehow gain activity and a retry fires, the re-check would still see zero and still skip. Upholds "make illegal states unrepresentable" (Principle 9) — the idempotency record only exists when an email was (or is being) sent.
- **Alternatives considered:**
  - *Insert first, then check and mark `status = skipped`:* over-complicates the status state machine.
  - *Filter in the scheduler query:* requires the scheduler to compute activity, which is expensive when enqueuing thousands of users; better to push that check to the per-user worker.
- **Trade-off accepted:** The scheduler enqueues workers for users who may ultimately have nothing to send. This is acceptable — the worker's zero-activity check is cheap.

---

### D7. Brand-new user: partial-week window

- **Decision:** The rolling 7-day window is computed as `[user.created_at OR (monday_00:00 - 7 days), monday_00:00)`, whichever is later. For a user who joined mid-week, `user.created_at` is the window start.
- **Why:** Blueprint edge case: "a brand-new user who joined mid-week: they receive a digest covering only the days since they joined, if there was activity." This is a one-line adjustment to the query's `WHERE created_at >= window_start`. Upholds "simplicity first" (Principle 1) — no special code path; the window parameter changes.
- **Alternatives considered:**
  - *Skip first-week digest entirely:* violates the blueprint.
- **Trade-off accepted:** None material.

---

### D8. SendGrid as sole email delivery integration point

- **Decision:** All email delivery is routed through a single `EmailDeliveryService` (or equivalent thin wrapper) that calls the SendGrid API. No direct SendGrid SDK calls from job code; the service is the chokepoint. Auth via API key stored in environment secrets.
- **Why:** Upholds "high cohesion, loose coupling" (Principle 3) and "design the seams for testing" (Principle 15): a single chokepoint makes mocking trivial and a future provider swap cheap. Secrets are environment variables, not in-repo.
- **Alternatives considered:**
  - *Call SendGrid inline in the job:* works but couples job code to the SDK; harder to swap or mock.
- **Trade-off accepted:** One extra layer; negligible overhead.

---

## 4. Data Model & Persistence

### 4.1 New table: `digest_sends`

```sql
CREATE TABLE digest_sends (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start  DATE        NOT NULL,   -- Monday 00:00 local→UTC normalized date
  status      VARCHAR(16) NOT NULL DEFAULT 'pending',
                                       -- 'pending' | 'sent' | 'failed' | 'skipped'
  sent_at     TIMESTAMPTZ,
  error       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT digest_sends_user_week_unique UNIQUE (user_id, week_start)
);

CREATE INDEX digest_sends_week_start_idx ON digest_sends (week_start);
```

**Invariants:**
- `(user_id, week_start)` is unique — the core idempotency constraint.
- `week_start` is always a Monday date (enforced by the scheduler logic; a DB CHECK constraint can be added if wanted: `EXTRACT(DOW FROM week_start) = 1`).
- `status` transitions: `pending → sent | failed`. `skipped` is written for audit if the job exits before sending (e.g., post-retry timeout).

**Retention:** Retain indefinitely as an audit log. Rows are small (~100 bytes each); at 100k users × 52 weeks ≈ 5.2M rows/year — no partitioning needed at this scale. Revisit at 10× growth.

---

### 4.2 Modified table: `users`

Add two columns (migration):

```sql
ALTER TABLE users
  ADD COLUMN digest_enabled  BOOLEAN     NOT NULL DEFAULT true,
  ADD COLUMN timezone        VARCHAR(64) NOT NULL DEFAULT 'UTC';
```

**Invariants:**
- `timezone` must be a valid IANA timezone string. Validated at write time (user settings endpoint). If null/invalid, the scheduler defaults to `'UTC'` (blueprint edge case).
- `digest_enabled = false` means no `DigestSendJob` is enqueued for that user.

---

### 4.3 Existing tables (unchanged schema)

The activity query reads from existing workspace-item, completion, and comment tables. No schema changes are needed there; the query joins on `workspace_id` and `created_at` with the rolling window bounds.

---

### 4.4 Migration order

1. Add `digest_enabled` and `timezone` to `users` with safe defaults (`true`, `'UTC'`). No backfill required — defaults are correct.
2. Create `digest_sends` table. Deployed before the scheduler job is enabled.
3. The cron entry is added in the same deploy as or after step 2.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| SendGrid | Transactional email delivery | API key in `SENDGRID_API_KEY` env var; never in code or logs | ~$0.001/email at standard tiers; rate limit: 600 req/min on shared IP pools. Cost ceiling: proportional to user count — at 100k users, ~$100/week, well within standard plan. | HTTP 5xx or timeout: Sidekiq retries up to N times with exponential backoff, exhausting by end-of-Monday morning (see §7). On final failure, mark `status = failed` in `digest_sends` and drop — blueprint specifies no late delivery. HTTP 4xx (bad address): mark `status = failed`, log the bounce code; do not retry. | Stub `EmailDeliveryService` in tests with a test double; use SendGrid's sandbox mode in staging. Never call live API in unit tests. |

**Follow-up note:** SendGrid's template/dynamic-data API grammar (template IDs, substitution keys, from/reply-to field rules) belongs in a probe-tested skill, not inline in this document. The design uses a server-side rendered HTML body passed to the API as a raw `content` field — no SendGrid template ID dependency — to keep the integration grammar minimal and testable locally.

---

## 6. Performance, Scale & Caching

### Latency

The digest pipeline is entirely background; there are no user-visible synchronous latency targets for sending. The only user-visible HTTP action is the unsubscribe endpoint, which should respond in < 200ms p95 (a simple HMAC verify + single DB update — no exotic optimization needed).

### Scale

| Metric | Estimate | Reasoning |
|---|---|---|
| Users receiving digest/week | 100k (assumed; see A1) | Basis for all sizing |
| Peak enqueue rate | ~2,800 jobs/hour (100k ÷ 36 hours of Monday-spread) | Users distributed across ~36 time zones of interest; spread across the 24h Monday window |
| Peak DB query rate | Same as above | One activity query per DigestSendJob |
| SendGrid calls/hour at peak | ~2,800 | Well within 600 req/min = 36,000 req/hour limit |
| `digest_sends` row growth | ~100k rows/week | Trivial at Postgres scale |

**Concurrency model:** The scheduler enqueues individual `DigestSendJob` workers. Sidekiq's worker concurrency (typically 10–25 threads per process) naturally rate-limits DB and SendGrid load. No custom rate-limiting needed at current scale. If fan-out exceeds SendGrid's per-minute limit, a Sidekiq throttle (e.g. via `sidekiq-throttled`) on the `digest` queue can be added.

**Activity query performance:**
- The query filters by `user_id`, `workspace_id`, and a date range — standard indexed columns on activity tables. Expected p95 < 50ms per user.
- No caching of activity data: each query runs fresh per user at send time. The data is inherently time-bounded (7-day window) and the query runs exactly once per user per week — caching would add complexity without meaningful benefit (Principle 1).

### Caching

No application-layer cache is introduced. The `digest_sends` lookup in the scheduler is a simple indexed query; its own result set is the implicit "already sent" filter. The five-question cache test (what/where/TTL/invalidation/freshness trade-off) resolves to: nothing needs caching at this scale and access pattern.

---

## 7. Reliability & Failure Handling

### Email provider failure (SendGrid down or message rejected)

Blueprint deviation: *"retried; if still fails after retries, dropped for the week rather than delayed into the afternoon."*

**Implementation:**
- `DigestSendJob` retries on 5xx / network errors using Sidekiq's built-in retry with exponential backoff.
- **Retry deadline:** The retry schedule must exhaust before ~12:00 local Monday (to avoid "digest that arrives late is worse than one skipped"). Configure `sidekiq_options retry: 5` with exponential backoff — 5 retries cover ~2–4 hours, exhausting by mid-morning.
- On final retry exhaustion, Sidekiq moves the job to the dead queue; a `sidekiq_retries_exhausted` callback marks `digest_sends.status = 'failed'` and logs the error for observability.
- On SendGrid 4xx (invalid address, unsubscribed at provider level): do not retry; mark `status = 'failed'` immediately.

### Job triggered twice (D2 idempotency)

The unique constraint on `digest_sends(user_id, week_start)` prevents double-send. The second `DigestSendJob` for the same user attempts an insert, gets a unique-constraint violation, and exits cleanly. This is logged as "idempotency skip, not an error."

### Job delayed and starts late

The scheduler computes `week_start` and the 7-day window from the user's timezone — not from the wall clock at job execution time. A late job uses the same window bounds, so content is unaffected. Send time may slip, which the blueprint accepts.

### Insert-before-send crash recovery

If a worker crashes between the `digest_sends` insert (`status = pending`) and the SendGrid call, the row remains `pending`. On the next hourly cron pass, the scheduler's query filters by `NOT EXISTS (SELECT 1 FROM digest_sends WHERE user_id = u.id AND week_start = :week_start)` — this means the `pending` row *will* block re-enqueueing by default. To handle the crash case, the scheduler (or a separate reconciliation pass) should also pick up rows that have been `pending` for more than, say, 30 minutes, and re-enqueue those users. This is a small additional query on `digest_sends`. Alternatively, the unique-constraint approach can be revised to: insert with `ON CONFLICT DO NOTHING` and only skip if `status IN ('sent', 'failed')` — allowing re-enqueueing for stuck `pending` rows (see Open Risks, §13).

### Deleted workspace

Activity query always joins `workspaces WHERE deleted_at IS NULL`. Items from deleted workspaces are invisible to the query. If a user's *only* workspace is deleted, the activity count is zero and no email is sent (zero-activity short-circuit, D6).

### User with no timezone set

Scheduler defaults `COALESCE(timezone, 'UTC')`. Blueprint specifies default to 08:00 UTC, which this achieves.

### Timezone change on Sunday night

The scheduler reads `users.timezone` at job enqueue time. If changed Sunday night, the next Monday's sweep picks up the new value — the correct behavior per the blueprint.

---

## 8. Security & Privacy

### Unsubscribe token

- HMAC-SHA256 over `"unsubscribe:#{user_id}:#{week_start_epoch}"` with a server-side secret (`DIGEST_HMAC_SECRET` env var).
- The controller validates the signature before trusting any extracted `user_id`.
- The token is single-purpose: it can only set `digest_enabled = false`. No other state is modified via this endpoint.
- No session cookie required (GET or POST; GET is acceptable for a simple flag flip with no side effects beyond opt-out).
- Rate-limit the unsubscribe endpoint (e.g. 10 requests/minute/IP) to prevent enumeration attempts, though the HMAC already makes enumeration infeasible.

### Authorization on activity queries

`DigestSendJob` queries only items where the user has active workspace membership. The query joins `workspace_memberships WHERE user_id = :user_id AND workspace.deleted_at IS NULL`. No cross-user or cross-workspace data leakage is possible by construction.

### PII in logs

Logs must not include email addresses, item content, or user-identifiable activity data. Log `user_id` (opaque integer), `week_start`, and `status` only. Error logs may include SendGrid error codes but not the email body.

### Secret handling

- `SENDGRID_API_KEY` and `DIGEST_HMAC_SECRET` are environment variables; never committed or logged.
- No secrets are embedded in the email body or links.

### Abuse

- Idempotency record prevents sending more than one email per user per week, regardless of how the job is invoked.
- Item links in the email are standard authenticated deep-links; the user must be logged in to view item content. No data is exposed in the email body that isn't already visible to the user.

---

## 9. Observability

### Metrics (emit per job run)

| Metric | Description |
|---|---|
| `digest.scheduler.users_enqueued` | Count of `DigestSendJob`s enqueued per cron run |
| `digest.send.success` | Count of emails successfully sent (per week cohort) |
| `digest.send.skipped_no_activity` | Count of users skipped due to zero activity |
| `digest.send.skipped_idempotency` | Count of jobs skipped due to existing `digest_sends` record |
| `digest.send.failed` | Count of final-failure sends (exhausted retries) |
| `digest.send.duration_ms` | p50/p95 per-job wall time |
| `digest.sendgrid.error_rate` | Rate of SendGrid non-2xx responses |

### Logs

- Structured log on every job: `user_id`, `week_start`, `status`, `duration_ms`, `error_code` (if any).
- Log at WARN level for: idempotency conflicts (informational, not errors), zero-activity skips.
- Log at ERROR level for: SendGrid failures, HMAC validation failures on unsubscribe.

### The one signal that proves the feature is healthy

> **`digest.send.success` for the current week's cohort reaches expected user count by Monday noon UTC.**

Alert if by Monday 14:00 UTC, `digest.send.success + digest.send.skipped_no_activity` is less than 80% of `digest.scheduler.users_enqueued` for that `week_start`. This catches scheduler failures, SendGrid outages, and broken workers without flooding on individual per-user retries.

### Traces

Wrap `DigestSendJob#perform` in a trace span. Include `user_id` and `week_start` as trace attributes. The SendGrid HTTP call should be a child span so latency attribution is clear.

### Alerts

1. **Scheduler not firing:** Alert if `digest.scheduler.users_enqueued` is zero on any Monday between 00:00–23:00 UTC (implies cron misconfiguration or Sidekiq down).
2. **High failure rate:** Alert if `digest.send.failed / digest.send.success > 5%` for a given week.
3. **Unhealthy completion rate:** Alert on the "one signal" above.

---

## 10. Rollout & Operability

### Feature flag

Gate the scheduler cron entry (and the `DigestSendJob` enqueue logic) behind a feature flag `digest_weekly_enabled`. Default: **off**. This is a kill switch, not a gradual rollout flag — once enabled, all eligible users receive digests.

**Gradual rollout option (recommended):** Before full rollout, enable for a percentage of users (e.g. `user_id % 100 < 10` for 10%) by adding a sampling check in the scheduler. This allows volume and SendGrid cost validation before full launch.

### Migration / deploy order

1. Deploy migration: add `digest_enabled`, `timezone` columns to `users` (safe; defaults are correct, backward-compatible).
2. Deploy migration: create `digest_sends` table (safe; no existing code reads it).
3. Deploy application code (scheduler, worker, unsubscribe endpoint) with `digest_weekly_enabled = false`.
4. Smoke test the scheduler locally / in staging with a small set of test users.
5. Enable `digest_weekly_enabled = true` (or at partial rollout %) — ideally on a Thursday/Friday so the first real Monday sweep is a few days away.

### Reversibility

- Disabling `digest_weekly_enabled` stops all new sends immediately. Already-sent digests are not revocable (email is inherently fire-and-forget).
- The `digest_sends` table serves as a full audit log and can be retained indefinitely.
- Schema changes (`digest_enabled`, `timezone` columns) are additive and non-breaking; they can be dropped safely if the feature is removed, with a down migration.

### Operational runbook hints

- To manually skip a user for a week: insert a row into `digest_sends(user_id, week_start, status='skipped')`.
- To manually re-send for a user (e.g. after a bug): delete the `digest_sends` row for that `(user_id, week_start)` and re-enqueue `DigestSendJob`.
- To disable the scheduler in an emergency: flip `digest_weekly_enabled = false`; all queued-but-not-yet-executed workers will check the flag and exit (flag check should be at the top of `DigestSendJob#perform`).

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | User base is up to ~100k active users at launch; 10× growth within 2 years | Typical SaaS scale; sizing shows no architectural changes needed at either point | Yes — confirm order-of-magnitude |
| A2 | The `users` table exists with `id`, and activity tables (items, comments, completions) exist with `workspace_id`, `user_id`, `created_at` columns | Standard workspace app schema; blueprint references "workspace activity" | Low risk; verify column names during implementation |
| A3 | Sidekiq is already running in production with a cron plugin (e.g. `sidekiq-cron` or `sidekiq-scheduler`) | Stack specified as Sidekiq for background jobs | Yes — confirm cron plugin is available |
| A4 | IANA timezone strings are stored/validated at the user settings layer | Standard approach; Rails `ActiveSupport::TimeZone` handles IANA names | Low risk |
| A5 | SendGrid is on a plan that supports ~100k emails/week without special approval | Standard SendGrid paid plans include this; dedicated IP may be needed for deliverability | Yes — confirm plan tier |
| A6 | No existing email abstraction layer exists; a thin `EmailDeliveryService` wrapper is new | Stack described as straightforward; no mention of an existing mailer abstraction | Low risk to add |
| A7 | `week_start` is defined as the user's local Monday 00:00 converted to a normalized DATE (UTC date of that Monday) | Consistent with "rolling seven days ending Monday 00:00 local time" in the blueprint | No — derivable from blueprint |
| A8 | The retry budget (5 retries, ~2–4 hours) is acceptable for the "exhausted by mid-morning" goal | Sidekiq default exponential backoff: 15s, 1m, 5m, 30m, 2h ≈ 2h45m total | Yes — confirm retry count/schedule |
| A9 | Item deep-links in the email are standard authenticated app URLs; no special link-generation service is needed | Blueprint says "clicking any item link opens that item in the app" — standard URL format | Low risk |
| A10 | `kite-arch-compass` is not available; design uses the generic principles lens | Confirmed in task description | N/A — documented |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Insert-before-send idempotency: a crash between insert and send leaves the user without a digest that week | One possible missed digest per crash event | Design for failure (Principle 5) — ideally every failure mode has a recovery path | Blueprint explicitly prefers a skipped digest over a late one. The reconciliation pass (§7) mitigates stuck `pending` rows. Missed digests are individually low-value (weekly, informational). | If missed-digest rate exceeds 1% of sends, invest in the reconciliation pass as a first-class feature. |
| C2 | Send time can slip up to 59 minutes from the user's exact 08:00 | Sub-hour precision on send time | Principle of least surprise (Principle 14) — users might expect 08:00 exactly | Blueprint explicitly accepts "send time may slip." Weekly digests have no time-sensitivity within a 1-hour window. | If UX research shows users notice or care, move to per-minute scheduling or pre-schedule jobs at exact send time. |
| C3 | No activity pre-aggregation; activity counts computed fresh at send time | Slightly higher DB load during Monday sweeps | Cost as a first-class constraint (Principle 12) — aggregation would reduce query load | At current scale (~100k jobs spread over 24h), the peak is ~2,800 queries/hour — well within Postgres capacity. A materialized view would add schema complexity with no current need (Principle 1). | Revisit if DB load during Monday sweeps measurably degrades other queries (add monitoring signal). |
| C4 | Gradual rollout is done via a simple modulo sampling check in the scheduler, not a formal feature-flag system | Less fine-grained control; can't target specific user segments | Match existing patterns (Principle 2) — without knowing the existing flag system, a simple modulo is the safe fallback | Sufficient for a volume/cost validation rollout. | Replace with the production feature-flag system when the existing conventions are known. |

---

## 13. Open Risks & Callouts

1. **Stuck `pending` rows (crash-recovery gap):** The current design leaves a gap where a worker crash after insert but before send blocks re-enqueueing. The reconciliation pass described in §7 is recommended but not yet fully designed. Before launch, decide: either implement the reconciliation query, or change the scheduler filter to skip only `sent`/`failed` rows (allowing `pending` re-enqueueing) with an additional flag-check in the worker to avoid double-sends. Both options are viable; the choice should be made during implementation.

2. **HMAC secret rotation:** Rotating `DIGEST_HMAC_SECRET` invalidates all unsubscribe links in already-delivered emails. These links are in emails that could be in inboxes for months. A rotation strategy (e.g. accept signatures from both old and new key during a transition period) should be defined before production rotation.

3. **SendGrid deliverability / reputation:** Sending ~100k emails/week from a new sending domain requires SPF, DKIM, and DMARC records and potentially a dedicated IP with a warmup schedule. This is an operational prerequisite, not a code concern, but it must be done before full launch.

4. **Timezone edge cases (DST transitions):** On DST change weekends, some users' "Monday 08:00 local" may not map cleanly to a single UTC hour. The hourly sweep handles this correctly (it checks the current UTC time against each user's local time), but DST transitions that occur at 02:00 local (e.g. US/EU) on a Monday are rare but possible. Verify with timezone library behavior.

5. **Large workspace activity counts:** A user in a very active workspace could have thousands of activity items in the 7-day window. The query caps highlights at 10 (`LIMIT 10`) and counts the total — but the `COUNT(*)` across all activity tables should have EXPLAIN-analyzed query plans before launch to confirm index usage.

---

## 14. Out of Scope

The following are explicitly out of scope for this design, consistent with the blueprint and the task:

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering of the digest content.
- Email template visual design and HTML/CSS specifics (implementation concern, not architecture).
- SendGrid template API grammar and substitution keys (belongs in a probe-tested skill, per the skill's external-system-grammar guardrail).
- Push notifications or Slack/webhook digest delivery channels.
- Analytics on email open rates or click-through rates (can be added via SendGrid's tracking features without architectural changes).
- Admin tooling to view or replay digest send history (the `digest_sends` table provides the data; UI is out of scope).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — background job, no user-visible latency; unsubscribe endpoint < 200ms p95 |
| A2 Throughput & scale | Assumed (A1) | §6 — ~100k users, ~2,800 jobs/hour peak; within Sidekiq + Postgres + SendGrid limits |
| A3 Concurrency & consistency | Resolved | D2 — unique constraint on `digest_sends(user_id, week_start)` prevents double-send; idempotency survives concurrent workers |
| A4 Availability & reliability | Resolved | §7, D2 — retry with deadline, drop-after-exhaustion per blueprint preference, idempotency guard |
| A5 Data integrity & durability | Resolved | §4 — `digest_sends` unique constraint; `users` column defaults; transactional insert; audit log retained indefinitely |
| A6 Caching & freshness | Resolved | §6 — no caching; fresh query per user per week; five-question test resolves to "no cache needed" |
| A7 Cost | Assumed (A5) | §5, §6 — ~$100/week at 100k users on standard SendGrid plan; no runaway vector (capped sends) |
| A8 Security & privacy | Resolved | D5, §8 — HMAC unsubscribe token, permission-scoped queries, PII-free logs, secrets in env vars |
| A9 Observability | Resolved | §9 — metrics, logs, traces, three alerts, primary health signal defined |
| A10 Maintainability & simplicity | Resolved | D1, D8 — hourly cron is a standard pattern; single SendGrid chokepoint; no novel abstractions |
| A11 Testability | Resolved | D8, §5 — `EmailDeliveryService` wrapper is mockable; deterministic seams on activity queries (date-bounded); Sidekiq testing via `sidekiq/testing` inline mode |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, gradual rollout option, reversibility |
| A13 Backward compatibility | Resolved | §4.4 — all schema changes are additive (new columns with safe defaults, new table); no existing API contract changes |
| A14 Accessibility & device/env | Resolved (N/A for sending pipeline) | Email HTML should follow accessible email conventions (alt text, semantic structure) — this is an implementation concern for the template, not an architectural decision. Unsubscribe endpoint has no accessibility surface. |
| B1 Placement / module taxonomy | Resolved | §2 — two new Sidekiq jobs (`DigestSchedulerJob`, `DigestSendJob`), one new controller (`UnsubscribeController`), one new service (`EmailDeliveryService`) |
| B2 Data model & persistence | Resolved | §4 — `digest_sends` table, `users` columns; migration order; invariants; retention |
| B3 API surface & schemas | Resolved | §2, §8 — one new route: `GET /digest/unsubscribe?token=<hmac>`; no new JSON API endpoints; no schema changes to existing routes |
| B4 Async / background work | Resolved | D1, D2, §7 — hourly cron + per-user worker; idempotent; retry deadline; completion surfaced via `digest_sends` status |
| B5 External services & contracts | Resolved | §5 — SendGrid: purpose, auth, rate limits, cost, failure modes, mock strategy |
| B6 Frontend integration | N/A | The digest is email-only. The unsubscribe endpoint is a standalone HTTP handler, not part of the frontend SPA. No frontend state or polling is involved. |
| B7 Feature flags & rollout | Resolved | §10 — `digest_weekly_enabled` flag, default off, gradual rollout via modulo sampling |
| B8 Error handling | Resolved | §7, D2 — Sidekiq retries on 5xx; no-retry on 4xx; exhaustion callback writes `status = failed`; idempotency conflict is a clean exit (logged, not an error) |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Every Monday morning, each user receives a digest of the previous seven days | Behavior | D1, §2 | Hourly cron identifies users at local Monday 08:00; enqueues per-user send job |
| Send time is 8:00 AM in each user's configured timezone | Behavior | D1 | Scheduler computes local Monday 08:00 per user using `users.timezone` |
| Digest covers rolling seven days ending Monday 00:00 local time | Behavior | D3, D7 | Window computed as `[MAX(user.created_at, monday_minus_7_days), monday_00:00)` in user's tz |
| User receives one email with headline summary, counts, and up to ten highlighted items | Behavior | D3 | Count queries + `ORDER BY created_at DESC LIMIT 10`; email assembled in `DigestSendJob` |
| Each email has a one-click unsubscribe link | Behavior | D5, §8 | HMAC-signed token in footer; `UnsubscribeController` validates and sets `digest_enabled = false` |
| Clicking item link opens that item in the app | Behavior | A9 (assumption) | Standard authenticated deep-links; no special architecture needed |
| A user with digests turned off receives nothing | Behavior | D1 | Scheduler query filters `WHERE digest_enabled = true` |
| No email sent if no relevant activity in past week | Behavior | D6 | Zero-activity short-circuit before idempotency insert in `DigestSendJob` |
| Each user receives at most one digest per week | Behavior | D2 | Unique constraint on `digest_sends(user_id, week_start)` |
| Highlighted items chosen by recency, capped at ten; "+N more" if over ten | Behavior | D3 | `ORDER BY created_at DESC LIMIT 10`; `+N more` = `total_count - 10` |
| Unsubscribing is immediate and takes effect before next Monday | Behavior | D5 | `digest_enabled = false` written immediately on link click; scheduler reads live value |
| Brand-new user joined mid-week: digest covers days since joining | Edge case | D7 | Window start is `MAX(user.created_at, monday_minus_7_days)` |
| User in deleted workspace: no email | Edge case | D4 | Activity query joins `workspaces WHERE deleted_at IS NULL`; zero results → zero-activity skip |
| User with no timezone set: defaults to 08:00 UTC | Edge case | §7, A4 | `COALESCE(timezone, 'UTC')` in scheduler query |
| User changes timezone Sunday night: next digest uses new timezone | Edge case | §7 | Scheduler reads live `users.timezone` at enqueue time each week |
| Email provider down or rejects at send time: retry, then drop for the week | Deviation | §7 | Sidekiq retries with exponential backoff; deadline exhausts by mid-morning; final failure → `status = failed`, dropped |
| Weekly job triggered twice: user still gets only one digest | Deviation | D2 | Unique constraint conflict on second insert → clean exit |
| Job delayed and starts late: correct seven-day window, send time may slip | Deviation | D1, D3 | Window is time-based (not wall-clock at execution); scheduler re-queries users each hour |
| Unsubscribe link must act only on its issued account; not guessable | Adversarial | D5, §8 | HMAC-SHA256 with server secret; `user_id` extracted from validated token only |
| Digest content must only include items the user is allowed to see | Adversarial | D4, §8 | Permission-scoped query with workspace-membership join; deleted workspaces excluded |
| Daily or monthly digest frequencies | Out of scope | §14 | Explicitly out of scope per blueprint |
| User customization of activity types | Out of scope | §14 | Explicitly out of scope per blueprint |
| In-app rendering of the digest | Out of scope | §14 | Explicitly out of scope per blueprint |

---

## Appendix A: Captured Inputs

*Note: This design was produced autonomously with no human interviewee available. The following records the decisions, recommendations, and assumptions made in place of the P3 interview and P4 last-call gate. Each entry documents the question that would have been asked, the recommendation made, and the resolution chosen. These records serve as the "why" for a future reader.*

---

### Topic 1: Scheduling mechanism for per-timezone sends

- **Question:** How should we schedule per-user, per-timezone sends at 08:00 local time — one cron per timezone, a per-user scheduled job, or an hourly sweep?
- **Recommendation given:** Hourly sweep: one cron job checks each hour which users are at their local Monday 08:00. Simpler than per-timezone crons; no need to manage DST transitions in the scheduler configuration. Upholds simplicity (Principle 1) and match existing patterns (Principle 2).
- **User's answer:** Resolved autonomously as the hourly sweep.
- **Notes / intent:** The blueprint specifies 08:00 in each user's timezone as an absolute requirement. The hourly sweep is the minimal mechanism that satisfies it without managing N cron entries. Sub-hour precision is not required for a weekly digest.

---

### Topic 2: Idempotency mechanism for "at most one digest per week"

- **Question:** How do we enforce the blueprint's "each user receives at most one digest per week" rule, including the double-trigger deviation scenario? Options: in-memory lock, Redis lock, or DB unique constraint.
- **Recommendation given:** DB unique constraint on `digest_sends(user_id, week_start)` — durable across restarts, works in multi-process Sidekiq deployments, no extra infrastructure. Insert-before-send is the correct ordering.
- **User's answer:** Resolved autonomously with the DB constraint.
- **Notes / intent:** Redis locks are not durable across crashes; the blueprint's scenario explicitly names a job being triggered twice by a deploy, which implies a durability requirement.

---

### Topic 3: Activity query — pre-aggregate vs. query at send time

- **Question:** Should activity data be pre-aggregated (e.g. materialized view updated incrementally throughout the week) or queried fresh at send time?
- **Recommendation given:** Query fresh at send time. Pre-aggregation adds schema complexity and a continuous background job for a query that runs once per user per week. At current scale (~100k users, spread over 24h), fresh queries are within normal Postgres capacity. Upholds simplicity (Principle 1) and measure don't guess (Principle 8).
- **User's answer:** Resolved autonomously as fresh query.
- **Notes / intent:** If the DB shows load spikes on Monday mornings, a materialized view can be added without changing the consumer interface (the worker just reads a different table).

---

### Topic 4: Unsubscribe token mechanism

- **Question:** How should the unsubscribe token be generated — UUID stored in DB, JWT, or HMAC?
- **Recommendation given:** HMAC-SHA256 over `"unsubscribe:#{user_id}:#{week_start_epoch}"`. No DB storage needed; token is unforgeable; operation is idempotent. Upholds security by design (Principle 11) and simplicity (Principle 1).
- **User's answer:** Resolved autonomously as HMAC.
- **Notes / intent:** The blueprint's adversarial scenario is explicit: "must not be guessable to unsubscribe someone else." HMAC satisfies this without a new table. One-click UX (no login required) is standard for email unsubscribe.

---

### Topic 5: Retry deadline for failed sends

- **Question:** How many retries should `DigestSendJob` attempt before giving up? The blueprint says "if it still fails after retries, dropped for the week rather than delayed into the afternoon."
- **Recommendation given:** 5 retries with Sidekiq's default exponential backoff (~2h45m total). This exhausts well before noon local time for a job that starts at 08:00. Upholds design for failure (Principle 5).
- **User's answer:** Resolved autonomously as 5 retries.
- **Notes / intent:** The exact retry count should be confirmed with the team since it depends on how early the Sidekiq process starts sending (first jobs at ~00:00 UTC, last at ~23:00 UTC — all should exhaust the same day).

---

### Topic 6: Feature flag and rollout strategy

- **Question:** Should rollout be all-at-once or gradual? What flag gates it?
- **Recommendation given:** Feature flag `digest_weekly_enabled` defaults off. Recommend a gradual rollout via modulo sampling in the scheduler (e.g. 10% → 50% → 100%) before full launch, to validate SendGrid volume and DB load.
- **User's answer:** Resolved autonomously with gradual rollout recommendation noted.
- **Notes / intent:** Without knowing the production feature-flag system, a simple modulo check is the safe fallback. Replace with the team's existing flag infrastructure when conventions are known (Accepted Compromise C4).

---

### Last-call (P4)

- **Asked:** "Before writing this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** No human available to respond. The following areas were reviewed for completeness: DST edge cases (noted in Open Risks §13); large workspace activity counts (noted in Open Risks §13); SendGrid deliverability prerequisites (noted in Open Risks §13); crash-recovery gap in insert-before-send (noted in Open Risks §13 and §7). No additional gaps identified after this review.
