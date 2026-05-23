# Behavior Blueprint: Admin Announcement Banner

**Status:** Approved · **Date:** 2026-05-15

## Summary

Lets a workspace admin post a short announcement banner that appears at the
top of the app for every user in the workspace. Users can dismiss the
banner. The admin can give it a start and end date. Only one banner is
active at a time.

## Happy path

1. An admin opens the "Announcements" page in admin settings.
2. They type a short message (plain text, up to 200 characters), optionally
   pick a start date/time and end date/time, and click "Publish."
3. Within a short time, every user in the workspace sees the banner across
   the top of the app.
4. A user clicks the "x" on the banner to dismiss it; it does not come back
   for that user.
5. When the end date passes, the banner stops showing for everyone.

## Behaviors and rules

- The banner is a single line of plain text plus an optional link.
- At most one banner is active per workspace. Publishing a new one replaces
  the previous active banner.
- If no start date is given, the banner is active immediately. If no end
  date is given, it stays active until the admin removes it.
- Dismissal is per user: once a user closes the banner, they do not see
  that banner again, even across devices and sessions.
- An admin can edit the active banner's text; an edit does **not** bring it
  back for users who already dismissed it.
- An admin can end a banner early by clicking "Remove."

## Edge cases

- **A user who joins after a banner was published:** they see it (if still
  within its active window) and have not dismissed it.
- **The start date is in the future:** the banner does not show until then.
- **The end date is before the start date:** publishing is rejected with a
  validation message.
- **No banner is active:** users simply see no banner; this is the normal
  case.

## Deviation scenarios

- **An admin publishes a banner while another admin is editing the old
  one:** the most recent publish wins; the active banner is whichever was
  published last.
- **A user dismisses the banner, then the admin edits its text:** the user
  still does not see it — dismissal sticks to the banner, not its text.

## Adversarial scenarios

- Only admins of the workspace may create, edit, or remove banners.
- A non-admin must not be able to publish a banner by crafting a request.

## Out of scope

- Rich text, images, or multiple simultaneous banners.
- Targeting a banner to a subset of users.
- Scheduling a recurring banner.
