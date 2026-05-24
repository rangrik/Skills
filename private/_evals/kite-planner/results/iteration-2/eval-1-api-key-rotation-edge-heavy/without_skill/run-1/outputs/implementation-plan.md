# Implementation Plan: Workspace API Key Rotation

## Source Inputs

This plan is based on:

- Behavior blueprint: `api-key-rotation-blueprint.md`
- System design: `api-key-rotation-system-design.md`

## Feature Goal

Workspace admins can rotate a workspace API key without immediately breaking live integrations. Rotation creates a new current key, keeps the previous key valid as a superseded key for a 24-hour grace period, records successful use of the superseded key during that grace period, and reliably revokes the superseded key when the grace period ends or when an admin revokes it early.

The implementation must preserve these invariants:

- Only workspace admins can rotate a key or revoke a superseded key.
- The full plaintext value of a newly generated key is shown exactly once in the rotation response.
- Plaintext API keys are never stored in recoverable form.
- A workspace has at most one current key and at most one superseded key.
- At most two keys can authenticate for a workspace at any time: the current key and, only during grace, the superseded key.
- A key in revoked state must never authenticate.
- Unknown keys and revoked keys produce the same generic authentication rejection.
- Grace-period expiry is enforced by authentication itself as well as by a background revocation job.
- The grace-period boundary is deterministic and uses a single canonical comparison against `grace_expires_at`.

## Scenario Order

Build in this order so each scenario creates a stable foundation for the next:

1. Model key records and validity states.
2. Authenticate current keys through hashed lookup.
3. Rotate a key and return the new plaintext value once.
4. Authenticate both current and superseded keys during grace.
5. Record superseded-key usage during grace.
6. Revoke the superseded key when grace expires, including the boundary condition.
7. Revoke the superseded key early by admin action.
8. Rotate again while a grace period is active.
9. Reject revoked and unknown keys without disclosing key existence.
10. Harden authorization, concurrency, and observability around the full state machine.

## Scenario 1: Model Key Records and Validity States

### Behavior

Represent workspace API keys as records with enough state to distinguish current, superseded, and revoked keys. A workspace must never have more than one current key and one superseded key that is still within grace.

### Implementation Plan

- Add or extend persistence for workspace API key records.
- Store only salted hashes of key values, never plaintext.
- Track the workspace owner, key state, masked display prefix, creation time, optional supersession time, optional `grace_expires_at`, optional revocation time, and revocation reason.
- Define the key states as `current`, `superseded`, and `revoked`.
- Ensure records support indexed lookup by key hash so authentication does not require scanning workspace key sets.
- Add database-level or transactional safeguards so a workspace cannot end up with multiple current keys after rotation.
- Add a migration path for any existing workspace key so it becomes the initial `current` key under the new model.

### Verification

- Confirm a workspace can have one current key.
- Confirm a workspace can have one current and one superseded key.
- Confirm revoked keys remain stored for lookup and audit but are not considered valid.
- Confirm plaintext key values are not persisted.
- Confirm lookup by presented key hash is indexed.

## Scenario 2: Authenticate Current Keys Through Hashed Lookup

### Behavior

Requests bearing the current workspace API key authenticate successfully with no grace-period logic involved.

### Implementation Plan

- Update the API key authentication path to hash the presented key using the same scheme used at key creation.
- Resolve the hash to a single key record.
- Accept a matching key only if its state is `current`.
- Preserve existing workspace scoping and request identity behavior after the key record is resolved.
- Make the authentication path return a generic failure for missing, malformed, unknown, revoked, or expired keys.

### Verification

- A valid current key authenticates.
- A missing key is rejected generically.
- A malformed key is rejected generically.
- A random unknown key is rejected generically.
- Authentication latency remains a single indexed lookup plus state validation.

## Scenario 3: Rotate a Key and Return the New Plaintext Value Once

### Behavior

An admin on the workspace API Keys settings page can click "Rotate key." The system generates a new key, stores only its salted hash, marks it as current, and returns the full plaintext key exactly once in the rotation response.

### Implementation Plan

- Add a rotate-key server action or API endpoint for the workspace settings surface.
- Enforce workspace admin authorization on the server before generating or mutating keys.
- Generate a new high-entropy API key value.
- Compute and store the salted hash and masked prefix.
- In a single transaction, change the existing current key to `superseded`, set its `grace_expires_at` to 24 hours after the rotation time, and create or mark the generated key as `current`.
- Return the plaintext new key only in the successful rotation response.
- Ensure all subsequent reads of the key settings data expose only masked prefixes and metadata.
- Update the settings page to show the new key once, then fall back to masked display after dismissal or refresh.

