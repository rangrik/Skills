# Repository Restructure Suggestion

## Goal

Restructure this repo around a self-learning skill-improvement loop where **everything is committed**: skill source, eval definitions, eval fixtures, generated run outputs, grading artifacts, review reports, and daily summaries.

The repo should become both:

1. the source of truth for the skills, and
2. the historical learning journal showing how those skills improved over time.

Because of that goal, the structure should not treat generated eval outputs as disposable. They should be organized clearly and committed intentionally.

## Core Principles

### 1. Commit everything

Do not hide learning-loop artifacts in `.gitignore`. If a run produces inputs, outputs, reports, grading, feedback, or summaries, those files should be committed so the system can compare progress over time.

Recommended policy:

- Keep `.gitignore` empty, or remove it.
- Do not ignore `*-workspace/`, eval reports, feedback JSON, run outputs, timing files, or generated HTML.
- Prefer moving generated outputs into a clear committed location instead of ignoring them.

### 2. Separate by purpose, not by whether Git tracks it

Everything is tracked, but directories should still clearly communicate intent:

- `evals/` = reusable eval definitions
- `fixtures/` = reusable eval inputs
- `runs/` = historical execution artifacts
- `reports/` = human-readable summaries and trend analysis
- `docs/` = durable research, guides, and design notes
- skill directories = executable/publishable skill source

### 3. Preserve public skill paths for now

The current README advertises install paths like:

```sh
npx skills add rangrik/Skills/blueprint
npx skills add rangrik/Skills
```

Because of that, the least disruptive structure keeps public skills at the repo root for now:

```text
blueprint/
system-design/
```

A future cleanup could move skills under `skills/public/`, but that should only happen if the publishing/install workflow is updated at the same time.

### 4. Keep private/internal skills explicit

Private or local-only skills should stay separate from public skills:

```text
private-skills/
```

The sync script should ideally make private skill linking opt-in, so local/internal guidance is not accidentally treated as public publishing material.

### 5. Make daily learning runs reproducible

Each learning-loop run should capture enough context to reproduce and understand it later:

- what skill version ran
- what commit it started from
- what model/provider ran it
- what eval definitions and fixtures were used
- what outputs were produced
- how grading/review judged those outputs
- what improvement was made afterward
- whether the next run improved or regressed

## Proposed Structure

Recommended path-preserving target layout:

```text
README.md
PUBLICATION.md
restructure-suggestion.md

blueprint/
  SKILL.md
  references/
  evals/
    evals.json
    fixtures/

system-design/
  SKILL.md
  references/
  evals/
    evals.json
    fixtures/

private-skills/
  backend-standards/
    SKILL.md
    references/
    evals/
      fixtures/
  kite-arch-compass/
    SKILL.md
    references/
    evals/
      evals.json
      fixtures/

docs/
  guides/
  research/
  factory/

eval-runs/
  2026-05-23/
    loop-001/
      manifest.json
      blueprint/
        inputs/
        outputs/
        grading/
        reports/
      system-design/
        inputs/
        outputs/
        grading/
        reports/
      daily-summary.md

reports/
  daily/
  trends/

scripts/
  sync-skills.sh
  run-learning-loop.sh
```

## Migration Recommendations

### Phase 1 — Make tracking policy explicit

- Empty or remove `.gitignore`.
- Add a README section explaining that generated learning-loop artifacts are intentionally committed.
- Add `PUBLICATION.md` describing what is public, private, experimental, and generated-but-committed.

### Phase 2 — Stabilize eval inputs

Move reusable eval fixtures into each skill's `evals/fixtures/` directory.

For example, `system-design/evals/evals.json` should reference:

```text
system-design/evals/fixtures/github-contributions-blueprint.md
system-design/evals/fixtures/saved-views-blueprint.md
system-design/evals/fixtures/weekly-digest-blueprint.md
system-design/evals/fixtures/announcement-banner-blueprint.md
system-design/evals/fixtures/collab-cursors-blueprint.md
```

instead of referencing files inside a generated workspace.

### Phase 3 — Consolidate generated artifacts

Move historical/generated run outputs into `eval-runs/` using a date and loop ID:

```text
eval-runs/YYYY-MM-DD/loop-001/<skill-name>/...
```

This replaces the current split between directories like:

```text
evals-results/
system-design-workspace/
```

Those can be preserved as legacy folders temporarily, but the target should be one committed run-history tree.

