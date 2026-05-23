# Repository Restructure Suggestion

_Last reviewed: 2026-05-23_

## Goal

Maintain this repository as a long-lived home for agent skills and the learning
history around those skills.

The repo should serve two jobs at the same time:

1. **Source of truth for executable skills** — public skills, private skills,
   draft skills, and reference/vendor skill material are easy to distinguish.
2. **Historical learning journal** — eval definitions, fixtures, run outputs,
   grading artifacts, review reports, and summaries are preserved so skill
   quality can be compared over time.

Because of that second goal, generated eval outputs should not be treated as
throwaway build artifacts. They should be tracked intentionally and organized so
future maintainers can tell what was run, why, and what changed afterward.

## Current State Snapshot

The repo has already moved beyond the previous version of this document. Current
state:

| Path | Current role | Long-term note |
| --- | --- | --- |
| `blueprint/` | Public root skill. README advertises `npx skills add rangrik/Skills/blueprint`. | Keep at root unless the public publishing/install path changes. |
| `system-design/` | Public root skill with references and eval definitions. | Keep at root. Fix eval fixture paths; current `files` point at workspace-style inputs. |
| `private-skills/kite-arch-compass/` | Private/internal Kite architecture skill with evals and references. | Keep separate from public root skills. |
| `wip/backend-standards/` | Draft/WIP backend standards skill. | Do not sync or publish by default. Promote to `private-skills/` only when ready. |
| `by-anthropic/skill-creator/` | Tracked reference/vendor copy of Anthropic's skill creator. | Treat as reference material, not a repo-published skill. Current sync script ignores `by-anthropic`. |
| `by-openai/skill-creator/` | Tracked reference/vendor copy of OpenAI's skill creator. | Treat as reference material, not a repo-published skill. Current sync script ignores `by-openai`. |
| `evals-results/` | Tracked historical eval outputs for `blueprint`, `system-design`, and `kite-arch-compass`. | Preserve. New runs should move toward a normalized `eval-runs/` shape. |
| `guides/` | Durable guide material. | Target: `docs/guides/`. |
| `research/` | Durable research notes. | Target: `docs/research/`. |
| `skills-factory/` | Active skill-factory planning workspace: generation/build plans, prompt drafts, lifecycle diagram, raw notes, and a comparison/gap analysis for future Kite pipeline skills. | Target: `docs/factory/`; decide where `raw` and the untracked comparison doc belong. |
| `sync-skills.sh` | Links repo skills into local agent skill stores. | Move to `scripts/`, keep root wrapper if desired. Default should become public-only. |
| `uninstall-skills.sh` | Removes installed repo skills from local agent skill stores. | Move to `scripts/`, keep root wrapper if desired. Keep discovery rules in sync with `sync-skills.sh`. |
| `.gitignore` | Currently only ignores `.DS_Store`. | Good direction: keep minimal local-junk ignores only; do not ignore eval artifacts. |
| `archive/` | Empty placeholder. | Remove if unused, or add `archive/README.md` explaining what belongs there. |

## Core Principles

### 1. Classify every top-level area by purpose

Every directory should clearly be one of these categories:

- **Public skill** — installable/publishable skill source.
- **Private skill** — executable locally/internal to a project, not public by default.
- **WIP skill** — draft skill that should not be synced or published by default.
- **Vendor/reference material** — copied examples or external skill creators used for study.
- **Reusable eval material** — stable eval definitions and fixtures.
- **Historical run output** — generated but intentionally committed run artifacts.
- **Durable docs** — research, guides, and design notes.
- **Automation** — scripts that maintain, sync, test, or report on the repo.

This is more important than whether a file was human-written or generated.

### 2. Preserve public skill paths for now

The README currently advertises root-level install paths such as:

```sh
npx skills add rangrik/Skills/blueprint
npx skills add rangrik/Skills
```

Keep public skills at the repo root until the publishing story is deliberately
changed:

```text
blueprint/
system-design/
```

If the repo-wide install command would expose nested/vendor/private skills, stop
advertising it or add a publishing guard before relying on it long term.

### 3. Keep private, WIP, and vendor material visibly separate

The repo now has three kinds of non-public skill-shaped content:

```text
private-skills/kite-arch-compass/
wip/backend-standards/
by-anthropic/skill-creator/
by-openai/skill-creator/
```

Do not let these collapse into one bucket. They have different maintenance
rules:

