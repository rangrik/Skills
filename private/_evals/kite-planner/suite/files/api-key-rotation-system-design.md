# System Design: Workspace API Key Rotation

**Reads alongside:** api-key-rotation-blueprint.md

## Summary

Rotation is modeled as a state machine on the workspace's key set. A workspace
has at most two active key records: the `current` key and, during a grace
period, a `superseded` key with a `grace_expires_at` timestamp. Authentication
checks both records. A background job (and a lazy check at auth time) enforces
revocation once the grace window closes, so expiry never depends solely on a
timer firing on time.

## Key technical decisions

- **Storage.** Keys are stored as salted hashes, never plaintext. The full key
  value exists only in the response to the rotation request and is never
  persisted in recoverable form.
- **Validity model.** Auth resolves a presented key to a key record and checks
  its state (`current`, `superseded` within grace, or `revoked`). The boundary
  is evaluated with a single canonical comparison against `grace_expires_at` so
  there is no ambiguous window.
- **Concurrency.** Rotation is a transactional state transition guarded so that
  two concurrent rotations cannot leave more than one `superseded` key; the
  later rotation wins and immediately revokes the prior `superseded` key.
- **Usage recording.** Each successful auth with a `superseded` key writes a
  lightweight usage event so an admin can see whether the old key is still live.
- **Authorization.** Rotate and revoke are admin-only, enforced server-side on
  every path.
- **Rejection.** A revoked or unknown key yields an identical generic rejection
  so the response does not disclose whether a key ever existed.

## Quality expectations

- Auth latency must not regress; the key lookup is a single indexed hash lookup.
- Revocation at grace expiry must be reliable even if the background job is late.

## Accepted compromises

- At most two keys valid at once (current + one superseded); richer key sets are
  out of scope and revisited only if multi-integration scoping is requested.
