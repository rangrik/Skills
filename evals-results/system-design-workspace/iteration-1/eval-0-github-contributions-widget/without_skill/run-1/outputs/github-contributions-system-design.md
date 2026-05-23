# System Design: GitHub Contributions Widget

**Stack:** Django + PostgreSQL + Celery + React  
**Blueprint date:** 2026-05-10  
**Design date:** 2026-05-23

---

## 1. Overview

The GitHub Contributions Widget displays a member's trailing-12-month commit activity on their public profile page. The member connects their GitHub account once via OAuth; from that point forward every profile visitor sees the cached contribution grid. The design deliberately minimises GitHub API calls by treating data as fresh for 24 hours and rate-limiting owner-initiated refreshes to once per hour.

---

## 2. Goals and Non-Goals

### Goals
- Render the 53-week contribution grid, yearly total, current streak, and longest streak on public profiles.
- Keep GitHub API traffic low: rely on stored data; never fetch on visitor page loads.
- Give the profile owner a controlled "Refresh" path, no more than once per hour.
- Handle token revocation, GitHub outages, and username renames gracefully.
- Prevent visitors from triggering fetches or accessing tokens.

### Non-Goals (from blueprint)
- Organisation or repository contribution graphs.
- Historical data beyond 12 months.
- Any write access to GitHub.

---

## 3. User-Facing Flows

### 3.1 Connect GitHub (OAuth)

```
Member clicks "Connect GitHub"
  → GET /auth/github/connect/
  → Redirect to GitHub OAuth (scope: read:user)
  → GitHub redirects to /auth/github/callback/?code=...&state=...
  → Exchange code for access token (server-side, token never hits the browser)
  → Store GitHubConnection record
  → Enqueue background task: fetch_github_contributions(user_id)
  → Redirect member back to settings page
```

### 3.2 View Profile (any visitor)

```
GET /api/profiles/{username}/
  → Return profile JSON including github_contributions field (from DB cache)
  → React widget renders grid from stored data
  → No GitHub API call on this path
```

### 3.3 Owner Refresh

```
POST /api/me/github/refresh/
  → Authenticated, must be profile owner
  → Check GitHubConnection.last_manual_refresh_at: if < 60 minutes ago → 429
  → Otherwise: set last_manual_refresh_at = now(), enqueue fetch_github_contributions(user_id)
  → Return { status: "queued", next_refresh_available_at: <iso8601> }
  → React polls GET /api/me/github/contributions/status/ until done or times out
```

### 3.4 Disconnect GitHub

```
DELETE /api/me/github/
  → Delete GitHubConnection row (CASCADE removes contribution data)
  → Return 204
```

---

## 4. Data Model

### 4.1 `GitHubConnection`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `user_id` | FK → User | UNIQUE (one connection per member) |
| `github_user_id` | bigint | Stable across renames; used as the canonical identifier |
| `github_login` | varchar(40) | Display only; updated on each fetch |
| `access_token` | text (encrypted) | Encrypted at rest (see §8) |
| `token_valid` | boolean | Set false on 401/403 from GitHub |
| `connected_at` | timestamptz | |
| `last_manual_refresh_at` | timestamptz | Nullable; enforces the 1-hour cooldown |

Index: `(user_id)` unique; `(github_user_id)` for reverse lookup.

### 4.2 `GitHubContributionCache`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `github_connection_id` | FK → GitHubConnection | CASCADE DELETE |
| `fetched_at` | timestamptz | When this snapshot was retrieved |
| `total_contributions` | int | Trailing-year total |
| `current_streak` | int | Days |
| `longest_streak` | int | Days |
| `weeks` | jsonb | Array of 53 week objects (see §4.3) |
| `fetch_status` | varchar(20) | `ok`, `rate_limited`, `token_invalid`, `error` |

Index: `(github_connection_id)` — one active row per connection (we upsert).

### 4.3 `weeks` JSONB Schema

```json
[
  {
    "week_start": "2025-05-26",
    "days": [
      { "date": "2025-05-26", "count": 3, "level": 2 },
      ...
    ]
  },
  ...
]
```

`level` maps contribution count to GitHub's 0–4 intensity scale, computed server-side so the frontend is purely presentational.

---

## 5. API Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/auth/github/connect/` | Session | Initiate OAuth flow |
| `GET` | `/auth/github/callback/` | — | OAuth redirect handler |
| `DELETE` | `/api/me/github/` | JWT (owner) | Disconnect GitHub |
| `POST` | `/api/me/github/refresh/` | JWT (owner) | Queue a manual refresh |
| `GET` | `/api/me/github/contributions/status/` | JWT (owner) | Poll fetch status |
| `GET` | `/api/profiles/{username}/` | Optional | Public profile (includes widget data) |

### `GET /api/profiles/{username}/` — widget payload

