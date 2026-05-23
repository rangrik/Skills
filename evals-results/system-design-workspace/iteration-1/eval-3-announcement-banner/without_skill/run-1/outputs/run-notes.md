# Run Notes

**Date:** 2026-05-23

## Key Decisions & Assumptions

**Propagation mechanism:** Chose polling (60 s interval) over WebSockets. The blueprint says "within a short time" — interpreted as ~1 minute being acceptable for a non-urgent banner. WebSockets would add infrastructure complexity disproportionate to the feature.

**Expiry enforcement:** Enforced at query time rather than via a background cron job. Simpler operationally; latency on expiry is bounded by the poll interval.

**"Replace" semantics:** Implemented as setting `is_active = FALSE` on the old banner in the same DB transaction as inserting the new one. Old rows are retained for potential audit history.

**Dismissal scoped to banner ID, not text:** The blueprint explicitly states editing text does not un-dismiss; tying dismissal rows to `announcement_id` (not content) naturally satisfies this.

**Link field:** Blueprint mentions "optional link" with no further spec. Assumed it needs both a URL and an optional display label, both stored on the banner row.

**`starts_at` default:** Defaults to `NOW()` at insert time so immediate publishing needs no special-case code path.

**Authorization:** Assumed a pre-existing role system with per-workspace admin roles accessible via `req.user`.
