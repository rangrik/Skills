# Implementation Plan: Workspace API Key Rotation

## Feature
- Blueprint: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/api-key-rotation-blueprint.md
- System design: /Users/pranavkanade/Skills/private/_evals/kite-planner/suite/files/api-key-rotation-system-design.md
- Summary: Workspace admins can rotate a workspace API key without breaking live integrations. Rotation generates a new current key, exposes its full value exactly once, moves the prior key into a 24-hour superseded grace state, records successful superseded-key usage, and reliably revokes superseded keys at grace expiry or earlier admin action. Authentication must accept only the current key plus, during grace, one superseded key; revoked and unknown keys must be rejected with indistinguishable generic failures.

## Scenario order & status
| # | ID | Title | Type | Status | Ordering rationale |
|---|----|-------|------|--------|--------------------|
| 1 | S1 | Workspace admin views the API Keys page safely | happy_path | planned | Establishes the admin surface, masked-key display, and rotation entry point used by all admin actions. |
| 2 | S2 | Admin rotates the key and receives the new key exactly once | happy_path | planned | Creates the core state transition and one-time disclosure behavior that later auth, revoke, expiry, and second-rotation scenarios depend on. |
| 3 | S3 | Current and superseded keys authenticate during grace and superseded use is recorded | happy_path | planned | Builds on S2's current plus superseded state and proves both accepted-key auth paths before hardening expiry and revocation. |
| 4 | S4 | Admin revokes the old key before grace expiry | edge_case | planned | Uses the active superseded state from S2/S3 and introduces explicit admin revocation before generic rejected-key behavior is finalized. |
| 5 | S5 | Grace expiry revokes the old key reliably, including when it was never used | edge_case | planned | Extends the superseded lifecycle after the active-grace and early-revoke paths exist. |
| 6 | S6 | A request at the grace-period boundary is evaluated deterministically | edge_case | planned | Depends on the expiry model from S5 and isolates the boundary comparison so all enforcement paths agree. |
| 7 | S7 | Admin rotates again while a grace period is active | edge_case | planned | Builds on the first rotation lifecycle and verifies the transactional replacement rule that prevents more than two valid keys. |
| 8 | S8 | Non-admin users cannot rotate or revoke workspace keys | adversarial | planned | Hardens all mutation paths after their intended admin behavior has been defined. |
| 9 | S9 | Revoked and unknown keys are rejected without existence disclosure | adversarial | planned | Finalizes auth rejection after all ways a key can become revoked are represented. |

## Scenario S1 - Workspace admin views the API Keys page safely
- Order: 1
- Type: happy_path
- Status: planned
- Design references: Storage; Authorization; full key value exists only in the rotation response; keys are stored as salted hashes; rotate and revoke are admin-only.

### Gherkin
Given a workspace has an existing current API key
And the user is a workspace admin
When the admin opens the API Keys page in workspace settings
Then the page shows the key only as a masked prefix
And the page offers the admin a way to rotate the key
And the page does not expose any recoverable full API key value

### Code-blind plan
- Preconditions:
  - A workspace can have a current API key record represented without recoverable plaintext.
  - The user can be identified in the context of a workspace.
- Required capabilities:
  - A workspace settings API Keys surface that is available to workspace admins.
  - A way to read key metadata for the workspace without reading plaintext key material.
  - A stable masked-prefix representation that lets an admin identify a key without revealing the full key.
  - A rotate-key entry point that is visible or reachable for authorized workspace admins.
  - Server-side authorization for workspace-admin access to the key-management surface.
- Postconditions:
  - Workspace admins can find the rotation control from workspace settings.
  - Displayed key information is limited to non-secret metadata such as a masked prefix.
  - This scenario provides the UI and authorization foundation for rotate and revoke actions.
- Risks / assumptions:
  - The blueprint does not define a non-admin read experience for the page; the plan only requires admin access to the rotation surface.
  - The masked prefix must not be derived by fetching recoverable plaintext.

### Research questions
- RQ1: Is there an existing workspace settings surface or route where an API Keys page should be added or extended?
- RQ2: Is there an existing workspace-admin authorization helper for settings pages, and where should it be applied?
- RQ3: Is there an existing key metadata model or read API that can return a masked prefix without exposing plaintext?
- RQ4: Is there an existing masking convention for secrets or API keys that this feature should follow?
- RQ5: Is there an existing UI pattern for privileged settings actions such as key rotation?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S2 - Admin rotates the key and receives the new key exactly once
- Order: 2
- Type: happy_path
- Status: planned
- Design references: Storage; Validity model; Concurrency; Authorization; accepted compromise of at most two valid keys; full key value exists only in the response to the rotation request and is never persisted in recoverable form.

