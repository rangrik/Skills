# Run Notes — Weekly Digest System Design (Autonomous)

**Date:** 2026-05-23 · **Run:** iteration-2 / eval-2 / run-1

## Key autonomous decisions

1. **Fan-out architecture** — chose per-user Sidekiq jobs over a single batch loop; independent retryability and partial-failure isolation outweighed the job-count overhead.
2. **Unique-constraint dedup** — `digest_sends(user_id, iso_week)` with `UNIQUE` constraint was chosen over Redis distributed locks or user-row flags; atomic and durable with no extra infrastructure.
3. **Hourly timezone bucketing** — accepted ±59 min send-time precision as reasonable for a non-time-sensitive weekly notification; avoids per-user scheduling complexity.
4. **HMAC-signed stateless unsubscribe tokens** — encoding `user_id` + `iso_week` in the payload; no revocation table needed given weekly expiry.
5. **No activity cache** — each user's digest is assembled fresh; caching provides near-zero reuse and adds unnecessary complexity.

## What I would have asked a human

1. Is sub-hour send-time precision acceptable, or is exact 8:00 AM required?
2. What is the exact schema of the activity/events table?
3. Is Sidekiq-Cron (or which scheduling library) already in the stack?
4. Are there compliance or regulatory requirements that demand revocable unsubscribe tokens?
5. What is the confirmed user scale (to validate 100k assumption)?
