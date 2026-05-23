#!/usr/bin/env bash
#
# uninstall-skills.sh — interactively remove installed skills that come from
# this repo from your agent skill stores.
#
# This removes installed entries from ~/.agents/skills and ~/.claude/skills.
# It never removes the source skill folders in this repository.
#
# Usage:
#   ./uninstall-skills.sh            Choose installed repo skills to uninstall
#   ./uninstall-skills.sh --all      Uninstall every installed repo skill
#   ./uninstall-skills.sh --dry-run  Show what would be removed
#   ./uninstall-skills.sh --help

set -euo pipefail
shopt -s nullglob

# Keep these in sync with sync-skills.sh.
AGENT_SKILL_DIRS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

IGNORED_SKILL_PARENT_DIR_NAMES=(
  "by-anthropic"
  "by-openai"
)

usage() {
  cat <<'EOF'
uninstall-skills.sh — remove installed skills from this repo

Usage:
  ./uninstall-skills.sh            Choose installed repo skills to uninstall
  ./uninstall-skills.sh --all      Uninstall every installed repo skill
  ./uninstall-skills.sh --dry-run  Show what would be removed, without deleting
  ./uninstall-skills.sh --help     Show this message

What it removes:
  - symlinks in the configured agent skill dirs that point into this repo
  - copied skill folders with names matching skills in this repo, after confirmation

What it never removes:
  - source skill folders in this repo
  - symlinks that point outside this repo
  - unrelated installed skills whose names do not match this repo's skills

Selection syntax:
  1,3,5       select individual entries
  2-4         select a range
  all         select all listed entries
EOF
}

DRY_RUN=false
REMOVE_ALL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true ;;
    --all|-a)     REMOVE_ALL=true ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE_DIR="$REPO_DIR/private-skills"

is_ignored_skill_path() {
  local path="${1%/}"
  local rel component ignored

  case "$path" in
    "$REPO_DIR") rel="" ;;
    "$REPO_DIR"/*) rel="${path#"$REPO_DIR"/}" ;;
    *) rel="$path" ;;
  esac

  local IFS='/'
  for component in $rel; do
    for ignored in "${IGNORED_SKILL_PARENT_DIR_NAMES[@]}"; do
      if [ "$component" = "$ignored" ]; then
        return 0
      fi
    done
  done

  return 1
}

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; X=""
fi

# Discover repo skills using the same rules as sync-skills.sh.
skill_dirs=()
for d in "$REPO_DIR"/*/; do
  if is_ignored_skill_path "${d%/}"; then continue; fi
  if [ -f "${d}SKILL.md" ]; then skill_dirs+=("${d%/}"); fi
