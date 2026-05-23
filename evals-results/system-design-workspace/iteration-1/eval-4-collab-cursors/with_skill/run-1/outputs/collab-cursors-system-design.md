# System Design: Real-Time Collaborative Cursors

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [../inputs/collab-cursors-blueprint.md](../inputs/collab-cursors-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The presence layer is implemented as a **WebSocket hub** co-located with the existing Node backend. Each connected client maintains a persistent WebSocket connection; cursor-position messages are broadcast peer-to-peer within a document room by the hub. No cursor data is persisted — presence is purely in-memory, stored in the hub process (or a shared Redis pub/sub channel when the hub scales beyond one process). The single most important architectural choice is **WebSocket over polling**: the blueprint's 250 ms end-to-end motion-to-render budget cannot be met with any polling interval that is also cheap to operate, and WebSocket is the only push primitive available in all modern browsers without a third-party service. This is a new, self-contained `PresenceService` module added to the Node backend; no existing REST routes, Postgres schema, or editor logic is touched.

---

## 2. System Placement

```
Browser (React)
  └─ PresenceClient (hook/context)
       ├─ sends:  { type: "cursor_move", docId, pos, selection }
       └─ receives: { type: "cursor_update", userId, pos, selection, color, name }
            │
            │  WebSocket  (ws://host/presence)
            ▼
Node Backend
  └─ PresenceGateway  (new — WebSocket server, thin router)
       └─ PresenceService  (new — in-memory room state, auth, throttle)
            ├─ auth:  verifies JWT / session cookie before accepting connection
            ├─ rooms: Map<docId, Map<sessionId, CursorState>>
            └─ pub/sub bridge → Redis (when >1 process)
```

**Components touched:**
- **New:** `PresenceGateway` — WebSocket server (e.g., `ws` library), lives alongside the existing Express app, bound to the same port on a distinct upgrade path (`/presence`).
- **New:** `PresenceService` — room state, participant lifecycle, per-client throttle, idle fade timer.
- **Existing (read-only at connection time):** Auth middleware — reused to validate the JWT/session before upgrading to WebSocket.
- **Existing (no change):** Document REST API, Postgres schema, editor logic.
- **New (optional, horizontal-scale path):** Redis pub/sub channel per `docId` — used only if the backend runs as more than one process.

---

## 3. Architecture Decisions

### D1. Transport: WebSocket (not polling, not SSE)

- **Decision:** Use persistent WebSocket connections for all presence messages. The existing Node server handles WebSocket upgrades on `/presence`.
- **Why:** The blueprint mandates sub-250 ms perceived latency for cursor motion. Polling at any practical interval (e.g., 200 ms) doubles the worst-case latency and multiplies server load with the participant count. Server-Sent Events (SSE) is one-directional and would still require a separate HTTP POST for each outgoing cursor position, adding a round-trip. WebSocket is bidirectional, has near-zero overhead per message, and is universally supported. Upholds: *Design for the measured requirement* (Principle 8) and *fewest moving parts* (Principle 1).
- **Alternatives considered:**
  - *Long-polling* — worst-case latency O(poll interval); not viable for <250 ms target.
  - *SSE + REST POST* — works but two separate connections per client; more complex client-side lifecycle.
  - *Managed service (e.g., Pusher, Ably, Liveblocks)* — offloads infra but adds an external dependency, data-egress cost, and a vendor trust boundary for user presence data. Rejected to keep the initial design simple and in-house; flagged as a future escape valve (see Open Risks).
- **Trade-off accepted:** The backend now maintains long-lived stateful connections; horizontal scaling requires a pub/sub fan-out layer (Redis). This is the right trade-off: without scale pressure today, the Redis path is additive and does not affect the initial deployment.

---

### D2. In-process room state (+ Redis pub/sub at scale)

- **Decision:** Each `PresenceService` instance keeps an in-memory `Map<docId, Map<sessionId, CursorState>>`. When the backend scales to multiple processes/instances, a Redis pub/sub channel per `docId` fans out updates between instances. Presence state is never written to Postgres.
- **Why:** Cursor data is ephemeral by definition (blueprint: "never saved, no value once the session ends"). Writing it to a database would add latency, schema complexity, and meaningless records. In-memory is the correct durability tier for this data. Upholds: *Get the data model right* (Principle 4), *simplicity first* (Principle 1).
- **Alternatives considered:**
  - *Postgres presence table* — unnecessary durability cost; querying it on every cursor move would blow the latency budget.
  - *Redis as the primary store (no in-process state)* — adds a Redis round-trip (~1–2 ms) to every broadcast even with a single process; premature.
- **Trade-off accepted:** If the backend process crashes, all presence for all documents is lost. Users see everyone else's cursor disappear and reappear on reconnect — acceptable because the blueprint explicitly classifies cursors as ephemeral and defines graceful degradation for service unavailability.

---

### D3. Message throttle: client-side rate-limiting + server-side per-client cap

- **Decision:** The React `PresenceClient` throttles `mousemove`/`selectionchange` events to at most **50 messages/second per client** (20 ms minimum interval) before sending. The server enforces an independent per-connection hard cap of **100 messages/second**, dropping excess silently for that client. Throttle values are configurable via environment variables.
- **Why:** Raw `mousemove` events fire at display refresh rate (60–120 Hz). Broadcasting unthrottled would multiply network load by participants × refresh rate. 50 Hz is imperceptible to humans for cursor tracking and keeps per-client bandwidth under ~5 KB/s for a typical message payload. Upholds: *Idempotency & bounded operations* (Principle 6); addresses blueprint adversarial scenario: "A flood of rapid cursor updates from one client must not degrade the experience for everyone else."
- **Alternatives considered:**
  - *Server-only throttle* — still puts unnecessary load on the network and parsing path; client-side throttle is free.
  - *Debounce only* — would introduce perceptible lag on fast continuous movement.
- **Trade-off accepted:** A client that is genuinely moving the cursor at >100 events/second will have some positions silently dropped. The visual effect is imperceptible since each dropped frame is immediately followed by the next real position.

---

### D4. Color and name assignment: server-authoritative, per-session

- **Decision:** When a client connects, `PresenceService` assigns a color from a fixed palette (e.g., 12 distinct colors) by hashing `userId + docId`. The user's display name is taken from the authenticated session (the same source as the existing application). Both color and name are attached by the server to every outgoing `cursor_update` broadcast, never trusted from the client.
- **Why:** Blueprint: "A user must not be able to spoof another user's name or color." Client-supplied identity is trivially forgeable. Server-side assignment from authenticated data is the only correct model. Upholds: *Security & privacy by design* (Principle 11).
- **Alternatives considered:**
  - *Client-supplied color/name* — rejected; spoofable.
  - *Stored color preference* — unnecessary persistence; hashing produces stable, session-consistent colors without storage. The blueprint says "stable color for the duration of their session", which hash assignment satisfies.
- **Trade-off accepted:** Two users with the same `userId + docId` hash bucket will get the same color. With 12 colors this is rare; a future enhancement could use a per-document color-claim mechanism to guarantee uniqueness, but that adds state and is not required now.

---

### D5. Participant lifecycle: heartbeat + server-side TTL

- **Decision:** The server tracks a `lastSeen` timestamp per participant. Clients send a **heartbeat ping** every **15 seconds** using the WebSocket protocol-level ping frame (no application message). If no ping is received for **30 seconds**, the server removes the participant and broadcasts a `cursor_leave` event. On clean disconnect (`close` event), removal is immediate.
- **Why:** The blueprint requires cursors to disappear "within a few seconds" of a user leaving, and specifies that brief network drops should freeze the cursor rather than immediately remove it. A 30 s TTL gives a 30 s reconnect window before eviction, matching typical TCP keepalive behavior. Upholds: *Design for failure* (Principle 5); maps to blueprint deviation scenario: "A user's network drops briefly."
- **Alternatives considered:**
  - *Application-level heartbeat messages* — more overhead than protocol-level ping/pong; rejected in favor of the built-in mechanism.
  - *Immediate removal on any error* — too aggressive; causes flicker on brief network hiccups.
  - *Long TTL (e.g., 5 min)* — stale cursors remain visible far too long after a disconnect; violates the blueprint.
- **Trade-off accepted:** There is a up-to-30 s window where a disconnected user's cursor remains visible. The blueprint explicitly accepts this ("freezes in place, then disappears once the disconnect is detected"), so no mitigation is needed.

---

### D6. Authorization: validate document access on WebSocket upgrade

- **Decision:** Before accepting a WebSocket upgrade for `docId`, the `PresenceGateway` calls the existing authorization check (the same function used by the REST document-read route) to verify the connecting user has read access to the document. If the check fails, the upgrade is rejected with HTTP 403.
- **Why:** Blueprint adversarial scenario: "A user must only receive cursor data for documents they are allowed to open." The simplest, most auditable enforcement point is at connection time — a single gate before any presence data flows. Upholds: *Security & privacy by design* (Principle 11), *high cohesion, loose coupling* (Principle 3 — reuse the existing auth logic, don't duplicate it).
- **Alternatives considered:**
  - *Validate on every message* — expensive; unnecessary if the connection is already authorized.
  - *Trust the client-supplied docId without checking* — rejected outright.
- **Trade-off accepted:** If a user's document access is revoked while they have an open WebSocket, they continue to receive presence updates until their connection times out or they reconnect. Acceptable initially; a future enhancement can push a `force_disconnect` event when access is revoked (see Open Risks).

---

### D7. Idle-fade state: client-side timer, server-aware

- **Decision:** The client sets a **3-minute inactivity timer** after the last cursor-move event. On expiry, it sends a `cursor_idle` message to the server, which broadcasts it to peers. Peers render the cursor at reduced opacity. When the next cursor-move arrives, the client sends a `cursor_active` message and full opacity is restored. The server does not evict idle participants.
- **Why:** Blueprint: "after a few minutes with no movement, their cursor fades but is not removed." The idle state is a UI hint, not a connectivity state. Keeping it client-driven minimizes server logic. Upholds: *Simplicity first* (Principle 1), *high cohesion* (Principle 3 — the rendering concern stays in the client).
- **Alternatives considered:**
  - *Server-driven idle detection* — server would need to track per-client last-move time separately from last-ping time; more state and logic for the same outcome.
- **Trade-off accepted:** If a client crashes without sending `cursor_idle`, the cursor will remain at full opacity until the TTL evicts it. Acceptable — the cursor will still disappear within the heartbeat window.

---

### D8. Crowding: client-side cap at display

- **Decision:** The `PresenceClient` renders at most **12 cursors** on screen. When the room has more than 12 remote participants, it renders 12 cursors and a `+N others` badge (as specified in the blueprint). The server still broadcasts all participants' positions; the client chooses which 12 to render (preferring most recently active).
- **Why:** Blueprint: "beyond a dozen or so participants, show a count (+8 others)." This is a rendering heuristic, not a data constraint. Keeping it client-side means the server stays simple and all clients can independently decide their rendering threshold (useful if different surfaces have different UI). Upholds: *Simplicity first* (Principle 1), *high cohesion* (Principle 3).
- **Alternatives considered:**
  - *Server-side participant filtering* — would require the server to know display viewport, which it doesn't. Rejected.
- **Trade-off accepted:** Each client still receives all cursor updates for all participants in the document. For very large rooms (e.g., 100+ participants) this is wasteful. At that scale, a server-side fan-out filter would be warranted (see Open Risks).

---

### D9. Multi-tab: each tab is an independent session

- **Decision:** Each browser tab connecting to `/presence` gets a unique `sessionId` (a UUID generated at connect time), separate from `userId`. The server treats each tab as a distinct participant. The client never renders its own `sessionId`'s cursor (matching `userId` alone would hide all tabs of the user from themselves; matching `sessionId` is precise).
- **Why:** Blueprint: "A user opens the same document in two tabs: each tab is its own participant with its own cursor." Upholds: *Make illegal states unrepresentable* (Principle 9) — the data model naturally represents this without special casing if sessionId ≠ userId.
- **Trade-off accepted:** A user with 5 tabs in the same document will occupy 5 cursor slots out of the 12-visible limit. Edge case; acceptable.

---

## 4. Data Model & Persistence

**No Postgres schema changes.** Cursor data is never persisted.

**In-memory structures (PresenceService):**

```typescript
interface CursorState {
  sessionId: string;      // unique per tab
  userId: string;         // from auth session
  displayName: string;    // from auth session
  color: string;          // assigned by server (hex)
  pos: { line: number; ch: number };
  selection?: { anchor: { line: number; ch: number }; head: { line: number; ch: number } };
  lastSeen: number;       // Date.now() — used for TTL eviction
  idle: boolean;          // set by cursor_idle message
}

// Server-side room map
rooms: Map<docId, Map<sessionId, CursorState>>
```

**Wire message schemas (JSON over WebSocket):**

```typescript
// Client → Server
{ type: "cursor_move",  docId: string, pos: Position, selection?: Selection }
{ type: "cursor_idle",  docId: string }
{ type: "cursor_active",docId: string }

// Server → Client (broadcast to all other participants)
{ type: "cursor_update", sessionId: string, userId: string, displayName: string,
  color: string, pos: Position, selection?: Selection, idle: boolean }
{ type: "cursor_leave",  sessionId: string }
{ type: "room_snapshot", participants: CursorState[] }  // sent to new joiner
```

**Retention:** All in-memory state is destroyed when the process exits. There is no migration, backup, or replay concern.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| **Redis** (optional) | Pub/sub fan-out between backend processes when horizontally scaled | Internal network, no auth required in a VPC; connection string via env var `REDIS_URL` | Minimal — presence messages are small (<200 bytes); Redis pub/sub has no per-message cost beyond infra | If Redis is unavailable, `PresenceService` falls back to single-process mode silently; clients in different processes won't see each other, but won't error | Integration tested with a local Redis instance in CI; unit tests stub the pub/sub interface |

No other external services. The presence layer is entirely self-contained within the existing backend infrastructure.

*Note:* If the team later adopts a managed presence service (Liveblocks, Ably, Pusher), the `PresenceGateway`/`PresenceService` boundary is the clean swap point. That evaluation belongs to a future ADR, not this document.

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Budget source |
|---|---|---|---|
| Cursor move → peer sees it | < 80 ms | < 200 ms | Blueprint: "visible lag of more than ~250 ms feels broken" |
| User joins → others see cursor | < 500 ms | < 1 s | Not specified; reasonable UX expectation |
| User leaves → cursor disappears | < 30 s | < 30 s | Heartbeat TTL (D5) |

**Budget decomposition for cursor move:**
- Client throttle delay: 0–20 ms (D3)
- Network RTT (WAN): ~30–80 ms
- Server broadcast (in-process): < 5 ms
- React re-render: < 5 ms
- **Total p95 estimate: ~110 ms** — well within the 250 ms budget.

### Expected load

| Metric | Estimate | Basis |
|---|---|---|
| Concurrent WebSocket connections | ~500 initial, up to ~5,000 at growth | Assumed (see §11, A3) |
| Messages/sec per active client | ~50 peak, ~5 average | D3 throttle |
| Peak server messages/sec | ~2,500 (500 clients × 5 avg) | Calculated |
| Peak broadcast fan-out | 12 peers × 2,500 = 30,000 msg/s | Worst case, single process |

Node's event loop handles >100,000 small async I/O operations/second; 30,000 msg/s is well within range for a single process. Horizontal scaling (multiple processes) adds Redis pub/sub but is additive, not required at initial deployment.

### Caching

There is no traditional caching layer. The in-memory room state IS the live cache — it is the authoritative source of current presence, and it is invalidated in real time by each incoming message. There is no TTL-based staleness concern because updates arrive continuously.

The **room snapshot** message (sent to a new joiner on connect) serves as the cache-warming step: the new participant immediately receives the current state of the room without waiting for other clients to move.

### Concurrency model

- Single Node process: all room operations happen in the event loop; no locks needed (JavaScript single-threaded event loop).
- Multi-process: Redis pub/sub serializes cross-process broadcasts; room state per process may temporarily diverge by up to one Redis round-trip (~1–2 ms). Acceptable for presence data.

---

## 7. Reliability & Failure Handling

| Failure | Detection | Response | User experience | Blueprint ref |
|---|---|---|---|---|
| Client network drop | Heartbeat timeout (30 s) | Server evicts participant; broadcasts `cursor_leave` | Others see cursor freeze, then disappear | Deviation: "network drops briefly" |
| Client reconnect | New WebSocket connection | Server issues new `sessionId`, sends `room_snapshot`, broadcasts join | Cursor reappears; a brief gap where the cursor was absent is acceptable | Same |
| Server process crash | Load balancer health check | All clients reconnect; room state rebuilt from reconnects | All cursors disappear and reappear within reconnect window | Deviation: "presence service unavailable" |
| PresenceService unavailable | WS upgrade fails with 5xx | Client catches error; does NOT block document load | Editor opens normally, no cursors shown, no error message to user | Deviation: "presence service unavailable — document still opens" |
| Redis unavailable | Pub/sub subscription error | Fall back to single-process mode; log warning | Users on the same process see each other; users on different processes do not | Internal — Redis is optional |
| Stale/out-of-order cursor message | Sequence number on each message | Receiver discards if `seq` < last seen `seq` for that `sessionId` | No visual glitch; latest position wins | Deviation: "out-of-order updates" |
| Message flood from one client | Per-connection server cap (D3) | Excess messages dropped; no disconnect | Other participants unaffected | Adversarial: "flood of rapid updates" |

**Retry policy:** The React `PresenceClient` uses exponential backoff (1 s, 2 s, 4 s, max 30 s) with jitter for reconnection attempts. It does not surface errors to the user — the editor remains fully functional.

**Timeouts:** WebSocket upgrade: 10 s. Auth check on upgrade: 2 s.

**Circuit breaker:** Not applicable — the PresenceService has no downstream it needs to protect against. Redis connection errors are handled by the fallback mode above.

---

## 8. Security & Privacy

### Authentication & authorization

- **Connection-time auth (D6):** The WS upgrade request must carry the same session cookie or `Authorization: Bearer <jwt>` header as REST requests. The existing auth middleware is called; failure → HTTP 403, no upgrade.
- **Document access check (D6):** After auth, the server verifies the user has read permission for `docId` using the existing document authorization function.
- **Re-auth:** No mid-connection re-auth is performed. If access is revoked, the connection persists until the next reconnect (see Open Risks, OR2).

### Input validation

- All messages from the client are validated against a strict JSON schema at the gateway before passing to `PresenceService`.
- `pos` fields (line, ch) are clamped to non-negative integers; invalid messages are dropped silently (no disconnect).
- `docId` in each message must match the `docId` the connection was authorized for; mismatches are dropped.

### Identity integrity (D4)

- `displayName` and `color` are always server-assigned from the authenticated session. Client-supplied identity fields are ignored.

### PII exposure

- `displayName` (user's display name) is broadcast to all participants in the same document room. This is intentional and consistent with the application's document-sharing model — if you can open the document, you can see who else has it open.
- No email addresses, internal user IDs beyond `userId`, or other PII are included in cursor messages.

### Abuse vectors

| Vector | Mitigation |
|---|---|
| Spoofed identity | Server-assigned name/color (D4) |
| Message flood | Per-connection rate cap, client-side throttle (D3) |
| Cross-document snooping | docId checked on upgrade and per-message (D6) |
| Unauthorized join | Auth gate on WS upgrade (D6) |
| Large payload injection | Message size cap: 512 bytes max per message; larger messages dropped |

---

## 9. Observability

### Metrics (emit to existing metrics backend)

| Metric | Type | Alert threshold |
|---|---|---|
| `presence.connections.active` | Gauge | — (capacity planning) |
| `presence.rooms.active` | Gauge | — |
| `presence.messages.received_per_sec` | Counter | — |
| `presence.messages.dropped_rate` (throttle drops / total) | Gauge | > 5% over 1 min → warn |
| `presence.connection.auth_failures_per_min` | Counter | > 50/min → alert (potential abuse) |
| `presence.participant.evictions_per_min` | Counter | Spike → investigate network issues |
| `presence.ws_upgrade_latency_ms` | Histogram (p50/p95/p99) | p95 > 500 ms → alert |
| `presence.broadcast_latency_ms` | Histogram (p50/p95) | p95 > 50 ms → alert |

### Logs

- `INFO` on connect/disconnect (sessionId, userId, docId, reason).
- `WARN` on auth failure, message drop (throttle exceeded), schema validation failure.
- `ERROR` on Redis connection failure or unexpected exception.
- No cursor position data in logs (unnecessary volume; no diagnostic value).

### Traces

- Distributed trace span on WS upgrade (includes auth + docId check).
- No per-message spans (too high frequency; metrics suffice).

### The one signal that proves the feature is healthy

**`presence.broadcast_latency_ms` p95 < 50 ms, measured end-to-end at the server.** If this is green and `presence.messages.dropped_rate` is near zero, the presence layer is working correctly.

### Health check

Add `/health/presence` to the backend: returns `{ status: "ok", connections: N, rooms: M }`. Used by load balancers and the runbook.

---

## 10. Rollout & Operability

### Feature flag

Gate the entire presence layer behind a feature flag `collab_cursors_enabled` (boolean, default: `false`).

- **Backend:** `PresenceGateway` checks the flag on each WS upgrade attempt; returns HTTP 503 with body `{"error":"presence_disabled"}` if off.
- **Frontend:** `PresenceClient` checks the flag before attempting to connect; skips silently if disabled.
- **Fail mode:** Flag off or unreadable → no cursors, editor unaffected. This is fail-closed for the presence feature but fail-open for the core editor — consistent with the blueprint's degradation requirement.

### Rollout sequence

1. **Backend deploy** — `PresenceGateway` + `PresenceService` ship with flag `off`. No user impact.
2. **Frontend deploy** — `PresenceClient` ships with flag `off`. No user impact.
3. **Internal enable** — Flag on for internal users/documents. Smoke test; verify observability signals.
4. **Staged rollout** — Enable for 5% → 25% → 100% of documents, watching `broadcast_latency_ms` and `messages.dropped_rate`.
5. **Full enable** — Remove flag gate in a follow-up PR once stable.

### Reversibility

Rolling back is a flag flip. No database migrations, no schema changes, no data to backfill. Fully reversible at any stage.

### Deploy coordination

Frontend and backend can deploy independently (flag gates both). No coordinated cut-over required.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | The Node backend uses the `ws` npm library or an equivalent that supports WebSocket upgrades on the existing HTTP server | `ws` is the de-facto standard for Node WebSocket; straightforward to add alongside Express | Yes — confirm the backend has no policy against adding WebSocket to the existing server |
| A2 | The backend currently runs as a **single process** (or a small fixed number) at initial deployment | Consistent with a REST-only Node app; Redis pub/sub path is additive and not required on day one | Yes — confirm whether horizontal scaling (multiple processes) is in scope for the initial deploy |
| A3 | Concurrent active users in a single document rarely exceed ~50; document rooms with >100 participants are exceptional | Typical for collaborative productivity apps at early/mid scale | Yes — if the product has known high-concurrency documents (e.g., live classrooms), the fan-out design needs revisiting |
| A4 | The existing session/JWT mechanism is accessible as a callable function from the new PresenceGateway module | Standard in Node apps; auth middleware is typically importable | Confirm auth is not tightly coupled to Express middleware chain in a way that prevents reuse |
| A5 | The React frontend has a global/context-level document state that knows the active `docId` and current user identity | Reasonable for any editor app; needed to bootstrap the PresenceClient | Confirm the frontend has a clean place to mount the PresenceClient context |
| A6 | The infrastructure allows persistent WebSocket connections (no aggressive load-balancer timeout, no WebSocket-stripping proxy) | Standard in modern cloud infrastructure; may need sticky sessions for multi-process | Yes — confirm load balancer supports WebSocket pass-through and what the idle connection timeout is |
| A7 | Redis is already available in the infrastructure (or easily provisioned) for the multi-process scale path | Redis is ubiquitous in Node stacks; often already present for sessions or caching | Confirm Redis availability if multi-process is in scope for initial deploy |
| A8 | Display name for each user is available in the JWT/session payload, not requiring a DB lookup per connection | Typical for JWT-based auth | Confirm what fields the JWT/session carries |
| A9 | The blueprint's "~250 ms" latency threshold is a UX guideline, not a contractual SLO | Framed as "feels broken" in the blueprint, not a hard SLO | No — treat as a design target |
| A10 | No offline/PWA mode is in scope; clients without a network connection will not receive presence updates | Out of scope per blueprint; no offline editing is mentioned | No |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | Up to 30-second stale cursor after network drop | Instant cursor removal | *Design for failure* (Principle 5) | Blueprint explicitly accepts a freeze-then-disappear window; 30 s is within tolerable UX range | If UX testing shows users are confused by stale cursors, reduce TTL to 10 s |
| C2 | No mid-connection re-authorization | Revoked access can still receive presence for up to TTL window | *Security & privacy by design* (Principle 11) | Access revocation is an edge case; presence data (cursor positions) is low-sensitivity compared to document content, which is already denied at the REST layer | When a permission-revocation push event is added to the app, wire it to force-disconnect presence connections |
| C3 | All participant cursor positions broadcast to all clients in the room | Higher bandwidth for large rooms | *Idempotency & bounded operations* (Principle 6) | Acceptable at initial scale (<50 participants); server-side fan-out filter would add significant complexity for a case that doesn't yet exist | When average room size exceeds 50 or latency targets are missed, add server-side viewport filtering |
| C4 | Color assigned by hash (not guaranteed unique within a room) | Possible duplicate colors for two users | *Principle of least surprise* (Principle 14) | With 12 colors and typical room sizes, collisions are rare; guaranteed uniqueness requires per-document color-claim state | Add per-document color claim if user research shows collisions cause confusion |
| C5 | Single tab = single sessionId; no cross-tab coordination | A user with 5 tabs uses 5 of the 12 visible cursor slots | *Simplicity first* (Principle 1) | Blueprint explicitly defines each tab as its own participant | Add cross-tab cursor merging if the 12-slot limit proves constraining in practice |

---

## 13. Open Risks & Callouts

| ID | Risk | Likelihood | Impact | Mitigation / Watch |
|---|---|---|---|---|
| OR1 | WebSocket connections exhaust file descriptors or memory under unexpected load spike | Low | High | Monitor `presence.connections.active`; set OS-level `ulimit` appropriately; add a hard connection cap per document room (e.g., 200) |
| OR2 | Revoked document access does not terminate existing presence connection (C2) | Low | Medium | Accept now; future work: listen to access-revocation events and call `PresenceService.forceDisconnect(userId, docId)` |
| OR3 | Load balancer terminates idle WebSocket connections before heartbeat window | Medium | High | Confirm LB idle timeout (A6); if shorter than 30 s, reduce heartbeat interval or configure LB keep-alive |
| OR4 | Very large documents with 100+ simultaneous participants exceed broadcast fan-out capacity | Low (initially) | Medium | Monitor room sizes; if rooms regularly exceed 50, implement server-side participant fan-out filtering |
| OR5 | Third-party managed presence service (Liveblocks / Ably) provides better economics at scale | Unknown | Low | The `PresenceGateway`/`PresenceService` boundary is the clean swap point; evaluate at scale |
| OR6 | Blueprint does not specify behavior when document is deleted while users have it open | N/A for this design | Medium | Flag for the blueprint: what should happen to presence connections when a document is deleted? Likely: broadcast `force_leave`, close connections |

---

## 14. Out of Scope

Per the blueprint and this design:

- **Collaborative document editing / conflict resolution** — handled by the existing editor; this design adds only the presence layer.
- **Persisting or replaying cursor history** — explicitly out of scope in the blueprint.
- **Voice, video, or chat presence** — out of scope in the blueprint.
- **Cursor-aware scroll or viewport synchronization** — not in the blueprint.
- **Offline editing or PWA cursor buffering** — not in scope.
- **Server-side viewport filtering for large rooms** — identified as a future enhancement (OR4); not designed here.
- **Cross-tab cursor deduplication** — future enhancement (C5).
- **Admin tooling for presence monitoring** — operational tooling, not part of the feature design.

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6 — p95 < 200 ms; budget decomposition provided |
| A2 Throughput & scale | Resolved | §6 — load estimates, single-process capacity analysis, Redis scale path |
| A3 Concurrency & consistency | Resolved | D9, §6 — single event loop, Redis round-trip acceptable; sequence numbers for ordering |
| A4 Availability & reliability | Resolved | §7, D5 — heartbeat TTL, reconnect backoff, graceful degradation |
| A5 Data integrity & durability | Resolved | D2, §4 — ephemeral by design; no persistence; no migration |
| A6 Caching & freshness | Resolved | D2, §6 — in-memory state IS the live cache; room snapshot on join |
| A7 Cost | Assumed (A7) | No paid external services; Redis is infra cost absorbed into existing ops budget |
| A8 Security & privacy | Resolved | D4, D6, §8 — auth on upgrade, server-assigned identity, input validation, abuse mitigations |
| A9 Observability | Resolved | §9 — key metrics, logs, traces, single health signal, health endpoint |
| A10 Maintainability & simplicity | Resolved | D1–D9 — new isolated module; no changes to existing REST, DB, or editor |
| A11 Testability | Resolved | §5 (Redis stub), §7 (reconnect seams) — injectable WebSocket client, Redis pub/sub mockable; unit test seams defined |
| A12 Deployability & rollout | Resolved | §10 — feature flag, staged rollout, fully reversible |
| A13 Backward compatibility | Resolved | No existing API contracts changed; presence is a new endpoint; no schema migration |
| A14 Accessibility & device/env | Resolved | D8 — crowding handled; cursor fade on idle; reduced-motion: cursor position updates continue but CSS transitions can respect `prefers-reduced-motion`; keyboard users: no cursor tracking (keyboard-only users have no mouse position — their cursor is simply absent, consistent with the blueprint's "cursor moves as the person moves") |
| B1 Placement / module taxonomy | Resolved | §2 — new `PresenceGateway` + `PresenceService` modules on existing Node backend |
| B2 Data model & persistence | Resolved | §4 — in-memory only; no Postgres changes |
| B3 API surface & schemas | Resolved | §4 — WebSocket message schemas defined; no new REST routes |
| B4 Async / background work | Resolved | D5 — heartbeat TTL eviction runs as a `setInterval` in `PresenceService`; not a background job framework |
| B5 External services & contracts | Resolved | §5 — Redis (optional, internal); no third-party services |
| B6 Frontend integration | Resolved | §2, D3, D7, D8 — `PresenceClient` hook/context; throttle; idle timer; crowding cap |
| B7 Feature flags & rollout | Resolved | §10 — `collab_cursors_enabled` flag; staged rollout plan |
| B8 Error handling | Resolved | §7 — per-layer error handling: auth failure → 403; invalid message → drop; service unavailable → editor unaffected; Redis failure → single-process fallback |

---

## Appendix A: Captured Inputs

*This design was produced autonomously (no live user interview was conducted). The following records each decision fork, the recommendation made, the autonomous resolution, and the reasoning. This appendix stands in for the P3 interview record and the P4 last-call gate. Items that would have been questions to a human are explicitly called out.*

---

### Transport protocol (D1)

- **Question that would have been asked:** "For the presence layer, I recommend WebSocket — it's the only transport that meets the 250 ms latency budget without continuous polling cost. Do you want to use WebSocket on the existing Node server, or would you prefer a managed service (Liveblocks, Ably, Pusher) or SSE+POST?"
- **Recommendation given:** WebSocket on the existing Node server. Rationale: meets latency target, no external dependency, fits simplicity-first principle. Managed service is a valid future escape valve.
- **Autonomous resolution:** WebSocket on existing Node server (D1).
- **Notes:** If the team has prior experience with a managed presence service or has policy against long-lived server connections, this decision should be revisited. Flagged as OR5.

---

### Persistence model (D2)

- **Question that would have been asked:** "Cursor data is ephemeral per the blueprint. Confirm: no Postgres writes for presence, in-memory only, with Redis pub/sub added only when you scale to multiple processes?"
- **Recommendation given:** In-memory only; Redis additive. No Postgres involvement.
- **Autonomous resolution:** Confirmed (D2). Redis path is optional and additive.
- **Notes:** A1–A2 in the Assumptions table flag the single-process assumption for confirmation.

---

### Message throttle rate (D3)

- **Question that would have been asked:** "For client-side throttle, I recommend 50 messages/sec (20 ms interval) — imperceptible to humans, low bandwidth. Does that fit, or does the editor fire events at a different natural granularity?"
- **Recommendation given:** 50 Hz client throttle, 100 Hz server cap.
- **Autonomous resolution:** Adopted (D3). Values are environment-variable-configurable so they can be tuned without a deploy.
- **Notes:** The specific numbers are reasonable defaults but should be validated against the actual editor's event model during implementation.

---

### Color/name assignment (D4)

- **Question that would have been asked:** "For user identity on cursors, I recommend server-assigned color (hash of userId+docId) and server-supplied display name from the auth session — prevents spoofing. Does the JWT/session carry the display name, or does it require a DB lookup?"
- **Recommendation given:** Server-assigns both. Display name from JWT/session.
- **Autonomous resolution:** Adopted (D4). Flagged as A8 (confirm what the JWT carries).
- **Notes:** If the JWT does not carry the display name, the gateway will need a DB lookup at connect time — acceptable overhead (once per connection, not per message).

---

### Heartbeat TTL (D5)

- **Question that would have been asked:** "For disconnect detection, I recommend a 30-second eviction TTL with 15-second protocol-level pings. The blueprint allows cursors to freeze briefly on a network drop. Is 30 seconds the right window, or does your UX need faster eviction (e.g., 10 s)?"
- **Recommendation given:** 30 s TTL, 15 s heartbeat.
- **Autonomous resolution:** Adopted (D5). Flagged as C1 (a known compromise; revisit trigger defined).
- **Notes:** If UX testing reveals users find stale cursors confusing, reduce TTL to 10 s. The heartbeat interval should be roughly TTL/2 to avoid false positives.

---

### Authorization approach (D6)

- **Question that would have been asked:** "For access control, I recommend validating document read access at WebSocket upgrade time using the existing auth function — single gate, reuses existing logic. Does the auth function support being called outside of Express middleware (e.g., called directly with a userId + docId)?"
- **Recommendation given:** Auth at upgrade time, reuse existing document authorization.
- **Autonomous resolution:** Adopted (D6). Flagged as A4 (confirm auth is importable outside Express middleware chain).
- **Notes:** Mid-connection re-auth is deferred (C2 compromise). OR2 flags the revisit trigger.

---

### Scale: single process vs. multi-process (A2)

- **Question that would have been asked:** "Is the initial deployment single-process, or are you already running multiple Node processes/instances behind a load balancer? This determines whether Redis pub/sub is needed on day one."
- **Recommendation given:** Design for single-process first; Redis path is additive.
- **Autonomous resolution:** Assumed single-process for initial deploy (A2). Redis design is fully specified so it can be enabled without re-architecture.
- **Notes:** If the team is already running behind a load balancer with multiple Node instances, Redis pub/sub should be enabled from day one. Flagged for confirmation.

---

### Concurrent user scale (A3)

- **Question that would have been asked:** "What's the expected number of concurrent users in a single document? And are there use cases (classrooms, live events) where a single document might have 100+ participants?"
- **Recommendation given:** Design for up to ~50 participants without server-side fan-out filtering.
- **Autonomous resolution:** Assumed ~50 max typical room size (A3). Fan-out filtering flagged as OR4.
- **Notes:** This is the assumption most likely to be wrong for certain product segments. High-concurrency documents need a revisit of D8 (crowding) and §6 (broadcast fan-out).

---

### Frontend integration: hook vs. component (B6)

- **Question that would have been asked:** "For the React integration, I recommend a `PresenceClient` context + hook that wraps the WebSocket lifecycle — consistent with modern React patterns. Does the frontend already have a context layer for the editor (e.g., a document context) that the PresenceClient can subscribe to?"
- **Recommendation given:** Context + hook pattern; mount alongside existing editor context.
- **Autonomous resolution:** Adopted. Flagged as A5 (confirm a clean mounting point exists in the frontend).
- **Notes:** If the editor is a third-party component (e.g., CodeMirror, ProseMirror), cursor rendering will need to use that editor's decoration/widget API rather than absolute DOM positioning.

---

### Feature flag default (B7)

- **Question that would have been asked:** "Should the feature flag default to on or off? I recommend off — lets you deploy backend and frontend independently before any user sees it."
- **Recommendation given:** Default off; staged rollout.
- **Autonomous resolution:** Adopted (§10).
- **Notes:** The flag should be removable (not permanent) — once the feature is stable and fully rolled out, the flag and its branches should be cleaned up.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **Autonomous resolution:** The following items were identified during the last-call pass as worth calling out, even with no human to surface them:
  1. **Editor cursor position encoding** — the design uses `{line, ch}` position coordinates, consistent with CodeMirror conventions. If the frontend uses a different editor (e.g., ProseMirror uses a flat integer offset), the wire schema should use that editor's native position type. Flagged as an implementation-time detail.
  2. **Document deletion while presence is active** — no behavior is specified in the blueprint (OR6). A force-disconnect event should be added when a document is deleted.
  3. **Reduced-motion accessibility** — cursor animations should respect `prefers-reduced-motion`. Noted in A14 of the checklist.
  4. **Load balancer WebSocket support** — flagged as A6 and OR3; the most operationally common deployment surprise for first-time WebSocket features.
