# Behavior Blueprint: GitHub Contributions Widget

**Status:** Approved · **Date:** 2026-05-10

## Summary

A widget on a member's public profile page that displays their GitHub
contribution graph — the familiar grid of green squares showing commit
activity over the trailing 12 months. The member connects their GitHub
account once; the widget then renders their activity on every visit.

## Happy path

1. On their profile settings page, the member clicks "Connect GitHub."
2. They complete GitHub's OAuth consent screen and return to our app.
3. The widget appears on their public profile, showing the 12-month
   contribution grid, total contributions for the year, and the longest
   streak.
4. Any visitor to that public profile sees the same widget.
5. The member can click "Refresh" on the widget to pull the latest data.

## Behaviors and rules

- The widget shows: the 53-week grid, total contributions (trailing year),
  current streak, and longest streak.
- Contribution data is considered fresh enough if it is less than 24 hours
  old. Visitors never trigger a fetch; they see whatever is stored.
- The "Refresh" button is available only to the profile owner, and only
  once per hour (a visible cooldown timer shows when it is on cooldown).
- If the member has connected GitHub but has zero contributions, the widget
  shows an empty grid with the text "No public contributions yet."
- A member can disconnect GitHub from settings; the widget then disappears
  from their profile and stored contribution data is removed.

## Edge cases

- **Member never connected GitHub:** no widget shown; settings page shows
  the "Connect GitHub" button instead.
- **GitHub account has only private contributions:** the grid reflects
  whatever the GitHub API returns for the authorized scope; if the count is
  zero, treat it as the empty state.
- **Member renamed their GitHub username:** the connection is by account
  ID, so a rename does not break the widget.
- **Profile is set to private on our platform:** the widget is not shown to
  visitors, only to the owner.

## Deviation scenarios

- **GitHub is slow or unreachable when data is needed:** the widget shows
  the last successfully stored grid with a small "Last updated <time>"
  label. It never shows a hard error to visitors.
- **The member's GitHub token is revoked or expired:** the owner sees a
  "Reconnect GitHub" prompt in place of the widget; visitors see the last
  stored grid.
- **GitHub returns a rate-limit response:** the refresh silently fails and
  the cooldown still applies; the owner sees "Couldn't refresh right now,
  try again later."

## Adversarial scenarios

- A visitor should never be able to trigger a data fetch or see another
  member's GitHub token.
- A member should not be able to refresh faster than the cooldown by
  scripting the request.

## Out of scope

- Contribution graphs for organizations or repositories.
- Historical data older than 12 months.
- Any write access to GitHub.
