# Slice Solution-Design Document Template

Write the output to `slice-N-<short>-system-design.md`, as a **sibling** of the
slice it designs, inside the `<feature>-slices/` directory. One slice → one spec.

This is **Step 3 (Solution Design): how should the system achieve this
behavior** — at a **high-level system-design altitude**, NOT implementation
detail. Decide *what* and *which subsystem*; leave column-level schemas, migration
SQL, and function signatures to planning and implementation.

Rules:
- Fill every section. If a section is N/A for this slice, say so in one line and why.
- **Code-blind.** State the *capabilities required* and the *data flow intended*;
  never assert what already exists in the codebase. Everything that needs the code
  to confirm — including any "we already have X" claim — goes in §10 **Open
  Questions for the Codebase**, not in the design prose.
- The **autonomy bar:** when this spec is read alongside the codebase by an
  implementer with sound engineering principles, no *user-answerable* unknown
  should remain. Anything still open is a §10 codebase question.
- Name subsystems with `SYSTEM_TAXONOMY.md`'s canonical terms where it exists; if
  it doesn't, name them plainly and consistently.
- Decisions (§4) cite the governing principle they uphold — the **Kite principle
  number** from `kite-design-system-standards` where applicable.
- §3–§9 are the **standard enumeration shared across the pipeline's artifacts**
  (Decisions · Tradeoffs · Assumptions · Scope · Risks · Constraints ·
  Dependencies) — keep each first-class and scannable, not buried in prose.
- §11 (Decision Coverage Checklist) accounts for **every** row in
  `decision-taxonomy.md`. §12 (Slice Coverage Checklist) accounts for **every**
  scenario in the slice.
- Appendix A faithfully captures the interview.

Replace every `<…>` placeholder. Delete this instruction block from the final file.

---

