# Repository Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure this skills repository into long-term maintainable top-level areas: `personal/`, `private/`, `vendor/`, `wip/`, `docs/`, `tools/`, and `generated/`, while keeping runtime skill folders free of eval suites/results.

**Architecture:** Runtime skills live as direct skill folders under their ownership bucket, except vendor skills which are grouped by vendor name and then keep the original skill directory name. Eval suites and results live together under each bucket's `_evals/<skill-name>/` folder, outside the runtime skill folder. Tooling uses `catalog.yaml` as the source of truth instead of recursively discovering every `SKILL.md`.

**Tech Stack:** Bash scripts, YAML catalog, existing `SKILL.md` skill format, git filesystem moves.

---

## Target structure

```txt
Skills/
  README.md
  catalog.yaml

  personal/
    blueprint/
      SKILL.md
      references/
    system-design/
      SKILL.md
      references/
    skill-creator/
      SKILL.md
      agents/
      assets/
      eval-viewer/
      references/
      scripts/
    _evals/
      blueprint/
        suite/
          evals.json
        results/
          iteration-1/
      system-design/
        suite/
          evals.json
        results/
          eval-2-recheck/
          eval-2-verify/
          eval-review.html
          eval-review-iteration-2.html
          feedback.json
          iteration-1/
          iteration-2/
      skill-creator/
        suite/
          .gitkeep
        results/
          .gitkeep

  private/
    kite-arch-compass/
      SKILL.md
      references/
    _evals/
      kite-arch-compass/
        suite/
          evals.json
          files/
            export_routes.py
        results/
          iteration-1/

  vendor/
    anthropic/
      skill-creator/
        SKILL.md
        LICENSE.txt
        agents/
        assets/
        eval-viewer/
        references/
        scripts/
      _evals/
        skill-creator/
          suite/
            .gitkeep
          results/
            .gitkeep
    openai/
      skill-creator/
        SKILL.md
        license.txt
        agents/
        assets/
        references/
        scripts/
      _evals/
        skill-creator/
          suite/
            .gitkeep
          results/
            .gitkeep

  wip/
    backend-standards/
      SKILL.md
      patterns.md
    _evals/
      backend-standards/
        suite/
          .gitkeep
        results/
          .gitkeep

  docs/
    guides/
    research/
    factory/
    superpowers/
      plans/
        2026-05-23-repository-migration.md

  tools/
    sync-skills.sh
    report-skills.sh
    uninstall-skills.sh
    installed-skills.html

  generated/
    .gitkeep
    installed-skills.json   # generated, git-ignored
    installed-skills.js     # generated, git-ignored
```

## Important invariants

- Do not rename any skill directory itself.
  - `skill-creator` remains `skill-creator` in `personal/`, `vendor/anthropic/`, and `vendor/openai/`.
  - `blueprint`, `system-design`, `kite-arch-compass`, and `backend-standards` keep their exact directory names.
- Keep evals out of runtime skill folders.
- Keep eval suite and eval results together under `_evals/<skill-name>/`.
- Use one catalog convention: `evals.suite` always points to the suite directory, not to `evals.json`.
- Keep `wip/` as a first-class top-level directory, but sync tooling must ignore it unless a catalog entry is explicitly set to `install: true`.
- Do not install vendor skills by default because they collide by basename with `personal/skill-creator`.
- Remove stale empty top-level `archive/` if it exists; it is not part of the clean layout.

---

### Task 1: Create the new top-level layout

**Files:**
- Create directories: `personal/`, `private/`, `vendor/`, `docs/`, `tools/`, `generated/`
- Preserve existing directory: `wip/`
- Create placeholder files for intentionally empty directories that should survive a fresh clone.

- [ ] **Step 1: Create destination directories**

Run:

