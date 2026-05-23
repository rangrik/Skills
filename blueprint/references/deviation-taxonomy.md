# Deviation Taxonomy

This is the engine of the skill. It turns "think of edge cases" — open-ended, tiring,
and never provably complete — into a finite checklist you can work cell by cell.

## How to use this file

After the happy path is confirmed, build a **traversal matrix**: every atomic step of
every happy path down one axis, every category below across the other. Visit each cell
and ask: *can this deviation happen at this step?* When it can, write a Gherkin scenario
whose `Then` steps specify the graceful product behavior.

Some categories are step-level (they happen *at* a step) and some are flow-level (they
happen *across* the whole interaction). Each category is marked. Flow-level categories
are applied once to the flow as a whole rather than to every step.

Every category must finish with either a scenario or a justified "not applicable" entry
in the coverage checklist. An honest N/A is fine; a silent omission is the failure this
skill exists to prevent.

## Graceful-behavior principles

These cross-cutting principles tell you what *should* happen. Every deviation scenario's
`Then` steps should be an application of one or more of them. They are why a resolution
counts as "graceful" rather than merely "handled."

1. **Preserve the user's work.** Never silently discard input. A half-filled form, a
   draft, an in-progress upload — keep it, restore it, or warn clearly before it is lost.
   Losing work a user spent effort on is the fastest way to feel broken.

2. **Make repeated actions idempotent.** Retrying or double-submitting an action that
   already succeeded should land the user in the *same* good state — not create a
   duplicate, not double-charge, not error out confusingly. The safe mental model: a
   completed action, repeated, is a no-op that still shows success.

3. **Communicate honestly and specifically.** An error message should say what happened,
   in the user's terms, and what to do next. "Something went wrong" and "Error 500" are
   not acceptable resolutions. Never display success when something failed, and never
   hide a failure the user needs to know about.

4. **Keep the system in a safe, consistent state.** A flow interrupted halfway should
   leave data either fully applied or fully not applied — never half-applied. No orphaned
   records, no partial writes the user can't see, no state only the database knows about.

5. **Always offer a way forward.** Every dead end needs a recovery action: retry, go
   back, edit and resubmit, save and resume later, request access, or contact support.
   A deviation scenario that ends with the user stuck is not finished.

6. **Fail safe and least-surprise.** When the right behavior is unclear, choose the
   option that does the least irreversible damage and best matches what a reasonable user
   would expect. Destructive or costly actions deserve confirmation; reversible ones
   should not nag.

7. **Explain limits, don't just enforce them.** Rate limits, quotas, permission
   boundaries, and expiries should tell the user *why* they hit the wall and give a path
   through it where one exists — how long to wait, how to upgrade, how to request access.

---

## The categories

### 1. Incomplete or invalid input — *step-level*

The user submits a step with data that is missing, malformed, out of range, or the wrong
type. The classic case: a half-filled form gets submitted.

**Detect it — ask at each step that accepts input:** What if a required field is blank?
What if the format is wrong (a malformed email, letters in a number field)? What if a
value is out of range (a negative quantity, a date in the past)? What if the input is
technically valid but nonsensical for this context?

**Graceful pattern:** Validate before committing. Block the submission, keep everything
the user already entered (principle 1), and point to the specific field with a specific,
plain-language reason. Where possible, validate inline as they go rather than only on
submit. Never lose the rest of the form to fix one field.

```gherkin
Scenario: Submitting the form with a required field empty
  Given the user has filled every field except "Email"
  When the user submits the form
  Then the form is not submitted
  And the "Email" field is highlighted with the message "Enter your email address"
  And every other value the user entered remains in place
```

### 2. Duplicate submission or retry of a completed action — *step-level*

The user repeats an action that already succeeded — a double-click, an impatient second
click on a slow button, a browser refresh on a POSTed page, a retry after a success
message they did not see.

**Detect it — ask at each step that changes state:** What if the user clicks twice? What
if they refresh after submitting? What if they navigate back and resubmit? What if a
slow response makes them think it failed and they retry?

