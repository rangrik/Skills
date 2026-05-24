# Extraction guide

Where the ubiquitous language hides in a repo, how to filter it, and a fully
worked example. Read this when you need more than the high-level process in
`SKILL.md`.

## Table of contents

1. Where each kind of term lives
2. The inclusion/exclusion decision in practice
3. Canonicalization: synonyms vs. ambiguities
4. A worked example (a small SaaS repo)

---

## 1. Where each kind of term lives

Different concept types surface in different parts of a repo. Sweep these
sources; the first few are the highest signal because they show the team's own
words, not just inferred structure.

**Narrative docs (highest signal for canonical names).**
`README`, `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`, `docs/`, design docs,
ADRs, RFCs. People write these in the language they actually speak, so they are
your best source for the *canonical* name of a subsystem or product area and for
how concepts relate. When a doc and the code disagree on a name, that disagreement
is itself a candidate flagged ambiguity.

**Routes and product surfaces.**
Frontend router config, page directories (`pages/`, `app/`, `routes/`), backend
route modules. Routes name the surfaces users navigate — pages, sections,
dashboards, flows. A path like `/app/:id/analytics` tells you "Analytics" is a
surface; the segment names are often domain nouns.

**Data model — the load-bearing nouns.**
ORM models, table definitions, migrations, schema files, core types, and
especially **enums** (which encode lifecycle states: `draft → published →
archived`). The entities here are usually the spine of the taxonomy, and their
state enums often deserve their own lifecycle cluster.

**Directory and module structure.**
Top-level folders and feature folders frequently map to product areas, bounded
contexts, or subsystems (`billing/`, `discoverability/`, `orchestrator/`). Treat
a folder name as a *candidate* concept, then confirm it's something people talk
about — not just a code-organization bucket.

**Named moving parts of the system.**
Agents, services, workers, queues, scheduled jobs, event/message names, pipelines.
These are the architecture vocabulary: Orchestrator, Coding Agent, Sandbox,
Workpad, the publish queue, a "self-heal" job. If the team refers to it by a
proper name, it's a term.

**External integrations as concepts.**
A payment processor, a deploy-preview provider, a search-console integration, an
email sender. Capture the *concept and its role* ("Deploy Preview: a
throwaway environment for reviewing a change"), never the SDK or client class.

**Tests and fixtures (corroboration).**
Test names and fixture data often state intent in plain language and can confirm
what a concept really means or reveal an alias the main code hides.

---

## 2. The inclusion/exclusion decision in practice

Run every candidate through one question: **would two teammates use this word in
a design conversation, and does it name a concept rather than a piece of code?**

Worked judgements:

| Candidate | Verdict | Why |
| --- | --- | --- |
| `Order`, `Invoice`, `Subscription` | include | Core domain nouns people say constantly. |
| `Orchestrator`, `Sandbox`, `Deploy Preview` | include | Named subsystems the team discusses; needed to explain system design. |
| `Publish`, `Fulfillment` | include | Lifecycle/process concepts with shared meaning. |
| `OrderService`, `InvoiceRepository` | exclude | Implementation of a concept already captured as `Order` / `Invoice`. |
| `useDebounce`, `formatCurrency` | exclude | Generic helpers, no product meaning. |
| `DTO`, `endpoint`, `callback` | exclude | Generic CS vocabulary. |
| `Workpad` (a coined internal term) | include | Generic-looking, but the team gave it a specific local meaning — define it. |

When unsure, lean on whether the word appears in *prose* (docs, PR descriptions,
comments written for humans) versus only as an *identifier*. Prose presence is
strong evidence it's part of the ubiquitous language.

---

## 3. Canonicalization: synonyms vs. ambiguities

The two cases look similar and are constantly confused. Keep them apart:

**Synonyms — many words, one concept.**
The repo says "site," "app," and "project" in different places but means the same
thing. Resolution: pick one canonical term (the clearest, most-used, least
collision-prone), and list the others under **Aliases to avoid**. The goal is
that the team stops using the alternatives.

**Ambiguity — one word, two concepts.**
The repo says "account" to mean both a paying customer and a login identity.
Resolution: do **not** pick a winner among the meanings — invent or adopt two
distinct terms (`Customer`, `User`), and record the collision under **Flagged
ambiguities** with a recommendation. The danger of an ambiguity is silent
miscommunication, so naming it is the whole point.

A quick way to tell them apart: if you can replace every occurrence of the word
with one chosen term and nothing breaks in meaning, it's a synonym set. If
replacing it would make some sentences wrong, it's an ambiguity.

---

## 4. A worked example

Suppose a repo is an e-commerce backend with `README` mentioning "orders,"
"customers," and a "fulfillment pipeline"; models for `Order`, `Invoice`,
`Shipment`, `Customer`, `User`; a folder `fulfillment/`; and inconsistent use of
"account" (sometimes the billing entity, sometimes the auth row) and "client"
(used interchangeably with "customer").

The harvested, filtered, canonicalized result:

```markdown
# System Taxonomy

## Order lifecycle

| Term            | Definition                                                       | Aliases to avoid      |
| --------------- | ---------------------------------------------------------------- | --------------------- |
| **Order**       | A customer's request to purchase one or more items               | Purchase, transaction |
| **Fulfillment** | The process of preparing and dispatching an order's items        | Processing            |
| **Shipment**    | A single dispatch of items toward a customer                     | Delivery, package     |
| **Invoice**     | A request for payment sent to a customer after a fulfillment     | Bill, payment request |

## People

| Term         | Definition                                  | Aliases to avoid       |
| ------------ | ------------------------------------------- | ---------------------- |
| **Customer** | A person or organization that places orders | Client, buyer, account |
| **User**     | An authentication identity in the system    | Login, account         |

## Relationships

- An **Order** belongs to exactly one **Customer**
- An **Order** produces one or more **Shipments**
- Each **Shipment** generates exactly one **Invoice**
- A **User** may or may not represent a **Customer**

## Example dialogue

> **Dev:** "When a **Customer** places an **Order**, do we create the **Invoice** immediately?"
> **Domain expert:** "No — an **Invoice** is only generated once a **Fulfillment** is confirmed. A single **Order** can produce multiple **Invoices** if items ship in separate **Shipments**."
> **Dev:** "So if a **Shipment** is cancelled before dispatch, no **Invoice** exists for it?"
> **Domain expert:** "Exactly. The **Invoice** lifecycle is tied to the **Fulfillment**, not the **Order**."

## Flagged ambiguities

- "account" was used to mean both **Customer** and **User** — these are distinct concepts: a **Customer** places orders, while a **User** is an authentication identity that may or may not represent a **Customer**.
- "client" appeared as a synonym for **Customer** in some modules and as an HTTP client elsewhere; reserve **Customer** for the domain concept and never use "client" for it.
```

Note what the example does: every term traces to something in the repo, synonyms
are demoted with an opinion, the one-word-two-concepts case ("account") is split
and flagged rather than merged, the dialogue turns on the real boundary
(Invoice tied to Fulfillment, not Order), and you could narrate the whole
order-to-payment flow using only these words.
