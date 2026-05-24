# Implementation Plan: Workspace API Key Rotation

## Source Scope

This plan is based only on the approved behavior blueprint for workspace API key rotation and the accompanying system design. It is code-blind and should be used as the implementation guide before inspecting the Kite codebase.

## Product Outcome

Workspace admins can rotate a workspace API key without immediately breaking live integrations. A rotation creates a new current key, keeps the old key valid for a 24-hour grace period, records successful use of the old key during that grace period, and then revokes the old key automatically. Admins can also revoke the old key early.

## Non-Goals

- Per-integration scoped API keys.
- More than two valid keys at once.
- Recovering or re-displaying a full key after the one-time creation response.
- Distinguishing revoked keys from unknown keys in authentication failures.

## Global Invariants

- A workspace has one current key.
- A workspace may also have one superseded key while its grace period is still open.
- No workspace may have more than two valid keys at once.
- Full key material is never persisted in recoverable form. Store only salted hashes plus non-secret display metadata such as a masked prefix.
- The full new key value is shown exactly once, in the rotation result.
- During grace, both the current key and the superseded key authenticate requests.
- Every successful request authenticated with the superseded key during grace records a lightweight usage event.
- At grace expiry, the superseded key is no longer valid even if the scheduled revocation job has not run.
- Rotate and revoke actions are server-side admin-only operations.
- Revoked and unknown keys return the same generic authentication failure, with no response difference that reveals whether a key ever existed.

## Grace Boundary Rule

Use one canonical server-side evaluation time for each authentication decision. The superseded key is valid only when the evaluation time is strictly before grace_expires_at. A request evaluated exactly at grace_expires_at, or any time after it, is rejected as expired and treated the same as a revoked or unknown key externally.

This rule must be shared by authentication, lazy expiry enforcement, background revocation, and tests.

## Implementation Sequence

### 1. Locate Existing Ownership and Contracts

Before editing code, identify the existing code paths for:

- Workspace settings and admin authorization.
- Workspace API key storage, hashing, creation, and display metadata.
- API key authentication middleware or service entry points.
- Background jobs, scheduled tasks, or worker queues.
- Audit, event, or usage-recording patterns.
- Workspace settings UI routes and data-loading patterns.

Keep the feature inside those existing ownership boundaries instead of introducing a parallel key system.

### 2. Add the Key State Model

Implement the storage shape needed for the state machine:

- Key records can represent current, superseded, and revoked states.
- Superseded records carry a grace_expires_at timestamp.
- Revoked records carry revocation metadata sufficient for audit and cleanup.
- Key lookup remains indexed by salted hash so authentication stays a single indexed lookup.
- Display metadata supports a masked prefix without exposing full key material.
- Usage events can reference the workspace and superseded key record without storing the plaintext key.

Migration expectations:

- Existing workspace API keys become current keys.
- Existing plaintext key material, if any, must not be newly exposed or migrated into recoverable storage.
- Constraints or transactional guards must preserve at most one current key and at most one not-yet-expired superseded key per workspace.

Verification:

- Existing workspaces still authenticate with their current key after migration.
- Data constraints prevent multiple current keys for the same workspace.
- Data constraints or service-level guards prevent multiple simultaneously valid superseded keys.

### 3. Implement Admin Authorization for Rotation and Revocation

Add or extend server-side operations for:

- Rotate workspace API key.
- Revoke old key now.
- Fetch current key status for the settings page.
- Fetch superseded-key usage summary or event list for the settings page.

Authorization requirements:

- Workspace admins may rotate.
- Workspace admins may revoke the old key.
- Non-admin workspace members and unauthenticated users may not rotate or revoke.
- UI gating is useful but not sufficient; the server must enforce authorization on every path.

Verification:

- Admin requests succeed when otherwise valid.
- Non-admin rotate and revoke attempts fail.
- Direct API calls bypassing the UI still enforce admin-only behavior.

### 4. Implement Happy-Path Rotation

When an admin rotates a key and no grace period is active:

- Generate a new high-entropy key.
- Hash and store the new key as the workspace current key.
- Move the previously current key into superseded state.
- Set grace_expires_at to 24 hours after the rotation time.
- Return the full new key value exactly once in the rotation response.
- Return enough non-secret metadata for the UI to show the masked key state afterward.

The rotation state transition must be transactional so the workspace never observes a missing current key or more valid keys than allowed.

Verification:

- After rotation, the old key and new key both authenticate before grace expiry.
- The old key has a grace_expires_at timestamp 24 hours after rotation.
- Reloading the page after rotation never shows the full new key again.
- Only masked metadata is available after the one-time response.

### 5. Implement Authentication Across Current, Superseded, and Revoked Keys

Extend authentication to resolve a presented key through the indexed salted-hash lookup and evaluate the resolved record state:

- Current key authenticates normally.
- Superseded key authenticates only before grace_expires_at.
- Superseded key at or after grace_expires_at is rejected.
- Revoked key is rejected.
- Unknown key is rejected.
- Revoked, expired, and unknown failures are externally identical.

