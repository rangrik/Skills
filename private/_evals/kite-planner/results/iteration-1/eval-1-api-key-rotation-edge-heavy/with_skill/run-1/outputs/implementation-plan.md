# Implementation Plan: Workspace API Key Rotation

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/api-key-rotation-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/api-key-rotation-system-design.md
- Summary: Workspace admins can rotate a workspace API key without immediately breaking integrations. Rotation creates a new current key, shows its full plaintext value exactly once, keeps the prior key valid as a superseded key for a 24-hour grace period, records successful use of the superseded key during grace, and then revokes the superseded key. The implementation must enforce admin-only mutation paths, deterministic grace-boundary handling, reliable expiry even when scheduled jobs are late, immediate revocation of older superseded keys when rotating again mid-grace, and indistinguishable rejection for revoked and unknown keys.

## Scenario order & status
| # | ID | Title | Status |
|---|----|-------|--------|
| 1 | S1 | Admin rotates a workspace API key and starts grace for the old key | planned |
| 2 | S2 | Non-admin cannot rotate a workspace API key | planned |
| 3 | S3 | Newly generated key is shown once and later masked | planned |
| 4 | S4 | Current and superseded keys authenticate during active grace, with old-key usage recorded | planned |
| 5 | S5 | Admin revokes the superseded key before grace expires | planned |
| 6 | S6 | Non-admin cannot revoke the superseded key | planned |
| 7 | S7 | Superseded key expires normally even when unused | planned |
| 8 | S8 | Request at the exact grace-period boundary is deterministic | planned |
| 9 | S9 | Admin rotates again while grace is active | planned |
| 10 | S10 | Revoked and unknown keys are rejected without existence disclosure | planned |

## Ordering rationale
- S1 establishes the core rotation state transition: a current key becomes superseded, a new current key is created, and a grace window is attached to the superseded key. Most later scenarios depend on this state shape.
- S2 protects the first mutation path as soon as it exists, using the same rotate surface from S1.
- S3 completes the user-facing handling of the generated secret while the rotation response path is still fresh.
- S4 makes the grace state operational in authentication and introduces usage recording for superseded keys.
- S5 builds the explicit admin revocation path once a superseded key can authenticate and be observed.
- S6 applies the authorization rule to the revoke path after that path exists.
- S7 adds automatic and lazy revocation at grace expiry, using the superseded-key state and auth behavior already introduced.
- S8 focuses on the boundary rule after expiry enforcement exists, so the comparison semantics can be verified precisely.
- S9 builds the second rotation on top of the initial rotation and revocation behavior, including the at-most-two-active-keys constraint.
- S10 validates the generic rejection contract across all revoked-key sources introduced earlier: early revoke, expiry, and second rotation.

## Scenario S1 - Admin rotates a workspace API key and starts grace for the old key
- Order: 1
- Type: happy_path
- Status: planned
- Design references: Storage; Validity model; Concurrency; Authorization; Accepted compromises

### Gherkin
Given a workspace has an existing current API key
And a workspace admin is on the API Keys page in workspace settings
When the admin chooses to rotate the workspace API key
Then a new current API key is generated
And the previous current key becomes a superseded key
And the superseded key has a grace period that expires 24 hours after rotation
And the workspace has no more than one current key and one superseded key
And the full new key value is returned for immediate display

### Code-blind plan
- Preconditions: The workspace has exactly one current key before rotation. The actor is authenticated as a workspace admin. The system can determine the canonical rotation time used to compute the grace expiry.
- Required capabilities: A workspace API Keys settings surface with a rotate action; server-side authorization for workspace admin actions; generation of a new high-entropy API key value; salted hash storage for API keys with no recoverable plaintext persistence; a transactional key state transition from current to superseded plus new current; grace expiry calculation at 24 hours; a response shape that can carry the one-time plaintext key; protection against concurrent rotations leaving more than one superseded key.
- Postconditions: The new key is the workspace current key. The prior key is superseded and valid until its grace expiry under the validity model. The full new key value exists only in the rotation response and is not recoverably stored. The workspace key set obeys the at-most-two-active-keys compromise.
- Risks / assumptions: The design requires the mutation to be transactional and concurrency guarded. The plan assumes the API Keys page already has a concept of the selected workspace and authenticated actor, but research must confirm the concrete surfaces and patterns.

