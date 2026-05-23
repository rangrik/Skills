# Run Notes — Collab Cursors System Design (Autonomous Run)

## Key decisions made autonomously

- **WebSocket (not SSE or polling):** Forced by the 250 ms latency cap and the bidirectional fan-out pattern; SSE would require a second channel for outbound moves.
- **In-process, no Postgres, no Redis at launch:** Blueprint states cursors are explicitly ephemeral; Postgres writes would be wasteful. Redis deferred until multi-process scale is needed.
- **Server-authoritative color + identity:** The adversarial "no spoofing" requirement mandates this; color from JWT-backed server assignment, not client self-report.
- **20 Hz client throttle + server-side rate limiter:** Satisfies both the smoothness requirement and the flood-prevention adversarial scenario.
- **10 s heartbeat / 5 s timeout:** Meets "disappears within a few seconds" with a worst-case of 15 s.
- **Global feature flag, default off:** Simplest rollout path; per-org scoping deferred.

## What I would have asked a human

1. **Editor library and position API** (highest risk assumption A3) — ProseMirror/CodeMirror assumed; must confirm before implementation.
2. **HTTP server bootstrap** (A1) — can the existing server accept WebSocket upgrade events?
3. **JWT in query string acceptable?** Or is a short-lived presence ticket needed for log hygiene?
4. **Is 15 s worst-case cursor disappear latency acceptable?**
5. **Preferred color palette / accessibility requirements for cursor colors.**