Successful authentication with the superseded key must enqueue or write a usage event before the request is considered complete enough for admin visibility. The usage event should be lightweight and should not affect the single indexed key lookup requirement.

Verification:

- Current key requests authenticate.
- Superseded key requests authenticate before grace expiry.
- Superseded key requests record usage events.
- Current key requests do not create old-key usage events.
- Revoked, expired, and unknown keys produce the same status, response body shape, headers, and logging exposure appropriate for generic rejection.

### 6. Enforce Grace Expiry Reliably

Implement both scheduled and lazy expiry enforcement:

- A background job finds superseded keys whose grace_expires_at has passed and marks them revoked.
- Authentication performs the same boundary check and rejects expired superseded keys even if the background job is late.
- The lazy path may also mark the expired superseded key revoked, but correctness must not depend on that write succeeding before the rejection.

Boundary behavior:

- Just before grace_expires_at, the superseded key is accepted.
- Exactly at grace_expires_at, the superseded key is rejected.
- Just after grace_expires_at, the superseded key is rejected.

Verification:

- Tests use controlled time to cover before, exactly at, and after the boundary.
- If the background job is disabled or delayed, authentication still rejects the expired key.
- If no integration ever used the old key during grace, expiry and revocation still happen normally.

### 7. Implement Revoke Old Key Now

When an admin revokes the old key during an active grace period:

- Mark the superseded key revoked immediately.
- Preserve the current key unchanged.
- Stop accepting the old key immediately after the transaction commits.
- Keep existing usage history available for admin review.

The operation should be safe if retried after the old key is already revoked or no grace period is active. The UI can disable the action when no old key is revocable, but the server should still handle stale or repeated requests gracefully.

Verification:

- Old key authenticates before manual revoke.
- Old key is rejected immediately after manual revoke.
- New current key continues to authenticate.
- Repeating revoke does not corrupt current key state.
- Non-admin revoke attempts fail.

### 8. Implement Rotate Again During Active Grace

When an admin rotates while a grace period is already active, apply the required state transition transactionally:

- The existing superseded key is revoked immediately.
- The existing current key becomes the new superseded key.
- The new superseded key receives a fresh 24-hour grace period.
- A newly generated key becomes the current key.
- Only the newly generated key is shown in full, exactly once.

Example state progression:

- Before first rotation: key A is current.
- After first rotation: key B is current, key A is superseded until its grace expiry.
- After second rotation during that grace period: key C is current, key B is superseded with a fresh grace expiry, and key A is revoked immediately.

Concurrency requirements:

- Concurrent rotations for the same workspace must be serialized or guarded by a version check.
- The later committed rotation wins.
- No interleaving may leave key A and key B both valid as superseded keys.
- No interleaving may leave the workspace without a current key.

Verification:

- After the second rotation, the first old key is rejected immediately.
- After the second rotation, the previously current key authenticates during its fresh grace period.
- The new current key authenticates.
- The first old key and an unknown key are rejected identically.
- Simulated concurrent rotations never produce more than one current key and one valid superseded key.

### 9. Implement Old-Key Usage Visibility

Expose admin-visible usage of the superseded key during grace:

- Record each successful superseded-key authentication event.
- Show whether the old key has been used during the grace period.
- Provide enough timing information for admins to decide whether to wait, notify an integration owner, or revoke early.
- Preserve usage history after manual revoke or automatic expiry for the relevant rotation window.

Privacy and security expectations:

- Do not store plaintext keys in usage events.
- Avoid exposing request details beyond what existing workspace audit or usage patterns permit.
- Do not record usage for rejected revoked, expired, or unknown keys in a way that becomes visible as proof that a key existed.

Verification:

- A successful old-key request appears in admin-visible usage.
- Multiple old-key requests are represented according to the product pattern chosen, such as event rows or aggregate counts.
- No usage during grace still results in normal expiry and a clear no-usage state.
- Rejected revoked-key attempts do not appear as valid old-key usage.

### 10. Implement Workspace Settings UI

Update the API Keys page in workspace settings:

- Admins can start rotation.
- The newly generated key is shown exactly once after rotation.
- After leaving or refreshing the page, only masked key metadata is shown.
- During grace, the page indicates that an old key is temporarily valid.
- During grace, admins can revoke the old key now.
- During grace and after revocation or expiry, admins can inspect old-key usage for the rotation window.
- Non-admins cannot access rotation or revoke controls.

UI state expectations:

- Rotation success state must make it hard to miss that the full key is one-time visible.
- Revoke controls should reflect loading, success, failure, and stale-state outcomes.
- If another admin rotates or revokes in another session, the page should refresh or reconcile to the server state without relying on stale local assumptions.

Verification:

- Admin can complete the happy path from the settings page.
- Full key is visible only in the immediate rotation success state.
- Refreshing removes the full key from the UI.
- Old-key usage appears after a successful old-key request.
- Revoke old key now removes old-key validity from the UI state after the server confirms.
- Non-admin UI paths do not expose privileged controls.

### 11. Add Observability and Operational Safety

Add internal observability for:

