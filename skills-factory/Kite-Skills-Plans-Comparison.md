# Kite Skills — Plan Comparison & Gap Analysis

An exhaustive comparison of the two competing plans for generating the five Kite
pipeline skills, cross-checked against the actual source files.

- **Plan A — `Kite-Skills-Generation-Plan.md`** (the "Generation Plan")
- **Plan B — `Kite-Skills-Build-Plan.md`** (the "Build Plan")

Both plans set out to do the same job: turn the five verbatim `SKILL.md` blocks
in `skills-factory/Kite-Skill-Prompts.md` into installed skills under
`private-skills/` (`kite-planner`, `kite-research`, `kite-implementation`,
`kite-scenario-check`, `kite-feature-review`), alongside the existing
`kite-arch-compass`, which both correctly leave untouched.

Everything below was verified against `Kite-Skill-Prompts.md`, the
`private-skills/` tree, both `skill-creator` variants in the repo, and the
sibling skills (`blueprint/`, `system-design/`, `evals-results/`).

---

## The single most important finding: the plans target two different toolchains

Almost every divergence between the plans traces back to one root cause: **they
were written for two different `skill-creator` toolchains, and both toolchains
physically exist in this repo.**

- **Plan A targets the OpenAI / Codex `skill-creator`.** It references
  `/Users/pranavkanade/.codex/skills/.system/skill-creator/`, uses
  `init_skill.py`, and generates `agents/openai.yaml`. This matches
  `by-openai/skill-creator/`, which contains `scripts/init_skill.py`,
  `scripts/generate_openai_yaml.py`, and an `agents/openai.yaml`.
- **Plan B targets the Anthropic / Claude `skill-creator`.** It invokes the
  skill through the Skill tool, states "no init script; scaffolding is manual,"
  and runs a full eval / benchmark loop. This matches `by-anthropic/skill-creator/`
  (the same build installed at `.claude/skills/skill-creator`), which has **no**
  `init_skill.py` but **does** have `run_loop.py`, `run_eval.py`,
  `aggregate_benchmark.py`, `eval-viewer/`, and grader/analyzer/comparator agents.

Consequence: where the two plans appear to contradict each other on facts, they
are frequently *both correct — for their own toolchain*. The real question is
which toolchain this repo expects. On that point the evidence is one-sided (see
Adjudication).

---

## Side-by-side comparison

### Scope & strategy

| Dimension | Plan A — Generation Plan | Plan B — Build Plan |
|---|---|---|
| Apparent author / toolchain | OpenAI Codex `skill-creator` | Anthropic Claude `skill-creator` |
| Skills covered | 5 (correct) | 5 (correct) |
| `kite-arch-compass` | Excluded, referenced only | Excluded, referenced only |
| Install location | `private-skills/` | `private-skills/` |
| **Overall scope** | **Generate + validate only** | **Generate + author evals + run the full benchmark/iterate loop** |
| Number of stages | 1 (generate) | 2 (Stage 1 generate, Stage 2 eval/iterate) |
| Evals | None | `evals/evals.json` + `evals/files/` fixtures for all 5 |
| Benchmark loop | None | Full: with-skill vs baseline runs, grader, HTML viewer, `feedback.json`, iterations |
| Stage 2 prioritization | n/a | planner & feature-review first, then scenario-check, then research & implementation |
| Commits | "Do not commit unless explicitly asked" | Not addressed |
| Document size / depth | ~9 KB, terse and operational | ~13 KB, heavy context and rationale |

### Toolchain & build mechanics

| Dimension | Plan A — Generation Plan | Plan B — Build Plan |
|---|---|---|
| `skill-creator` invocation | By file path (`.codex/.../SKILL.md`) | By Skill tool (`skill-creator:skill-creator`) |
| Scaffolding | `init_skill.py` | Manual (uses the "content already written" path) |
| `agents/openai.yaml` | Generated for all 5, with exact interface values | Not created / not mentioned |
| Interface values supplied | Yes — `display_name`, `short_description`, `default_prompt` per skill | None |
| Subagent type | `worker` | `general-purpose` |
| Subagent dispatch | 5 in parallel, one message, disjoint write scopes | 5 in parallel, one message, disjoint write scopes |
| Subagent prompt form | 5 prompts written out in full | 1 shared template + per-skill fill-ins |
| Validation tool | `quick_validate.py` (assumed present) | `quick_validate.py` "if available" + manual frontmatter check |

