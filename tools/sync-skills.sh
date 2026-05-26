#!/usr/bin/env bash
#
# sync-skills.sh — link catalog-selected skills from this repo into your agent
# skill stores, so editing a skill here updates it for every agent at once.
#
# Usage:
#   ./tools/sync-skills.sh            Link install:true skills; refresh symlinks
#   ./tools/sync-skills.sh --force    Replace copied skill folders with symlinks
#   ./tools/sync-skills.sh --dry-run  Show what would change, without doing it
#   ./tools/sync-skills.sh --help

set -eo pipefail
shopt -s nullglob

# The skills store(s) to link into.
AGENT_SKILL_DIRS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
  "$HOME/.hermes/skills"
)

usage() {
  cat <<'EOF'
sync-skills.sh — link skills marked install: true in catalog.yaml into agent
skill stores (~/.agents/skills, ~/.claude/skills, and ~/.hermes/skills).

Usage:
  ./tools/sync-skills.sh            Link selected skills and refresh symlinks
  ./tools/sync-skills.sh --force    Also replace already-copied skill folders
                              with live symlinks
  ./tools/sync-skills.sh --dry-run  Show what would change, without doing it
  ./tools/sync-skills.sh --help     Show this message

The catalog is the source of truth. WIP skills, vendor reference skills, evals,
docs, tools, and generated files are ignored unless explicitly enabled with
install: true in catalog.yaml.

Top-level repo buckets:
  personal/   personal/general skills
  private/    private work-context skills
  vendor/     vendor-authored reference skills
  wip/        skills under active development; ignored by default
EOF
}

DRY_RUN=false
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true ;;
    --force|-f)   FORCE=true ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TOOL_DIR/.." && pwd)"
CATALOG_FILE="$REPO_DIR/catalog.yaml"

if [ ! -f "$CATALOG_FILE" ]; then
  echo "catalog.yaml not found at $CATALOG_FILE" >&2
  exit 1
fi

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; X=""
fi

skill_names=()
skill_dirs=()
skill_dirs_canon=()

while IFS=$'\t' read -r name rel_path; do
  [ -n "${name:-}" ] || continue

  src="$REPO_DIR/$rel_path"
  if [ ! -f "$src/SKILL.md" ]; then
    echo "${R}error${X} catalog entry '$name' points to a non-skill path: $rel_path" >&2
    exit 1
  fi

  for existing in "${skill_names[@]}"; do
    if [ "$existing" = "$name" ]; then
      echo "${R}error${X} multiple install:true catalog entries use skill name '$name'" >&2
      echo "${D}Only one skill can be linked to each installed basename.${X}" >&2
      exit 1
    fi
  done

  skill_names+=("$name")
  skill_dirs+=("$src")
  skill_dirs_canon+=("$(cd -P "$src" && pwd -P)")
done < <(python3 -c '
from pathlib import Path
import sys

catalog_path = Path(sys.argv[1])
records = []
current = None
for raw in catalog_path.read_text().splitlines():
    line = raw.rstrip("\n")
    stripped = line.strip()
    if line.startswith("  - id: "):
        if current:
            records.append(current)
        current = {"id": stripped.split(": ", 1)[1]}
        continue
    if current is not None and line.startswith("    ") and ": " in stripped:
        key, value = stripped.split(": ", 1)
        if key in {"name", "path", "install"}:
            current[key] = value
if current:
    records.append(current)

for record in records:
    if record.get("install") == "true":
        print(record["name"] + "\t" + record["path"])
' "$CATALOG_FILE")

if [ "${#skill_dirs[@]}" -eq 0 ]; then
  echo "${Y}No install:true skills found in catalog.yaml.${X}"
  exit 0
fi

points_into_repo() {
  local installed_path="$1"
  local link_target resolved

  link_target="$(readlink "$installed_path")"
  case "$link_target" in
    "$REPO_DIR"|"$REPO_DIR"/*) return 0 ;;
  esac

  if resolved="$(cd -P "$installed_path" 2>/dev/null && pwd -P)"; then
    case "$resolved" in
      "$REPO_DIR"|"$REPO_DIR"/*) return 0 ;;
    esac
  fi

  return 1
}

is_current_desired_link() {
  local entry="$1"
  local name resolved i
  name="$(basename "$entry")"

  if ! resolved="$(cd -P "$entry" 2>/dev/null && pwd -P)"; then
    return 1
  fi

  for i in "${!skill_names[@]}"; do
    if [ "$name" = "${skill_names[$i]}" ] && [ "$resolved" = "${skill_dirs_canon[$i]}" ]; then
      return 0
    fi
  done

  return 1
}

linked=0; replaced=0; pruned=0; skipped=0

echo "${B}Syncing ${#skill_dirs[@]} catalog-selected skill(s)${X} from $REPO_DIR"
if $DRY_RUN; then echo "${Y}dry run — nothing will be changed${X}"; fi
echo

for target in "${AGENT_SKILL_DIRS[@]}"; do
  echo "${B}→ ${target}${X}"
  $DRY_RUN || mkdir -p "$target"

  # Prune stale repo symlinks: old paths, disabled catalog entries, renamed
  # skills, or repo links that no longer match the install:true catalog source.
  if [ -d "$target" ]; then
    for entry in "$target"/*; do
      [ -L "$entry" ] || continue
      if points_into_repo "$entry" && ! is_current_desired_link "$entry"; then
        echo "  ${Y}prune${X}    $(basename "$entry") ${D}— stale or disabled repo link${X}"
        $DRY_RUN || rm -f "$entry"
        pruned=$((pruned + 1))
      fi
    done
  fi

  for i in "${!skill_dirs[@]}"; do
    src="${skill_dirs[$i]}"
    name="${skill_names[$i]}"
    link="$target/$name"

    if [ -L "$link" ]; then
      $DRY_RUN || rm -f "$link"
    elif [ -d "$link" ]; then
      if $FORCE; then
        echo "  ${Y}replace${X}  $name ${D}— swapping the copied folder for a symlink${X}"
        $DRY_RUN || rm -rf "$link"
        replaced=$((replaced + 1))
      else
        echo "  ${R}skip${X}     $name ${D}— a copied folder is here; re-run with --force to make it a live symlink${X}"
        skipped=$((skipped + 1))
        continue
      fi
    elif [ -e "$link" ]; then
      echo "  ${R}skip${X}     $name ${D}— a real file is in the way${X}"
      skipped=$((skipped + 1))
      continue
    fi

    echo "  ${G}link${X}     $name ${D}→ ${src#"$REPO_DIR"/}${X}"
    $DRY_RUN || ln -s "$src" "$link"
    linked=$((linked + 1))
  done
  echo
done

echo "${B}Done.${X}  ${G}${linked} linked${X} · ${Y}${replaced} replaced${X} · ${Y}${pruned} pruned${X} · ${R}${skipped} skipped${X}"
if $DRY_RUN; then
  echo "${D}Re-run without --dry-run to apply.${X}"
else
  echo "${D}Edits to linked catalog skills now apply everywhere instantly.${X}"
  echo "${D}Update catalog.yaml and re-run this script when install selections change.${X}"
fi
