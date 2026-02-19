#!/usr/bin/env bash
# PostToolUse hook
# Logs Codex and Gemini delegations with short summaries to delegations.jsonl
# Full prompt/response stored in per-thread detail files under details/
# Codex threads are JSONL — each turn appends to {threadId}.jsonl
# Keeps the last MAX_ENTRIES summary entries (FIFO rotation)
# Detail files expire after RETENTION_DAYS
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"

MAX_ENTRIES=100
RETENTION_DAYS=30
LOG_FILE="${LOG_DIR}/delegations.jsonl"
DETAIL_DIR="${LOG_DIR}/details"

ensure_dirs
mkdir -p "$DETAIL_DIR"

# Read input
payload="$(cat)"

tool_name=$(echo "$payload" | jq -r '.tool_name // ""')

# Only log Codex and Gemini calls
case "$tool_name" in
  mcp__codex__codex|mcp__codex__codex-reply) tool_type="codex" ;;
  mcp__gemini_web__web_search|mcp__gemini_web__web_fetch|mcp__gemini_web__web_summarize) tool_type="gemini" ;;
  *) exit 0 ;;
esac

# Extract common fields
tool_input=$(echo "$payload" | jq -c '.tool_input // {}')
tool_response=$(echo "$payload" | jq -r '.tool_response // "{}"')

# Generate a short summary from first line of prompt/query (truncated to 80 chars)
make_summary() {
  local text="$1"
  local first_line
  first_line=$(echo "$text" | head -1 | sed 's/^[[:space:]]*//')
  if [[ ${#first_line} -gt 80 ]]; then
    echo "${first_line:0:77}..."
  else
    echo "$first_line"
  fi
}

# Compute duration_ms from pending marker (written by codex--log-delegation-start.sh)
compute_duration() {
  local prompt_text="$1"
  local prompt_prefix="${prompt_text:0:100}"
  local prompt_hash
  prompt_hash=$(printf '%s-%s' "$tool_name" "$prompt_prefix" | shasum -a 256 | cut -c1-16)

  local pending_file="${PENDING_DIR}/${prompt_hash}"
  if [[ -f "$pending_file" ]]; then
    local start_ms
    start_ms=$(cat "$pending_file")
    rm -f "$pending_file"

    local now_ms
    if [[ "$(uname)" == "Darwin" ]]; then
      now_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo "0")
    else
      now_ms=$(date +%s%3N 2>/dev/null || echo "0")
    fi

    if [[ "$now_ms" -gt 0 && "$start_ms" -gt 0 ]]; then
      echo $(( now_ms - start_ms ))
      return
    fi
  fi
  echo "null"
}

# Build log entry based on tool type
if [[ "$tool_type" == "codex" ]]; then
  thread_id=$(echo "$tool_response" | jq -r '.threadId // "unknown"')
  sandbox=$(echo "$tool_input" | jq -r '.sandbox // "default"')
  approval_policy=$(echo "$tool_input" | jq -r '.["approval-policy"] // "default"')
  cwd=$(echo "$tool_input" | jq -r '.cwd // "unknown"')
  prompt=$(echo "$tool_input" | jq -r '.prompt // ""')
  response_content=$(echo "$tool_response" | jq -r '.content // ""')

  if [[ "$thread_id" != "unknown" && "$thread_id" != "null" && -n "$thread_id" ]]; then
    success=true
  else
    success=false
  fi

  summary=$(make_summary "$prompt")
  duration_ms=$(compute_duration "$prompt")

  # Determine turn number for this thread
  detail_file="${DETAIL_DIR}/${thread_id}.jsonl"
  if [[ -f "$detail_file" ]]; then
    turn=$(( $(wc -l < "$detail_file") + 1 ))
  else
    turn=1
  fi

  # Detail entry level
  local_level="info"
  [[ "$success" == "false" ]] && local_level="error"

  # Append full detail as a new turn (JSONL — one line per turn, never overwrites)
  log_json "$local_level" "delegation" "codex_delegation" \
    --argjson turn "$turn" \
    --arg tool "$tool_name" \
    --arg threadId "$thread_id" \
    --arg sandbox "$sandbox" \
    --arg approval_policy "$approval_policy" \
    --arg cwd "$cwd" \
    --arg prompt "$prompt" \
    --arg response "$response_content" \
    --argjson success "$success" \
    --argjson duration_ms "$duration_ms" \
    >> "$detail_file"

  # Summary entry for the index log (no prompt/response)
  log_entry=$(log_json "$local_level" "delegation" "codex_delegation" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg threadId "$thread_id" \
    --arg sandbox "$sandbox" \
    --arg approval_policy "$approval_policy" \
    --arg cwd "$cwd" \
    --arg summary "$summary" \
    --arg detail "$detail_file" \
    --argjson success "$success" \
    --argjson duration_ms "$duration_ms")

elif [[ "$tool_type" == "gemini" ]]; then
  query=$(echo "$tool_input" | jq -r '.query // .url // .prompt // ""')
  response_content=$(echo "$tool_response" | jq -r 'if type == "string" then . else (tostring) end' 2>/dev/null || echo "$tool_response")

  summary=$(make_summary "$query")
  duration_ms=$(compute_duration "$query")

  # Gemini has no threadId, generate a unique id
  detail_id="gemini-$(date +%s)-$$"
  detail_file="${DETAIL_DIR}/${detail_id}.jsonl"

  log_json "info" "delegation" "gemini_query" \
    --arg tool "$tool_name" \
    --arg query "$query" \
    --arg response "$response_content" \
    --argjson success true \
    --argjson duration_ms "$duration_ms" \
    > "$detail_file"

  # Summary entry for the index log (no response)
  log_entry=$(log_json "info" "delegation" "gemini_query" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg summary "$summary" \
    --arg detail "$detail_file" \
    --argjson success true \
    --argjson duration_ms "$duration_ms")
fi

# Append new entry
echo "$log_entry" >> "$LOG_FILE"

# Rotate: keep only the last MAX_ENTRIES lines, cleaning up detail files for removed entries
cleanup_detail() {
  local line="$1"
  local old_detail
  old_detail=$(echo "$line" | jq -r '.detail // ""')
  [[ -f "$old_detail" ]] && rm -f "$old_detail"
}
rotate_jsonl "$LOG_FILE" "$MAX_ENTRIES" cleanup_detail

# Time-based retention: delete detail files older than RETENTION_DAYS
find "$DETAIL_DIR" -name "*.jsonl" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

exit 0
