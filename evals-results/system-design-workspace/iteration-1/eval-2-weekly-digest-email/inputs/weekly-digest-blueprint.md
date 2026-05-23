# Behavior Blueprint: Weekly Digest Email

**Status:** Approved · **Date:** 2026-05-14

## Summary

Every Monday morning, each user receives an email digest summarizing
activity in their workspace over the previous seven days: new items,
completed items, comments mentioning them, and a short "what changed"
headline. The email is sent at 8:00 AM in the user's own timezone.

## Happy path

1. On Monday at 8:00 AM local time, the system assembles a digest for a
   user from the past week's workspace activity.
2. The user receives one email with: a headline summary, counts (new /
   completed / commented), and up to ten highlighted items with links.
3. Clicking any item link opens that item in the app.
4. Each email has a one-click "unsubscribe from digests" link in the
   footer.

## Behaviors and rules

- The digest covers the rolling seven days ending Monday 00:00 local time.
- Send time is 8:00 AM in each user's configured timezone. Users in
  different timezones receive the email at different absolute times.
- A user with digests turned off receives nothing.
- **If a user had no relevant activity in the past week, no email is sent**
  — the system never sends an empty digest.
- Each user receives at most one digest email per week.
- The "highlighted items" are chosen by recency, capped at ten; the email
  notes "+N more" if there were more.
- Unsubscribing is immediate and takes effect before the next Monday.

## Edge cases

- **A brand-new user who joined mid-week:** they receive a digest covering
  only the days since they joined, if there was activity.
- **A user with activity but in a workspace that was deleted:** no email.
- **A user whose timezone is not set:** the digest defaults to 8:00 AM UTC.
- **A user changes their timezone on Sunday night:** the next digest uses
  the new timezone; a small shift in send time is acceptable.

## Deviation scenarios

- **The email provider is down or rejects a message at send time:** that
  user's digest is retried; if it still fails after retries, it is dropped
  for the week rather than delayed into the afternoon — a digest that
  arrives late is worse than one skipped.
- **The weekly job is triggered twice** (e.g. a deploy re-runs it): a user
  must still receive only one digest for that week.
- **The job is delayed and starts late:** users still get the correct
  seven-day window; send time may slip but content is unaffected.

## Adversarial scenarios

- An unsubscribe link must act only on the account it was issued for and
  must not be guessable to unsubscribe someone else.
- Digest content for a user must only include items that user is allowed to
  see.

## Out of scope

- Daily or monthly digest frequencies.
- User customization of which activity types appear.
- In-app rendering of the digest.