### Verification

- A non-admin cannot rotate a key.
- An admin can rotate a key.
- The response includes the full new key exactly once.
- Refreshing or reloading the settings page does not reveal the full key again.
- The old key becomes superseded with a 24-hour `grace_expires_at`.
- The new key becomes current immediately.

## Scenario 4: Authenticate Both Current and Superseded Keys During Grace

### Behavior

During the grace period, both the newly generated current key and the previous superseded key authenticate successfully.

### Implementation Plan

- Extend authentication validity checks to accept a key in `superseded` state only when the current request time is still within its grace window.
- Use one canonical time source for the comparison.
- Use a single comparison rule throughout the application: a superseded key is valid only when the request time is strictly before `grace_expires_at`.
- Keep the current key validation independent of grace-period status.
- Do not allow any revoked key to authenticate, even if it has a future or stale `grace_expires_at`.

### Verification

- Immediately after rotation, the current key authenticates.
- Immediately after rotation, the superseded key authenticates.
- A superseded key for one workspace does not authenticate as another workspace.
- A revoked key does not authenticate even if its hash is known.

## Scenario 5: Record Superseded-Key Usage During Grace

### Behavior

Every successful request authenticated with the superseded key during grace is recorded so admins can see whether integrations still use the old key.

### Implementation Plan

- Add a lightweight usage event for successful superseded-key authentication.
- Record enough data for admin visibility without storing the presented key value.
- Include workspace, key record, request time, and safe request context such as endpoint or integration-identifying metadata if already available.
- Write the usage event only after authentication succeeds.
- Do not write usage events for current-key authentication.
- Do not write usage events for rejected, expired, revoked, malformed, or unknown keys.
- Expose the usage summary or event list on the API Keys settings page during the grace period and after revocation if audit visibility is expected by existing settings patterns.

### Verification

- A successful superseded-key request during grace creates a usage event.
- A successful current-key request creates no superseded usage event.
- An expired superseded-key request creates no usage event.
- A revoked-key request creates no usage event.
- The settings page can show whether the old key is still being used.

## Scenario 6: Revoke the Superseded Key When Grace Expires

### Behavior

At the end of the grace period, the superseded key stops working. Revocation must happen reliably even if a background job is delayed.

### Implementation Plan

- Add a background job that finds superseded keys whose `grace_expires_at` has passed and marks them revoked.
- Add lazy expiry enforcement in authentication: if a request presents a superseded key at or after `grace_expires_at`, authentication must reject it and ensure the key is treated as revoked from then on.
- Make the lazy revocation update idempotent so concurrent requests at the boundary cannot produce inconsistent state.
- Preserve the current key unchanged when revoking the superseded key.
- Ensure no grace-period usage event is written for a request rejected because the grace window has closed.

### Grace-Period Boundary Rule

Use the deterministic rule:

- Superseded key is valid when request time is before `grace_expires_at`.
- Superseded key is invalid when request time is equal to or after `grace_expires_at`.

This rule must be used by both authentication and the background revocation job.

### Verification

- A request just before `grace_expires_at` with the superseded key succeeds.
- A request exactly at `grace_expires_at` with the superseded key is rejected.
- A request after `grace_expires_at` with the superseded key is rejected.
- The current key still succeeds before, at, and after the old key's `grace_expires_at`.
- If the background job has not run yet, authentication still rejects the expired superseded key.
- If multiple expired-key requests arrive concurrently, the key ends in revoked state and all boundary-or-later requests are rejected.

## Scenario 7: Revoke the Superseded Key Early

### Behavior

An admin can click "Revoke old key now" during the grace period. After early revocation, the superseded key no longer authenticates.

### Implementation Plan

- Add an early-revoke server action or API endpoint.
- Enforce workspace admin authorization on the server.
- Allow early revoke only when the workspace currently has a superseded key that has not already been revoked.
- Mark the superseded key revoked with a revocation reason indicating admin action.
- Leave the current key unchanged.
- Make the operation idempotent for already-revoked or already-expired superseded keys, returning the current key-state view without revealing extra key material.
- Update the settings page so the revoke action is available only while a superseded key is active during grace.

### Verification