- `private-skills/` can be executable locally, but should be opt-in for sync.
- `wip/` is draft material and should never sync by default.
- `by-anthropic/` and `by-openai/` are vendor/reference material and should never
  sync or publish as this repo's skills.

### 4. Track learning artifacts intentionally

The current repo already tracks eval outputs under `evals-results/`. Keep that
policy. A run's outputs, grading, timing, benchmark files, review HTML, feedback,
and summaries are part of the learning record.

Recommended ignore policy:

- Keep `.gitignore` minimal.
- Ignore local machine junk such as `.DS_Store`.
- Do **not** ignore `evals-results/`, future `eval-runs/`, reports, grading JSON,
  timing files, generated markdown, or review HTML.
- Prefer moving generated outputs into a clear committed location instead of
  hiding them.

### 5. Separate reusable eval inputs from historical run outputs

A stable eval definition should not depend on a generated workspace path.

Reusable material belongs near the skill:

```text
system-design/evals/evals.json
system-design/evals/fixtures/*.md
private-skills/kite-arch-compass/evals/evals.json
private-skills/kite-arch-compass/evals/fixtures/*
```

Run-specific copies and generated outputs belong in run history:

```text
evals-results/        # current legacy history
eval-runs/            # recommended normalized history for new runs
```

### 6. Avoid silent duplicate sources of truth

Some reference material exists both globally and inside a skill, for example the
Kite engineering principles guide under `guides/` and the copied runtime version
under `private-skills/kite-arch-compass/references/`.

Pick one canonical source for each duplicated reference:

- If the skill needs the file at runtime, make the skill-local copy canonical and
  link to it from docs; or
- if the docs copy is canonical, add a sync/check script that copies it into the
  skill before publishing or local sync.

Do not allow two independent copies to drift silently.

## Recommended Target Layout

Path-preserving target layout for the next phase:

```text
README.md
PUBLICATION.md
restructure-suggestion.md
.gitignore

blueprint/
  SKILL.md
  references/
  evals/
    evals.json
    fixtures/                 # optional; blueprint currently uses inline prompts

system-design/
  SKILL.md
  references/
  evals/
    evals.json
    fixtures/                 # stable blueprint/input fixtures

private-skills/
  kite-arch-compass/
    SKILL.md
    references/
    evals/
      evals.json
      fixtures/
  kite-planner/               # planned, if generated from skills-factory
  kite-research/              # planned, if generated from skills-factory
  kite-implementation/        # planned, if generated from skills-factory
  kite-scenario-check/        # planned, if generated from skills-factory
  kite-feature-review/        # planned, if generated from skills-factory

wip/
  backend-standards/
    SKILL.md
    patterns.md
    evals/                    # add before promotion, if useful

vendor/                       # target name; current paths are by-anthropic/by-openai
  anthropic/skill-creator/
  openai/skill-creator/

docs/
  guides/
  research/
  factory/

evals-results/                # current tracked legacy history; keep until deliberately migrated

eval-runs/
  2026-05-23/
    loop-001/
      manifest.json
      summary.md
      blueprint/
      system-design/
      kite-arch-compass/

reports/
  daily/
  trends/

scripts/
  sync-skills.sh
  uninstall-skills.sh
  run-learning-loop.sh
  validate-repo.sh

archive/                      # remove if unused; otherwise document policy
```

Do not move public root skills (`blueprint/`, `system-design/`) until the README,
publishing workflow, and any skills.sh expectations are updated together.

## Migration Recommendations

### Phase 1 — Document boundaries before moving files

Add `PUBLICATION.md` with a simple classification table:

- Public skills: `blueprint/`, `system-design/`.
- Private skills: `private-skills/kite-arch-compass/`.
- WIP skills: `wip/backend-standards/`.
- Vendor/reference copies: `by-anthropic/skill-creator/`,
  `by-openai/skill-creator/`.
- Generated-but-committed history: `evals-results/`.
- Durable docs: `guides/`, `research/`, `skills-factory/`.

Update `README.md` so it does not imply every `SKILL.md`-shaped thing in the repo
is public. At minimum, list both public skills and point private/WIP/vendor
readers to `PUBLICATION.md`.

### Phase 2 — Harden skill discovery and local sync

Current `sync-skills.sh` links root skills and private skills by default, while
ignoring `by-anthropic` and `by-openai`. For long-term safety, change the default
behavior:

```sh
./scripts/sync-skills.sh                  # public root skills only
./scripts/sync-skills.sh --include-private # also link private-skills/*
./scripts/sync-skills.sh --include-wip     # optional; explicit only
```

