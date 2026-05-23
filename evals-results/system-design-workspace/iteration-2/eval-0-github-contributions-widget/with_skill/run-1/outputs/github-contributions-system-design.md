# System Design: GitHub Contributions Widget

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./github-contributions-blueprint.md](./github-contributions-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The GitHub Contributions Widget connects a member's GitHub account via OAuth, stores their contribution data in Postgres, and serves that cached data to every profile visitor — never live-fetching from GitHub during a page view. The single most important architectural choice is the **store-and-serve model**: contribution data is fetched into Postgres by a Celery background task and read back from there; GitHub is never called in the request path. This protects GitHub API rate limits, keeps profile-page latency under control regardless of GitHub's response time, and satisfies the blueprint's rule that visitors never trigger a fetch. A 24-hour TTL governs background refresh; the owner's manual Refresh button is rate-limited to once per hour enforced server-side.

---

## 2. System Placement

This feature spans three layers of the Django + Postgres + Celery + React stack:

**Backend — new Django app `github_contributions`**

```
profile page request
      │
      ▼
Django view / REST API
      │
      ├─ GET /api/github-contributions/{username}/   ← read cached data from Postgres
      ├─ POST /api/github-oauth/connect/             ← begin OAuth flow
      ├─ GET  /api/github-oauth/callback/            ← complete OAuth, store token
      ├─ POST /api/github-contributions/refresh/     ← owner-only; queues Celery task
      └─ DELETE /api/github-oauth/disconnect/        ← revoke + purge data

      │
      ▼
GitHubContributionService   (service layer, no HTTP knowledge)
      │
      ├─ reads / writes GitHubConnection model
      ├─ reads / writes ContributionSnapshot model
      └─ enqueues / checks RefreshCooldown

      │
      ▼
Celery task: fetch_github_contributions(user_id)
      │
      └─ calls GitHub GraphQL API → upserts ContributionSnapshot
```

**Frontend — React widget component `<GitHubContributionsWidget />`**

- Rendered inside the profile page; reads contribution data from the REST API on page load.
- Displays loading skeleton, filled grid, empty state, "Reconnect" prompt, or cooldown timer depending on data/state returned by the API.
- No polling; no real-time push. A single GET on mount is sufficient because data is served from the DB cache.

**Components touched:**
- New Django app `github_contributions` (models, views, service, tasks, URLs)
- Existing `profiles` app — profile page view/template wires in the widget
- Existing `users` / auth module — OAuth token storage uses the existing secrets pattern
- Celery worker — adds one new task queue or shares the default queue
- React profile page — adds the new widget component

---

## 3. Architecture Decisions

### D1. Store-and-serve: all reads come from Postgres, not GitHub

- **Decision:** Contribution data is fetched from GitHub exactly when needed (initial connect, scheduled background refresh, or explicit owner Refresh) and stored in a `ContributionSnapshot` Postgres row. Every read — profile owner and visitors alike — queries that row. GitHub is never called in the HTTP request path.
- **Why:** Upholds *Design for failure* (Principle 5): GitHub unavailability never breaks a profile page view. Upholds *Cost as a first-class constraint* (Principle 12): API calls are bounded to one per user per 24-hour window plus one explicit refresh per hour, not one per visitor per page load. Upholds *Cache invalidation is a design decision* (Principle 13): the TTL and invalidation story (24 h background + owner manual) are explicit and co-located with the model.
- **Alternatives considered:** (a) Live-fetch on every page load — rejected: hammers GitHub API, exposes visitor latency to GitHub response time, impossible to rate-limit correctly. (b) CDN-level caching of the API response — rejected: adds operational complexity, doesn't help with GitHub rate limits on the fetch itself, and makes token revocation detection harder.
- **Trade-off accepted:** Data shown to visitors can be up to 24 hours stale between automatic refreshes. Acceptable per blueprint: "Contribution data is considered fresh enough if it is less than 24 hours old."

### D2. Background refresh via Celery task, not inline

- **Decision:** All GitHub API calls happen inside a Celery task `fetch_github_contributions(user_id)`. The OAuth callback enqueues this task immediately after saving the token. The scheduled background refresh is a Celery Beat periodic task that enqueues a task for each user whose snapshot is older than 24 hours. The owner's Refresh button endpoint enqueues the task immediately (after cooldown check) and returns `202 Accepted`.
- **Why:** Upholds *Design for failure* (Principle 5): a slow GitHub response doesn't block the HTTP request. Upholds *Idempotency & bounded operations* (Principle 6): the task is idempotent — re-running it for the same user produces the same result and is safe on retry. Upholds *Simplicity first* (Principle 1): the existing Celery stack already handles async work; no new infrastructure needed.
- **Alternatives considered:** Inline fetch on OAuth callback — rejected: ties user-facing latency to GitHub's response time and provides no protection against GitHub being slow at auth time.
- **Trade-off accepted:** After the owner clicks Refresh, they see a `202` and must wait for the task to complete before the grid updates (frontend polls or user manually reloads). This is a minor UX gap; see Assumption A6 for the chosen resolution.

### D3. OAuth token stored encrypted in Postgres (not a separate secrets store)

- **Decision:** The GitHub OAuth access token is stored in the `GitHubConnection` table, encrypted at rest using Django's existing field-level encryption pattern (e.g. `django-cryptography` or equivalent already in the project). The token is never returned to the frontend.
- **Why:** Upholds *Security & privacy by design* (Principle 11): the token is PII/secret and must not be exposed to clients or logs. Using the project's existing encryption pattern upholds *Match existing patterns over novelty* (Principle 2).
- **Alternatives considered:** AWS Secrets Manager / HashiCorp Vault — rejected under YAGNI (Principle 1): the existing field-level encryption is sufficient for a single token per user; a dedicated secrets store adds operational overhead not justified at this scale.
- **Trade-off accepted:** Token rotation/re-encryption requires a data migration rather than a Vault policy change. Acceptable now; revisit if the project adopts a secrets manager broadly.

### D4. Refresh cooldown enforced server-side with a DB timestamp

- **Decision:** `GitHubConnection` carries a `last_manual_refresh_at` timestamp. The `POST /refresh/` endpoint checks `now() - last_manual_refresh_at < 1 hour`; if true it returns `429` with the seconds-remaining value. The frontend renders this as the cooldown timer. No separate Redis key or token bucket.
- **Why:** Upholds *Simplicity first* (Principle 1): Postgres already holds all relevant state; adding Redis for a single timestamp is unnecessary indirection. Upholds *Make illegal states unrepresentable* (Principle 9): the cooldown is in the authoritative store, so scripted requests or multi-tab races can't bypass it.
- **Alternatives considered:** Redis TTL key — would be marginally faster to check but introduces a new dependency and a split-brain risk if Postgres and Redis diverge.
- **Trade-off accepted:** Cooldown check is a DB round-trip rather than an in-memory check. At the scale of one button click per hour per user this is negligible.

### D5. GitHub connection keyed on GitHub account ID, not username

- **Decision:** `GitHubConnection` stores `github_account_id` (the immutable numeric ID returned by the GitHub API) as the canonical foreign key to the GitHub identity. `github_username` is stored as a display field but is not used for any lookup.
- **Why:** Directly implements the blueprint edge case "Member renamed their GitHub username: the connection is by account ID, so a rename does not break the widget." Upholds *Get the data model right* (Principle 4): using an immutable key prevents a class of breakage that would be hard to repair in production.
- **Alternatives considered:** Keying on username — rejected: username changes are common on GitHub and would silently break all subsequent fetches.
- **Trade-off accepted:** None material.

### D6. Scheduled background refresh via Celery Beat — no per-user timer

- **Decision:** A single Celery Beat periodic task runs every hour (or every N minutes, configurable). It queries `ContributionSnapshot` for rows where `fetched_at < now() - 24 hours` (and `GitHubConnection.is_active = True`) and enqueues one `fetch_github_contributions` task per user. No per-user scheduled job; no cron-per-user.
- **Why:** Upholds *Simplicity first* (Principle 1): a single sweeper is far simpler than N per-user timers. Upholds *Idempotency & bounded operations* (Principle 6): the sweeper is naturally bounded to the user count; the per-task work is a single API call.
- **Alternatives considered:** Celery ETA / countdown per user on each refresh — adds scheduling complexity and can accumulate a large number of scheduled tasks if users grow.
- **Trade-off accepted:** Background refresh is eventually consistent within the sweep interval (up to 1 hour past the 24-hour mark). Acceptable: the blueprint says "less than 24 hours old" as a freshness threshold, and a brief overshoot is not material.

### D7. GitHub GraphQL API for contribution data

- **Decision:** Use GitHub's GraphQL API (`contributionsCollection`) rather than the REST API to fetch the 53-week contribution grid, total contributions, current streak, and longest streak in a single request.
- **Why:** The GitHub REST API does not expose the contribution graph directly; the GraphQL API does via `contributionsCollection`. Upholds *Idempotency & bounded operations* (Principle 6): one round-trip per refresh vs. multiple REST calls. The query scope is read-only; no write access required.
- **Alternatives considered:** Scraping GitHub's SVG contribution graph — rejected: fragile, violates ToS, and provides no streak data. GitHub REST search — rejected: doesn't expose the contribution grid natively.
- **Trade-off accepted:** GraphQL adds a small learning surface compared to REST but is the only supported path for this data. The API grammar (query structure, field names, date range parameters) should be codified in a separate probe-tested skill rather than hardcoded inline — noted as a follow-up.

### D8. Disconnect purges all stored data immediately

- **Decision:** `DELETE /api/github-oauth/disconnect/` deletes both the `GitHubConnection` row and the associated `ContributionSnapshot` row(s) in the same database transaction. The profile widget disappears immediately on the next page load.
- **Why:** Upholds *Security & privacy by design* (Principle 11): retaining contribution data after a disconnect raises privacy expectations that must be met. The blueprint states "stored contribution data is removed" on disconnect — this is a behavioral requirement, not just a nice-to-have. Upholds *Get the data model right* (Principle 4): a `CASCADE` delete on the FK enforces the invariant at the DB level.
- **Alternatives considered:** Soft-delete / mark as disconnected and purge async — rejected: leaves PII in the DB longer than the user expects and adds a state machine that has no benefit here.
- **Trade-off accepted:** Data is not recoverable after disconnect; re-connecting starts fresh. Acceptable: the blueprint does not mention any recovery path.

---

## 4. Data Model & Persistence

### `GitHubConnection`

```
github_contributions_githubconnection

  id                     bigserial PRIMARY KEY
  user_id                bigint NOT NULL UNIQUE  FK → users_user(id) ON DELETE CASCADE
  github_account_id      text    NOT NULL UNIQUE         -- immutable GitHub numeric ID
  github_username        text    NOT NULL                -- display only; mutable
  access_token_encrypted bytea   NOT NULL                -- field-level encrypted
  scopes                 text    NOT NULL DEFAULT ''     -- space-separated OAuth scopes granted
  connected_at           timestamptz NOT NULL DEFAULT now()
  is_active              boolean NOT NULL DEFAULT true   -- false = token known bad
  last_manual_refresh_at timestamptz                     -- NULL = never manually refreshed
  token_invalidated_at   timestamptz                     -- NULL = token still valid
```

**Invariants:**
- One connection per user (`UNIQUE user_id`). Re-connecting via OAuth upserts this row.
- `is_active = false` is set by the Celery task when a 401/403 is returned by GitHub; cleared on successful reconnect.
- `access_token_encrypted` is never read by any code path that touches the HTTP response.

### `ContributionSnapshot`

```
github_contributions_contributionsnapshot

  id                     bigserial PRIMARY KEY
  connection_id          bigint NOT NULL UNIQUE  FK → github_contributions_githubconnection(id)
                                                 ON DELETE CASCADE
  fetched_at             timestamptz NOT NULL DEFAULT now()
  year_total             integer NOT NULL DEFAULT 0
  current_streak         integer NOT NULL DEFAULT 0
  longest_streak         integer NOT NULL DEFAULT 0
  weeks_json             jsonb   NOT NULL DEFAULT '[]'
  -- weeks_json schema: [{week_start: "YYYY-MM-DD", days: [{date, count, level}×7]}×53]
  fetch_status           text    NOT NULL DEFAULT 'ok'
  -- 'ok' | 'rate_limited' | 'token_invalid' | 'github_error'
```

**Invariants:**
- One snapshot per connection (`UNIQUE connection_id`). All updates are upserts on `connection_id`.
- `weeks_json` is always stored even on partial failure (last known-good value retained); `fetch_status` records what happened on the most recent attempt.
- `fetched_at` is updated only on a successful fetch (status `ok`). This ensures the 24-hour staleness check is based on the last good data, not the last attempt.

### Migrations

- Two new tables; no changes to existing tables.
- Initial migration creates both tables and their indexes.
- `ON DELETE CASCADE` on `ContributionSnapshot.connection_id` enforces the disconnect-purges-data invariant at the DB level.
- No backfill needed (new feature).

### Retention

- Contribution snapshots are retained as long as the `GitHubConnection` exists. Disconnect cascades deletion. No separate TTL/expiry job needed.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| GitHub OAuth 2.0 (`github.com/login/oauth`) | Member connects their GitHub account; grants read access to contribution data | `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in Django settings (env vars); per-user access token stored encrypted in Postgres | No hard rate limit on OAuth flow itself; standard OAuth2 redirect flow | OAuth callback failure: show error, member can retry connect. Token revocation detected on next API call (401) → set `is_active=false`, show "Reconnect" prompt to owner | Mock with `responses` library in unit tests; integration test against GitHub's sandbox or a test app |
| GitHub GraphQL API (`api.github.com/graphql`) | Fetch 53-week contribution grid, totals, and streaks | Per-user `access_token_encrypted` (Bearer token); read-only scope (`read:user`) | 5,000 points/hour per token (GraphQL costs ~1 point per query); no per-call cost | Timeout (set 10 s): retain last snapshot, log warning. 401/403: set `is_active=false`, prompt owner to reconnect. 429 rate-limit: mark `fetch_status='rate_limited'`, do not retry until next sweep; show "Couldn't refresh right now" to owner. 5xx: retry with exponential back-off (max 3 attempts within the task); on exhaustion retain last snapshot | Mock with `responses` or `unittest.mock`; fixture JSON for unit tests; a dedicated probe-tested skill for the GraphQL query grammar is recommended as a follow-up |

**External-system grammar note:** The GitHub GraphQL `contributionsCollection` query shape, field names, date range arguments, and pagination (if needed for >1-year windows) should be captured in a probe-tested skill rather than hardcoded in application code. This is a follow-up item; for initial implementation, the query is defined as a versioned constant in the service module.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| Profile page load (widget read) | < 50 ms | < 150 ms | DB read of one `ContributionSnapshot` row + `weeks_json` |
| Owner Refresh (button click) | < 200 ms | < 400 ms | Cooldown check + task enqueue; no GitHub call in the request path |
| GitHub fetch (background task) | < 5 s | < 10 s | One GraphQL round-trip; 10 s hard timeout |
| OAuth callback completion | < 300 ms | < 600 ms | DB write + task enqueue |

### Expected load

- User base assumption: tens of thousands of members, with a small fraction (~5–20 %) connecting GitHub at any given time. See Assumption A1.
- Peak profile-page reads: the `ContributionSnapshot` read is a single-row primary-key lookup — O(1) and trivially scalable with existing Postgres setup.
- Background sweep: N connected users × 1 task per 24-hour window = modest queue pressure. At 10,000 connected users the sweep enqueues ~417 tasks/hour on average. Well within standard Celery worker capacity.

### Caching model

The `ContributionSnapshot` table **is** the cache. There is no secondary Redis or in-process cache. This is deliberate:

| Cache concern | Answer |
|---|---|
| What is cached | 53-week contribution grid, totals, streaks |
| Where | `ContributionSnapshot` table in Postgres |
| TTL | 24 hours (background sweep triggers refresh when `fetched_at < now() - 24h`) |
| Invalidation | Explicit owner Refresh (manual, cooldown-gated); background sweep (automatic); re-connect (immediate re-fetch) |
| Freshness vs. cost trade-off | Data may be up to 24 h stale for visitors. Blueprint explicitly accepts this. Manual refresh gives the owner an escape hatch. |

No in-memory or Redis cache is added for this feature. The DB read is cheap enough that caching the HTTP response layer (e.g. per-user Django cache) would add invalidation complexity with no meaningful latency benefit. Revisit if profiling shows the DB as a bottleneck.

### Concurrency — concurrent refreshes

If the owner somehow submits two Refresh requests simultaneously (race between two browser tabs), the cooldown check is a DB read-then-conditional-update wrapped in `select_for_update()` on the `GitHubConnection` row. Only one request proceeds; the other gets `429`. The Celery task itself is idempotent, so double-enqueue (if it slips through) produces the same result.

---

## 7. Reliability & Failure Handling

### GitHub slow or unreachable (blueprint deviation)

- Celery task sets a 10-second timeout on the GitHub API call.
- On timeout or 5xx: task retries with exponential back-off, max 3 attempts (delays: 30 s, 2 min, 10 min).
- After 3 failures: task exits, `fetch_status` set to `'github_error'`, `fetched_at` is **not** updated (last-good timestamp preserved).
- Profile page continues to serve the last stored snapshot with the "Last updated <time>" label derived from `fetched_at`. No hard error shown to visitors.

### Token revoked or expired (blueprint deviation)

- A 401 or 403 from GitHub inside the Celery task sets `GitHubConnection.is_active = false` and `token_invalidated_at = now()`.
- The API read endpoint checks `is_active`: if false, the response includes `token_invalid: true`.
- Owner's widget shows "Reconnect GitHub" prompt; visitors see the last stored snapshot (same as the stale-data path).

### GitHub rate-limit response (blueprint deviation)

- A 429 from GitHub inside the Celery task: do not retry (retrying would worsen the rate-limit situation). Set `fetch_status = 'rate_limited'`. Cooldown still applies.
- For owner-triggered Refresh: the endpoint returns success (task was enqueued) but if the task receives a 429, the owner will see "Couldn't refresh right now, try again later" on their next page load (communicated via `fetch_status` in the API response).

### Idempotency

- `fetch_github_contributions(user_id)` is idempotent: it upserts `ContributionSnapshot` on `connection_id`. Running it twice for the same user produces the same stored state.
- `POST /refresh/` is protected by the server-side cooldown, but even if called twice rapidly the second call returns `429` before enqueuing.

### Disconnect during in-flight task

- If a user disconnects while a Celery task is running, the task will attempt a DB upsert that will fail with a foreign-key constraint violation (the `GitHubConnection` row is gone). The task should catch `IntegrityError` / `ObjectDoesNotExist`, log a warning, and exit cleanly. This is a safe failure mode.

---

## 8. Security & Privacy

### Authentication & authorization

- `GET /api/github-contributions/{username}/` — public; no auth required. Returns only contribution data (no token, no email). Returns empty/widget-hidden response if the profile is private and the requester is not the owner.
- `POST /refresh/` — requires authentication; server checks that the requesting user owns the profile. Returns `403` otherwise.
- `POST /connect/`, `DELETE /disconnect/` — requires authentication; owner only.
- GitHub OAuth `state` parameter: generated as a CSRF token tied to the user's session; validated in the callback to prevent OAuth CSRF attacks.

### Input validation

- `{username}` path parameter: validated as a known user lookup (resolved to `user_id` internally); never passed to GitHub or used in a raw query.
- OAuth `code` and `state`: validated server-side before token exchange; `state` checked against session value.

### Secret handling

- `GITHUB_CLIENT_SECRET` and per-user `access_token_encrypted` are never logged or included in API responses.
- `access_token_encrypted` is decrypted only inside the Celery task, in memory, for the duration of the GitHub API call.
- The API read endpoint (`GET /api/github-contributions/{username}/`) returns only contribution grid data — never the token or any GitHub account credential.

### PII & privacy

- `github_username` is treated as public (it's the user's chosen display name on a public platform).
- `github_account_id` is an internal key; not exposed in API responses.
- `access_token_encrypted` is PII/secret; encrypted at rest, never returned over HTTP.
- If the platform profile is set to private, the widget endpoint returns an empty/hidden response to non-owners, consistent with the platform's existing profile privacy model.

### Abuse vectors (blueprint adversarial scenarios)

- **Visitor triggering a fetch:** The read endpoint is a pure DB read; it cannot trigger a GitHub API call. The Refresh endpoint requires authentication and owner-ship check. Visitors cannot trigger any GitHub API call.
- **Scripted refresh to bypass cooldown:** The `POST /refresh/` cooldown check uses `select_for_update()` on the DB row, making it race-safe. Even with parallel requests, only one can hold the lock and set `last_manual_refresh_at`; subsequent requests within the hour window receive `429`. Rate-limiting middleware (existing Django rate-limiter or nginx-level) should be applied to the `/refresh/` endpoint as a defense-in-depth measure (see Assumption A4).

---

## 9. Observability

### Logs

- Every `fetch_github_contributions` task execution: log `user_id`, `fetch_status`, duration, and GitHub response status.
- OAuth connect/disconnect events: log `user_id` and event type (no token values).
- Cooldown `429` responses: log `user_id` and `seconds_remaining` at DEBUG level.

### Metrics

| Metric | Type | Purpose |
|---|---|---|
| `github_contributions.fetch.duration_seconds` | Histogram | Track GitHub API latency; alert on p95 > 8 s |
| `github_contributions.fetch.status` (labels: ok / rate_limited / token_invalid / github_error) | Counter | Health of background fetches |
| `github_contributions.snapshots.stale_count` | Gauge | Count of snapshots older than 24 h (sweep health check) |
| `github_contributions.refresh.cooldown_rejections` | Counter | Detect scripted refresh attempts |
| `github_contributions.oauth.connect_count` | Counter | Feature adoption |

### The one signal that proves the feature is healthy

> **`github_contributions.fetch.status{status="ok"}` rate remains > 95 % of all fetch attempts over a 1-hour window.** Alert if it drops below 90 % for 15 minutes — that indicates a systemic GitHub API problem or a token-revocation wave.

### Traces

- Celery tasks should carry a trace context propagated from the enqueuing request (if the project uses distributed tracing). At minimum, log a `task_id` that can be correlated to the originating HTTP request.

### Alerts

1. `fetch.status{status="github_error"}` rate > 10 % for 10 min → GitHub API degraded.
2. `snapshots.stale_count` > expected (e.g. > 1 % of connected users with data > 48 h old) → background sweep is broken.
3. Task queue depth for `fetch_github_contributions` > 1,000 → worker throughput issue.

---

## 10. Rollout & Operability

### Feature flag

- Gate the entire feature behind a boolean feature flag `GITHUB_CONTRIBUTIONS_ENABLED` (environment variable or the project's existing feature-flag mechanism).
- Default: **off** (fail-closed). The "Connect GitHub" button in settings and the widget on the profile page are only rendered when the flag is on.
- The OAuth callback endpoint must also check the flag and return `404` if off, to prevent partial-state issues during rollout.

### Migration order

1. Deploy backend with migrations (creates `GitHubConnection` and `ContributionSnapshot` tables). Flag is off; no user-visible change.
2. Deploy Celery beat configuration for the background sweep task (it will find zero rows to process until users connect).
3. Enable flag for internal users / beta group. Validate OAuth flow, background fetch, and widget rendering end-to-end.
4. Gradual rollout: enable flag for a percentage of users (or all users). Monitor `fetch.status` metrics.
5. Full rollout.

### Reversibility

- The feature flag makes rollout reversible at any point. Turning the flag off hides the widget and disables new connects; existing `GitHubConnection` and `ContributionSnapshot` rows are retained (no data loss on flag toggle).
- The tables can be dropped in a later migration if the feature is permanently removed, with a separate migration gated on confirmation.

### No coordination required

- The backend migration and the frontend widget deploy are independent: the frontend widget renders nothing when the API returns no data (flag off or no connection). No locked-step deploy is required.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | User base in the tens of thousands; connected GitHub users in the low thousands at launch | Typical early-stage product scale; the design handles 10× this trivially | Yes — confirm if scale is materially larger |
| A2 | The project already uses Celery Beat for periodic tasks | The task description says "Django + Celery app"; Beat is the standard periodic task scheduler | No — but confirm Beat is already configured; if not, it needs to be set up |
| A3 | Field-level encryption for secrets already exists in the project (e.g. `django-cryptography`) | Common in Django projects handling OAuth tokens | Yes — confirm the encryption pattern to use; if absent, add the library as a dependency |
| A4 | The project has request-level rate-limiting middleware or nginx-level throttling available for sensitive endpoints | Defense-in-depth for the Refresh endpoint; standard in production Django deployments | Yes — confirm and apply to `POST /refresh/` |
| A5 | The GitHub OAuth app will be registered with `read:user` scope (which includes the contribution graph via GraphQL) | This scope is required and sufficient for `contributionsCollection` | No — confirmed by GitHub API docs |
| A6 | After clicking Refresh, the owner refreshes the page (or the frontend polls the read endpoint) to see updated data | A simple page refresh is acceptable UX; no real-time push infrastructure exists | Yes — if the product expectation is instant in-page update, a short polling loop (e.g. poll every 2 s for up to 30 s after Refresh click) should be added to the frontend |
| A7 | The project's existing Django REST Framework (or similar) is used for the API layer | "Django + React" stack implies DRF or equivalent | No — align with existing API framework |
| A8 | The background sweep runs every 60 minutes via Celery Beat, which is sufficient to keep data within the 24-hour freshness window | A 60-minute sweep interval means data can be at most 25 hours old in the worst case — a negligible overshoot | No — acceptable per blueprint semantics |
| A9 | `contributionsCollection` GraphQL query returns data sufficient to compute current streak and longest streak directly, or that the service layer computes them from the day-by-day grid | GitHub's API returns daily counts; streak computation is a simple pass over the array | No — straightforward implementation |
| A10 | The project does not currently have a GitHub integration of any kind | New domain; no existing module to extend or conflict with | Yes — confirm no prior GitHub OAuth flow exists |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Visitor-visible data can be up to 24 hours stale | Real-time contribution accuracy for visitors | *Measure, don't guess* (Principle 8) — we're not optimizing for freshness beyond what the blueprint requires | Blueprint explicitly accepts 24-hour staleness; member has a Refresh button | If the product decides to surface sub-hour freshness for visitors |
| C2 | No in-memory or Redis cache in front of the `ContributionSnapshot` read | Marginally higher DB load per profile page view | *Simplicity first* (Principle 1) — a second cache layer adds invalidation complexity | The read is a single-row PK lookup; Postgres handles this at < 5 ms even at moderate scale | If profiling shows DB as a bottleneck at scale |
| C3 | After Refresh the owner must reload the page to see new data (no real-time update) | Instant feedback after clicking Refresh | *Simplicity first* (Principle 1) — no WebSocket or real-time push infrastructure needed | The Refresh action is rare (at most once per hour); a manual reload is acceptable UX | If user research shows this is a significant friction point; a short client-side polling loop is the low-complexity fix |
| C4 | Background sweep may overshoot the 24-hour window by up to the sweep interval (60 min) | Strict 24-hour freshness guarantee | *Simplicity first* (Principle 1) — a per-user timer would be more precise but far more complex | Blueprint says "less than 24 hours old" as a target, not a hard SLA; a ~1-hour overshoot is not material | If the product hardens the freshness guarantee into an SLA |
| C5 | GitHub GraphQL query grammar hardcoded as a versioned constant in the service module initially | Fragility if GitHub changes the API schema | *Design the seams for testing* (Principle 15) — a probe-tested skill is the right home | Acceptable for initial implementation; noted as a follow-up | When the query needs to change or GitHub announces a breaking change |

---

## 13. Open Risks & Callouts

1. **GitHub API schema stability.** The `contributionsCollection` GraphQL field has been stable for several years but is not versioned in GitHub's API. A breaking change would silently produce bad data or errors. Mitigation: validate the response shape in the Celery task and alert on schema mismatch.

2. **Token scope creep.** If the product later wants to add write access (e.g. starring repos), the OAuth scope must be extended, which requires existing users to re-authorize. This is a one-way door — plan scope carefully up front. Current scope: `read:user` only.

3. **GDPR / data-deletion compliance.** If the project has a GDPR data-deletion flow, the `GitHubConnection` and `ContributionSnapshot` rows must be included in the user-data-deletion pipeline. The `ON DELETE CASCADE` handles the GitHub data when the user account is deleted, but confirm that the platform's deletion flow deletes the `users_user` row (which would cascade).

4. **GitHub account shared across multiple platform accounts.** The current model has `UNIQUE github_account_id` on `GitHubConnection`, meaning one GitHub account can only be connected to one platform account. This is likely correct (preventing sharing of a GitHub identity) but should be confirmed as intentional product behavior.

5. **Private contributions scope.** The blueprint notes that if the GitHub account has only private contributions the grid reflects whatever the API returns. However, surfacing private contribution counts to the public profile may surprise users who did not realize their private activity would be visible. This is a product decision that should be confirmed in the blueprint before shipping.

---

## 14. Out of Scope

Per the blueprint:
- Contribution graphs for organizations or repositories.
- Historical data older than 12 months.
- Any write access to GitHub.

Additionally, the following are out of scope for this design:
- Real-time contribution updates (webhooks from GitHub).
- Aggregated analytics across multiple members' GitHub data.
- GitHub Enterprise or GHES support.
- The GitHub OAuth app registration process (operational, not a system-design concern).
- Probe-tested skill for the GitHub GraphQL query grammar (noted as a follow-up in §5).

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — p50/p95 targets per action; DB-read path keeps widget load < 150 ms p95 |
| A2 Throughput & scale | Assumed (A1) | §6 — low thousands of connected users; single-row PK lookup scales trivially |
| A3 Concurrency & consistency | Resolved | §6, §7 — `select_for_update()` on cooldown check; idempotent task; disconnect race handled |
| A4 Availability & reliability | Resolved | §7 — retries, timeouts, graceful degradation, stale-data fallback per blueprint deviations |
| A5 Data integrity & durability | Resolved | §4 — transactional boundaries, FK CASCADE, upsert semantics, no partial-failure inconsistency |
| A6 Caching & freshness | Resolved | D1, §6 — explicit: what/where/TTL/invalidation/trade-off all stated; Principle 13 applied |
| A7 Cost | Resolved | D1, §6 — API calls bounded to 1/user/24 h + 1/user/hour manual; no runaway cost path |
| A8 Security & privacy | Resolved | D3, D4, §8 — token encrypted at rest, never in responses, OAuth CSRF protection, adversarial scenarios addressed |
| A9 Observability | Resolved | §9 — logs, metrics, key alert signal, traces |
| A10 Maintainability & simplicity | Resolved | D1, D2, D4 — new Django app, no new infrastructure, fits existing patterns |
| A11 Testability | Resolved | §5, §7 — mock strategy with `responses` library; idempotent task has deterministic seams; fixture JSON for unit tests |
| A12 Deployability & rollout | Resolved | §10 — feature flag, migration order, reversibility, no locked-step deploy |
| A13 Backward compatibility | Resolved (N/A) | New feature; no existing data shapes or API contracts changed |
| A14 Accessibility & device/env | Assumed (A6) | Frontend widget must render empty/loading/error states; skeleton loader and `aria-label` on grid cells recommended; offline behavior is stale-data per blueprint deviation — no additional system design needed. Details are frontend implementation concerns. |
| B1 Placement / module taxonomy | Resolved | §2 — new `github_contributions` Django app with service layer, views, tasks, models |
| B2 Data model & persistence | Resolved | §4 — two new tables, FK CASCADE, upserts, encrypted token column, migration shape |
| B3 API surface & schemas | Resolved | §2, §8 — four endpoints defined with auth requirements and response contracts |
| B4 Async / background work | Resolved | D2, D6 — Celery task, idempotent, Beat sweep, 202 response on manual Refresh |
| B5 External services & contracts | Resolved | §5 — GitHub OAuth + GraphQL; auth, rate limits, failure modes, mock strategy, grammar follow-up |
| B6 Frontend integration | Resolved | §2, C3, A6 — single GET on mount, state-driven render (loading/empty/error/stale/reconnect), no polling required |
| B7 Feature flags & rollout | Resolved | §10 — `GITHUB_CONTRIBUTIONS_ENABLED` flag, fail-closed, staged rollout |
| B8 Error handling | Resolved | §7 — per-layer error handling: DB (FK constraint), service (token invalid), task (retry/back-off/give-up), route (429/403/404) |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Widget shows 53-week grid, total contributions (trailing year), current streak, longest streak | Behavior | §4 (`weeks_json`, `year_total`, `current_streak`, `longest_streak` columns) | All four stored in `ContributionSnapshot`; served via read endpoint |
| Contribution data fresh if < 24 hours old | Behavior | D1, D6, §6 | 24-hour TTL via `fetched_at`; background sweep enforces it |
| Visitors never trigger a fetch; they see whatever is stored | Behavior | D1, §8 | Read endpoint is a pure DB read; no GitHub call possible from it |
| "Refresh" button available only to profile owner, once per hour | Behavior | D4, §8 | Ownership check on `POST /refresh/`; `select_for_update()` cooldown; 429 with seconds-remaining |
| Visible cooldown timer shows when Refresh is on cooldown | Behavior | D4 | `429` response includes `seconds_remaining`; frontend renders timer |
| Zero contributions → empty grid with "No public contributions yet" | Behavior | §4 (`year_total = 0`), B6 | `weeks_json` with all-zero days returned; frontend renders empty-state text |
| Disconnect removes widget and purges stored data | Behavior | D8, §4 | `DELETE` endpoint + transaction; FK CASCADE removes snapshot |
| Member never connected GitHub → no widget, show "Connect GitHub" button | Edge case | §8, §10 | No `GitHubConnection` row → read endpoint returns no-connection state; frontend renders connect CTA |
| Only private contributions → reflect what API returns; zero = empty state | Edge case | D7, §4 | GraphQL API returns authorized scope; zero result stored and rendered as empty state |
| Member renamed GitHub username → connection by account ID, not username | Edge case | D5 | `github_account_id` (immutable) is the key; `github_username` is display-only |
| Profile set to private → widget not shown to visitors, only owner | Edge case | §8 | Read endpoint checks platform profile privacy; returns hidden/empty response to non-owners |
| GitHub slow or unreachable → show last stored grid with "Last updated <time>" label | Deviation | §7, D1 | Task retries + gives up; `fetched_at` preserved; read endpoint always returns last snapshot with timestamp |
| Token revoked/expired → owner sees "Reconnect GitHub" prompt; visitors see last stored grid | Deviation | §7, §4 (`is_active`, `token_invalidated_at`), §8 | 401/403 sets `is_active=false`; read endpoint returns `token_invalid: true` to owner; visitors see snapshot |
| GitHub rate-limit → refresh silently fails, cooldown still applies, owner sees "Couldn't refresh right now" | Deviation | §7, §4 (`fetch_status='rate_limited'`) | 429 from GitHub: no retry, status stored, cooldown unchanged; owner reads `fetch_status` from API response |
| Visitor cannot trigger a data fetch | Adversarial | D1, §8 | Read endpoint is DB-only; Refresh requires auth + ownership |
| Visitor cannot see another member's GitHub token | Adversarial | D3, §8 | Token never in API responses; read endpoint returns only contribution data |
| Member cannot refresh faster than cooldown by scripting | Adversarial | D4, §8 | `select_for_update()` makes cooldown race-safe; defense-in-depth with rate-limiting middleware (A4) |
| Contribution graphs for orgs/repos are out of scope | Out of scope | §14 | Not implemented |
| Historical data > 12 months out of scope | Out of scope | §14 | `contributionsCollection` queried for trailing 12 months only |
| Write access to GitHub out of scope | Out of scope | §14 | OAuth scope is `read:user` only |

---

## Appendix A: Captured Inputs

*This design was produced autonomously (no human interviewee). The following records the decisions that would normally be resolved in a P3 interview, the recommendation made in each case, and the rationale. These decisions are also surfaced in §11 (Assumptions) and §12 (Compromises). A future human reviewer should treat any row marked "Needs confirmation?" in §11 as an open question.*

### Fetch architecture: live vs. store-and-serve

- **Question:** Should GitHub be called live on each profile page request, or should data be stored and served from the DB?
- **Recommendation given:** Store-and-serve. Visitors never trigger a GitHub call. Background Celery task refreshes data. Upholds Principles 5 (failure isolation), 12 (cost ceiling), 13 (explicit caching).
- **Decision made:** Store-and-serve (D1).
- **Notes:** The user's prompt explicitly flagged "avoid hammering the GitHub API" — this is the primary driver.

### Caching layer: Postgres vs. Redis

- **Question:** Should contribution snapshots be cached in Redis (fast) or stored directly in Postgres?
- **Recommendation given:** Postgres only. The read is a single-row PK lookup; Redis adds invalidation complexity with no meaningful latency benefit at this scale. Upholds Principle 1 (simplicity).
- **Decision made:** Postgres as the cache store (D1, §6).
- **Notes:** No Redis dependency introduced for this feature.

### Token storage: field-level encryption vs. dedicated secrets store

- **Question:** How should the GitHub OAuth access token be stored?
- **Recommendation given:** Field-level encryption in Postgres using the project's existing pattern. Vault/Secrets Manager is YAGNI at this stage. Upholds Principle 11 (security) and Principle 2 (match existing patterns).
- **Decision made:** Encrypted column in `GitHubConnection` (D3). Assumption A3 notes that the encryption library must be confirmed.

### Refresh UX: 202 + reload vs. real-time update

- **Question:** After the owner clicks Refresh and the Celery task runs, how does the UI update?
- **Recommendation given:** Return `202 Accepted`; owner reloads page to see new data. Real-time push requires WebSocket infrastructure not present in the stack. Upholds Principle 1.
- **Decision made:** 202 + manual reload (C3). Assumption A6 notes that a short client-side polling loop is the low-complexity upgrade path.

### Cooldown enforcement: DB timestamp vs. Redis TTL

- **Question:** Where is the 1-hour Refresh cooldown enforced?
- **Recommendation given:** DB timestamp with `select_for_update()`. Redis TTL is faster but adds a dependency and split-brain risk. Upholds Principles 1 and 9.
- **Decision made:** DB timestamp (D4).

### GitHub API: REST vs. GraphQL

- **Question:** Which GitHub API surface to use for contribution data?
- **Recommendation given:** GraphQL `contributionsCollection`. REST does not expose the contribution graph natively. One round-trip for all required data.
- **Decision made:** GraphQL (D7).

### Background refresh scheduling: per-user timer vs. sweeper

- **Question:** How to schedule the 24-hour background refresh per connected user?
- **Recommendation given:** Single Celery Beat sweeper that queries stale rows and enqueues tasks. Per-user timers are more precise but far more complex.
- **Decision made:** Hourly sweeper (D6).

### Disconnect behavior: immediate hard delete vs. soft delete

- **Question:** On disconnect, should contribution data be deleted immediately or soft-deleted?
- **Recommendation given:** Immediate hard delete in the same transaction, enforced by FK CASCADE. Blueprint says "stored contribution data is removed." Soft delete adds complexity with no benefit.
- **Decision made:** Hard delete (D8).

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** (Autonomous run — no human available.) Reviewed blueprint top to bottom; all behaviors, edge cases, deviation scenarios, and adversarial scenarios are accounted for in the Blueprint Coverage Checklist (§16). Open risks noted in §13, particularly: GDPR deletion pipeline inclusion, unique-GitHub-account-per-platform-account policy, and the private-contributions visibility question.
