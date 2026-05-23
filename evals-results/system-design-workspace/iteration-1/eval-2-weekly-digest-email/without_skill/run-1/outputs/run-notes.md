# Run Notes

**Date:** 2026-05-23

## Key Decisions and Assumptions

**Timezone fan-out strategy:** Blueprint says "8:00 AM in each user's timezone." I chose a Sidekiq-Cron coordinator that fires hourly (and at :30 for sub-hour offsets) rather than pre-scheduling 24 per-timezone jobs. This keeps the scheduler simple and handles DST transitions automatically.

**`week_start` as UTC Monday date:** The idempotency key uses the UTC calendar Monday, not the local Monday, to keep the DB column a simple DATE. All local-time calculations are done in Ruby using the user's timezone.

**Retry deadline = 4 hours:** Blueprint says late digest is worse than no digest but gives no hard number. I chose 4 hours as a reasonable cut-off that covers normal transient failures while preventing afternoon delivery.

**Unsubscribe token as plain-text random string:** No HMAC or session binding needed; the worst-case misuse is unsubscribing someone from a weekly email, not a high-stakes action.

**`workspace_memberships` and `workspaces` join for permission scoping:** Assumed these tables exist with a `deleted_at` soft-delete column, consistent with standard Rails/ActiveRecord conventions.

**Highlighted items: de-duped union of all three activity categories, sorted by recency.** Blueprint only specifies recency ordering; I assumed cross-category de-duplication by item ID.
