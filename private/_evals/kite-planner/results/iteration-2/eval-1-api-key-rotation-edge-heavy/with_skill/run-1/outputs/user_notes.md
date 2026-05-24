# User Notes

- The blueprint and system design require deterministic evaluation for requests exactly at grace_expires_at, but they do not state the exact inclusive or exclusive comparison in product language. The implementation plan keeps this as an explicit requirement: choose one canonical boundary rule before implementation and apply it consistently in auth, lazy expiry, background expiry, and tests.
