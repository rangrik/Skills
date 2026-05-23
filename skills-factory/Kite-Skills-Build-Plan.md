# Plan: Generate the five Kite pipeline skills with `skill-creator`

## Context — why we're doing this, and how these skills are used in practice

### Why

`skills-factory/Kite-Skill-Prompts.md` contains the finished `SKILL.md` text for
five new skills that together form a **feature-delivery pipeline** for the
appsmith-v2 (Kite) platform. They are written but not yet installed as skills.
The job is to turn each verbatim block into a real, installed skill on disk,
using the `skill-creator` workflow, alongside the already-existing
`kite-arch-compass` reference skill.

The pipeline encodes deliberate **separation of concerns** and **feedback
loops** so that feature work is built the way Kite is meant to be built:

```
kite-planner → kite-research → kite-implementation → kite-feature-review
                                (inner loop per scenario with kite-scenario-check)
```

- **kite-planner** — turns a blueprint + system-design doc into an ordered,
  scenario-by-scenario plan **code-blind** (never reads source), so the plan
  reflects what the design _needs_, not what today's code makes convenient.
- **kite-research** — the _only_ planning-phase skill allowed to read source;
  answers the planner's research questions against the real codebase (EXISTS /
  MISSING / reuse constraints), and raises BLOCKING findings that loop back to
  the planner.
- **kite-implementation** — builds the feature one **vertical scenario slice**
  at a time, checking architecture (via `kite-arch-compass`) and running an
  independent `kite-scenario-check` before each commit.
- **kite-scenario-check** — a fast, independent pre-commit gate: does one
  freshly built scenario satisfy its Gherkin? PASS/FAIL with concrete gaps.
- **kite-feature-review** — final, purely adversarial, scenario-by-scenario
  audit that produces a **review report document** for a human to act on.

### How a skill is used in practice

Skills are _triggered by intent_, not invoked by name. A developer building a
Kite feature simply says what they want at each stage — "plan this feature",
"research the codebase for this plan", "implement this plan", "review the
feature" — and the matching skill's `description` frontmatter fires it. The
**plan file** (shared schema, Section 0 of the prompts doc) is the connective
tissue and state machine: each skill reads and appends to it, every scenario
carries a status, so any phase can be interrupted and resumed.
`kite-arch-compass` is consulted as a reference throughout (lightly by
planner/research, strongly by implementation and review). This is why the skills
must be installed as real, independently-triggerable skills rather than pasted
into a single doc.

### Verified facts grounding this plan

- Skills in this repo live at `private-skills/<name>/SKILL.md` (internal) with
  optional `references/*.md`, `evals/evals.json`, and `evals/files/` fixtures.
  Confirmed against `private-skills/kite-arch-compass/`, `blueprint/`,
  `system-design/`.
- `kite-arch-compass` already exists at
  `/Users/pranavkanade/Skills/private-skills/kite-arch-compass/` — **must not be
  recreated**.
- The five SKILL.md bodies already exist verbatim in
  `skills-factory/Kite-Skill-Prompts.md`. The instruction is to copy each block
  verbatim — no rewriting.
- The shared **plan-file schema** (Section 0) is a _reference_, not a skill, and
  is bundled as `references/plan-file.md` inside each skill that touches the
  plan file (planner, research, implementation, feature-review).
  `kite-scenario-check` does **not** bundle it (it takes code changes + Gherkin
  directly).
- `skill-creator` supports the "content already written" path: _"maybe they
  already have a draft of the skill — in this case you can go straight to the
  eval/iterate part of the loop."_ No init script; scaffolding is manual.

### Decisions confirmed with the user

- **Location:** `private-skills/` (alongside `kite-arch-compass`).
- **Eval scope:** the **full skill-creator loop** (scaffold → evals → benchmark
  with-skill vs baseline → grade → review viewer → iterate).

---

## Approach (two stages)

Because the full loop has an inherent **human-review checkpoint** (the HTML
viewer → `feedback.json`) and the five skills differ in how autonomously they
can be evaluated, the work is staged:

### Stage 1 — Generate all five skills (parallel: 5 `skill-creator` subagents)