```bash
mkdir -p \
  personal/_evals/blueprint/suite \
  personal/_evals/blueprint/results \
  personal/_evals/system-design/suite \
  personal/_evals/system-design/results \
  personal/_evals/skill-creator/suite \
  personal/_evals/skill-creator/results \
  private/_evals/kite-arch-compass/suite \
  private/_evals/kite-arch-compass/results \
  vendor/anthropic/_evals/skill-creator/suite \
  vendor/anthropic/_evals/skill-creator/results \
  vendor/openai/_evals/skill-creator/suite \
  vendor/openai/_evals/skill-creator/results \
  wip/_evals/backend-standards/suite \
  wip/_evals/backend-standards/results \
  docs/guides \
  docs/research \
  docs/factory \
  docs/superpowers/plans \
  tools \
  generated
```

Expected: command exits with status `0`.

- [ ] **Step 2: Add `.gitkeep` files for intentionally empty directories**

Run:

```bash
touch \
  personal/_evals/skill-creator/suite/.gitkeep \
  personal/_evals/skill-creator/results/.gitkeep \
  vendor/anthropic/_evals/skill-creator/suite/.gitkeep \
  vendor/anthropic/_evals/skill-creator/results/.gitkeep \
  vendor/openai/_evals/skill-creator/suite/.gitkeep \
  vendor/openai/_evals/skill-creator/results/.gitkeep \
  wip/_evals/backend-standards/suite/.gitkeep \
  wip/_evals/backend-standards/results/.gitkeep \
  generated/.gitkeep
```

Expected: command exits with status `0`.

- [ ] **Step 3: Verify directories exist**

Run:

```bash
test -d personal && \
test -d private && \
test -d vendor/anthropic && \
test -d vendor/openai && \
test -d wip && \
test -d docs && \
test -d tools && \
test -d generated
```

Expected: command exits with status `0`.

---

### Task 2: Move personal runtime skills

**Files:**
- Move: `blueprint/` → `personal/blueprint/`
- Move: `system-design/` → `personal/system-design/`
- Move: `skill-creator/` → `personal/skill-creator/`

- [ ] **Step 1: Move root personal skill directories**

Run:

```bash
git mv blueprint personal/blueprint
git mv system-design personal/system-design
git mv skill-creator personal/skill-creator
```

Expected: all three `git mv` commands exit with status `0`.

- [ ] **Step 2: Verify personal skills still contain `SKILL.md`**

Run:

```bash
test -f personal/blueprint/SKILL.md && \
test -f personal/system-design/SKILL.md && \
test -f personal/skill-creator/SKILL.md
```

Expected: command exits with status `0`.

---

### Task 3: Move private and vendor runtime skills

**Files:**
- Move: `private-skills/kite-arch-compass/` → `private/kite-arch-compass/`
- Move: `by-anthropic/skill-creator/` → `vendor/anthropic/skill-creator/`
- Move: `by-openai/skill-creator/` → `vendor/openai/skill-creator/`
- Keep: `wip/backend-standards/`

- [ ] **Step 1: Move private and vendor skill directories without renaming skill folders**

Run:

```bash
git mv private-skills/kite-arch-compass private/kite-arch-compass
git mv by-anthropic/skill-creator vendor/anthropic/skill-creator
git mv by-openai/skill-creator vendor/openai/skill-creator
```

Expected: all three `git mv` commands exit with status `0`.

- [ ] **Step 2: Remove empty old grouping directories if git leaves them behind**

Run:

```bash
rmdir private-skills by-anthropic by-openai 2>/dev/null || true
```

Expected: command exits with status `0`. It is acceptable if some directories were already gone.

- [ ] **Step 3: Verify all moved skills still contain `SKILL.md`**

Run:

```bash
test -f private/kite-arch-compass/SKILL.md && \
test -f vendor/anthropic/skill-creator/SKILL.md && \
test -f vendor/openai/skill-creator/SKILL.md && \
test -f wip/backend-standards/SKILL.md
```

Expected: command exits with status `0`.

---

### Task 4: Move eval suites out of runtime skills

