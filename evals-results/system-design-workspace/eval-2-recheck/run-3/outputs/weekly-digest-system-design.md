# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../inputs/weekly-digest-blueprint.md](../inputs/weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The weekly digest feature is implemented as a timezone-bucketed Sidekiq background job that fires continuously throughout Monday, dispatching per-user digest emails via SendGrid. The most important architectural choice is **per-timezone scheduling via a coordinator job and per-user child jobs**, rather than a single Monday-morning batch. This approach naturally handles the blueprint's requirement that each user receives their email at 8:00 AM in their own timezone — without blocking a single long-running job on a global user scan — and keeps per-user work isolated and retry-safe. Idempotency is enforced through a `digest_sends` ledger table keyed on `(user_id, digest_week_start)`, which prevents duplicate sends even if the coordinator job is triggered twice. The design introduces three new database tables, no new HTTP routes, and relies on Sidekiq's native retry semantics with a dead-letter-drop policy aligned to the blueprint's preference for skipping rather than late-delivering.

---

## 2. System Placement

This feature is a pure **background-job system** with no new user-facing HTTP routes. It lives entirely in the backend.

### Components touched

- **New: `DigestCoordinatorJob` (Sidekiq job)** — scheduled by cron (e.g. via `sidekiq-cron` or `whenever`). Runs every hour on Mondays. For each timezone offset whose 8:00 AM local time falls within the current hour, it enqueues one `DigestUserJob` per eligible user in that timezone bucket.
- **New: `DigestUserJob` (Sidekiq job)** — processes a single user. Checks the ledger for an existing send this week; if already sent, exits immediately. Queries workspace activity, skips if no qualifying activity exists, then builds and sends the email via SendGrid, recording the send in the ledger.
- **New: `DigestActivityQuery` (service/query object)** — encapsulates the workspace activity query (new items, completed items, comments mentioning the user, recency-sorted, capped at 10). Enforces the user's permission boundary so only visible items are included.
- **New: `DigestEmailBuilder` (service object)** — renders the email payload (subject, HTML/text body, item links, unsubscribe link). Isolated so it can be unit-tested without a database.
- **New: `UnsubscribeController` action** — one new HTTP endpoint (`GET /digest/unsubscribe?token=<token>`) that validates the HMAC token, sets `digest_opted_in = false` on the user, and renders a confirmation page.
- **Existing: `User` model** — gains `timezone`, `digest_opted_in` columns (may already exist in part; see §4).
- **Existing: SendGrid integration layer** — extended or reused as the email transport.

### Data-flow sketch

```
[cron: every hour on Monday]
    └─► DigestCoordinatorJob
          ├─ resolves which timezone offsets hit 8:00 AM this hour
          ├─ queries users in those offsets with digest_opted_in = true
          └─► enqueues DigestUserJob(user_id, digest_week_start) per user
                  │
                  ├─ check digest_sends ledger → already sent? EXIT
                  ├─ DigestActivityQuery(user, week_window) → no activity? EXIT
                  ├─ DigestEmailBuilder.build(user, activity)
                  ├─ SendGrid.send(email_payload)
                  └─ insert digest_sends(user_id, digest_week_start, sent_at, sendgrid_message_id)
```

---

## 3. Architecture Decisions

### D1. Per-timezone coordinator + per-user child jobs (not a single global batch)

- **Decision:** A lightweight `DigestCoordinatorJob` runs hourly on Mondays, buckets users by their UTC-offset-derived 8:00 AM window, and enqueues one `DigestUserJob` per user. Each child job is fully isolated.
- **Why:** The blueprint requires delivery at 8:00 AM local time per user. A single batch job that processes all users at once cannot honor this — it would either send everyone at one fixed time or require complex in-process fan-out. Per-user jobs keep work isolated, parallelized, and individually retry-safe (Principle 3: high cohesion, loose coupling; Principle 6: bounded operations with backpressure; Principle 5: design for failure).
- **Alternatives considered:**
  - *Single Monday 00:00 UTC batch with delayed_job delivery times:* requires storing future delivery timestamps and polling — more moving parts, harder to reason about. Rejected.
  - *One cron entry per timezone (24+ cron jobs):* operationally unwieldy; managing 24 cron schedules is worse than one coordinator. Rejected.
- **Trade-off accepted:** The coordinator adds an extra hop (coordinator enqueues child, child does the work). This is a minor complexity cost, well paid for by timezone correctness and isolated retry semantics.

---

### D2. Idempotency via `digest_sends` ledger table