done
if [ -d "$PRIVATE_DIR" ]; then
  for d in "$PRIVATE_DIR"/*/; do
    if is_ignored_skill_path "${d%/}"; then continue; fi
    if [ -f "${d}SKILL.md" ]; then skill_dirs+=("${d%/}"); fi
  done
fi

if [ "${#skill_dirs[@]}" -eq 0 ]; then
  echo "${Y}No skills found in this repo.${X}"
  exit 0
fi

skill_names=()
for src in "${skill_dirs[@]}"; do
  skill_names+=("$(basename "$src")")
done

entry_skill=()
entry_target=()
entry_path=()
entry_kind=()
entry_note=()

add_entry() {
  entry_skill+=("$1")
  entry_target+=("$2")
  entry_path+=("$3")
  entry_kind+=("$4")
  entry_note+=("$5")
}

points_into_repo() {
  local installed_path="$1"
  local link_target resolved

  link_target="$(readlink "$installed_path")"
  case "$link_target" in
    "$REPO_DIR"|"$REPO_DIR"/*) return 0 ;;
  esac

  # Handle relative symlinks too, if they resolve to an existing repo path.
  if resolved="$(cd "$installed_path" 2>/dev/null && pwd -P)"; then
    case "$resolved" in
      "$REPO_DIR"|"$REPO_DIR"/*) return 0 ;;
    esac
  fi

  return 1
}

for target in "${AGENT_SKILL_DIRS[@]}"; do
  [ -d "$target" ] || continue

  for name in "${skill_names[@]}"; do
    installed="$target/$name"

    if [ -L "$installed" ]; then
      if points_into_repo "$installed"; then
        if [ -e "$installed" ]; then
          add_entry "$name" "$target" "$installed" "symlink" "points into this repo"
        else
          add_entry "$name" "$target" "$installed" "broken symlink" "points into this repo"
        fi
      fi
    elif [ -d "$installed" ] && [ -f "$installed/SKILL.md" ]; then
      add_entry "$name" "$target" "$installed" "copied folder" "name matches a repo skill"
    fi
  done
done

if [ "${#entry_path[@]}" -eq 0 ]; then
  echo "${G}No installed skills from this repo found.${X}"
  exit 0
fi

echo "${B}Installed skills from this repo:${X}"
echo
for i in "${!entry_path[@]}"; do
  n=$((i + 1))
  printf '[%d] %-18s %-40s %s %s%s%s\n' \
    "$n" \
    "${entry_skill[$i]}" \
    "${entry_path[$i]}" \
    "${entry_kind[$i]}" \
    "$D" \
    "— ${entry_note[$i]}" \
    "$X"
done
echo

selected=()
select_all_entries() {
  local i
  for i in "${!entry_path[@]}"; do
    selected[$i]=1
  done
}

parse_selection() {
  local input="$1"
  local token start end n i

  input="${input//[[:space:]]/}"
  case "$input" in
    all|ALL|All)
      select_all_entries
      return 0
      ;;
    "")
      return 1
      ;;
  esac

  local IFS=','
  for token in $input; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      n="$token"
      if [ "$n" -lt 1 ] || [ "$n" -gt "${#entry_path[@]}" ]; then
        echo "Selection out of range: $n" >&2
        return 1
      fi
      selected[$((n - 1))]=1
    elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${token%-*}"
      end="${token#*-}"
      if [ "$start" -lt 1 ] || [ "$end" -gt "${#entry_path[@]}" ] || [ "$start" -gt "$end" ]; then
        echo "Range out of bounds: $token" >&2
        return 1
      fi
      for ((i = start; i <= end; i++)); do
        selected[$((i - 1))]=1
      done
    else
      echo "Invalid selection: $token" >&2
      return 1
    fi
  done
}

if $REMOVE_ALL; then
  select_all_entries
else
  if [ ! -t 0 ]; then
    echo "Interactive selection requires a terminal. Re-run with --all or provide input from a terminal." >&2
    exit 1
  fi

  while true; do
    read -r -p "Choose entries to uninstall (for example: 1,3 or 2-4 or all): " answer
    selected=()
    if parse_selection "$answer"; then
      break
    fi
  done
fi

selected_count=0
for i in "${!entry_path[@]}"; do
  if [ "${selected[$i]:-0}" = 1 ]; then
    selected_count=$((selected_count + 1))
  fi
done

if [ "$selected_count" -eq 0 ]; then
  echo "No entries selected."
  exit 0
fi

echo
echo "${B}Selected for uninstall:${X}"
for i in "${!entry_path[@]}"; do
  if [ "${selected[$i]:-0}" = 1 ]; then
    echo "  - ${entry_skill[$i]} ${D}(${entry_kind[$i]})${X}: ${entry_path[$i]}"
  fi
done

echo
if $DRY_RUN; then
  echo "${Y}dry run — nothing will be removed${X}"
else
  read -r -p "Remove $selected_count installed skill entr$( [ "$selected_count" -eq 1 ] && echo 'y' || echo 'ies' )? [y/N] " confirm
  case "$confirm" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

removed=0
for i in "${!entry_path[@]}"; do
  if [ "${selected[$i]:-0}" != 1 ]; then
    continue
  fi

  path="${entry_path[$i]}"
  kind="${entry_kind[$i]}"

  echo "${R}remove${X}  ${entry_skill[$i]} ${D}from ${entry_target[$i]} (${kind})${X}"
  if ! $DRY_RUN; then
    if [ -L "$path" ]; then
      rm -f "$path"
    elif [ -d "$path" ]; then
      rm -rf "$path"
    else
      echo "  ${Y}skip${X} missing: $path"
      continue
    fi
  fi
  removed=$((removed + 1))
done

echo
if $DRY_RUN; then
  echo "${B}Done.${X} ${Y}${removed} would be removed.${X}"
else
  echo "${B}Done.${X} ${G}${removed} removed.${X}"
fi
