# User Notes

Non-blocking uncertainties captured in the implementation plan:

- The blueprint allows an optional link but does not specify whether the displayed link text is the URL itself, a fixed label, or a separate author-provided label. The plan does not add a separate label field.
- The blueprint says the most recent publish wins, while the system design also specifies a conflict response for truly simultaneous publish races. The plan treats replacement as the normal behavior and asks research to confirm the local conflict/stale-edit convention.
- The system design references feature flags, metrics, structured logging, and timeout/backoff conventions. The plan asks research to locate the existing mechanisms instead of assuming their implementation.
