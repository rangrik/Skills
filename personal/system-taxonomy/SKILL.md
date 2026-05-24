---
name: system-taxonomy
description: >-
  Extract the ubiquitous language of a code repository — the shared vocabulary
  of domain concepts AND named subsystems that a team actually uses to discuss
  the product and its architecture — and write it to UBIQUITOUS_LANGUAGE.md: an
  opinionated, grouped glossary with tight definitions, aliases to avoid,
  relationships with cardinality, an example dialogue, and flagged ambiguities.
  The result is a communication contract: reading it lets one engineer (or an
  agent) name a concept and have everyone land on exactly the right module, then
  explain a feature's flow or point out a bug using only those terms. Use this
  whenever the user wants to map, document, agree on, or align an agent to the
  vocabulary / terminology / concepts / taxonomy / domain language of a codebase
  or product. Triggers on "what are the core concepts here", "build a glossary",
  "define our domain language", "create a ubiquitous language", "what should we
  call X", "map the taxonomy of this repo", "I want one shared vocabulary for
  the system so we stop calling the same thing different names", or onboarding a
  person or agent into speaking about the system consistently. Fire even when
  the user says only "taxonomy", "domain model", "shared vocabulary", or
  "terminology" and never says "ubiquitous language".
---

# System Taxonomy

## What this produces and why

The deliverable is a single file, `SYSTEM_TAXONOMY.md`, that captures the
**shared language of the system**: every concept that carries meaning when
people (or agents) discuss the product and how it is built. The point is not a
data dictionary or a list of classes — it is the vocabulary itself, made
consistent and unambiguous.

Treat the document as a **communication contract**, not reference trivia. The
real job is that two engineers — or an engineer and an agent — can use it to
talk about the codebase and mean the same thing. Concretely, after reading it a
person should be able to:

- **say a term and have the listener land on exactly one module/concept** — no
  "wait, which X do you mean?";
