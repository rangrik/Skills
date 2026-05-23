# Kite Skills Generation Plan

## Summary

Create the five new Kite delivery skills from
`skills-factory/Kite-Skill-Prompts.md` under
`/Users/pranavkanade/Skills/private-skills`:

- `kite-planner`
- `kite-research`
- `kite-implementation`
- `kite-scenario-check`
- `kite-feature-review`

Why: these skills encode a repeatable Kite feature-delivery lifecycle that keeps
design planning, codebase research, implementation, per-scenario verification,
and final adversarial review as separate modes of work. In practice, a human
starts with a blueprint and system design, runs `kite-planner`, enriches the
plan through `kite-research`, implements one vertical scenario at a time with
`kite-implementation`, gates each scenario with `kite-scenario-check`, then runs
`kite-feature-review` for the final report.

`kite-arch-compass` already exists at
`/Users/pranavkanade/Skills/private-skills/kite-arch-compass` and will be
referenced, not recreated.

## Implementation

- Use `skill-creator` for each generated skill.
- Initialize each skill with
  `/Users/pranavkanade/.codex/skills/.system/skill-creator/scripts/init_skill.py`.
- Preserve each fenced `SKILL.md` block from `Kite-Skill-Prompts.md` as the
  behavioral source of truth, making only packaging-level adjustments needed for
  valid skills.
- Add `references/plan-file.md` copied from Section 0 to `kite-planner`,
  `kite-research`, `kite-implementation`, and `kite-feature-review`; do not add
  it to `kite-scenario-check`.
- Generate `agents/openai.yaml` for every skill with only `display_name`,
  `short_description`, and `default_prompt`.
- Do not create README/changelog/extra docs, and do not commit unless explicitly
  asked.

## Exact Subagent Prompts

Dispatch five parallel `worker` subagents with disjoint write scopes.

### `kite-planner`

```text
Use the skill-creator skill at /Users/pranavkanade/.codex/skills/.system/skill-creator/SKILL.md.

You are responsible only for creating/updating /Users/pranavkanade/Skills/private-skills/kite-planner. You are not alone in the codebase; do not revert or modify edits outside this directory, and adapt if files already exist.

Read /Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md. Create the kite-planner skill from the fenced block under "Skill 1 - `kite-planner`". Also copy Section 0, "Shared reference: the plan file", into /Users/pranavkanade/Skills/private-skills/kite-planner/references/plan-file.md because this skill writes the plan file.

Use skill-creator's init_skill.py to initialize the folder with references support and agents/openai.yaml. Use these interface values:
display_name="Kite Planner"
short_description="Create code-blind Kite implementation plans"
default_prompt="Use $kite-planner to turn this Kite blueprint and system design into an ordered implementation plan."

Keep SKILL.md concise and faithful to the source block. Do not add README, changelog, examples, scripts, or assets. Validate with quick_validate.py. Final response: list changed files and the exact validation command/result.
```

### `kite-research`

```text
Use the skill-creator skill at /Users/pranavkanade/.codex/skills/.system/skill-creator/SKILL.md.

You are responsible only for creating/updating /Users/pranavkanade/Skills/private-skills/kite-research. You are not alone in the codebase; do not revert or modify edits outside this directory, and adapt if files already exist.

Read /Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md. Create the kite-research skill from the fenced block under "Skill 2 - `kite-research`". Also copy Section 0, "Shared reference: the plan file", into /Users/pranavkanade/Skills/private-skills/kite-research/references/plan-file.md because this skill reads and updates the plan file.

Use skill-creator's init_skill.py to initialize the folder with references support and agents/openai.yaml. Use these interface values:
display_name="Kite Research"
short_description="Annotate Kite plans with codebase findings"
default_prompt="Use $kite-research to inspect the codebase and annotate this Kite implementation plan."

Keep SKILL.md concise and faithful to the source block. Do not add README, changelog, examples, scripts, or assets. Validate with quick_validate.py. Final response: list changed files and the exact validation command/result.
```

### `kite-implementation`

