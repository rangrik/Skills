# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./weekly-digest-blueprint.md](./weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

**Note on authoritative standard:** This design is not in the appsmith-v2 / Kite repo, so `kite-arch-compass` does not apply. All decisions are grounded in the generic `design-principles.md` lens. Principles are cited by name (e.g., "Idempotency & bounded operations") rather than by Kite compass number.

---

## 1. Summary

The weekly digest is a pure background-processing feature: a scheduled Sidekiq job fans out per-user digest jobs every Monday morning, each job queries Postgres for the user's activity window, assembles email content, and delivers through SendGrid. The single most important architectural choice is the **two-level job fan-out with an idempotency lock**: a top-level scheduler job enqueues one `DigestEmailJob` per eligible user, and a `digest_sends` table with a `(user_id, week_start_date)` unique constraint guarantees at-most-one delivery per user per week regardless of how many times the scheduler fires. This makes the entire pipeline retry-safe and idempotent — the blueprint's "triggered twice" deviation scenario is handled at the data layer, not in code logic.

---

## 2. System Placement

The feature lives entirely in the backend. There is no synchronous user-facing surface; the only user-visible output is the email itself.

**Components touched:**

- **`DigestSchedulerJob` (new Sidekiq job, cron-scheduled)** — fires at 00:00 UTC Monday; queries for all users eligible to receive a digest at their respective 8 AM local times in the coming hour, enqueues individual `DigestEmailJob`s. Runs once per hour through the week to drain all timezones.
- **`DigestEmailJob` (new Sidekiq job, enqueued per user)** — assembles the digest for a single user, writes the send record, and delivers via SendGrid.
- **`DigestContentQuery` (new service object/query class)** — encapsulates the Postgres query for a user's seven-day activity window: new items, completed items, comments mentioning the user, ranked by recency, capped at ten.
- **`UnsubscribeController#digest` (new HTTP route)** — handles the one-click unsubscribe token; no authentication required beyond a valid signed token.
- **Postgres** — holds user preferences (`digest_enabled`, `timezone`), the `digest_sends` deduplication/idempotency table, and signed unsubscribe tokens (or token derivation data).
- **SendGrid** — transactional email delivery.

**Data flow:**

```
[Sidekiq cron: every hour Mon]
  → DigestSchedulerJob
      → query: users where digest_enabled=true AND next_send_at <= now()
      → for each user: enqueue DigestEmailJob(user_id, week_start_date)

[DigestEmailJob(user_id, week_start_date)]
  → INSERT digest_sends (user_id, week_start_date) — fails silently on duplicate
  → if no row inserted: skip (already sent)
  → DigestContentQuery → Postgres → activity rows
  → if zero activity: skip (no empty digest)
  → build email payload
  → SendGrid API call
  → on success: mark digest_sends.status = 'delivered'
  → on failure: Sidekiq retry (up to N times within same-day window)
```

---

## 3. Architecture Decisions

### D1. Two-level fan-out: hourly scheduler + per-user worker jobs

- **Decision:** A cron-scheduled `DigestSchedulerJob` runs hourly and enqueues individual `DigestEmailJob`s for users whose local 8 AM falls within that hour. Individual jobs are processed by the Sidekiq worker pool.
- **Why:** Users span many timezones; a single Monday-morning job at one fixed UTC time cannot deliver at 8 AM local time for all users. Hourly scanning covers the full 24-hour band of "Monday 8 AM" across all timezones. Per-user jobs ensure that one user's failure does not block another's, and Sidekiq's retry machinery applies independently to each. Upholds **Design for failure** (per-user isolation) and **Idempotency & bounded operations** (each job is bounded to one user).
- **Alternatives considered:**
  - *Single job at a fixed UTC time for all users:* Simple but violates the blueprint requirement ("8:00 AM in each user's configured timezone"). Rejected.
  - *One job per timezone group:* Slightly fewer enqueues but adds a grouping abstraction. No meaningful benefit over per-user jobs given Sidekiq scales horizontally. Rejected in favor of simplicity.
  - *Sidekiq-cron with one job per user registered at setup:* Operationally expensive to maintain as users join/leave. Rejected.
- **Trade-off accepted:** The scheduler does a periodic DB scan instead of event-driven scheduling. At large user counts the scan must be indexed; see §6.

### D2. `digest_sends` table as the idempotency and deduplication guard

- **Decision:** A `digest_sends` table with a `UNIQUE (user_id, week_start_date)` constraint serves as the at-most-one-per-week guarantee. Before doing any work, `DigestEmailJob` attempts an INSERT; if the row already exists (duplicate job, scheduler re-run), it exits immediately without sending.
- **Why:** The blueprint's deviation scenario ("job triggered twice") requires exactly one email per user per week regardless of re-runs or re-queues. Encoding this invariant in the database schema (a unique constraint) rather than in application logic makes the illegal state — two sends for the same user/week — unrepresentable at the storage layer. Upholds **Make illegal states unrepresentable**, **Idempotency & bounded operations**, and **Get the data model right**.
- **Alternatives considered:**
  - *Redis-based distributed lock:* Works but introduces a second store, adds a TTL management problem, and is not durable across Redis restarts. Postgres already in the stack; the unique constraint is simpler and more durable. Rejected.
  - *Application-level check-before-insert:* Race-prone (TOCTOU). Rejected.