```json
{
  "username": "alice",
  "github": {
    "connected": true,
    "login": "alice-gh",
    "fetched_at": "2026-05-23T08:00:00Z",
    "total_contributions": 847,
    "current_streak": 12,
    "longest_streak": 45,
    "weeks": [ ... ]
  }
}
```

If `connected` is false, the `github` key is omitted entirely (no widget rendered by the frontend).  
If the profile's privacy setting is non-public, `github` is omitted for non-owners.

### `POST /api/me/github/refresh/` — responses

| Scenario | HTTP | Body |
|---|---|---|
| Queued successfully | 202 | `{ "status": "queued", "next_refresh_available_at": "..." }` |
| Still on cooldown | 429 | `{ "status": "cooldown", "next_refresh_available_at": "..." }` |
| No GitHub connection | 404 | `{ "error": "not_connected" }` |

---

## 6. Background Task: `fetch_github_contributions`

**Queue:** `github_contributions` (dedicated Celery queue, low priority)  
**Retry policy:** 3 attempts, exponential back-off (30 s, 2 min, 8 min), then mark `fetch_status = error`  
**Task signature:** `fetch_github_contributions(user_id: int)`

### Algorithm

```
1. Load GitHubConnection for user_id; abort if not found.
2. Call GitHub GraphQL API (contributionsCollection) with the stored access_token.
3. On success:
   a. Compute streaks and intensity levels.
   b. Upsert GitHubContributionCache (overwrite previous row).
   c. Update GitHubConnection.github_login (handle renames).
   d. Set fetch_status = 'ok', fetched_at = now().
4. On HTTP 401/403:
   a. Set GitHubConnection.token_valid = False.
   b. Set fetch_status = 'token_invalid'. Do NOT retry.
5. On HTTP 429 (rate limit):
   a. Set fetch_status = 'rate_limited'. Do NOT retry immediately.
   b. Respect Retry-After header; reschedule once if header ≤ 3600 s.
6. On network error / 5xx:
   a. Raise exception → Celery retries per retry policy.
```

### Automatic 24-hour Refresh

A Celery Beat periodic task (`refresh_stale_contributions`) runs every hour and enqueues `fetch_github_contributions` for any `GitHubConnection` where:

```sql
SELECT gc.user_id
FROM github_contributions_cache c
JOIN github_connection gc ON gc.id = c.github_connection_id
WHERE c.fetched_at < now() - interval '24 hours'
  AND gc.token_valid = true
```

This means data is never more than ~25 hours old without owner action, and the GitHub API is called at most once per 24 hours per user on the background path.

---

## 7. Caching Strategy Summary

| Layer | TTL / Rule | Rationale |
|---|---|---|
| PostgreSQL `GitHubContributionCache` | Replaced on each fetch | Single source of truth; survives server restarts |
| Automatic background refresh | Every 24 hours per user | Blueprint requirement; keeps data reasonably fresh |
| Owner manual refresh | 1 request per 60 minutes | Blueprint requirement; enforced server-side in DB |
| Django view-level HTTP cache | `Cache-Control: public, max-age=300` on public profile endpoint | Edge/CDN can serve profile pages for 5 min without hitting Django; short enough that new data shows within 5 min of a refresh completing |
| React component | No local caching; fetches on mount | Widget always shows data as of the last page load |

**No Redis is introduced for this feature.** The cooldown check is a single DB read (`last_manual_refresh_at`) and the data store is PostgreSQL, keeping the operational surface minimal.

---

## 8. Security

### Token Storage
- `GitHubConnection.access_token` is encrypted at the application layer using Django's `django-fernet-fields` (or equivalent). The plaintext token is never written to logs or included in API responses.
- The token is read only inside the Celery worker context; it is not exposed through any API endpoint.

### OAuth State Parameter
- A CSRF `state` token is generated per OAuth initiation, stored in the user's session, and validated on callback. Mismatched or missing state → reject.

### Visitor Isolation
- The public profile endpoint never returns `access_token`, `token_valid`, or any GitHubConnection metadata other than the rendered contribution data.
- `POST /api/me/github/refresh/` requires authentication and checks that the authenticated user owns the connection. There is no endpoint that accepts a target `user_id` from the caller.

### Rate-Limit Enforcement
- The 1-hour cooldown is checked against `last_manual_refresh_at` in the database, not a cookie or client-supplied timestamp. Concurrent requests for the same user are serialised with `SELECT FOR UPDATE` on the `GitHubConnection` row to prevent race-condition bypasses.

---

## 9. Frontend (React)

### Component: `<GitHubContributionsWidget />`

**Props received from the profile API response:**
```ts
interface GitHubWidgetData {
  login: string;
  fetched_at: string;        // ISO-8601
  total_contributions: number;
  current_streak: number;
  longest_streak: number;
  weeks: Week[];
}
```

