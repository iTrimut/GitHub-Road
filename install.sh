#!/usr/bin/env bash
# =============================================================================
# install.sh — install this Agent Skill into your agent's skills directory.
#
# The skill follows the standard Agent Skills format (SKILL.md + YAML frontmatter),
# so it works in any agent: Claude Code, DeepSeek Harness (DSH), Cursor,
# Windsurf, GitHub Copilot, OpenCode, Codex, etc. This script detects which
# agent is present and copies the skill where that agent expects it.
#
# Usage:
#   bash install.sh                  # auto-detect agent, project-level install
#   bash install.sh --user           # user-level install (~/<agent-dir>/skills/)
#   bash install.sh --agent <name>   # force agent: claude|dsh|cursor|windsurf|copilot|opencode|codex
#   bash install.sh --list           # show detected agents and exit
#   bash install.sh -h               # this help
#
# Exit codes: 0 ok, 1 error (no/unknown agent, nothing to copy)
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- locate skill directory/directories: flat repo (SKILL.md at root) or nested (skills/*/) ---
SKILL_SRCS=()
if [[ -f "$HERE/SKILL.md" ]]; then
  SKILL_SRCS=( "$HERE" )
else
  shopt -s nullglob
  for d in "$HERE"/skills/*/; do
    [[ -f "$d/SKILL.md" ]] && SKILL_SRCS+=( "${d%/}" )
  done
  if [[ ${#SKILL_SRCS[@]} -eq 0 ]]; then
    echo "error: no SKILL.md found next to install.sh or under skills/." >&2
    exit 1
  fi
fi

skill_name_of() { # $1 = skill dir -> echo frontmatter name
  grep -m1 '^name:' "$1/SKILL.md" | sed 's/^name:[[:space:]]*//' | tr -d '\r'
}

# --- agent registry (parallel arrays; bash 3.2 compatible, works on macOS) ---
AGENT_IDS=(    claude      dsh     cursor    windsurf  copilot    opencode  codex )
AGENT_LABEL=(  "Claude Code" "DeepSeek Harness (DSH)" "Cursor" "Windsurf" "GitHub Copilot" "OpenCode" "Codex" )
AGENT_USER=(   ".claude/skills" ".dsh/skills" ".cursor/skills" ".windsurf/skills" ".github/skills" ".opencode/skills" ".codex/skills" )
AGENT_PROJ=(   ".claude/skills" "" ".cursor/skills" ".windsurf/skills" ".github/skills" ".opencode/skills" ".codex/skills" )
AGENT_BIN=(    claude      dsh     cursor    windsurf  gh-copilot opencode  codex )

idx_of() { # $1 = agent id -> echo index or -1
  local i
  for i in "${!AGENT_IDS[@]}"; do
    [[ "${AGENT_IDS[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo -1
}

show_help() {
  cat <<'EOF'
install.sh — install this Agent Skill into your agent's skills directory.

Usage:
  bash install.sh                  auto-detect agent, project-level install
  bash install.sh --user           user-level install (~/<agent-dir>/skills/)
  bash install.sh --agent <name>   force agent: claude|dsh|cursor|windsurf|copilot|opencode|codex
  bash install.sh --list           show detected agents and exit
  bash install.sh -h               this help

DSH (DeepSeek Harness) is always installed user-level (~/.dsh/skills/).
EOF
  exit 0
}

USERLEVEL=0
FORCE=""
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)      USERLEVEL=1 ;;
    --agent)     FORCE="${2:?--agent needs a value}"; shift ;;
    --list)      LIST=1 ;;
    -h|--help)   show_help ;;
    *)           echo "unknown option: $1 (see -h)" >&2; exit 1 ;;
  esac
  shift
done

# --- detect installed agents ---
detected=()
for i in "${!AGENT_IDS[@]}"; do
  id="${AGENT_IDS[$i]}"
  if [[ -d "$HOME/.$id" ]] || command -v "${AGENT_BIN[$i]}" >/dev/null 2>&1; then
    detected+=("$id")
  fi
done

if [[ "$LIST" == "1" ]]; then
  for s in "${SKILL_SRCS[@]}"; do
    echo "skill: $(skill_name_of "$s") (source: $s)"
  done
  if [[ ${#detected[@]} -eq 0 ]]; then
    echo "detected agents: none"
  else
    echo "detected agents: ${detected[*]}"
  fi
  exit 0
fi

AGENT="${FORCE:-${detected[0]:-}}"
if [[ -z "$AGENT" ]]; then
  echo "error: no supported agent detected. Install manually into one of:" >&2
  for i in "${!AGENT_IDS[@]}"; do
    printf '  %-24s ~/%s/\n' "${AGENT_LABEL[$i]}" "${AGENT_USER[$i]}" >&2
  done
  exit 1
fi
IDX="$(idx_of "$AGENT")"
if [[ "$IDX" == "-1" ]]; then
  echo "error: unknown agent '$AGENT'. Valid: ${AGENT_IDS[*]}" >&2
  exit 1
fi

if [[ "$AGENT" == "dsh" ]]; then
  ROOT="$HOME/${AGENT_USER[$IDX]}"          # DSH is user-level only
elif [[ "$USERLEVEL" == "1" ]]; then
  ROOT="$HOME/${AGENT_USER[$IDX]}"
else
  ROOT="$PWD/${AGENT_PROJ[$IDX]}"
fi

installed=()
for s in "${SKILL_SRCS[@]}"; do
  name="$(skill_name_of "$s")"
  if [[ -z "$name" ]]; then
    echo "warning: skipping $s (no 'name:' in SKILL.md frontmatter)" >&2
    continue
  fi
  DEST="$ROOT/$name"
  mkdir -p "$DEST"
  copied=0
  for item in SKILL.md references files; do
    if [[ -e "$s/$item" ]]; then
      cp -R "$s/$item" "$DEST/"
      copied=1
    fi
  done
  if [[ "$copied" == "0" ]]; then
    echo "warning: nothing to copy from $s" >&2
    continue
  fi
  installed+=( "$name" )
done

if [[ ${#installed[@]} -eq 0 ]]; then
  echo "error: no skill could be installed." >&2
  exit 1
fi

echo "installed ${#installed[@]} skill(s) for ${AGENT_LABEL[$IDX]} -> $ROOT:"
for name in "${installed[@]}"; do echo "  - $name"; done
echo "Restart/reload your agent, then mention the skill's trigger words to verify it loads."