**Files:**
- Move: `personal/blueprint/evals/evals.json` → `personal/_evals/blueprint/suite/evals.json`
- Move: `personal/system-design/evals/evals.json` → `personal/_evals/system-design/suite/evals.json`
- Move: all contents of `private/kite-arch-compass/evals/` → `private/_evals/kite-arch-compass/suite/`, including `files/export_routes.py`

- [ ] **Step 1: Move eval suite contents**

Run:

```bash
git mv personal/blueprint/evals/evals.json personal/_evals/blueprint/suite/evals.json
git mv personal/system-design/evals/evals.json personal/_evals/system-design/suite/evals.json
git mv private/kite-arch-compass/evals/* private/_evals/kite-arch-compass/suite/
```

Expected: all three `git mv` commands exit with status `0`.

- [ ] **Step 2: Remove now-empty runtime eval directories**

Run:

```bash
rmdir personal/blueprint/evals personal/system-design/evals private/kite-arch-compass/evals 2>/dev/null || true
```

Expected: command exits with status `0`.

- [ ] **Step 3: Verify runtime skill folders no longer contain eval directories**

Run:

```bash
test ! -d personal/blueprint/evals && \
test ! -d personal/system-design/evals && \
test ! -d private/kite-arch-compass/evals
```

Expected: command exits with status `0`.

- [ ] **Step 4: Verify kite eval helper files were preserved outside the runtime skill**

Run:

```bash
test -f private/_evals/kite-arch-compass/suite/evals.json && \
test -f private/_evals/kite-arch-compass/suite/files/export_routes.py
```

Expected: command exits with status `0`.

---

### Task 5: Move eval results beside their suites

**Files:**
- Move: `evals-results/blueprint-workspace/iteration-1/` → `personal/_evals/blueprint/results/iteration-1/`
- Remove: empty `evals-results/blueprint-workspace/evals/` instead of carrying it forward as a confusing results directory
- Move: all tracked `evals-results/system-design-workspace/` result artifacts → `personal/_evals/system-design/results/`
- Move: `evals-results/kite-arch-compass-workspace/iteration-1/` → `private/_evals/kite-arch-compass/results/iteration-1/`

- [ ] **Step 1: Move blueprint eval results and remove the empty old workspace eval directory**

Run:

```bash
git mv evals-results/blueprint-workspace/iteration-1 personal/_evals/blueprint/results/
rmdir evals-results/blueprint-workspace/evals 2>/dev/null || true
```

Expected: command exits with status `0` and `personal/_evals/blueprint/results/iteration-1/` exists.

- [ ] **Step 2: Move system-design eval results, including recheck and verify runs**

Run:

```bash
git mv evals-results/system-design-workspace/iteration-1 personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/iteration-2 personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/eval-2-recheck personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/eval-2-verify personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/eval-review.html personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/eval-review-iteration-2.html personal/_evals/system-design/results/
git mv evals-results/system-design-workspace/feedback.json personal/_evals/system-design/results/
```

Expected: command exits with status `0`; `eval-2-recheck/`, `eval-2-verify/`, `eval-review.html`, `feedback.json`, `iteration-1/`, and `iteration-2/` are under `personal/_evals/system-design/results/`.

- [ ] **Step 3: Move kite-arch-compass eval results**

Run:

```bash
git mv evals-results/kite-arch-compass-workspace/iteration-1 private/_evals/kite-arch-compass/results/
```

Expected: command exits with status `0` and `private/_evals/kite-arch-compass/results/iteration-1/` exists.

- [ ] **Step 4: Remove old eval results workspace directories**

Run:

```bash
rmdir evals-results/blueprint-workspace evals-results/system-design-workspace evals-results/kite-arch-compass-workspace evals-results 2>/dev/null || true
```

Expected: command exits with status `0`.

---

### Task 6: Move docs, generated reports, and maintenance tools

