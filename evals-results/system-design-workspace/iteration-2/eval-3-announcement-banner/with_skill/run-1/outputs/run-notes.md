# Run Notes — Announcement Banner System Design (Autonomous)

**Run date:** 2026-05-23  
**Mode:** Fully autonomous (no human interview)

## Key decisions made autonomously

1. **Poll interval (60 s):** The blueprint says "within a short time" with no SLA number. Chose 60 s as the standard background-refresh interval. This is the most likely point a human would push back on — flagged as A6 needing product confirmation.

2. **Date-window at read time, not cron:** Rejected a background job for start/end enforcement in favor of a query-time filter, eliminating the "job fails, banner stays live" failure class.

3. **Optional link modeled as URL + label:** Blueprint says "optional link" without specifying a display label. Added `link_label` column as nullable; flagged as a product gap.

4. **Dismissal server-side:** No ambiguity — the blueprint's cross-device requirement forecloses localStorage.

5. **Partial unique index for single-active invariant:** Chose DB-level enforcement over application-only logic (Principle 9).

## What I would have asked a human

- Confirm the 60-second poll window is acceptable, or specify a tighter SLA.
- Confirm whether the optional link has a display label in the admin UI.
- Identify the exact React shell component that should mount the banner.
- Confirm a feature-flag system exists (or specify the rollout toggle mechanism).