- **Decision:** Before sending, `DigestUserJob` checks for an existing row in `digest_sends` keyed on `(user_id, digest_week_start)`. If a row exists, the job exits without sending. The row is inserted after a confirmed send (SendGrid returns 2xx). A unique index enforces uniqueness at the database level.
- **Why:** The blueprint's deviation scenario explicitly requires that a user receives at most one digest per week even if the coordinator is triggered twice. A database-level unique constraint makes this invariant unrepresentable to violate (Principle 9: make illegal states unrepresentable; Principle 6: idempotency by design).
- **Alternatives considered:**
  - *Redis-based deduplication key:* faster check but lacks durability — if Redis is flushed or the key expires, a duplicate send becomes possible. Rejected.
  - *Relying on Sidekiq's unique jobs plugin:* useful complementary protection but not a substitute for durable state — a restart or queue flush would bypass it. Rejected as the sole guard.
- **Trade-off accepted:** An extra DB read at the start of every `DigestUserJob`. At plausible scale (see §6) this is negligible.

---

### D3. Skip rather than retry beyond threshold (aligned to blueprint deviation policy)

- **Decision:** `DigestUserJob` retries on transient SendGrid failures using Sidekiq's built-in retry with exponential backoff, capped at a maximum of 3 retries within a 2-hour window. If all retries are exhausted before the window closes, the job moves to the dead-letter queue and the digest is silently dropped for that week. No late delivery.
- **Why:** The blueprint is explicit: "a digest that arrives late is worse than one skipped." This is a product constraint that overrides the default "keep retrying until success" instinct. Reliability here means not delivering stale content on Tuesday (Principle 5: failure mode must be designed, not left to defaults; Principle 14: least surprise for the user).
- **Alternatives considered:**
  - *Unlimited retries:* could deliver a digest hours or days late — explicitly rejected by the blueprint.
  - *Retry with deadline check:* check wall-clock time before each retry attempt; if past a configured cutoff (e.g. noon Monday local time), drop without retrying. This is more precise but requires passing the user's timezone into retry logic. **Assumed as an enhancement** — see §11, A7.
- **Trade-off accepted:** Some users will miss a digest when SendGrid is briefly unavailable on a Monday. This is the blueprint's stated preference.

---

### D4. Unsubscribe via HMAC-signed token

- **Decision:** Each digest email's footer contains an unsubscribe URL of the form `/digest/unsubscribe?token=<hmac_token>`. The token is an HMAC-SHA256 of `user_id + ":" + week_start_date` using a server-side secret. The controller validates the HMAC, sets `users.digest_opted_in = false`, and renders a one-click confirmation. The token does not expire (but is scoped to the user_id it encodes, so it cannot unsubscribe a different user).
- **Why:** The blueprint's adversarial scenario requires the unsubscribe link to act only on the account it was issued for and to not be guessable. HMAC-signed tokens satisfy both requirements without needing a separate token storage table (Principle 11: security by design; Principle 4: get the data model right — avoids an extra table).
- **Alternatives considered:**
  - *UUID token stored in the database:* equally secure but requires a `digest_unsubscribe_tokens` table and a lookup on every unsubscribe click. More moving parts for equivalent security. Rejected (Principle 1: YAGNI).
  - *JWT:* heavier than needed for a simple one-field flag. Rejected.
- **Trade-off accepted:** HMAC tokens have no revocation mechanism — a token in an old email remains technically valid. Acceptable because the only action it can take is setting `digest_opted_in = false` on the correct user, which is already the user's right. Re-subscribing would be done through account settings (out of scope).

---

### D5. Activity query scoped by permission boundary at query time

- **Decision:** `DigestActivityQuery` applies the same authorization filter used in the normal app data layer: items from workspaces the user is a member of, excluding deleted workspaces. No activity data is persisted in a pre-aggregated digest-specific store.
- **Why:** The blueprint's adversarial scenario states that digest content must only include items the user is allowed to see. Computing this at query time from the live data model means permission changes (workspace deletion, membership revocation) are automatically respected without any stale cache to invalidate (Principle 11: security by design; Principle 13: cache invalidation is a design decision — avoiding a cache here removes a class of stale-data security bugs).
- **Alternatives considered:**
  - *Pre-aggregate activity into a `user_weekly_activity` table on each event:* faster at send time but introduces a secondary source of truth that can diverge from the live permission model. Rejected.
- **Trade-off accepted:** The activity query runs at send time, not pre-computed. At the scale anticipated (see §6), this is acceptable. If query latency becomes a problem, read-replica routing is the first lever.

---

### D6. Highlighted items sorted by recency, capped at 10

