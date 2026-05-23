# Gut-check: SitemapAgent shape

Short version: the *idea* of a dedicated sitemap capability is reasonable, but two parts of the proposed shape are likely to bite you. One is an architectural smell (agent-to-agent direct calls), the other is a workload mismatch (putting crawling + XML formatting inside a reasoning loop). Let me walk through both and suggest an alternative.

## 1. SEO agent calling SitemapAgent directly — avoid this

Having one specialized agent reach in and invoke another specialized agent creates a tight, hidden coupling that tends to get expensive fast:

- **Hidden control flow.** The orchestrator no longer has a complete picture of what work is happening. If the SEO agent silently spawns SitemapAgent, then debugging, tracing, cost accounting, and timeout/retry policy all get murky — you have a sub-call that doesn't show up where the rest of orchestration lives.
- **A coupling graph that doesn't scale.** Today it's SEO → Sitemap. Tomorrow something else wants sitemaps too (a deploy hook, a "publish" flow, a content agent). If each caller wires a direct dependency, you get an N×N mesh of agents knowing about each other. The orchestrator exists precisely to be the hub so agents don't need to.
- **Reuse gets blocked.** A sitemap is a generally useful artifact. If it's only reachable *through* the SEO agent's reasoning, every other consumer has to route through SEO-specific logic (and pay for SEO's reasoning tokens) to get it.
- **Error handling leaks.** When SitemapAgent fails, the SEO agent now owns that failure mid-reasoning. Recovery, partial results, and retries become the SEO agent's problem instead of the orchestrator's, which is the wrong place for it.

**Better:** keep agent invocation decisions with the orchestrator. The SEO agent shouldn't *call* SitemapAgent — it should *signal a need* ("a sitemap should be generated/refreshed for this app") and let the orchestrator decide whether to dispatch the sitemap work. That keeps the dependency graph a star, not a mesh, and keeps all dispatch/trace/cost in one place.

## 2. Crawling + XML formatting inside a reasoning loop — also avoid this

This is the bigger concern. Generating a sitemap is, at its core, **deterministic mechanical work**:

- Enumerate the app's routes/pages (you almost certainly already have this — appsmith-style platforms keep an explicit page/route registry in app metadata; you should read that, not "crawl").
- Apply filters (exclude auth-gated, draft, or non-indexable pages).
- Emit well-formed XML conforming to the `sitemaps.org` schema (`<urlset>`, `<url>`, `<loc>`, optional `<lastmod>`, `<changefreq>`, `<priority>`).

None of that benefits from LLM reasoning, and putting it in a reasoning loop actively hurts you:

- **Correctness.** An LLM emitting raw XML can produce subtly malformed output — unescaped `&`, wrong namespace, dropped entries, hallucinated URLs. XML generation should go through a serializer/template that is correct by construction.
- **Cost and latency.** You'd pay tokens to "reason" about a loop-and-format task. For a large app this is slow and expensive for zero added intelligence.
- **Non-determinism.** The same app could yield different sitemaps run-to-run. Sitemaps should be reproducible.
- **Scale.** Hundreds of routes won't fit comfortably or reliably in a model context.

**Better:** the sitemap *generation* should be a plain deterministic function/tool — given the app's route registry and base URL, return validated XML. No model in the hot path.

## So do you even need a "SitemapAgent"?

Probably not as a full reasoning agent. Ask what actual *judgment* is required:

- If the answer is "almost none — just enumerate routes and format XML," then this should be a **tool** (e.g. `generate_sitemap(appId)`), not an agent. The orchestrator (or whatever flow) calls the tool directly.
- An agent is only warranted if there's genuine reasoning: deciding *which* pages are SEO-worthy, inferring `priority`/`changefreq` from page semantics, handling localized/alternate URLs, reconciling against an existing sitemap. Even then, the agent should *decide* and then *call the deterministic tool* to actually produce the XML — the agent orchestrates, the tool emits.

A useful litmus test: **agents reason; tools do.** Crawling and XML serialization are "do." If a step has a single correct output for a given input, it belongs in a tool.

## Recommended shape

```
Orchestrator
  ├── SEO agent        → reasons about SEO needs; emits a request:
  │                      "generate/refresh sitemap for app X"
  │                      (does NOT call another agent)
  │
  ├── [optional] SitemapAgent  → only if real judgment is needed
  │                              (page selection, priority inference);
  │                              it reasons, then calls the tool below
  │
  └── generate_sitemap(appId)  → deterministic tool
                                 reads app route registry,
                                 filters non-indexable pages,
                                 emits schema-valid XML
```

Decision flow:
1. SEO agent concludes a sitemap is needed → returns that as a result/intent to the orchestrator.
2. Orchestrator dispatches sitemap work. If selection logic is trivial, it calls `generate_sitemap` directly and skips the agent entirely.
3. The deterministic tool builds and validates the XML.

## Concrete suggestions

- **Don't crawl — read metadata.** A deployed app on this kind of platform exposes its pages/routes in app config. Pull from that source of truth; HTTP-crawling your own app is slower, flakier, and can miss or duplicate routes.
- **Validate output.** Run generated XML against the sitemap XSD (or at minimum a well-formedness + namespace check) before publishing.
- **Handle the >50,000-URL / 50MB limit.** Large apps need a sitemap *index* pointing to multiple sitemap files. Bake that into the tool.
- **Make `lastmod` meaningful.** Derive it from real page/app modification timestamps in metadata, not "now" — wrong `lastmod` is worse than none.
- **Decide who triggers refresh.** A sitemap is usually best regenerated on deploy/publish, not on every SEO-agent run. Consider a deploy hook calling the tool, with the SEO agent only requesting an ad-hoc refresh.

## Bottom line

- The need is real; the *packaging* is off.
- **Don't** have the SEO agent call another agent directly — have it return an intent and let the orchestrator dispatch. Keep the agent graph a star.
- **Don't** put crawling/XML formatting in a reasoning loop — make it a deterministic tool that reads the route registry and emits schema-valid XML.
- A standalone `SitemapAgent` is only justified if there's genuine page-selection judgment; otherwise ship `generate_sitemap` as a tool and you're done.
