# System Design: GitHub Contributions Widget

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../../../../../inputs/github-contributions-blueprint.md](../../../../../inputs/github-contributions-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

> **Off-repo note:** The `kite-arch-compass` authoritative standard is not applicable here (this is not the appsmith-v2 / Kite repo). All decisions are grounded in the generic `design-principles.md` lens, cited by principle name. Every recommendation that would normally cite a Kite principle number instead cites the generic principle by name.

---

## 1. Summary

The GitHub Contributions Widget is a read-heavy, third-party-data display feature. The core architectural choice is a **background-cache model**: contribution data is fetched from GitHub asynchronously via a Celery task, stored in Postgres, and served directly from the database on every page load — visitors never hit the GitHub API. A 24-hour TTL governs automatic staleness; the profile owner can trigger an on-demand refresh subject to a 1-hour per-user cooldown enforced in Redis. This design satisfies the explicit "avoid hammering the GitHub API" constraint, protects against GitHub rate limits, keeps the public profile page fast (a single DB read), and degrades gracefully when GitHub is unreachable.

---

## 2. System Placement

The feature spans three layers of the Django + Postgres + Celery + React stack:

```
Browser (React)
    │
    │  REST API calls
    ▼
Django (HTTP layer)
    ├── GET  /api/profile/<user_id>/github-contributions/   → serve cached data
    ├── POST /api/profile/github/oauth/callback/            → handle OAuth return
    ├── POST /api/profile/github/disconnect/                → disconnect + purge
    └── POST /api/profile/github/refresh/                   → enqueue manual refresh
         │
         │  enqueue task
         ▼
    Celery Worker
         └── tasks.fetch_github_contributions(user_id)
              │
              │  GitHub GraphQL API (read-only)
              ▼
         GitHub API
              │
              │  write result
              ▼
         Postgres
              ├── GitHubConnection (tokens, account linkage)
              └── GitHubContributionSnapshot (cached grid data)

    Redis
         └── cooldown key:  github_refresh_cooldown:<user_id>
```

**Touched components:**
- New Django app `github_widget` (or module inside an existing `integrations` app, per team convention — see Assumption A1)
- New Celery task `fetch_github_contributions`
- New Postgres tables (2)
- Redis (existing, assumed present — see Assumption A2)
- React: new `GitHubContributionsWidget` component, new `GitHubConnectButton` component

---

## 3. Architecture Decisions

### D1. Store contribution data in Postgres; serve visitors from DB only

- **Decision:** Contribution data (the 53-week grid, totals, streaks) is fetched from GitHub by a background worker and persisted in Postgres. All reads — by the profile owner and by any visitor — are served from this snapshot. No read request, from any user, ever triggers a live GitHub API call.
- **Why:** The blueprint's freshness rule ("fresh enough if less than 24 hours old") and adversarial rule ("a visitor should never trigger a fetch") together mandate a cache-first read path. This aligns with **Principle 13 (Cache invalidation is a design decision)** — the cache is the DB row itself, with an explicit `fetched_at` timestamp as the TTL anchor — and **Principle 12 (Cost as a first-class constraint)** — GitHub API calls are rate-limited; funneling all reads through the DB eliminates runaway cost.
- **Alternatives considered:**
  - *Fetch from GitHub on profile page load (visitor triggers):* Rejected. Violates the adversarial rule from the blueprint, hammers the GitHub API proportionally to profile views, and exposes the latency of a GitHub API call to every visitor.
  - *Store in Redis only (no Postgres):* Rejected. Redis is not the right durability layer for data that survives restarts, is queried in Django ORM, and needs to co-locate with the OAuth token record. Principle 4 (Get the data model right) favors Postgres.
- **Trade-off accepted:** Data shown to visitors can be up to 24 hours stale. This is explicitly allowed by the blueprint and is the core freshness-vs-cost trade-off the product owner accepted.

---

### D2. Fetch contributions via GitHub GraphQL API using the stored OAuth token

- **Decision:** Use the GitHub GraphQL API (specifically the `contributionsCollection` query on the authenticated user) to retrieve contribution data. The OAuth access token stored in `GitHubConnection` is passed as a bearer token. The connection is identified by GitHub account ID (not username), matching the blueprint's rename-resilience requirement.
- **Why:** The GitHub GraphQL API can return the full contribution collection — grid, totals, streaks — in a single request, minimizing API calls per refresh cycle (Principle 6 — bounded operations). Username-based lookups would break on rename; account ID is stable. Principle 11 (Security & privacy) — the token is only used by the background worker in a server-side context; it never touches the browser.
- **Alternatives considered:**
  - *GitHub REST API:* Multiple endpoints needed (commits, events) with no direct streak/grid primitive; higher call count, lower data fidelity. GraphQL is the right fit.
  - *Scraping the public contribution SVG:* Fragile, unsupported, potentially violates ToS. Rejected.
- **Trade-off accepted:** The GraphQL `contributionsCollection` returns only public contributions unless the token has private `repo` scope. The blueprint explicitly accepts this: "reflects whatever the GitHub API returns for the authorized scope." We request only `read:user` scope; private contributions are out of scope by design.

---

### D3. Background fetch via Celery task; no synchronous GitHub calls in the request path

- **Decision:** All GitHub API calls happen in a Celery task (`fetch_github_contributions`). The HTTP endpoints that trigger fetches (auto-refresh on expiry, manual refresh) enqueue the task and return immediately. The frontend polls for completion.
- **Why:** GitHub API calls can take 1–5 seconds and can fail. Keeping them out of the request path prevents slow GitHub responses from degrading page load (Principle 1 — simplicity, fewer failure modes in the critical path; Principle 5 — design for failure). Celery is the existing async primitive in this stack (Principle 2 — match existing patterns).
- **Alternatives considered:**
  - *Synchronous fetch in the Django view on first load:* Adds GitHub latency to page load, blocks the request worker thread during a GitHub outage, and violates "visitors never trigger a fetch." Rejected.
  - *Django async views with httpx:* Could work but adds novelty and doesn't fit the existing Celery pattern. Principle 2 steers away.
- **Trade-off accepted:** After connecting GitHub, the owner sees a "loading" or "pending" state briefly while the first Celery task runs. This is a mild UX cost in exchange for a much simpler, more resilient system.

---

### D4. Cooldown enforced via Redis key with TTL; not purely in Postgres

- **Decision:** The 1-hour manual refresh cooldown is enforced by setting a Redis key `github_refresh_cooldown:<user_id>` with a 3600-second TTL when a refresh is triggered. The `POST /api/profile/github/refresh/` endpoint checks this key before enqueuing; if present, it returns 429. The cooldown expiry time is stored in Postgres alongside the snapshot record (as `manual_refresh_available_at`) so the frontend can display the countdown without polling Redis.
- **Why:** Redis TTL is the natural primitive for expiring rate-limit state — it requires no cron, no expiry column sweeps, and the key vanishes automatically (Principle 1 — fewest moving parts for this behavior; Principle 6 — bounded, rate-limited operations). Storing `manual_refresh_available_at` in Postgres is a cheap denormalization that lets the frontend render the cooldown timer from the same DB read that serves the widget — no extra round-trip.
- **Alternatives considered:**
  - *Enforce cooldown purely in Postgres (`last_manual_refresh_at` column + arithmetic):* Works, but requires a DB write and read on every refresh attempt rather than a Redis check. Also, stale rows could accumulate if cleanup is not handled. Redis is simpler and more reliable for this pattern.
  - *Enforce cooldown in application logic only (no Redis):* Race-prone across multiple Django processes. The blueprint's adversarial scenario ("scripting the request") requires a server-side, cross-process lock. Redis is the right answer.
- **Trade-off accepted:** We now depend on Redis being available to enforce the cooldown. If Redis is down, the fallback is to allow the refresh (fail-open on cooldown) and rely on GitHub's own rate limiting as a backstop — see §7 for the failure handling detail. This is acceptable given that Redis is assumed to already be in the stack.

---

### D5. Auto-refresh triggered by age check at read time, not by a periodic beat task

- **Decision:** When the `GET /api/profile/<user_id>/github-contributions/` endpoint is called, it checks `fetched_at` on the snapshot. If the snapshot is older than 24 hours AND the user has a valid GitHub connection, it enqueues a background refresh task. It still returns the stale snapshot immediately. It does not enqueue if a task is already pending (idempotency guard via a Redis lock key `github_fetch_in_flight:<user_id>`).
- **Why:** A Celery Beat periodic task that sweeps all connected users would be simpler in principle but creates unnecessary load and complexity for a feature that may have few active users initially (Principle 1 — YAGNI; Principle 8 — measure, don't guess). Read-time lazy refresh means we only refresh profiles that are actually being viewed, which is the right proportionality given GitHub API rate limits (Principle 12). The in-flight guard prevents duplicate tasks from piling up.
- **Alternatives considered:**
  - *Celery Beat periodic task sweeping all stale connections:* Scales poorly as users grow; fetches data for profiles that may never be viewed; requires maintaining a beat schedule and a sweep query. Preferred approach is simpler at current scale. Can be added later if needed (Principle 7 — reversible decisions).
  - *Push via webhook from GitHub:* GitHub does not offer a "contributions updated" webhook. Not viable.
- **Trade-off accepted:** If a profile has had no visitors for more than 24 hours, the next visitor will see stale data (up to the previous snapshot age) and trigger a background refresh that the visitor won't see the result of. The blueprint permits this: visitors always see stored data. This is the explicit freshness contract.

---

### D6. OAuth flow uses the standard Django redirect pattern; tokens stored encrypted in Postgres

- **Decision:** The GitHub OAuth flow uses Django's standard redirect-based OAuth: the user is sent to GitHub's authorization URL, GitHub redirects back to our callback endpoint with a `code`, the backend exchanges it for an access token, and stores the token (encrypted at rest, see §8) in `GitHubConnection`. The connection record holds the GitHub account ID (not username) and the access token.
- **Why:** Standard OAuth PKCE/redirect is the correct pattern for server-side token acquisition. Storing by account ID is mandated by the blueprint (rename resilience). Encrypting the token at rest is required by Principle 11 (Security & privacy — secrets are first-class). Principle 2 (match existing patterns) — if the app already has a social auth library (e.g. `python-social-auth` or `django-allauth`), use it; see Assumption A3.
- **Alternatives considered:**
  - *Store token in the session only:* Token would be lost on logout. Background tasks need the token independently of user sessions. Rejected.
  - *Use GitHub Apps instead of OAuth Apps:* GitHub Apps offer finer-grained permissions but require installation and are scoped to repos/orgs, not user contribution graphs. OAuth App with `read:user` scope is the right fit.
- **Trade-off accepted:** We store an OAuth access token in our database. This is a sensitive secret that requires encryption, careful access control, and a clear revocation path — all addressed in §8. The alternative (not storing it) is incompatible with background refresh.

---

## 4. Data Model & Persistence

### Table: `github_connections`

Stores the OAuth link between a platform user and their GitHub account.

```sql
CREATE TABLE github_connections (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    github_account_id   VARCHAR(64) NOT NULL,   -- GitHub's stable numeric user ID
    github_username     VARCHAR(255),            -- denormalized for display only; not used for lookups
    access_token_enc    BYTEA NOT NULL,          -- encrypted access token
    token_scopes        VARCHAR(255),            -- e.g. "read:user"
    connected_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_token_check_at TIMESTAMPTZ,             -- last time the token was verified live
    token_status        VARCHAR(16) NOT NULL DEFAULT 'active'
                            CHECK (token_status IN ('active', 'revoked', 'expired'))
);

CREATE INDEX idx_github_connections_user_id ON github_connections(user_id);
```

**Invariants:**
- One connection per user (`UNIQUE` on `user_id`). A user connecting a second GitHub account replaces the first.
- `github_account_id` is immutable after insert (a rename does not change it; reconnecting with a different account should update all fields atomically).
- `access_token_enc` is never readable in API responses.

---

### Table: `github_contribution_snapshots`

Stores the most recent fetched contribution data for a connected user.

```sql
CREATE TABLE github_contribution_snapshots (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    fetched_at      TIMESTAMPTZ NOT NULL,
    fetch_period_start  DATE NOT NULL,          -- first day of the 53-week window fetched
    fetch_period_end    DATE NOT NULL,          -- last day of the 53-week window (≈ today at fetch time)
    total_contributions INT NOT NULL DEFAULT 0,
    current_streak  INT NOT NULL DEFAULT 0,
    longest_streak  INT NOT NULL DEFAULT 0,
    weeks_json      JSONB NOT NULL,             -- array of 53 week objects: [{week_start, days:[{date,count}]}]
    fetch_status    VARCHAR(16) NOT NULL DEFAULT 'ok'
                        CHECK (fetch_status IN ('ok', 'error', 'pending')),
    last_error      TEXT,                       -- populated on fetch_status='error'
    manual_refresh_available_at TIMESTAMPTZ,    -- when the 1-hour cooldown expires; NULL = available now
    CONSTRAINT fk_snapshot_connection
        FOREIGN KEY (user_id) REFERENCES github_connections(user_id) ON DELETE CASCADE
);

CREATE INDEX idx_snapshots_user_id ON github_contribution_snapshots(user_id);
CREATE INDEX idx_snapshots_fetched_at ON github_contribution_snapshots(fetched_at)
    WHERE fetch_status = 'ok';
```

**Invariants:**
- One snapshot per user (`UNIQUE` on `user_id`). Each fetch is an upsert (INSERT … ON CONFLICT DO UPDATE).
- `weeks_json` is the canonical representation of the grid; the frontend derives the color buckets from the raw counts.
- On disconnect (`DELETE` from `github_connections`), both tables cascade-delete automatically. No orphaned data.
- `fetch_status = 'pending'` is a transient state set at task enqueue time, replaced by `'ok'` or `'error'` on completion.

---

### Migration shape

Two migrations, applied in order:
1. `0001_create_github_connections.py`
2. `0002_create_github_contribution_snapshots.py`

No backfill needed (new tables, no existing data). Both migrations are safe for zero-downtime deploy: additive only, no column drops or type changes.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| GitHub OAuth API (`github.com/login/oauth`) | Exchange authorization code for access token during connect flow | N/A for the user; our app's `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` in environment (never in DB or logs) | Not metered; standard OAuth flow, one call per connect action | Network failure: return error to user, OAuth flow aborted, no state written. Connection not created. | Mock the token-exchange endpoint in integration tests; use `responses` library or `httpretty`. |
| GitHub GraphQL API (`api.github.com/graphql`) | Fetch contribution data (grid, totals, streaks) | Per-user OAuth bearer token (stored encrypted) | 5,000 points/hour per authenticated user (GraphQL cost: ~1 point per contributionsCollection query). No monetary cost. | Rate-limit (429): task marks `fetch_status='error'`, cooldown still applies, user sees "Couldn't refresh right now"; GitHub down: same degradation, last snapshot shown. Token revoked/expired: `token_status` updated to `revoked`/`expired`, owner sees reconnect prompt. | Mock with a fixture response in unit tests. Integration tests use a VCR cassette or a test GitHub account. |

**Grammar note:** The GitHub GraphQL query structure (field names, pagination, date arithmetic for the 53-week window) is encoding-sensitive and should be covered by a probe-tested utility/fixture — not left to ad-hoc inline strings in the task. The recommended follow-up is a `github_graphql_contrib.py` helper module with a test that exercises the real query shape against a pinned fixture.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| Public profile page load (widget read) | < 50 ms | < 100 ms | Single indexed DB read; no GitHub call |
| Manual refresh enqueue (POST /refresh) | < 80 ms | < 150 ms | Redis check + Celery enqueue; no GitHub call |
| Background fetch task (Celery) | < 3 s | < 8 s | One GitHub GraphQL call + DB upsert; not user-visible |
| OAuth connect callback | < 300 ms | < 800 ms | One GitHub token exchange call |

### Expected load and scale

- Assumption: the platform has up to 100k registered users; GitHub connection adoption is estimated at 10–20% = 10–20k connected users (see Assumption A4).
- Profile page views: assumed up to 1M/day across all profiles. Widget reads are pure DB reads; Postgres easily handles this at current scale.
- Background task volume: at 24-hour TTL, the task queue sees at most ~20k tasks/day (one per connected user per viewed profile per day) — roughly 0.23 tasks/second average, well within Celery + Postgres capacity.
- GitHub API: at ~20k connected users, worst-case is 20k API calls/day. Per the rate limit (5,000 points/hour/user), each user's calls are individually rate-limited — there is no shared pool risk. The lazy refresh model (only refresh viewed profiles) means actual call volume is much lower.

### Caching strategy

The **primary cache is the `github_contribution_snapshots` table itself** — a single DB row per user. There is no separate Redis or in-memory cache for contribution data; the DB read is fast enough given the index.

| What | Where | TTL / invalidation | Freshness trade-off |
|---|---|---|---|
| Contribution grid, totals, streaks | Postgres (`github_contribution_snapshots`) | 24 hours (`fetched_at` age check); invalidated by manual refresh | Visitors see data up to 24 h stale — explicitly accepted by blueprint |
| Manual refresh cooldown | Redis (`github_refresh_cooldown:<user_id>`) | 3600 s TTL, auto-expiry | Exact; Redis TTL is the source of truth |
| In-flight fetch guard | Redis (`github_fetch_in_flight:<user_id>`) | 60 s TTL (auto-expire as safety net) | Prevents duplicate tasks; released on task completion |

**Principle 13 applied:** All five questions answered above (what, where, TTL, invalidation, freshness trade-off).

---

## 7. Reliability & Failure Handling

### GitHub API failure during background task

- **Behavior:** The Celery task catches all GitHub API exceptions (network timeout, 5xx, rate limit 429, token error 401).
- **Retry policy:** On transient errors (5xx, network), retry up to 3 times with exponential backoff (2 s, 8 s, 32 s). On rate limit (429), respect the `Retry-After` header; use Celery's `countdown` to reschedule. On auth error (401), do not retry — update `token_status` to `'revoked'` or `'expired'` and set `fetch_status = 'error'`.
- **User experience:** The last successfully stored snapshot is always served. The `"Last updated <time>"` label (from `fetched_at`) is shown on the widget (blueprint deviation scenario). Visitors see no error. The owner sees "Couldn't refresh right now, try again later" for rate-limit/transient failures and "Reconnect GitHub" for token errors.
- **Idempotency:** The fetch task is idempotent — it always issues the same query and upserts the result. Safe to retry without data corruption.

### Redis failure (cooldown enforcement)

- **Behavior:** If Redis is unavailable, the cooldown check fails open: the refresh is allowed. This is a deliberate fail-open choice (see D4) — GitHub's own rate limiter is the backstop.
- **Alternative guarded behavior:** If this is considered unacceptable, fall back to checking `manual_refresh_available_at` in Postgres. This is the secondary guard, always written regardless of Redis state.

### GitHub OAuth callback failure

- **Behavior:** If the token exchange call fails, the user sees an error page/message ("Couldn't connect GitHub — please try again"). No `GitHubConnection` record is written. The "Connect GitHub" button remains available.

### Postgres unavailable

- The widget degrades to an error state for visitors (no data to show). This is a platform-wide failure mode, not widget-specific.

### Timeouts

- GitHub API call: 10 s connect timeout, 30 s read timeout. If the read timeout fires, the task fails and retries per the policy above.
- The Celery task has a `soft_time_limit=60s` and `time_limit=90s`.

---

## 8. Security & Privacy

### Authentication and authorization

- **Widget read endpoint (`GET /api/profile/<user_id>/github-contributions/`):** Public (no auth required) for users whose profile is public. The backend enforces the profile privacy flag — if the profile is set to private, the endpoint returns 404 (not 403, to avoid confirming the user exists).
- **Refresh endpoint (`POST /api/profile/github/refresh/`):** Requires authentication AND ownership check (`request.user.id == user_id`). The server verifies both; the frontend guard is not trusted.
- **Disconnect endpoint:** Requires authentication + ownership.
- **OAuth callback:** Uses a `state` parameter (CSRF token) to prevent CSRF attacks on the OAuth flow. The `state` is a signed, short-lived token stored in the session at redirect-out time.

### Adversarial scenarios (from blueprint)

| Scenario | Mitigation |
|---|---|
| Visitor triggers a data fetch | Visitors hit a pure DB-read endpoint. No fetch is ever triggered by an unauthenticated or non-owner request. |
| Visitor sees another user's GitHub token | The token is stored encrypted in Postgres and never serialized in any API response. The widget read endpoint returns only contribution data, not connection metadata. |
| Member scripts around cooldown | Cooldown enforced server-side via Redis key. Rate-limiting is per `user_id` (not per IP), so proxying doesn't help the attacker. The API should also apply standard Django rate-limiting middleware (e.g. `django-ratelimit`) on the refresh endpoint. |

### Secrets handling

- `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` are environment variables, never stored in the DB or logged.
- Per-user OAuth access tokens are encrypted at rest using a symmetric key (e.g. Fernet / `cryptography` library) before writing to `access_token_enc`. The encryption key is an environment variable (`GITHUB_TOKEN_ENCRYPTION_KEY`).
- Tokens are never included in logs, error messages, or API responses.
- On disconnect, the access token is deleted from the DB immediately. A best-effort call to revoke the token on GitHub (`DELETE /applications/{client_id}/token`) is made; failure to revoke on GitHub is logged but does not block the disconnect.

### PII

- `github_username` (display only, denormalized) is PII-adjacent. It is served as part of the widget display but not used for lookups.
- On account deletion, both tables cascade-delete via the `users(id)` foreign key.

---

## 9. Observability

### Metrics (all prefixed `github_widget.`)

| Metric | Type | What it tells us |
|---|---|---|
| `fetch_task.enqueued` | Counter | How many background fetches are being requested |
| `fetch_task.succeeded` | Counter | Successful GitHub API calls |
| `fetch_task.failed` | Counter, tagged with `reason` (timeout, rate_limit, auth_error, other) | Where fetches are breaking |
| `fetch_task.duration_seconds` | Histogram | GitHub API + DB write latency |
| `refresh_cooldown.rejected` | Counter | How often the cooldown gate fires (anti-abuse signal) |
| `oauth_connect.succeeded` / `failed` | Counter | Connect flow health |
| `token_revoked.detected` | Counter | Token health signal; spike = GitHub integration issue |

### Logs

- Task start/end with `user_id` (hashed), outcome, GitHub API response time, and any error code. No tokens in logs.
- Cooldown enforcement log entry on rejection (rate, anti-abuse audit trail).

### Traces

- The Celery task should carry a trace ID from the enqueuing request (passed as task kwargs) so the refresh flow can be traced end-to-end.

### The one health signal

**`fetch_task.failed` rate > 5% over a 15-minute window** is the primary alert. It indicates either GitHub API degradation, a token revocation wave, or a code regression. Secondary alert: **`fetch_task.duration_seconds` p95 > 10 s**.

### Dashboard

A single dashboard with: fetch success rate, fetch duration p50/p95, token revocation rate, cooldown rejection rate, OAuth connect funnel (started vs completed).

---

## 10. Rollout & Operability

### Feature flag

Gate the entire feature behind a flag `GITHUB_WIDGET_ENABLED` (Django setting or a feature-flag system if one exists — see Assumption A5). Default: `False` (off). This controls:
- Whether the "Connect GitHub" button appears in profile settings.
- Whether the widget endpoint is reachable.
- Whether the Celery task is enqueued.

The flag does not need to be per-user for initial rollout; a global enable/disable is sufficient. Per-user percentage rollout can be added via the flag system if desired.

### Deploy order

1. **Backend + migrations first:** Deploy `github_connections` and `github_contribution_snapshots` tables. Flag is off; no traffic touches the new code.
2. **Celery workers deploy:** New task registered. No tasks enqueued yet.
3. **Frontend deploy:** New components deployed but hidden behind the flag.
4. **Enable flag** for internal users / staff → validate OAuth flow, widget render, refresh, disconnect.
5. **Staged rollout:** Enable for 5% → 25% → 100% of users.

### Reversibility

- Flag can be turned off at any time. The DB tables and data remain (no data loss on flag-off).
- Full removal: turn off flag, drain any pending Celery tasks, drop the two tables, remove the Celery task and routes. Clean two-way door up until public GA; after GA, the data in `github_connections` represents user intent and deleting it would require a user-facing notice.

### No backward-compatibility concerns

This is a net-new feature with new tables and new routes. It does not modify any existing schema, contract, or API.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | A new `github_widget` Django app (or module inside `integrations`) is the right home for this code | The feature is self-contained enough to warrant its own module. If an `integrations` app already exists with similar patterns, nesting there follows Principle 2. | Yes — confirm naming convention with the team |
| A2 | Redis is already in the stack (used for Celery broker and/or session caching) | The task states "Django + Postgres + Celery"; Celery almost universally uses Redis or RabbitMQ as a broker; Redis is the most common choice. Cooldown enforcement requires a shared, ephemeral, TTL-aware store. | Yes — confirm Redis is available; if not, fall back to a Postgres-based cooldown with `manual_refresh_available_at` column (still works, slightly more write load) |
| A3 | No existing social auth library (django-allauth / python-social-auth) is in the stack | The task description doesn't mention one. If one exists, the OAuth callback pattern should reuse it rather than implement a bespoke exchange. | Yes — check for existing OAuth infrastructure |
| A4 | Platform has ≤100k users at current scale; GitHub adoption ~10–20% | Reasonable for a mid-sized developer platform. Informs the background task load estimate. | No — design is not scale-sensitive at this range; revisit at 1M+ connected users |
| A5 | A feature-flag mechanism exists (Django setting, Waffle, LaunchDarkly, or similar) | Nearly universal in production Django apps. The exact primitive doesn't change the design. | Yes — confirm the flag system and flag naming convention |
| A6 | The `users` table has an `id` (BIGINT) primary key that both new tables can reference | Standard Django model assumption. | No |
| A7 | The profile "public vs private" flag is already modeled on the `users` or `profiles` table | The blueprint references it as an existing platform concept. | Yes — confirm the column/field name for the privacy check |
| A8 | OAuth scope `read:user` is sufficient to access `contributionsCollection` via GraphQL | The GitHub GraphQL API returns public contribution data with `read:user`. Private contributions are not requested. | Yes — verify against GitHub API docs before implementation |
| A9 | The Celery worker tier has outbound internet access to `api.github.com` | Required for background fetches. Most production Celery workers do; some have egress restrictions. | Yes — confirm network policy |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | No periodic Celery Beat sweep; lazy read-time refresh only | Data for unvisited profiles goes stale indefinitely | Principle 8 (Measure, don't guess) — we're not optimizing for freshness of unvisited profiles | The product rule ("fresh if < 24 hours") only matters when someone is looking at the profile. Unvisited profiles have no freshness requirement. YAGNI (Principle 1). | If the product adds email digests or other background consumption of contribution data |
| C2 | Fail-open on Redis cooldown check | A Redis outage allows a burst of refreshes from a determined owner | Principle 6 (bounded operations) — the cooldown bound is temporarily unenforceable | GitHub's own 5,000 pts/hour per-user rate limit is the hard backstop. A single user cannot cause cross-user rate-limit issues. Risk is low. | If Redis availability SLO degrades or if the feature is opened to higher-volume use cases |
| C3 | 24-hour data staleness shown to visitors | Visitors may see a grid that is up to 24 hours behind reality | Principle 8 (Measure for accuracy) | Explicitly specified in the blueprint as the accepted freshness contract. The trade-off is owned by the product decision. | If the product changes the freshness requirement |
| C4 | Single snapshot per user (upsert, no history) | We cannot show contribution trend over time or debug what changed between fetches | Principle 4 (Get the data model right) — future-proofing omitted | The blueprint only requires current-state display. History adds storage cost and schema complexity for zero current benefit. | If the product wants "compare this month vs last month" or audit trails |
| C5 | Best-effort GitHub token revocation on disconnect | The token may remain valid on GitHub's side for a short time after disconnect | Principle 11 (Security & privacy) | The access is read-only (`read:user`); there is no write exposure even if the token lingers. The token is deleted from our DB immediately, ending all future use by our system. | If the scope is ever expanded to include write permissions |

---

## 13. Open Risks & Callouts

1. **GitHub API changes:** GitHub has changed its GraphQL contribution schema before. The `weeks_json` JSONB storage means the raw shape is stored as-is; frontend parsing logic could break silently if GitHub adds/removes fields. Mitigation: pin the query shape and add a schema validation step in the task before writing to DB.

2. **Token encryption key rotation:** If `GITHUB_TOKEN_ENCRYPTION_KEY` is rotated, all stored tokens become unreadable until re-encrypted. There is no key-rotation migration in this design. This should be addressed before GA.

3. **GitHub's OAuth token expiry model:** GitHub OAuth tokens (for OAuth Apps) do not expire by default, but GitHub may add expiry or force-revoke tokens. The `token_status` field accommodates this, but a proactive token refresh flow (using refresh tokens) is not designed here. If GitHub moves to expiring tokens for OAuth Apps, this would need a follow-up design.

4. **`contributionsCollection` date window:** The GitHub GraphQL API's `contributionsCollection` uses a `from`/`to` date range. The task must correctly compute "trailing 52 weeks + current week = 53 weeks" in UTC, respecting the user's GitHub account timezone vs. UTC discrepancy. This is a subtle implementation detail to validate in tests.

5. **Profile privacy enforcement:** The widget read endpoint must consult the profile privacy flag on every request (not cache it). A caching mistake here could expose a private user's contribution data to visitors. This is flagged as a high-attention implementation detail.

---

## 14. Out of Scope

Per the blueprint:
- Contribution graphs for organizations or repositories.
- Historical contribution data older than 12 months.
- Any write access to GitHub.

Additionally, per design scope:
- Webhook-based real-time updates from GitHub (GitHub does not offer this for contributions).
- Multi-GitHub-account linking (one account per user).
- Displaying private contributions (out of scope at the chosen OAuth scope).
- A Celery Beat periodic sweep for proactive refresh of unvisited profiles (see C1 — revisit trigger documented).
- Token refresh flow for expiring GitHub OAuth tokens (see Risk 3).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — latency table per action; DB-read path for visitor is the fast path |
| A2 Throughput & scale | Resolved | §6 — 100k users, 1M profile views/day, 20k tasks/day; well within stack capacity |
| A3 Concurrency & consistency | Resolved | §3 D4/D5 — Redis in-flight guard prevents duplicate tasks; cooldown enforced cross-process |
| A4 Availability & reliability | Resolved | §7 — retry policy, fail-open on Redis, stale-data degradation for GitHub outage |
| A5 Data integrity & durability | Resolved | §4 — upsert pattern, cascade deletes, no orphaned data; transactional boundaries noted |
| A6 Caching & freshness | Resolved | §3 D1/D5, §6 — five-question cache answer, 24h TTL, Redis cooldown, lazy refresh |
| A7 Cost | Resolved | §5, §6 — GitHub API is free at this scale; rate limits documented; no monetary cost |
| A8 Security & privacy | Resolved | §8 — token encryption, ownership checks, adversarial scenarios addressed |
| A9 Observability | Resolved | §9 — metrics, logs, traces, primary alert signal, dashboard |
| A10 Maintainability & simplicity | Resolved | §3 — background fetch follows existing Celery pattern; minimal new components |
| A11 Testability | Resolved | §5 (mock strategy), §3 D5 (in-flight guard as deterministic seam), grammar-helper follow-up noted |
| A12 Deployability & rollout | Resolved | §10 — feature flag, staged deploy order, reversibility |
| A13 Backward compatibility | Assumed (A6) | New tables + routes only; no existing schema touched |
| A14 Accessibility & device/env | Assumed | Blueprint does not specify a11y requirements; the widget is display-only. Assumed: WCAG 2.1 AA color contrast for the grid, ARIA label on the grid ("Contribution activity for the past year"), keyboard-accessible Refresh button. Reduced-motion: no animation in initial design. |
| B1 Placement / module taxonomy | Assumed (A1) | New `github_widget` Django app (or `integrations` submodule); confirm with team |
| B2 Data model & persistence | Resolved | §4 — two new tables, schema, invariants, migration shape |
| B3 API surface & schemas | Resolved | §2 (flow diagram), §3 (endpoint list); four new endpoints with documented contracts |
| B4 Async / background work | Resolved | §3 D3 — Celery task for all GitHub calls; polling for completion |
| B5 External services & contracts | Resolved | §5 — GitHub OAuth + GraphQL; auth, rate limits, failure modes, mock strategy |
| B6 Frontend integration | Resolved | §3 D3 (polling for task completion), §6 (loading/empty/error states from blueprint), §2 (component list) |
| B7 Feature flags & rollout | Assumed (A5) | `GITHUB_WIDGET_ENABLED` flag; confirm flag system with team — §10 |
| B8 Error handling | Resolved | §7 — per-layer error handling; task retry policy; user-facing messages per blueprint |

---

## Appendix A: Captured Inputs

> This session ran in autonomous mode (no human interviewee). The following records the decision-making process: for each fork, the question that would have been asked, the recommendation, the autonomous resolution, and the rationale. This appendix substitutes for a live interview transcript and records the intent behind every design choice.

---

### OAuth token storage and encryption

- **Question (would have asked):** Do you have an existing encryption utility for sensitive DB fields (e.g. `django-encrypted-model-fields`, Fernet wrapper), or should we design one?
- **Recommendation given:** Use an existing utility if present (Principle 2 — match patterns); otherwise, a Fernet-based encryption helper is the simplest addition.
- **Autonomous resolution:** Designed for Fernet-based encryption of `access_token_enc`; flagged as Assumption A3 to confirm whether an existing library is available.
- **Notes:** The encryption key rotation risk is called out as Open Risk 2.

---

### Refresh trigger: lazy (read-time) vs. periodic Celery Beat

- **Question (would have asked):** Do you prefer a periodic Celery Beat task that sweeps all stale connections, or a lazy read-time trigger that only refreshes profiles that are actively viewed?
- **Recommendation given:** Lazy read-time trigger. Simpler, proportional to actual usage, avoids wasted GitHub API calls for inactive profiles. Can add Beat sweep later if needed (Principle 1, Principle 7).
- **Autonomous resolution:** D5 — lazy trigger selected. Documented as Accepted Compromise C1 with a revisit trigger.
- **Notes:** The user's stated priority ("avoid hammering the GitHub API") strongly favors the lazy approach.

---

### Redis for cooldown enforcement

- **Question (would have asked):** Is Redis available in your stack for the cooldown TTL key? If not, should we fall back to a Postgres-only approach?
- **Recommendation given:** Redis TTL key is the cleanest primitive for rate-limit state. If Redis is not available, `manual_refresh_available_at` in Postgres is the fallback.
- **Autonomous resolution:** Designed for Redis primary + Postgres fallback. Flagged as Assumption A2 for confirmation.
- **Notes:** The fail-open behavior on Redis unavailability is documented as Accepted Compromise C2.

---

### GitHub API: REST vs. GraphQL

- **Question (would have asked):** Any organizational preference for GitHub REST vs. GraphQL? Both can serve this feature.
- **Recommendation given:** GraphQL `contributionsCollection` — single request, richer data, lower call count.
- **Autonomous resolution:** D2 — GraphQL selected. Documented with alternatives.
- **Notes:** The grammar of the GraphQL query (field names, date range parameters) is flagged as a follow-up for a probe-tested helper module, per the skill's external-system grammar guardrail.

---

### Snapshot history vs. single-row upsert

- **Question (would have asked):** Do you need historical contribution snapshots (audit trail, trend analysis), or is the latest snapshot sufficient?
- **Recommendation given:** Single-row upsert. Blueprint only requires current-state display. History adds cost and complexity for no current benefit (Principle 1 — YAGNI).
- **Autonomous resolution:** Single-row upsert design in §4. Documented as Accepted Compromise C4 with a revisit trigger.
- **Notes:** JSONB for `weeks_json` leaves the door open for schema evolution without a migration.

---

### Feature flag scope: global vs. per-user

- **Question (would have asked):** Should the feature flag be a global on/off, or a per-user percentage rollout flag?
- **Recommendation given:** Global on/off for initial rollout (simpler); add percentage rollout at the staged-rollout phase if the flag system supports it.
- **Autonomous resolution:** Global `GITHUB_WIDGET_ENABLED` flag with staged rollout guidance in §10. Flagged as Assumption A5.
- **Notes:** No user-specific business logic depends on the flag granularity.

---

### Frontend completion signal: polling vs. WebSocket/SSE

- **Question (would have asked):** After enqueueing a refresh, should the frontend poll the widget endpoint or use a WebSocket/SSE push to signal completion?
- **Recommendation given:** Polling. The refresh is a non-urgent background operation; polling every 3–5 seconds for up to 30 seconds is simple and sufficient. SSE/WebSocket adds infrastructure complexity for no user-experience gain here (Principle 1).
- **Autonomous resolution:** Polling approach documented in §3 D3 and §6. No SSE/WebSocket infrastructure added.
- **Notes:** The task's `fetch_status` field in the snapshot row is what the poll reads; it transitions from `pending` → `ok`/`error`.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** (Autonomous mode — no human available.) Reviewed all blueprint scenarios against the design:
  - "Member never connected GitHub" → no widget, Connect button shown. Covered: widget endpoint returns 404 if no `github_connections` row.
  - "GitHub account has only private contributions" → covered: D2 documents this is the accepted scope behavior.
  - "Member renamed GitHub username" → covered: connection by account ID in `github_connections.github_account_id`.
  - "Profile is private" → covered: §8, privacy flag enforcement on the widget read endpoint.
  - All four deviation scenarios → covered in §7.
  - Both adversarial scenarios → covered in §8.
  - All out-of-scope items → confirmed in §14.
  - No additional concerns identified. Proceeding to write.
