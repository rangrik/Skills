# System Design: Weekly Digest Email

**Feature:** Weekly Digest Email
**Stack:** PostgreSQL · Sidekiq · SendGrid
**Blueprint Date:** 2026-05-14
**Design Date:** 2026-05-23

---

## 1. Overview

Every Monday at 08:00 in each user's configured timezone, the system sends one digest email summarizing the previous seven days of workspace activity. The design must handle timezone-driven fan-out, idempotent delivery, permission-scoped content assembly, and secure one-click unsubscribe.

---

## 2. Data Model

### 2.1 Users table (additions / relevant columns)

```sql
-- Existing or extended columns on the users table
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS digest_enabled       BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS timezone             TEXT        NOT NULL DEFAULT 'UTC',
  ADD COLUMN IF NOT EXISTS digest_unsubscribe_token TEXT    UNIQUE,
  ADD COLUMN IF NOT EXISTS created_at           TIMESTAMPTZ NOT NULL DEFAULT now();
```

`digest_unsubscribe_token` is a random, opaque, per-user token generated at account creation (or backfilled). It never changes so that unsubscribe links in already-delivered emails remain valid.

### 2.2 digest_sends table (idempotency ledger)

```sql
CREATE TABLE digest_sends (
  id           BIGSERIAL     PRIMARY KEY,
  user_id      BIGINT        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start   DATE          NOT NULL,   -- Monday (UTC date) that defines this digest window
  status       TEXT          NOT NULL DEFAULT 'pending',  -- pending | sent | skipped | failed
  sendgrid_message_id TEXT,
  created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
  UNIQUE (user_id, week_start)           -- idempotency constraint
);

CREATE INDEX ON digest_sends (week_start, status);
```

`week_start` is stored as the Monday calendar date in UTC. The UNIQUE constraint on `(user_id, week_start)` is the database-level guard against duplicate sends.

### 2.3 workspace_items table (illustrative; adapt to existing schema)

Assumed existing columns relevant to digest assembly:

| Column | Type | Notes |
|--------|------|-------|
| id | bigint | PK |
| workspace_id | bigint | FK → workspaces |
| created_by_user_id | bigint | FK → users |
| title | text | |
| item_type | text | e.g. task, doc, comment |
| mentioned_user_ids | bigint[] | users @-mentioned |
| completed_at | timestamptz | NULL if not completed |
| created_at | timestamptz | |
| deleted_at | timestamptz | soft delete |

### 2.4 workspace_memberships table (assumed existing)

```sql
-- Used for permission scoping
-- user_id, workspace_id, role, deleted_at
```

---

## 3. Scheduling Architecture

### 3.1 Timezone fan-out via Monday rollovers

Rather than one massive job at a single UTC time, the scheduler enqueues per-user jobs at the right UTC moment for each timezone.

**Approach: Hourly coordinator job**

A lightweight Sidekiq-Cron job (`DigestCoordinatorJob`) runs every hour, 24 hours a day, 7 days a week. On each run it:

1. Computes `target_local_time = 08:00 on the current Monday` for each timezone offset.
2. Identifies the UTC window `[now-60min, now)` — i.e., the set of timezone offsets whose 08:00 Monday falls within the past hour.
3. Queries for all users whose `timezone` maps to those offsets AND `digest_enabled = TRUE`.
4. For each user, upserts a `digest_sends` row with `status = 'pending'` (skips if the row already exists — idempotency).
5. Enqueues one `DigestBuildAndSendJob` per user.

```
config/initializers/sidekiq_cron.rb (illustrative)

Sidekiq::Cron::Job.create(
  name:  'Weekly Digest Coordinator',
  cron:  '0 * * * *',       # top of every hour
  class: 'DigestCoordinatorJob'
)
```

This approach scales linearly with user count and naturally handles all 24 timezones (and sub-hour offsets like IST +05:30) by running every hour at :00 and, if sub-hour offsets are needed, also at :30.

### 3.2 DigestCoordinatorJob — pseudocode

