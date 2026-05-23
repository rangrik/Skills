# Behavior Blueprint: Workspace API Key Rotation

**Status:** Approved · **Date:** 2026-05-20

## Summary

Lets a workspace admin rotate the workspace's API key: generate a new key,
keep the old key working for a short grace period, then revoke the old key.
This avoids breaking live integrations during a rotation.

## Happy path

1. An admin opens the "API Keys" page in workspace settings.
2. They click "Rotate key." A new key is generated and shown once.
3. The old key keeps working for a 24-hour grace period.
4. After the grace period, the old key stops working; only the new key is valid.

## Behaviors and rules

- The full new key value is shown exactly once, at creation time. Afterward
  only a masked prefix is shown.
- During the grace period both the old and the new key authenticate requests.
- An admin can end the grace period early by clicking "Revoke old key now."
- Each request authenticated with the old key during the grace period is
  recorded, so the admin can see whether anything is still using it.

## Edge cases

- **An admin rotates again while a grace period is still active:** the previous
  old key is revoked immediately, and the previously-new key becomes the new
  old key with a fresh grace period.
- **A request arrives exactly at the grace-period boundary:** it is evaluated
  against the current validity rule deterministically (no ambiguous window).
- **No integration ever uses the old key during the grace period:** revocation
  at the end of the window still happens normally.

## Adversarial scenarios

- Only workspace admins may rotate or revoke keys.
- A request bearing a revoked key must be rejected, and the rejection must not
  reveal whether the key ever existed.

## Out of scope

- Per-integration scoped keys.
- More than two keys valid at once.
