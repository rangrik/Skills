# Run Notes — Collab Cursors System Design (Autonomous)

## Key autonomous decisions

1. **WebSocket over polling/SSE** — blueprint's 250 ms latency target makes polling non-viable; chose WebSocket on the existing Node server over a managed service to keep the design self-contained.

2. **In-memory only, no Postgres** — blueprint explicitly calls cursor data ephemeral; Redis pub/sub added as an additive scale path, not required on day one.

3. **50 Hz client throttle, 30 s heartbeat TTL** — reasonable defaults inferred from the blueprint's timing language; made configurable via env vars so they can be tuned without a redeploy.

4. **Single-process assumed for initial deploy** — the stack is REST-only today, implying a simple deployment; Redis fan-out path is fully designed but gated on actual multi-process need.

5. **Room size cap at display layer only** — server broadcasts all positions; client renders at most 12. Deferred server-side fan-out filtering to an open risk.

## What I would have asked a human

- Does the JWT/session carry the display name, or does it require a DB lookup?
- Is the load balancer WebSocket-capable, and what is the idle timeout?
- Are there any known high-concurrency documents (classrooms, live events) that would push room sizes past 50?
- Is the backend already running multiple processes behind a load balancer (affects Redis day-one need)?
- Which editor library does the frontend use (CodeMirror, ProseMirror) — affects cursor position encoding in the wire schema.