```ruby
class DigestCoordinatorJob
  include Sidekiq::Job

  SEND_HOUR = 8  # 08:00 local

  def perform
    now_utc = Time.now.utc

    # Only act on Mondays (UTC); accept a ±1-day window to cover edge timezones
    return unless (now_utc - 1.day).monday? || now_utc.monday? || (now_utc + 1.day).monday?

    # Find users whose 08:00 Monday falls in [now_utc - 1.hour, now_utc)
    eligible_users = User
      .where(digest_enabled: true)
      .where(workspace_active_membership: true)  # join filter — no deleted workspaces
      .select { |u| in_send_window?(u.timezone, now_utc) }

    week_start = current_week_start(now_utc)  # the Monday date in UTC

    eligible_users.each do |user|
      # Idempotency: INSERT ... ON CONFLICT DO NOTHING
      send_record = DigestSend.create_or_skip(user_id: user.id, week_start: week_start)
      next if send_record.nil?  # already exists

      DigestBuildAndSendJob.perform_async(user.id, week_start.iso8601)
    end
  end

  private

  def in_send_window?(tz_name, now_utc)
    tz = ActiveSupport::TimeZone[tz_name] || ActiveSupport::TimeZone['UTC']
    local_now = now_utc.in_time_zone(tz)
    local_prev = (now_utc - 1.hour).in_time_zone(tz)

    # Check if 08:00 this Monday falls in the window
    monday_8am = local_now.beginning_of_week.change(hour: SEND_HOUR)
    monday_8am >= local_prev && monday_8am < local_now
  end

  def current_week_start(now_utc)
    # The Monday that is nearest in the past (or today)
    now_utc.to_date.beginning_of_week(:monday)
  end
end
```

### 3.3 Double-trigger protection

The `UNIQUE (user_id, week_start)` constraint on `digest_sends` combined with `INSERT ... ON CONFLICT DO NOTHING` ensures that even if the coordinator fires twice (e.g., due to a deploy restart), at most one `digest_sends` row is created per user per week, and therefore at most one `DigestBuildAndSendJob` is enqueued.

If the job were somehow enqueued twice, `DigestBuildAndSendJob` checks `digest_sends.status` at the start; if it is already `sent`, it exits immediately.

---

## 4. Content Assembly

### 4.1 DigestBuildAndSendJob — responsibilities

1. Re-check the user is still eligible (digest still enabled, not deleted).
2. Compute the digest window: `[user_joined_at_or_7_days_ago, monday_00:00_local)`.
3. Query workspace activity, scoped to workspaces the user is currently a member of.
4. If no activity → mark `digest_sends.status = 'skipped'`, return.
5. Render the email template.
6. Deliver via SendGrid.
7. Mark `digest_sends.status = 'sent'`.

### 4.2 Window calculation

```ruby
week_start_date = Date.parse(week_start_str)           # the Monday
local_tz        = ActiveSupport::TimeZone[user.timezone] || ActiveSupport::TimeZone['UTC']
window_end      = local_tz.local(week_start_date.year,
                                  week_start_date.month,
                                  week_start_date.day, 0, 0, 0).utc
window_start    = [window_end - 7.days, user.created_at].max
```

This handles the new-user edge case: if the user joined mid-week, `window_start` is clamped to their join date.

### 4.3 Activity queries (permission-scoped)

All queries join through `workspace_memberships` to ensure the user is an active member of the workspace and the workspace is not deleted.

```sql
-- New items created by others in the user's workspaces
SELECT wi.*
FROM workspace_items wi
JOIN workspace_memberships wm
  ON wm.workspace_id = wi.workspace_id
  AND wm.user_id = :user_id
  AND wm.deleted_at IS NULL
JOIN workspaces w ON w.id = wi.workspace_id AND w.deleted_at IS NULL
WHERE wi.created_at BETWEEN :window_start AND :window_end
  AND wi.deleted_at IS NULL
  AND wi.created_by_user_id != :user_id
ORDER BY wi.created_at DESC
LIMIT 11;  -- fetch 11 to detect "+N more"

-- Items completed in the window
SELECT wi.*
FROM workspace_items wi
JOIN workspace_memberships wm ON wm.workspace_id = wi.workspace_id
  AND wm.user_id = :user_id AND wm.deleted_at IS NULL
JOIN workspaces w ON w.id = wi.workspace_id AND w.deleted_at IS NULL
WHERE wi.completed_at BETWEEN :window_start AND :window_end
  AND wi.deleted_at IS NULL
ORDER BY wi.completed_at DESC
LIMIT 11;

-- Comments mentioning the user
SELECT wi.*
FROM workspace_items wi
JOIN workspace_memberships wm ON wm.workspace_id = wi.workspace_id
  AND wm.user_id = :user_id AND wm.deleted_at IS NULL
JOIN workspaces w ON w.id = wi.workspace_id AND w.deleted_at IS NULL
WHERE wi.item_type = 'comment'
  AND :user_id = ANY(wi.mentioned_user_ids)
  AND wi.created_at BETWEEN :window_start AND :window_end
  AND wi.deleted_at IS NULL
ORDER BY wi.created_at DESC
LIMIT 11;
```

**Highlighted items selection:** The up-to-ten highlighted items are drawn from the union of all three categories, de-duplicated by `id`, sorted by recency, and capped at 10. If the total exceeds 10, "+N more" is appended in the email.

### 4.4 Empty-digest guard