- Rotation attempts, successes, and failures.
- Manual revocations.
- Automatic grace-expiry revocations.
- Lazy expiry rejections.
- Superseded-key successful usage during grace.

Security constraint:

- Internal logs may help operators diagnose behavior, but external API responses must never distinguish unknown, expired, and revoked keys.
- Logs must not contain plaintext API keys.

Verification:

- Rotation and revoke flows emit the expected internal events or metrics.
- No plaintext key appears in logs, usage events, analytics, or persisted records.
- Authentication rejection responses remain generic even when internal logs classify the cause.

## End-to-End Scenario Checklist

### Scenario A: Happy Rotation With Grace

Given a workspace has key A as current and an admin rotates it, key B becomes current, key A becomes superseded for 24 hours, both keys authenticate before grace expiry, and key B is shown in full only once.

Implementation depends on scenarios 2, 3, 4, 5, and 10.

### Scenario B: Grace-Period Boundary

Given key A is superseded with grace_expires_at set, authentication with key A succeeds just before grace_expires_at and fails exactly at grace_expires_at and afterward, regardless of whether the background job has already revoked the record.

Implementation depends on scenarios 5 and 6.

### Scenario C: Rotate Again Mid-Grace

Given key A is superseded and key B is current, when an admin rotates again during A's grace period, key A is revoked immediately, key B becomes superseded with a fresh 24-hour grace period, and key C becomes current.

Implementation depends on scenarios 4, 5, and 8.

### Scenario D: Manual Revocation

Given key A is superseded during grace, when an admin clicks revoke old key now, key A stops authenticating immediately and the current key continues to authenticate.

Implementation depends on scenarios 5, 7, and 10.

### Scenario E: Revoked-Key Rejection

Given a request presents a revoked key, an expired key, or an unknown key, authentication rejects the request with the same generic external response and does not reveal whether the key ever existed.

Implementation depends on scenarios 5, 6, 7, and 8.

### Scenario F: Old-Key Usage Recording

Given an integration uses the superseded key during grace, the request authenticates and a lightweight usage event is recorded for admin visibility. Given no integration uses the old key, expiry still revokes it normally at the end of grace.

Implementation depends on scenarios 5, 6, 9, and 10.

### Scenario G: Authorization Enforcement

Given a non-admin attempts to rotate or revoke, the server rejects the action. Given an admin performs the same action, the server applies the state transition.

Implementation depends on scenarios 2, 4, 7, 8, and 10.

## Test Strategy

Prioritize tests around the state machine and security boundary before broad UI coverage.

State-machine tests:

- First rotation creates current plus superseded.
- Manual revoke transitions superseded to revoked.
- Automatic expiry transitions superseded to revoked.
- Second rotation during grace revokes the prior superseded key immediately.
- Concurrent rotations preserve at most one current and one valid superseded key.

Authentication tests:

- Current key authenticates.
- Superseded key authenticates before grace expiry.
- Superseded key fails exactly at grace_expires_at.
- Superseded key fails after grace_expires_at even if background expiry has not run.
- Revoked, expired, and unknown keys produce indistinguishable external failures.
- Superseded-key success records usage.
- Rejected key attempts do not create valid old-key usage.

Authorization tests:

- Admin can rotate.
- Admin can revoke old key.
- Non-admin cannot rotate.
- Non-admin cannot revoke.
- UI-hidden controls are not relied on for authorization.

UI tests:

- Rotation displays the full key once.
- Reloading after rotation displays only masked metadata.
- Active grace state shows old-key status and revoke action to admins.
- Usage appears after an old-key request.
- Manual revoke updates the old-key state.
- Non-admin view omits privileged actions.

Operational tests:

- Background job revokes expired superseded keys.
- Late background job does not allow expired-key authentication.
- Logs and persisted records do not contain plaintext keys.
- Auth lookup remains indexed and does not introduce avoidable latency.

## Rollout Plan

1. Ship storage migration and compatibility reads for existing current keys.
2. Add state-machine services and authentication support behind server-side tests.
3. Add rotation and revoke endpoints with admin authorization.
4. Add expiry job and lazy expiry handling.
5. Add usage recording and admin read model.
6. Add settings UI for rotation, one-time key display, grace status, revoke, and usage.
7. Enable in an internal or staged environment and run end-to-end tests with controlled time.
8. Release broadly once revoked-key rejection, boundary behavior, and mid-grace rotation are verified.

## Completion Criteria

The feature is complete when:

- Admins can rotate a workspace API key from settings.
- The new key is shown in full exactly once.
- The previous key works for 24 hours unless manually revoked.
- At the exact grace boundary, the previous key is rejected.
- A second rotation during grace immediately revokes the first old key and gives the previously current key a fresh grace period.
- Revoked, expired, and unknown keys are rejected identically.
- Successful old-key usage during grace is visible to admins.
- Revocation does not depend solely on timely background job execution.
- All admin-only paths are enforced server-side.
- Tests cover the happy path, grace boundary, mid-grace rotation, manual revoke, revoked-key rejection, no-usage expiry, and authorization failures.
