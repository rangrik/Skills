# Run Notes — Collab Cursors System Design

**Key autonomous decisions:**

1. **Transport:** Chose Socket.IO over raw WebSockets for built-in reconnect, heartbeat, and the battle-tested Redis adapter for multi-node scaling — no prior art in the codebase to constrain this.

2. **Redis assumed not present:** Blueprint says REST-only today, so Redis was added as a new dependency. If it already exists, Phase 1 of rollout collapses.

3. **Editor assumed generic:** The specific rich-text editor (CodeMirror, ProseMirror, etc.) was not specified; position is encoded as `{line, col}` with coordinate mapping delegated to an editor-specific adapter inside the React component.

4. **Idle threshold:** Blueprint says "a few minutes" — interpreted as 3 min for client-side fade and 5 min for server-side TTL eviction, giving a two-tier grace window.

5. **Disconnect detection lag:** Blueprint says cursors disappear "within a few seconds" on disconnect. Socket.IO's default heartbeat means worst-case ~45 s for unclean disconnects; this was flagged as a tuning point rather than changed by default.

6. **Single Presence Service process:** Designed for horizontal scaling from day one via Redis adapter, but recommended starting with one process for simplicity.