**Files:**
- Move: `guides/` → `docs/guides/`
- Move: `research/` → `docs/research/`
- Move: `skills-factory/` → `docs/factory/`
- Move: `sync-skills.sh` → `tools/sync-skills.sh`
- Move: `report-skills.sh` → `tools/report-skills.sh`
- Move: `uninstall-skills.sh` → `tools/uninstall-skills.sh`
- Move: `installed-skills.html` → `tools/installed-skills.html`
- Move if present: `installed-skills.json` → `generated/installed-skills.json`
- Move if present: `installed-skills.js` → `generated/installed-skills.js`
- Remove if present and empty: `archive/`

- [ ] **Step 1: Move documentation areas**

Run:

```bash
git mv guides docs/guides
git mv research docs/research
git mv skills-factory docs/factory
```

Expected: all three `git mv` commands exit with status `0`.

- [ ] **Step 2: Move scripts and viewer**

Run:

```bash
git mv sync-skills.sh tools/sync-skills.sh
git mv report-skills.sh tools/report-skills.sh
git mv uninstall-skills.sh tools/uninstall-skills.sh
git mv installed-skills.html tools/installed-skills.html
```

Expected: all four `git mv` commands exit with status `0`.

- [ ] **Step 3: Move generated installed-skill report files if they are tracked or present**

Run:

```bash
if git ls-files --error-unmatch installed-skills.json >/dev/null 2>&1; then
  git mv installed-skills.json generated/installed-skills.json
else
  mv installed-skills.json generated/installed-skills.json 2>/dev/null || true
fi

if git ls-files --error-unmatch installed-skills.js >/dev/null 2>&1; then
  git mv installed-skills.js generated/installed-skills.js
else
  mv installed-skills.js generated/installed-skills.js 2>/dev/null || true
fi
```

Expected: command exits with status `0` whether these generated files are tracked, untracked, or absent.

- [ ] **Step 4: Remove stale empty top-level `archive/` if present**

Run:

```bash
rmdir archive 2>/dev/null || true
```

Expected: command exits with status `0`. It is acceptable if `archive/` was already absent.

---

### Task 7: Add `catalog.yaml` as the source of truth

**Files:**
- Create: `catalog.yaml`

- [ ] **Step 1: Write the catalog**

Create `catalog.yaml` with this content:

```yaml
version: 1

sync:
  defaultInstall: false
  ignoredRoots:
    - wip
    - docs
    - tools
    - generated
  ignoredDirectoryNames:
    - _evals

skills:
  - id: blueprint
    name: blueprint
    bucket: personal
    path: personal/blueprint
    install: true
    evals:
      suite: personal/_evals/blueprint/suite
      results: personal/_evals/blueprint/results

  - id: system-design
    name: system-design
    bucket: personal
    path: personal/system-design
    install: true
    evals:
      suite: personal/_evals/system-design/suite
      results: personal/_evals/system-design/results

  - id: skill-creator
    name: skill-creator
    bucket: personal
    path: personal/skill-creator
    install: true
    evals:
      suite: personal/_evals/skill-creator/suite
      results: personal/_evals/skill-creator/results

  - id: kite-arch-compass
    name: kite-arch-compass
    bucket: private
    path: private/kite-arch-compass
    install: true
    evals:
      suite: private/_evals/kite-arch-compass/suite
      results: private/_evals/kite-arch-compass/results

  - id: vendor-anthropic-skill-creator
    name: skill-creator
    bucket: vendor
    vendor: anthropic
    path: vendor/anthropic/skill-creator
    install: false
    evals:
      suite: vendor/anthropic/_evals/skill-creator/suite
      results: vendor/anthropic/_evals/skill-creator/results

  - id: vendor-openai-skill-creator
    name: skill-creator
    bucket: vendor
    vendor: openai
    path: vendor/openai/skill-creator
    install: false
    evals:
      suite: vendor/openai/_evals/skill-creator/suite
      results: vendor/openai/_evals/skill-creator/results

  - id: backend-standards
    name: backend-standards
    bucket: wip
    path: wip/backend-standards
    install: false
    evals:
      suite: wip/_evals/backend-standards/suite
      results: wip/_evals/backend-standards/results
```