### Phase 4 — Move durable non-skill docs under `docs/`

Suggested moves:

```text
guides/         -> docs/guides/
research/       -> docs/research/
skills-factory/ -> docs/factory/
```

This keeps root-level space focused on installable skills, scripts, reports, and run history.

### Phase 5 — Move scripts under `scripts/`

Suggested move:

```text
sync-skills.sh -> scripts/sync-skills.sh
```

If root-level convenience matters, keep a tiny root wrapper that calls the script in `scripts/`.

### Phase 6 — Improve private-skill sync behavior

Update the sync flow so private skills are linked only when explicitly requested:

```sh
./scripts/sync-skills.sh --include-private
```

This reduces the chance of internal skills leaking into public workflows by accident.

## Daily Commit Pattern

A self-learning loop should create a readable commit sequence. A good daily pattern is:

```text
eval: record 2026-05-23 baseline results
improve(system-design): tighten decision coverage workflow
eval: record 2026-05-23 post-change results
report: summarize 2026-05-23 learning loop
```

This gives the repo a useful historical rhythm:

1. show the previous behavior,
2. make the skill improvement,
3. show the measured effect,
4. summarize what was learned.

## Run Artifact Shape

Each run should include:

```text
manifest.json
inputs/
outputs/
grading/
reports/
notes.md
```

Recommended `manifest.json` fields:

```json
{
  "date": "2026-05-23",
  "loop_id": "loop-001",
  "starting_commit": "<git-sha>",
  "ending_commit": "<git-sha-if-known>",
  "skills_tested": ["blueprint", "system-design"],
  "model": "<model-name>",
  "eval_command": "<command-used>",
  "summary": "<one-sentence-summary>"
}
```

## Canonical Reference Policy

Some reference material may exist both globally and inside a skill's `references/` directory. For runtime reliability, the skill-local copy should be treated as the executable copy: if a skill needs a reference to function, that reference should live inside that skill.

If a global copy is also useful for browsing or authoring, either:

- make the skill-local copy canonical and link to it from `docs/`, or
- make the `docs/` copy canonical and add a script/check that syncs it into the skill before publishing.

Avoid silent duplication where two copies can drift without detection.

## Top-Level and Second-Level Directory Context for Agents

This section is intended for future agents reading the repo. Use it to decide where to put new files or what to update.

### `README.md`

Root overview for humans and agents. Update this when the public purpose of the repo, install instructions, or high-level repository layout changes.

### `PUBLICATION.md`

Proposed policy document for what is public, private, experimental, generated, or safe to publish. Update this when adding a new skill, changing publishing paths, or changing private/public boundaries.

### `restructure-suggestion.md`

This document. It records the proposed target structure and migration plan. Update it if the structure decision changes before migration is complete.

### `blueprint/`

Public skill directory for the `blueprint` skill. Keep this at the repo root unless the public publishing path is intentionally changed.

#### `blueprint/SKILL.md`

The executable prompt/instructions for the `blueprint` skill. Update this when changing how the behavior-blueprint skill works.

#### `blueprint/references/`

Runtime references used by the `blueprint` skill. Put supporting templates, taxonomies, style guides, and other skill-required documents here.

#### `blueprint/evals/`

Reusable eval definitions and inputs for the `blueprint` skill. Put eval cases in `evals.json` and reusable input files under `fixtures/`.

#### `blueprint/evals/fixtures/`

Tracked input fixtures used by blueprint evals. Put stable prompts, source docs, sample PRDs, or other reusable eval inputs here.

### `system-design/`

Public skill directory for the `system-design` skill. Keep this at the repo root unless the public publishing path is intentionally changed.

#### `system-design/SKILL.md`

The executable prompt/instructions for the `system-design` skill. Update this when changing the system-design workflow.

#### `system-design/references/`

Runtime references used by the `system-design` skill, such as decision taxonomies, design principles, and design-document templates.

#### `system-design/evals/`

Reusable eval definitions and inputs for the `system-design` skill. Eval definitions should not depend on generated workspace paths.

#### `system-design/evals/fixtures/`

Tracked blueprint/input fixtures used by system-design evals. Move any reusable files currently living in workspaces into this directory.

### `private-skills/`

Container for local/internal skills that are not intended to be public skills.sh publishing targets by default. Put private or repo-specific skills here.

#### `private-skills/backend-standards/`