```markdown
# Solution Design — Slice N: <Slice Name>

**Status:** Draft · **Date:** <YYYY-MM-DD> · **Slice:** [./slice-N-<short>.md](./slice-N-<short>.md) · **Builds on:** <slice-M design(s), or "walking skeleton — none">

> Step 3 (Solution Design). The slice defines *what the user can do/see after this increment*; this spec defines, at a high level, *how the system should achieve it*. Read alongside the slice.

## 1. Summary
<One paragraph: how the system achieves this slice's behavior, and the single most important design choice a reviewer must understand first. In taxonomy terms.>

## 2. Data Flow (the entry lens)
<How the slice's data is sourced and moved. High level — name subsystems, not code.>

### 2.1 Source — do we have it, or do we generate it?
<Is the data already produced/stored by an existing subsystem, supplied by the user, fetched from a third party, or generated (e.g. by one of our AI agents)? State which, and what it implies. Note the rough shape/type of the data and the integrity it needs — at design altitude, not a schema.>

### 2.2 Travel — origin → product surface
<Trace the path, subsystem by subsystem, from where the data is born to where the user sees/uses it per the slice's scenarios. A bullet chain or small diagram is welcome:>

- **<Source subsystem>** → (<handoff: event / call / write>) → **<subsystem>** → … → **<Product surface>**

### 2.3 Actors & effects — who acts on the data, and what happens
| Subsystem | Action (C/R/U/D/act) | Effect when it acts (events, downstream work, caches, billing, other subsystems that react) |
|---|---|---|
| <name> | <e.g. creates the record> | <e.g. emits `X` consumed by **Y**> |

## 3. High-Level System View
<Which subsystems this slice touches and how. Shape only — no implementation steps.>

| Subsystem | New / Modified / Reused | What it must do for this slice | Confirmed? (else → §10 Q#) |
|---|---|---|---|
| <name> | <New/Modified/Reused> | <responsibility> | <yes / needs Q#> |

## 4. Decisions
<The load-bearing design decisions, each concise and citing the principle it upholds. ADR-style but high-level.>

### D1. <Decision title>
- **Decision:** <what we're doing — at design altitude>
- **Why:** <rationale, citing the Kite principle number from `kite-design-system-standards`, e.g. `[P<n>]`; or the generic principle by name where the standard is silent>
- **Alternatives considered:** <options and why rejected>

### D2. <Decision title>
<…>

## 5. Tradeoffs
<What each significant choice gives up. If a tradeoff bends a principle, say which (Kite number) — that makes it an accepted compromise, recorded openly per the deviation rule.>

| # | Tradeoff | What we gain | What we give up | Principle bent (if any) |
|---|---|---|---|---|
| T1 | <…> | <…> | <…> | <`[P<n>]` or "none"> |

## 6. Assumptions
<Everything defaulted rather than decided with the user — including interview forks you resolved by recommendation when the user wasn't available. The reader can challenge any row.>

| # | Assumption | Why safe to assume | Needs confirmation? |
|---|---|---|---|
| A1 | <…> | <…> | <yes/no> |

## 7. Scope
- **In scope:** <what this slice's design covers.>
- **Out of scope:** <what it deliberately doesn't — deferred to a named later slice, or owned by an earlier one, or out per the source blueprint.>

## 8. Risks — what can go wrong
<The failure modes and hazards on the data path and in the design. Each with how the design mitigates it (or that it's accepted/open).>

| # | Risk (what can go wrong) | Likelihood/Impact | Mitigation / handling |
|---|---|---|---|
| R1 | <…> | <…> | <how the design addresses it, or "accepted" / "open → Q#"> |

## 9. Constraints & Dependencies
- **Constraints:** <fixed limits this design must respect — platform standards, quotas, latency budgets, ordering guarantees, existing contracts the slice must not break.>
- **Dependencies:** <other slices, subsystems, services, or external providers this slice depends on. Note which are confirmed vs. a §10 question.>

## 10. Open Questions for the Codebase
<The code-blind handoff to the research stage. Every fact only the codebase can settle — does X exist? where is Y wired? what is the current shape of Z? — plus every "we already have it" claim, recorded as a question. Phrase each to be answerable EXISTS / MISSING with a location.>

| # | Question (answerable EXISTS / MISSING + location) | Why the slice needs the answer | Capability required if MISSING |
|---|---|---|---|
| Q1 | <e.g. "Is there an existing App-ownership authorization helper for this route surface, and where is it applied?"> | <which decision / data-flow step depends on it> | <what would have to be built> |

## 11. Decision Coverage Checklist
<Every row from `decision-taxonomy.md`, accounted for. Status: Resolved / Assumed (A#) / Codebase-question (Q#) / N/A — a dimension the codebase must settle is *covered* as long as the question is recorded in §10.>

| Dimension | Status | Where / Note |
|---|---|---|
| A1 Performance & latency | Resolved / Assumed (A#) / Codebase (Q#) / N/A | §<n> / … |
| A2 Throughput & scale | … | … |
| A3 Concurrency & consistency | … | … |
| A4 Availability & reliability | … | … |
| A5 Data integrity & durability | … | … |
| A6 Caching & freshness | … | … |
| A7 Cost | … | … |
| A8 Security & privacy | … | … |
| A9 Observability | … | … |
| A10 Maintainability & simplicity | … | … |
| A11 Testability | … | … |
| A12 Deployability & rollout | … | … |
| A13 Backward compatibility | … | … |
| A14 Accessibility & device/env | … | … |
| B1 Placement / module taxonomy | … | … |
| B2 Data model & persistence | … | … |
| B3 API surface & schemas | … | … |
| B4 Async / background work | … | … |
| B5 External services & contracts | … | … |
| B6 Frontend integration | … | … |
| B7 Feature flags & rollout | … | … |
| B8 Error handling | … | … |

## 12. Slice Coverage Checklist
<Every scenario, edge case, and deviation in *this slice*, mapped to where this design handles it. §11 proves the architectural dimensions were considered; this proves the slice's behavior was. If an item needs no system-design treatment, mark N/A with a reason.>

| Slice item | Type | Handled in | Note |
|---|---|---|---|
| <scenario — quoted or paraphrased> | Happy-path / Edge case / Deviation / Adversarial | §<n> / D<n> / Q<n> | <how it's handled, or N/A + why> |

---

## Appendix A: Captured Inputs
<A faithful record of the interview. For each decision discussed: the question, the recommendation given (and the principle behind it), any push-back you raised on a principle violation, the user's answer, and their intent/notes in their own words.>

### <Topic / Decision 1>
- **Question:** <what was asked>
- **Recommendation given:** <option + Kite principle behind it>
- **Push-back (if any):** <principle flagged and why, if the user's intent bent one>
- **User's answer:** <what they chose>
- **Notes / intent:** <why, constraints, preferences>

### <Topic / Decision 2>
<…>

### Last-call & autonomy check (P4)
- **Asked:** "Anything we've missed for this slice — any concern, constraint, side-effect, or intent not yet captured?"
- **User's response:** <what surfaced, or "nothing further">
- **Autonomy check:** <confirmation that no user-answerable unknown remains; anything still open is a §10 codebase question>
```