If all three result sets are empty → `digest_sends.status = 'skipped'`, job exits, no email sent.

---

## 5. Email Delivery

### 5.1 SendGrid integration

The application uses the `sendgrid-ruby` gem (or equivalent HTTP client). A dedicated transactional template is used; dynamic template data is injected at send time.

```ruby
class DigestMailer
  def self.send_digest(user:, digest_data:, week_start:)
    client = SendGrid::API.new(api_key: ENV['SENDGRID_API_KEY'])

    mail = SendGrid::Mail.new
    mail.template_id = ENV['SENDGRID_DIGEST_TEMPLATE_ID']
    mail.from        = SendGrid::Email.new(email: 'digest@yourapp.com', name: 'YourApp')

    personalization = SendGrid::Personalization.new
    personalization.add_to(SendGrid::Email.new(email: user.email))
    personalization.add_dynamic_template_data({
      user_name:           user.display_name,
      week_label:          week_label(week_start),
      new_count:           digest_data[:new_count],
      completed_count:     digest_data[:completed_count],
      mentioned_count:     digest_data[:mentioned_count],
      highlighted_items:   digest_data[:highlighted_items],  # array of {title, url, type}
      more_count:          digest_data[:more_count],
      unsubscribe_url:     unsubscribe_url(user)
    })

    mail.add_personalization(personalization)

    # Custom header for idempotency tracking
    mail.add_header(SendGrid::Header.new(
      key:   'X-Digest-Week',
      value: "#{user.id}-#{week_start}"
    ))

    response = client.client.mail._('send').post(request_body: mail.to_json)
    raise SendGridError, response.body unless (200..299).cover?(response.status_code.to_i)

    response
  end
end
```

### 5.2 Unsubscribe URL

```ruby
def unsubscribe_url(user)
  Rails.application.routes.url_helpers.digest_unsubscribe_url(
    token: user.digest_unsubscribe_token,
    host:  ENV['APP_HOST']
  )
end
```

The token is a 32-byte URL-safe random string generated at account creation:

```ruby
SecureRandom.urlsafe_base64(32)
```

It is unique per user and not guessable. It is **not** tied to a session or expiry — clicking it at any time disables digest for that account. The token does not reveal the user's identity in the URL.

### 5.3 Unsubscribe endpoint

```
GET /digest/unsubscribe?token=<token>
```

Controller:
1. Look up `User` by `digest_unsubscribe_token`.
2. If not found → render generic "already unsubscribed" page (no error).
3. Set `digest_enabled = FALSE`, save.
4. Render confirmation page.

This is a GET (one-click) so it works from email clients that pre-fetch links for preview. Since it only ever disables (never enables) digest, pre-fetching is safe. Re-subscribing requires the user to go to account settings (out of scope for this feature).

---

## 6. Retry and Failure Handling

### 6.1 Sidekiq retry policy

`DigestBuildAndSendJob` is configured with a limited retry window. The blueprint states that a late digest is worse than a skipped one, so retries must be bounded in time.

```ruby
class DigestBuildAndSendJob
  include Sidekiq::Job

  sidekiq_options(
    retry: 3,          # at most 3 attempts
    dead:  false,      # don't move to dead queue
    queue: 'digest'
  )

  sidekiq_retry_in do |count, _exception|
    # Retry at 5m, 15m, 30m — total window < 1 hour
    [5 * 60, 15 * 60, 30 * 60][count] || 30 * 60
  end

  around_perform do |job, block|
    # Hard deadline: if more than 4 hours have passed since the intended
    # send time, mark as failed and abort rather than sending stale email.
    send_record = DigestSend.find_by(
      user_id: job.args[0],
      week_start: Date.parse(job.args[1])
    )

    if send_record&.created_at && send_record.created_at < 4.hours.ago
      send_record.update!(status: 'failed')
      return  # drop quietly
    end

    block.call
  end
end
```

After all retries are exhausted, the Sidekiq `sidekiq_retries_exhausted` callback marks `digest_sends.status = 'failed'`. The email is dropped for the week — consistent with the blueprint rule that a late digest is worse than no digest.

### 6.2 Status transitions

```
pending → sent      (happy path)
pending → skipped   (no activity, or user ineligible at job time)
pending → failed    (SendGrid error after all retries, or deadline exceeded)
```

There is no `retrying` state; Sidekiq manages that internally.

---

## 7. Idempotency Summary

| Layer | Mechanism |
|-------|-----------|
| Coordinator job | `INSERT ... ON CONFLICT DO NOTHING` on `digest_sends (user_id, week_start)` |
| Worker job | Check `status != 'sent'` at job start before doing any work |
| SendGrid | Custom `X-Digest-Week` header for provider-level dedup (best-effort) |
| Unsubscribe endpoint | Idempotent write: setting `digest_enabled = FALSE` twice is safe |