### Gherkin
Given a workspace admin is on the API Keys page
And the workspace has one current key
When the admin clicks Rotate key
Then a new API key is generated
And the full new key value is shown exactly once at creation time
And the old key becomes superseded with a grace period that expires 24 hours later
And after the creation response the new key is shown only as a masked prefix
And no recoverable full key value is persisted

### Code-blind plan
- Preconditions:
  - S1 is implemented so admins can reach the rotation action.
  - The workspace has a current key state that can be transitioned transactionally.
- Required capabilities:
  - A server-side rotate-key mutation restricted to workspace admins.
  - Secure generation of a new API key value.
  - Salted-hash persistence for the new key, with no recoverable plaintext storage.
  - A transactional state transition that makes the generated key current and makes the prior current key superseded.
  - A grace-period timestamp set to 24 hours after rotation for the superseded key.
  - A one-time response path that returns the full generated key value only in the rotation response.
  - A post-rotation display path that uses masked metadata rather than full plaintext.
- Postconditions:
  - The workspace has a new current key and one superseded key with a 24-hour grace expiry.
  - The admin has exactly one opportunity to copy the full new key value.
  - Refreshing or reopening the API Keys page can no longer reveal the full new key value.
- Risks / assumptions:
  - The design requires plaintext to exist only during the rotation response; logs, analytics, client persistence, and error reporting must not capture the full key.
  - The plan assumes a 24-hour grace period is fixed by this feature rather than configurable.
  - Transactional rotation must preserve the out-of-scope constraint that more than two keys are never valid at once.

### Research questions
- RQ1: Is there an existing mutation pattern for workspace-admin settings actions, and where should the rotate-key mutation fit?
- RQ2: Is there an existing secure token or API key generation utility suitable for workspace API keys?
- RQ3: Is there an existing salted-hash storage pattern for secrets that should be reused?
- RQ4: Is there an existing transaction mechanism for workspace state transitions that should guard rotation?
- RQ5: Is there an existing convention for computing and storing a 24-hour expiry timestamp from a server-side canonical clock?
- RQ6: Is there an existing one-time secret disclosure UI or API response pattern that prevents later retrieval?
- RQ7: Is there an existing logging, telemetry, or error-scrubbing convention for preventing secret values from being recorded?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S3 - Current and superseded keys authenticate during grace and superseded use is recorded
- Order: 3
- Type: happy_path
- Status: planned
- Design references: Validity model; Usage recording; Quality expectations; auth resolves a presented key to a key record and checks current, superseded within grace, or revoked; each successful auth with a superseded key writes a lightweight usage event; key lookup is a single indexed hash lookup.

### Gherkin
Given a workspace has a current key
And the workspace has a superseded key whose grace period has not expired
When an API request authenticates with the current key
Then the request is accepted
When an API request authenticates with the superseded key during grace
Then the request is accepted
And a lightweight superseded-key usage event is recorded
And the admin can see whether the old key is still being used

### Code-blind plan
- Preconditions:
  - S2 is implemented so rotation creates a current key and a superseded key with a grace expiry.
  - Requests can present workspace API keys for authentication.
- Required capabilities:
  - API key authentication that resolves a presented key by salted hash.
  - Validity evaluation that accepts current keys.
  - Validity evaluation that accepts superseded keys only while they are within their grace period.
  - A usage-event write for each successful superseded-key authentication.
  - An admin-visible usage summary or event surface showing whether old-key traffic still exists.
  - Auth performance that preserves the single indexed hash lookup expectation.
- Postconditions:
  - Integrations using either the new current key or the old superseded key continue working during grace.
  - Admins have evidence of superseded-key use during the grace period.
  - Usage recording happens only for successful superseded-key auth, not for current-key auth.
- Risks / assumptions:
  - Usage recording must be lightweight enough not to regress auth latency.
  - The blueprint requires visibility into whether anything is still using the old key but does not specify aggregation granularity; the implementation should choose the smallest useful representation consistent with existing product patterns.
  - Usage events must not include full API key values.