Recommended script improvements:

- Move `sync-skills.sh` and `uninstall-skills.sh` under `scripts/`.
- Keep tiny root wrappers if convenience matters.
- Share one discovery function between sync and uninstall so they cannot drift.
- Refuse to link duplicate skill names unless the user explicitly chooses one.
  This matters because both vendor copies are named `skill-creator`.
- Never link or uninstall from vendor/reference directories.
- Add `scripts/validate-repo.sh` to check classification rules, duplicate skill
  names, eval fixture paths, and accidental generated-artifact ignores.

### Phase 3 — Stabilize eval fixtures

Keep `evals-results/` as historical run output, but stop using it as a source of
reusable eval input.

Immediate fixture work:

- Copy stable system-design blueprint inputs from current historical outputs into
  `system-design/evals/fixtures/`:
  - `github-contributions-blueprint.md`
  - `saved-views-blueprint.md`
  - `weekly-digest-blueprint.md`
  - `announcement-banner-blueprint.md`
  - `collab-cursors-blueprint.md`
- Update `system-design/evals/evals.json` so `files` points at those fixtures,
  not workspace-style paths.
- Rename `private-skills/kite-arch-compass/evals/files/` to
  `private-skills/kite-arch-compass/evals/fixtures/` for consistency, then update
  paths in its eval definitions if needed.
- Keep `blueprint/evals/evals.json` as-is unless prompts grow large enough to
  deserve fixture files.

### Phase 4 — Normalize future eval run history

Current history lives in:

```text
evals-results/blueprint-workspace/
evals-results/system-design-workspace/
evals-results/kite-arch-compass-workspace/
```

That history is useful and should stay committed. Do not delete it just because
it is generated.

For new runs, prefer a normalized date/loop structure:

```text
eval-runs/YYYY-MM-DD/loop-NNN/
  manifest.json
  summary.md
  <skill-name>/
    benchmark.json
    benchmark.md
    review.html
    feedback.json              # if produced
    <eval-case>/
      eval_metadata.json
      inputs/
      with_skill/
        run-1/
          outputs/
          grading.json
          timing.json
      without_skill/
        run-1/
          outputs/
          grading.json
          timing.json
      recheck/                 # optional ad-hoc follow-up runs
      verify/                  # optional verification runs
```

Preserve the current with-skill/without-skill comparison shape because it makes
skill impact easy to inspect later.

Migration options:

1. **Low risk:** keep `evals-results/` as legacy history and write only new runs
   to `eval-runs/`.
2. **Cleaner but noisier:** migrate old history into `eval-runs/` with a manifest
   explaining the original paths.

Recommendation: choose option 1 first. It avoids churn while establishing the
future convention.

### Phase 5 — Consolidate durable docs

Move durable non-skill docs under `docs/`:

```text
guides/         -> docs/guides/
research/       -> docs/research/
skills-factory/ -> docs/factory/
```

Specific decisions to make during this move:

- Convert or rename `skills-factory/raw` so its purpose is obvious, for example
  `docs/factory/raw-implementation-skill-notes.md`.
- Decide whether `skills-factory/Kite-Skills-Plans-Comparison.md` should be
  committed and moved to `docs/factory/`.
- Keep the Kite pipeline skill-generation plans together: prompts, build plan,
  generation plan, lifecycle diagram, and comparison/gap analysis should live in
  one `docs/factory/kite-pipeline-skills/` cluster if they remain active.
- Resolve canonical ownership for `engineering-principles-contract.md` so the
  docs copy and the `kite-arch-compass` runtime copy cannot drift.

### Phase 6 — Clean up vendor/reference copies

The current vendor/reference directories are:

```text
by-anthropic/skill-creator/
by-openai/skill-creator/
```

They are useful for study, but risky as executable skills because both contain a
`SKILL.md` and both use the skill name `skill-creator`.

Recommended target:

```text
vendor/anthropic/skill-creator/
vendor/openai/skill-creator/
```

Then make the policy explicit:

- Vendor directories are tracked reference material.
- Vendor directories are never linked by local sync.
- Vendor directories are never treated as public skills from this repo.
- If copied vendor code is modified, note whether it is still a faithful copy or
  a local adaptation.

If the external skills publishing tool recursively discovers nested `SKILL.md`
files, either add a supported publication ignore mechanism or stop advertising
repo-wide install until the behavior is safe.

