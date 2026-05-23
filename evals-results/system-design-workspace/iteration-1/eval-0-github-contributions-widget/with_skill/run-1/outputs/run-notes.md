# Run Notes — GitHub Contributions Widget System Design

**Mode:** Autonomous (no human interviewee)

## Key decisions made autonomously

1. **Lazy refresh over Celery Beat sweep.** The user's explicit "avoid hammering the GitHub API" constraint pointed strongly here. Chose read-time staleness check + enqueue, not a periodic sweep.

2. **Redis for cooldown enforcement, with Postgres fallback.** Assumed Redis is available (it's the common Celery broker). Fail-open behavior on Redis unavailability is documented as an accepted compromise.

3. **GraphQL over REST for GitHub API.** Single-request data retrieval, lower call count, richer contribution primitives.

4. **Single-row upsert snapshot (no history).** Blueprint asks for current state only. YAGNI applied.

5. **Global feature flag** (not per-user) for initial rollout.

6. **Frontend polls for task completion** after refresh enqueue — no SSE/WebSocket added.

## What I would have asked a human

- Is Redis confirmed in the stack, or should the design be Redis-free?
- Is there an existing Django social-auth library (allauth, python-social-auth) to reuse for the OAuth flow?
- Is there an existing field-level encryption utility for sensitive DB columns?
- What is the existing feature-flag system and naming convention?
- Which module/app is the right home — new `github_widget` app or a submodule of `integrations`?
- Is the profile privacy flag accessible at `user.profile.is_private` or some other path?