**Graceful pattern:** Idempotency (principle 2). The action should be safe to repeat:
disable or show progress on the control while in flight, de-duplicate on the server with
an idempotency key, and on a repeat show the *same* success outcome rather than an error
or a duplicate. Money and irreversible effects make this critical.

```gherkin
Scenario: Clicking submit twice on a slow connection
  Given the user has submitted the form and the request is still in flight
  When the user clicks "Submit" a second time
  Then no second submission is created
  And the user sees a single success confirmation once the request completes
```

### 3. Rate limits, quotas, and throttling — *step- or flow-level*

The user performs an action so often, or accumulates so much, that they cross a limit —
and then keeps going.

**Detect it — ask:** Is there a per-minute or per-hour cap on this action? A total quota
(storage, seats, API calls, items)? What happens on the request that crosses the line —
and on the ten requests after that?

**Graceful pattern:** Principle 7. State the limit, why it exists, and the path through:
the wait time before they can retry, or how to raise the quota (upgrade, request more).
Keep already-accepted work intact. Never fail silently and never let the user keep
hammering with no feedback.

```gherkin
Scenario: Exceeding the hourly send limit
  Given the user has reached the limit of 50 invites per hour
  When the user sends another invite
  Then the invite is not sent
  And the user sees "You've hit the hourly invite limit. You can send more in 24 minutes."
  And invites already sent this hour remain valid
```

### 4. Connectivity loss and interruption — *flow-level*

The network drops, a request times out, or the tab/app is closed mid-flow.

**Detect it — ask:** What if connectivity drops between a user action and the system's
response? What if a long-running operation is interrupted partway? What if the user
closes the tab mid-submission?

**Graceful pattern:** Principles 1 and 4. The user's in-progress input is preserved
(locally if needed) so a reconnect resumes rather than restarts. A partially-applied
operation either completes or rolls back cleanly — never half-done. On reconnect, tell
the user the current true state plainly; do not leave them guessing whether it worked.

```gherkin
Scenario: Losing connectivity while submitting
  Given the user submits the form
  And the network connection drops before a response is received
  When connectivity is restored
  Then the user is told the submission did not complete
  And all entered data is still present so the user can retry
  And no partial record was created on the server
```

### 5. Abandonment and resumption — *flow-level*

The user leaves the flow unfinished and comes back — minutes later in the same session,
or days later in a new one.

**Detect it — ask:** What if the user gets halfway and walks away? What do they see on
return? Is partial progress saved? Does it expire? What if they return on a different
device?

**Graceful pattern:** Principle 1. Decide explicitly whether progress is saved as a draft
or discarded — and if discarded, warn before it happens. On return, restore them to where
they left off, or clearly explain that the flow restarts and why. Stale partial state
should expire on a defined, stated timeline rather than lingering forever.

```gherkin
Scenario: Returning to an unfinished flow the next day
  Given the user left the flow after completing 2 of 4 steps
  When the user returns the following day
  Then the user resumes at step 3 with the earlier steps still filled in
  And the user is shown when the saved progress will expire
```

### 6. Out-of-order actions and navigation — *step-level*

The user does steps in an unintended sequence: skips ahead, jumps back, uses the browser
Back button, deep-links into the middle of a flow, or triggers a later action before an
earlier one is done.

**Detect it — ask:** What if the user reaches this step without completing the prior one?
What if they go back and change an earlier step after a later one depended on it? What if
they deep-link straight to the middle?

**Graceful pattern:** Principle 6. Guard each step's real preconditions and, if they are
unmet, route the user to what they need first with an explanation — do not show a broken
or empty screen. If an earlier change invalidates later work, say so and let them
reconcile it. Back navigation should be predictable, never destructive without warning.

```gherkin
Scenario: Deep-linking into a later step without completing the first
  Given the user has not completed step 1
  When the user opens the URL for step 3 directly
  Then the user is redirected to step 1
  And the user is told the earlier steps must be completed first
```