- **explain the flow of a new feature** using only these terms;
- **point out where a bug lives** ("it's in the **Orchestrator**, between the
  **Coding Agent** and the **Sandbox**") using only these terms.

The north-star test for the whole document: **someone holding only this file
should be able to do all three of those without reaching for a single word that
isn't defined here.** If you need outside jargon to describe how the system
works, locate a feature, or place a bug, the taxonomy has a gap. That test
drives both what you include and when you're done — and it raises the bar on
*precision*: each term must pick out exactly one thing, so naming it leaves no
doubt about which module or concept you mean.

This is a *ubiquitous language* in the domain-driven-design sense: the words the
team already uses, harvested from the codebase, then made opinionated — one
canonical name per concept, synonyms demoted to "aliases to avoid," and genuine
ambiguities called out rather than smoothed over.

## What counts as a term

Capture two layers, because for an engineering product you cannot explain the
system design with only business words:

| Include | Exclude |
| --- | --- |
| **Product-domain concepts** people use in conversation: the core entities, actors, lifecycles, and surfaces (e.g. App, Customer, Order, Invoice, Publish, Dashboard, Subscription). | **Incidental code identifiers** — a specific service class, helper function, util module, variable, or file name that names an implementation, not a concept (`OrderServiceImpl`, `useFetch`, `utils.ts`). |
| **Named subsystems and architectural concepts** the team refers to by name (e.g. Orchestrator, Sandbox, Coding Agent, Workpad, Deploy Preview, Queue). These ARE domain language for the people building the system. | **Generic programming vocabulary** with no product-specific meaning (array, endpoint, callback, repository-pattern, DTO) — unless the team has given the word a special local meaning. |
| **A word the team gives a special local meaning**, even if it looks generic — define it precisely. | **Pure infrastructure plumbing** nobody discusses by name (a specific Docker base image, a CI step) unless it's a concept people actually reason about. |

The litmus test for inclusion: *would two teammates use this word in a design
conversation, and does it name a concept rather than a piece of code?* If yes,
it belongs. If it only ever appears as an identifier in source and never in a
sentence between humans, leave it out.

## Process

Work in this order. Steps 1–2 are grounding; the document only earns trust if
every term traces back to the actual repo, even though the output never cites
file paths.

### 1. Harvest the team's own words (don't invent vocabulary)

The ubiquitous language already exists in the repo — your job is to surface and
sharpen it, not author it from scratch. Read, in roughly this order of signal:

1. **Narrative docs** — `README`, `AGENTS.md` / `CLAUDE.md`, `docs/`,
   architecture notes, ADRs. These name subsystems and product areas in the
   team's own voice and are the highest-signal source for canonical names.
2. **Routes and surfaces** — the router / route definitions and page files.
   These reveal product surfaces, sections, and dashboards users navigate.
3. **Data model** — DB models, schemas, core types/enums. These are the
   load-bearing nouns of the domain (the entities and their states).
4. **Directory and module structure** — top-level and feature folders often map
   to product areas, bounded contexts, or subsystems.
5. **Named agents, services, workers, queues, jobs, events** — the moving parts
   of the system design that people refer to by name.
6. **External integrations** that carry domain meaning (a named provider, a
   "Deploy Preview", a payment processor) — include the *concept*, not the SDK.

For a deeper, repo-shape-by-repo-shape map of exactly where each kind of term
hides, read `references/extraction-guide.md`.

### 2. Build the candidate list, then filter

List every candidate concept you saw. Then run each through the inclusion
litmus test above and drop the incidental identifiers and generic CS terms.
Being ruthless here is what separates a useful taxonomy from a noisy dump.

### 3. Canonicalize — be opinionated

This is where you add value. The codebase is almost certainly inconsistent: the
same concept appears as "site" in one place, "app" in another, "project" in a
third. For each concept:

- **Pick the single best name.** Prefer the one the team uses most, that reads
  most clearly to a newcomer, and that won't collide with another concept.
- **Prefer the spoken term over the code identifier.** When the word people say
  in a design conversation differs from the symbol in the code or the DB (the
  team says "Website" but the table is `applications`; they say "Publish" but the
  service is `deployment_service`), the *spoken* word is canonical and the code
  identifier is just one of its aliases. This document exists so humans and
  agents can talk to each other, so it must speak their language — and naming the
  code identifier as an alias is exactly what lets a reader bridge from a
  conversation to the right symbol. Apply this the same way every time so the
  canonical name for the central entity never flip-flops between sections or
  between two runs of this skill.
- **Demote the rest to "aliases to avoid."** These are real words from the repo
  that mean the same thing and should stop being used.

Distinguish three situations carefully — they are handled differently:

- *Many words → one concept* (site / app / project all mean the same thing):
  canonical term + **aliases to avoid**.
- *One word → two distinct concepts* ("account" used for both a paying Customer
  and a login identity): this is an **ambiguity**, not a synonym. Don't pick a
  winner — split it into two terms and record the collision in *Flagged
  ambiguities* with a recommendation.
- *Two words → two genuinely distinct but paired concepts*, most often an
  **action and its mechanism** or a **user-facing name and its system name**
  ("**Publish**" is what the user does; "**Deployment**" is the system pipeline
  it triggers). These are **not** synonyms — do not demote one to an alias of the
  other. Keep both as terms and connect them in *Relationships* and *Key flows*
  ("one **Publish** triggers one **Deployment**"). The tell is whether they sit
  at different layers or have different actors; if so, collapsing them destroys a
  distinction people rely on. When in doubt, keep both and relate them rather
  than merging.

### 4. Cluster into groups

Group terms into natural clusters and give each its own heading and table.
Cluster by whatever structure the domain actually has — subdomain, lifecycle,
actor (people/roles), or subsystem. If everything genuinely belongs to one
cohesive domain, a single table is fine; don't manufacture groups to look
organized.

### 5. Write definitions

One sentence, maximum — long enough to pin the concept, short enough to read at
a glance. The framing depends on what kind of term it is:

- **Entities, states, and roles** — define what the concept **IS**, a noun
  phrase, not a behavior. "An **Invoice** is a request for payment sent after
  delivery," not "An Invoice charges the customer and updates the ledger."
- **Modules and subsystems** (an Agent, a Service, a queue) — here the concept's
  identity *is* its responsibility, so define it by its role in one sentence:
  "The **Coding Agent** is the module that makes all code changes to a website by
  driving the editor on the Sandbox." Don't fight the grain by forcing a pure
  "what it is" noun phrase onto something whose whole point is what it does —
  just keep it to its single defining responsibility, not a list of behaviors.

Either way, resist piling on a second sentence of mechanics; that detail belongs
in the relationships, the flows, or nowhere.

### 6. Write relationships

State how terms connect, using **bold** term names and expressing cardinality
where it's obvious: "An **Invoice** belongs to exactly one **Customer**"; "An
**Order** produces one or more **Invoices**." Relationships are where the
taxonomy stops being a glossary and starts being a model.

### 7. Trace the key flows (when localizing bugs and features matters)

If the taxonomy covers a system with named subsystems — anything where someone
will say "the bug is in **X** handing off to **Y**" — add a short **Key flows**
section. List the two or three main end-to-end sequences (e.g. the core product
journey, the generation/build path) as an ordered chain of the modules involved,
naming each **handoff** between them: "**Orchestrator** → (`trigger_coding_agent`
tool call) → **Coding Agent** → drives **OpenCode CLI** → on the **Sandbox**." A
relationships list tells you what connects to what; a flow tells you the *order
and the seams*, which is exactly what lets a reader point at the boundary a
defect lives on. Skip this for a pure business-domain taxonomy (orders, invoices)
where there's no runtime pipeline to localize against — it would be noise.

Here — and only here — it's worth naming the actual tool, function, or handler
at a seam (`trigger_coding_agent`, `deployment_service.create_deployment()`)
even though those code identifiers are not taxonomy terms. The flow's whole job
is letting someone jump from "the bug is at this handoff" to the exact code, so
the seam labels earn their place. Keep the *nodes* in taxonomy terms; let the
*edges* cite the code that implements the handoff.

