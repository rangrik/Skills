# User Notes

The implementation plan is code-blind and is based only on the provided blueprint and system design document.

Items to confirm before or during research:

- The blueprint says the "most recent publish wins" when admins overlap, while the system design says a concurrent publish may surface a 409 to the losing admin. The plan keeps a dedicated concurrency scenario and asks research/design follow-up to confirm the exact admin UX.
- The blueprint mentions an optional link but does not specify link display text. The design suggests either showing the URL itself or a fixed label. Product should confirm whether a separate link-label field is needed.
- The design assumes 30-second polling satisfies "within a short time." If a tighter user-visible latency is required, the polling decision should be revisited.
- The design flags admin publish idempotency as a follow-up rather than a required first implementation. Research should check whether the codebase already has an idempotency mechanism that would make this cheap to include.
