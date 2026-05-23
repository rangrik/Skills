# System Design: Real-Time Collaborative Cursors

**Blueprint:** collab-cursors-blueprint.md (approved 2026-05-18)
**Stack:** Node.js (REST today), PostgreSQL, React
**Date:** 2026-05-23

---

## 1. Goals and Non-Goals

### Goals
- Show live cursors (caret + name label + selection highlight) for all collaborators viewing the same document.
- Cursor appearance/disappearance latency ≤ 250 ms under normal network conditions.
- Graceful degradation: document editing works fully when the presence layer is unavailable.
- Authorization: users only receive cursor data for documents they are permitted to open.
- Spoofing prevention: a user cannot impersonate another user's cursor identity.
- Rate-limiting: a misbehaving client cannot degrade the experience for others.

### Non-Goals
- Collaborative content editing / OT / CRDT (handled by existing editor).
- Persisting or replaying cursor history.
- Voice, video, or chat.
- Offline-first sync of document content.

---

## 2. Key Design Decisions (with Rationale)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Use WebSockets (Socket.IO on the Node server) rather than SSE or polling | Bi-directional, low-latency, and widely supported. REST-only today means adding one new transport; Socket.IO has proven Node.js integration and handles reconnects automatically. |
| 2 | Presence state lives only in-memory (Redis pub/sub across nodes) — never Postgres | Cursor data is explicitly ephemeral. Postgres writes would be wasted I/O; Redis TTL handles stale cleanup automatically. |
| 3 | Client-side throttle (pointer events → 50 ms debounce) before sending | Keeps wire traffic low without perceptible latency; 20 updates/sec is more than enough for the 250 ms target. |
| 4 | Server-side per-client rate limiter (token bucket, 30 msg/sec) | Isolates a flooding client; other participants are unaffected. |
| 5 | Sequence numbers on every update; clients discard out-of-order arrivals | Fulfills the "show only most recent position" requirement cheaply without server-side ordering. |
| 6 | Colors assigned server-side from a deterministic palette at join time | Prevents spoofing; client never chooses its own color. |
| 7 | Idle fade at 3 min client-side; server removes presence at 5 min of inactivity | Blueprint says fade-not-remove; a server-side TTL caps stale presence if the client never sends a clean leave. |
| 8 | Cap display at 12 cursors; overflow shows "+N others" | Blueprint requirement; avoids DOM performance cliffs. |

---

## 3. Architecture Overview

```
┌──────────────┐        WebSocket (Socket.IO)         ┌────────────────────┐
│ React Client │ ◄──────────────────────────────────► │ Node Presence       │
│              │                                       │ Service             │
│  - cursor    │  REST (existing)                      │  (new process or    │
│    overlay   │ ◄──────────────────────────────────► │   module on same    │
│  - throttler │                                       │   Node process)     │
└──────────────┘                                       └────────┬───────────┘
                                                                │
                                                   Redis Pub/Sub│(presence rooms)
                                                                │
                                                       ┌────────▼───────────┐
                                                       │  Redis              │
                                                       │  - room:{docId}     │
                                                       │    participant set  │
                                                       │  - presence:{sid}   │
                                                       │    hash (TTL 5 min) │
                                                       └────────────────────┘
                                                                │
                                              (auth check only) │
                                                       ┌────────▼───────────┐
                                                       │  PostgreSQL         │
                                                       │  - users table      │
                                                       │  - doc_permissions  │
                                                       └────────────────────┘
```

**Deployment topology:** The Presence Service can run as a separate Node process (recommended for isolation) or as an additional Socket.IO namespace on the existing Node server if operational simplicity is preferred. Both options work; the design below treats it as separable.

---

## 4. Data Model

### 4.1 In-Memory Presence Record (Redis hash, key `presence:{socketId}`)

| Field | Type | Description |
|-------|------|-------------|
| `userId` | string (UUID) | Authenticated user identity |
| `displayName` | string | Pulled from Postgres at join; immutable during session |
| `docId` | string (UUID) | Which document this cursor belongs to |
| `color` | string (hex) | Assigned server-side at join |
| `position` | JSON `{line, col}` | Last known cursor position |
| `selection` | JSON `{anchor, head}` \| null | Current selection range |
| `seq` | integer | Monotonically increasing per-socket counter |
| `lastSeen` | epoch ms | Updated on every message; used for idle/TTL |
| `tabId` | string | Client-generated UUID per tab; allows same user in multiple tabs |

TTL: 5 minutes, reset on every update message. Expires automatically if client crashes without sending a leave.