### Fidelity to the source blocks

| Dimension | Plan A — Generation Plan | Plan B — Build Plan |
|---|---|---|
| Copy policy | "Faithful," "keep SKILL.md concise," "packaging-level adjustments" allowed | "Byte-for-byte," "do not edit, rephrase, reflow, or improve a single word" |
| Block identification | By heading name ("Skill 1 - `kite-planner`") | By exact line ranges (all verified accurate) |
| Outer-fence stripping | Not specified | Explicit ("copy only content inside the outer fence") |
| Four-backtick fence on Skill 5 | Not mentioned | Explicitly handled (nested report-template block preserved) |
| Cross-skill references in bodies | Not mentioned | Explicit ("leave references to other skills as written") |
| `references/plan-file.md` content | All of Section 0 | Only the Template block + "Ownership and status flow" (lines 50–108) |
| `plan-file.md` recipients | planner, research, implementation, feature-review (not scenario-check) | Same |

### Verification

| Dimension | Plan A — Generation Plan | Plan B — Build Plan |
|---|---|---|
| Verbatim diff vs source | No (read-through only) | Yes (diff each body against its source block) |
| Frontmatter check | Yes (only `name` + `description`) | Yes (`name` matches directory, YAML parses) |
| Cross-skill `plan-file.md` equality | Yes (byte-for-byte across the 4) | Implicit ("same reference as above") |
| Stray-file check | Yes (`find ... -maxdepth 2`) | No explicit check |
| Triggering verification | No | Yes (skills appear and fire on intended phrases; spot-check) |
| Eval-loop verification | n/a | Yes (benchmark aggregates; with-skill beats baseline) |
| Live `appsmith-v2` repo dependency | Not addressed | Explicitly flagged for research & implementation evals |

---

## Adjudication — who is right where the plans conflict

Each disputed claim checked against the actual files in the repo.

| Disputed point | Plan A says | Plan B says | Verified verdict |
|---|---|---|---|
| Does `init_skill.py` exist? | Yes — uses it | No — "scaffolding is manual" | **Both right, per toolchain.** `init_skill.py` exists in `by-openai/skill-creator/scripts/`; it is absent from `by-anthropic/skill-creator/`. Not a true contradiction. |
| `quick_validate.py` | Uses it (assumed) | "If available" | **Exists in both** variants. Plan A's confidence is justified; Plan B's hedge is unnecessary. |
| Is `agents/openai.yaml` a repo convention? | Treats it as standard | Ignores it | **It is the Codex `skill-creator` convention only.** No existing skill in the repo — `kite-arch-compass`, `system-design`, `blueprint`, `backend-standards` — has an `agents/openai.yaml`. |
| Is `evals/evals.json` a repo convention? | Omits it | Treats it as standard | **Plan B matches the repo.** `kite-arch-compass`, `system-design`, and `blueprint` all ship `evals/evals.json` + `evals/files/`. `evals-results/` shows the loop has already been run for three sibling skills. |
| Is Skill 5 a four-backtick fenced block? | Silent | Yes, with a nested ```` ``` ```` report template | **True.** `Kite-Skill-Prompts.md` lines 507–618: a ```` ````md ```` fence wrapping a nested triple-backtick report template. Plan B handles it; Plan A has a latent extraction bug here. |
| Plan B's line numbers | n/a (uses headings) | Exact ranges per skill/section | **All accurate** — Skill 1 (114–239), Section 0 Template (50–97), Ownership flow (99–108), Skill 2 (245–343), Skill 3 (349–431), Skill 4 (437–501), Skill 5 (507–618). |
| What does "copy" mean? | "Faithful" / "concise" / adjustments allowed | "Byte-for-byte verbatim" | **Plan B matches the source.** `Kite-Skill-Prompts.md` line 8: "copy a block **verbatim**." Plan A's "keep SKILL.md concise" wording risks a subagent trimming the body. |
| Should the skills be evaluated, not just generated? | "Not... full forward-testing" (first pass) | Full eval/iterate loop | **Plan B matches the source's stated intent.** `Kite-Skill-Prompts.md`'s "Next step" section: the prompts "are drafts meant to be exercised, not assumed correct," and it explicitly recommends the `skill-creator` eval loop — "kite-planner and kite-feature-review first." Plan B follows this almost word for word; Plan A's scope assumption contradicts it. |

**Net:** Plan B is consistent with the repo's established structure (every comparable
skill = `SKILL.md` + `references/` + `evals/`, no `openai.yaml`) and with the
source document's own "Next step" instruction. Plan A is internally coherent, but
for the OpenAI/Codex toolchain — and that toolchain is not the one this repo has
been built with.

---

## Gaps in Plan A (Generation Plan)

**High severity**

- **No evals, against the source's explicit instruction.** `Kite-Skill-Prompts.md`
  states the five prompts "are drafts meant to be exercised, not assumed correct"
  and recommends running them through `skill-creator`'s eval loop. Plan A's
  Assumptions section scopes this out ("not... full forward-testing"). It treats
  drafts as final, which the source specifically warns against.
- **Output is structurally inconsistent with the repo.** Plan A produces
  `SKILL.md` + `references/` + `agents/openai.yaml` and **no** `evals/`. Every
  comparable skill it sits beside — `kite-arch-compass`, `system-design`,
  `blueprint` — has the opposite shape (`evals/` present, no `openai.yaml`). The
  five new skills would not match their own neighbour `kite-arch-compass`.
- **Skill 5's four-backtick fence is not flagged.** `kite-feature-review` is
  wrapped in a ```` ````md ```` fence because its body contains a nested
  triple-backtick report template. A subagent told only to "create the skill from
  the fenced block" can truncate the `SKILL.md` at the first inner ```` ``` ```` or
  mangle the template. Plan A gives no warning; Plan B does.