- **Trade-off accepted:** The `digest_sends` table grows one row per user per week; needs periodic pruning (see §4).

### D3. Skip-and-drop on exhausted retries — no late delivery

- **Decision:** `DigestEmailJob` retries on SendGrid failure with exponential backoff, but the retry window is capped to the same calendar day (Monday). If all retries are exhausted, the `digest_sends` row is marked `status='failed'` and the send is dropped for that week. No attempt is made to deliver late.
- **Why:** The blueprint explicitly states: "a digest that arrives late is worse than one skipped." This is a hard product requirement; delivering on Tuesday is worse UX than silence. Upholds **Design for failure** (explicit, visible failure mode) and **Principle of least surprise** (a digest that arrives mid-week would confuse users).
- **Alternatives considered:**
  - *Retry across multiple days:* Violates the blueprint's stated preference. Rejected.
  - *Dead-letter queue for manual retry:* Adds operational complexity; the blueprint says drop it. Rejected.
- **Trade-off accepted:** A user whose email delivery repeatedly fails will miss digests silently. Monitoring (§9) must surface persistent failure rates so the team can intervene if SendGrid is consistently rejecting a subset of addresses.

### D4. Signed unsubscribe tokens — HMAC over user ID and week

- **Decision:** Unsubscribe links embed an HMAC-SHA256 token derived from `user_id + issued_week` signed with a server-side secret. The unsubscribe endpoint verifies the token, sets `digest_enabled=false` for the user, and returns a confirmation page. No session or login required.
- **Why:** The blueprint's adversarial scenario requires that an unsubscribe link "must act only on the account it was issued for and must not be guessable." A signed token satisfies both: it is bound to a specific user_id, and guessing a valid token requires knowledge of the server secret. Upholds **Security & privacy by design** and **Make illegal states unrepresentable** (an invalid token cannot unsubscribe anyone).
- **Alternatives considered:**
  - *Random opaque token stored in DB:* Equally secure, but requires a new table or column and a lookup. HMAC is stateless and needs no additional storage. Accepted.
  - *User-ID in plaintext:* Directly violates the adversarial scenario. Rejected.
  - *Require login before unsubscribing:* Degrades UX; one-click is the blueprint requirement. Rejected.
- **Trade-off accepted:** HMAC tokens are not revocable (no per-token DB record to delete). Once a link is issued, it remains valid until the signing secret rotates. Mitigation: token includes the issued week, so old links from past digests still work but are bounded in scope (they only ever unsubscribe the correct user). The unsubscribe action itself is idempotent.

### D5. Permission-scoped content query — digest includes only visible items

- **Decision:** `DigestContentQuery` applies the same row-level permission filters used elsewhere in the application when fetching activity data. Items in a deleted workspace are excluded by joining against active workspaces. The query is never a raw "all activity for this user_id."
- **Why:** The blueprint's adversarial scenario states: "Digest content for a user must only include items that user is allowed to see." Enforcing this in the query (not in post-processing) ensures the constraint cannot be bypassed by code paths that skip a post-process filter. Upholds **Security & privacy by design** and **High cohesion, loose coupling** (permission logic stays in the data layer).
- **Alternatives considered:**
  - *Fetch all items, filter in Ruby:* Races with permission changes that happen between fetch and filter, and loads unauthorized data into memory. Rejected.
- **Trade-off accepted:** The query is more complex. Joins against workspace membership and item visibility tables are required; query performance must be validated (see §6).

### D6. No caching of digest content