Expected: `catalog.yaml` exists at the repo root.

- [ ] **Step 2: Validate catalog paths that should exist now**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
required_files = [
    'personal/blueprint/SKILL.md',
    'personal/system-design/SKILL.md',
    'personal/skill-creator/SKILL.md',
    'private/kite-arch-compass/SKILL.md',
    'vendor/anthropic/skill-creator/SKILL.md',
    'vendor/openai/skill-creator/SKILL.md',
    'wip/backend-standards/SKILL.md',
    'personal/_evals/blueprint/suite/evals.json',
    'personal/_evals/system-design/suite/evals.json',
    'private/_evals/kite-arch-compass/suite/evals.json',
    'private/_evals/kite-arch-compass/suite/files/export_routes.py',
    'personal/_evals/skill-creator/suite/.gitkeep',
    'personal/_evals/skill-creator/results/.gitkeep',
    'vendor/anthropic/_evals/skill-creator/suite/.gitkeep',
    'vendor/anthropic/_evals/skill-creator/results/.gitkeep',
    'vendor/openai/_evals/skill-creator/suite/.gitkeep',
    'vendor/openai/_evals/skill-creator/results/.gitkeep',
    'wip/_evals/backend-standards/suite/.gitkeep',
    'wip/_evals/backend-standards/results/.gitkeep',
    'generated/.gitkeep',
]
required_dirs = [
    'personal/_evals/blueprint/suite',
    'personal/_evals/blueprint/results',
    'personal/_evals/system-design/suite',
    'personal/_evals/system-design/results',
    'private/_evals/kite-arch-compass/suite',
    'private/_evals/kite-arch-compass/results',
]
missing_files = [p for p in required_files if not Path(p).is_file()]
missing_dirs = [p for p in required_dirs if not Path(p).is_dir()]
if missing_files or missing_dirs:
    message = []
    if missing_files:
        message.append('Missing expected files:\n' + '\n'.join(missing_files))
    if missing_dirs:
        message.append('Missing expected dirs:\n' + '\n'.join(missing_dirs))
    raise SystemExit('\n'.join(message))
print('catalog path check passed')
PY
```

Expected: output includes `catalog path check passed`.

---

### Task 8: Update `tools/sync-skills.sh` for the new structure

**Files:**
- Modify: `tools/sync-skills.sh`

- [ ] **Step 1: Replace old root/private discovery with catalog-driven discovery**

Update `tools/sync-skills.sh` so it:

1. Resolves `TOOL_DIR` as the script directory and `REPO_DIR` as the parent directory of `tools/`.
2. Reads `$REPO_DIR/catalog.yaml`.
3. Selects only catalog entries with `install: true`.
4. Links each selected skill using the catalog `name` as the destination basename and catalog `path` as the source.
5. Never scans `wip/`, `_evals/`, `docs/`, `tools/`, or `generated/` for skills.

Use this path setup:

```bash
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TOOL_DIR/.." && pwd)"
CATALOG_FILE="$REPO_DIR/catalog.yaml"
```

Use a small Python parser for the fixed catalog shape so the script does not depend on PyYAML:

```bash
mapfile -t skill_records < <(python3 - "$CATALOG_FILE" <<'PY'
from pathlib import Path
import sys

catalog_path = Path(sys.argv[1])
records = []
current = None
for raw in catalog_path.read_text().splitlines():
    line = raw.rstrip('\n')
    stripped = line.strip()
    if line.startswith('  - id: '):
        if current:
            records.append(current)
        current = {'id': stripped.split(': ', 1)[1]}
        continue
    if current and line.startswith('    ') and ': ' in stripped:
        key, value = stripped.split(': ', 1)
        if key in {'name', 'path', 'install'}:
            current[key] = value
if current:
    records.append(current)

for record in records:
    if record.get('install') == 'true':
        print(f"{record['name']}\t{record['path']}")
PY
)
```

Then build parallel `skill_names` and `skill_dirs` arrays from those records, and use the catalog `name` rather than `basename "$src"` when creating each installed link:

```bash
skill_names=()
skill_dirs=()
for record in "${skill_records[@]}"; do
  name="${record%%$'\t'*}"
  rel_path="${record#*$'\t'}"
  src="$REPO_DIR/$rel_path"
  if [ ! -f "$src/SKILL.md" ]; then
    echo "${R}error${X} catalog entry '$name' points to a non-skill path: $rel_path" >&2
    exit 1
  fi
  skill_names+=("$name")
  skill_dirs+=("$src")
