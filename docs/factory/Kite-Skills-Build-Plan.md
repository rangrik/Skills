# Plan: Generate the five Kite pipeline skills with `skill-creator`

## Context — why we're doing this, and how these skills are used in practice

### Why

`docs/factory/Kite-Skill-Prompts.md` contains the finished `SKILL.md` text for
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

- This repository is bucketed by skill ownership: `personal/`, `private/`,
  `vendor/`, and `wip/`.
- Runtime skill folders contain only runtime resources an agent may use while
  applying the skill: `SKILL.md`, optional `references/`, `assets/`, and runtime
  helper scripts. Eval suites and eval results do **not** live inside runtime
  skill folders.
- The five Kite pipeline skills belong in the `private` bucket:
  `private/<name>/SKILL.md` with optional `private/<name>/references/*.md`.
- Eval suites/results for private skills live outside the runtime skill folder:
  - Suite: `private/_evals/<name>/suite/evals.json`
  - Fixtures: `private/_evals/<name>/suite/files/` and referenced from
    `evals.json` as `files/<fixture>`
  - Results: `private/_evals/<name>/results/`
- `catalog.yaml` is the source of truth for skill paths, install flags, and eval
  suite/result locations. New installed private skills need catalog entries.
- `kite-arch-compass` already exists at
  `/Users/pranavkanade/Skills/private/kite-arch-compass/` with evals at
  `private/_evals/kite-arch-compass/` — **must not be recreated**.
- The five `SKILL.md` bodies already exist verbatim in
  `docs/factory/Kite-Skill-Prompts.md`. The instruction is to copy each block
  verbatim — no rewriting.
- The shared **plan-file schema** (Section 0) is a _reference_, not a skill, and
  is bundled as `references/plan-file.md` inside each skill that touches the
  plan file (planner, research, implementation, feature-review).
  `kite-scenario-check` does **not** bundle it (it takes code changes + Gherkin
  directly).
- `skill-creator` supports the "content already written" path: _"maybe they
  already have a draft of the skill — in this case you can go straight to the
  eval/iterate part of the loop."_ No init script is required; scaffolding is
  manual.

### Decisions confirmed with the user

- **Runtime location:** `private/<name>/` (alongside `private/kite-arch-compass/`).
- **Eval suite location:** `private/_evals/<name>/suite/`.
- **Eval results location:** `private/_evals/<name>/results/`.
- **Catalog:** add all five skills to `catalog.yaml` with `bucket: private`,
  `install: true`, and the matching suite/results paths.
- **Eval scope:** the **full skill-creator loop** (scaffold → evals → benchmark
  with-skill vs baseline → grade → review viewer → iterate).

---

## Approach (three stages)

Because the full loop has an inherent **human-review checkpoint** (the HTML
viewer → `feedback.json`) and the five skills differ in how autonomously they
can be evaluated, the work is staged:

### Stage 1 — Generate all five skills (parallel: 5 `skill-creator` subagents)

One subagent per skill, dispatched in a single message so they run concurrently.
Each owns its own runtime skill directory and eval-suite directory (no shared
state):

- Runtime: `private/<name>/`
- Eval suite: `private/_evals/<name>/suite/`

Each subagent invokes the `skill-creator` skill and produces: verbatim
`SKILL.md`, bundled `references/plan-file.md` (4 of 5), and an authored
`private/_evals/<name>/suite/evals.json` with realistic test prompts + fixtures
under `private/_evals/<name>/suite/files/` as needed.

The parallel subagents **do not edit `catalog.yaml`** and **do not write eval
results**. That avoids shared-file conflicts and keeps runtime files separate
from eval artifacts.

### Stage 1b — Register the skills and create result roots (serial orchestrator step)

After all five Stage 1 outputs exist, the main orchestrator updates shared repo
state in one serial edit:

1. Add five `catalog.yaml` entries:

   ```yaml
   - id: kite-planner
     name: kite-planner
     bucket: private
     path: private/kite-planner
     install: true
     evals:
       suite: private/_evals/kite-planner/suite
       results: private/_evals/kite-planner/results
   ```

   Repeat for `kite-research`, `kite-implementation`, `kite-scenario-check`, and
   `kite-feature-review`.

