# Custom-domain finalization — does `finalize_domain()` fit how we build things?

Short answer: the *goal* is right, but the *shape* — one function that runs the DNS check, makes the GSC call, waits for the result, and flips the row to active all in one pass — does not fit how appsmith-v2 builds this kind of flow. It collapses a multi-step external workflow into a single blocking call, and that conflicts with two principles this part of the codebase is explicitly built around. The good news: the repo already has the pattern you need, and domain/GSC flows are even cited as the canonical example of it.

I checked this against the Kite Architecture Compass. The work spans three components: **Backend Services**, **Deployment & Domains**, and **Celery & Background Workers**.

## Why the single-function plan doesn't fit

### Principle 16 — Model long or external flows as resumable state machines

This is the decisive one. The principle states: multi-step work that crosses process boundaries or external services is *not* a single blocking call — it is an explicit sequence of states that commits each transition and can resume from where it stopped. And it names your exact flow as the example: *"Domain purchase (`pending → purchased → setup → active`), Search Console verification, and generation jobs all work this way. A crash mid-flow leaves a recoverable state, not a corrupt one."*

Your `finalize_domain()` holds DNS-check + GSC-call + wait + activation in one in-memory pass. If the process dies, gets redeployed, or the request times out anywhere in the middle, there is no committed intermediate state to resume from — the domain is left in an undefined limbo, and re-running the function starts over from scratch instead of picking up where it stopped. The repo's standard is that each transition is a committed state in the domain row, so a crash leaves a recoverable state, not a corrupt one.

The Component Map confirms this is non-negotiable for this area: both **Backend Services** and **Deployment & Domains** list Principle 16, with Deployment & Domains noting specifically "Domain purchase and GSC verification commit each transition and can resume."

### Principle 19 — Do slow and fallible work asynchronously, with backpressure

"Wait for it to come back" inside a service function means the request path blocks on an external provider. P19 says the request path stays fast; long-running or failure-prone work is pushed onto queues and workers — the user-facing request never blocks on work that can be deferred. GSC verification is both slow and fallible (it is exactly the kind of "external service" P19 and P16 are about). It belongs on Celery, with the route returning immediately and the client polling for status — which is also how the rest of Deployment & Domains already works (P19 there: "deploys run `--prod --no-wait`; side effects are tracked background tasks; clients poll for status").

### Principle 21 — Bound every retry; define terminal states

GSC verification doesn't always succeed, and "wait for the result" implies polling. The catalogue calls this out by name: *"Search Console stepped backoff into `retry_exhausted`"* and *"GSC stepped backoff into a terminal state."* Your plan has no terminal state for the case where GSC never verifies — it would either hang or fail in an undefined direction. The standard is a finite, backed-off retry that ends in an explicit terminal state (e.g. `retry_exhausted`), which is itself a defined outcome, not an error.

## Supporting principles to build to

- **P15 — Idempotency by design.** Whichever step kicks this off (DNS-propagation completion) and the GSC step itself can be redelivered or retried. Each must be safe to run twice: don't re-issue a GSC verification if one is already in flight or done, and make the activation transition a no-op if the row is already active. Celery & Background Workers lists P15 for exactly this reason.
- **P17 — Explicit transaction boundaries.** Each state transition is its own committed unit. The domain database module should `flush()` and leave the `commit()` to the caller (the service or task that owns the step). Don't bundle all transitions into one transaction — that defeats the resumability you're building.
- **P2 / P6 — Thin edges, single responsibility.** Keep the service functions scoped to one transition each. The Celery task is a thin wrapper that calls the service; the route just kicks off the flow and returns. No business logic in the route or the task body.
- **P20 — Choose fail-open vs fail-closed deliberately.** Decide explicitly what happens if GSC is unreachable. Flipping a domain to `active` is a correctness-sensitive change, so it should *not* fail open into "active anyway" — it should stay in its current state and retry. Make that decision explicit (a comment or the PR description), per the deviation/decision discipline.

## What to do instead

Replace the one blocking `finalize_domain(domain_id)` with a small resumable state machine over the domain row. Concretely:

1. **Define the states explicitly.** Extend the existing domain status progression with the steps this flow needs — e.g. `dns_verified → gsc_pending → gsc_verified → active`, plus a terminal `retry_exhausted` (reuse the existing domain status column / enum rather than inventing a parallel one — P5, single source of truth). Mirror the existing `pending → purchased → setup → active` style already in the repo.

2. **One service function per transition, each committing its own step.** Instead of one function that does everything:
   - a function that runs the DNS check and, on success, transitions the row to `dns_verified` (or kicks off the GSC step);
   - a function that issues the GSC verification call and transitions to `gsc_pending`;
   - a function that checks the GSC result and transitions to `gsc_verified`, or applies stepped backoff;
   - a function that performs the final activation, idempotently, transitioning to `active`.
   Each commits its transition before the next begins, so a crash leaves a recoverable state.

3. **Run the slow/fallible parts on Celery, not in the request path.** The DNS-propagation completion enqueues a task; the GSC verification poll runs as a Celery task with bounded, backed-off retries (`max_retries` / `retry_backoff`) terminating in `retry_exhausted`. The route that triggers this returns immediately; the client polls for status (consistent with how deploys already work here).

4. **Make every step idempotent.** Guard the GSC issue step against double-issuing; make the activation step a no-op when already `active`; use `acks_late`-safe task design so redelivery is harmless.

5. **Keep transaction ownership explicit.** Domain DB module functions `flush()`; the service/task that owns the step `commit()`s. Don't wrap the whole flow in one transaction.

This isn't more code for its own sake — it's the difference between a flow that survives a deploy or a GSC hiccup and one that strands customer domains in a broken state. And because GSC verification is already a named example of P16 and P21 in the contract, building it as a state machine keeps it consistent with the domain-purchase flow sitting right next to it.

## If you genuinely need to deviate

If there's a real constraint that makes the single-function approach necessary (I don't see one here — GSC is inherently async), the repo's rule is that the deviation must be explicit and justified: name the principle you're departing from (P16), state why, and record it where the next reader will see it — a comment, the PR description, or a decision record (P37). An undocumented deviation from P16 on a customer-facing domain flow would be flagged in review as a blocking issue, since it sits in the State & Correctness theme.

## One thing to confirm

I'm working from the architecture contract, not the live `domain` service code. Before you build, check the existing domain-purchase implementation (`pending → purchased → setup → active`) and any existing GSC verification code — they are the golden-path reference for the state-machine shape and the stepped-backoff terminal state. Match their conventions for status columns, task naming, and where commits happen rather than introducing a new pattern alongside them (P5, P8).