- **Decision:** Items are selected by `updated_at DESC` (or equivalent recency signal), the first 10 are included in the email, and if the total exceeds 10 the email appends "+N more." This is implemented as a `LIMIT 11` query (to detect overflow) rather than a count query.
- **Why:** The blueprint specifies recency as the sort criterion and 10 as the cap. Using `LIMIT 11` is a single query with minimal overhead that detects overflow without a separate `COUNT(*)` (Principle 1: simplicity; Principle 6: bounded operations — the query is always bounded).
- **Alternatives considered:**
  - *Separate COUNT query:* two round-trips for information one query can return. Rejected.
- **Trade-off accepted:** None significant.

---

### D7. New-user pro-rated window via `users.created_at`

- **Decision:** The digest window is computed as `MAX(monday_00:00_local - 7 days, user.created_at)`. This naturally gives new users a shorter window covering only their active days without any special case in the job logic.
- **Why:** The blueprint edge case states that a brand-new user should receive a digest covering only their active days. Using `created_at` as a lower bound is the simplest correct implementation (Principle 1: simplicity; Principle 9: encode invariants rather than checking after the fact).
- **Trade-off accepted:** None.

---

## 4. Data Model & Persistence

### New tables

#### `digest_sends`

Tracks that a digest was dispatched for a given user and week. The primary idempotency guard.

```sql
CREATE TABLE digest_sends (
  id               bigserial PRIMARY KEY,
  user_id          bigint       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  digest_week_start date        NOT NULL,  -- Monday 00:00 UTC of that week (canonical key)
  sent_at          timestamptz  NOT NULL DEFAULT now(),
  sendgrid_message_id varchar(128),         -- for correlation / delivery tracking
  status           varchar(32)  NOT NULL DEFAULT 'sent',
                                            -- 'sent' | 'skipped_no_activity' | 'failed_dropped'
  CONSTRAINT uq_digest_sends_user_week UNIQUE (user_id, digest_week_start)
);

CREATE INDEX idx_digest_sends_week ON digest_sends (digest_week_start);
```