- A non-admin cannot revoke the old key.
- An admin can revoke the old key during grace.
- After early revocation, the superseded key is rejected.
- After early revocation, the current key still authenticates.
- Repeating the revoke action does not change the current key or produce an error state.

## Scenario 8: Rotate Again While a Grace Period Is Active

### Behavior

If an admin rotates again while a grace period is still active, the previous superseded key is revoked immediately. The previously current key becomes the new superseded key with a fresh 24-hour grace period. The newly generated key becomes current.

### Implementation Plan

- Implement rotation as a single transactional state transition.
- Lock or guard the workspace key set so concurrent or repeated rotations cannot leave multiple superseded keys.
- During rotation, identify the current key and any active superseded key from the transaction's consistent view.
- If a superseded key already exists, mark it revoked immediately with a revocation reason indicating replacement by a subsequent rotation.
- Mark the previously current key as superseded and assign a fresh `grace_expires_at` based on the second rotation time.
- Create or mark the newly generated key as current.
- Return only the newest plaintext key in the second rotation response.
- Ensure the older superseded key is rejected immediately after the second rotation, even if its original grace period had time remaining.

### Verification

- Start with key A as current.
- Rotate once: key A becomes superseded, key B becomes current, key A has grace expiry A1.
- While key A is still within grace, rotate again: key A becomes revoked, key B becomes superseded, key C becomes current, key B has fresh grace expiry B1.
- After the second rotation, key A is rejected immediately.
- After the second rotation, key B authenticates until B1.
- After the second rotation, key C authenticates as current.
- The system never has more than one current key and one superseded key.
- The second rotation response reveals only key C, not key A or key B.

## Scenario 9: Reject Revoked and Unknown Keys Without Disclosure

### Behavior

A request bearing a revoked key must be rejected, and the rejection must not reveal whether the key ever existed. Unknown keys and revoked keys must be indistinguishable to the caller.

### Implementation Plan

- Normalize authentication failures for unknown, revoked, expired, malformed, and missing keys into the same response shape, status, and public error message.
- Avoid separate public messages such as "key revoked," "key expired," or "key not found."
- Keep detailed reason codes only in internal logs or metrics, if such internal classification is already appropriate.
- Ensure revoked keys remain resolvable internally by hash so the system can consistently reject them and support internal audit, without exposing that fact externally.
- Do not record superseded-key usage for rejected revoked-key attempts.

### Verification

- A revoked key and a random unknown key receive the same public rejection response.
- A previously valid but expired superseded key receives the same public rejection response as an unknown key.
- A manually revoked superseded key receives the same public rejection response as an unknown key.
- No response body, header, timing-sensitive branch, or settings-facing unauthenticated endpoint reveals whether the rejected key ever existed.

## Scenario 10: Authorization, Concurrency, and Observability Hardening

### Behavior

The complete rotation state machine must remain correct under unauthorized access, concurrent admin actions, delayed jobs, and repeated requests.

### Implementation Plan

- Apply server-side workspace admin authorization to every mutation path: rotate and revoke.
- Keep UI authorization checks as convenience only, not as enforcement.
- Make rotation transactionally safe against two admins rotating at nearly the same time.
- Make early revoke transactionally safe against rotation happening at nearly the same time.
- Make background expiry and lazy auth-time expiry idempotent.
- Add internal metrics or logs for rotation success, early revoke success, grace expiry revocation, lazy expiry revocation, superseded-key usage, and generic auth rejection.
- Avoid logging plaintext key values.
- Ensure audit or operational events reference key records by internal identifier and masked prefix only.

### Verification

- Concurrent rotations settle into one current key, at most one superseded key, and all older superseded keys revoked.
- Concurrent early revoke and rotation do not revoke the newly current key.
- Background expiry and auth-time lazy expiry can run in either order without inconsistent state.
- Internal logs and metrics contain no plaintext API keys.
- Unauthorized users cannot infer key state through mutation responses.

## UI Plan

### API Keys Settings Page

- Show the current key masked prefix and creation metadata.
- After rotation, show the full new key value exactly once.
- Provide a clear dismissal or copied state after the one-time reveal, then show only masked data.
- During an active grace period, show the superseded key masked prefix, grace expiration time, revoke action, and usage information.
- Hide or disable "Revoke old key now" when there is no active superseded key.
- After grace expiry or early revocation, show that only the current key is active.
- Do not expose revoked-key details beyond safe masked or audit-oriented information already available to workspace admins.

### UI Verification