2. Create each empty results directory as `private/_evals/<name>/results/`
   (with `.gitkeep` if needed so the directory is tracked before any benchmark
   output exists).
3. Run a dry-run sync/report check after catalog update:

   ```sh
   ./tools/sync-skills.sh --dry-run
   ./tools/report-skills.sh --no-open
   ```

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

All five are dispatched together (one message, five subagent runs). Shared
template below; per-skill specifics follow.

### Shared prompt template

`````
You are creating a new agent skill in the repo /Users/pranavkanade/Skills.
First invoke the installed `skill-creator` skill (runtime name `skill-creator`)
and follow its conventions for scaffolding a skill whose full SKILL.md content
is ALREADY written (go straight to the scaffold + eval-authoring part of the
loop — do not redraft the body).

Verified repo conventions (mirror private/kite-arch-compass/ and catalog.yaml):
- Runtime skill path: private/<NAME>/SKILL.md
- Runtime bundled references: private/<NAME>/references/*.md
- Eval suite path: private/_evals/<NAME>/suite/evals.json
- Eval fixtures path: private/_evals/<NAME>/suite/files/
- Eval fixture paths in evals.json are relative to the suite directory, e.g.
  "files/example.md"
- Eval results path, used later by the orchestrator: private/_evals/<NAME>/results/
- Do NOT put evals or eval results inside private/<NAME>/.

Your skill: <NAME>

STEP 1 — Scaffold these directories only:
- private/<NAME>/
- private/_evals/<NAME>/suite/
- private/_evals/<NAME>/suite/files/ if fixtures are needed

Do not edit catalog.yaml; the main orchestrator will register all five skills in
one serial edit after parallel generation completes.

STEP 2 — Write SKILL.md VERBATIM. Open
/Users/pranavkanade/Skills/docs/factory/Kite-Skill-Prompts.md and copy the
fenced SKILL.md block for <NAME> (Skill <N>, lines <RANGE>) verbatim into
private/<NAME>/SKILL.md. Copy only the content INSIDE the outer fence — do NOT
include the opening ```md / ````md line or the closing fence line. Preserve
everything else exactly: the YAML frontmatter and any nested code blocks. Do not
edit, rephrase, reflow, or "improve" a single word.

STEP 3 — <plan-file reference: see per-skill note>

STEP 4 — Author private/_evals/<NAME>/suite/evals.json following the repo shape
(study private/_evals/kite-arch-compass/suite/evals.json and
personal/_evals/system-design/suite/evals.json: top-level skill_name and evals[]
with id, optional name, prompt, expected_output, files, expectations[]). Write
2–3 realistic, autonomously-runnable test prompts: <per-skill eval guidance>.
Put any fixture files under private/_evals/<NAME>/suite/files/ and reference
them from evals.json as files/<filename-or-relative-path>. Do NOT execute the
benchmark — only author the suite.

STEP 5 — Validate: confirm SKILL.md frontmatter parses, `name` matches the
directory name, eval fixture paths resolve relative to private/_evals/<NAME>/suite/,
and the tree matches convention. Report the final file tree and any problems.

HARD CONSTRAINTS:
- Do NOT create or modify kite-arch-compass (it already exists).
- Do NOT touch any path other than private/<NAME>/ and private/_evals/<NAME>/suite/.
- Do NOT create private/<NAME>/evals/ or put eval artifacts inside the runtime skill folder.
- Do NOT edit catalog.yaml from the parallel subagent.
- The SKILL.md body must be byte-for-byte the source block (frontmatter
  included). Leave references to kite-arch-compass and other skills as written.
