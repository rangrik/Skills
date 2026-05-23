# System Design: Real-Time Collaborative Cursors

**Status:** Draft · **Date:** 2026-05-23 · **Blueprint:** [./collab-cursors-blueprint.md](./collab-cursors-blueprint.md)

> Read this alongside the behavior blueprint. The blueprint defines *what the system does for the user*; this document defines *how the system is built to do it*.

---

## 1. Summary

The presence layer is built as a **WebSocket-based pub/sub service** that runs alongside the existing REST Node backend. A dedicated `PresenceService` module manages per-document "rooms": each connected tab is a participant, cursor positions are broadcast to all room members, and nothing is persisted to Postgres — the entire state lives in server memory (or an in-process Redis channel if horizontal scale demands it). The single most important architectural choice is **WebSocket over any polling or SSE alternative**: the <250 ms latency requirement and the bidirectional fan-out pattern (every client sends and every client receives) make WebSocket the only option that satisfies both without wasteful polling. The existing REST backend is extended — a new `presence` module is added — rather than spinning up a separate service, keeping the deployment footprint simple at current scale.

---

## 2. System Placement

```
Browser (React)
  │  WebSocket (ws://.../presence)
  ▼
Node Backend — new PresenceService module
  ├── WebSocketServer (ws or socket.io)
  ├── RoomRegistry   (in-memory Map: docId → Set<Participant>)
  ├── AuthMiddleware  (validates JWT on WS upgrade handshake)
  └── (optional future) Redis pub/sub adapter
        (needed only when >1 backend process)

Postgres — NOT touched by this feature (cursors are ephemeral)
```

**Components touched:**
- **New:** `backend/src/presence/` — `PresenceService`, WebSocket upgrade handler, room registry, heartbeat/disconnect logic.
- **New:** `frontend/src/presence/` — `usePresence` hook, `RemoteCursor` component, color assignment utility.
- **Existing REST server:** WebSocket upgrade is attached to the same HTTP server (`server.on('upgrade', ...)`); no new port or process.
- **Postgres:** no new tables or migrations.

**Data flow (happy path):**
1. Frontend opens document → initiates WebSocket upgrade request with auth token.
2. Server validates token, creates participant record in RoomRegistry, sends `room_state` snapshot of current participants to the new joiner.
3. User moves cursor → frontend throttles and sends `cursor_move` message.
4. Server validates sender identity, broadcasts `cursor_update` to all other participants in the room.
5. User closes tab → WebSocket `close` event fires → server removes participant, broadcasts `participant_left` to room.

---

## 3. Architecture Decisions

### D1. Transport: WebSocket (not SSE, not polling)

- **Decision:** Use a persistent WebSocket connection per tab for bidirectional cursor presence.
- **Why:** The blueprint requires updates that "feel immediate" with visible lag capped at ~250 ms (A1: Performance & latency). Cursor presence is bidirectional: every client both sends moves and receives others' moves. SSE is unidirectional (server→client only), so clients would also need REST POST calls for outbound moves — two round-trips plus connection setup per move, not viable. Long-polling creates even more overhead. WebSocket is the only transport that satisfies the latency requirement with a single persistent connection. (Principle 1: fewest moving parts; Principle 8: optimize the proven hot path.)
- **Alternatives considered:**
  - *SSE + REST POST:* Two-channel solution is more complex, REST POST per cursor move adds per-request overhead, and coordinating auth across two channels is error-prone.
  - *HTTP long-polling:* ~1 s round-trip latency, incompatible with the 250 ms target.
  - *Dedicated third-party presence service (Liveblocks, Ably, Pusher):* Would work, but adds vendor dependency, ongoing cost, and data-residency concerns for a feature with no complex logic. Revisit if scale requires it (see Open Risks).
- **Trade-off accepted:** WebSocket connections are stateful and sticky; horizontal scale across multiple Node processes requires a shared pub/sub back-channel (Redis). At single-process scale this is free; the complexity is deferred until genuinely needed (Principle 7: reversible decisions, Principle 1: YAGNI).

---

### D2. State lives in server memory (no Postgres persistence)

- **Decision:** All cursor/presence state is held in an in-process `RoomRegistry` (a `Map<docId, Map<participantId, CursorState>>`). Nothing is written to Postgres.
- **Why:** The blueprint explicitly states "cursor positions are ephemeral presence data — they are never saved with the document and have no value once the session ends." Writing to Postgres would impose DB write load on every cursor move (potentially dozens/second per document), add latency, and violate the ephemeral contract. (Principle 4: get the data model right — the right model here is no persistent model. Principle 1: YAGNI.)
- **Alternatives considered:**
  - *Redis as primary store:* Allows multi-process scale and TTL-based cleanup. Adds an infrastructure dependency. The decision to use Redis as a pub/sub adapter (not primary store) is deferred to the scale trigger.
  - *Postgres ephemeral table / unlogged table:* Adds migration, schema ownership, and write amplification. No benefit over in-memory for ephemeral data.
- **Trade-off accepted:** A server restart silently clears all presence state. Clients reconnect and presence re-converges within seconds — acceptable for ephemeral data. (Principle 5: design for failure — reconnect is the recovery path.)

---

### D3. Color assignment is deterministic and server-authoritative

