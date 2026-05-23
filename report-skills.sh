#!/usr/bin/env bash
#
# report-skills.sh — report which skills are currently installed in your agent
# skill stores (~/.agents/skills and ~/.claude/skills), as structured JSON that
# a small viewer page (installed-skills.html) renders.
#
# It walks each store and, for every installed skill, records:
#   • the skill name
#   • how it is installed (machine key → meaning):
#       - copied    a real directory living in the store
#       - repo      a symlink resolving into this repository
#       - shared    a symlink into ~/.agents/skills (the shared store)
#       - external  a symlink resolving somewhere else
#       - broken    a symlink whose target no longer exists
#   • the link target (for symlinks)
#   • the one-line description from the skill's SKILL.md frontmatter
#
# Outputs two generated (git-ignored) files at the repo root:
#   • installed-skills.json   the data, as plain JSON for any consumer
#   • installed-skills.js     the same data as `window.INSTALLED_SKILLS = …;`,
#                             a shim so installed-skills.html can load it when
#                             opened straight off disk (file:// blocks fetch of
#                             local JSON, but a <script src> works)
# then opens installed-skills.html (committed, static) in your browser.
#
# Usage:
#   ./report-skills.sh                Write the data files and open the viewer
#   ./report-skills.sh --no-open      Write the data files; don't open a browser
#   ./report-skills.sh --dry-run      Print the JSON to stdout; write nothing
#   ./report-skills.sh --help

set -euo pipefail
shopt -s nullglob

# The skill stores to inspect. Keep in sync with sync-skills.sh.
AGENT_SKILL_DIRS=(
  "$HOME/.agents/skills"   # shared store — reaches pi, Cursor, Codex, …
  "$HOME/.claude/skills"   # Claude Code's own skills directory
)

usage() {
  cat <<'EOF'
report-skills.sh — report which skills are installed in your agent skill
stores (~/.agents/skills and ~/.claude/skills) as JSON, and open a viewer.

Usage:
  ./report-skills.sh                Write the data files and open the viewer
  ./report-skills.sh --no-open      Write the data files; don't open a browser
  ./report-skills.sh --dry-run      Print the JSON to stdout; write nothing
  ./report-skills.sh --help         Show this message

Writes installed-skills.json (plain data) and installed-skills.js (a shim for
the file:// viewer), then opens installed-skills.html. For each store it lists
every installed skill, how it is installed (copied folder, symlink into this
repo, symlink into the shared store, symlink elsewhere, or a broken link), the
link target, and the one-line description from the skill's SKILL.md.
EOF
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_FILE="$REPO_DIR/installed-skills.json"
JS_FILE="$REPO_DIR/installed-skills.js"
HTML_FILE="$REPO_DIR/installed-skills.html"
DRY_RUN=false
OPEN=true

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true ;;
    --no-open)    OPEN=false ;;
    --help|-h)    usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; X=""
fi

# Canonical path of the shared store, so symlinks into it can be recognised
# even when $HOME itself contains symlinks.
SHARED_STORE_CANON="$(cd -P "$HOME/.agents/skills" 2>/dev/null && pwd -P || echo "$HOME/.agents/skills")"

# Read the `description:` field from a skill's SKILL.md frontmatter. Handles
# both inline values and YAML block scalars (`description: >-` / `|` followed by
# indented lines), folding the latter onto a single line.
get_description() {
  local skill_md="$1/SKILL.md"
  [ -f "$skill_md" ] || { printf ''; return; }
  awk '
    /^---[[:space:]]*$/ { fm++; if (fm >= 2) exit; next }
    fm != 1 { next }
    {
      if (grab) {
        if ($0 ~ /^[^[:space:]]/) { grab = 0 }    # dedent ends the block
        else {
          l = $0; sub(/^[[:space:]]+/, "", l)
          buf = (buf == "" ? l : buf " " l)
          next
        }
      }
      if (!done && $0 ~ /^[Dd]escription:/) {
        v = $0; sub(/^[Dd]escription:[[:space:]]*/, "", v)
        if (v ~ /^[>|][+-]?[[:space:]]*$/) { grab = 1; buf = ""; done = 1 }
        else { print v; done = 2; exit }
      }
    }
    END { if (done == 1) print buf }
  ' "$skill_md"
}

