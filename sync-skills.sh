#!/usr/bin/env bash
#
# sync-skills.sh — link every skill in this repo into your agent skills
# stores, so editing a skill here updates it for every agent at once.
#
# Background
#   The `skills` CLI (skills.sh / `npx skills`) installs skills into one shared
#   store — ~/.agents/skills/ — and wires that store into every agent you use
#   (Claude Code, pi, Cursor, Codex, …). It installs them as *copies*, so a
#   skill you develop locally goes stale the moment you edit it: you would have
#   to push and re-run `npx skills` to see the change.
#
#   This script instead places a *symlink* in that shared store, pointing back
#   at this repo. Edits here are then live in every agent instantly — no
#   reinstall, no `npx skills update`.
#
# Usage
#   ./sync-skills.sh            Link new skills; refresh existing symlinks
#   ./sync-skills.sh --force    Also replace copied skill folders with symlinks
#   ./sync-skills.sh --dry-run  Show what would change, without doing it
#   ./sync-skills.sh --help
#
# Re-run it whenever you add a new skill or set up a new machine.

set -euo pipefail
shopt -s nullglob

# ─── Configuration ─────────────────────────────────────────────────────────
# The skills store(s) to link into:
#   • ~/.agents/skills — the store the `skills` CLI manages and exposes to
#     most agents (pi, Cursor, Codex, …) from one place.
#   • ~/.claude/skills — Claude Code reads its skills straight from here, so it
#     needs its own link target.
# Add another line only if some other agent keeps its own separate directory.
AGENT_SKILL_DIRS=(
  "$HOME/.agents/skills"   # shared store — reaches pi, Cursor, Codex, …
  "$HOME/.claude/skills"   # Claude Code's own skills directory
)
# ───────────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
sync-skills.sh — link every skill in this repo into your agent skills stores
(~/.agents/skills and ~/.claude/skills), so editing a skill here updates it
for every agent instantly. No reinstall, no copies going stale.

Usage:
  ./sync-skills.sh            Link new skills and refresh existing symlinks
  ./sync-skills.sh --force    Also replace already-copied skill folders
                              (e.g. ones installed earlier via `npx skills`)
                              with live symlinks
  ./sync-skills.sh --dry-run  Show what would change, without doing it
  ./sync-skills.sh --help     Show this message

It links both public skills (a folder with a SKILL.md at the repo root) and
private skills (the same, under private-skills/, kept separate). Stale
symlinks from renamed or removed skills are cleaned up automatically. Real
skill folders are never touched unless you pass --force, and even then only
ones whose name matches a skill in this repo.

Edit AGENT_SKILL_DIRS near the top of this script to change where it links.
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

# The repo is wherever this script lives — resolved at run time, so the same
# script works on every machine.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE_DIR="$REPO_DIR/private-skills"

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; X=""
fi

# ─── Discover skills (any folder containing a SKILL.md) ────────────────────
skill_dirs=()
for d in "$REPO_DIR"/*/; do
  if [ -f "${d}SKILL.md" ]; then skill_dirs+=("${d%/}"); fi
done
if [ -d "$PRIVATE_DIR" ]; then
  for d in "$PRIVATE_DIR"/*/; do
    if [ -f "${d}SKILL.md" ]; then skill_dirs+=("${d%/}"); fi
  done
fi

if [ "${#skill_dirs[@]}" -eq 0 ]; then
  echo "${Y}No skills found.${X} Looked for folders containing a SKILL.md in:"
  echo "  $REPO_DIR/*/"
  echo "  $PRIVATE_DIR/*/"
  exit 0
fi

echo "${B}Syncing ${#skill_dirs[@]} skill(s)${X} from $REPO_DIR"
if $DRY_RUN; then echo "${Y}dry run — nothing will be changed${X}"; fi
echo

linked=0; replaced=0; pruned=0; skipped=0

for target in "${AGENT_SKILL_DIRS[@]}"; do
  echo "${B}→ ${target}${X}"
  $DRY_RUN || mkdir -p "$target"

  # Prune stale links we previously created: symlinks pointing into this repo
  # that no longer resolve to a real skill (skill renamed or deleted).
  if [ -d "$target" ]; then
    for entry in "$target"/*; do
      [ -L "$entry" ] || continue
      case "$(readlink "$entry")" in
        "$REPO_DIR"/*)
          if [ ! -f "$entry/SKILL.md" ]; then
            echo "  ${Y}prune${X}    $(basename "$entry") ${D}— stale link${X}"
            $DRY_RUN || rm -f "$entry"
            pruned=$((pruned + 1))
          fi ;;
      esac
    done
  fi

  # Link every discovered skill.
  for src in "${skill_dirs[@]}"; do
    name="$(basename "$src")"
    link="$target/$name"
    tag=""
    case "$src" in "$PRIVATE_DIR"/*) tag=" ${D}(private)${X}" ;; esac

    if [ -L "$link" ]; then
      # Existing symlink — refresh it so it always points at the current source.
      $DRY_RUN || rm -f "$link"
    elif [ -d "$link" ]; then
      # A real folder is here — almost always a copy installed by `npx skills`.
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

    echo "  ${G}link${X}     ${name}${tag}"
    $DRY_RUN || ln -s "$src" "$link"
    linked=$((linked + 1))
  done
  echo
done

echo "${B}Done.${X}  ${G}${linked} linked${X} · ${Y}${replaced} replaced${X} · ${Y}${pruned} pruned${X} · ${R}${skipped} skipped${X}"
if $DRY_RUN; then
  echo "${D}Re-run without --dry-run to apply.${X}"
else
  echo "${D}Edits to any linked skill now apply everywhere instantly.${X}"
  echo "${D}Re-run this script after adding a new skill.${X}"
  if [ "$replaced" -gt 0 ]; then
    echo
    echo "${Y}Note:${X} replaced skills were previously installed by \`npx skills\`."
    echo "They are now live symlinks. Manage them by editing this repo — don't run"
    echo "\`npx skills add/update\` on them again, or the symlink becomes a copy"
    echo "once more (just re-run this script if that happens)."
  fi
fi
