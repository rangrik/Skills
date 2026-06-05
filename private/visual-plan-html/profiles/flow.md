# Profile: new flow / design

**Accent:** `--accent:#a78bfa; --accent-bg:rgba(167,139,250,.15);` (violet)
**Badge:** `⇄ FLOW`
**Sub-line:** what the flow is · context

## What the reader wants
"How does this work end-to-end — the actors, the order, the branches?" The **diagram is the hero** here; text is captions.

## Recommended structure (adapt to the issue)
1. **The flow** — the main event. A large sequence / swimlane / state diagram, usually inline `<svg>` for crossing or curved edges. Give it room; it's the point of the page.
2. **Actors / components** — a short key of who's who (a compact panel row or tree).
3. **Branches & edge cases** — forks (`.split`) or a `.matrix` of "case → behavior".
4. **Open questions** — `.callout`s for anything undecided.

## Notes
- Violet = "design/architecture". Resist prose — if you're writing paragraphs, you're probably not diagramming what should be diagrammed.
- Reach for inline SVG early: real flows have back-edges, loops, and parallel paths the box-stack can't show.
