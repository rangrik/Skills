# Behavior Blueprint: Real-Time Collaborative Cursors

**Status:** Approved · **Date:** 2026-05-18

## Summary

When several people have the same document open in the editor, each person
sees the live cursors of everyone else — a colored caret with a small name
label that moves as that person moves. Cursors appear when someone opens
the document and disappear when they leave.

## Happy path

1. Two or more users open the same document in the editor.
2. Each user sees a colored cursor for every other user currently in the
   document, labeled with that user's name.
3. As a user moves their cursor or selection, the others see it move in
   near real time.
4. When a user closes the document or goes offline, their cursor disappears
   for everyone else within a few seconds.

## Behaviors and rules

- Each participant is assigned a stable color for the duration of their
  session in that document.
- A cursor shows the user's name on hover, and always shows their colored
  caret; a text selection is shown as a colored highlight range.
- Cursor positions are ephemeral presence data — they are never saved with
  the document and have no value once the session ends.
- Updates should feel immediate; a visible lag of more than about a quarter
  second between someone moving and others seeing it feels broken.
- The document content itself is edited and saved by the existing editor;
  this feature only adds the presence layer on top.
- A user never sees their own cursor drawn as a remote cursor.

## Edge cases

- **Many people in one document:** beyond a dozen or so participants, show
  a count ("+8 others") rather than crowding the document with carets.
- **A user is idle:** after a few minutes with no movement, their cursor
  fades but is not removed; it returns to full on their next movement.
- **A user opens the same document in two tabs:** each tab is its own
  participant with its own cursor.
- **A user has the document open but loses focus** (switches apps): their
  cursor remains shown to others until they actually disconnect.

## Deviation scenarios

- **A user's network drops briefly:** their cursor freezes in place, then
  either resumes when they reconnect or disappears once the disconnect is
  detected.
- **The presence service is unavailable:** the document still opens and is
  fully editable; collaborators simply do not see each other's cursors, and
  no error blocks the editor.
- **Cursor updates arrive out of order:** only the most recent position for
  a given user is shown; stale updates are discarded.

## Adversarial scenarios

- A user must only receive cursor data for documents they are allowed to
  open.
- A user must not be able to spoof another user's name or color on a
  cursor.
- A flood of rapid cursor updates from one client must not degrade the
  experience for everyone else in the document.

## Out of scope

- Collaborative editing / conflict resolution of document content (already
  handled by the editor).
- Persisting or replaying cursor history.
- Voice, video, or chat presence.