---

## 8. Security

### 8.1 Unsubscribe token

- 32-byte URL-safe random token: 256 bits of entropy, not guessable.
- Stored in `users.digest_unsubscribe_token` (plain text is acceptable; it is not a secret that protects high-stakes actions — worst case an attacker unsubscribes someone from a newsletter).
- One token per user: cannot be used to affect another user's account.
- No CSRF token needed for the GET endpoint because the action is unsubscribe-only and idempotent.

### 8.2 Permission-scoped content

All digest content queries join through `workspace_memberships` with `deleted_at IS NULL` and through `workspaces` with `deleted_at IS NULL`. A user will never see content from a workspace they have left or that has been deleted, even if the underlying `workspace_items` rows still exist.

### 8.3 Deleted workspace edge case

If a workspace is deleted between activity occurring and the digest job running, the workspace join (`w.deleted_at IS NULL`) filters out all items from that workspace. If all items belonged to the deleted workspace, the digest is empty and is skipped.

---

## 9. Key Flows (Sequence)

### 9.1 Happy path

```
[Sidekiq Cron]
  → DigestCoordinatorJob (runs hourly)
      → identifies users whose 08:00 Monday is in current UTC hour
      → INSERT INTO digest_sends ON CONFLICT DO NOTHING
      → enqueue DigestBuildAndSendJob(user_id, week_start)

[DigestBuildAndSendJob]
  → check digest_sends.status (exit if 'sent')
  → re-verify user eligibility
  → compute window [max(created_at, 7d ago), monday_00:00_local)
  → query new_items, completed_items, mentioned_items (permission-scoped)
  → if all empty → update status='skipped', exit
  → assemble digest_data (highlight top 10, compute counts)
  → DigestMailer.send_digest(...)  → SendGrid API call
  → update digest_sends.status = 'sent', sendgrid_message_id = <id>
```

### 9.2 Unsubscribe flow

```
User clicks link in email footer
  → GET /digest/unsubscribe?token=<token>
  → User.find_by(digest_unsubscribe_token: token)
  → user.update!(digest_enabled: false)
  → render "You've been unsubscribed"
```

---

## 10. Observability

| Signal | How |
|--------|-----|
| Digests sent per week | Count of `digest_sends WHERE status='sent'` |
| Digests skipped (no activity) | Count of `digest_sends WHERE status='skipped'` |
| Delivery failures | Count of `digest_sends WHERE status='failed'`; alert if > threshold |
| SendGrid delivery events | Webhook → log bounces, opens, unsubscribes |
| Job queue depth | Sidekiq Web UI / Prometheus exporter on the `digest` queue |
| Coordinator job health | Sidekiq-Cron job last-run timestamp; alert if missed |

---

## 11. Database Indexes

```sql
-- Fast lookup for coordinator: users eligible for digest in a timezone
CREATE INDEX idx_users_digest_tz ON users (timezone, digest_enabled)
  WHERE digest_enabled = TRUE;

-- Fast idempotency check
CREATE UNIQUE INDEX idx_digest_sends_user_week
  ON digest_sends (user_id, week_start);

-- Dashboard / monitoring queries
CREATE INDEX idx_digest_sends_week_status
  ON digest_sends (week_start, status);

-- Activity queries
CREATE INDEX idx_workspace_items_created_at ON workspace_items (workspace_id, created_at)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_workspace_items_completed_at ON workspace_items (workspace_id, completed_at)
  WHERE completed_at IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX idx_workspace_items_mentions ON workspace_items
  USING GIN (mentioned_user_ids)
  WHERE item_type = 'comment' AND deleted_at IS NULL;
```

---

## 12. Scaling Considerations

- **Fan-out size:** At peak, all users in one UTC offset fire together. The coordinator job fans out one Sidekiq job per user; Sidekiq handles the concurrency with the `digest` queue worker pool.
- **Queue isolation:** The `digest` queue uses dedicated workers so digest fan-out does not starve other queues.
- **Batch enqueue:** If user count is very large (>100k), the coordinator should use cursor-based batching to avoid loading all users into memory at once.
- **Database load:** Activity queries run across the digest send window (~08:00 in each timezone). Proper indexing (§11) keeps individual queries fast; the overall load is spread across 24 hours due to timezone fan-out.
- **SendGrid rate limits:** Use Sidekiq throttling (e.g., `sidekiq-throttled` gem) on the `digest` queue to respect SendGrid's per-second API limits.

---

## 13. Out of Scope (per Blueprint)

- Daily or monthly digest frequencies.
- User customization of which activity types appear in the digest.
- In-app rendering of the digest content.
