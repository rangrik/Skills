# Skills

Private repository for maintaining personal, private, vendor, and work-in-progress agent skills.

## Layout

| Path | Purpose |
|------|---------|
| `personal/` | Skills authored for personal/general use. |
| `private/` | Skills tied to private work context. |
| `vendor/` | Reference skills authored by vendors, grouped by vendor name. |
| `wip/` | Skills currently being developed; ignored by sync tooling unless explicitly enabled in `catalog.yaml`. |
| `*/_evals/<skill>/suite/` | Eval definitions and suite helper files for a skill. |
| `*/_evals/<skill>/results/` | Eval run outputs for a skill. |
| `docs/` | Research, guides, factory notes, and implementation plans. |
| `tools/` | Maintenance scripts and viewers. |
| `generated/` | Generated local reports; ignored by git except `.gitkeep`. |

## Runtime skill rule

A runtime skill folder should contain only the files an agent may use while applying that skill, such as `SKILL.md`, `references/`, `assets/`, and runtime helper scripts. Eval suites and eval results live outside the skill folder under the bucket's `_evals/` directory.

## Catalog

`catalog.yaml` is the source of truth for which skills exist, where they live, whether they should be synced into local agent skill stores, and where their eval suite/results directories are.

## Syncing skills locally

```sh
./tools/sync-skills.sh --dry-run
./tools/sync-skills.sh
```

The sync script links only skills marked `install: true` in `catalog.yaml`. It ignores `wip/`, `_evals/`, `docs/`, `tools/`, and `generated/` unless the catalog explicitly changes.

## Reporting and uninstalling local skill links

```sh
./tools/report-skills.sh --no-open
./tools/uninstall-skills.sh --dry-run --all
```

Generated report data is written to `generated/`; the static viewer lives at `tools/installed-skills.html`.