### 7. Authentication and permission changes mid-flow — *flow-level*

The user's session expires, they get logged out, or their permissions change while they
are partway through.

**Detect it — ask:** What if the session times out between steps? What if the user is
logged out in another tab? What if an admin revokes their access, or their role changes,
mid-flow? What if they were never authorized for this in the first place?

**Graceful pattern:** Principles 1 and 5. On a session expiry, preserve the in-progress
work, prompt re-authentication, and return the user exactly where they were — do not dump
them on a blank login page and lose everything. If permission is genuinely gone, explain
it and offer the recovery path (request access, contact an admin) rather than a bare
"Forbidden."

```gherkin
Scenario: Session expires partway through the flow
  Given the user's session expires after completing step 2
  When the user attempts step 3
  Then the user is prompted to sign in again
  And after signing in, the user returns to step 3 with prior input intact
```

### 8. Concurrency and stale data — *flow-level*

The same user acts in two tabs, two users act on the same object, or the user acts on
data that changed since it loaded.

**Detect it — ask:** What if the user has this open in two tabs? What if someone else
edits the same record at the same time? What if the data on screen is stale by the time
the user acts on it? What if two requests race?

**Graceful pattern:** Principles 3 and 4. Detect the conflict (version checks, optimistic
concurrency) rather than letting a last-write silently clobber the other. Tell the user
their copy is stale, show what changed, and let them merge or re-decide. Never destroy
someone's work to a conflict they were never told about.

```gherkin
Scenario: Saving a record edited by someone else in the meantime
  Given the user opened the record for editing
  And another user saved a change to the same record afterward
  When the user saves their edits
  Then the user is warned the record changed since they opened it
  And the user is shown the conflicting changes and can choose how to resolve them
  And neither version is discarded without the user's choice
```

### 9. Precondition already satisfied / state conflict — *step-level*

The user tries to reach a state the system is already in, or that conflicts with the
current state: inviting someone already a member, deleting something already deleted,
enabling what is already enabled, acting on a dependency that no longer exists.

**Detect it — ask:** What if the target state is already true? What if a thing this step
depends on was deleted or moved? What if this action contradicts the current state?

**Graceful pattern:** Principles 2 and 6. Treat "already done" as a benign success, not
an error — the user's goal is met. For genuine conflicts, explain the current state and
the safe options. Reference a missing dependency by what it was, and offer a way forward.

```gherkin
Scenario: Inviting a person who is already a member
  Given "sam@example.com" is already a member of the workspace
  When the user sends an invite to "sam@example.com"
  Then no duplicate invite is created
  And the user is told that person is already a member
```

### 10. Empty, boundary, and scale extremes — *step-level*

The data is at an extreme: zero items, exactly one, the maximum allowed, or far more than
expected. Also includes the very first run, before any data exists.

**Detect it — ask:** What does this step show with zero items? With one? At the maximum?
With a value far larger than designed for (a 10,000-row export, a 500-character name)?
What does a brand-new user with no history see?

**Graceful pattern:** Design the empty state deliberately — it is a real screen, often a
user's first impression, and should orient and guide rather than show a blank void. At
the upper bound, either handle the scale gracefully (paginate, stream, background the
job) or set and explain a clear limit. Singular/plural and layout should hold at every
size.

```gherkin
Scenario: Opening the page before any items exist
  Given the user has not created any items yet
  When the user opens the list
  Then the user sees an empty state explaining what items are and how to create the first one
  And no error or broken layout is shown
```

### 11. Environment and device capability — *flow-level*

The user's environment differs from the assumed one: a small screen, a touch device, an
unsupported or old browser, disabled JavaScript, assistive technology, a slow device.

**Detect it — ask:** Does this work on a narrow mobile screen? With touch instead of a
mouse? On an older or unsupported browser? With a screen reader and keyboard only? On a
slow device or connection?