# Escape a string for use as a JSON string value (between quotes).
json_escape() {
  local s="$1"
  # Strip a single pair of wrapping quotes left over from a YAML quoted scalar,
  # before escaping (so the comparison sees the raw quotes).
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  s="${s//\\/\\\\}"      # backslash first
  s="${s//\"/\\\"}"      # double quotes
  s="${s//$'\t'/ }"      # tabs → space
  s="${s//$'\r'/ }"      # CR → space
  s="${s//$'\n'/ }"      # any stray newline → space
  printf '%s' "$s"
}

GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"

total_all=0; total_copied=0; total_repo=0; total_shared=0; total_external=0; total_broken=0

stores_json=""
first_store=true

for store in "${AGENT_SKILL_DIRS[@]}"; do
  display="${store/#$HOME/~}"

  $first_store || stores_json+=","
  first_store=false

  if [ ! -d "$store" ]; then
    stores_json+="{\"path\":\"$(json_escape "$display")\",\"present\":false,\"count\":0,\"skills\":[]}"
    echo "${Y}skip${X} ${display} ${D}— not present${X}"
    continue
  fi

  skills_json=""
  first_skill=true
  count=0

  for entry in "$store"/*; do
    name="$(basename "$entry")"
    type=""
    target=""
    resolved=""

    if [ -L "$entry" ]; then
      target="$(readlink "$entry")"
      if resolved="$(cd -P "$entry" 2>/dev/null && pwd -P)" && [ -n "$resolved" ]; then
        case "$resolved" in
          "$REPO_DIR"|"$REPO_DIR"/*)
            type="repo"; total_repo=$((total_repo + 1)) ;;
          "$SHARED_STORE_CANON"|"$SHARED_STORE_CANON"/*)
            type="shared"; total_shared=$((total_shared + 1)) ;;
          *)
            type="external"; total_external=$((total_external + 1)) ;;
        esac
      else
        type="broken"; total_broken=$((total_broken + 1))
      fi
    elif [ -d "$entry" ]; then
      if [ -f "$entry/SKILL.md" ]; then
        type="copied"; total_copied=$((total_copied + 1)); resolved="$entry"
      else
        continue   # plain directory, not a skill
      fi
    else
      continue       # stray file
    fi

    desc=""
    if [ -n "$resolved" ] && [ -f "$resolved/SKILL.md" ]; then
      desc="$(get_description "$resolved")"
    elif [ -f "$entry/SKILL.md" ]; then
      desc="$(get_description "$entry")"
    fi

    $first_skill || skills_json+=","
    first_skill=false
    skills_json+="{\"name\":\"$(json_escape "$name")\",\"type\":\"$type\",\"target\":\"$(json_escape "$target")\",\"description\":\"$(json_escape "$desc")\"}"
    count=$((count + 1))
  done

  total_all=$((total_all + count))
  stores_json+="{\"path\":\"$(json_escape "$display")\",\"present\":true,\"count\":$count,\"skills\":[$skills_json]}"
  echo "${B}${display}${X}: ${G}${count} skills${X}"
done

summary_json="{\"total\":$total_all,\"copied\":$total_copied,\"repo\":$total_repo,\"shared\":$total_shared,\"external\":$total_external,\"broken\":$total_broken}"
JSON="{\"generatedAt\":\"$(json_escape "$GENERATED_AT")\",\"summary\":$summary_json,\"stores\":[$stores_json]}"

if $DRY_RUN; then
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$JSON" | python3 -m json.tool
  else
    printf '%s\n' "$JSON"
  fi
  echo "${Y}dry run — no files written${X}" >&2
  exit 0
fi

printf '%s\n' "$JSON" > "$JSON_FILE"
printf 'window.INSTALLED_SKILLS = %s;\n' "$JSON" > "$JS_FILE"

echo
echo "${B}Wrote${X} ${JSON_FILE/#$HOME/~} ${D}and${X} ${JS_FILE/#$HOME/~}"
echo "${D}${total_all} entries · ${total_copied} copied · ${total_repo} → repo · ${total_shared} → shared · ${total_external} → external · ${total_broken} broken${X}"

if [ ! -f "$HTML_FILE" ]; then
  echo "${R}warning${X} ${HTML_FILE/#$HOME/~} is missing — the viewer page is not in the repo." >&2
  exit 1
fi

if $OPEN; then
  if command -v open >/dev/null 2>&1; then
    open "$HTML_FILE"
    echo "${G}Opened${X} ${HTML_FILE/#$HOME/~}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$HTML_FILE" >/dev/null 2>&1 &
    echo "${G}Opened${X} ${HTML_FILE/#$HOME/~}"
  else
    echo "${Y}Could not find \`open\`/\`xdg-open\`.${X} Open this file manually:"
    echo "  $HTML_FILE"
  fi
fi