### Research questions
- RQ1: Where is the workspace settings API Keys page or route implemented, and what existing action pattern should a rotate control use?
- RQ2: Is there an existing server-side authorization helper for verifying workspace admin permissions? If so, where and how is it applied to workspace settings mutations?
- RQ3: Is there an existing API key generation utility or secret generation pattern suitable for workspace API keys? If so, where?
- RQ4: Is there an existing salted-hash storage pattern for API keys or comparable secrets? If so, where?
- RQ5: Where should the workspace API key state transition be modeled so that current, superseded, grace expiry, and revoked states are represented consistently?
- RQ6: What transaction or locking mechanism is available for guarding concurrent workspace key rotations?
- RQ7: What response handling pattern supports returning a one-time secret value from a mutation without persisting plaintext?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S2 - Non-admin cannot rotate a workspace API key
- Order: 2
- Type: corner_case
- Status: planned
- Design references: Authorization

### Gherkin
Given a workspace has an existing current API key
And an authenticated user is not a workspace admin
When the user attempts to rotate the workspace API key
Then the rotation is rejected
And no new key is generated
And the existing current key remains unchanged
And no superseded key or grace period is created

### Code-blind plan
- Preconditions: The rotate action from S1 exists. The system can distinguish workspace admins from non-admin workspace users or other authenticated actors.
- Required capabilities: Server-side authorization on the rotate mutation; failure handling that prevents partial key creation or state transition; a user-facing failure state for a denied rotate attempt; verification that denial leaves the key set unchanged.
- Postconditions: Non-admin users cannot rotate keys through the UI or direct server calls. Rejected attempts have no side effects on key state.
- Risks / assumptions: Authorization must not rely on UI visibility alone. The plan assumes denied mutation responses can be represented without disclosing key material.

### Research questions
- RQ1: What permission model distinguishes workspace admins from other users for workspace-level settings?
- RQ2: Where should rotate authorization be enforced server-side so that UI and direct request paths share the same rule?
- RQ3: What standard error or denial pattern should be used for unauthorized workspace mutations?
- RQ4: How can tests or existing helpers verify that a failed mutation leaves workspace key records unchanged?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S3 - Newly generated key is shown once and later masked
- Order: 3
- Type: edge_case
- Status: planned
- Design references: Storage; Key technical decisions; Blueprint full-key display rule

### Gherkin
Given a workspace admin has rotated the workspace API key
And the rotation response displayed the full new key value once
When the admin leaves and later returns to the API Keys page
Then the full key value is not shown again
And only a masked prefix or non-secret key identifier is shown

### Code-blind plan
- Preconditions: S1 has created a current key and returned the plaintext value once. The API Keys page can render key metadata after the initial rotation response is gone.
- Required capabilities: A persisted non-secret display field or derivable masked prefix; UI state for showing the one-time plaintext key immediately after rotation; page reload or revisit behavior that fetches only non-secret key metadata; guarantees that plaintext key material is never persisted in recoverable form.
- Postconditions: Admins can identify the current key after creation without seeing the full secret again. Reloading, revisiting, or querying key metadata cannot recover the plaintext key.
- Risks / assumptions: The masked prefix must be long enough to be useful but not treated as an authenticator. Research must determine whether key prefixes are stored separately or derived from non-secret metadata at creation time.

### Research questions
- RQ1: What UI pattern exists for one-time secret reveal messages or panels after a mutation?
- RQ2: Where should non-secret key metadata, such as masked prefix and creation time, be stored and fetched?
- RQ3: Is there an existing masking or secret-display component that should be reused?
- RQ4: How can the page distinguish the immediate post-rotation display state from later visits?
- RQ5: Are there tests or conventions for ensuring secret plaintext is not returned by metadata fetches?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S4 - Current and superseded keys authenticate during active grace, with old-key usage recorded
- Order: 4
- Type: happy_path
- Status: planned
- Design references: Validity model; Usage recording; Quality expectations