**Medium severity**

- **"Concise" undercuts "verbatim."** The subagent prompts say "Keep SKILL.md
  concise and faithful to the source block." "Concise" invites trimming; the
  source demands a verbatim copy. Plan A also has no verbatim diff in its
  verification, so any drift would go uncaught.
- **"Packaging-level adjustments" is an unbounded escape hatch.** Plan A permits
  "adjustments needed for valid skills" without saying what they are. The source
  blocks already validate as-is (frontmatter is plain `name` + `description`), so
  this licence is unnecessary and risk-only.
- **No triggering verification.** Plan A checks files exist and validate, but
  never confirms the skills actually fire on their intended phrases — the one
  thing that makes a skill useful.
- **`references/plan-file.md` is over-inclusive.** Plan A copies *all* of
  Section 0, including its intro prose — which contains build-time meta-instructions
  ("When you scaffold the skills, bundle a copy as `references/plan-file.md`..."").
  That scaffolding instruction does not belong inside a reference shipped to the
  skill's *runtime* reader.

**Low severity**

- The `worker` subagent type is environment-specific; it is not a generic type
  and may not exist outside the Codex toolchain.
- The `.codex/.../skill-creator` path is plausible (the user does run Codex) but
  unverifiable from the repo; the equivalent scripts are confirmed only in
  `by-openai/skill-creator/`.

---

## Gaps in Plan B (Build Plan)

**Medium severity**

- **No `agents/openai.yaml`, with no acknowledgement of the trade-off.** The repo
  is explicitly multi-agent (`README.md`: "compatible with any agent"; `sync-skills.sh`
  installs into a shared store that "reaches pi, Cursor, Codex…"). If these skills
  are ever surfaced in a Codex-style chip UI they will carry no display metadata.
  Plan B never raises this; Plan A at least supplies the interface copy.
- **`references/plan-file.md` is under-inclusive.** Plan B copies only the Template
  block + "Ownership and status flow" and drops Section 0's framing prose —
  including the genuinely useful "the plan file is a single Markdown document; it
  doubles as the pipeline's state machine" and "living document" framing. The
  ideal copy is Template + Ownership flow + that framing, minus the scaffolding
  meta-instruction. Neither plan lands exactly there.

**Low severity**

- **Verbatim vs. validity conflict has no resolution.** Plan B demands
  "byte-for-byte" *and* "frontmatter parses / `name` matches directory." If a
  source block ever failed validation, the subagent would be stuck. (In practice
  the blocks do validate, so this is latent only.)
- **No commit / git guidance.** The repo is under git; Plan B is silent on
  whether to stage or commit. Plan A states a clear "do not commit" default.
- **No stray-file check.** Plan B lists the files to create but never verifies
  that nothing extra was produced. Plan A's `find -maxdepth 2` check is better.
- **Stage 2 omits the headless detail.** `by-anthropic/skill-creator` notes that
  in Cowork/headless environments `generate_review.py` needs `--static` to emit a
  standalone HTML file. Plan B describes the viewer step but not this flag.
- The skill name `skill-creator:skill-creator` may be namespaced differently in
  the actual environment (e.g. `anthropic-skills:skill-creator`).

---

## Gaps in both plans

- **Neither defines `references/plan-file.md` correctly.** Plan A over-includes
  (ships build-time meta-instructions); Plan B under-includes (drops useful schema
  framing). The correct content is the Template block + "Ownership and status
  flow" + the "single Markdown document / state machine / living document"
  sentences, and nothing about scaffolding.
- **Neither mentions installation / discovery.** New skills in `private-skills/`
  are not visible to any agent until `sync-skills.sh` (or `npx skills`) links
  them into the skill stores. Both plans stop at "validated on disk." If the goal
  includes the skills actually being usable, this step is missing from both.
- **Neither addresses the alternative shared-path option.** Section 0 explicitly
  offers a choice: bundle `plan-file.md` in each skill *or* "keep it at a shared
  path your tooling supports." Both plans silently chose the four-copy approach
  (defensible — but undiscussed, and it creates four files to keep in sync).
- **Neither handles a verbatim-block-fails-validation contingency** cleanly. Plan A
  has a vague escape hatch; Plan B has none.

---

## Bottom line

The plans are not really two takes on one job — they are one job seen through two
toolchains. **Plan A is a clean, fast "generate and validate" plan for the
OpenAI/Codex `skill-creator`. Plan B is a thorough "generate, evaluate, and
iterate" plan for the Anthropic/Claude `skill-creator`.**

Measured against this repo and the source document, **Plan B is the better
baseline**: its structure matches every existing skill, its verbatim discipline
matches the source's explicit "copy verbatim" instruction, and its eval loop is
exactly what the source's "Next step" section asks for. Plan A's main weaknesses
— no evals, an `openai.yaml` no other skill has, an unflagged four-backtick fence,
and "concise" wording that undercuts verbatim copying — are real and would leave
the five skills both unverified and structurally off-pattern.

The strongest result is a merge — take Plan B as the spine and graft on Plan A's
sharper edges:

1. **Spine: Plan B** — verbatim byte-for-byte copy, exact line ranges, explicit
   four-backtick handling, `evals/evals.json` + fixtures, and the Stage 2
   benchmark/iterate loop (planner & feature-review first).
2. **From Plan A, adopt:** the explicit "do not commit" default; the
   `find -maxdepth 2` stray-file check; and — *only if these skills are meant to
   surface in Codex* — the `agents/openai.yaml` files with the interface copy
   Plan A already wrote.
3. **Fix in both:** define `references/plan-file.md` precisely (Template +
   Ownership flow + the state-machine framing, no scaffolding meta-text); and add
   a final step to run `sync-skills.sh` so the skills are actually discoverable.

One decision only the user can settle: **are these skills Claude-only, or do they
also need to work in Codex?** That single answer determines whether
`agents/openai.yaml` is a gap in Plan B or correctly absent — and it is the only
genuine fork between the two plans that the source files cannot resolve.

---

*Sources: `skills-factory/Kite-Skill-Prompts.md`, `skills-factory/Kite-Skills-Generation-Plan.md`,
`skills-factory/Kite-Skills-Build-Plan.md`, `private-skills/kite-arch-compass/`,
`by-openai/skill-creator/`, `by-anthropic/skill-creator/`, `system-design/`,
`blueprint/`, `evals-results/`, `README.md`, `sync-skills.sh`.*