### 4.2 Room Membership (Redis set, key `room:{docId}`)

Members: `socketId` strings. Used to enumerate participants when a new user joins and needs the current state snapshot.

### 4.3 Color Palette

```js
const PALETTE = [
  '#E53935', '#8E24AA', '#1E88E5', '#00897B',
  '#F4511E', '#6D4C41', '#039BE5', '#3949AB',
  '#43A047', '#FB8C00', '#00ACC1', '#D81B60',
];
// Assignment: PALETTE[room_member_count % PALETTE.length] at join time
// Server owns assignment; client never sends a preferred color.
```

---

## 5. API and Protocol

### 5.1 WebSocket Events

All messages are JSON. The server validates JWT on the initial Socket.IO handshake (via `auth` option); connections without a valid token are rejected before any room is joined.

#### Client → Server

| Event | Payload | Notes |
|-------|---------|-------|
| `presence:join` | `{ docId }` | Server checks doc permission in Postgres, assigns color, broadcasts snapshot to new joiner, announces new participant to room |
| `presence:cursor` | `{ docId, position: {line,col}, selection: {anchor,head}\|null, seq }` | Throttled client-side to ≤ 20/sec; rate-limited server-side to 30/sec |
| `presence:leave` | `{ docId }` | Sent on unmount/beforeunload; server removes presence and broadcasts |
| `presence:ping` | `{ docId }` | Sent every 60 s if user is idle; resets server-side TTL |

#### Server → Client

| Event | Payload | Notes |
|-------|---------|-------|
| `presence:snapshot` | `{ participants: Participant[] }` | Sent only to the joining client; full current state |
| `presence:joined` | `{ participant: Participant }` | Broadcast to room when someone new joins |
| `presence:update` | `{ socketId, position, selection, seq, lastSeen }` | Broadcast on every cursor move |
| `presence:left` | `{ socketId }` | Broadcast on clean leave or TTL expiry |
| `presence:error` | `{ code, message }` | Non-fatal; sent to the individual client only |

#### Participant object schema

```ts
interface Participant {
  socketId: string;
  userId: string;
  displayName: string;
  color: string;     // hex, server-assigned
  tabId: string;
  position: { line: number; col: number } | null;
  selection: { anchor: number; head: number } | null;
  seq: number;
  idle: boolean;     // server sets true when lastSeen > 3 min
}
```

### 5.2 REST Endpoint (minimal addition)

No new REST endpoints are strictly required. The existing session/auth token is reused for the Socket.IO handshake. If the team wants a fallback presence poll (for environments that block WebSockets), a single endpoint can be added:

```
GET /api/documents/:docId/presence
Authorization: Bearer <token>
Response: { participants: Participant[] }
```

This endpoint reads from Redis and returns the current room snapshot. It is optional and not on the critical path.

---

## 6. Sequence Diagrams

### 6.1 User Joins a Document

```
Client A                  Presence Service              Redis               Client B (already in room)
  │                              │                        │                        │
  │─── WS connect (JWT) ────────►│                        │                        │
  │                              │── auth.verify ─────────┤                        │
  │                              │── doc permission check ┤                        │
  │◄── connected ────────────────│                        │                        │
  │                              │                        │                        │
  │─── presence:join {docId} ───►│                        │                        │
  │                              │── SADD room:{docId} ──►│                        │
  │                              │── HSET presence:{sid} ►│                        │
  │                              │── SMEMBERS room:{docId}│                        │
  │◄── presence:snapshot ────────│                        │                        │
  │                              │─── presence:joined ────┼──────────────────────►│
```

### 6.2 Cursor Move

```
Client A                  Presence Service              Redis               Client B
  │                              │                        │                        │
  │── [mouse move] (debounced)   │                        │                        │
  │─── presence:cursor ─────────►│                        │                        │
  │                              │── rate-limit check     │                        │
  │                              │── seq validation       │                        │
  │                              │── HSET presence:{sid} ►│                        │
  │                              │── PUBLISH room:{docId} ┼──────────────────────►│
  │                              │                        │  presence:update       │
```

### 6.3 Clean Disconnect

```
Client A                  Presence Service              Redis               Client B
  │                              │                        │                        │
  │─── presence:leave ──────────►│                        │                        │
  │                              │── DEL presence:{sid}  ►│                        │
  │                              │── SREM room:{docId}   ►│                        │
  │                              │── PUBLISH presence:left┼──────────────────────►│
  │── WS disconnect ────────────►│                        │                        │
```

### 6.4 Unclean Disconnect (network drop)

