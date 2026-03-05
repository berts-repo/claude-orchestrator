#!/usr/bin/env bash
# log-view.sh — Human-readable viewer for delegation logs.
# Usage:
#   bash scripts/log-view.sh              # last 5 entries, full detail
#   bash scripts/log-view.sh 10           # last 10 entries
#   bash scripts/log-view.sh --list       # summary table only
#   bash scripts/log-view.sh --codex      # filter: Codex only
#   bash scripts/log-view.sh --gemini     # filter: Gemini only
#   bash scripts/log-view.sh auth         # keyword filter on summary/cwd
#   bash scripts/log-view.sh 10 --codex   # combinable
set -euo pipefail

LOG_FILE="${HOME}/.claude/logs/delegations.jsonl"

# ── ANSI colours (TTY only) ─────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_HEADER="\033[1;36m"   # bold cyan — entry headers
  C_LABEL="\033[1;33m"    # bold yellow — PROMPT / RESPONSE labels
  C_DIM="\033[2m"         # dim — separators / footer
  C_BOLD="\033[1m"        # bold — table header
  C_GREEN="\033[32m"
  C_RED="\033[31m"
  C_RESET="\033[0m"
else
  C_HEADER="" C_LABEL="" C_DIM="" C_BOLD="" C_GREEN="" C_RED="" C_RESET=""
fi

SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Argument parsing ─────────────────────────────────────────────────────────
COUNT=5
LIST_ONLY=false
TYPE_FILTER=""
KEYWORD=""

for arg in "$@"; do
  case "$arg" in
    --list)   LIST_ONLY=true ;;
    --codex)  TYPE_FILTER="codex" ;;
    --gemini) TYPE_FILTER="gemini" ;;
    [0-9]*)   COUNT="$arg" ;;
    *)        KEYWORD="$arg" ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt_ts() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && { echo "—"; return; }
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null; then
    return
  fi
  date -d "$ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts"
}

fmt_dur() {
  local ms="$1"
  [[ -z "$ms" || "$ms" == "null" ]] && { echo "—"; return; }
  printf "%.1fs" "$(echo "scale=1; $ms / 1000" | bc 2>/dev/null || echo 0)"
}