**Rendering rules:**
- If `total_contributions === 0`: render empty grid + "No public contributions yet."
- Otherwise: render the 53-week grid using the `level` field (0–4) for colour intensity.
- Always show "Last updated `<relative time>`" using `fetched_at`.
- If profile owner and `token_valid === false` (returned only to the owner): show "Reconnect GitHub" prompt in place of the grid.

### Refresh Button (owner only)

- Shown only when `isOwner === true`.
- On click: `POST /api/me/github/refresh/`; start polling `GET /api/me/github/contributions/status/` every 3 seconds.
- On `fetch_status === 'ok'`: reload widget data, clear polling.
- On `fetch_status === 'rate_limited'`: display "Couldn't refresh right now, try again later."
- On 429 response from refresh endpoint: parse `next_refresh_available_at`, show countdown timer.
- Cooldown timer ticks client-side, re-enables button when `next_refresh_available_at` is reached (button disabled until then).

---

## 10. Error States and Degradation

| Condition | Owner sees | Visitor sees |
|---|---|---|
| Data fresh (< 24 h, `fetch_status = ok`) | Grid + stats | Grid + stats |
| GitHub unreachable (last fetch was ok) | Last grid + "Last updated X" | Same |
| Token revoked / expired | "Reconnect GitHub" prompt | Last stored grid + "Last updated X" |
| Rate limited on manual refresh | Toast: "Couldn't refresh right now, try again later" | Unchanged (last grid) |
| Never connected | "Connect GitHub" button (settings) | No widget |
| Zero contributions | Empty grid + "No public contributions yet." | Same |
| Profile set to private | Full widget visible | No widget shown |

Visitors are never shown a hard error. The widget either renders from cache or is absent entirely.

---

## 11. Disconnect Flow

1. Member calls `DELETE /api/me/github/`.
2. Django deletes the `GitHubConnection` row; `CASCADE` removes `GitHubContributionCache`.
3. Django revokes the GitHub token via `DELETE https://api.github.com/applications/{client_id}/token` (best-effort; failure is logged but does not block the disconnect response).
4. Response: 204 No Content.
5. The settings page re-shows the "Connect GitHub" button. The public profile no longer includes the `github` key; the widget disappears.

---

## 12. GitHub API Usage

### Endpoint
GitHub GraphQL API — `contributionsCollection` query, trailing 365 days from request date.

```graphql
query($from: DateTime!, $to: DateTime!) {
  viewer {
    login
    contributionsCollection(from: $from, to: $to) {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date
            contributionCount
          }
        }
      }
    }
  }
}
```

### Rate Limit Posture
- GraphQL API: 5,000 points/hour per token; this query costs ~1 point.
- We call it at most once per 24 hours per user on the background path, and at most once per hour on the manual-refresh path.
- On a 429 response we respect the `Retry-After` header and set `fetch_status = 'rate_limited'` rather than retrying blindly.

---

## 13. Django App Structure

```
github_widget/
  models.py          # GitHubConnection, GitHubContributionCache
  views.py           # OAuth flow, refresh endpoint, disconnect
  serializers.py     # DRF serialisers for API responses
  tasks.py           # fetch_github_contributions, refresh_stale_contributions
  services.py        # GitHub API client, streak computation, intensity mapping
  urls.py
  admin.py
  tests/
    test_oauth.py
    test_tasks.py
    test_api.py
    test_services.py
```

---

## 14. Database Migrations Outline

1. `0001_create_github_connection.py` — create `GitHubConnection` table.
2. `0002_create_github_contribution_cache.py` — create `GitHubContributionCache` table with FK + CASCADE.

No changes to the `User` model; the connection is a separate table with a unique FK.

---

## 15. Observability

| Signal | What to track |
|---|---|
| Celery task success/failure | `fetch_github_contributions` outcome (ok / token_invalid / rate_limited / error) |
| API latency | P50/P99 on GitHub GraphQL calls, tracked in `services.py` |
| Cooldown 429s | Count of refresh requests rejected by cooldown (indicates owner scripting attempts) |
| Token invalidity rate | How often `token_valid` flips to false; spike = GitHub policy change or mass revocation |
| Stale data age | Histogram of `now() - fetched_at` for connected accounts; alert if > 26 h |

---

## 16. Open Questions / Future Work

- **Webhook-based refresh:** GitHub does not offer a contribution-update webhook, so polling is the only option. If GitHub adds one in future, the `fetch_github_contributions` task can be triggered on demand.
- **Fine-grained OAuth scopes:** `read:user` is the minimum required scope. If the member has private-contribution visibility enabled on GitHub, the same scope returns them; no additional scope is needed.
- **Multiple GitHub accounts:** The blueprint implies one connection per member (UNIQUE constraint on `user_id`). If multi-account support is ever needed, the UNIQUE constraint and widget layout would need revisiting.