```
Client A              Socket.IO           Presence Service        Redis          Client B
  │  [drops]               │                    │                   │                │
  │                        │── disconnect event ►│                  │                │
  │                        │                    │── DEL presence── ►│                │
  │                        │                    │── SREM room ─────►│                │
  │                        │                    │── PUBLISH left ───┼───────────────►│
  │                        │   [within Socket.IO disconnect timeout, default 20 s]   │
```

Socket.IO's built-in heartbeat (default ping interval 25 s, timeout 20 s) detects the dead connection. Worst-case detection is ~45 s; presence:left is emitted at that point, which is within the "a few seconds" spec when interpreted as "best effort, not guaranteed sub-second."

---

## 7. Frontend Design

### 7.1 State Management

```ts
// Zustand slice (or Redux slice — same shape)
interface PresenceState {
  participants: Map<string, Participant>; // socketId → Participant
  mySocketId: string | null;
}
```

Rules:
- On `presence:snapshot`: replace entire map (minus own socketId).
- On `presence:joined`: add entry.
- On `presence:update`: apply only if incoming `seq` > stored `seq`; discard otherwise.
- On `presence:left`: remove entry.
- Never render own socketId as a remote cursor.

### 7.2 Cursor Overlay Component

```tsx
// Rendered in a positioned overlay over the editor canvas
function CursorOverlay({ editorView }: { editorView: EditorView }) {
  const participants = usePresenceStore(s => [...s.participants.values()]);
  const displayedCursors = participants.slice(0, 12);
  const overflowCount = Math.max(0, participants.length - 12);

  return (
    <div className="cursor-overlay" aria-hidden="true">
      {displayedCursors.map(p => (
        <RemoteCursor key={p.socketId} participant={p} editorView={editorView} />
      ))}
      {overflowCount > 0 && <OverflowBadge count={overflowCount} />}
    </div>
  );
}
```

Cursor position is converted from `{line, col}` to pixel coordinates using the editor's coordinate mapping API (CodeMirror: `view.coordsAtPos()`; ProseMirror: `view.coordsAtPos()`).

### 7.3 Throttle and Debounce

```ts
// Pointer/selection change handler
const sendCursorUpdate = useMemo(
  () => throttle((pos, sel) => {
    socket.emit('presence:cursor', {
      docId,
      position: pos,
      selection: sel,
      seq: nextSeq(),
    });
  }, 50),  // 50 ms → max 20 updates/sec
  [socket, docId]
);
```

### 7.4 Idle Fade

A `useEffect` timer checks `participant.lastSeen` every 30 seconds. If `Date.now() - lastSeen > 180_000` (3 min), the cursor's CSS opacity is reduced to 0.3. It returns to 1.0 on the next `presence:update`.

### 7.5 Graceful Degradation

The Socket.IO connection attempt has a timeout. If the connection fails or the service emits `presence:error`, the client silently logs the error and renders no cursor overlay. The document editor remains fully functional. No error banner is shown to the user unless the failure persists beyond a configurable threshold (e.g., 3 retries over 30 s), at which point a subtle non-blocking toast is acceptable.

---

## 8. Server-Side Logic

### 8.1 Authorization on Join

```
1. Decode and verify JWT from handshake auth.token.
2. Look up userId in Postgres.
3. Query doc_permissions WHERE doc_id = :docId AND user_id = :userId AND can_view = true.
4. If not authorized → emit presence:error {code: 'FORBIDDEN'} and leave room.
5. Cache the permission result in Redis (key: perm:{userId}:{docId}, TTL 60 s) to avoid a Postgres hit on every reconnect.
```

### 8.2 Rate Limiting

Token bucket per socket, server-side:
- Capacity: 60 tokens
- Refill: 30 tokens/sec
- Each `presence:cursor` message costs 1 token
- On bucket empty: message silently dropped; after 3 consecutive drops, emit `presence:error {code: 'RATE_LIMITED'}` to the offending client only

Other participants are not affected.

### 8.3 Sequence Validation

The server does not reorder; it simply broadcasts the latest update. Clients discard if `incoming.seq <= stored.seq`. This is sufficient because:
- Updates are per-socket, so the sequence is per-user-per-tab.
- Only the most recent position matters; there is no history to reconstruct.

### 8.4 Multi-Node Scaling

When running multiple Node processes:

```
Node 1 (Client A's socket) ──► Redis PUBLISH room:{docId} "cursor_update"
Node 2 (Client B's socket) ──► Redis SUBSCRIBE room:{docId} → forward to B's socket
```