### Research questions
- RQ1: Is there an existing API key authentication flow that resolves presented keys by hash?
- RQ2: Is there an existing indexed lookup or schema pattern that can satisfy the single-lookup auth expectation?
- RQ3: Where should validity-state evaluation for current, superseded-within-grace, and revoked keys live?
- RQ4: Is there an existing event or audit model suitable for lightweight superseded-key usage records?
- RQ5: Is there an existing admin UI pattern for displaying recent usage or status signals on settings pages?
- RQ6: Is there an existing performance test or benchmark coverage for API key authentication latency?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S4 - Admin revokes the old key before grace expiry
- Order: 4
- Type: edge_case
- Status: planned
- Design references: Validity model; Authorization; Rejection; admin can end the grace period early; rotate and revoke are admin-only; revoked or unknown keys receive identical generic rejection.

### Gherkin
Given a workspace admin has rotated a key
And the old key is superseded and still within its grace period
When the admin clicks Revoke old key now
Then the old key is revoked immediately
And the current key remains valid
And subsequent requests with the old key are not accepted

### Code-blind plan
- Preconditions:
  - S2 is implemented so an active superseded key can exist.
  - S3 is implemented so superseded keys are accepted during grace before explicit revocation.
- Required capabilities:
  - An admin-only revoke-old-key action available when a superseded key is in grace.
  - A transactional update that changes only the active superseded key to revoked.
  - A post-revoke key-management state that no longer presents the old key as grace-valid.
  - Auth validity evaluation that stops accepting the revoked key immediately.
  - A user-facing result for successful revocation that confirms the old key is no longer valid without exposing key material.
- Postconditions:
  - Early revocation closes the grace period for the superseded key.
  - The workspace retains exactly one valid key: the current key.
  - Any later old-key request proceeds through the generic rejected-key path planned in S9.
- Risks / assumptions:
  - The blueprint does not define behavior when an admin clicks revoke and there is no active superseded key; research should determine whether existing product patterns prefer a disabled action, idempotent success, or a user-visible no-op.
  - Revocation must be immediate across all auth enforcement paths, not just reflected in the settings UI.

### Research questions
- RQ1: Is there an existing mutation pattern for admin-only destructive settings actions?
- RQ2: Is there an existing transactional update mechanism suitable for revoking only the active superseded key?
- RQ3: Is there an existing settings UI pattern for actions that are available only in certain resource states?
- RQ4: Where should API key auth read revoked state so early revocation takes effect immediately?
- RQ5: Is there an existing product convention for no-op or unavailable destructive actions when the target state no longer exists?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S5 - Grace expiry revokes the old key reliably, including when it was never used
- Order: 5
- Type: edge_case
- Status: planned
- Design references: Validity model; Quality expectations; background job and lazy auth-time check enforce revocation once the grace window closes; revocation at grace expiry must be reliable even if the background job is late.

### Gherkin
Given a workspace has a current key
And the workspace has a superseded key whose 24-hour grace period has ended
And no integration has used the superseded key during the grace period
When grace expiry enforcement runs
Then the superseded key is revoked normally
And only the current key remains valid
And requests with the old key are not accepted

### Code-blind plan
- Preconditions:
  - S2 is implemented so superseded keys have grace expiry timestamps.
  - S3 is implemented so superseded-key usage can be absent or present without changing the expiry rule.
- Required capabilities:
  - A background expiry job that finds superseded keys whose grace period has closed and revokes them.
  - A lazy auth-time expiry check that rejects and/or revokes expired superseded keys even if the background job is late.
  - Expiry logic that is independent of whether any superseded-key usage events exist.
  - Settings-page state that reflects when no old key remains valid after expiry.
  - Auth validity evaluation that accepts only the current key once the grace period is over.
- Postconditions:
  - Superseded keys are revoked after grace expiry whether or not integrations used them.
  - Timer delays do not extend old-key validity beyond the canonical expiry rule.
  - The workspace returns to a single-valid-key state after expiry.
- Risks / assumptions:
  - The background job and lazy auth-time check must share the same validity rule to avoid inconsistent outcomes.
  - Expiry enforcement must be safe to run repeatedly.
  - The system design requires reliability if the background job is late; implementation cannot depend solely on scheduled execution.

### Research questions
- RQ1: Is there an existing background job framework for periodic workspace maintenance tasks?
- RQ2: Is there an existing auth-time hook where lazy expiry can be enforced before accepting a superseded key?
- RQ3: Is there an existing shared time or clock abstraction that should provide canonical grace-expiry comparisons?
- RQ4: Is there an existing idempotent state-transition pattern for scheduled revocations?
- RQ5: Is there an existing settings-state representation for showing that no old key is currently in grace?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S6 - A request at the grace-period boundary is evaluated deterministically
- Order: 6
- Type: edge_case
- Status: planned
- Design references: Validity model; Quality expectations; the boundary is evaluated with a single canonical comparison against grace_expires_at so there is no ambiguous window; revocation at grace expiry must be reliable even if the background job is late.