### Gherkin
Given a workspace admin has rotated the workspace API key
And the old key is superseded but still within its grace period
When an integration sends a request authenticated with the old key
Then the request is accepted
And a lightweight usage event is recorded for the superseded key
When an integration sends a request authenticated with the new current key
Then the request is accepted
And no superseded-key usage event is recorded for the current key

### Code-blind plan
- Preconditions: S1 has produced a current key and a superseded key with a future grace expiry. The authentication path can resolve a presented key to a workspace key record.
- Required capabilities: Indexed lookup by presented key hash; validity checks for current and superseded-within-grace states; authentication behavior that accepts both valid records during grace; usage event creation only for successful auth with a superseded key; an admin-visible way to inspect whether the old key is still being used; latency-preserving implementation that avoids extra broad lookups.
- Postconditions: Integrations using either the new key or the old key keep working during grace. Every successful old-key request during grace is visible as usage signal to admins. Current-key requests are not incorrectly counted as old-key usage.
- Risks / assumptions: Usage recording must be lightweight enough not to regress auth latency. Research must identify whether usage events should be exact per-request rows, aggregated signals, or existing audit/event records that satisfy the product rule.

### Research questions
- RQ1: Where is API key authentication performed, and how does it currently resolve a presented key to a workspace or credential record?
- RQ2: What indexed lookup or schema support exists for hashed API keys?
- RQ3: Where should the validity model for current, superseded within grace, and revoked states live so all API key auth paths share it?
- RQ4: What existing event, audit, analytics, or activity model can record successful superseded-key authentication?
- RQ5: Where should the API Keys page display old-key usage during grace?
- RQ6: What performance tests or conventions exist for guarding auth latency on key lookup paths?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S5 - Admin revokes the superseded key before grace expires
- Order: 5
- Type: edge_case
- Status: planned
- Design references: Validity model; Authorization; Rejection

### Gherkin
Given a workspace admin has rotated the workspace API key
And the old key is superseded and still within its grace period
When the admin chooses to revoke the old key now
Then the superseded key is revoked immediately
And the current key remains valid
And subsequent requests using the old key are not authenticated as valid

### Code-blind plan
- Preconditions: S1 has created a superseded key with active grace. S4 has made superseded-key auth behavior explicit. The actor is authenticated as a workspace admin.
- Required capabilities: UI affordance to revoke the old key during grace; server-side revoke mutation; admin authorization on the revoke mutation; transactional state transition from superseded to revoked; preservation of the current key; auth validity logic that no longer accepts revoked keys.
- Postconditions: Admins can end the grace period early. The old key becomes unusable immediately. The current key is unaffected.
- Risks / assumptions: Revoke should be idempotent or gracefully handle repeated attempts after the key is already revoked or no superseded key exists. Research must determine the product's standard handling for stale UI actions.

### Research questions
- RQ1: Where should the "Revoke old key now" control appear on the API Keys page during an active grace period?
- RQ2: What mutation pattern should be used for explicit revocation of a workspace key?
- RQ3: How should the system represent a revoked key record while preserving enough metadata for generic rejection and audit behavior?
- RQ4: What existing pattern handles repeated or stale mutation attempts when the targeted state has already changed?
- RQ5: How should tests verify that current-key authentication remains valid after revoking the superseded key?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S6 - Non-admin cannot revoke the superseded key
- Order: 6
- Type: corner_case
- Status: planned
- Design references: Authorization

### Gherkin
Given a workspace has a superseded key still within its grace period
And an authenticated user is not a workspace admin
When the user attempts to revoke the old key now
Then the revoke attempt is rejected
And the superseded key remains valid until its grace expiry unless another valid revocation path occurs
And the current key remains unchanged

