# Run Notes — GitHub Contributions Widget System Design

**Run:** iteration-2 / eval-0 / with_skill / run-1 · **Date:** 2026-05-23

## Key decisions made autonomously

1. **Store-and-serve over live fetch.** The user's prompt explicitly said "avoid hammering the GitHub API." Store-and-serve was the clear answer; no fork to resolve.
2. **Postgres as the cache store (no Redis).** A single-row PK lookup is fast enough; Redis would add invalidation complexity with no latency benefit at this scale. Chose simplicity.
3. **DB timestamp for cooldown enforcement** (not a Redis TTL key) — race-safe via `select_for_update()`; avoids a new dependency.
4. **202 + manual reload after Refresh** (not real-time push) — no WebSocket infrastructure assumed; a short client-side polling loop noted as the upgrade path.
5. **Hard delete on disconnect** — blueprint is unambiguous; soft-delete adds complexity with no benefit.
6. **GitHub GraphQL over REST** — REST does not expose the contribution graph natively; no real choice here.

## Things I would have asked a human

- Whether field-level encryption already exists in the project, and which library to use.
- Whether Celery Beat is already configured, or needs to be added.
- Whether a 202 + manual reload is acceptable Refresh UX, or whether the product expects an in-page update.
- Whether one GitHub account is allowed to connect to multiple platform accounts (unique constraint decision).
- Whether private contributions appearing on a public profile is intentional product behavior.
- Confirm GDPR deletion pipeline includes the new tables.
