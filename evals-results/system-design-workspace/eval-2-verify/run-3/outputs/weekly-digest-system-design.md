# System Design: Weekly Digest Email

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../../../iteration-1/eval-2-weekly-digest-email/inputs/weekly-digest-blueprint.md](../../../iteration-1/eval-2-weekly-digest-email/inputs/weekly-digest-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The weekly digest is a pure background-job feature: a Sidekiq scheduler fires once per minute (or per timezone wave), queries for users whose 8:00 AM window has arrived, assembles their digest from the past seven days of workspace activity, and delivers via SendGrid. The single most important architectural choice is the **idempotency guard** — a `digest_sends` table that records (user_id, iso_week) pairs so that re-triggers, deploy restarts, or Sidekiq duplicates never produce a duplicate email, satisfying the blueprint's hard rule that each user receives at most one digest per week. All email work is async; no synchronous request is blocked; and the unsubscribe token is a signed, user-scoped HMAC so that guessing one user's token cannot affect another.

---

## 2. System Placement

This feature is a **background-job subsystem** with no synchronous API surface visible to the product UI, except for one unsubscribe endpoint.

```
[Sidekiq cron job: DigestSchedulerJob]
       |
       | every minute (or per-timezone-bucket, see D1)
       v
[DigestSchedulerJob] — queries users whose send-window has arrived
       |
       | enqueues one job per user
       v
[DigestSendJob (per user)] — idempotency check → assemble digest → send via SendGrid
       |
       +---> [PostgreSQL: digest_sends, user_preferences, workspace_activity]
       +---> [SendGrid HTTP API]

[Unsubscribe endpoint: GET /emails/digest/unsubscribe?token=<signed>]
       |
       v
[UnsubscribesController] — validates HMAC token → sets user.digest_enabled = false
```

**Components touched:**
- New Sidekiq jobs: `DigestSchedulerJob`, `DigestSendJob`
- New DB tables: `digest_sends`, and a column on `users` (or `user_preferences`) for `digest_enabled` and `timezone`
- New controller action: `UnsubscribesController#digest`
- SendGrid integration (new or reusing existing mailer abstraction)

---

## 3. Architecture Decisions

### D1. Scheduling strategy: timezone-bucket fan-out vs. per-minute query

- **Decision:** Run `DigestSchedulerJob` as a Sidekiq-cron job every minute. Each run queries `users` for those whose `digest_send_at` time falls within the current minute's window (i.e., `timezone` maps to an 8:00 AM UTC offset that is "now"). This is a single recurring job that fans out per-user `DigestSendJob` items.
- **Why:** Upholds *Simplicity first / YAGNI* (Principle 1) — one cron entry instead of 24 timezone-bucket queues. A per-minute scheduler is the standard Sidekiq-cron pattern; a per-bucket design adds 24 cron entries and timezone-mapping logic for no concrete gain at the expected scale. Upholds *Match existing patterns* (Principle 2) — per-minute sweep is conventional for "send at local time" digest systems.
- **Alternatives considered:**
  - 24 timezone-bucket queues (one job per UTC offset): more precise batching but O(24) cron entries, complex to maintain when DST shifts offsets. Rejected — complexity not earned.
  - Single Monday 00:00 UTC job that sends to all users: cannot satisfy per-timezone 8:00 AM delivery. Rejected — violates blueprint.
- **Trade-off accepted:** The per-minute scheduler issues a DB query every minute on Monday. At low-to-medium user scale this is negligible; at very large scale a bucket approach could reduce DB reads. We accept the simpler design and will revisit if the Monday scheduler query becomes a measurable hotspot (see §6).

---

### D2. Idempotency: deduplicate sends across job re-triggers

- **Decision:** Before sending a digest, `DigestSendJob` performs an atomic `INSERT INTO digest_sends (user_id, iso_week) ... ON CONFLICT DO NOTHING` and checks the row count. If 0 rows inserted (conflict), the job exits immediately. The `iso_week` is the ISO week number of the Monday the digest covers.
- **Why:** Upholds *Idempotency & bounded operations* (Principle 6). The blueprint explicitly states "the weekly job is triggered twice — a user must still receive only one digest." Using a DB unique constraint rather than an in-memory or Redis lock makes the guard durable across restarts and concurrent Sidekiq workers. Upholds *Data integrity & durability* (Principle 5) — the constraint is enforced at the storage layer, not solely in application code.
- **Alternatives considered:**
  - Redis SET NX key: faster but not durable — a Redis flush or restart would lose the guard. Rejected.
  - Application-level check then insert (non-atomic): race condition between two concurrent workers. Rejected.
- **Trade-off accepted:** One additional DB write per digest job. The write is a tiny indexed insert; the cost is negligible.

---

### D3. Activity assembly: inline query vs. materialized activity cache

- **Decision:** `DigestSendJob` runs a set of direct PostgreSQL queries on the workspace activity tables to compute counts and select the top-10 highlighted items. No materialized or cached intermediate is pre-computed.
- **Why:** Upholds *Simplicity first / YAGNI* (Principle 1) and *Measure, don't guess* (Principle 8). The digest is computed once per user per week; there is no repeated read of the same data. A pre-materialized activity cache would add write-time fanout to every workspace event for a benefit that only manifests at send time. The queries run in a background job so user-perceived latency is unaffected. Upholds *Observability from day one* (Principle 10) — a slow query in a background job is measurable without impacting UX.
- **Alternatives considered:**
  - Nightly materialized view refresh: reduces Monday send-time query load at the cost of staleness (last 24 h missed) and added infrastructure. Rejected — staleness is unacceptable and complexity not earned.
  - Real-time event streaming to a digest aggregate table: significant complexity. Rejected.
- **Trade-off accepted:** Monday morning send time is a query hotspot if there are many concurrent digests. Mitigated by batching job enqueues with a short stagger (see §6) and by ensuring queries are covered by indexes on `(workspace_id, created_at)` and `(user_id, created_at)`.

---

### D4. Permission-scoped content: activity filtered to what the user can see

- **Decision:** The activity assembly queries JOIN on the user's workspace memberships and apply the same permission predicates used elsewhere (user can see items in workspaces they are a member of, with roles that grant read access). The query must not return items from deleted workspaces.
- **Why:** Upholds *Security & privacy by design* (Principle 11). The blueprint's adversarial scenario is explicit: "Digest content for a user must only include items that user is allowed to see." A deleted workspace must also be excluded (blueprint edge case). This is not optional — including unseen content is a security bug.
- **Alternatives considered:**
  - Collect all activity first then filter in Ruby: moves the trust boundary into application code where bugs are harder to audit. Rejected — prefer DB-layer enforcement.
- **Trade-off accepted:** Queries are slightly more complex (JOINs to membership/permission tables). This is a required cost; there is no cheaper option that preserves the security guarantee.

---

### D5. Empty digest suppression

- **Decision:** After the activity query, if total activity count is zero, `DigestSendJob` exits without sending and without inserting into `digest_sends`. This leaves the slot open; however, since activity count is zero by definition, there will be nothing to send for the rest of the week. We log the suppression for observability.
- **Why:** Direct blueprint requirement: "If a user had no relevant activity in the past week, no email is sent." Not inserting into `digest_sends` means if the job is re-run (duplicate trigger), it will re-check activity and again suppress — still idempotent, and avoids falsely marking "sent" a digest that was never sent.
- **Alternatives considered:**
  - Insert a `digest_sends` row with `status = 'suppressed'`: clearer audit trail but complicates the idempotency guard logic. We prefer a separate `digest_suppressions` log table (see §4) to keep the idempotency table clean.
- **Trade-off accepted:** The `digest_sends` table only records emails that were dispatched. A separate suppression log is needed for full audit visibility.

---

### D6. Unsubscribe token: signed HMAC, not guessable random

- **Decision:** Each email's unsubscribe link carries a token of the form `HMAC-SHA256(secret_key, user_id + ":" + iso_week)`, URL-safe base64 encoded. The unsubscribe endpoint validates the signature and acts only on the `user_id` embedded in the verified payload.
- **Why:** Upholds *Security & privacy by design* (Principle 11). The blueprint's adversarial scenario: "An unsubscribe link must act only on the account it was issued for and must not be guessable to unsubscribe someone else." An HMAC token with a server-side secret key is not guessable; brute-forcing it is infeasible. Including `iso_week` scopes the token to the specific send, preventing replay of old links across subsequent emails (minor but reasonable bound). The secret key is held in application secrets / environment variable.
- **Alternatives considered:**
  - UUID stored in DB per send: requires a DB lookup on every unsubscribe click, and UUIDs must be generated and stored for every send (including unsent users). The HMAC approach is stateless — no storage required.
  - Unauthenticated user-id parameter: trivially guessable; violates the adversarial requirement. Rejected.
- **Trade-off accepted:** Tokens do not expire (only bounded by `iso_week` scope). A leaked unsubscribe link remains valid indefinitely for that user. Acceptable because the worst-case abuse is unsubscribing a user from digests — undesirable but not a high-severity attack. The `iso_week` suffix limits the blast radius to that week's token.

---

### D7. Email delivery failure handling: retry-then-drop, no late delivery

- **Decision:** `DigestSendJob` retries on SendGrid failure up to 3 times with exponential back-off (5 s, 25 s, 125 s — fitting within a ~3-minute window). After exhausting retries, the job is marked dead in Sidekiq's dead-job queue and a structured log entry is written. The digest is **not** re-queued for later in the day.
- **Why:** Direct blueprint requirement: "A digest that arrives late is worse than one skipped — drop it for the week rather than delay into the afternoon." This is a deliberate product decision captured in the blueprint's deviation scenario. Upholds *Design for failure* (Principle 5) — failure modes are explicit, visible, and consistent with product intent.
- **Alternatives considered:**
  - Retry indefinitely until Monday 12:00 then drop: adds scheduler complexity for little gain — the user will have been at their desk for hours. Rejected.
  - No retries at all: transient SendGrid errors (rate limits, momentary downtime) are common enough that zero retries would increase the suppression rate unnecessarily. Rejected.
- **Trade-off accepted:** Transient errors that persist beyond ~3 minutes cause a missed digest. Acceptable per blueprint.

---

### D8. New-user partial-week window

- **Decision:** The activity assembly query uses `MAX(created_at, user.created_at)` as the window start, rather than a fixed Monday-00:00 cutoff. This ensures a user who joined mid-week gets a digest covering only the days since joining.
- **Why:** Direct blueprint requirement (edge case): "A brand-new user who joined mid-week: they receive a digest covering only the days since they joined, if there was activity."
- **Alternatives considered:**
  - Always use Monday-00:00 as window start: simpler query, but would show zero activity for a new user (since items pre-date their join), risking an empty digest suppression when there is post-join activity, or including activity that pre-dates the user's account. Rejected.
- **Trade-off accepted:** Minor query complexity — one additional `GREATEST(window_start, user.created_at)` expression.

---

### D9. Timezone default and runtime resolution

- **Decision:** Users with no configured timezone are treated as UTC (send at 08:00 UTC on Monday). Timezone is read from `users.timezone` (or `user_preferences.timezone`) at job enqueue time in `DigestSchedulerJob`. The timezone is stored as an IANA string (e.g., `"America/New_York"`). Offset is computed at send time using the system timezone database.
- **Why:** Direct blueprint requirement: "A user whose timezone is not set: the digest defaults to 8:00 AM UTC." Upholds *Make illegal states unrepresentable* (Principle 9) — rather than a nullable timezone that downstream code must guard against, the scheduler has a single normalization point.
- **Alternatives considered:**
  - Store UTC offset integer instead of IANA name: breaks for DST transitions; IANA names are the standard. Rejected.
- **Trade-off accepted:** If a user updates their timezone on Sunday night (blueprint edge case), the next scheduler sweep picks up the new value — "a small shift in send time is acceptable" per blueprint. No special handling required.

---

## 4. Data Model & Persistence

### `users` (existing table — new columns)

| Column | Type | Notes |
|---|---|---|
| `digest_enabled` | `boolean NOT NULL DEFAULT true` | Whether the user receives digests. |
| `timezone` | `varchar(64) NULL` | IANA timezone string. NULL treated as UTC at send time. |

Migration: `ADD COLUMN digest_enabled BOOLEAN NOT NULL DEFAULT TRUE`, `ADD COLUMN timezone VARCHAR(64)`. Backfill: existing users get `digest_enabled = true` (opt-out model — users receive by default until they unsubscribe). If the codebase already has a `user_preferences` table, these columns belong there; assumption A5 notes this.

---

### `digest_sends` (new table)

| Column | Type | Constraint | Notes |
|---|---|---|---|
| `id` | `bigint` | PK | |
| `user_id` | `bigint` | FK → users, NOT NULL | |
| `iso_week` | `varchar(8)` | NOT NULL | Format: `"YYYY-Www"` (e.g. `"2026-W21"`) |
| `sent_at` | `timestamptz` | NOT NULL DEFAULT now() | When the email was dispatched |
| `status` | `varchar(32)` | NOT NULL DEFAULT `'sent'` | `'sent'` or `'failed_dropped'` |
| | | UNIQUE(`user_id`, `iso_week`) | Idempotency constraint |

Index: `(user_id, iso_week)` — covered by the unique constraint. No additional index needed unless querying by date range for ops dashboards.

Retention: rows are cheap; retain indefinitely for audit/support. A future cleanup job can purge rows older than 1 year (out of scope for this design).

---

### `digest_suppressions` (new table — audit log for empty-digest non-sends)

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint` | PK |
| `user_id` | `bigint` | FK → users, NOT NULL |
| `iso_week` | `varchar(8)` | NOT NULL |
| `suppressed_at` | `timestamptz` | NOT NULL DEFAULT now() |
| `reason` | `varchar(64)` | `'no_activity'`, `'workspace_deleted'`, `'digest_disabled'` |

No unique constraint — multiple suppression log entries for the same (user, week) are acceptable in edge cases (duplicate job runs with no activity both suppress).

---

### Workspace activity tables (existing — read-only from this feature)

The design assumes existing tables covering: items/tasks (with `workspace_id`, `created_at`, `completed_at`, `updated_at`), comments (with `user_id`, `item_id`, `created_at`), and workspaces (with `deleted_at`). No schema changes to these tables. Assumption A6 covers this.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **SendGrid** | Transactional email delivery (digest emails and unsubscribe confirmation) | API key stored in environment variable / secrets manager (`SENDGRID_API_KEY`). Never committed to source. | Free tier: 100 emails/day. Paid tiers scale to millions/day. Cost: ~$0.001–0.002 per email at typical tiers. Quota ceiling: configure SendGrid alert at 80% of plan limit; application-level circuit breaker if HTTP 429 received. | HTTP 4xx (bad request, invalid address): log and drop — do not retry invalid-address errors. HTTP 429 (rate limit): retry with back-off. HTTP 5xx (SendGrid outage): retry up to 3 times then drop per D7. No fallback delivery provider (see Assumption A3). | Stub the SendGrid HTTP client in tests; inject a `Mailer` interface so unit tests never make live HTTP calls. Integration tests use SendGrid's sandbox mode (set `mail_settings.sandbox_mode.enable = true` in API payload). |

**Note on external-system grammar:** SendGrid's transactional email API carries template IDs, substitution variable schemas, and tracking settings. The specifics of template configuration (variable names, HTML template ID) should be captured in a separate operational runbook or probe-tested configuration skill rather than encoded as invariants in this design doc.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | Target | Notes |
|---|---|---|
| User receives digest email | 8:00 AM ± 5 min local time | Background job; no synchronous user request |
| Unsubscribe link click → confirmation | p95 < 500 ms | Simple DB write + redirect |
| Digest assembly per user | < 2 s per user in background | Not user-visible; generous budget |

### Expected load

- **Initial scale assumption:** 10,000 active users. Spread across 24 UTC offset hours, ~420 users per hour bucket. Peak Monday UTC offsets (UTC-5 to UTC+5) may batch ~2,000–3,000 users in a 2-hour window.
- **Growth:** Up to ~100,000 users is handled by the same architecture; queries must be index-covered (see §4). Beyond that, consider pre-aggregating activity in a nightly job (revisit trigger in C3).
- **Sidekiq concurrency:** Digest jobs run in a dedicated `digest` queue with concurrency=20. This paces the query load on Postgres and limits simultaneous SendGrid connections.

### Caching

No caching layer is introduced for this feature. Rationale:

- Each user's digest content is computed once per week per user; there is no repeated read within the same run.
- Activity data is live PostgreSQL; freshness requirement is "rolling 7 days ending Monday 00:00 local" — no stale cache is acceptable.
- Applying *Principle 13 (cache invalidation is a design decision)*: since there is no cache to introduce, there is no invalidation concern. We explicitly choose not to cache rather than defaulting to it.

### Query optimization

- Index `workspace_items(workspace_id, created_at)`, `workspace_items(created_at)` for time-range scans.
- Index `comments(user_id, created_at)` for mention queries.
- Ensure `workspaces(deleted_at)` is indexed for the deletion-filter join.
- The top-10 highlighted items query uses `ORDER BY created_at DESC LIMIT 11` (11 to detect "+N more").

### Job stagger

`DigestSchedulerJob` enqueues `DigestSendJob` items with a small random delay (0–30 s jitter) to avoid thundering-herd on Postgres and SendGrid when a large timezone bucket fires at once.

---

## 7. Reliability & Failure Handling

### Failure matrix

| Failure | Behavior | User sees | Blueprint ref |
|---|---|---|---|
| SendGrid HTTP 5xx (transient) | Retry 3× with exponential back-off (5 s, 25 s, 125 s) | Nothing — email may arrive slightly late but within window | Deviation: "retried; if still fails after retries, dropped for the week" |
| SendGrid error persists after 3 retries | Job moved to Sidekiq dead queue; `digest_sends` row inserted with `status='failed_dropped'`; structured log written | No email this week | Deviation: "dropped for the week rather than delayed into afternoon" |
| SendGrid invalid recipient (422) | No retry — log and insert `digest_sends(status='failed_dropped')` | No email | Principle 5: don't retry unrecoverable errors |
| Job triggered twice (duplicate) | Second job hits `digest_sends` unique constraint → exits immediately | One email only | Deviation: "weekly job triggered twice — user still receives only one" |
| Activity query returns 0 results | No email sent; row inserted into `digest_suppressions` | No email | Behavior: "no email is sent" for empty digest |
| User's workspace deleted | Permission JOIN excludes deleted workspace items; if all activity was in deleted workspace → empty digest → no email | No email | Edge case: "workspace deleted — no email" |
| Scheduler job delayed (late start) | Users still get correct 7-day window; absolute send time may slip | Email arrives late but with correct content | Deviation: "job delayed — correct window, send time may slip" |
| Postgres temporarily unavailable | Sidekiq job fails → retried by Sidekiq default retry policy (up to 25 retries over ~21 days). Since digest jobs run on Monday, retries within the same Monday are meaningful; after Monday the job will eventually be dropped or left dead. | No email or delayed email | Principle 5 |

### Idempotency guarantee

The `UNIQUE(user_id, iso_week)` constraint on `digest_sends` is the single durable idempotency guard. Application-level checks are secondary. This means: even if two concurrent `DigestSendJob` workers race for the same user, the DB constraint ensures only one proceeds to SendGrid.

### Retry policy for `DigestSendJob`

```
sidekiq_options queue: :digest, retry: 3
```

Custom back-off: 5 s, 25 s, 125 s. After 3 failures the job is moved to the Sidekiq dead queue (not retried again automatically). Ops can manually retry from the dead queue if a systematic SendGrid outage caused widespread failures.

---

## 8. Security & Privacy

### Authentication & authorization

- `DigestSchedulerJob` and `DigestSendJob` run as internal Sidekiq workers. They are not callable from the outside — no external attack surface.
- The unsubscribe endpoint (`GET /emails/digest/unsubscribe?token=<signed>`) is the only public-facing surface. It requires no login — by design (a user who received the email may not be logged in when they click unsubscribe).

### Unsubscribe token security (D6)

- Token: `HMAC-SHA256(DIGEST_UNSUBSCRIBE_SECRET, "#{user_id}:#{iso_week}")`, base64url-encoded.
- `DIGEST_UNSUBSCRIBE_SECRET` is a randomly generated 256-bit key stored as an environment variable / secrets manager entry. Never logged, never committed.
- Validation: the endpoint extracts `user_id` and `iso_week` from the token payload (or passes them as URL params alongside the HMAC), recomputes the HMAC, and uses a constant-time comparison (`Rack::Utils.secure_compare`) to prevent timing attacks.
- A valid token for week W cannot be used to unsubscribe in week W+1 (different `iso_week` suffix).

### Content scoping (D4)

- Digest content is assembled with the user's permission context applied at the SQL level.
- Items in deleted workspaces are excluded via `WHERE workspaces.deleted_at IS NULL`.
- No cross-user data leakage is possible because queries are parameterized on `user_id`.

### PII handling

- Digest emails contain user-generated content (item titles, comment excerpts). This content transits SendGrid. Ensure DPA with SendGrid is in place.
- No PII is logged beyond user_id and iso_week in structured logs.
- Unsubscribe endpoint logs only `user_id` and timestamp — not the token itself.

### Input validation

- The unsubscribe token is validated before any DB write. Invalid or tampered tokens return HTTP 400 with no information disclosure.
- No user-supplied content is rendered server-side in the unsubscribe flow.

---

## 9. Observability

### Structured log events

| Event | Level | Fields |
|---|---|---|
| `digest.scheduler.enqueued` | INFO | `iso_week`, `user_count`, `duration_ms` |
| `digest.send.started` | INFO | `user_id`, `iso_week` |
| `digest.send.suppressed` | INFO | `user_id`, `iso_week`, `reason` |
| `digest.send.delivered` | INFO | `user_id`, `iso_week`, `item_count`, `sendgrid_message_id` |
| `digest.send.failed` | ERROR | `user_id`, `iso_week`, `attempt`, `error_class`, `error_message` |
| `digest.send.dropped` | WARN | `user_id`, `iso_week`, `reason` (`retries_exhausted` or `invalid_address`) |
| `digest.duplicate.skipped` | INFO | `user_id`, `iso_week` |

### Metrics (emit to application metrics system)

| Metric | Type | Notes |
|---|---|---|
| `digest_emails_enqueued_total` | Counter | Incremented by scheduler |
| `digest_emails_delivered_total` | Counter | Per successful send |
| `digest_emails_suppressed_total` | Counter | Labels: `reason` |
| `digest_emails_failed_dropped_total` | Counter | Alerts on this |
| `digest_assembly_duration_seconds` | Histogram | Per-user query time |
| `digest_send_duration_seconds` | Histogram | SendGrid HTTP call time |

### The one signal that proves the feature is healthy

> **`digest_emails_delivered_total` increases by ≥ 80% of `digest_emails_enqueued_total` in the 2-hour window after Monday 08:00 UTC.**

This single ratio catches scheduler failures, mass SendGrid outages, and broken assembly logic. Alert if the ratio drops below 80% in any Monday send window.

### Alerts

| Alert | Trigger | Severity |
|---|---|---|
| Digest delivery ratio low | Delivered < 80% of enqueued in 2-hour window | P2 |
| Digest dropped count spike | `digest_emails_failed_dropped_total` > 100 in 1 hour | P2 |
| Scheduler did not run | No `digest.scheduler.enqueued` event on Monday between 07:55–09:00 UTC | P1 |
| Sidekiq dead queue growing | Dead-queue depth for `digest` queue > 50 | P3 |

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a boolean flag: `digest_emails_enabled`. Default: **off** (fail-closed). The scheduler checks this flag at the top of `DigestSchedulerJob#perform` and no-ops if disabled.

Staged rollout:
1. Deploy schema migrations (additive columns + new tables) — no behavior change.
2. Enable `digest_emails_enabled = true` for internal users / a small percentage.
3. Observe metrics for one Monday cycle.
4. Expand to 100% of users.

### Migration order

1. `ALTER TABLE users ADD COLUMN digest_enabled BOOLEAN NOT NULL DEFAULT TRUE`
2. `ALTER TABLE users ADD COLUMN timezone VARCHAR(64)`
3. `CREATE TABLE digest_sends ...`
4. `CREATE TABLE digest_suppressions ...`
5. Deploy application code (scheduler + jobs + unsubscribe endpoint)
6. Register cron job in Sidekiq scheduler config

All migrations are additive. No backfill required — `digest_enabled = true` default covers existing users.

### Reversibility

- Disabling the feature flag immediately stops all digest sending.
- Dropping the cron job entry removes the scheduler trigger.
- The schema changes are additive; reverting the application code does not require a schema rollback.
- `digest_sends` and `digest_suppressions` tables can be dropped safely; no other feature depends on them.

### Operational runbook hooks

- To manually suppress all digests for a maintenance window: set `digest_emails_enabled = false` before Monday 07:00 UTC.
- To re-run a failed week's digests: delete affected rows from `digest_sends` and re-trigger `DigestSchedulerJob` (idempotency guard will prevent re-sends to users who already received their digest).

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | Users exist in a single `users` table with `id`, `email`, `created_at`. | Standard Rails/Postgres app model; no multi-tenant per-user DB sharding described in the stack. | No |
| A2 | There is already a Sidekiq cron scheduler configured (e.g., `sidekiq-cron` gem). | Stack description specifies Sidekiq for background jobs; cron scheduling is a standard Sidekiq extension. | Yes — confirm `sidekiq-cron` or equivalent is available |
| A3 | SendGrid is the sole email provider; no fallback provider. | Task specifies SendGrid. Fallback provider adds significant complexity not warranted without evidence of availability requirements beyond "drop after retries." | No |
| A4 | The application has a secrets/environment variable system for holding `SENDGRID_API_KEY` and `DIGEST_UNSUBSCRIBE_SECRET`. | Standard for any production Rails app. | No |
| A5 | Timezone and digest preference can be added as columns on `users`. If a `user_preferences` table exists, columns go there instead. | Both are valid; the schema is equivalent. | Yes — confirm correct table |
| A6 | Workspace activity (items, completions, comments) is stored in Postgres in tables with `workspace_id`, `user_id`, and `created_at` columns. | Blueprint describes "workspace activity" without specifying schema; this is the minimal required shape. | Yes — confirm exact table/column names |
| A7 | "Comments mentioning a user" means comments where the user is the author OR is @-mentioned. The exact mention mechanism is already modeled in the DB. | Blueprint lists "comments mentioning them" as digest content. Exact semantics depend on existing model. | Yes — confirm mention model |
| A8 | The existing application has a mailer abstraction (e.g., ActionMailer) that wraps SendGrid, or we will create a thin wrapper. | Rails + SendGrid is the standard stack combination. | No |
| A9 | Workspace deletion is tracked with a `deleted_at` column (soft delete) on the `workspaces` table. | Soft delete is the conventional Rails pattern; required by the blueprint edge case. | Yes — confirm soft vs hard delete |
| A10 | The user's `created_at` column can be used as the join-date for the partial-week window calculation. | Standard convention; no separate "activated_at" is described. | No |
| A11 | The digest covers items across **all** workspaces a user is a member of, not just one. | Blueprint says "workspace activity" without limiting to a single workspace per user. | Yes — confirm multi-workspace scope |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | No pre-aggregated activity cache — queries run at send time | If the user base is large, Monday morning becomes a Postgres read hotspot | Principle 8 (Measure, don't guess) — we're accepting potential perf debt instead of over-engineering now | At initial scale (10K users), the load is manageable. A per-minute scheduler spreads load; the `digest` Sidekiq queue is rate-limited to 20 concurrent workers. | When Monday digest queries account for > 5% of Postgres read load, introduce a nightly incremental aggregate |
| C2 | Drop-after-3-retries rather than guaranteed delivery | A user misses their digest if SendGrid is down for > ~3 minutes | Principle 5 (Design for failure) — "never miss" would be better technically | Blueprint explicitly specifies this behavior: "a digest that arrives late is worse than one skipped." Product intent overrides the principle here. | If the product team re-evaluates the "late is worse than none" rule |
| C3 | No email template versioning in this design | Changing the email template is a code deploy, not a config change | Principle 7 (Prefer reversible decisions) — template-as-code is less flexible | Template versioning adds significant infrastructure (template service or SendGrid Dynamic Templates with version IDs). Out of scope for initial feature. | When > 1 active email template version needs to be supported simultaneously |
| C4 | Unsubscribe token does not expire | A leaked token can unsubscribe the user indefinitely for that `iso_week`-scoped token | Principle 11 (Security & privacy by design) — an expiring token would be stronger | The worst-case abuse (unsubscribing a user) is low-severity and reversible (re-enable in preferences). Token rotation per-week limits blast radius. | If token leakage incidents occur or user sensitivity increases |
| C5 | Timezone read at scheduler time, not locked at job creation | If timezone changes between scheduler run and job execution (seconds), the send time could be marginally off | Principle 6 (Idempotency & bounded operations) | The window is seconds; the blueprint explicitly accepts "a small shift in send time." | Not a revisit trigger — acceptable permanently per blueprint |

---

## 13. Open Risks & Callouts

- **Risk R1 — Activity schema unknown:** The design assumes a specific shape for workspace activity tables (assumption A6). If the actual schema differs materially (e.g., activity is in a separate event-sourcing store, not Postgres), the assembly query strategy must be revisited before implementation.
- **Risk R2 — Mention semantics:** "Comments mentioning them" (assumption A7) is ambiguous. If there is no @-mention model in the DB, the digest can only count comments where the user is the author, which changes the product behavior. Requires confirmation before implementation.
- **Risk R3 — SendGrid plan limits:** At 10K users/week, SendGrid free tier (100/day) is far exceeded. Confirm the paid plan is in place and the `SENDGRID_API_KEY` is provisioned before Monday of the first live run.
- **Risk R4 — Timezone data quality:** If most users have no timezone set, nearly all digests will fire at 08:00 UTC. This could be a Monday-morning Postgres/SendGrid spike. Monitor on first rollout.
- **Risk R5 — Sidekiq-cron availability:** If `sidekiq-cron` is not already installed (assumption A2), integration requires adding a gem dependency and scheduler config. This is a small but blocking prerequisite.
- **Risk R6 — Multi-workspace scope:** If digests should be scoped to a single "primary" workspace per user rather than all workspaces, the permission-filter query and highlighted-items selection change significantly (assumption A11).

---

## 14. Out of Scope

The following are explicitly out of scope per the blueprint and/or deliberate design choices:

- Daily or monthly digest frequencies (blueprint out of scope).
- User customization of which activity types appear in the digest (blueprint out of scope).
- In-app rendering of the digest (blueprint out of scope).
- Email template versioning / A/B testing (C3).
- Fallback email provider (A3).
- Digest delivery for deactivated/suspended accounts — assumed to be handled by existing user-status logic; no special case added here.
- Re-sending a missed digest on request — a user who missed their digest due to SendGrid failure has no self-service recovery path in this design.
- Analytics or click-tracking on digest links beyond what SendGrid provides natively.
- Admin dashboard for digest health (covered by metrics/alerts in §9).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency targets set; background job removes sync latency concern; unsubscribe endpoint p95 < 500 ms |
| A2 Throughput & scale | Resolved | §6 — 10K users baseline; Sidekiq queue concurrency=20; stagger jitter; index strategy in §4 |
| A3 Concurrency & consistency | Resolved | D2 — DB unique constraint on `digest_sends(user_id, iso_week)` is the atomic idempotency guard; §7 failure matrix |
| A4 Availability & reliability | Resolved | D7 — retry 3× then drop; §7 failure matrix; no late delivery per blueprint |
| A5 Data integrity & durability | Resolved | D2 — idempotency at DB layer; §4 — schema constraints; §7 — partial failure handling |
| A6 Caching & freshness | Resolved | D3 — explicit decision: no cache; direct queries for freshness; §6 caching section |
| A7 Cost | Resolved | §5 — SendGrid cost noted; plan ceiling alert; Sidekiq queue rate-limiting; §12 C1 on query cost |
| A8 Security & privacy | Resolved | D4 — permission-scoped queries; D6 — HMAC unsubscribe token; §8 full security section |
| A9 Observability | Resolved | §9 — structured logs, metrics, alerts, health signal |
| A10 Maintainability & simplicity | Resolved | D1, D3 — explicitly chose simpler designs; §14 scope cuts; two new tables, two new jobs, one endpoint |
| A11 Testability | Resolved | §5 — SendGrid mock strategy; D6 — deterministic HMAC allows deterministic test tokens; §9 seams |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, staged rollout, reversibility |
| A13 Backward compatibility | Assumed (A1, A5) | Additive schema changes only; no existing API contracts changed; no frontend changes |
| A14 Accessibility & device/env | N/A (partially) | Email rendering accessibility (alt text, semantic HTML) is a template concern, not a system-design concern. The unsubscribe flow is a single-link redirect — no complex UI. Email client compatibility is a template/QA concern. |
| B1 Placement / module taxonomy | Resolved | §2 — two Sidekiq jobs (`DigestSchedulerJob`, `DigestSendJob`), one controller action; placement described |
| B2 Data model & persistence | Resolved | §4 — `digest_sends`, `digest_suppressions`, columns on `users`; migration shape; retention |
| B3 API surface & schemas | Resolved | Unsubscribe endpoint: `GET /emails/digest/unsubscribe?token=<signed>` — no other public API surface |
| B4 Async / background work | Resolved | D1 — Sidekiq cron + per-user jobs; D7 — retry policy; idempotency in D2 |
| B5 External services & contracts | Resolved | §5 — SendGrid table; auth, rate limits, failure, mock strategy |
| B6 Frontend integration | N/A | No frontend changes. Digest is email-only. Unsubscribe is a server-rendered redirect. In-app digest rendering is out of scope. |
| B7 Feature flags & rollout | Resolved | §10 — `digest_emails_enabled` flag, default off, staged rollout |
| B8 Error handling | Resolved | D7 — retry/drop policy; §7 failure matrix; error classes (transient 5xx vs invalid-address 4xx) |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| "Every Monday morning, each user receives an email digest summarizing activity in their workspace over the previous seven days" | Behavior | D1, §2 | Sidekiq cron scheduler fans out per-user send jobs every Monday |
| "Send time is 8:00 AM in each user's configured timezone" | Behavior | D1, D9, §6 | Scheduler queries users whose 8:00 AM UTC equivalent is current; timezone from `users.timezone` |
| "Digest covers rolling seven days ending Monday 00:00 local time" | Behavior | D3, D8 | Activity query window: `GREATEST(user.created_at, monday_00:00_local)` to `monday_00:00_local` |
| "User receives one email with: headline summary, counts (new/completed/commented), and up to ten highlighted items with links" | Behavior | D3, §4 | Assembly query returns counts and `ORDER BY created_at DESC LIMIT 11`; email template renders these |
| "Clicking any item link opens that item in the app" | Behavior | N/A (template concern) | Item links are generated from item IDs; URL format is a template/routing concern, not a system-design decision |
| "Each email has a one-click unsubscribe link in the footer" | Behavior | D6, §8 | HMAC-signed token in footer link; validated by unsubscribe endpoint |
| "A user with digests turned off receives nothing" | Behavior | D5, §4 | `digest_enabled = false` → suppressed, logged in `digest_suppressions` |
| "If a user had no relevant activity in the past week, no email is sent" | Behavior | D5 | Activity count = 0 → no send, `digest_suppressions` entry written |
| "Each user receives at most one digest email per week" | Behavior | D2 | `UNIQUE(user_id, iso_week)` on `digest_sends`; duplicate job skips |
| "Highlighted items chosen by recency, capped at ten; email notes '+N more' if more" | Behavior | D3 | `ORDER BY created_at DESC LIMIT 11`; if 11 rows returned → "+N more" in template |
| "Unsubscribing is immediate and takes effect before the next Monday" | Behavior | D6, §8 | Unsubscribe endpoint writes `digest_enabled = false` immediately; next scheduler sweep skips the user |
| **Edge case:** brand-new user joined mid-week — digest covers only days since joining | Edge case | D8 | Window start = `GREATEST(monday_00:00_local, user.created_at)` |
| **Edge case:** user with activity but workspace deleted — no email | Edge case | D4 | Permission JOIN excludes workspaces with `deleted_at IS NOT NULL`; if all activity is in deleted workspace → empty → suppressed |
| **Edge case:** user timezone not set — defaults to 8:00 AM UTC | Edge case | D9 | NULL timezone → treated as UTC in scheduler query |
| **Edge case:** user changes timezone on Sunday night — next digest uses new timezone | Edge case | D9 | Timezone read at scheduler time (Monday morning); new value already in DB → picked up |
| **Deviation:** email provider down — retry; if still fails after retries, drop for week | Deviation | D7, §7 | Retry 3× (5 s, 25 s, 125 s); on exhaustion → `failed_dropped` in `digest_sends`, Sidekiq dead queue |
| **Deviation:** weekly job triggered twice — user must still receive only one digest | Deviation | D2 | `ON CONFLICT DO NOTHING` on `digest_sends`; second job exits after 0 rows inserted |
| **Deviation:** job delayed and starts late — users get correct 7-day window | Deviation | D3, D9 | Window is computed from `monday_00:00_local` regardless of when job runs; content is unaffected |
| **Adversarial:** unsubscribe link must act only on the account it was issued for and must not be guessable | Adversarial | D6, §8 | HMAC-SHA256 with server secret; token validated before DB write; constant-time comparison |
| **Adversarial:** digest content must only include items the user is allowed to see | Adversarial | D4, §8 | SQL queries JOIN on membership/permission tables; parameterized on `user_id` |

---

## Appendix A: Captured Inputs

*This feature was designed autonomously (no human interview available). The following records each decision fork, the recommendation made, the reasoning applied, and the resolution. This appendix preserves the P3 interview record as it would appear after a live interview, with all resolutions noted as autonomous decisions made from the blueprint and stack description.*

---

### Scheduling strategy (D1)

- **Question:** Should we fan out per-user jobs via a per-minute cron sweep, or use 24 timezone-bucket queues?
- **Recommendation given:** Per-minute sweep. Simpler cron configuration (one entry), standard Sidekiq pattern. 24-bucket design adds complexity not warranted at the specified scale.
- **Resolution (autonomous):** Per-minute sweep adopted. Consistent with Principle 1 (Simplicity first) and Principle 2 (Match existing patterns).
- **Notes:** The sweep query needs a DB index on `(timezone, digest_enabled)` to be efficient.

---

### Idempotency guard (D2)

- **Question:** Should the duplicate-send guard live in Redis (SET NX), in the DB (unique constraint), or in application code?
- **Recommendation given:** DB unique constraint on `digest_sends(user_id, iso_week)`. Durable across restarts; enforced at the storage layer; survives Sidekiq worker restarts and Redis flushes.
- **Resolution (autonomous):** DB unique constraint adopted. Upholds Principles 5 and 6.
- **Notes:** The `ON CONFLICT DO NOTHING` + row-count check pattern is the atomic implementation.

---

### Activity assembly: inline query vs. pre-aggregated (D3)

- **Question:** Should activity data be pre-aggregated nightly or queried at send time?
- **Recommendation given:** Query at send time. Digest is computed once per user per week; pre-aggregation adds write-path complexity for a read that happens once weekly per user.
- **Resolution (autonomous):** Direct query at send time. Upholds Principle 1. Revisit trigger added in §12 C1.
- **Notes:** Index strategy on activity tables is required to make this acceptable.

---

### Permission-scoped content (D4)

- **Question:** Should permissions be enforced at SQL level or post-query in application code?
- **Recommendation given:** SQL level — JOIN on membership/permission tables in the assembly query.
- **Resolution (autonomous):** SQL-level enforcement. Non-negotiable given the adversarial requirement.

---

### Empty digest suppression (D5)

- **Question:** Should a suppressed (no-activity) digest result in a `digest_sends` row with a `suppressed` status, or a separate table?
- **Recommendation given:** Separate `digest_suppressions` table to keep the idempotency guard clean.
- **Resolution (autonomous):** Separate table adopted. Idempotency table records only dispatched emails; suppressions are logged separately.

---

### Unsubscribe token design (D6)

- **Question:** Should the unsubscribe token be a DB-stored UUID or a stateless HMAC?
- **Recommendation given:** Stateless HMAC-SHA256. No storage needed; not guessable; satisfies the adversarial requirement.
- **Resolution (autonomous):** HMAC adopted. `iso_week` included in the HMAC input to scope the token per-send-week.

---

### Email delivery failure policy (D7)

- **Question:** How many retries, and what happens on exhaustion?
- **Recommendation given:** 3 retries with exponential back-off, then drop. Consistent with the blueprint's explicit "late is worse than none" ruling.
- **Resolution (autonomous):** 3-retry policy adopted. Blueprint's deviation scenario is the direct source of truth.

---

### New-user partial-week window (D8)

- **Question:** How is the activity window computed for a user who joined mid-week?
- **Recommendation given:** Use `GREATEST(monday_00:00_local, user.created_at)` as window start.
- **Resolution (autonomous):** Adopted. Direct implementation of the blueprint edge case.

---

### Timezone resolution and default (D9)

- **Question:** IANA string or UTC offset integer? What default?
- **Recommendation given:** IANA string (DST-safe); NULL → UTC default.
- **Resolution (autonomous):** IANA string with UTC default. Blueprint specifies "defaults to 8:00 AM UTC" for unset timezone.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** *(Autonomous run — no human available.)* No additional concerns surfaced from the blueprint. The following open risks were self-identified and captured in §13: activity schema shape (R1), mention semantics (R2), SendGrid plan provisioning (R3), timezone data quality (R4), sidekiq-cron availability (R5), multi-workspace scope (R6).