### Code-blind plan
- Preconditions: S5 has introduced the revoke mutation. The system can identify the actor's workspace role.
- Required capabilities: Server-side authorization on the revoke mutation; denied-response handling for non-admin users; no-side-effect guarantees for failed revoke attempts; UI-level hiding or disabling of the revoke control for non-admins as a convenience, with server enforcement as the source of truth.
- Postconditions: Non-admin users cannot shorten another integration's grace period or alter key state. Rejected revoke attempts preserve both current and superseded key validity.
- Risks / assumptions: The product rule says only admins may revoke, so any delegated or service-user role must be evaluated by the same admin permission model unless the design later expands it.

### Research questions
- RQ1: Can the same workspace-admin authorization helper from rotate be reused for revoke?
- RQ2: Where should revoke authorization be enforced so direct requests cannot bypass UI gating?
- RQ3: What standard unauthorized response should be used for a denied revoke mutation?
- RQ4: What test pattern verifies a denied mutation does not modify persisted state?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S7 - Superseded key expires normally even when unused
- Order: 7
- Type: edge_case
- Status: planned
- Design references: Validity model; Quality expectations; Blueprint no-usage edge case

### Gherkin
Given a workspace admin has rotated the workspace API key
And no integration uses the superseded key during the grace period
When the 24-hour grace period has passed
Then the superseded key is revoked
And only the current key remains valid
And revocation does not depend solely on a background job firing on time

### Code-blind plan
- Preconditions: S1 has created a superseded key with grace expiry. S4 has defined auth acceptance during grace. The system has access to canonical time when checking validity.
- Required capabilities: Background job or scheduled worker that revokes superseded keys whose grace window has closed; lazy auth-time expiry enforcement that rejects or transitions expired superseded keys even if the background job is late; metadata on the API Keys page showing that the old key is no longer active; tests or controls for time-based behavior without relying on real elapsed time.
- Postconditions: A superseded key becomes invalid after grace even if it was never used. Late background execution cannot extend old-key validity. The current key remains valid.
- Risks / assumptions: The design explicitly requires both background and lazy enforcement. Research must identify the job framework and the appropriate place for the auth-time fallback without adding multiple inconsistent expiry rules.

### Research questions
- RQ1: What background job or scheduler framework should enforce expired superseded-key revocation?
- RQ2: Where can auth-time lazy expiry be implemented so all API key auth paths use the same canonical comparison?
- RQ3: What time provider or test helper exists for deterministic time-based tests?
- RQ4: How should the API Keys page represent an ended grace period with no old-key usage events?
- RQ5: What persistence update should occur when a superseded key is found expired by the background job or lazy auth path?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S8 - Request at the exact grace-period boundary is deterministic
- Order: 8
- Type: edge_case
- Status: planned
- Design references: Validity model; Quality expectations

### Gherkin
Given a workspace has a superseded key with a known grace_expires_at timestamp
When a request authenticated with the superseded key arrives exactly at grace_expires_at
Then the request is evaluated by the system's single canonical boundary comparison
And the result is deterministic
And there is no ambiguous interval where the same boundary request might be accepted in one path and rejected in another

### Code-blind plan
- Preconditions: S7 has introduced expiry enforcement. The system design's canonical comparison rule has a single place to live. Tests can control or simulate exact boundary time.
- Required capabilities: One shared validity function or policy for comparing request time to grace expiry; a documented choice of whether equality is inside or outside the grace window; reuse of that comparison by background revocation and lazy auth checks; deterministic boundary tests for exact equality and adjacent instants.
- Postconditions: Every auth path resolves boundary requests the same way. The chosen equality semantics are captured in tests so future changes do not reintroduce an ambiguous window.
- Risks / assumptions: The blueprint requires determinism but does not specify whether equality should accept or reject. The design says use a single canonical comparison, so implementation must make the equality rule explicit and consistent. This is not a blocker because the design allows either outcome if it is canonical and tested.

### Research questions
- RQ1: Where should the single canonical grace-expiry comparison be defined so auth, lazy expiry, and background revocation share it?
- RQ2: Does the codebase already have conventions for inclusive or exclusive expiry comparisons?
- RQ3: What test utilities can set the request time exactly to grace_expires_at and immediately before or after it?
- RQ4: How should the chosen boundary semantics be documented in tests or local comments without duplicating logic?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S9 - Admin rotates again while grace is active
- Order: 9
- Type: corner_case
- Status: planned
- Design references: Concurrency; Validity model; Accepted compromises

