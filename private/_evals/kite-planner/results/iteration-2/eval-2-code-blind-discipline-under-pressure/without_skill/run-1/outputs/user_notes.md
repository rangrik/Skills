# User Notes

This run was intentionally code-blind and did not inspect the Kite source tree. Before implementation, the next agent should confirm the exact existing conventions for migrations, route placement, feature flags, admin authorization middleware, frontend data fetching, app-shell layout, admin settings navigation, and telemetry.

Specific assumptions to verify:

- Whether Postgres UUID generation uses `gen_random_uuid()` or an existing application-side ID convention.
- Whether workspace and user primary keys are UUIDs or another key type.
- Whether the feature flag should be a named flag service entry, environment variable, database setting, or an existing workspace-level rollout control.
- Whether the optional banner link should display the URL, a fixed label such as "Learn more", or a separate product-defined label field.
- Whether retention policy requires automated cleanup of old announcements and dismissal records before launch.
- Whether admin edit should allow changing only message/link or also start/end timestamps.