`````

### Per-skill fill-ins

**1. kite-planner** — Skill 1, lines 114–239.

- STEP 3: Create `private/kite-planner/references/plan-file.md` — the canonical
  plan-file definition, assembled from `docs/factory/Kite-Skill-Prompts.md`
  Section 0 as exactly three parts, in this order, copied verbatim:
  1. **State-machine framing** — the paragraph at lines 44–46 ("The plan file is
     a single Markdown document. It doubles as the pipeline's **state
     machine**…").
  2. **Template** — the `### Template` heading and its fenced block, lines 48–97.
  3. **Ownership and status flow** — the `### Ownership and status flow` heading
     and its bullets, lines 99–108.
  Prepend a single `# Plan file` H1 so the file stands on its own; add nothing
  else. **Do NOT include** Section 0's heading or its opening paragraph (lines
  35–43, "This is **not a skill**… single canonical definition.") — that is
  build-time scaffolding guidance for whoever installs the skills, not part of
  the schema the skill reads at runtime. The four skills that bundle this file
  each get a byte-for-byte identical copy.
- STEP 4 evals: given a blueprint + system-design doc fixture, produces a plan
  file that (a) extracts every scenario incl. corner cases as Gherkin, (b)
  orders scenarios for reuse with stated reasoning, (c) writes code-blind
  plans + research questions, (d) sets status `planned`, and **never references
  source code / never asserts what already exists**. Reuse a blueprint+design
  fixture pair from `personal/_evals/blueprint/suite/files/` or
  `personal/_evals/system-design/suite/files/` if present; otherwise author a
  small pair under `private/_evals/kite-planner/suite/files/`.

**2. kite-research** — Skill 2, lines 245–343.

- STEP 3: Same `private/<NAME>/references/plan-file.md` as above.
- STEP 4 evals: given a `planned` plan file + a small codebase fixture, answers
  each research question one-to-one as EXISTS (with file:line + reuse note) or
  MISSING (with extension point), records reuse constraints, raises a BLOCKING
  finding + `blocked` status when the codebase contradicts the plan, and puts
  **only names/locations, never copied source** into the plan file. Provide a
  tiny codebase fixture under `private/_evals/kite-research/suite/files/`.

**3. kite-implementation** — Skill 3, lines 349–431.

- STEP 3: Same `private/<NAME>/references/plan-file.md` as above.
- STEP 4 evals: given a `researched` plan file, works scenarios in order as
  vertical slices, reuses EXISTS / adds at MISSING extension points, tests
  selectively (not exhaustively), runs the arch check + an independent
  scenario-check before each commit, skips `blocked` scenarios, and records the
  implementation record + `committed` status. Capture the limitation that a
  faithful benchmark needs the live appsmith-v2 repo in the eval's
  `expected_output`/`expectations[]` and in the Stage 2 limitation note — do not
  add a non-schema `notes` field to `evals.json`.

**4. kite-scenario-check** — Skill 4, lines 437–501.

- STEP 3: **No plan-file reference** — this skill takes code changes + a Gherkin
  definition directly. Skip STEP 3.
- STEP 4 evals: given one scenario's code changes + its Gherkin, returns PASS or
  FAIL; FAIL ties each gap to the violated Gherkin clause; correctly flags
  scenario drift (added things the scenario never asked for); stays a fast gate
  (no full-feature audit). Provide a passing-case and a failing-case fixture
  pair under `private/_evals/kite-scenario-check/suite/files/`.

**5. kite-feature-review** — Skill 5, lines 507–618. NOTE: this block uses a
**four-backtick** outer fence because it contains nested triple-backtick code
(the report template). Extract the content between the opening four-backtick
`md` fence and the closing four-backtick fence, keeping the inner
triple-backtick report-template block intact.

- STEP 3: Same `private/<NAME>/references/plan-file.md` as above.
- STEP 4 evals: given blueprint + design + full code changes + plan file,
  produces the adversarial review report in the prescribed structure — coverage
  check, orphan-change detection, per-scenario "why it's unacceptable" with
  kite-arch-compass principle citations + a concrete failure Gherkin, and Step-9
  missed-corner-cases beyond the blueprint. Provide a feature fixture
  (blueprint + a deliberately flawed set of code changes) under
  `private/_evals/kite-feature-review/suite/files/`.

---

## Stage 2 — full eval/iterate loop (after Stage 1 + Stage 1b land)

For each skill in priority order (planner & feature-review → scenario-check →
research & implementation):

1. Confirm/finish `private/_evals/<name>/suite/evals.json` assertions (the
   `expectations[]` are the graded criteria), and confirm every path in
   `files[]` exists relative to `private/_evals/<name>/suite/`.