One subagent per skill, dispatched in a single message so they run concurrently.
Each owns its own `private-skills/<name>/` directory (no shared state), invokes
the `skill-creator` skill, and produces: verbatim `SKILL.md`, bundled
`references/plan-file.md` (4 of 5), and an authored `evals/evals.json` with
realistic test prompts + fixtures under `evals/files/`.

### Stage 2 — Run the full eval/iterate loop (orchestrated, prioritized)

The benchmark loop spawns nested with-skill/baseline runs and ends at a human
review viewer, so it is run by the main orchestrator, **prioritized by
behavioral weight and evaluability**:

1. **kite-planner** and **kite-feature-review** first (highest weight; both
   evaluate autonomously off-repo from blueprint/design/code-change fixtures).
2. **kite-scenario-check** next (evaluable from code-change + Gherkin fixtures).
3. **kite-research** and **kite-implementation** — these need the _live
   appsmith-v2 repo_ as a fixture to evaluate meaningfully (one reads code, the
   other writes it). Before running their loops, confirm whether the repo is
   available locally to point evals at; otherwise their evals stay as
   documented-but-unrun starters and we note the limitation.

Each skill's loop runs to the review viewer, then pauses for the user's
feedback, then iterates (`iteration-2/`...) until the user is satisfied.

---

## Exact subagent prompts — Stage 1

All five are dispatched together (one message, five `Agent` tool calls,
`subagent_type: general-purpose`). Shared template below; per-skill specifics
follow.

### Shared prompt template

`````
You are creating a new agent skill in the repo /Users/pranavkanade/Skills.
First invoke the `skill-creator` skill (Skill tool → name
`skill-creator:skill-creator`) and follow its conventions for scaffolding a
skill whose full SKILL.md content is ALREADY written (go straight to the
scaffold + eval-authoring part of the loop — do not redraft the body).

Verified repo conventions (mirror private-skills/kite-arch-compass/):
- Skill path: private-skills/<name>/SKILL.md
- Optional: references/*.md, evals/evals.json, evals/files/ fixtures

Your skill: <NAME>

STEP 1 — Scaffold the directory private-skills/<NAME>/.

STEP 2 — Write SKILL.md VERBATIM. Open
/Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md and copy the
fenced SKILL.md block for <NAME> (Skill <N>, lines <RANGE>) verbatim into
private-skills/<NAME>/SKILL.md. Copy only the content INSIDE the outer fence —
do NOT include the opening ```md / ````md line or the closing fence line.
Preserve everything else exactly: the YAML frontmatter and any nested code
blocks. Do not edit, rephrase, reflow, or "improve" a single word.

STEP 3 — <plan-file reference: see per-skill note>

STEP 4 — Author evals/evals.json following the repo shape (study
private-skills/kite-arch-compass/evals/evals.json and
system-design/evals/evals.json: top-level skill_name, notes, and evals[] with
id, name, prompt, expected_output, files, expectations[]). Write 2–3 realistic,
autonomously-runnable test prompts: <per-skill eval guidance>. Put any fixture
files under evals/files/. Do NOT execute the benchmark — only author the file.

STEP 5 — Validate: confirm SKILL.md frontmatter parses, `name` matches the
directory name, and the tree matches convention. Report the final file tree and
any problems.

HARD CONSTRAINTS:
- Do NOT create or modify kite-arch-compass (it already exists).
- Do NOT touch any directory other than private-skills/<NAME>/.
- The SKILL.md body must be byte-for-byte the source block (frontmatter
  included). Leave references to kite-arch-compass and other skills as written.