Each Presence Service node subscribes to the room channels for all currently-connected clients. Redis pub/sub fan-out handles the cross-node delivery. Socket.IO's official `@socket.io/redis-adapter` implements this pattern and should be used.

### 8.5 TTL-Based Stale Cleanup

A lightweight background loop (setInterval, 30 s) scans active rooms and checks `lastSeen` on each presence hash. If `Date.now() - lastSeen > 300_000` (5 min), the entry is treated as stale: presence hash is deleted, socketId is removed from room set, and a `presence:left` event is published. This handles clients that disconnect without firing the disconnect event (e.g., browser crash with no Socket.IO heartbeat detection).

---

## 9. Security

| Threat | Mitigation |
|--------|-----------|
| Unauthorized cursor access | JWT verified on handshake; Postgres permission check on `presence:join`; permission cached in Redis for 60 s |
| Cursor identity spoofing | `displayName` and `color` pulled server-side from Postgres at join; client payload for these fields is ignored |
| Flood / DoS from one client | Token bucket rate limiter per socket (30 msg/sec); excess silently dropped; offending client notified after 3 drops |
| Cursor data leaking across documents | Room namespaced by `docId`; server validates client's `docId` claim matches their authorized document |
| Replay of old cursor positions | Sequence numbers; client discards `seq ≤ stored`; no sensitive data in cursor payloads anyway |
| WebSocket hijacking | Socket.IO over TLS (wss://); JWT expiry and rotation handled by existing auth layer |

---

## 10. Operational Concerns

### 10.1 Metrics to Instrument

| Metric | Type | Alert threshold |
|--------|------|----------------|
| `presence.connected_sockets` | Gauge | — |
| `presence.room_size` per docId | Histogram | p99 > 50 (investigate) |
| `presence.cursor_events_per_sec` | Counter | — |
| `presence.rate_limited_drops` | Counter | Spike > 100/min |
| `presence.join_latency_ms` | Histogram | p99 > 500 ms |
| `presence.redis_pubsub_lag_ms` | Histogram | p99 > 100 ms |

### 10.2 Redis Failure Mode

If Redis is unavailable:
- The Presence Service logs the error and falls back to in-process room state (single node only — no cross-node sync).
- Cursor updates still work for clients on the same node.
- On multi-node deployments, cross-node delivery fails silently; clients on different nodes see no cursors for each other.
- The document editor is unaffected in all cases.

### 10.3 Presence Service Failure Mode

If the entire Presence Service is down:
- React client's Socket.IO connection fails; the client catches the error and suppresses it.
- The editor loads and is fully editable.
- No cursor overlay is shown; no error is surfaced to the user unless retries are exhausted (see §7.5).

### 10.4 Horizontal Scaling

- Presence Service is stateless aside from Redis.
- Socket.IO sticky sessions (via load-balancer cookie or IP hash) are required so reconnects land on the same node during a session; this avoids double-join edge cases.
- Redis cluster or Redis Sentinel for HA.

---

## 11. Rollout Plan

1. **Phase 1 — Infrastructure:** Add Redis to the stack; deploy the Presence Service behind the existing load balancer with Socket.IO sticky sessions.
2. **Phase 2 — Backend:** Implement join/leave/cursor events, auth check, rate limiter, TTL cleanup. Deploy behind a feature flag (`presence_enabled`).
3. **Phase 3 — Frontend:** Add Socket.IO client, presence Zustand slice, cursor overlay component. Feature-flagged off by default.
4. **Phase 4 — Internal rollout:** Enable for internal users; measure metrics; tune rate limiter and TTL values.
5. **Phase 5 — GA:** Remove feature flag; monitor for Redis pub/sub lag and room size anomalies.

---

## 12. Open Questions / Deferred Decisions

| # | Question | Default assumption used in this design |
|---|----------|----------------------------------------|
| 1 | Which rich-text editor is in use (CodeMirror, ProseMirror, Slate, Monaco)? | Position encoded as `{line, col}` (universal); coordinate mapping is editor-specific and encapsulated in `RemoteCursor` component. |
| 2 | Is Redis already in the stack? | Assumed not yet; adding it is the first infrastructure step. If already present, skip. |
| 3 | Multiple Presence Service nodes from day one? | Designed for it (Redis adapter), but single-node is fine for the initial rollout. |
| 4 | Exact Socket.IO ping/timeout tuning? | Default values (25 s interval, 20 s timeout) assumed; tune based on observed disconnect latency in production. |
| 5 | JWT expiry shorter than a long editing session? | Assumed the existing auth layer handles token refresh; Presence Service re-validates on reconnect. |