### Gherkin
Given a workspace has a superseded key
And the request authentication time is exactly at the key's grace-period boundary
When an API request authenticates with the superseded key
Then the request outcome is determined by one canonical grace-expiry comparison
And every enforcement path produces the same accept-or-reject result for that boundary instant
And no ambiguous window allows different outcomes for the same boundary condition

### Code-blind plan
- Preconditions:
  - S5 is implemented so grace expiry is enforced by both background and lazy auth-time paths.
  - The feature has a canonical server-side clock source for auth-time evaluation.
- Required capabilities:
  - A single shared boundary comparison rule for superseded-key validity at grace_expires_at.
  - Consistent use of that comparison in auth, lazy expiry, and background expiry.
  - Boundary-focused tests or scenario checks that exercise the exact grace_expires_at instant.
  - Observability or diagnostics sufficient to investigate boundary decisions without exposing secret key material.
- Postconditions:
  - Requests at the exact boundary have deterministic outcomes.
  - Background expiry and auth-time expiry cannot disagree about whether the old key is valid at the boundary.
  - The selected comparison rule is documented in feature behavior or tests so future changes do not reintroduce ambiguity.
- Risks / assumptions:
  - The blueprint and system design require a deterministic canonical comparison but do not name the exact inclusive or exclusive operator in product language; implementation must make that rule explicit before or during build and apply it everywhere.
  - Distributed clock skew must not allow clients to choose the boundary time; server-side time is the source of truth.

### Research questions
- RQ1: Is there an existing shared place where API key validity rules can be centralized so the boundary comparison is not duplicated?
- RQ2: Is there an existing server-side clock abstraction used in auth and jobs?
- RQ3: Is there an existing test pattern for exact timestamp-boundary behavior?
- RQ4: Is there an existing logging or diagnostic convention for auth decisions that avoids leaking key existence or key values?
- RQ5: Where should the selected inclusive or exclusive grace-expiry rule be documented so auth, jobs, and tests share it?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S7 - Admin rotates again while a grace period is active
- Order: 7
- Type: edge_case
- Status: planned
- Design references: Concurrency; Validity model; accepted compromise of at most two valid keys; rotating during active grace immediately revokes the prior superseded key, makes the previously-new key the new superseded key, and gives it a fresh grace period; later rotation wins under concurrent rotations.

### Gherkin
Given a workspace has a current key
And the workspace has a superseded key whose grace period is still active
When a workspace admin rotates the key again
Then a new current key is generated and shown exactly once
And the previously current key becomes superseded with a fresh 24-hour grace period
And the previous superseded key is revoked immediately
And no more than two keys are valid after the rotation

### Code-blind plan
- Preconditions:
  - S2 is implemented for the basic rotate transition.
  - S3 is implemented so active grace is a meaningful state.
  - S4 and S5 establish revoked behavior for keys that leave grace.
- Required capabilities:
  - Rotation logic that detects an existing active superseded key.
  - A transactional state transition that revokes the prior superseded key, moves the prior current key to superseded, creates the new current key, and assigns a fresh 24-hour grace expiry.
  - Concurrency guarding so simultaneous rotations cannot leave multiple superseded keys valid.
  - A deterministic later-rotation-wins outcome for overlapping rotations.
  - Settings-page state that shows only the newest current key and the one active superseded key after the second rotation.
  - Auth validity evaluation that rejects the immediately revoked prior superseded key and accepts the newly superseded key during its fresh grace period.
- Postconditions:
  - The workspace never has more than one current key and one superseded key valid at the same time.
  - The key that was superseded before the second rotation is no longer valid.
  - The key that was current immediately before the second rotation now has its own fresh grace period.
- Risks / assumptions:
  - This is the highest-risk state transition because it combines generation, one-time disclosure, revocation, and grace-period replacement.
  - Usage history for the previously superseded key may remain visible as history, but it must not imply continued validity.
  - Concurrency handling must preserve the one-time disclosure guarantee for whichever rotation result is committed.

