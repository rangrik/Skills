# Profile: feature

**Accent:** `--accent:#5aa9ff; --accent-bg:rgba(90,169,255,.13);` (blue)
**Badge:** `✦ FEATURE`
**Sub-line:** one-line capability · `PR #… · branch …`

## What the reader wants
"What new capability is this, how does it flow, what are the pieces, and in what order do we build it?" Lead with the **capability**, not the code.

## Recommended structure (adapt to the issue)
1. **The capability** — one or two lines + the new user/data flow as a diagram (horizontal flow or sequence). Show the new path lighting up.
2. **Building blocks** — the components/files involved and how they connect (panels, a small architecture diagram, or a tree). Mark new vs reused via color.
3. **Key decisions** — if a real fork was chosen, a `.matrix` (options × criteria) with the pick highlighted; else `.callout`s.
4. **Build order** — `.steps`, mark `.done` as slices land.
5. **How it's tested** — `.checks` (Action → Expect); pass counts in `.stats`.

## Notes
- Blue = "new build". Keep the capability/flow as the hero; defer file-level detail.
