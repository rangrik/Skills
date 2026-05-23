# Gut-check: SitemapAgent shape

Short version: the *capability* is fine to want, but the *shape* you've drawn has two things that cut against how the Kite agentic system is built. Both are fixable, and the fix actually makes the feature smaller.

I checked this against the Kite Architecture Compass — specifically the **Specialised Agents**, **Skills**, and **Tools** components, and the agentic-system principles behind them.

## Problem 1 — SEO agent calling SitemapAgent directly breaks hub-and-spoke

This is the bigger one, and it's blocking-tier.

> **Principle 38 — Hub-and-spoke orchestration through a single mediator.** "One orchestrator agent owns the user conversation and is the only component that decides what happens next; specialised agents, routines, and services own implementation detail and never coordinate each other directly."

> **Principle 4 — Loose coupling.** For Specialised Agents specifically: "They communicate via tool results and persisted state, not direct calls. The orchestrator and its specialist agents never call each other directly."

Your plan has the SEO agent *deciding a sitemap is needed* and then *invoking SitemapAgent itself*. That makes the SEO agent a mini-orchestrator — a spoke coordinating another spoke. In this codebase the spokes are deliberately kept independent and replaceable precisely because they don't know about each other. The moment SEO holds a reference to SitemapAgent, you've created a coupling that the architecture spends real effort avoiding.

The correct shape: the SEO agent does not call anything. If, in the course of its work, it determines a sitemap is needed, that determination flows *back to the orchestrator* (via its tool result / persisted state), and the **orchestrator** decides to dispatch the sitemap work next. All coordination flows through the one hub. This keeps SEO and the sitemap capability independently testable and independently replaceable.

## Problem 2 — A whole new agent is probably the wrong layer for this

Before adding an agent at all, the catalogue says to start lower:

> **Principle 41 — Skill-first extension.** "New capability is added at the lowest-power layer that can carry it. Prefer extending or adding a skill (instructions and routing) before writing new code; move deterministic logic into services and tools; reserve agent/loop code for genuinely iterative work. The question for any new capability is 'can a skill do this?' before 'what code do I write?'."

Now look at what sitemap generation actually is. You described it as: crawl the app's known routes, format them into XML. That is **deterministic work** — there is a finite, knowable set of routes for a deployed app, and XML sitemap formatting is a fixed, spec-defined transformation. There is no genuine reasoning loop here; there's no iterative "try, observe, adjust" cycle that needs an LLM in the loop.

> **Principle 6 — Single responsibility** and the Tools entry: tools "validate input, delegate to one primary callee, translate the result," with "deterministic business logic in services, not in prompts or tools."

So the natural decomposition is:

- **A service** (Backend Services, Principle 2 — thick core) that owns the actual logic: enumerate the deployed app's routes and render the XML sitemap. This is plain deterministic code. It's unit-testable without an LLM.
- **A tool** that is a thin adapter over that service — validates input, calls the one service, returns the `ToolResult` / `ToolError` envelope (Principle 7).
- Optionally **a skill** if there's instruction/routing nuance about *when* a sitemap should be produced — but only if that judgment genuinely needs to live in an instruction bundle.

Putting the crawling and XML formatting "inside the new agent's reasoning loop" is the part to drop. A reasoning loop wrapped around deterministic work just makes the work slower, costlier (every loop step is context + tokens — Principle 39, context economy), and non-deterministic where it should be exact. An XML sitemap that's *almost* right because the model formatted it freehand is a defect; a service that emits it is correct every time.

A SitemapAgent would only be justified if producing the sitemap were genuinely open-ended and iterative — e.g. it had to discover routes by exploring an app it has no manifest for, reacting to what it finds. From your description that's not the case. If it later turns out to be, that's the moment to introduce the agent — not now (Principle 9, YAGNI — earn every abstraction).

## Recommended shape

1. **Sitemap-generation service** — deterministic route enumeration + XML rendering. Lives in `backend/app/services/`. The thick core.
2. **A thin tool** over that service, returning the standard `ToolResult` envelope.
3. **The orchestrator** decides when to invoke that tool — it is the only thing that decides "what happens next."
4. **The SEO agent** never calls the sitemap path. If SEO concludes a sitemap is warranted, that conclusion goes back to the orchestrator in its result, and the orchestrator dispatches the tool. No spoke-to-spoke call.
5. Add a **skill** only if there's real instructional nuance about *when/how* to produce a sitemap that's worth disclosing on demand.

This is strictly less code than your plan (no new agent, no new reasoning loop), it's deterministically testable, and it keeps SEO and the sitemap capability decoupled.

## If you still want an agent

If there's context I'm missing and the sitemap work really is iterative enough to need an agent, that's allowed — but it's a **deviation**, and the deviation rule applies: don't slip it in. Name what makes the work genuinely non-deterministic, write down why a service+tool can't carry it, and record that rationale in the PR description or a decision record (Principle 37). And even then, the hub-and-spoke point in Problem 1 still stands without exception — the orchestrator dispatches it, not the SEO agent.

## One caveat on coverage

The compass tells me clearly *where* this capability should live (service/tool, orchestrator-dispatched) and *what it must not do* (spoke-to-spoke calls). It does not contain a sitemap-specific or route-crawling-specific standard — there isn't an existing pattern in the catalogue for "how Kite enumerates a deployed app's routes." So treat the route-enumeration mechanics as a normal design decision within the service layer; the architecture just requires that it be a service, deterministic, and tested (Principle 34).