- **Decision:** Digest content is assembled fresh from Postgres at job execution time. No intermediate cache layer is used.
- **Why:** Each digest is unique to one user, generated at most once per week, and consumed once (at send time). Caching provides no reuse benefit. Adding a cache would introduce a staleness problem (user permissions or item content could change between cache-fill and send) and an unnecessary Redis dependency. Upholds **Simplicity first / YAGNI** and **Cache invalidation is a design decision** (the answer here is: don't cache, because there is no reuse to justify it).
- **Alternatives considered:**
  - *Pre-compute and cache digests on Friday for Monday delivery:* Adds complexity, increases staleness risk (items completed over the weekend would be missed), and is inconsistent with the blueprint's "rolling seven days ending Monday 00:00." Rejected.
- **Trade-off accepted:** Each job hits Postgres; query performance must be acceptable at scale (see §6).

### D7. UTC-based scheduler with timezone-aware user filtering

- **Decision:** The `DigestSchedulerJob` cron runs hourly at :00 UTC. Each run queries for users where `((8:00 AM in user.timezone) BETWEEN now() AND now() + 1 hour)`. User timezone is stored as an IANA timezone string; a missing/invalid timezone defaults to UTC (matching the blueprint's "unset timezone → 8:00 AM UTC" rule).
- **Why:** Sidekiq cron operates in UTC. The only correct way to send at 8 AM local time is to convert the target time to UTC at query time and select users in the current window. Upholds **Principle of least surprise** and **Get the data model right** (storing timezone as IANA string is the standard, portable format).
- **Alternatives considered:**
  - *Precompute and store `next_send_at` (UTC) per user:* More efficient query (indexed timestamp scan vs computed filter), but requires updating this column on every timezone change and on every weekly send. Adds write complexity. For the expected user volume this is an optimization worth revisiting if the hourly scan becomes slow (see §6). Noted as a future optimization.
  - *Store timezone as UTC offset integer:* Does not handle DST correctly. Rejected.
- **Trade-off accepted:** The hourly computed timezone filter may be slower than an indexed `next_send_at` column at very high user counts. Acceptable for initial launch; an index on `(digest_enabled, timezone)` mitigates this (§6).

---

## 4. Data Model & Persistence

### New or modified tables

#### `users` table — new columns

| Column | Type | Notes |
|---|---|---|
| `digest_enabled` | `boolean NOT NULL DEFAULT true` | User preference; set to `false` on unsubscribe |
| `timezone` | `varchar(64) DEFAULT NULL` | IANA timezone string (e.g., `"America/New_York"`). NULL treated as UTC in all digest logic. |

Migration: additive-only columns with defaults; no backfill required. Existing users default to `digest_enabled=true` and UTC.

#### `digest_sends` table — new table

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint PK` | |
| `user_id` | `bigint NOT NULL REFERENCES users(id)` | |
| `week_start_date` | `date NOT NULL` | Monday date of the digest week (local date in user's timezone, normalized at enqueue time) |
| `status` | `varchar(16) NOT NULL DEFAULT 'pending'` | Enum: `pending`, `skipped_no_activity`, `skipped_disabled`, `delivered`, `failed` |
| `attempted_at` | `timestamptz` | When the job first attempted delivery |
| `delivered_at` | `timestamptz` | When SendGrid accepted the message |
| `sendgrid_message_id` | `varchar(255)` | SendGrid's message ID for tracing |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `updated_at` | `timestamptz NOT NULL DEFAULT now()` | |

**Unique constraint:** `UNIQUE (user_id, week_start_date)` — the idempotency guard.

**Indexes:**
- `(user_id, week_start_date)` — covered by the unique constraint.
- `(status, week_start_date)` — for monitoring queries (how many delivered/failed this week).

**Retention:** Rows older than 90 days can be pruned. Digest send history is operational metadata, not business-critical audit data. A periodic background job or a Postgres partitioning strategy can handle pruning.

#### No new tables for activity data

Digest content is queried from existing workspace activity tables (items, comments, etc.). No denormalized activity snapshot is created.

### Invariants enforced at the schema level

- `UNIQUE (user_id, week_start_date)` on `digest_sends` — at-most-one send per user per week.
- `digest_enabled` has a `NOT NULL DEFAULT true` — no nullable boolean ambiguity.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid** | Transactional email delivery | API key stored in environment variable / secrets manager; passed in `Authorization: Bearer` header | SendGrid's free tier: 100 emails/day; paid tiers scale to millions. Cost is per-email (fractions of a cent at scale). Set a monthly send ceiling in the SendGrid dashboard to prevent runaway cost. | HTTP 4xx on bad address or template: mark send as `failed`, do not retry (permanent failure). HTTP 5xx or network timeout: Sidekiq retry with backoff, capped to same-day window per D3. Rate-limit (429): Sidekiq retry with backoff. | Stub the SendGrid HTTP client in unit tests using a test-double/mock. Integration tests use SendGrid's sandbox mode (emails accepted but not delivered). Never call live SendGrid in CI. |

**Follow-up:** SendGrid's email template DSL (dynamic template variables, Handlebars syntax, unsubscribe header injection) carries a grammar that is best validated with probe tests against the live sandbox rather than encoded inline in this document. Record this as a follow-up task.

---

## 6. Performance, Scale & Caching

### Latency targets

This is a background feature; there is no synchronous user-facing latency. The relevant throughput concern is: all users in a given timezone band must have their digest job enqueued (and ideally sent) within the 60-minute window that constitutes "their Monday 8 AM hour."

### Expected load

- **Initial scale:** Assume tens of thousands of `digest_enabled` users. Worst-case fan-out per hourly scheduler run: a few thousand users in peak timezone bands (UTC, ET, PT). This is well within Sidekiq's throughput envelope.
- **Growth:** At millions of users, the hourly scheduler scan becomes the bottleneck. Mitigation path: add a `next_send_at timestamptz` column to `users`, indexed, and update it on each send and on timezone changes. This converts the hourly computed-filter query to a simple indexed range scan. This is the planned optimization trigger (see §12, C2).
- **Digest content query:** One Postgres query per user per week. At 100k users, that is ~100k queries per week, spread across a 24-hour window. Load is negligible in any reasonable database pool configuration.

### Caching

No caching is used for digest content (D6). The `digest_sends` unique constraint acts as a write-through idempotency layer, not a read cache.

### Bounded operations

- Highlighted items are capped at ten in the query (`LIMIT 10`), matching the blueprint's stated cap. The "+N more" count is derived from a separate `COUNT(*)` query with the same filters but without the LIMIT, or from a `LIMIT 11` query where an 11th result signals overflow.
- The `week_start_date` filter bounds the activity query to seven days; no unbounded table scan.
- The scheduler query is bounded by `digest_enabled = true` and the timezone window.

### Concurrency

No two jobs race on the same user: the `UNIQUE (user_id, week_start_date)` constraint ensures the second concurrent job fails to insert and exits immediately. No application-level lock is needed.

---

## 7. Reliability & Failure Handling

### SendGrid failure (blueprint deviation: "email provider is down or rejects a message")

- **Transient failure (5xx, network timeout, 429):** Sidekiq retries with exponential backoff. The retry schedule is configured so that all retries are exhausted within the same Monday. If the last retry fails, `digest_sends.status` is set to `'failed'` and the week is dropped (D3).
- **Permanent failure (4xx: bad address, invalid template, account suspended):** Sidekiq does not retry; the job marks `status='failed'` immediately and raises an alert (§9).
- **User sees:** Nothing. A skipped digest is consistent with the blueprint's explicit preference.

### Duplicate scheduler trigger (blueprint deviation: "weekly job triggered twice")

- The `UNIQUE (user_id, week_start_date)` constraint absorbs duplicate triggers transparently (D2). The second job attempt inserts nothing, detects the no-op, and exits.

### Late job start (blueprint deviation: "job delayed and starts late")

- `week_start_date` is computed from the user's local time at job enqueue time, not job execution time. The content query uses `Monday 00:00 local time` as the window end, derived from the same `week_start_date`. A late start shifts send time but does not change the seven-day content window.

### New user mid-week (blueprint edge case)

- `DigestContentQuery` uses `MAX(user.created_at, week_start_date_utc)` as the lower bound of the activity window. This naturally covers only the days since the user joined. If no activity exists in that partial window, no email is sent.

### Deleted workspace (blueprint edge case)

- `DigestContentQuery` joins against the workspaces table and filters `WHERE workspace.deleted_at IS NULL`. Items from deleted workspaces are excluded.

### Timezone not set / invalid (blueprint edge case)

- `DigestSchedulerJob` treats `NULL` or unrecognized timezone as UTC. The user is enqueued in the UTC 8 AM window.

### Timezone changed on Sunday night (blueprint edge case)

- The scheduler reads the user's current timezone at enqueue time (not at registration). If the user changes timezone on Sunday, the Monday scheduler run picks up the new value. A small shift in send time is acceptable per the blueprint.

### Unsubscribe idempotency

- `UPDATE users SET digest_enabled = false` is idempotent. Clicking an unsubscribe link twice produces the same end state.

---

## 8. Security & Privacy

### Unsubscribe token integrity (blueprint adversarial scenario)

- Tokens are HMAC-SHA256 over `"#{user_id}:#{issued_week}"` signed with a server-managed secret (D4).
- The unsubscribe endpoint validates the signature before acting. An invalid or tampered token returns 400 and takes no action.
- Tokens are scoped to a user_id; an attacker cannot use one user's token to unsubscribe another.
- Tokens are included in the email as a URL query parameter; they are not stored in the database.

### Content authorization (blueprint adversarial scenario)

- `DigestContentQuery` enforces workspace membership and item visibility at the query level (D5). A user can only receive content from workspaces they are a member of and items they have read access to.

### Secret handling

- SendGrid API key is stored in the environment / secrets manager, never in source code or committed configuration.
- The HMAC signing secret is a separate dedicated secret, stored the same way.

### PII exposure

- Email addresses are passed to SendGrid; they are PII. SendGrid is a trusted processor; no additional masking is required in transit (TLS).
- Digest content (item titles, comment snippets) may be PII depending on workspace data. This is inherent to the feature; no additional treatment is required beyond the access controls in D5.

### Input validation at trust boundaries

- The `week_start_date` and `user_id` embedded in job arguments are internal system values, not user-supplied; no additional sanitization needed.
- The unsubscribe token URL parameter is the only user-supplied input to a sensitive action; it is validated by HMAC signature check before any state mutation.

### Abuse vectors

- Unsubscribe token replay: acceptable — replaying a token is idempotent and the attacker must already know the correct token.
- Bulk unsubscribe via enumeration: not possible — tokens are HMAC-signed and not guessable.
- Job queue flooding: the scheduler produces a bounded number of jobs (one per eligible user per week); no external input drives job creation.

---

## 9. Observability

### Key metrics

| Metric | What it indicates |
|---|---|
| `digest.scheduler.users_enqueued` (weekly counter) | How many users were queued for a digest |
| `digest.jobs.attempted` (weekly counter) | How many individual send jobs ran |
| `digest.jobs.delivered` (weekly counter) | Successful deliveries |
| `digest.jobs.skipped_no_activity` (weekly counter) | Users with zero activity — expected to be a large fraction |
| `digest.jobs.failed` (weekly counter) | Delivery failures — the primary health signal |
| `digest.job.duration_ms` (histogram) | Per-job latency — catches slow queries |
| `digest.content_query.duration_ms` (histogram) | Postgres query latency |

### Alerts

- **Alert:** `digest.jobs.failed / digest.jobs.attempted > 5%` in a rolling Monday window → page on-call. Indicates SendGrid issue or systematic configuration problem.
- **Alert:** `digest.scheduler.users_enqueued == 0` on a Monday → page on-call. Indicates the scheduler did not run (cron misconfiguration or process failure).

### Logs

- Each `DigestEmailJob` logs: `user_id`, `week_start_date`, outcome (`delivered` / `skipped_no_activity` / `skipped_duplicate` / `failed`), and SendGrid message ID on success.
- Errors include the SendGrid HTTP status code and response body for diagnosis.

### The single health signal

**`digest.jobs.failed / digest.jobs.attempted` on each Monday.** A healthy week looks like: a large `skipped_no_activity` fraction, a small `failed` fraction (ideally zero). If the failed fraction spikes, the feature is broken. If `users_enqueued` is zero, the scheduler did not fire.

### Traces

- Wrap each `DigestEmailJob` execution in a trace span, with child spans for the content query and the SendGrid HTTP call. This makes it possible to identify whether latency is in the DB or in the external call.

---

## 10. Rollout & Operability

### Feature flag

A `weekly_digest_enabled` feature flag gates the entire feature:
- **Default state:** off (closed). No digests are sent until the flag is explicitly enabled.
- **Staged rollout:** Enable for internal users first; expand to a percentage of production users; then enable globally.
- **Fail-closed is correct here:** If the flag evaluation fails, no digests are sent. A missed digest is acceptable; a flood of unexpected emails is not.

### Migration order

1. Deploy migration: add `digest_enabled` and `timezone` columns to `users` with defaults.
2. Deploy migration: create `digest_sends` table.
3. Deploy application code (flag off — no jobs run).
4. Enable flag for internal cohort; monitor metrics.
5. Gradual rollout to production users.

All migrations are additive; no backfill is required. Rollback removes the flag; existing `digest_sends` rows are benign.

### Reversibility

- Turning the flag off immediately stops all new scheduler runs.
- The `digest_sends` table retains history; it can be dropped safely if the feature is abandoned.
- The two new `users` columns (`digest_enabled`, `timezone`) are innocuous if the feature is removed; they can be dropped in a later migration.

### Operational runbook items

- To resend a digest for a user: delete the `digest_sends` row for `(user_id, week_start_date)` and re-enqueue the job.
- To check if a user received a digest: query `digest_sends` by `user_id` and `week_start_date`.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Sidekiq is already in use for background processing | Stated in the task context as the background job stack | No |
| A2 | Postgres is the application database | Stated in the task context | No |
| A3 | SendGrid is the email delivery provider | Stated in the task context | No |
| A4 | A Sidekiq cron / scheduled-job mechanism (e.g., `sidekiq-cron` or `sidekiq-scheduler` gem) is available | Standard Sidekiq extension; common in stacks using Sidekiq | Yes — confirm the specific cron gem in use |
| A5 | User timezone is already stored somewhere (or can be added) and is an IANA string | Common convention; UTC default is a safe fallback | Yes — confirm existing timezone field name if it exists |
| A6 | Workspace activity data (items, completions, comments) lives in Postgres and is queryable with filters on user membership and date | Implied by the feature's existence; the query structure depends on the actual schema | Yes — the exact activity schema must be reviewed before query implementation |
| A7 | The "items a user is allowed to see" permission model is already enforced at the Postgres query level in other feature queries | Standard for row-level security; assumed from the adversarial requirement | Yes — confirm with a code review of existing permission-scoped queries |
| A8 | Email HTML rendering (templates) will use SendGrid's dynamic template system | Common pattern; avoids server-side HTML email rendering complexity | Yes — confirm template tooling preference |
| A9 | There is no existing weekly digest feature or partial implementation to integrate with | No evidence in the blueprint of prior art | Yes — confirm no existing partial implementation |
| A10 | Digest send history older than 90 days has no compliance or audit requirement | Blueprint does not mention retention requirements; 90 days covers operational lookback | Yes — confirm with data/legal team if applicable |
| A11 | User count is in the tens-of-thousands range at launch | Reasonable for a product with workspace activity features; shapes scale decisions | Yes — confirm order-of-magnitude estimate |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Skip-and-drop on retry exhaustion (D3) | Users with persistent SendGrid failures silently miss digests | Design for failure — ideal system would retry across the week | The blueprint explicitly requires this: "a digest that arrives late is worse than one skipped." This is a product decision, not an engineering shortcut. | If blueprint changes to allow late delivery |
| C2 | Hourly computed timezone filter instead of indexed `next_send_at` column | Query performance degrades at very high user counts (millions) | Simplicity first — the simpler approach is taken first | At tens-of-thousands of users the computed filter is fast enough. Adding `next_send_at` adds write complexity (must be updated on every send and timezone change). | User count reaches ~500k or the hourly scheduler scan exceeds 1s |
| C3 | HMAC token is not stored; cannot be individually revoked before expiry | A compromised unsubscribe link can be used until a new digest is issued (at most one week) | Reversible decisions — a stored token is more revocable | The blast radius is low: the worst case is an unsubscribe for the correct user. The action is harmless and idempotent. Token rotation (changing the signing secret) revokes all outstanding tokens at once if needed. | If the threat model expands (e.g., tokens used for more sensitive actions) |
| C4 | No pre-computation of digest content | If many users share similar workspaces, identical sub-queries run N times | Cost as a first-class constraint — shared caching could reduce DB load | The per-user query is fast (seven-day window, indexed). Workspace-level pre-aggregation adds significant complexity for unclear benefit at current scale. | If DB query load from digest jobs becomes measurable during Monday windows |

---

## 13. Open Risks & Callouts

1. **Activity schema unknown.** The `DigestContentQuery` design assumes Postgres tables for items, completions, and comments with user-membership joins. The exact schema must be reviewed before implementation. If the activity model is more complex (e.g., multiple item types, polymorphic associations), the query may need to be more involved than assumed.

2. **SendGrid template tooling decision.** The specific template mechanism (dynamic templates, transactional templates, server-rendered HTML) affects how the email is assembled and tested. This should be aligned with any existing email-sending patterns in the codebase before implementation.

3. **Timezone column existence.** If `users.timezone` does not already exist, adding it requires deciding who is responsible for populating it (user settings UI, onboarding flow, etc.). That UI surface is out of scope for this design but must exist for the feature to work correctly.

4. **Large workspace edge case.** The blueprint caps highlighted items at ten. However, the `COUNT(*)` for "+N more" requires a second query or a careful `LIMIT 11` approach. The exact query strategy should be finalized during implementation to avoid N+1 patterns.

5. **SendGrid rate limits at Monday peak.** If the user base grows rapidly, the Monday morning spike (all users in a given timezone band sending within one hour) could approach SendGrid rate limits. The SendGrid account tier and rate limit ceiling should be confirmed before full rollout.

6. **Cron job reliability.** If the Sidekiq process is not running on Monday morning (e.g., deployment window), users in that timezone band miss their digest. A monitoring alert on `digest.scheduler.users_enqueued == 0` mitigates detection, but missed sends cannot be retroactively recovered without manual intervention (see §9).

---

## 14. Out of Scope

Per the blueprint and this design's scope:

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering of the digest content.
- A user-facing settings UI for toggling digest preferences (required for the feature to be fully operable, but UI design is outside the system design for the backend pipeline).
- Email deliverability optimization (DKIM, SPF, DMARC, IP warming) — these are operational concerns for SendGrid account setup, not design decisions.
- Bounce and spam-complaint handling from SendGrid webhooks — a follow-up feature; for now, failed sends are observable via metrics.
- A/B testing of email content or send times.
- Multi-language / localized email content.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Assumed (A1–A3, see §6) | §6 — background feature; no user-facing latency target. Throughput target: all users in a timezone band processed within 60-minute window. |
| A2 Throughput & scale | Resolved | §6, D1, D7, C2 — hourly fan-out; per-user jobs; scale bottleneck identified and mitigation path noted. |
| A3 Concurrency & consistency | Resolved | D2, §6 — `UNIQUE (user_id, week_start_date)` handles duplicate jobs; no application lock needed. |
| A4 Availability & reliability | Resolved | D3, §7 — retry with same-day window; skip-and-drop on exhaustion; explicit failure modes for each blueprint deviation. |
| A5 Data integrity & durability | Resolved | D2, §4 — schema constraints enforce at-most-one send; send history retained 90 days; activity data is in existing tables (not duplicated). |
| A6 Caching & freshness | Resolved | D6 — explicitly no cache; rationale documented. |
| A7 Cost | Resolved | §5, §6 — SendGrid per-email cost acknowledged; monthly ceiling in SendGrid dashboard; no runaway vector identified. |
| A8 Security & privacy | Resolved | D4, D5, §8 — HMAC unsubscribe tokens; permission-scoped content query; secret handling; PII handling. |
| A9 Observability | Resolved | §9 — metrics, alerts, logs, traces, and the primary health signal defined. |
| A10 Maintainability & simplicity | Resolved | D1, D6, D7 — two-level job fan-out fits Sidekiq patterns; no novel shapes introduced; simplest viable approach taken first. |
| A11 Testability | Resolved | §5 — SendGrid mocked in unit tests (test double); SendGrid sandbox mode for integration tests; idempotency seam (unique constraint) is deterministic and testable. |
| A12 Deployability & rollout | Resolved | §10 — feature flag (`weekly_digest_enabled`); additive-only migrations; staged rollout; reversibility documented. |
| A13 Backward compatibility | Resolved (N/A for most) | §4, §10 — additive columns with defaults; no existing contracts changed; no prior digest feature to be compatible with (A9). |
| A14 Accessibility & device/env | Assumed (A8) | Email HTML rendering accessibility (screen reader, plain-text fallback) depends on template design. Not a system-design decision in this document; flagged as a follow-up for the template implementation. |
| B1 Placement / module taxonomy | Resolved | §2 — `DigestSchedulerJob`, `DigestEmailJob`, `DigestContentQuery`, `UnsubscribeController#digest`; all new; described in §2. |
| B2 Data model & persistence | Resolved | §4 — two new columns on `users`; new `digest_sends` table; schema, constraints, indexes, and retention documented. |
| B3 API surface & schemas | Resolved | §2, §8 — one new HTTP route (`UnsubscribeController#digest`); no new API endpoints for the email pipeline itself (background only). |
| B4 Async / background work | Resolved | D1, D2, D3, §7 — two-level Sidekiq job fan-out; idempotency at DB layer; retry policy with same-day cap; skip on duplicate. |
| B5 External services & contracts | Resolved | §5 — SendGrid: purpose, auth, rate limits, cost, failure modes, test strategy; follow-up on template grammar noted. |
| B6 Frontend integration | N/A | This feature has no frontend component. The only user-facing surface is the email itself and the unsubscribe landing page (a simple server-rendered confirmation). No SPA state changes. |
| B7 Feature flags & rollout | Resolved | §10 — `weekly_digest_enabled` flag; default off; staged rollout; fail-closed behavior specified. |
| B8 Error handling | Resolved | D3, §7 — per-layer error handling: DB (unique constraint), job (Sidekiq retry), external call (4xx vs 5xx distinction); failure visibility via metrics and logs. |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Every Monday at 8:00 AM local time, user receives a digest | Behavior | D1, D7, §2 | Hourly scheduler enqueues per-timezone-band; 8 AM local computed via IANA timezone. |
| Digest covers rolling seven days ending Monday 00:00 local time | Behavior | §4 (DigestContentQuery), §7 | `week_start_date` is the Monday local date; query lower bound is 7 days prior; upper bound is Monday 00:00. |
| Email content: headline summary, counts (new/completed/commented), up to ten highlighted items with links | Behavior | §2 (DigestContentQuery), §6 | Query fetches activity counts and top-10 items by recency (LIMIT 10); "+N more" computed via count or LIMIT 11. |
| Clicking any item link opens that item in the app | Behavior | §5, A8 | Links are generated server-side using item IDs; URL structure is an application concern, not a system-design concern. Noted as follow-up for template implementation. |
| One-click "unsubscribe from digests" link in the footer | Behavior | D4, §8 | HMAC-signed token in URL; handled by `UnsubscribeController#digest`. |
| Digest covers rolling seven days (not calendar week) | Behavior | §4, §7 | `week_start_date` minus 7 days = query lower bound. |
| Send time is 8:00 AM in each user's configured timezone | Behavior | D1, D7 | Hourly scheduler selects users whose 8 AM local time falls in the current UTC hour. |
| Users in different timezones receive email at different absolute times | Behavior | D1, D7 | Fan-out by timezone band across 24 hourly scheduler runs. |
| A user with digests turned off receives nothing | Behavior | §2 (scheduler query), §4 | Scheduler filters `WHERE digest_enabled = true`. |
| If no relevant activity in the past week, no email is sent | Behavior | §2 (DigestEmailJob), §7 | Job exits before send if `DigestContentQuery` returns zero activity rows; `digest_sends.status = 'skipped_no_activity'`. |
| Each user receives at most one digest email per week | Behavior | D2, §4 | `UNIQUE (user_id, week_start_date)` constraint; INSERT fails on duplicate; job exits without sending. |
| Highlighted items chosen by recency, capped at ten; "+N more" if more | Behavior | §6 | `ORDER BY created_at DESC LIMIT 10`; count of overflow computed separately. |
| Unsubscribing is immediate and takes effect before the next Monday | Behavior | D4, §7 | `UnsubscribeController` sets `digest_enabled=false` immediately; scheduler reads this column fresh each run. |
| Brand-new user joined mid-week: digest covers only days since joining | Edge case | §7 | `DigestContentQuery` uses `MAX(user.created_at, week_start_monday_utc)` as activity window lower bound. |
| User with activity but workspace deleted: no email | Edge case | D5, §7 | Query joins against `workspaces WHERE deleted_at IS NULL`; deleted-workspace items are excluded. |
| User timezone not set: digest defaults to 8:00 AM UTC | Edge case | D7, §7 | NULL timezone treated as UTC in scheduler filter and content query. |
| User changes timezone on Sunday night: next digest uses new timezone | Edge case | D7, §7 | Scheduler reads current timezone at enqueue time; timezone change is picked up on the next Monday run. |
| Email provider down or rejects at send time: retry; if still fails, drop for the week | Deviation | D3, §7 | Sidekiq retry with backoff capped to same-day window; exhaustion → `status='failed'`; no late delivery. |
| Weekly job triggered twice: user still receives only one digest | Deviation | D2, §4 | `UNIQUE (user_id, week_start_date)` absorbs duplicate triggers; second INSERT is a no-op. |
| Job delayed and starts late: correct seven-day window, send time may slip | Deviation | §7, D7 | `week_start_date` is set at enqueue from the Monday date; content query is time-bounded by the date, not job execution time. |
| Unsubscribe link must act only on the account it was issued for and must not be guessable | Adversarial | D4, §8 | HMAC-SHA256 token bound to `user_id`; signature validation required before any mutation. |
| Digest content must only include items the user is allowed to see | Adversarial | D5, §8 | Permission-scoped query enforced at DB level, not post-process. |

---

## Appendix A: Captured Inputs

*This design was produced autonomously — no human interview was conducted. The following section records how each decision fork was resolved and the reasoning behind each autonomous choice. The skill's P3 interview step was replaced by reasoned resolution from the blueprint and the generic design-principles lens. All assumptions and autonomous decisions are recorded here so a future reader can reconstruct why the design is what it is.*

---

### Scheduling strategy (D1, D7)

- **Question:** How should the scheduler handle users in different timezones so each receives the email at 8 AM local time?
- **Recommendation given:** Hourly cron that filters users whose 8 AM local time falls in the current UTC hour. Upholds the blueprint's timezone requirement without requiring per-user scheduled jobs.
- **Autonomous decision:** Hourly scheduler adopted. Simpler than per-timezone-group jobs; Sidekiq handles the fan-out load well.
- **Notes:** The alternative (a `next_send_at` indexed column) was identified as the planned optimization path at high user counts (C2). Not adopted at launch because it adds write complexity for no current benefit.

### Idempotency / at-most-one-send guarantee (D2)

- **Question:** How to guarantee each user receives at most one digest per week even if the scheduler fires multiple times?
- **Recommendation given:** `UNIQUE (user_id, week_start_date)` constraint on `digest_sends`, with INSERT-before-send in the job. Database constraint makes the illegal state unrepresentable.
- **Autonomous decision:** Adopted. Redis lock was considered and rejected (see D2 alternatives).
- **Notes:** The blueprint's "triggered twice" deviation scenario was the direct driver of this decision.

### Retry policy and late-delivery behavior (D3)

- **Question:** How many retries for SendGrid failures, and what happens when retries are exhausted — delay to afternoon, or drop?
- **Recommendation given:** Drop for the week; the blueprint explicitly says "a digest that arrives late is worse than one skipped."
- **Autonomous decision:** Skip-and-drop adopted. The exact retry count and backoff schedule (e.g., 3 retries over 4 hours) is an implementation detail; the key constraint is same-day window. This was noted as C1 (accepted compromise against ideal failure handling).
- **Notes:** Monitoring (§9) is the mitigation for silent drops — operators will see the failure rate.

### Unsubscribe token design (D4)

- **Question:** How should unsubscribe links be implemented to satisfy the adversarial requirement (bound to one account, not guessable)?
- **Recommendation given:** HMAC-SHA256 signed token over `user_id + issued_week`. Stateless, no extra table, unforgeable without the server secret.
- **Autonomous decision:** HMAC adopted. Stored random token was considered and noted as equally secure but less simple. The non-revocability trade-off (C3) was documented; blast radius is low.
- **Notes:** Token includes `issued_week` to bound the token's semantic scope (an old unsubscribe link from a past week still correctly unsubscribes the correct user).

### Content permission scoping (D5)

- **Question:** How to ensure digest content only includes items the user is allowed to see?
- **Recommendation given:** Enforce at the query level, not post-process. Join against workspace membership and item visibility tables.
- **Autonomous decision:** Query-level enforcement adopted. Post-processing was rejected as race-prone and insecure.
- **Notes:** The exact permission join structure depends on the application's data model (risk item §13 item 1).

### Caching (D6)

- **Question:** Should digest content be pre-computed or cached?
- **Recommendation given:** No cache. Each digest is unique, generated once per week, consumed once. No reuse benefit; freshness risk is real.
- **Autonomous decision:** No cache adopted. Consistent with "Cache invalidation is a design decision" — the answer here is that there is nothing to cache.
- **Notes:** Pre-computation on Friday was considered and rejected (staleness, complexity, blueprint mismatch).

### P2 Map — assumptions accepted without interview

The following were classified as safe defaults and adopted without a fork:

- Sidekiq, Postgres, SendGrid are the correct stack (stated in task context).
- User timezone stored as IANA string (standard; UTC default matches blueprint).
- `digest_sends` retention at 90 days (no compliance requirement stated).
- Feature flag default off (standard for new email features; avoids unexpected sends).
- Additive-only migrations (standard practice for production databases).

### Last-call (P4)

- **Asked:** "Before writing up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** No human available. Autonomous review conducted: all blueprint behaviors, edge cases, deviation scenarios, and adversarial scenarios were walked against the design (§16). All taxonomy dimensions were accounted for (§15). Open risks were documented (§13). No silent omissions identified.