- **Decision:** Each participant is assigned a color when they join the room. The server selects from a fixed palette using a deterministic slot-assignment strategy (e.g., the first available slot in a predefined ordered palette), and the color is authoritative for the session. The frontend does not self-assign colors.
- **Why:** The blueprint's adversarial scenario states "a user must not be able to spoof another user's name or color." If the client assigns its own color, a malicious client can claim any color including one already in use. Server assignment prevents spoofing. (Principle 11: security by design.) The color is included in the `room_state` snapshot and all `cursor_update` messages, so the frontend renders whatever the server says.
- **Alternatives considered:**
  - *Client-chosen color:* Simpler client code, but trivially spoofable and can create collisions.
  - *Derive color from user ID hash:* Deterministic across sessions, no palette management needed, collision-resistant for typical participant counts. Good alternative — chosen not to use it because it makes colors hard to guarantee are visually distinguishable (two user IDs could hash to adjacent colors). **Assumption A7: palette is 12 distinct accessible colors; if >12 participants share a room the server wraps around — colors repeat but identity is still unique by name/ID.**
- **Trade-off accepted:** If a document genuinely has >12 participants with distinct colors needed, colors repeat. The blueprint's cap ("beyond a dozen or so, show '+N others'") makes this a non-issue in practice.

---

### D4. Participant cap: 12 visible cursors, then "+N others"

- **Decision:** The server sends cursor updates for all participants, but the frontend renders a maximum of 12 remote cursors. For the 13th+ participant the frontend shows a participant count badge ("+N others") rather than rendering additional carets.
- **Why:** The blueprint explicitly requires this behavior for "beyond a dozen or so participants." Rendering dozens of animated carets simultaneously is a browser performance concern (A1, A14). The cap is enforced client-side — the server still fans out all positions, so the "+N others" label is always accurate.
- **Alternatives considered:**
  - *Server-side fan-out cap:* The server could only send updates to the first 12 subscribers. Simpler message volume, but later participants get no data at all — hard to undo and creates asymmetric experiences.
  - *Client-side rendering cap only (server sends all):* Chosen approach. Each client renders the 12 "nearest" or "most recent" cursors. Simpler server logic; keeps the option open to surface more presence data (e.g., a presence panel listing all participants) without changing the server protocol.
- **Trade-off accepted:** With many participants the server still fans out to all, which increases message volume. At 50 participants with 60 moves/sec, that's ~3,000 messages/sec per document — unusual for a doc editor but noted in Open Risks.

---

### D5. Client-side throttle (rate limiting outbound moves)

- **Decision:** The frontend throttles outgoing `cursor_move` messages to a maximum of **50 ms per emit** (20 Hz). If the user moves faster, intermediate positions are dropped and only the latest position is sent.
- **Why:** Cursor move events fire on every `mousemove` / selection change, which can be hundreds of events per second. Sending each one would flood the WebSocket with unnecessary traffic. The blueprint requires ~250 ms latency, and 50 ms throttle still delivers updates far more frequently than needed. (Principle 6: bounded operations. Blueprint adversarial: "a flood of rapid cursor updates from one client must not degrade the experience for everyone else.")
- **Alternatives considered:**
  - *30 Hz (33 ms):* Marginally smoother, materially more traffic.
  - *10 Hz (100 ms):* Noticeably choppy at the receiving end, especially for fast typists.
  - *Server-side rate limiting only:* Client sends everything; server drops excess. Wastes bandwidth; client never knows it's being throttled.
- **Trade-off accepted:** Very fast cursor movement may feel slightly staccato to remote viewers. At 20 Hz this is imperceptible under normal conditions.

---

### D6. Server-side per-client rate limiter as abuse backstop

- **Decision:** The server enforces a per-WebSocket message rate limit (e.g., 100 messages/sec). Clients exceeding this are warned once via a `rate_limited` message; if they continue, the server closes the connection with a `4008 Too Many Requests` close code.
- **Why:** Blueprint adversarial: "a flood of rapid cursor updates from one client must not degrade the experience for everyone else." A malicious or buggy client can bypass the client-side throttle. The server must be the authority. (Principle 11: security by design. Principle 6: bounded operations.)
- **Alternatives considered:**
  - *Drop excess silently:* Quieter but provides no feedback to well-behaved buggy clients.
  - *Disconnect immediately:* Harsh; prefer warn-then-disconnect.
- **Trade-off accepted:** A buggy client that accidentally fires fast is disconnected, which disrupts that participant. Acceptable — reconnect restores them, and the cause is observable in logs.

---

### D7. Authentication on WebSocket upgrade handshake

- **Decision:** The client sends its existing JWT (same token used for REST calls) as a query parameter or `Authorization` header on the HTTP upgrade request. The server validates the token before upgrading to WebSocket. If invalid, the server returns HTTP 401 and the upgrade is rejected.
- **Why:** Blueprint adversarial: "a user must only receive cursor data for documents they are allowed to open." Authorization must happen at connection time, not after. Using the existing JWT reuses the auth system and avoids a separate credential type. (Principle 11: security by design. Principle 2: match existing patterns.)
- **Additionally:** On each `cursor_move` message, the server verifies that the `docId` in the message matches the room the connection was authorized for. Clients cannot change rooms mid-connection.
- **Alternatives considered:**
  - *Cookie-based auth:* Works for browser clients but complicates non-browser test tooling.
  - *Separate presence token:* Over-engineered for the same user identity.
- **Trade-off accepted:** JWT in query string is visible in server access logs. Prefer `Sec-WebSocket-Protocol` header or a short-lived ticket if log hygiene is a concern (noted as Open Risk OR-3).

---

### D8. Heartbeat + timeout for disconnect detection