### 8. Write the example dialogue

A short conversation (3–5 exchanges) between a dev and a domain expert that
shows the terms used precisely and naturally. Its job is to clarify *boundaries*
between concepts that are easy to confuse — make the dialogue hinge on exactly
the distinction a newcomer would get wrong, ideally the same seam a real bug
would sit on. Use bold term names throughout.

### 9. Write flagged ambiguities

Call out every place a word is used for two distinct concepts, or where the repo
contradicts itself, with a clear recommendation for how to disambiguate. This
section is often the most valuable part of the document — it's where you save
the next person from a real misunderstanding.

### 10. Completeness self-test (the gate before you write the file)

The taxonomy is a communication contract, so test it the way it will be used.
Narrate each of these to yourself using **only** the terms in the taxonomy:

1. **The main product journey** — what a user does from start to finish.
2. **The core system flow** — how the system fulfills that journey end to end
   (the system-design walkthrough).
3. **Introducing a new feature** — describe where a plausible new capability
   would slot in and which concepts it touches.
4. **Pointing at a bug** — name where a realistic defect would live ("in the
   **X**, when it hands off to the **Y**").

Every time you're forced to reach for a word that isn't defined, you've found a
gap — add the term (or flag the ambiguity) and narrate again. And every time a
term is too vague to land on one thing ("the service", "the handler" — which
one?), that's a *precision* gap: split or rename it until naming it is
unambiguous. Stop when all four narrations read cleanly with no outside jargon
and every reference resolves to exactly one concept. This is the operational
meaning of "exhaustive" — not "I listed a lot of terms," but "nothing is left
that I'd have to explain with, or point at using, a word from outside the
list."

## Output format

Write `SYSTEM_TAXONOMY.md` at the repo root (unless the user names another
location) using exactly this structure. Group tables by natural cluster; the
headings below are illustrative.

```markdown
# System Taxonomy

## <Cluster name, e.g. Order lifecycle>

| Term        | Definition                                              | Aliases to avoid      |
| ----------- | ------------------------------------------------------- | --------------------- |
| **Order**   | A customer's request to purchase one or more items      | Purchase, transaction |
| **Invoice** | A request for payment sent to a customer after delivery | Bill, payment request |

## <Another cluster, e.g. People>

| Term         | Definition                                  | Aliases to avoid       |
| ------------ | ------------------------------------------- | ---------------------- |
| **Customer** | A person or organization that places orders | Client, buyer, account |
| **User**     | An authentication identity in the system    | Login, account         |

## Relationships

- An **Invoice** belongs to exactly one **Customer**
- An **Order** produces one or more **Invoices**

## Key flows
<!-- Include for systems with named subsystems; omit for a pure business domain. -->

- **Order fulfilment:** **Order** placed → **Fulfilment** confirmed → one **Shipment** dispatched → **Invoice** generated and sent to the **Customer**.

## Example dialogue

> **Dev:** "When a **Customer** places an **Order**, do we create the **Invoice** immediately?"
> **Domain expert:** "No — an **Invoice** is only generated once a **Fulfillment** is confirmed. A single **Order** can produce multiple **Invoices** if items ship in separate **Shipments**."
> **Dev:** "So if a **Shipment** is cancelled before dispatch, no **Invoice** exists for it?"
> **Domain expert:** "Exactly. The **Invoice** lifecycle is tied to the **Fulfillment**, not the **Order**."

## Flagged ambiguities

- "account" was used to mean both **Customer** and **User** — these are distinct concepts: a **Customer** places orders, while a **User** is an authentication identity that may or may not represent a **Customer**.
```

## Quality bar — common failure modes to avoid

- **Dumping code structure as terms.** A directory list or a class list is not a
  taxonomy. If a "term" only ever lives in source and never in a sentence
  between people, cut it.
- **Wishy-washy on synonyms.** Listing "site, app, project" as three separate
  terms is a failure. Pick one, demote two. Opinion is the deliverable.
- **Multi-sentence definitions.** A definition that runs to a second sentence of
  mechanics is doing the relationships' or flows' job. Keep each to one sentence:
  what an entity *is*, or a module's single defining responsibility.
- **A dialogue that just lists terms.** The dialogue must turn on a real
  boundary between two confusable concepts, not recite definitions.
- **The central entity named two ways.** If the doc calls the same core concept
  "Website" in one section and "Application" in another, the contract is broken
  before it starts. Pick the spoken term once, demote the code identifier, and
  hold it everywhere.
- **Terms too vague to point with.** If saying a term still leaves a colleague
  asking "which one?", it fails the contract. A term must resolve to exactly one
  module/concept so you can localize a bug or a feature with it. Split or rename
  until it's unambiguous.
- **Skipping the self-test.** Without step 10 you'll ship a plausible-looking
  glossary with a hole in the middle. The whole value is that there's no hole.

For a fully worked example and the detailed per-repo extraction map, see
`references/extraction-guide.md`.
