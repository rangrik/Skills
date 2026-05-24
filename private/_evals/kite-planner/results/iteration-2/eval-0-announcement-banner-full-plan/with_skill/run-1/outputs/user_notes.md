# User Notes

No blocking uncertainty prevented the implementation plan.

Non-blocking items to confirm before implementation:
- The blueprint says the banner has an optional link but does not specify link display text. The plan assumes the URL itself or a fixed label can be used unless product behavior adds a separate link-label field.
- The system design accepts no admin-publish idempotency key for the first implementation. If ambiguous publish retries need smoother UX, add idempotency-key support as a follow-up.
- The system design assumes existing feature-flag, UUID, workspace-admin authorization, and date/time conventions. The plan turns these into research questions rather than treating them as confirmed codebase facts.