### Phase 7 — Treat planned Kite pipeline skills as private until proven otherwise

The factory docs currently plan five additional Kite pipeline skills:

```text
kite-planner
kite-research
kite-implementation
kite-scenario-check
kite-feature-review
```

If those plans are executed, create them under `private-skills/` first, alongside
`kite-arch-compass`, not at the repo root. They are project-specific workflow
skills, not public skills by default.

Long-term rules for these planned skills:

- Each generated skill should have `SKILL.md`, `references/`, and `evals/` if it
  is intended to be maintained.
- Shared runtime references such as `references/plan-file.md` should either be
  byte-for-byte identical across the skills or generated from one canonical
  source.
- Evals should use `evals/fixtures/` for stable inputs and write historical
  outputs to `eval-runs/`, not back into the factory docs.
- `PUBLICATION.md` and sync discovery must be updated before these skills are
  linked locally.
- Once the skills are generated and validated, mark the corresponding factory
  docs as completed, superseded, or still active so future agents do not rerun an
  obsolete plan.

### Phase 8 — Decide the fate of `wip/backend-standards`

Current state: `wip/backend-standards/` is a draft skill with `SKILL.md` and
`patterns.md`.

Keep it under `wip/` until one of these decisions is made:

- **Promote to private:** move to `private-skills/backend-standards/`, add evals,
  and allow opt-in local sync.
- **Promote to public:** move to root `backend-standards/`, update README and
  publication docs, and add public-facing evals/references.
- **Archive:** move to `archive/backend-standards/` with a note explaining why it
  is no longer active.

Do not let WIP skills be synced by default. Draft trigger descriptions can fire
in surprising contexts and pollute day-to-day agent behavior.

### Phase 9 — Add reports as curated summaries

Raw run artifacts answer "what happened?" Reports answer "what did we learn?"
Add:

```text
reports/daily/
reports/trends/
```

A daily report should link to the relevant `eval-runs/` or `evals-results/`
artifacts and summarize:

- baseline behavior,
- skill changes made,
- post-change behavior,
- regressions,
- open follow-ups.

## Daily Commit Pattern

A useful learning-loop history has a readable commit rhythm:

```text
eval: record 2026-05-23 baseline results
improve(system-design): tighten decision coverage workflow
eval: record 2026-05-23 post-change results
report: summarize 2026-05-23 learning loop
```

This sequence keeps causality clear:

1. show previous behavior,
2. make the skill improvement,
3. show measured effect,
4. summarize what was learned.

## Run Manifest Shape

Every normalized run should include a `manifest.json` like:

```json
{
  "date": "2026-05-23",
  "loop_id": "loop-001",
  "starting_commit": "<git-sha>",
  "ending_commit": "<git-sha-if-known>",
  "skills_tested": ["blueprint", "system-design"],
  "model": "<model-name>",
  "eval_command": "<command-used>",
  "runner": "<script-or-tool>",
  "artifacts_root": "eval-runs/2026-05-23/loop-001",
  "summary": "<one-sentence-summary>"
}
```

For migrated legacy runs, add:

```json
{
  "migrated_from": "evals-results/system-design-workspace/iteration-2",
  "migration_note": "Original tracked eval output preserved under normalized run history."
}
```

## Agent Placement Guide

Use this section when deciding where to put new files.

### Root files

#### `README.md`

Human-facing overview and public install instructions. Update when public skills,
install commands, or the high-level repo purpose changes.

#### `PUBLICATION.md` _(proposed)_

Classification policy for public, private, WIP, vendor/reference, generated, and
durable-doc content. Update whenever a skill changes classification.

#### `restructure-suggestion.md`

This document. Update when the structure decision changes or the current-state
snapshot becomes stale.

#### `.gitignore`

Minimal local-junk ignore list. Do not add generated eval/run/report paths unless
the repo's learning-history policy changes.

### Public skills

#### `blueprint/`

Public behavior-blueprint skill. Keep at root while `rangrik/Skills/blueprint`
is an advertised install path.

- `blueprint/SKILL.md` — executable skill prompt/instructions.
- `blueprint/references/` — runtime references required by the skill.
- `blueprint/evals/evals.json` — reusable eval definitions.
- `blueprint/evals/fixtures/` — optional stable fixture files if future evals need
  larger inputs.

#### `system-design/`

Public system-design skill. Keep at root while repo root contains public skills.

- `system-design/SKILL.md` — executable skill prompt/instructions.
- `system-design/references/` — runtime design taxonomies, principles, and
  templates.