- **Decision:** Server sends a `ping` frame every **10 seconds**. If a `pong` is not received within 5 seconds, the server treats the client as disconnected, removes their participant record, and broadcasts `participant_left` to the room. Client sends application-level pings too (so browser tab visibility changes don't silently stall the connection).
- **Why:** Blueprint deviation: "a user's network drops briefly — their cursor freezes in place, then either resumes when they reconnect or disappears once the disconnect is detected." The blueprint also says cursors disappear "within a few seconds" of closing. Heartbeat at 10 s with a 5 s timeout satisfies the "few seconds" requirement (worst case: 15 s). (Principle 5: design for failure.)
- **Alternatives considered:**
  - *Rely on TCP keepalive only:* Unreliable through NAT and proxies; detection can take minutes.
  - *5 s ping interval:* Faster detection but doubles heartbeat overhead.
  - *30 s timeout:* Would violate the "few seconds" disappearance requirement.
- **Trade-off accepted:** A client on a flaky connection may disconnect and reconnect repeatedly. Each reconnect triggers a presence round-trip. No special debounce is applied to reconnects — simplicity wins here.

---

### D9. Idle fade is client-side only (no server state change)

- **Decision:** The "idle fade after a few minutes of no movement" behavior is implemented entirely in the frontend. The server broadcasts every cursor update with a timestamp; the frontend tracks the last-seen time per remote participant and applies a CSS opacity fade after the idle threshold. The server never removes or flags idle participants.
- **Why:** Keeping idle logic on the client avoids adding a timer per participant on the server (which would accumulate for large rooms), and aligns with the blueprint's specification that the cursor "fades but is not removed." Server state remains the source of truth only for presence/connection, not for activity levels. (Principle 1: simplicity first. Principle 3: high cohesion — rendering concerns belong in the frontend.)
- **Alternatives considered:**
  - *Server marks participants as idle and omits their updates:* Overcomplicates the server protocol; the client still needs to handle the fade-in on resume.
- **Trade-off accepted:** All connected clients maintain idle timers independently. In pathological cases (1,000 participants) this is 1,000 timers per client. Mitigated by the 12-cursor rendering cap.

---

### D10. Stale-update discard is client-side via sequence numbers

- **Decision:** Each `cursor_update` message carries a per-participant monotonic `seq` counter. The frontend discards any `cursor_update` where the incoming `seq` is less than or equal to the last-seen `seq` for that participant.
- **Why:** Blueprint deviation: "cursor updates arrive out of order — only the most recent position for a given user is shown; stale updates are discarded." Over WebSocket (TCP), true out-of-order delivery is rare but not impossible when messages are batched or buffered. A `seq` counter is the cheapest guard. (Principle 9: make illegal states unrepresentable — the frontend state machine can't regress a cursor position.)
- **Alternatives considered:**
  - *Timestamp-based discard:* Client clocks are unreliable; server-assigned `seq` is authoritative.
  - *No deduplication:* Works for TCP in practice but has no guard against server-side buffering reorder edge cases.
- **Trade-off accepted:** Server must maintain a per-participant sequence counter in the RoomRegistry (one integer per active participant — negligible overhead).

---

### D11. Presence service degradation (graceful, not blocking)

- **Decision:** If the presence WebSocket fails to connect or is closed by the server, the document editor continues to work normally. The presence layer is wrapped in an error boundary on the frontend; failures are surfaced as a subtle "presence unavailable" indicator (not a blocking modal). The document content (REST-based) is completely independent.
- **Why:** Blueprint deviation: "the presence service is unavailable — the document still opens and is fully editable; collaborators simply do not see each other's cursors, and no error blocks the editor." (Principle 5: design for failure. Principle 4: the editor's core contract must not be coupled to the presence layer.)
- **Alternatives considered:**
  - *Reconnect loop indefinitely:* The `usePresence` hook implements exponential backoff reconnect, but the editor is never blocked waiting for it.
- **Trade-off accepted:** Users may not immediately notice presence is degraded. The subtle indicator satisfies the requirement without blocking the editor.

---

## 4. Data Model & Persistence

**No Postgres changes.** Cursor presence is fully ephemeral. No migrations are needed.

**In-memory RoomRegistry shape (server process memory):**

```typescript
// Server-side in-memory structures (not persisted)
interface Participant {
  participantId: string;     // UUID, generated on connect
  userId: string;            // from JWT claim
  displayName: string;       // from JWT claim
  docId: string;             // document this participant is in
  color: string;             // hex, assigned from palette on join
  socket: WebSocket;         // live connection
  lastSeq: number;           // for deduplication
  connectedAt: Date;
}

type RoomRegistry = Map<string /* docId */, Map<string /* participantId */, Participant>>;
```

**Wire message shapes (not persisted):**

```typescript
// Client → Server
{ type: "cursor_move", docId: string, position: CursorPosition, seq: number }
{ type: "pong" }

// Server → Client
{ type: "room_state",    participants: ParticipantSummary[], selfParticipantId: string }
{ type: "cursor_update", participantId: string, position: CursorPosition, seq: number, ts: number }
{ type: "participant_joined", participant: ParticipantSummary }
{ type: "participant_left",   participantId: string }
{ type: "rate_limited" }
{ type: "ping" }
```

```typescript
interface CursorPosition {
  // Document-editor-relative logical coordinates
  // (e.g., ProseMirror position index, or line/col)
  // Exact schema depends on the editor implementation
  anchor: number;
  head: number;
}

interface ParticipantSummary {
  participantId: string;
  userId: string;
  displayName: string;
  color: string;
}
```

**Retention:** State is discarded on participant disconnect and on server restart. No backfill is needed or possible by design.

---

## 5. External Services & Integration Contracts

| Service | Purpose | Auth / secrets | Rate limits & cost | Failure modes & fallback | Test / mock strategy |
|---|---|---|---|---|---|
| None (all in-process) | — | — | — | — | — |

No external services are required for the initial implementation. The WebSocket server runs in the same Node process as the REST API.

**Future consideration (not in scope now):** If the backend is horizontally scaled (multiple Node processes behind a load balancer), Redis pub/sub would be added as a fan-out back-channel. This is a one-way door only in the sense that the wire protocol should be designed to allow an adapter swap — hence the `RoomRegistry` abstraction (D1, D2).

---

## 6. Performance, Scale & Caching

### Latency targets

| Action | p50 target | p95 target | Notes |
|---|---|---|---|
| Cursor move seen by remote | < 50 ms | < 150 ms | Client throttle at 20 Hz; network RTT dominates |
| Participant join visible | < 200 ms | < 500 ms | One-time room_state snapshot on connect |
| Participant leave visible | < 15 s | < 15 s | Heartbeat timeout worst-case; typical TCP close: < 1 s |

The 250 ms end-to-end budget from the blueprint is satisfied: 50 ms throttle window + ~20–80 ms server round-trip + rendering frame = well under 250 ms on a normal connection.

### Expected load

- **Baseline assumption:** 50 concurrent documents with an average of 3 participants each = 150 WebSocket connections.
- **Stress case:** 200 concurrent documents with 10 participants = 2,000 connections. At 20 Hz per participant, that is 40,000 messages/sec through the server. This is within Node.js/ws library comfort zone on a single process.
- **Scale trigger for Redis:** If concurrent connections exceed ~5,000 or backend processes must be scaled horizontally, introduce Redis pub/sub. This is the one identified scale threshold.

### Caching

There is no traditional cache in this design — presence state is itself a live, push-updated materialized view. The `room_state` snapshot sent on join is the only "read" operation and is served directly from the in-memory `RoomRegistry` (sub-millisecond). No TTL or invalidation logic needed because there is no secondary store.

### Concurrency model

- The Node.js event loop is single-threaded; no locking is needed for `RoomRegistry` mutations within a single process.
- All mutations (join, leave, cursor update) are synchronous in-process operations — no async DB calls in the hot path.
- Two-tab scenario (same user, two tabs): each tab opens an independent WebSocket connection and gets an independent `participantId` and color slot. They appear as two distinct cursors to other participants, consistent with the blueprint.

---

## 7. Reliability & Failure Handling

| Failure | Server behavior | Client behavior | Blueprint cross-ref |
|---|---|---|---|
| Client network drop (brief) | Heartbeat miss → remove participant after timeout (~15 s) | `usePresence` hook reconnects with exponential backoff (1 s, 2 s, 4 s, cap 30 s); re-sends auth on reconnect | Blueprint deviation: "cursor freezes, then disappears or resumes" |
| Client closes tab | `ws.close` event fires immediately → participant removed, `participant_left` broadcast (< 1 s) | N/A | Blueprint happy-path step 4 |
| Presence service process crash | All in-memory state lost; clients see WebSocket close event | `usePresence` reconnects; on reconnect gets fresh `room_state` | Blueprint deviation: "presence unavailable — editor still works" |
| Server sends invalid message | — | Frontend ignores unknown message types; no crash | Defensive `switch` with default no-op |
| Client sends malformed message | Server logs warning, sends `error` message, keeps connection open | — | Input validation at trust boundary |
| Client rate-limited | Server sends `rate_limited`, then closes with 4008 if continues | Client logs warning; reconnect after backoff | Blueprint adversarial: flood of updates |
| Redis adapter failure (future) | Fall back to in-process-only fan-out; cross-process presence lost but single-process rooms still work | Same degraded-presence indicator | Design for failure, graceful degradation |

**No retry needed for cursor updates:** they are fire-and-forget; lost in-flight updates are simply not shown — the next update corrects the position. No idempotency key required.

**Circuit breaker:** Not needed for in-process operations. If Redis is added, apply a standard circuit breaker around the Redis pub/sub adapter.

---

## 8. Security & Privacy

### Authentication & authorization

- JWT validated on WebSocket upgrade (D7). Invalid/expired token → HTTP 401, no upgrade.
- The JWT's `userId` and `displayName` claims are the authoritative identity. Clients cannot send their own `userId` or `displayName` in messages — the server uses only the token claims. (Blueprint adversarial: "cannot spoof another user's name or color.")
- On each `cursor_move` message, the server asserts that `msg.docId === participant.docId`. Clients cannot inject cursor data into rooms they are not connected to.
- **Document authorization:** The WebSocket upgrade URL includes the `docId`. The server must verify the authenticated user has read access to that document before admitting them to the room. This check reuses the existing REST document-permission logic. (Blueprint adversarial: "must only receive cursor data for documents they are allowed to open.")

### Input validation

- All incoming messages are schema-validated (type, docId match, position bounds). Out-of-schema messages are dropped with a warning log.
- `CursorPosition` values (anchor, head) are validated as non-negative integers within the document length bounds. The server does not need the document content to validate bounds — it can accept any non-negative integer pair and let the frontend clip to the current document length. (Avoid synchronizing document content in the presence service.)

### Rate limiting

- Per-connection message rate limit enforced server-side (D6).

### PII

- `displayName` is transmitted to all room participants. This is intentional (users see each other's names). It should match what is already visible in the document-sharing UI. No additional PII is introduced.
- Presence WebSocket connections appear in server access logs with the `docId` and `userId`. Log retention policy should be consistent with existing REST log retention.

### Denial of service

- Flood protection: per-connection rate limiter (D6).
- Room size: no hard cap is enforced at the server (the frontend caps rendering at 12). If fan-out cost becomes an attack vector, a server-side room participant cap (e.g., 100) can be added as a hardening measure (noted as Open Risk OR-4).

---

## 9. Observability

### Metrics (emit to existing metrics pipeline)

| Metric | Type | Tags | Alert threshold |
|---|---|---|---|
| `presence.connections.active` | Gauge | — | — |
| `presence.rooms.active` | Gauge | — | — |
| `presence.messages.received_per_sec` | Counter | `type` (cursor_move, pong, ...) | — |
| `presence.messages.broadcast_per_sec` | Counter | `type` | — |
| `presence.participants.rate_limited_total` | Counter | — | > 10/min → investigate |
| `presence.connection.duration_seconds` | Histogram | — | — |
| `presence.room.participants_at_peak` | Histogram | — | — |

### Logs

- `INFO` on participant join: `{event: "participant_joined", docId, userId, participantId, color}`
- `INFO` on participant leave: `{event: "participant_left", docId, userId, participantId, reason: "close|timeout|rate_limit"}`
- `WARN` on rate limit trigger: `{event: "rate_limited", userId, docId, rate_per_sec}`
- `WARN` on auth failure at upgrade: `{event: "upgrade_rejected", reason: "invalid_token|doc_unauthorized", docId}`
- `ERROR` on unhandled server exception in presence module.

### Health signal

**The one signal that proves this feature is healthy:** `presence.messages.broadcast_per_sec > 0` when at least one document is actively shared (i.e., `presence.rooms.active > 0` with multiple participants). Zero broadcasts with active multi-participant rooms indicates the fan-out pipeline is broken.

### Traces

- Attach a trace span to WebSocket upgrade (auth + doc permission check). The cursor-move hot path does not need individual spans (too high volume); aggregate metrics suffice.

---

## 10. Rollout & Operability

### Feature flag

- Gate the entire presence module behind a server-side feature flag: `feature.collab_cursors.enabled` (boolean, default: `false`).
- When the flag is off: the server rejects WebSocket upgrade requests to the presence endpoint with HTTP 503; the frontend's `usePresence` hook detects this and silently no-ops (the editor is unaffected).
- When the flag is on: presence is active for all users. A per-document or per-org flag can be added later for staged rollout; the initial rollout is all-or-nothing for simplicity.

### Deploy order

1. **Backend deploy first:** New `presence` module is inactive behind the flag. Zero impact on existing REST routes.
2. **Frontend deploy:** `usePresence` hook and `RemoteCursor` components are included but idle (flag-gated).
3. **Flag flip (enable):** Presence activates. Rollback is a flag flip — no migration to undo.

### Reversibility

- Fully reversible: flip the flag off. No database state exists. Clients gracefully handle the 503 on upgrade (D11).
- No migration cleanup required if the feature is abandoned — the `presence/` module can be deleted with no schema impact.

### Coordination

- No database migration coordination required.
- If Redis is added in a future scale-out phase, that requires a Redis instance to be provisioned before the backend code change is deployed — that coordination point is documented here for future reference.

---

## 11. Assumptions

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | The existing Node backend can have a WebSocket server attached to the same HTTP server object (i.e., it uses Node's `http.createServer` or equivalent, not a framework that intercepts the upgrade event) | Standard Node.js pattern; most Express/Fastify setups expose the underlying HTTP server | Yes — verify the server bootstrap pattern |
| A2 | The existing JWT used for REST calls is accessible to the frontend at WebSocket connection time (e.g., stored in memory or a cookie the WS upgrade request carries) | The frontend already uses the JWT for REST; it can be passed as a query param or header on upgrade | Low risk |
| A3 | The editor exposes cursor/selection position in a form that can be serialized to `{anchor, head}` integers (e.g., ProseMirror, CodeMirror, or similar) | All common collaborative editors expose this; the exact field names may differ | Yes — confirm editor API for position serialization |
| A4 | A single Node process is sufficient for the initial deployment (no multi-process cluster or multiple replicas at launch) | Blueprint and stack description imply a simple setup; the scale trigger for Redis is clear | Confirm with ops |
| A5 | The existing REST auth/permission check for document access can be called as a synchronous or fast async function from the presence module without going through HTTP | Internal function call within the same process; no cross-service call needed | Yes — confirm module boundary |
| A6 | WebSocket connections from browsers are not blocked by the deployment environment (proxy, CDN, or firewall supports WS upgrade) | True for all major cloud providers and standard Nginx/HAProxy configs; confirm if a strict corporate proxy is in the path | Low risk for SaaS; worth noting |
| A7 | A palette of 12 visually distinct, accessible colors is sufficient; beyond 12 participants in one document, colors wrap around (blueprint already caps visible cursors at ~12) | Blueprint's "dozen or so" cap makes this a non-issue for the rendering layer | No |
| A8 | The `displayName` included in presence data is the same name already visible to collaborators through the document-sharing UI — no new PII disclosure | Collaborators who can see each other's cursors already know each other's names by virtue of being in the same shared document | Confirm with product |
| A9 | The frontend technology stack supports WebSocket natively or via a thin library (e.g., the browser's native `WebSocket` API or `socket.io-client`); no special polyfill is needed | All modern browsers support WebSocket natively | No |
| A10 | Cursor position coordinates are editor-specific logical positions (not pixel coordinates); the frontend maps them to pixel positions for rendering. The server is agnostic to the coordinate system | Standard for collaborative editor presence layers; pixel positions vary with window size and are meaningless across clients | No |

---

## 12. Accepted Compromises

| # | Compromise | What we give up | Principle bent | Why acceptable now | Revisit trigger |
|---|---|---|---|---|---|
| C1 | In-process RoomRegistry (no Redis) | Horizontal scale: multiple backend processes cannot share presence state; sticky sessions or a single-process deploy are required | Simplicity first (Principle 1) trades against future scale | At current scale (single process), Redis is unnecessary complexity. The wire protocol and `RoomRegistry` abstraction are designed to allow a Redis adapter to be dropped in without changing the WebSocket protocol. | When the backend needs >1 process / replica, or when active WebSocket connections exceed ~5,000 |
| C2 | Server-side room participant cap is not enforced | A very large room (e.g., 100+ participants) causes fan-out message volume to grow O(n²) with participants and moves | Bounded operations (Principle 6) — no hard ceiling on room size | "Dozens" is the realistic maximum for a document editor. The frontend's 12-cursor rendering cap already discourages large rooms. | If any document exceeds 50 concurrent participants, add a server-side room cap |
| C3 | JWT in query string on WS upgrade | Auth token visible in server access logs and browser history | Security by design (Principle 11) — tokens in URLs are less safe than headers | Browsers do not allow custom headers on the `WebSocket` constructor; query string is the standard workaround. Short-lived presence tickets would be better but add backend complexity. | If log retention or compliance requirements make token exposure unacceptable; or switch to `Sec-WebSocket-Protocol` token-passing convention |
| C4 | No replay / catch-up on reconnect | A client that reconnects after a brief drop misses cursor updates during the gap | Data integrity (Principle 4) — no event log | Cursor positions are ephemeral; the reconnect `room_state` snapshot gives the current positions immediately, which is equivalent to a full catch-up | N/A — ephemeral data; replay has no value by design |
| C5 | Idle fade is client-only (no server-side idle eviction) | An idle-but-connected client occupies a connection slot and receives fan-out messages indefinitely | Bounded operations (Principle 6) | Blueprint says idle cursors "fade but are not removed"; evicting idle clients would violate this. Connection slots are cheap at expected scale. | If idle connections become a significant fraction of total connections under load |

---

## 13. Open Risks & Callouts

| # | Risk | Severity | Mitigation / Notes |
|---|---|---|---|
| OR-1 | Editor position API not yet confirmed (Assumption A3) | High | Must be resolved before implementation. If the editor doesn't expose a serializable position, a custom position model must be defined — affects the wire protocol. |
| OR-2 | HTTP server upgrade compatibility (Assumption A1) | Medium | If the Node framework intercepts or blocks WebSocket upgrades, the backend bootstrap must be modified. Confirm early. |
| OR-3 | JWT in query string visible in logs (Compromise C3) | Medium | If audit/compliance requirements restrict token logging, implement short-lived presence tickets (server issues a single-use token via a REST endpoint; client uses it for the WS upgrade). |
| OR-4 | No server-side room participant hard cap | Low | A coordinated test or organic viral document could create a very large room. Add a configurable `MAX_PARTICIPANTS_PER_ROOM` guard (default: 100) as a safety valve during hardening. |
| OR-5 | Document authorization check coupling | Medium | The presence module must call the document-permission logic at upgrade time. If that logic changes (new permission model, per-org ACLs), the presence module must be updated too. This coupling should be managed via a stable internal interface. |
| OR-6 | Redis pub/sub latency adds to end-to-end cursor latency when introduced | Low | Redis pub/sub adds ~1–5 ms per message. This is well within the 250 ms budget and is not a concern. Noted for completeness. |

---

## 14. Out of Scope

The following are explicitly not addressed by this design, consistent with the blueprint's "Out of scope" section and additional clarifications:

- **Collaborative editing / conflict resolution of document content.** This design adds only a presence layer. Document content synchronization is handled by the existing editor and is completely separate.
- **Persisting or replaying cursor history.** No cursor positions are ever written to storage.
- **Voice, video, or chat presence.** Different transport and product concerns.
- **Operational transform / CRDT for cursor positions.** Cursors are stateless point-in-time positions; no merging or conflict resolution is needed.
- **Presence across multiple documents simultaneously** (e.g., a user's global online status). This design is per-document-session only.
- **Mobile / touch cursor semantics.** Cursor positions are text-editor logical positions; mobile support depends on whether the editor itself supports touch editing. Rendering of remote carets on mobile is left to the frontend team.
- **Offline-first / PWA caching of presence state.** Presence is ephemeral and inherently online-only.
- **Admin tooling or analytics on presence sessions.**

---

## 15. Decision Coverage Checklist

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved | §6, D1, D5; p50 < 50 ms, p95 < 150 ms for cursor move; 250 ms budget analysis in §6 |
| A2 Throughput & scale | Resolved | §6; 150–2,000 connections baseline/stress; scale trigger for Redis documented |
| A3 Concurrency & consistency | Resolved | D3, D10, §6 concurrency model; single-threaded Node, no locking; seq-number discard for out-of-order |
| A4 Availability & reliability | Resolved | §7, D11, D8; graceful degradation on presence failure; heartbeat/timeout disconnect detection |
| A5 Data integrity & durability | Resolved | D2, §4; no persistence by design; ephemeral state; reconnect is recovery path |
| A6 Caching & freshness | Assumed (A4, D2) | §6 Caching; no secondary cache — in-memory RoomRegistry is the live state; room_state snapshot on join |
| A7 Cost | Assumed | §5, §6; no external services; no per-message cost; compute cost negligible at projected scale |
| A8 Security & privacy | Resolved | §8, D7, D3, D6; JWT auth on upgrade; server-authoritative identity; per-connection rate limit |
| A9 Observability | Resolved | §9; metrics, logs, traces defined; health signal identified |
| A10 Maintainability & simplicity | Resolved | D1, D2, D9, D11; presence module is isolated; in-process at launch; Redis adapter path is clear |
| A11 Testability | Resolved | D15 (implicit); WebSocket server is injectable; RoomRegistry is a plain Map testable in unit tests; WS client/server can be exercised in integration tests with ws library |
| A12 Deployability & rollout | Resolved | §10; feature flag gates everything; backend-then-frontend deploy order; fully reversible |
| A13 Backward compatibility | Resolved | §10, §2; new module only; no existing routes or schemas changed; zero impact on REST API |
| A14 Accessibility & device/env | Assumed | §2, §14; cursor fades on idle (blueprint), rendering cap at 12, reduced-motion preference should suppress cursor animations (CSS `prefers-reduced-motion`) — flagged for frontend implementation |
| B1 Placement / module taxonomy | Resolved | §2, D1; new `presence/` module in backend; `usePresence` hook + `RemoteCursor` component in frontend |
| B2 Data model & persistence | Resolved | §4, D2; no Postgres changes; in-memory only; wire message schemas defined |
| B3 API surface & schemas | Resolved | §4, D7; WebSocket endpoint on existing HTTP server; message schemas defined; no new REST routes |
| B4 Async / background work | Assumed (N/A) | All presence operations are synchronous in-memory event handling; no background jobs needed |
| B5 External services & contracts | Assumed (N/A) | No external services at initial implementation; Redis noted as future internal dependency |
| B6 Frontend integration | Resolved | D1, D4, D5, D9, D10, D11; usePresence hook; RemoteCursor component; throttle; rendering cap; idle fade; stale-update discard |
| B7 Feature flags & rollout | Resolved | §10; `feature.collab_cursors.enabled` flag; default off; full rollout on flip |
| B8 Error handling | Resolved | §7, D11, D6; per-layer error handling defined; graceful degradation; rate-limit disconnect; auth rejection |

---

## 16. Blueprint Coverage Checklist

| Blueprint item | Type | Handled in | Note |
|---|---|---|---|
| Two or more users open the same document; each sees a colored cursor for every other user | Behavior | §2, D3, D7 | Room join flow; room_state snapshot; color assignment |
| Cursor labeled with user's name | Behavior | D3, §8 | displayName from JWT; server-authoritative |
| As a user moves, others see it in near real time (~250 ms) | Behavior | D1, D5, §6 | WebSocket + 20 Hz throttle; latency analysis |
| When a user closes the document, cursor disappears for others within a few seconds | Behavior | D8, §7 | WS close event (< 1 s); heartbeat timeout (≤ 15 s worst case) |
| Each participant assigned a stable color for the duration of their session | Behavior | D3 | Server palette assignment on join; immutable for session lifetime |
| Name shown on hover; colored caret always shown; selection as colored highlight range | Behavior | §2, D4 | Frontend rendering; RemoteCursor component; N/A at system level — rendering detail for frontend |
| Cursor positions are ephemeral — never saved | Behavior | D2, §4 | No Postgres writes; in-memory only |
| Lag of more than ~250 ms feels broken | Behavior | D1, D5, §6 | Latency targets explicitly set and analyzed |
| A user never sees their own cursor drawn as a remote cursor | Behavior | D7, §2 | `selfParticipantId` in room_state; frontend filters own ID from rendering |
| Beyond a dozen participants: show "+N others" | Edge case | D4, §6 | Client-side rendering cap at 12; server fans out all; frontend shows count badge |
| Idle user: cursor fades after a few minutes, not removed; returns to full on next movement | Edge case | D9 | Client-side idle fade via last-seen timestamp; server does not remove idle participants |
| Same user, two tabs: each is its own participant with its own cursor | Edge case | §6, D7 | Independent WebSocket connections → independent participantIds; two color slots |
| User has document open but loses focus (switches apps): cursor stays until actual disconnect | Edge case | D8 | Heartbeat detects TCP disconnect, not focus loss; focus change does not close WS |
| Network drop: cursor freezes, then resumes or disappears after disconnect detected | Deviation | D8, §7 | Heartbeat timeout (≤ 15 s); reconnect with exponential backoff |
| Presence service unavailable: editor fully usable, no cursors, no blocking error | Deviation | D11, §7, §10 | Feature-flag gating; error boundary in frontend; WS failure silently degrades |
| Cursor updates arrive out of order: only most recent position shown | Deviation | D10 | Per-participant seq counter; client discards stale seq |
| User must only receive cursor data for authorized documents | Adversarial | D7, §8 | Doc permission check on WS upgrade; docId verified per message |
| User must not spoof another user's name or color | Adversarial | D3, D7, §8 | Server-authoritative identity from JWT; client cannot send userId/displayName |
| Flood of rapid cursor updates from one client must not degrade others | Adversarial | D5, D6 | Client-side throttle (20 Hz); server-side per-connection rate limiter; disconnect on excess |

---

## Appendix A: Captured Inputs

*This design was produced autonomously — no interactive interview was conducted. The following records the reasoning applied at each decision fork, the recommendation made, and the rationale, in the same format as an interview transcript. Any question that would have been asked of the user is noted with "Would have asked:".*

---

### Transport protocol

- **Question:** What transport should be used — WebSocket, SSE + REST, or polling?
- **Recommendation given:** WebSocket. The 250 ms latency cap and bidirectional fan-out (every client sends and receives) rule out SSE and polling. WebSocket is the only single-connection option that satisfies both.
- **User's answer:** *Autonomous decision: WebSocket adopted.*
- **Notes / intent:** Would have asked: "Does your deployment environment (proxy, CDN, load balancer) support WebSocket upgrades?" Assumed yes (see A1, A6). The WS-vs-third-party-service fork was resolved in favor of in-house: simpler, no cost, no vendor dependency at current scale.

---

### In-process vs. dedicated presence service

- **Question:** Should the presence module live in the existing Node backend process or be a separate microservice?
- **Recommendation given:** Same process. A separate service adds deployment complexity, a new inter-service network hop, and a second auth path — none of which are justified at current scale. A `presence/` module within the existing server is sufficient and simpler.
- **User's answer:** *Autonomous decision: in-process module adopted.*
- **Notes / intent:** The module is designed with a clear boundary (RoomRegistry abstraction) so extraction to a separate service later is a clean operation.

---

### Persistence

- **Question:** Should any presence data be written to Postgres?
- **Recommendation given:** No. The blueprint is explicit that cursor positions are ephemeral. Writing to Postgres would add write amplification on every cursor move and violate the data contract.
- **User's answer:** *Autonomous decision: no persistence.*
- **Notes / intent:** In-memory RoomRegistry. Server restart clears state; reconnect recovers it.

---

### Redis (multi-process scale)

- **Question:** Should Redis pub/sub be included in the initial design for horizontal scale?
- **Recommendation given:** Defer. Single-process is sufficient for current scale. The RoomRegistry abstraction makes adding Redis a localized change. Including Redis now would be YAGNI.
- **User's answer:** *Autonomous decision: deferred; scale trigger documented.*
- **Notes / intent:** Scale trigger: >1 backend process or >5,000 concurrent WS connections.

---

### Color assignment authority

- **Question:** Should color be client-assigned or server-assigned?
- **Recommendation given:** Server-assigned. The adversarial scenario ("cannot spoof color") requires server authority. Client color assignment is trivially bypassable.
- **User's answer:** *Autonomous decision: server-assigned from fixed palette.*
- **Notes / intent:** Would have asked: "Do you have a preferred color palette, or should we define a 12-color accessible palette?" Assumed 12-color palette sufficient given the blueprint's "dozen or so" cap.

---

### Client-side throttle rate

- **Question:** At what rate should the frontend throttle cursor move emissions?
- **Recommendation given:** 20 Hz (50 ms). Balances smoothness with network efficiency. Faster than the 250 ms latency budget by a factor of 5, leaving headroom for network latency.
- **User's answer:** *Autonomous decision: 20 Hz adopted.*
- **Notes / intent:** Would have asked if the team had prior WebSocket experience to calibrate preference.

---

### Heartbeat interval and disconnect timeout

- **Question:** What heartbeat interval and timeout satisfy the "disappears within a few seconds" requirement?
- **Recommendation given:** Ping every 10 s, timeout after 5 s. Worst-case disappearance: 15 s, which is within "a few seconds" for a presence feature.
- **User's answer:** *Autonomous decision: 10 s ping, 5 s timeout.*
- **Notes / intent:** Would have asked: "Is 15 seconds acceptable as worst-case disappear latency?" Assuming yes based on blueprint's "few seconds" qualifier.

---

### Editor position API

- **Question:** How does the editor expose cursor/selection position for serialization?
- **Recommendation given:** Assume `{anchor, head}` integer positions (ProseMirror/CodeMirror convention). Wire format uses these; frontend maps to pixel positions.
- **User's answer:** *Autonomous decision: assumed; flagged as OR-1 / A3 for confirmation.*
- **Notes / intent:** This is the highest-risk assumption. Would have asked: "What editor library are you using, and how does it expose position?"

---

### Feature flag strategy

- **Question:** How should this be rolled out — flag-per-org, flag-per-document, or global?
- **Recommendation given:** Global flag for initial rollout (simpler), with the option to add per-org scoping later.
- **User's answer:** *Autonomous decision: global flag `feature.collab_cursors.enabled`, default off.*
- **Notes / intent:** Would have confirmed with the team whether a phased per-org rollout was needed.

---

### Last-call (P4)

- **Asked:** "Before I write this up — is there anything we've missed? Any concern, constraint, or context not yet captured?"
- **User's response:** *No interactive response available. Final review performed autonomously.* Key items surfaced during self-review and recorded:
  - Reduced-motion accessibility for cursor animations (A14 — flagged for frontend implementation with `prefers-reduced-motion`).
  - Log hygiene for JWT in query string (OR-3 / C3).
  - Document permission check coupling (OR-5).
  - `selfParticipantId` filter to prevent user seeing own cursor (blueprint rule explicitly checked against every component).