**Graceful pattern:** Principle 6. The core flow should function across the realistic
range of environments, or detect an unsupported one early and say so plainly rather than
failing in a confusing way mid-flow. Keyboard and screen-reader access are part of the
flow working, not an extra.

```gherkin
Scenario: Completing the flow on a mobile screen
  Given the user opens the flow on a narrow mobile viewport
  When the user works through each step
  Then every control is reachable and usable without horizontal scrolling
  And the flow can be completed end to end
```

### 12. External dependency failure — *step-level*

A step relies on something outside the product — a payment processor, an email or SMS
provider, a third-party API, file storage, an auth provider — and it is slow, erroring,
or down.

**Detect it — ask:** Which steps depend on an external service? What if that service is
down, slow, rate-limiting us, or returns an error or a malformed response?

**Graceful pattern:** Principles 3, 4, and 5. Never present the external failure as the
user's fault or as a raw technical error. Keep the user's work, explain that something on
our side is delayed, and offer a retry or a "we'll notify you" path. The system stays
consistent — a failed charge must not yield a fulfilled order.

```gherkin
Scenario: The email provider is unavailable when sending the confirmation
  Given the user completes the action successfully
  And the email provider is unavailable
  Then the user's action is still recorded as complete
  And the confirmation email is queued for automatic retry
  And the user is told the email may be delayed, without a raw technical error
```

### 13. Time, expiry, and scheduling — *step- or flow-level*

Time-bound elements lapse or collide: an expiring link or token, a time-limited offer,
a flow that straddles midnight or a daylight-saving change, two scheduled actions
overlapping.

**Detect it — ask:** Does this step involve a link, token, code, or offer that can
expire? What if the user acts on it after expiry? What if the flow crosses a day boundary
or a timezone? What if scheduled actions overlap?

**Graceful pattern:** Principles 5 and 7. An expired item explains that it expired and
offers a fresh one in a click — never a dead end. Be explicit about which timezone and
clock govern, so "expires tomorrow" is unambiguous.

```gherkin
Scenario: Using a link after it has expired
  Given the user opens a link whose 24-hour validity window has passed
  When the page loads
  Then the user is told the link has expired
  And the user can request a new link from the same screen
```

### 14. Adversarial and abuse input — *step-level*

A user — or a bot — supplies hostile input or uses the feature in bad faith: injection
attempts, oversized payloads, automated scraping, enumeration of others' data, harassment
through a user-to-user channel.

**Detect it — ask:** Could input here be used for injection (script, SQL, HTML)? Could
this be automated to abuse the feature or enumerate data? Could a user-supplied value
reach another user and harm them?

**Graceful pattern:** Principles 3 and 6. Treat all input as untrusted: validate,
sanitize, and escape. Apply abuse controls (rate limits, captchas where warranted)
without punishing honest users. Do not leak through error messages whether an account or
record exists. This category often surfaces decisions a product owner must ratify, so
lean on `@assumption` tags here.

```gherkin
@assumption
Scenario: Submitting input containing a script payload
  # Assumption: all free-text input is sanitized server-side and escaped on render.
  Given the user enters a value containing an embedded script
  When the user submits the step
  Then the value is stored and later displayed as inert text
  And the script never executes for that user or any other user
```

---

## Quick coverage check

Before writing the spec, confirm each of the 14 categories has been deliberately
visited for the feature at hand:

1. Incomplete or invalid input
2. Duplicate submission / retry of a completed action
3. Rate limits, quotas, throttling
4. Connectivity loss and interruption
5. Abandonment and resumption
6. Out-of-order actions and navigation
7. Authentication and permission changes mid-flow
8. Concurrency and stale data
9. Precondition already satisfied / state conflict
10. Empty, boundary, and scale extremes
11. Environment and device capability
12. External dependency failure
13. Time, expiry, and scheduling
14. Adversarial and abuse input

Each becomes a row in the spec's coverage checklist — with scenarios, or with a stated
reason it does not apply.