**Invariants:**
- One row per `(user_id, digest_week_start)` — enforced by the UNIQUE constraint.
- `digest_week_start` is always stored in UTC (normalized from the user's local Monday 00:00).
- `status = 'skipped_no_activity'` rows are written when the job exits early (no activity), so that the "already processed" check still guards against re-enqueue.

**Retention:** Rows may be pruned after 90 days via a scheduled cleanup job (see §13 for the risk callout).

---

#### `digest_unsubscribe_log` (optional audit table)

Records unsubscribe events for support and audit.

```sql
CREATE TABLE digest_unsubscribe_log (
  id           bigserial PRIMARY KEY,
  user_id      bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  unsubscribed_at timestamptz NOT NULL DEFAULT now(),
  source       varchar(32) NOT NULL  -- 'email_link' | 'account_settings'
);
```

This is append-only; no unique constraint.

---

### Changes to existing tables

#### `users` (additive columns)

```sql
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS digest_opted_in boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS timezone         varchar(64) NOT NULL DEFAULT 'UTC';
```

- `digest_opted_in DEFAULT true` — all existing users are opted in at migration time (see §10 for the rollout caveat).
- `timezone` — stores an IANA timezone string (e.g. `"America/New_York"`). Defaults to `'UTC'` if not set, consistent with the blueprint's edge case.

**Migration shape:** Two additive `ADD COLUMN IF NOT EXISTS` migrations. No backfill required beyond the `DEFAULT` values. Fully reversible (the columns can be dropped if the feature is reverted before launch).

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid** | Transactional email delivery (digest + unsubscribe confirmation) | API key stored in environment variable / secrets manager (`SENDGRID_API_KEY`); never in source code | SendGrid free tier: 100 emails/day; paid plans scale to millions. At ~1 email/user/week the weekly burst is bounded by user count. Rate limit: 600 requests/min on most plans. | HTTP 4xx (bad request / invalid recipient): do not retry, record `status = 'failed_dropped'` in ledger. HTTP 429 (rate limit) or 5xx (server error): retry with Sidekiq backoff (D3). Connection timeout: retry. | Inject a `MailClient` interface; stub in tests. Integration tests use SendGrid's sandbox mode (sends are validated but not delivered). |

**Follow-up:** SendGrid's template/substitution DSL (dynamic template IDs, variable names, click-tracking parameters) carries external-system grammar that should live in a probe-tested skill rather than inline in the design. Note as a follow-up action.

---

## 6. Performance, Scale & Caching

### Latency targets

This is entirely background work. There is no user-visible synchronous latency path. The "latency" that matters is the **delivery window**: each user's email must be sent within a few minutes of their 8:00 AM local time. The coordinator runs hourly, so maximum delivery drift is ~60 minutes. This is acceptable for a weekly digest.

### Expected load

| Metric | Estimate | Notes |
|---|---|---|
| Users receiving digests | 10,000 (assumed; see A1) | Scales linearly |
| Emails per weekly run | ≤ 10,000 | Spread over 24 hours (timezone distribution) |
| Peak hourly burst | ~420 jobs/hour | Assuming even distribution across 24 UTC offsets |
| Activity query per job | 1 query (~10–50 ms) | Indexed by user_id + created_at; uses read replica if available |
| SendGrid calls per job | 1 | Sequential; no batching needed at this scale |

At 10,000 users the weekly run is comfortably handled by Sidekiq's default concurrency. Even at 100,000 users the hourly peak (~4,200 jobs/hour) is modest for Sidekiq + Postgres.

### Caching

There is **no caching introduced by this feature.** Activity data is queried fresh at send time (see D5). This is a deliberate choice: the query window is computed once per job (not shared across users), the data is inherently user-specific, and caching activity per user would require a per-user invalidation story that adds complexity without meaningful benefit at the current scale.

If query latency becomes a bottleneck, the first lever is **routing `DigestActivityQuery` to a Postgres read replica** — no cache layer needed, no invalidation risk.

### Concurrency model

- `DigestCoordinatorJob`: single instance (not parallelized); lightweight (DB query + enqueue). Sidekiq's unique-job plugin (or a Redis lock) prevents concurrent coordinator runs if the cron fires twice in the same minute.
- `DigestUserJob`: fully parallelized across Sidekiq workers. Each job is isolated per user; no shared mutable state. Idempotency is enforced by the ledger's unique constraint (D2), which handles concurrent duplicate enqueues safely via Postgres's UNIQUE conflict.

---

## 7. Reliability & Failure Handling

### SendGrid failure (blueprint deviation scenario 1)

- **Transient (5xx, timeout, 429):** Sidekiq retries with exponential backoff, up to 3 attempts. Retry window is capped (assumption A7 — see §11). After exhaustion, job moves to Sidekiq's dead-letter queue; `digest_sends` row is written with `status = 'failed_dropped'`.
- **Permanent (4xx invalid recipient):** No retry. Log the error, write `status = 'failed_dropped'`. Do not alert on individual failures — track via metric (§9).
- **User experience:** The user simply doesn't receive a digest that week. Consistent with the blueprint's stated preference: "a digest that arrives late is worse than one skipped."

### Coordinator triggered twice (blueprint deviation scenario 2)

- If the coordinator runs twice in the same hour, the same `DigestUserJob(user_id, digest_week_start)` is enqueued twice.
- The second job's first action is the ledger check: a row already exists → exit immediately. No duplicate send.
- The unique constraint ensures that even a race between two concurrent child jobs resolves correctly: one INSERT succeeds, the other hits a unique violation and exits.

### Job delayed and starts late (blueprint deviation scenario 3)

- If the coordinator runs late, the per-user query window is computed from `digest_week_start` (a fixed Monday 00:00 local date), not from wall-clock time. Content is unaffected. Send time may slip, but correctness is preserved.

### Deleted workspace edge case

- `DigestActivityQuery` joins against workspaces using a `WHERE workspaces.deleted_at IS NULL` filter. Items from deleted workspaces are excluded automatically. No special job-level handling needed.

### Idempotency on retry

- `DigestUserJob` checks the ledger before doing any work. If `status = 'sent'` already exists, the job exits cleanly. This makes every retry safe regardless of how it failed (before the SendGrid call, after, or mid-write).

---

## 8. Security & Privacy

### Unsubscribe token (blueprint adversarial scenario 1)

- Token = `HMAC-SHA256(secret_key, "#{user_id}:#{digest_week_start}")` encoded as URL-safe base64.
- The controller decodes the token, recomputes the HMAC for the embedded `user_id`, and compares in constant time (`ActiveSupport::SecurityUtils.secure_compare` or equivalent). A mismatch returns 404 — no information leak.
- An attacker who guesses or modifies the token cannot unsubscribe a different user: the HMAC will not validate.
- The secret key is stored in the same secrets manager as other app secrets; it is rotatable (old tokens would break, but that only affects outstanding unsubscribe links in already-delivered emails — acceptable; users can unsubscribe via account settings).

### Permission boundary on digest content (blueprint adversarial scenario 2)

- `DigestActivityQuery` is constructed using the same authorization helper that gates item visibility in the main app. This is not a separate permission check — it reuses the existing access-control layer (Principle 3: loose coupling; Principle 11: security by design).
- Items from deleted workspaces are excluded (D5).
- No digest content is cached in a way that could serve stale permissions.

### PII handling

- Email addresses are transmitted to SendGrid over HTTPS. SendGrid is already the app's transactional email provider — no new third-party PII disclosure.
- `digest_sends` stores `user_id` (an internal integer) and `sendgrid_message_id` (opaque string). No email addresses or user-visible content are persisted in the ledger.
- The unsubscribe log stores `user_id` and timestamp only.

### Secret handling

- `SENDGRID_API_KEY` is injected via environment variable from the secrets manager. Never hardcoded or logged.
- The HMAC signing key (`DIGEST_UNSUBSCRIBE_SECRET`) is a separate secret, also injected via environment.

### Input validation

- The unsubscribe endpoint's `token` parameter is validated by HMAC verification before any state mutation. Invalid or missing tokens return 404 without revealing whether the `user_id` exists.
- `DigestUserJob` receives a `user_id` (integer) and `digest_week_start` (date string). Both are validated at job construction time.

---

## 9. Observability

### Key metrics (emit via StatsD / Prometheus or equivalent)

| Metric | Type | Why |
|---|---|---|
| `digest.coordinator.users_enqueued` | Counter | How many jobs were kicked off this run |
| `digest.user_job.sent` | Counter | Successful sends this week |
| `digest.user_job.skipped_no_activity` | Counter | Users with no activity (expected; baseline) |
| `digest.user_job.failed_dropped` | Counter | Failed after retries — the key health signal |
| `digest.user_job.duplicate_skipped` | Counter | Idempotency guard fired — signals coordinator double-fire |
| `digest.user_job.duration_ms` | Histogram | Per-job latency |
| `digest.activity_query.duration_ms` | Histogram | DB query latency |
| `digest.sendgrid.http_status` | Counter (by status code) | SendGrid response distribution |

### Logs

Each `DigestUserJob` logs structured events:
- `[digest] user_id=X week=YYYY-MM-DD action=sent message_id=...`
- `[digest] user_id=X week=YYYY-MM-DD action=skipped_no_activity`
- `[digest] user_id=X week=YYYY-MM-DD action=failed status=... attempt=N`
- `[digest] user_id=X week=YYYY-MM-DD action=duplicate_skipped`

### Alerts

| Alert | Condition | Severity |
|---|---|---|
| High drop rate | `digest.user_job.failed_dropped / digest.user_job.sent > 5%` in a weekly run | P2 — investigate SendGrid |
| Coordinator did not run | No `digest.coordinator.users_enqueued` event on any Monday | P1 — cron broken |
| Zero sends on Monday | `digest.user_job.sent == 0` by noon UTC on Monday | P1 — possible job failure |

### The one signal that proves the feature is healthy

> **`digest.user_job.sent` is non-zero each Monday, and `digest.user_job.failed_dropped / sent < 1%`.**

### Traces

Wrap `DigestUserJob` execution in a distributed trace span. Include `user_id` and `digest_week_start` as trace attributes so failures can be correlated to specific users without scanning all logs.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a boolean flag `weekly_digest_enabled` (default: `false`). The coordinator job checks this flag at the top of its `perform` method and exits immediately if disabled. This allows:
- Safe deployment of all code before enabling the feature.
- Instant kill-switch if problems arise post-launch.

### Migration / backfill order

1. Deploy migration adding `users.digest_opted_in` (DEFAULT true) and `users.timezone` (DEFAULT 'UTC').
2. Deploy migration creating `digest_sends` and `digest_unsubscribe_log`.
3. Deploy application code with `weekly_digest_enabled = false`.
4. Verify migrations, smoke-test the coordinator and child jobs in staging.
5. Enable `weekly_digest_enabled = true` the week before the first intended Monday send.

**Important:** `digest_opted_in DEFAULT true` means all existing users are opted in at migration time. This is the standard behavior for a new notification type — users who don't want it unsubscribe. If the product decision is opt-in-only (users must explicitly enable), change the column default to `false` before running the migration. This is captured in §11, A2.

### Reversibility

- The feature flag provides an instant off-switch.
- Migrations are additive (new columns with defaults, new tables). Rollback: set `weekly_digest_enabled = false`; the new columns and tables are inert.
- Removing the columns/tables is a separate, later migration once the feature is confirmed stable.

### Coordination

- No frontend changes required for the core digest flow (emails are standalone HTML).
- The unsubscribe endpoint (`GET /digest/unsubscribe`) is new but requires no frontend SPA changes — it renders a server-side confirmation page.
- If a user-facing "manage digest preferences" UI is added later, that is a separate frontend work item (out of scope for this design).

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Initial user base is under 50,000. The design handles 100,000+ without architectural changes, but capacity planning above that is out of scope. | The feature is new; Sidekiq + Postgres is proven at this scale. | No — flag if user count exceeds 500K. |
| A2 | Existing users are opted in by default (digest_opted_in DEFAULT true). All users receive the first digest unless they unsubscribe. | Standard industry practice for a new digest notification. | **Yes — product must confirm opt-in vs. opt-out default.** |
| A3 | The app already has a SendGrid integration and the API key is available in the secrets manager. The weekly digest reuses the existing transport layer. | The blueprint references SendGrid as the stack. | No — confirm SendGrid account plan supports expected weekly volume. |
| A4 | Sidekiq is already running in production with a cron plugin (sidekiq-cron or whenever gem). The coordinator cron entry is a configuration addition, not new infrastructure. | Blueprint specifies Sidekiq for background jobs. | No — verify cron plugin availability. |
| A5 | The `users` table has a `timezone` column or it will be added by this feature's migration. If the column exists, it stores IANA timezone strings. | Blueprint specifies per-user timezone; a column is the natural home. | No — verify existing column name/type before migration. |
| A6 | `digest_week_start` is computed as the Monday 00:00 in the user's local timezone, then stored normalized to UTC date in the ledger. | Consistent UTC storage avoids timezone arithmetic bugs in queries. | No. |
| A7 | Retry cutoff is "within 2 hours of the scheduled send time." The exact cutoff is not yet encoded in the job — the current design caps retries at 3 attempts with exponential backoff, which in practice fits within 2 hours. A time-based cutoff guard is a desirable enhancement. | The blueprint says "dropped for the week rather than delayed into the afternoon" — 2-hour window is a reasonable interpretation. | **Yes — product should confirm the latest acceptable send time.** |
| A8 | `DigestActivityQuery` reuses the existing app-level authorization helper. That helper is already tested and covers workspace membership and deletion checks. | Blueprint adversarial scenario requires permission-scoped content. | No — confirm with the team which auth helper to call. |
| A9 | Items are sorted by `updated_at DESC` as the recency signal. If the app uses a different recency field (e.g. `last_activity_at`), the query should use that instead. | `updated_at` is universally present in Rails. | No — confirm with the team which field best represents recency. |
| A10 | A Sidekiq dead-letter queue (Sidekiq Pro's `DeadSet`, or sidekiq-failures gem) is available for failed jobs. Operators can inspect and re-enqueue dropped jobs if needed. | Standard Sidekiq setup. | No — verify DLQ configuration. |
| A11 | The unsubscribe confirmation page is a simple server-rendered HTML page (no SPA route). A full account-settings UI for digest preferences is out of scope. | Blueprint says "unsubscribe is immediate." A server-rendered page is the minimal implementation. | No. |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Coordinator runs hourly; maximum delivery drift is ~60 minutes from the user's 8:00 AM local time. | Precision send time; some users get their email at 8:47 AM instead of 8:00 AM. | Principle 14 (least surprise — users expect delivery at 8:00 AM) | A weekly digest is low-urgency; 60-minute drift is not user-visible harm. Running every 5 minutes adds unnecessary coordinator churn. | If product receives complaints about timing, increase coordinator frequency or switch to a minute-level cron. |
| C2 | Activity data is queried live at send time (no pre-aggregated activity store). | Faster send execution; avoids query latency at job time. | Principle 8 (measure, don't guess — we're paying query cost at job time based on assumption, not measurement) | At expected scale, a single indexed query per user is fast enough. Pre-aggregation would add a secondary store with its own permission-staleness risk. | Revisit if `DigestActivityQuery` p95 latency exceeds 500 ms under production load. |
| C3 | Failed digests (after retries) are silently dropped; no user notification, no retry next Tuesday. | The affected user has no recourse that week. | Principle 5 (design for failure — degradation is visible to operators, not users) | The blueprint explicitly states this preference. Operator visibility is preserved via metrics and the dead-letter queue. | Blueprint change is the trigger; not a technical decision to revisit. |
| C4 | HMAC unsubscribe tokens do not expire. An old email's unsubscribe link remains valid indefinitely. | Token revocation. | Principle 11 (security by design — ideal would be short-lived tokens) | The token can only perform `digest_opted_in = false` on the correct user — a low-risk action. Token expiry would require a storage table (complexity not justified). | Revisit if the unsubscribe action gains higher-privilege effects. |

---

## 13. Open Risks & Callouts

1. **Timezone edge: DST transitions.** If a user's timezone observes DST and the transition falls on a Sunday night, the 8:00 AM Monday delivery time may shift by an hour. The blueprint acknowledges this ("a small shift in send time is acceptable"), but the implementation must use an IANA-aware time library (e.g. ActiveSupport::TimeZone) rather than raw UTC offset arithmetic. Risk: if timezone stored as a fixed offset (`+05:30`) instead of IANA name (`Asia/Kolkata`), DST arithmetic is wrong.

2. **Ledger retention and correctness.** If `digest_sends` rows are pruned too aggressively (e.g. after 30 days), the idempotency guard fails for late-arriving duplicate jobs from weeks ago. The 90-day retention assumption (§4) should be reviewed; rows are small and the table will not grow unboundedly.

3. **`digest_week_start` normalization.** All code that writes or queries `digest_week_start` must use the same normalization (UTC date of Monday 00:00). A mismatch between the coordinator (which computes the window in local time) and the ledger (which stores UTC) would break idempotency. This normalization must be centralized in a single helper, not duplicated.

4. **Opt-in default at first migration.** If `digest_opted_in` is deployed as `DEFAULT true`, all existing users will receive the first digest email. Depending on user count and relationship to the product, this may need a communication strategy (e.g. an in-app banner before launch). Flag for the product team.

5. **SendGrid template grammar.** The design uses SendGrid's transactional email API. The specific template ID, substitution variable names, click-tracking configuration, and unsubscribe header requirements (CAN-SPAM/GDPR compliance headers) carry external-system grammar that should be captured in a probe-tested skill or a dedicated integration spec, not inline here.

6. **GDPR / CAN-SPAM compliance.** The unsubscribe link satisfies the one-click unsubscribe requirement. However, the design does not address: physical mailing address in the footer, List-Unsubscribe headers in the SMTP envelope, or GDPR data-subject deletion cascade. These should be reviewed with a compliance lens before launch.

---

## 14. Out of Scope

As stated in the blueprint, plus the following design-level items:

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering of digest content.
- A user-facing "manage notification preferences" settings UI (the unsubscribe link is the only user-facing entry point in this design).
- Re-subscribing after unsubscribing (requires an account settings UI, which is not designed here).
- Digest content internationalization / localization (subject line, body text).
- A/B testing digest subject lines or layouts.
- SendGrid template grammar specification (see §13, risk 5 — follow-up skill).
- Digest delivery for multi-workspace users receiving cross-workspace aggregates.
- Analytics on email open rates or click-through rates (requires SendGrid webhook handling, not designed here).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Assumed (A1) | §6 — background only; 60-min delivery window acceptable |
| A2 Throughput & scale | Resolved | §6 — estimated ≤50K users; linear scaling; read-replica as first lever |
| A3 Concurrency & consistency | Resolved | §3 D2, §7 — unique constraint idempotency; Sidekiq parallel workers safe |
| A4 Availability & reliability | Resolved | §3 D3, §7 — retry cap, drop-on-exhaust, DLQ |
| A5 Data integrity & durability | Resolved | §3 D2, §4 — unique constraint, ledger table, additive migrations |
| A6 Caching & freshness | Resolved | §3 D5, §6 — no cache; live query at send time; deliberate choice |
| A7 Cost | Assumed (A3) | §5 — 1 SendGrid call/user/week; ceiling = user count; no runaway risk at scale |
| A8 Security & privacy | Resolved | §3 D4, §8 — HMAC tokens, permission-scoped query, PII minimization |
| A9 Observability | Resolved | §9 — metrics, logs, three alerts, key health signal defined |
| A10 Maintainability & simplicity | Resolved | §3 D1, §2 — two jobs + three services; fits Sidekiq pattern; no novel shapes |
| A11 Testability | Resolved | §5, §3 D5 — injectable MailClient; pure DigestEmailBuilder; deterministic seams |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, reversibility |
| A13 Backward compatibility | Resolved | §4 — additive-only migrations; no existing API contracts changed |
| A14 Accessibility & device/env | N/A | Feature is email-only. Email HTML should follow basic accessibility conventions (alt text, sufficient contrast) — noted as an implementation concern, not an architecture decision. No SPA routes introduced. |
| B1 Placement / module taxonomy | Resolved | §2 — two Sidekiq jobs, two service objects, one controller action; no new modules |
| B2 Data model & persistence | Resolved | §4 — three schema changes; migration shape and invariants specified |
| B3 API surface & schemas | Resolved | §2 — one new HTTP endpoint (`GET /digest/unsubscribe`); no JSON API routes |
| B4 Async / background work | Resolved | §3 D1, §6, §7 — coordinator + per-user Sidekiq jobs; idempotent; retry policy |
| B5 External services & contracts | Resolved | §5 — SendGrid table; HMAC auth; failure modes; mock strategy; follow-up noted |
| B6 Frontend integration | N/A | No frontend SPA changes. Unsubscribe is server-rendered HTML. Email content is self-contained. |
| B7 Feature flags & rollout | Resolved | §10 — `weekly_digest_enabled` flag; default false; kill-switch documented |
| B8 Error handling | Resolved | §7 — per-failure-mode handling at each layer; DLQ; metrics; no silent swallowing |

---

## Appendix A: Captured Inputs

> This design was produced autonomously (no interactive interview). The questions below represent the genuine decision forks that would have been put to the user in a live P3 interview. Each records the recommendation made and the autonomous resolution, so a future reader can reconstruct why the design is what it is.

---

### Topic 1: Scheduling architecture — single batch vs. per-timezone coordinator

- **Question:** The blueprint requires delivery at 8:00 AM per user timezone. Should we use (a) a single Monday batch job that processes all users at once, (b) 24+ cron entries (one per UTC offset), or (c) a single hourly coordinator that buckets users by timezone?
- **Recommendation given:** Option (c) — hourly coordinator. Keeps cron configuration minimal, honors per-user timezone correctly, and isolates per-user work for retry safety.
- **Autonomous resolution:** Option (c) chosen. See D1.
- **Notes:** The coordinator's hourly granularity introduces up to 60 minutes of delivery drift from the target 8:00 AM. This is the deliberate compromise C1.

---

### Topic 2: Idempotency mechanism — database ledger vs. Redis vs. Sidekiq-unique

- **Question:** The blueprint says a user must receive at most one digest per week even if the job is triggered twice. What is the idempotency guard?
- **Recommendation given:** A `digest_sends` ledger table with a `UNIQUE(user_id, digest_week_start)` constraint. More durable than Redis; more reliable than Sidekiq-unique plugins alone.
- **Autonomous resolution:** Ledger table chosen. See D2.
- **Notes:** Sidekiq-unique is noted as a complementary (not substitute) guard at the coordinator level to prevent duplicate child-job enqueues.

---

### Topic 3: Retry policy — unlimited retries vs. time-bounded drop

- **Question:** The blueprint says a failed send should be retried but, if retries fail, dropped for the week rather than delivered late. What is the concrete retry budget?
- **Recommendation given:** 3 retries with exponential backoff, expected to exhaust within ~2 hours. A time-based cutoff (e.g. drop if past noon Monday local time) is more precise but adds complexity.
- **Autonomous resolution:** 3-retry cap assumed. Time-based cutoff noted as a desirable enhancement (A7). Product should confirm the latest acceptable send time.
- **Notes:** This directly implements the blueprint's "late is worse than skipped" principle.

---

### Topic 4: Unsubscribe token design — HMAC vs. stored UUID vs. JWT

- **Question:** The blueprint requires the unsubscribe link to be scoped to the issuing account and not guessable. What token mechanism?
- **Recommendation given:** HMAC-SHA256 signed token (no storage table needed; satisfies security requirements; reversible).
- **Autonomous resolution:** HMAC chosen. See D4. No `digest_unsubscribe_tokens` table required.
- **Notes:** The token does not expire. This is compromise C4 — acceptable because the only action it can perform is opting the correct user out.

---

### Topic 5: Activity query — live vs. pre-aggregated

- **Question:** Should digest content be queried live at send time, or pre-aggregated into a summary table on each activity event?
- **Recommendation given:** Live query at send time. Simpler, always permission-correct, and avoids a secondary store. At expected scale the query is fast.
- **Autonomous resolution:** Live query. See D5. Compromise C2.
- **Notes:** Read-replica routing is the first lever if query latency becomes a problem.

---

### Topic 6: Opt-in default — existing users

- **Question:** When the `digest_opted_in` column is added, should existing users be opted in (DEFAULT true) or opted out (DEFAULT false)?
- **Recommendation given:** DEFAULT true is the standard for a new notification type, but it means all existing users receive the first digest. Product must confirm.
- **Autonomous resolution:** Assumed DEFAULT true (A2). Flagged for product confirmation.
- **Notes:** If opted-in by default, a pre-launch communication strategy is advisable (risk 4 in §13).

---

### Topic 7: Item recency signal

- **Question:** "Highlighted items chosen by recency" — should recency be `updated_at`, `created_at`, or a dedicated `last_activity_at` field?
- **Recommendation given:** `updated_at` as a safe default; the team should confirm the correct field.
- **Autonomous resolution:** Assumed `updated_at` (A9). Flagged for team confirmation.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **Autonomous resolution:** Running without a human respondent. The following items were self-identified as potential gaps and addressed in §13 (Open Risks): DST handling correctness, ledger retention policy, `digest_week_start` normalization as a single centralized helper, opt-in communication strategy, SendGrid grammar specification follow-up, and GDPR/CAN-SPAM compliance review.