### Research questions
- RQ1: Is there an existing transaction or locking mechanism that can guard multi-record workspace key transitions?
- RQ2: Is there an existing uniqueness or invariant mechanism that can enforce at most one current key and at most one active superseded key per workspace?
- RQ3: Where should later-rotation-wins behavior be implemented for overlapping rotate requests?
- RQ4: Is there an existing way to revoke a superseded key as part of a larger transaction?
- RQ5: Is there an existing settings display model that can distinguish current, active superseded, and historical revoked keys?
- RQ6: Is there an existing test pattern for concurrent mutations against the same workspace resource?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S8 - Non-admin users cannot rotate or revoke workspace keys
- Order: 8
- Type: adversarial
- Status: planned
- Design references: Authorization; rotate and revoke are admin-only, enforced server-side on every path.

### Gherkin
Given a user is not a workspace admin
When the user attempts to rotate the workspace API key
Then the rotation is denied server-side
And no new key value is generated or disclosed
And the workspace key state does not change
When the user attempts to revoke an old key
Then the revoke action is denied server-side
And the workspace key state does not change

### Code-blind plan
- Preconditions:
  - S2 implements rotate behavior for admins.
  - S4 implements revoke behavior for admins.
- Required capabilities:
  - Server-side workspace-admin authorization on every rotate path.
  - Server-side workspace-admin authorization on every revoke path.
  - UI behavior that prevents or handles non-admin attempts without relying on client-only enforcement.
  - A denial response that does not disclose secret key material.
  - Mutation guards that prevent unauthorized attempts from changing key state or creating usage events.
- Postconditions:
  - Non-admin users cannot rotate keys, receive newly generated key material, or revoke old keys.
  - Server-side enforcement remains correct even if a non-admin bypasses or manipulates the client UI.
  - Authorized admin behavior from earlier scenarios is unchanged.
- Risks / assumptions:
  - Authorization must be checked at mutation time, not inferred from page visibility.
  - Denied rotate attempts must not generate a key before authorization completes.

### Research questions
- RQ1: Is there an existing workspace-admin authorization helper for server mutations?
- RQ2: Is there an existing authorization middleware or guard that applies to settings mutations?
- RQ3: Is there an existing client-side pattern for hiding, disabling, or erroring privileged settings controls for non-admins?
- RQ4: Is there an existing test pattern for proving unauthorized mutations leave persisted state unchanged?
- RQ5: Is there an existing response convention for authorization denial on settings actions?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.

## Scenario S9 - Revoked and unknown keys are rejected without existence disclosure
- Order: 9
- Type: adversarial
- Status: planned
- Design references: Rejection; Validity model; Storage; revoked or unknown key yields an identical generic rejection; a request bearing a revoked key must be rejected, and the rejection must not reveal whether the key ever existed.

### Gherkin
Given an API request presents a key that is revoked
When authentication evaluates the request
Then the request is rejected
And the rejection does not reveal whether the key ever existed
Given an API request presents a key that is unknown
When authentication evaluates the request
Then the request is rejected with the same generic externally visible result

### Code-blind plan
- Preconditions:
  - S4, S5, and S7 are implemented so keys can become revoked through early revoke, grace expiry, or a second rotation.
  - S3 is implemented so auth can resolve current and superseded keys.
- Required capabilities:
  - Auth validity evaluation that rejects revoked keys.
  - Auth handling that rejects unknown keys.
  - A uniform externally visible rejection result for revoked and unknown keys.
  - Secret-safe logging and observability that may support operations without disclosing key existence to callers.
  - Usage recording rules that do not record rejected revoked-key or unknown-key attempts as successful superseded-key usage.
  - Tests or scenario checks that compare rejected-key responses across revoked and unknown inputs.
- Postconditions:
  - Revoked keys from any revocation path are unusable.
  - Attackers cannot distinguish revoked historical keys from keys that never existed based on the rejection.
  - Old-key usage visibility remains limited to successful superseded-key requests during grace.
- Risks / assumptions:
  - Timing, error body, headers, and status should all be considered part of the externally visible rejection behavior if they could reveal key existence.
  - Internal logs may distinguish cases for operations only if they are not exposed to callers and do not store full key values.

### Research questions
- RQ1: Is there an existing generic authentication failure response for invalid API keys?
- RQ2: Where should revoked-key and unknown-key rejection converge so callers receive the same externally visible result?
- RQ3: Is there an existing test helper for comparing authentication failure response shapes?
- RQ4: Is there an existing logging policy for invalid secret or API key attempts?
- RQ5: Is there an existing usage-recording path that must be constrained to successful superseded-key authentication only?

### Research findings
- Pending kite-research.

### Implementation record
- Pending kite-implementation.