```text
Use the skill-creator skill at /Users/pranavkanade/.codex/skills/.system/skill-creator/SKILL.md.

You are responsible only for creating/updating /Users/pranavkanade/Skills/private-skills/kite-implementation. You are not alone in the codebase; do not revert or modify edits outside this directory, and adapt if files already exist.

Read /Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md. Create the kite-implementation skill from the fenced block under "Skill 3 - `kite-implementation`". Also copy Section 0, "Shared reference: the plan file", into /Users/pranavkanade/Skills/private-skills/kite-implementation/references/plan-file.md because this skill reads and updates scenario status and implementation records.

Use skill-creator's init_skill.py to initialize the folder with references support and agents/openai.yaml. Use these interface values:
display_name="Kite Implementation"
short_description="Build Kite plans one scenario at a time"
default_prompt="Use $kite-implementation to implement this researched Kite plan scenario by scenario."

Keep SKILL.md concise and faithful to the source block. Do not add README, changelog, examples, scripts, or assets. Validate with quick_validate.py. Final response: list changed files and the exact validation command/result.
```

### `kite-scenario-check`

```text
Use the skill-creator skill at /Users/pranavkanade/.codex/skills/.system/skill-creator/SKILL.md.

You are responsible only for creating/updating /Users/pranavkanade/Skills/private-skills/kite-scenario-check. You are not alone in the codebase; do not revert or modify edits outside this directory, and adapt if files already exist.

Read /Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md. Create the kite-scenario-check skill from the fenced block under "Skill 4 - `kite-scenario-check`". This skill does not need the shared plan-file reference.

Use skill-creator's init_skill.py to initialize the folder with agents/openai.yaml. Use these interface values:
display_name="Kite Scenario Check"
short_description="Verify one Kite scenario before commit"
default_prompt="Use $kite-scenario-check to verify these code changes against this Gherkin scenario."

Keep SKILL.md concise and faithful to the source block. Do not add README, changelog, examples, scripts, references, or assets. Validate with quick_validate.py. Final response: list changed files and the exact validation command/result.
```

### `kite-feature-review`

```text
Use the skill-creator skill at /Users/pranavkanade/.codex/skills/.system/skill-creator/SKILL.md.

You are responsible only for creating/updating /Users/pranavkanade/Skills/private-skills/kite-feature-review. You are not alone in the codebase; do not revert or modify edits outside this directory, and adapt if files already exist.

Read /Users/pranavkanade/Skills/skills-factory/Kite-Skill-Prompts.md. Create the kite-feature-review skill from the fenced block under "Skill 5 - `kite-feature-review`". Also copy Section 0, "Shared reference: the plan file", into /Users/pranavkanade/Skills/private-skills/kite-feature-review/references/plan-file.md because this skill reads the plan file during final review.

Use skill-creator's init_skill.py to initialize the folder with references support and agents/openai.yaml. Use these interface values:
display_name="Kite Feature Review"
short_description="Run adversarial Kite feature reviews"
default_prompt="Use $kite-feature-review to audit this completed Kite feature against its blueprint and design."

Keep SKILL.md concise and faithful to the source block. Do not add README, changelog, examples, scripts, or assets. Validate with quick_validate.py. Final response: list changed files and the exact validation command/result.
```

## Integration And Test Plan

- Wait for all five workers, then inspect the changed file lists and validation
  output.
- Confirm each generated skill has valid `SKILL.md` frontmatter with only `name`
  and `description`.
- Confirm `agents/openai.yaml` exists and names the correct `$skill-name` in
  `default_prompt`.
- Confirm the shared `references/plan-file.md` is byte-for-byte equivalent
  across the four skills that need it.
- Run `quick_validate.py` against each skill folder again from the parent
  session.
- Run `find /Users/pranavkanade/Skills/private-skills -maxdepth 2 -type f` to
  verify no extra docs or unrelated files were created.
- Do a final read-through of all five `SKILL.md` files to confirm the pipeline
  boundaries remain intact: planner code-blind, research read-only,
  implementation scenario-by-scenario, scenario-check focused, feature-review
  adversarial.

## Assumptions

- "All skills mentioned in the file" means the five new skills in
  `Kite-Skill-Prompts.md`; `kite-arch-compass` is intentionally excluded because
  the file says it already exists and must not be recreated.
- The install location is `/Users/pranavkanade/Skills/private-skills`.
- The first pass should generate and validate the skills, not commit them or run
  full forward-testing.