trunc() {
  local s="$1" n="$2"
  if [[ ${#s} -gt $n ]]; then
    echo "${s:0:$((n-3))}..."
  else
    echo "$s"
  fi
}

# ── Check log file ────────────────────────────────────────────────────────────
if [[ ! -f "$LOG_FILE" ]]; then
  echo "⚠  Log file not found: $LOG_FILE"
  echo "   Run 'bash scripts/sync-hooks.sh' to verify hook setup."
  exit 0
fi

# ── Build jq filter ───────────────────────────────────────────────────────────
JQ_BASE='.event == "codex_delegation" or .event == "gemini_query"'

if [[ -n "$TYPE_FILTER" ]]; then
  JQ_FILTER="($JQ_BASE) and (.type == \"$TYPE_FILTER\")"
else
  JQ_FILTER="$JQ_BASE"
fi

# Apply keyword filter via --arg (no injection)
filter_entries() {
  if [[ -n "$KEYWORD" ]]; then
    jq -c --arg kw "${KEYWORD,,}" \
      "select($JQ_FILTER) | select(
        ((.summary // \"\") | ascii_downcase | contains(\$kw)) or
        ((.cwd // \"\") | ascii_downcase | contains(\$kw))
      )" "$LOG_FILE"
  else
    jq -c "select($JQ_FILTER)" "$LOG_FILE"
  fi
}

ALL_ENTRIES=$(filter_entries)
TOTAL=$(echo "$ALL_ENTRIES" | grep -c . 2>/dev/null || echo 0)
ENTRIES=$(echo "$ALL_ENTRIES" | tail -n "$COUNT")
SHOWN=$(echo "$ENTRIES" | grep -c . 2>/dev/null || echo 0)

if [[ -z "$(echo "$ENTRIES" | tr -d '[:space:]')" ]]; then
  echo "No entries found."
  [[ -n "$TYPE_FILTER" ]] && echo "  Filter: type=$TYPE_FILTER"
  [[ -n "$KEYWORD" ]] && echo "  Filter: keyword='$KEYWORD'"
  exit 0
fi

# ── List mode (summary table) ─────────────────────────────────────────────────
if [[ "$LIST_ONLY" == "true" ]]; then
  printf "${C_BOLD}%-4s %-20s %-7s %-9s %-7s %s${C_RESET}\n" \
    "#" "Timestamp" "Type" "Duration" "Status" "Summary"
  printf "${C_DIM}%-4s %-20s %-7s %-9s %-7s %s${C_RESET}\n" \
    "──" "───────────────────" "──────" "────────" "──────" "──────────────────────────────────────"

  idx=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ts=$(echo "$line"      | jq -r '.timestamp // ""')
    type=$(echo "$line"    | jq -r '.type // ""')
    dur_ms=$(echo "$line"  | jq -r '.duration_ms // "null"')
    success=$(echo "$line" | jq -r '.success // ""')
    summary=$(echo "$line" | jq -r '.summary // ""')

    local_ts=$(fmt_ts "$ts")
    dur=$(fmt_dur "$dur_ms")

    if [[ "$success" == "true" ]]; then
      status="${C_GREEN}✓${C_RESET}"
    elif [[ "$success" == "false" ]]; then
      status="${C_RED}✗${C_RESET}"
    else
      status="?"
    fi

    short_summary=$(trunc "$summary" 60)
    printf "${C_HEADER}%-4s${C_RESET} %-20s %-7s %-9s %-7b %s\n" \
      "$idx" "$local_ts" "$type" "$dur" "$status" "$short_summary"
    idx=$((idx + 1))
  done <<< "$ENTRIES"

# ── Full mode ─────────────────────────────────────────────────────────────────
else
  idx=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    ts=$(echo "$line"       | jq -r '.timestamp // ""')
    type=$(echo "$line"     | jq -r '.type // ""')
    dur_ms=$(echo "$line"   | jq -r '.duration_ms // "null"')
    sandbox=$(echo "$line"  | jq -r '.sandbox // ""')
    approval=$(echo "$line" | jq -r '.approval_policy // ""')
    cwd=$(echo "$line"      | jq -r '.cwd // ""')
    success=$(echo "$line"  | jq -r '.success // ""')
    detail=$(echo "$line"   | jq -r '.detail // ""')

    local_ts=$(fmt_ts "$ts")
    dur=$(fmt_dur "$dur_ms")

    echo -e "${C_HEADER}${SEP}${C_RESET}"
    header="${type}"
    [[ -n "$sandbox"  && "$sandbox"  != "null" ]] && header="${header} · ${sandbox}"
    [[ -n "$approval" && "$approval" != "null" ]] && header="${header} · ${approval}"
    header="${header} · ${dur} · ${local_ts}"
    echo -e "${C_HEADER}[${idx}] ${header}${C_RESET}"
    [[ -n "$cwd" && "$cwd" != "null" && "$cwd" != "unknown" ]] && \
      echo -e "${C_DIM}cwd: ${cwd}${C_RESET}"
    echo ""

    if [[ -z "$detail" || "$detail" == "null" || ! -f "$detail" ]]; then
      echo -e "  ${C_RED}⚠ detail file not found${C_RESET}"
      echo ""
      idx=$((idx + 1))
      continue
    fi

    if [[ "$type" == "codex" ]]; then
      turn_count=$(wc -l < "$detail" | tr -d ' ')
      turn_num=1
      while IFS= read -r turn_line; do
        [[ -z "$turn_line" ]] && continue
        prompt=$(echo "$turn_line"    | jq -r '.prompt // ""')
        response=$(echo "$turn_line"  | jq -r '.response // ""')
        turn_tool=$(echo "$turn_line" | jq -r '.tool // ""')

        [[ "$turn_count" -gt 1 ]] && echo -e "${C_DIM}Turn ${turn_num}${C_RESET}"

        if [[ "$turn_tool" == "mcp__delegate__codex_parallel" ]]; then
          echo -e "${C_LABEL}PROMPTS${C_RESET}"
          echo -e "${C_DIM}───────${C_RESET}"
          task_count=$(echo "$prompt" | jq 'length' 2>/dev/null || echo 0)
          if [[ "$task_count" -gt 0 ]]; then
            for i in $(seq 0 $((task_count - 1))); do
              task_prompt=$(echo "$prompt"  | jq -r ".[$i].prompt // \"\""  2>/dev/null || echo "")
              task_sandbox=$(echo "$prompt" | jq -r ".[$i].sandbox // \"\""  2>/dev/null || echo "")
              task_cwd=$(echo "$prompt"     | jq -r ".[$i].cwd // \"\""     2>/dev/null || echo "")
              echo -e "${C_DIM}[$((i+1))] sandbox=${task_sandbox} cwd=${task_cwd}${C_RESET}"
              echo "$task_prompt"
              echo ""
            done
          else
            echo "$prompt"
          fi
        else
          echo -e "${C_LABEL}PROMPT${C_RESET}"
          echo -e "${C_DIM}──────${C_RESET}"
          echo "$prompt"
        fi

        echo ""
        echo -e "${C_LABEL}RESPONSE${C_RESET}"
        echo -e "${C_DIM}────────${C_RESET}"
        echo "$response"
        echo ""
        turn_num=$((turn_num + 1))
      done < "$detail"

    elif [[ "$type" == "gemini" ]]; then
      detail_line=$(head -1 "$detail")
      query=$(echo "$detail_line" | jq -r '.query // ""')
      # response is stored as a JSON-encoded string; try to parse it as content blocks
      response=$(echo "$detail_line" | jq -r '
        .response // "" |
        if (ltrimstr(" ") | startswith("[")) then
          (. | fromjson | [.[] | select(.type == "text") | .text] | join("\n"))
        else
          .
        end
      ')

      echo -e "${C_LABEL}QUERY${C_RESET}"
      echo -e "${C_DIM}─────${C_RESET}"
      echo "$query"
      echo ""
      echo -e "${C_LABEL}RESULT${C_RESET}"
      echo -e "${C_DIM}──────${C_RESET}"
      echo "$response"
      echo ""
    fi

    idx=$((idx + 1))
  done <<< "$ENTRIES"

  echo -e "${C_HEADER}${SEP}${C_RESET}"
fi

# ── Footer ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${C_DIM}Showing ${SHOWN} of ${TOTAL} total entries · ${HOME}/.claude/logs/details/${C_RESET}"