- `system-design/evals/evals.json` — reusable eval definitions.
- `system-design/evals/fixtures/` — stable blueprint/input fixtures. This should
  replace references to generated workspace paths.

### Private skills

#### `private-skills/kite-arch-compass/`

Private Kite/appsmith-v2 architecture compass skill.

- `SKILL.md` — executable guidance and conformance-review workflow.
- `references/` — runtime engineering principles and conformance checklists.
- `evals/evals.json` — reusable eval definitions.
- `evals/fixtures/` — target home for files currently under `evals/files/`.

#### Planned Kite pipeline private skills

If generated from the factory docs, place `kite-planner`, `kite-research`,
`kite-implementation`, `kite-scenario-check`, and `kite-feature-review` under
`private-skills/`. Keep their shared references canonical and update
`PUBLICATION.md` plus sync discovery before linking them into local agent stores.

### WIP skills

#### `wip/backend-standards/`

Draft backend standards skill. Keep here while it is experimental.

- Do not sync by default.
- Add a short status note if it remains WIP for long.
- Promote to `private-skills/backend-standards/` or root `backend-standards/` only
  when its audience and publication policy are clear.

### Vendor/reference material

#### `by-anthropic/skill-creator/` and `by-openai/skill-creator/`

Current tracked vendor/reference copies. They should not be installed or
published as this repo's skills.

Target path if moved:

```text
vendor/anthropic/skill-creator/
vendor/openai/skill-creator/
```

If these stay in place, keep them in every script's ignore list and document the
reason in `PUBLICATION.md`.

### Durable docs

#### `guides/` -> `docs/guides/`

Polished durable guides and contracts.

#### `research/` -> `docs/research/`

Research notes and synthesized studies that inform skills or architecture
standards.

#### `skills-factory/` -> `docs/factory/`

Skill-factory plans, prompt drafts, lifecycle diagrams, raw notes, and
comparisons. The current active cluster is the Kite pipeline skill work: prompts,
build/generation plans, lifecycle diagram, and plan comparison/gap analysis.

### Eval history

#### `evals-results/`

Current tracked legacy run history. Preserve it unless deliberately migrated.
Do not write new ad-hoc output shapes here once `eval-runs/` exists.

Current workspaces:

- `evals-results/blueprint-workspace/`
- `evals-results/system-design-workspace/`
- `evals-results/kite-arch-compass-workspace/`

#### `eval-runs/` _(proposed)_

Normalized future run history. Use date and loop IDs, include a manifest, and
preserve per-skill benchmark/review artifacts plus per-eval run outputs.

### Reports

#### `reports/daily/` _(proposed)_

One human-readable learning-loop summary per day.

#### `reports/trends/` _(proposed)_

Longer-running trend analysis across days, skills, models, or eval suites.

### Scripts

#### `sync-skills.sh` -> `scripts/sync-skills.sh`

Links local repo skills into agent skill stores. Target default: public root
skills only, with explicit flags for private and WIP skills.

#### `uninstall-skills.sh` -> `scripts/uninstall-skills.sh`

Removes installed repo skills from local agent stores. Must use the same skill
discovery and classification rules as sync.

#### `scripts/run-learning-loop.sh` _(proposed)_

Runs evals, writes normalized artifacts under `eval-runs/`, and updates reports.

#### `scripts/validate-repo.sh` _(proposed)_

Checks repo invariants: no accidental ignored eval artifacts, no duplicate public
skill names, no fixture paths into historical run directories, and no vendor/WIP
skills in default sync discovery.

### Archive

#### `archive/`

Currently empty. Either remove it or add a README defining it as the place for
frozen, no-longer-active material that should remain tracked for historical
context.

## Immediate Recommended Next Steps

1. Add `PUBLICATION.md` before moving directories.
2. Update `README.md` to list current public skills and clarify non-public areas.
3. Make `sync-skills.sh` public-only by default, with explicit private/WIP flags.
4. Create `system-design/evals/fixtures/` and update stale eval file paths.
5. Decide whether to keep `evals-results/` as frozen legacy history or migrate it
   after `eval-runs/` exists.
6. Move durable docs under `docs/` once publication boundaries are documented.
7. Keep the Kite pipeline skill-factory docs together, and if the planned skills
   are generated, put them under `private-skills/` first.
8. Decide whether `wip/backend-standards/` should be promoted, kept WIP, or
   archived.
