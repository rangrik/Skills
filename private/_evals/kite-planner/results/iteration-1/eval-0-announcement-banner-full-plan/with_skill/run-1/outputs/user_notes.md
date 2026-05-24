# User Notes

- The blueprint says the banner has an optional link, but it does not specify link display text. The plan assumes the URL itself or a fixed label such as "Learn more" is acceptable unless product specifies a separate label field.
- The blueprint's "most recent publish wins" behavior is planned for sequential successful publishes. The system design handles truly simultaneous publish races by preserving one active banner and returning a conflict to any losing request.
- The system design assumes a feature flag mechanism, UUID-compatible persistence, and an existing workspace-admin authorization primitive. Research should confirm the exact local mechanisms before implementation.
- Retention cleanup, admin publish idempotency keys, and very-large-scale poll caching are treated as follow-ups unless research finds existing standards that make them cheap to include now.
