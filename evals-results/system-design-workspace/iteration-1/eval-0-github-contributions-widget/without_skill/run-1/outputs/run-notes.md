# Run Notes — GitHub Contributions Widget System Design

**Date:** 2026-05-23  
**Model:** claude-sonnet-4-6

## Key Decisions and Assumptions

**No Redis introduced.** The cooldown check is a single DB read; adding Redis for one timestamp felt like unnecessary operational overhead.

**GraphQL over REST.** GitHub's GraphQL `contributionsCollection` returns the full calendar in one call at ~1 point cost, cleaner than assembling it from multiple REST endpoints.

**One cache row per user (upsert pattern).** Rather than appending snapshot history, we overwrite the single `GitHubContributionCache` row on each fetch. The blueprint only ever needs the latest 12-month window, so history is wasted storage.

**Token encryption via django-fernet-fields.** Blueprint is silent on the encryption library; this is the standard Django choice for encrypted model fields.

**`SELECT FOR UPDATE` on cooldown check.** Prevents a race condition where two simultaneous refresh requests both pass the 60-minute gate. Blueprint flagged scripted bypasses as adversarial; this closes the gap.

**Celery Beat for automatic 24-hour refresh.** The blueprint says data is "fresh enough" under 24 hours; a periodic Beat task sweeping for stale records every hour keeps data within ~25 hours old without any visitor-triggered fetch.

**HTTP `Cache-Control: max-age=300` on public profile endpoint.** Short CDN cache avoids thundering-herd on popular profiles while keeping staleness acceptable.