done
```

Update the link loop from a source-only loop to an indexed loop:

```bash
for i in "${!skill_dirs[@]}"; do
  src="${skill_dirs[$i]}"
  name="${skill_names[$i]}"
  link="$target/$name"
  # keep the existing link/replace/skip behavior below this point
  ...
done
```

Expected: `tools/sync-skills.sh` no longer contains references to `PRIVATE_DIR`, `IGNORED_SKILL_PARENT_DIR_NAMES`, `by-anthropic`, or `by-openai`.

- [ ] **Step 2: Update script help text**

Update usage text to say:

```txt
sync-skills.sh links only skills marked install: true in catalog.yaml.
WIP skills, vendor reference skills, evals, docs, tools, and generated files are ignored unless explicitly enabled in the catalog.
```

Expected: `./tools/sync-skills.sh --help` describes `catalog.yaml`, `personal/`, `private/`, `vendor/`, and `wip/`.

- [ ] **Step 3: Run a dry-run sync check**

Run:

```bash
./tools/sync-skills.sh --dry-run
```

Expected: output lists links for:

```txt
blueprint
system-design
skill-creator
kite-arch-compass
```

Expected: output does not list links for:

```txt
backend-standards
vendor/anthropic/skill-creator
vendor/openai/skill-creator
```

---

### Task 9: Update `tools/uninstall-skills.sh` for the new structure

**Files:**
- Modify: `tools/uninstall-skills.sh`

- [ ] **Step 1: Replace old bucket ignore logic with catalog-driven skill names**

Update `tools/uninstall-skills.sh` so it:

1. Resolves `TOOL_DIR` as the script directory and `REPO_DIR` as the parent directory of `tools/`.
2. Reads `$REPO_DIR/catalog.yaml`.
3. Builds a de-duplicated list of catalog `name` values for matching copied installed folders.
4. Keeps symlink detection path-based with `points_into_repo`, so any installed symlink pointing into this repo can still be removed.
5. Does not reference `private-skills`, `by-anthropic`, `by-openai`, or old ignored parent directory names.

Use this path setup:

```bash
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TOOL_DIR/.." && pwd)"
CATALOG_FILE="$REPO_DIR/catalog.yaml"
```

Replace the old `skill_dirs` discovery block with this catalog name parser:

```bash
mapfile -t skill_names < <(python3 - "$CATALOG_FILE" <<'PY'
from pathlib import Path
import sys

catalog_path = Path(sys.argv[1])
names = set()
current = None
for raw in catalog_path.read_text().splitlines():
    line = raw.rstrip('\n')
    stripped = line.strip()
    if line.startswith('  - id: '):
        current = {}
        continue
    if current is not None and line.startswith('    ') and ': ' in stripped:
        key, value = stripped.split(': ', 1)
        if key == 'name':
            names.add(value)
for name in sorted(names):
    print(name)
PY
)
```

Remove these obsolete pieces from `tools/uninstall-skills.sh`:

```bash
PRIVATE_DIR="$REPO_DIR/private-skills"
IGNORED_SKILL_PARENT_DIR_NAMES=(...)
is_ignored_skill_path() { ... }
# Discover repo skills using the same rules as sync-skills.sh.
skill_dirs=()
...
for src in "${skill_dirs[@]}"; do
  skill_names+=("$(basename "$src")")