- Admin sees rotate controls.
- Non-admin does not see mutation controls and is still blocked server-side if they attempt direct mutation.
- One-time key reveal disappears after navigation, refresh, or dismissal.
- Active grace state shows the old key's remaining grace status and usage.
- Expired or revoked grace state no longer offers old-key authentication or active revoke controls.

## Data and Migration Plan

- Introduce the key record state model without changing existing external key format unless required by the current platform.
- Backfill existing workspace API keys as `current`.
- Preserve existing authentication behavior for current keys during rollout.
- Add nullable supersession, grace expiry, revocation, and masked-prefix fields as needed.
- Add indexes needed for hash lookup and workspace-state queries.
- Add constraints or transaction guards for one current key per workspace.
- If strict database constraints for one active superseded key are not feasible, enforce the invariant inside rotation and revocation transactions and cover it with concurrency tests.

## Background Job Plan

- Add a scheduled job that revokes superseded keys whose `grace_expires_at` is at or before the job's canonical current time.
- Make the job idempotent and safe to retry.
- Limit each run to a bounded batch if the platform has large workspaces or many keys.
- Record operational success and failure metrics.
- Rely on auth-time lazy expiry for correctness if the job is late.

## Security Plan

- Use high-entropy key generation.
- Store salted hashes only.
- Never persist, log, or re-display plaintext keys after the rotation response.
- Enforce admin authorization on all key mutations.
- Return generic auth rejection for unknown, revoked, expired, malformed, and missing keys.
- Ensure revoked keys cannot authenticate through stale cache, delayed background work, or race conditions.
- Ensure more than two valid keys cannot exist even under repeated rotations.

## Test Plan

### Unit Tests

- Key state transitions from current to superseded to revoked.
- Rotation creates a new current key and supersedes the old current key.
- Early revoke marks only the superseded key revoked.
- Grace boundary accepts before `grace_expires_at` and rejects at or after `grace_expires_at`.
- Revoked and unknown keys map to the same public rejection.
- Plaintext key value is not persisted in any key record.

### Integration Tests

- Admin rotation returns the new key once and updates settings state.
- Non-admin rotation and revoke attempts are rejected.
- Current and superseded keys both authenticate during grace.
- Superseded-key authentication records usage during grace.
- Superseded key no longer authenticates after grace expiry, even before the background job runs.
- Early revoked old key is rejected immediately.
- Rotating again mid-grace revokes the older superseded key and gives the previously current key a fresh grace window.
- Background job revokes expired superseded keys without affecting current keys.

### Concurrency Tests

- Two concurrent rotations produce one final current key, at most one superseded key, and revoked older keys.
- Rotation concurrent with early revoke cannot revoke the newly generated current key.
- Multiple requests using a superseded key exactly at expiry are rejected consistently and leave the key revoked.
- Background expiry concurrent with auth-time lazy expiry is idempotent.

### UI Tests

- Rotate flow shows full new key once.
- Reload after rotation shows only masked key data.
- Active grace state shows old key usage.
- Revoke old key action removes old-key validity.
- Non-admin cannot access mutation behavior through the UI and is blocked by the server.

## Rollout Plan

1. Ship the data model and migration with current-key authentication still behaving as before.
2. Enable the new authentication validity model for current keys.
3. Enable rotation for admins behind the appropriate release mechanism.
4. Enable superseded-key usage recording and grace-period UI.
5. Enable background expiry job.
6. Verify lazy auth-time expiry is active before relying on the background job for cleanup.
7. Monitor rotation, revoke, expired-key rejection, and generic auth rejection metrics.

## Non-Goals

- Per-integration scoped keys.
- More than two valid keys at once.
- Re-displaying plaintext key values after creation.
- Publicly telling callers whether a rejected key was unknown, expired, or revoked.

## Completion Criteria

The feature is complete when:

- An admin can rotate a workspace API key and see the new plaintext key exactly once.
- During the 24-hour grace period, both current and superseded keys authenticate.
- Superseded-key usage is recorded during grace.
- A superseded key is rejected exactly at and after `grace_expires_at`.
- An admin can revoke the superseded key early.
- Rotating again mid-grace immediately revokes the older superseded key and starts a fresh grace period for the previously current key.
- Revoked, expired, unknown, malformed, and missing keys all produce the same generic public rejection.
- The system remains correct under concurrent rotations, concurrent revoke and rotation, delayed background jobs, and auth-time lazy expiry.