### Gherkin
Given a workspace admin has rotated the workspace API key
And the previous old key is superseded and still within its grace period
And the previously new key is the current key
When the admin rotates the workspace API key again before the grace period ends
Then a new current key is generated
And the previously current key becomes the only superseded key with a fresh 24-hour grace period
And the prior superseded key is revoked immediately
And the workspace never has more than one current key and one superseded key valid at the same time

### Code-blind plan
- Preconditions: S1 supports rotation from a single current key. S5 and S7 define revoked state behavior. The system can execute the second rotation as a transaction over the existing current and superseded records.
- Required capabilities: Rotation logic that detects an active superseded key; immediate revocation of the prior superseded key during the same transaction that creates the new current key; transition of the previous current key into a new superseded record with a fresh grace expiry; concurrency guard so simultaneous rotations cannot create more than one superseded key; UI refresh that clearly reflects the newest current key and newest grace window.
- Postconditions: The later rotation wins. The oldest key is revoked immediately. The middle key is valid only as the superseded key during its fresh grace period. The newest key is current. The at-most-two-active-keys constraint is preserved.
- Risks / assumptions: This scenario is sensitive to transaction boundaries and concurrent user actions. Research must identify the strongest available lock or transaction pattern and any existing retry behavior for conflicting mutations.

### Research questions
- RQ1: Where should rotation logic determine whether an active superseded key already exists?
- RQ2: What transaction, row lock, optimistic concurrency, or unique constraint pattern can guarantee only one current and one superseded key after concurrent rotations?
- RQ3: How should the previous superseded key be marked revoked during the same rotation transaction?
- RQ4: How should the new grace_expires_at be computed for the previously current key on the second rotation?
- RQ5: What tests can simulate two rotations in sequence and, if feasible, concurrent rotations?
- RQ6: How should the API Keys page refresh after a second rotation so it does not keep showing stale old-key status?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.

## Scenario S10 - Revoked and unknown keys are rejected without existence disclosure
- Order: 10
- Type: corner_case
- Status: planned
- Design references: Rejection; Validity model; Storage

### Gherkin
Given a workspace API key has been revoked through early revoke, grace expiry, or a later rotation
When a request is sent with that revoked key
Then the request is rejected
And the rejection response does not reveal whether the key ever existed
When a request is sent with an unknown key
Then the request is rejected with the same generic response shape

### Code-blind plan
- Preconditions: Revoked states can arise from S5, S7, and S9. The auth path can distinguish valid current or superseded-within-grace keys from revoked and unknown keys internally.
- Required capabilities: Generic auth rejection response shared by revoked and unknown keys; internal validity handling that rejects revoked records; no externally visible difference in status details, error body, timing-sensitive messaging, logs exposed to callers, or headers that could reveal key existence; tests comparing revoked-key and unknown-key rejection behavior; preservation of internal observability without leaking existence to the requester.
- Postconditions: Revoked keys cannot authenticate. Unknown keys cannot authenticate. Callers cannot use the rejection response to learn whether a presented key was previously valid.
- Risks / assumptions: Exact timing equivalence may not be practical, but visible protocol-level differences must be eliminated. Research must determine the existing generic unauthorized response for API key auth failures and whether logs or audit events are caller-visible.

### Research questions
- RQ1: What response is currently returned for invalid or unknown API key authentication failures?
- RQ2: Where should revoked-key rejection be routed so it shares the same external response as unknown-key rejection?
- RQ3: Are there caller-visible headers, error codes, messages, or metadata that differ across auth failure reasons today?
- RQ4: What internal logging or audit behavior is safe for revoked-key attempts without leaking existence to the requester?
- RQ5: What tests can assert that revoked and unknown key failures have the same externally visible response shape?

### Research findings
Pending kite-research.

### Implementation record
Pending kite-implementation.