done
```

Expected: the script has no stale references to old bucket names and still uses `skill_names` later when scanning agent skill stores.

- [ ] **Step 2: Update script help text**

Update comments and `usage()` text to mention the new location and catalog behavior:

```txt
uninstall-skills.sh removes installed entries whose names appear in catalog.yaml or whose symlinks point into this repo.
Run it from the repo root as ./tools/uninstall-skills.sh.
```

Expected: `./tools/uninstall-skills.sh --help` no longer implies root-level script placement or old filesystem discovery.

- [ ] **Step 3: Run uninstall dry-run without prompting**

Run:

```bash
./tools/uninstall-skills.sh --dry-run --all
```

Expected: command exits with status `0`. It may list installed repo skills, or it may print `No installed skills from this repo found.` depending on the local machine state.

---

### Task 10: Update `tools/report-skills.sh` for moved generated output

**Files:**
- Modify: `tools/report-skills.sh`

- [ ] **Step 1: Update repo path and output paths**

Change path setup so:

```bash
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TOOL_DIR/.." && pwd)"
GENERATED_DIR="$REPO_DIR/generated"
JSON_FILE="$GENERATED_DIR/installed-skills.json"
JS_FILE="$GENERATED_DIR/installed-skills.js"
HTML_FILE="$TOOL_DIR/installed-skills.html"
```

Also ensure the script creates the generated directory before writing:

```bash
mkdir -p "$GENERATED_DIR"
```

Expected: generated files are written under `generated/`, and the viewer is opened from `tools/installed-skills.html`.

- [ ] **Step 2: Update help text**

Update comments and `usage()` text to mention:

```txt
Writes generated/installed-skills.json and generated/installed-skills.js, then opens tools/installed-skills.html.
```

Expected: `./tools/report-skills.sh --help` no longer says the generated files are at the repo root.

- [ ] **Step 3: Run report generation without opening browser**

Run:

```bash
./tools/report-skills.sh --no-open
```

Expected:

```txt
generated/installed-skills.json
generated/installed-skills.js
```

exist after the command.

---

### Task 11: Update ignore rules

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Replace old generated report ignore entries**

Update `.gitignore` so generated report files are ignored in their new location while `generated/.gitkeep` remains trackable:

```gitignore
.DS_Store

# Generated by tools/report-skills.sh (tools/installed-skills.html is tracked)
generated/installed-skills.json
generated/installed-skills.js
```

Expected: `.gitignore` no longer contains root-level `installed-skills.json` or `installed-skills.js` entries.

- [ ] **Step 2: Verify ignore behavior**

Run:

```bash
git check-ignore generated/installed-skills.json generated/installed-skills.js
```

Expected output:

```txt
generated/installed-skills.json
generated/installed-skills.js
```

- [ ] **Step 3: Verify `generated/.gitkeep` is not ignored**

Run:

```bash
if git check-ignore generated/.gitkeep >/dev/null 2>&1; then
  echo 'generated/.gitkeep is unexpectedly ignored' >&2
  exit 1