Private skill for backend coding standards. Update this when backend conventions change or when new backend standards are documented.

#### `private-skills/backend-standards/SKILL.md`

Executable instructions for the backend standards skill.

#### `private-skills/backend-standards/references/`

Supporting backend-standard references, examples, and pattern documents.

#### `private-skills/backend-standards/evals/`

Optional eval definitions and fixtures for the backend standards skill.

#### `private-skills/kite-arch-compass/`

Private/reference skill for Kite/appsmith-v2 architecture principles and conformance checks.

#### `private-skills/kite-arch-compass/SKILL.md`

Executable instructions for architecture guidance and conformance review.

#### `private-skills/kite-arch-compass/references/`

Runtime architecture principle catalogues and conformance checklists required by the skill.

#### `private-skills/kite-arch-compass/evals/`

Reusable eval definitions and fixtures for the architecture compass skill.

### `docs/`

Durable documentation that is not itself an executable skill. Put research, guides, design notes, and factory/planning docs here.

#### `docs/guides/`

Curated, durable guides and reference documents. Put polished docs here, not raw run artifacts.

#### `docs/research/`

Research notes and synthesized studies that inform future skills or standards. Put exploratory but durable research here.

#### `docs/factory/`

Skill-factory notes, draft skill architectures, lifecycle designs, and generated skill prompt drafts. Put proposed future-skill design work here.

### `eval-runs/`

Committed historical outputs from self-learning/eval loops. Put generated run artifacts here instead of hiding them in ignored workspaces.

#### `eval-runs/YYYY-MM-DD/`

All learning-loop runs for a specific date.

#### `eval-runs/YYYY-MM-DD/loop-NNN/`

One complete learning-loop iteration. Each loop should include a manifest, per-skill artifacts, and a summary.

#### `eval-runs/YYYY-MM-DD/loop-NNN/manifest.json`

Machine-readable record of the run: date, loop ID, commit SHA, model, commands, skills tested, and summary.

#### `eval-runs/YYYY-MM-DD/loop-NNN/<skill-name>/inputs/`

Exact inputs used for that skill during this run. These are run-specific copies, even if they came from reusable fixtures.

#### `eval-runs/YYYY-MM-DD/loop-NNN/<skill-name>/outputs/`

Outputs produced by the skill during the run.

#### `eval-runs/YYYY-MM-DD/loop-NNN/<skill-name>/grading/`

Raw grading artifacts, scorer outputs, pass/fail judgments, and machine-readable evaluation results.

#### `eval-runs/YYYY-MM-DD/loop-NNN/<skill-name>/reports/`

Generated human-readable review artifacts such as markdown reports, HTML reviews, screenshots, or summaries.

### `reports/`

Curated summaries derived from committed run artifacts. Put human-facing daily and trend reports here.

#### `reports/daily/`

One markdown summary per day. Use this for daily learning-loop summaries and human-readable progress notes.

#### `reports/trends/`

Longer-running trend analysis across days or skills. Use this to track whether a skill is improving, regressing, or changing behavior.

### `scripts/`

Local automation scripts. Put sync scripts, run-loop scripts, eval runners, report generators, and maintenance checks here.

#### `scripts/sync-skills.sh`

Script for linking local skill directories into agent skill stores. Should ideally link private skills only when explicitly requested.

#### `scripts/run-learning-loop.sh`

Proposed script for running the daily self-learning loop. It should create committed artifacts under `eval-runs/` and update reports.

### `evals-results/`

Current legacy location for generated eval results. Target state: migrate this content into `eval-runs/` using date/loop structure, then stop writing new artifacts here.

### `system-design-workspace/`

Current legacy/generated workspace for system-design evals. Target state: move reusable fixtures into `system-design/evals/fixtures/` and generated run artifacts into `eval-runs/`.

### `guides/`

Current legacy location for durable guides. Target state: move this content into `docs/guides/`.

### `research/`

Current legacy location for research notes. Target state: move this content into `docs/research/`.

### `skills-factory/`

Current legacy location for skill-factory drafts and raw notes. Target state: move this content into `docs/factory/`.

### `sync-skills.sh`

Current root-level sync script. Target state: move to `scripts/sync-skills.sh`, optionally keeping a root wrapper for convenience.

### `.gitignore`

Target state: empty or removed. This repo intentionally commits learning-loop artifacts, including generated outputs, so agents should not add new ignore rules unless the project policy changes.
