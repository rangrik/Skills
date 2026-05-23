# Run Notes — Weekly Digest Email System Design

**Run date:** 2026-05-23 · **Mode:** Fully autonomous (no human available for P3/P4 interview)

## Key decisions made autonomously

1. **Per-minute cron fan-out** chosen over a single Monday batch job — avoids thundering-herd; handles timezone diversity naturally. Straightforward given Sidekiq + timezone-per-user constraints.

2. **`digest_sends` unique constraint** as the idempotency gate — the most reliable option given the "job triggered twice" deviation scenario in the blueprint. Redis locks considered and rejected (expiry risk).

3. **HMAC-signed unsubscribe token** (no token table) — YAGNI + satisfies the adversarial non-guessable/account-scoped requirement cleanly.

4. **Live activity query at job time** — no pre-aggregation. YAGNI; background job context tolerates latency.

5. **3 retries then drop** — directly mandated by blueprint's failure policy ("late digest is worse than skipped").

## What I would have asked a human

- **Activity table names and schema** — the blueprint references "new items, completed items, comments mentioning them" but does not name tables. This is a genuine schema gap that could require significant query redesign.
- **Comment mention storage** — is a mentionee stored as a FK, or parsed from body text?
- **Existing mailer/ActionMailer setup** — assumed but not confirmed.
- **Percentage-ramp preference** — decided binary on/off was sufficient; a human might want staged rollout.