`````

### Per-skill fill-ins

**1. kite-planner** — Skill 1, lines 114–239.

- STEP 3: Create `references/plan-file.md` with the shared plan-file schema from
  Section 0 (the Template fenced block, lines 50–97, **plus** the "Ownership and
  status flow" subsection, lines 99–108). Copy faithfully.
- STEP 4 evals: given a blueprint + system-design doc fixture, produces a plan
  file that (a) extracts every scenario incl. corner cases as Gherkin, (b)
  orders scenarios for reuse with stated reasoning, (c) writes code-blind
  plans + research questions, (d) sets status `planned`, and **never references
  source code / never asserts what already exists**. Reuse a blueprint+design
  fixture pair from `blueprint/` or `system-design/evals/files/` if present.

**2. kite-research** — Skill 2, lines 245–343.

- STEP 3: Same `references/plan-file.md` as above.
- STEP 4 evals: given a `planned` plan file + a small codebase fixture, answers
  each research question one-to-one as EXISTS (with file:line + reuse note) or
  MISSING (with extension point), records reuse constraints, raises a BLOCKING
  finding + `blocked` status when the codebase contradicts the plan, and puts
  **only names/locations, never copied source** into the plan file. Provide a
  tiny codebase fixture under `evals/files/`.

**3. kite-implementation** — Skill 3, lines 349–431.

- STEP 3: Same `references/plan-file.md` as above.
- STEP 4 evals: given a `researched` plan file, works scenarios in order as
  vertical slices, reuses EXISTS / adds at MISSING extension points, tests
  selectively (not exhaustively), runs the arch check + an independent
  scenario-check before each commit, skips `blocked` scenarios, and records the
  implementation record + `committed` status. Note in `notes` that a faithful
  benchmark needs the live appsmith-v2 repo.

**4. kite-scenario-check** — Skill 4, lines 437–501.

- STEP 3: **No plan-file reference** — this skill takes code changes + a Gherkin
  definition directly. Skip STEP 3.
- STEP 4 evals: given one scenario's code changes + its Gherkin, returns PASS or
  FAIL; FAIL ties each gap to the violated Gherkin clause; correctly flags
  scenario drift (added things the scenario never asked for); stays a fast gate
  (no full-feature audit). Provide a passing-case and a failing-case fixture
  pair under `evals/files/`.

**5. kite-feature-review** — Skill 5, lines 507–618. NOTE: this block uses a
**four-backtick** outer fence because it contains nested triple-backtick code
(the report template). Extract the content between the
`md line and the   closing ` line, keeping the inner ``` report-template block
intact.

- STEP 3: Same `references/plan-file.md` as above.
- STEP 4 evals: given blueprint + design + full code changes + plan file,
  produces the adversarial review report in the prescribed structure — coverage
  check, orphan-change detection, per-scenario "why it's unacceptable" with
  kite-arch-compass principle citations + a concrete failure Gherkin, and Step-9
  missed-corner-cases beyond the blueprint. Provide a feature fixture
  (blueprint + a deliberately flawed set of code changes) under `evals/files/`.

---

## Stage 2 — full eval/iterate loop (after Stage 1 lands)

For each skill in priority order (planner & feature-review → scenario-check →
research & implementation):

1. Confirm/finish `evals/evals.json` assertions (the `expectations[]` are the
   graded criteria).
2. For each eval, spawn **with-skill and baseline (without-skill) runs in
   parallel** into
   `<name>-workspace/iteration-1/eval-<id>/{with_skill,without_skill}/`.
3. Grade each run with a grader subagent; aggregate with
   `python -m scripts.aggregate_benchmark`.
4. Generate the HTML review with `eval-viewer/generate_review.py` and **pause
   for the user to review and supply `feedback.json`**.
5. Improve SKILL.md from feedback (or bundle a helper if every run reinvents the
   same one), rerun into `iteration-2/`, repeat until the user is satisfied.

For **research** and **implementation**, before step 2 confirm the live
appsmith-v2 repo is available to point fixtures at; if not, deliver their loops
as authored-but-unrun and record the limitation.

---

## Verification

- **Structure:** each of the five `private-skills/<name>/` has `SKILL.md`; the
  four pipeline skills (all but `scenario-check`) have
  `references/plan-file.md`; each has `evals/evals.json`. `kite-arch-compass` is
  untouched.
- **Verbatim check:** diff each new `SKILL.md` body against its source fenced
  block in `Kite-Skill-Prompts.md` — must match exactly (frontmatter included).
- **Frontmatter/validity:** every `SKILL.md` `name:` matches its directory; YAML
  parses (run `skill-creator`'s `quick_validate.py` if available).
- **Triggering:** the skills appear in the available-skills list on the next
  session and fire on their intended phrases (e.g. "plan this feature" →
  kite-planner). Spot-check by triggering kite-planner on a sample blueprint.
- **Eval loop (Stage 2):** `benchmark.json` aggregates per skill; the review
  viewer renders with-skill vs baseline; with-skill runs measurably satisfy more
  `expectations[]` than baseline for kite-planner and kite-feature-review.
