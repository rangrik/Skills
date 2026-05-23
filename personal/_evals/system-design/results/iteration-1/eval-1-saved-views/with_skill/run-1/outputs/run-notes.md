# Run Notes — Saved Views System Design (Autonomous)

## Key autonomous decisions

1. **JSON column for config (D1):** No blueprint guidance on storage shape; chose jsonb over normalized rows per YAGNI and schema-flexibility rationale.
2. **Partial unique index for `is_default` (D3):** The blueprint's two-tab race scenario made DB-level enforcement the only safe choice; the partial index is the cleanest implementation.
3. **Service-layer authZ (D4):** Assumed no Pundit/CanCanCan exists; this is the highest-risk assumption.
4. **No server-side cache (§6):** Chose simplicity over performance optimization for a small, fast dataset.
5. **"Copy" name conflict:** Blueprint silent on fallback name; assumed "Copy of <name>" with counter.
6. **No pagination:** Assumed < 100 views per user per table; noted as compromise with revisit trigger.

## What I would have asked a human

- What is `table_id`? Is it a stable slug or a mutable name?
- Does the app already use Pundit or CanCanCan?
- What frontend state management approach is already in use (Redux, Zustand, component-local)?
- Is sharing always within one workspace, or can users share cross-workspace?
- What feature-flag mechanism does the app use?