2. For each eval, spawn **with-skill and baseline (without-skill) runs in
   parallel** into the current results layout:

   ```text
   private/_evals/<name>/results/iteration-1/
   └── eval-<id>-<slug>/
       ├── eval_metadata.json
       ├── with_skill/run-1/
       │   ├── outputs/
       │   ├── grading.json
       │   └── timing.json
       └── without_skill/run-1/
           ├── outputs/
           ├── grading.json
           └── timing.json
   ```

3. Grade each run with a grader subagent.
4. Aggregate the iteration with the skill-creator script from its current repo
   path:

   ```sh
   python personal/skill-creator/scripts/aggregate_benchmark.py \
     private/_evals/<name>/results/iteration-1 \
     --skill-name <name> \
     --skill-path private/<name>
   ```

5. Generate the HTML review with the current viewer path and **pause for the
   user to review and supply/save `feedback.json`**:

   ```sh
   python personal/skill-creator/eval-viewer/generate_review.py \
     private/_evals/<name>/results/iteration-1 \
     --skill-name <name>
   ```

   Feedback saves under `private/_evals/<name>/results/iteration-1/feedback.json`.

6. Improve `private/<name>/SKILL.md` from feedback (or bundle a helper if every
   run reinvents the same one), rerun into
   `private/_evals/<name>/results/iteration-2/`, repeat until the user is
   satisfied.

For **research** and **implementation**, before step 2 confirm the live
appsmith-v2 repo is available to point fixtures at; if not, deliver their loops
as authored-but-unrun and record the limitation.

---

## Verification

- **Runtime structure:** each of the five `private/<name>/` directories has
  `SKILL.md`; the four pipeline skills (all but `kite-scenario-check`) have
  `references/plan-file.md`; none has a runtime `evals/` directory.
- **Eval structure:** each skill has
  `private/_evals/<name>/suite/evals.json`; any fixture in `files[]` resolves
  under `private/_evals/<name>/suite/`; each has
  `private/_evals/<name>/results/` ready for benchmark output.
- **Catalog:** `catalog.yaml` contains five private entries with `install: true`,
  `path: private/<name>`, `evals.suite: private/_evals/<name>/suite`, and
  `evals.results: private/_evals/<name>/results`.
- **Existing skill safety:** `private/kite-arch-compass/` and
  `private/_evals/kite-arch-compass/` are untouched.
- **Verbatim check:** diff each new `SKILL.md` body against its source fenced
  block in `docs/factory/Kite-Skill-Prompts.md` — must match exactly
  (frontmatter included).
- **plan-file.md check:** confirm each `references/plan-file.md` contains exactly
  the three parts — state-machine framing, the `### Template` block, and
  `### Ownership and status flow` — preceded only by the `# Plan file` H1, and
  contains **none** of Section 0's "This is **not a skill**…" scaffolding
  paragraph; confirm the four copies are byte-for-byte identical.
- **Frontmatter/validity:** every `SKILL.md` `name:` matches its directory; YAML
  parses. Run:

  ```sh
  python personal/skill-creator/scripts/quick_validate.py private/kite-planner
  python personal/skill-creator/scripts/quick_validate.py private/kite-research
  python personal/skill-creator/scripts/quick_validate.py private/kite-implementation
  python personal/skill-creator/scripts/quick_validate.py private/kite-scenario-check
  python personal/skill-creator/scripts/quick_validate.py private/kite-feature-review
  ```

- **Sync/report check:** after catalog update, run `./tools/sync-skills.sh
  --dry-run` and `./tools/report-skills.sh --no-open` to confirm the new private
  skills are discoverable without linking unexpected paths.
- **Triggering:** after sync, the skills appear in the available-skills list on
  the next session and fire on their intended phrases (e.g. "plan this feature"
  → kite-planner). Spot-check by triggering kite-planner on a sample blueprint.
- **Eval loop (Stage 2):** `benchmark.json` aggregates under
  `private/_evals/<name>/results/iteration-N/`; the review viewer renders
  with-skill vs baseline; with-skill runs measurably satisfy more
  `expectations[]` than baseline for kite-planner and kite-feature-review.