fi
```

Expected: command exits with status `0`.

---

### Task 12: Update README navigation and tool guidance

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace publishing-oriented README content with repository map**

Update `README.md` to describe the private repository layout:

```markdown
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
```

Expected: README no longer advertises `npx skills add rangrik/Skills/blueprint` as the primary install path.

---

### Task 13: Final structural verification

**Files:**
- Verify: full repository structure

- [ ] **Step 1: Confirm runtime skill folders and WIP skill folders do not contain eval directories**

Run:

```bash
find personal private vendor wip -path '*/SKILL.md' -print | sort
find personal private vendor wip -path '*/evals' -type d -print
```

Expected first command includes:

```txt
personal/blueprint/SKILL.md
personal/skill-creator/SKILL.md
personal/system-design/SKILL.md
private/kite-arch-compass/SKILL.md
vendor/anthropic/skill-creator/SKILL.md
vendor/openai/skill-creator/SKILL.md
wip/backend-standards/SKILL.md
```

Expected second command prints nothing.

- [ ] **Step 2: Confirm eval suite/result homes exist**

Run:

```bash
test -f personal/_evals/blueprint/suite/evals.json && \
test -d personal/_evals/blueprint/results/iteration-1 && \
test -f personal/_evals/system-design/suite/evals.json && \
test -d personal/_evals/system-design/results/iteration-1 && \
test -d personal/_evals/system-design/results/iteration-2 && \
test -d personal/_evals/system-design/results/eval-2-recheck && \
test -d personal/_evals/system-design/results/eval-2-verify && \
test -f private/_evals/kite-arch-compass/suite/evals.json && \
test -f private/_evals/kite-arch-compass/suite/files/export_routes.py && \
test -d private/_evals/kite-arch-compass/results/iteration-1
```

Expected: command exits with status `0`.

- [ ] **Step 3: Confirm empty eval homes and generated directory are trackable**

Run:

```bash
test -f personal/_evals/skill-creator/suite/.gitkeep && \
test -f personal/_evals/skill-creator/results/.gitkeep && \
test -f vendor/anthropic/_evals/skill-creator/suite/.gitkeep && \
test -f vendor/anthropic/_evals/skill-creator/results/.gitkeep && \
test -f vendor/openai/_evals/skill-creator/suite/.gitkeep && \
test -f vendor/openai/_evals/skill-creator/results/.gitkeep && \
test -f wip/_evals/backend-standards/suite/.gitkeep && \
test -f wip/_evals/backend-standards/results/.gitkeep && \
test -f generated/.gitkeep
```

Expected: command exits with status `0`.

- [ ] **Step 4: Confirm removed old top-level buckets are gone**

Run:

```bash
test ! -d by-anthropic && \
test ! -d by-openai && \
test ! -d private-skills && \
test ! -d evals-results && \
test ! -d guides && \
test ! -d research && \
test ! -d skills-factory && \
test ! -d archive
```

Expected: command exits with status `0`.

- [ ] **Step 5: Confirm tools are in the tools directory**

Run:

```bash
test -x tools/sync-skills.sh && \
test -x tools/report-skills.sh && \
test -x tools/uninstall-skills.sh && \
test -f tools/installed-skills.html && \
test ! -e sync-skills.sh && \
test ! -e report-skills.sh && \
test ! -e uninstall-skills.sh && \
test ! -e installed-skills.html
```

Expected: command exits with status `0`.

- [ ] **Step 6: Review git status**

Run:

```bash
git status --short
```

Expected: status shows moves into `personal/`, `private/`, `vendor/`, `docs/`, `tools/`, and new/modified files including `catalog.yaml`, `.gitignore`, `README.md`, and `generated/.gitkeep`.

- [ ] **Step 7: Commit the migration**

Run:

```bash
git add -A
git commit -m "chore: restructure skills repository"
```

Expected: commit succeeds.

---

## Self-review

- Spec coverage: The plan covers personal/private/vendor/wip top-level buckets, vendor namespacing without skill directory renames, eval suite/results co-location, keeping evals outside runtime skill folders, `uninstall-skills.sh`, script updates, generated reports, README navigation, empty directory persistence, and stale `archive/` cleanup.
- Placeholder scan: No `TBD`, `TODO`, or unspecified implementation steps remain.
- Type/path consistency: Paths consistently use `personal/`, `private/`, `vendor/`, `wip/`, `docs/`, `tools/`, and `generated/`. Vendor skill directories remain named `skill-creator`. `evals.suite` consistently points to a suite directory.
