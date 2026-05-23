# Finalizing custom domains: review of your `finalize_domain` plan

Short answer: the *goal* is right, but a single `finalize_domain(domain_id)` that runs the DNS check, calls Google Search Console (GSC), **waits** for the result, and then flips the row to active is the part I'd push back on. The "wait for it to come back" step is the problem. Below is why, and what I'd build instead.

## The core issue: you're describing a long-running, multi-party workflow as one synchronous function

Your function spans three things with very different timing and failure characteristics:

1. **DNS propagation check** — fast-ish, but eventually-consistent and can be flaky.
2. **GSC verification call** — an outbound call to a third party. Initiating verification is quick, but Google does its own asynchronous check on its side. It is *not* instant and it is *not* guaranteed.
3. **Flip domain to active** — a local DB write.

The phrase "wait for the result" means one of two implementations, and both are problematic:

- **Block the request thread** until GSC confirms. This ties up a worker for seconds-to-minutes, breaks if the caller is an HTTP request (timeouts, retries firing mid-flight), and gives the user no feedback while it hangs.
- **Sleep/poll in a loop** inside the function. Same thread-occupancy problem, plus you've now built an ad-hoc scheduler inside a service method.

Neither fits how a well-structured service codebase typically handles "do work, wait on an external system, then continue." That pattern wants to be **asynchronous and broken into stages**.

## How this kind of thing is usually built in a repo like this

I don't have your actual source, so treat this as the conventional shape — but in a platform codebase (Rails/Django/Node service, etc.) with custom-domain support, you almost certainly already have:

- A **background job / worker** system (Sidekiq, Celery, BullMQ, a queue, cron, etc.).
- A **domain state machine** — domains move through statuses like `pending` -> `dns_pending` -> `dns_verified` -> `gsc_pending` -> `active` (and failure states).
- Existing **callers** of whatever does the DNS check today.

So before writing anything, do this reconnaissance:

1. Find the domain model/entity and list its current status values and transitions. Is there an explicit state machine (e.g. `aasm`, `state_machine`, a status enum + guarded transitions)? Mirror it.
2. Find how DNS propagation is checked today and how it's triggered. There's probably already a job that polls DNS — `finalize_domain` should likely *hook into the existing flow*, not re-run the DNS check from scratch.
3. Find how other third-party verification or webhook-style flows are modeled. GSC verification almost certainly has a precedent (provisioning, certificate issuance, OAuth callbacks). Copy that pattern.
4. Check whether GSC notifies you back (callback/webhook) or whether you must poll. This single fact decides the design.

## Recommended design: stages, not one function

Model finalization as **distinct steps driven by background jobs and the domain's status column**, each step idempotent and re-runnable.

### Step 1 — DNS confirmed -> request GSC verification
When DNS propagation is confirmed (likely already detected by an existing job):
- Transition the domain to a `gsc_pending` (or similar) status.
- Enqueue a job that makes the GSC verification *request*. This step only *kicks off* verification; it does not wait for the answer.
- Persist any token/handle Google returns so later steps can correlate.

### Step 2 — Get the GSC result
Two cases:

- **If GSC can call you back** (webhook/callback): handle it in a controller/endpoint, look up the domain by the stored token, and transition it. Preferred — no polling.
- **If you must poll**: enqueue a *re-checking* job that asks GSC for the current verification status. If still pending, it re-enqueues itself with a delay and a bounded retry/attempt count (exponential backoff). This is the only correct way to "wait" — let the queue hold the wait, not a thread.

### Step 3 — Flip to active
Only when GSC reports success:
- Transition the domain to `active` through the state machine's guarded transition (so invalid transitions are rejected).
- Do any activation side effects (cache invalidation, routing/cert config, notifying the user).

A thin service function is still fine — e.g. `DomainFinalization.activate(domain)` — but it should be the *last* step, called once verification has already succeeded, not the thing that orchestrates the wait.

## Things to get right regardless of structure

- **Idempotency.** Jobs get retried. Running step 2 twice, or step 3 on an already-active domain, must be safe. Guard every transition on current status.
- **Bounded retries + a terminal failure state.** GSC verification *will* sometimes never succeed (user removed the DNS record, wrong property, etc.). Define `gsc_failed` / `dns_failed` states with a max attempt count, and surface the reason to the user instead of polling forever.
- **Don't re-run the DNS check inside finalization.** If an existing job already established DNS is propagated, trust that status and move on. Re-checking invites a race where DNS passed a moment ago but blips now.
- **Persist status transitions, not just the final value.** A `status` column plus timestamps (`dns_verified_at`, `gsc_verified_at`, `activated_at`) makes the flow debuggable and lets you build a status UI.
- **Use the state machine's guarded transitions** rather than `domain.update(status: "active")`. This prevents skipping steps and gives you a single place for transition callbacks.
- **Wrap external calls** (DNS resolver, GSC API) with timeouts and explicit error handling. Treat transient errors (retry) differently from permanent errors (move to failed state).
- **Concurrency.** Make sure two jobs can't finalize the same domain simultaneously — lock the row or rely on guarded status transitions as the serialization point.
- **Observability.** Log/emit metrics at each transition. "Stuck in `gsc_pending`" is a question you'll want to answer quickly.

## What I'd actually do next

1. Read the domain model and confirm the existing status values and transition mechanism.
2. Find the existing DNS-propagation job and the existing third-party-verification pattern; match them.
3. Determine whether GSC pushes a callback or requires polling.
4. Implement it as: a job to *request* GSC verification, a callback handler **or** a self-re-enqueuing poll job to *collect* the result, and a small `activate` step guarded by the state machine.
5. Add the `gsc_failed`/`dns_failed` terminal states and bounded retries.
6. Cover with tests: DNS-passed-but-GSC-fails, GSC-times-out, retried-job-runs-twice, and finalize-called-on-already-active.

## Bottom line

Keep the *intent* of `finalize_domain` — there's value in one named entry point — but don't let it be a synchronous function that blocks on Google. Split it into queue-driven stages tracked by the domain's status, make every stage idempotent, add explicit failure states, and let the job system own the "waiting" instead of a thread. Reuse the existing DNS-check and verification patterns in the repo rather than inventing a parallel one. Confirm the actual model, jobs, and GSC callback-vs-poll behavior before writing code — those details will shape the final structure.
