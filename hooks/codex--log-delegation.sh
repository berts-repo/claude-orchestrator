#!/usr/bin/env bash
# PostToolUse hook
# Logs Codex and Gemini delegations with short summaries to delegations.jsonl
# Full prompt/response stored in per-thread detail files under details/
# Codex threads are JSONL — each turn appends to {threadId}.jsonl
# Keeps the last MAX_ENTRIES summary entries (FIFO rotation)
# Detail files expire after RETENTION_DAYS
# HOOK_EVENT: PostToolUse
# HOOK_MATCHER: mcp__delegate__codex|mcp__delegate__codex_parallel|mcp__delegate_web__search|mcp__delegate_web__fetch
# HOOK_TIMEOUT: 30
set -euo pipefail

REAL_SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_SCRIPT")" && pwd)"
source "$SCRIPT_DIR/shared--log-helpers.sh"
source "$SCRIPT_DIR/shared--codex-log-helpers.sh"

MAX_ENTRIES=100
RETENTION_DAYS=30
LOG_FILE="${LOG_DIR}/delegations.jsonl"
DETAIL_DIR="${LOG_DIR}/details"

ensure_dirs
mkdir -p "$DETAIL_DIR"

# Read input
payload="$(cat)"

tool_name=$(codex_log_extract_tool_name "$payload")
tool_type=$(codex_log_tool_type "$tool_name")
if [[ -z "$tool_type" ]]; then
  exit 0
fi

# Extract common fields
tool_input=$(echo "$payload" | jq -c '.tool_input // {}' 2>/dev/null || echo '{}')
tool_response=$(echo "$payload" | jq -c '.tool_response // {}' 2>/dev/null || echo '{}')

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

# Generate a stable per-call id when threadId is unavailable.
generate_call_id() {
  local prefix="${1:-call}"
  local ts
  if [[ "$(uname)" == "Darwin" ]]; then
    ts=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s000)
  else
    ts=$(date +%s%3N 2>/dev/null || date +%s000)
  fi

  if command -v uuidgen >/dev/null 2>&1; then
    local uuid
    uuid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    if [[ -n "$uuid" ]]; then
      echo "${prefix}-${uuid}"
      return
    fi
  fi

  echo "${prefix}-${ts}-$$-${RANDOM}"
}

# Infer success from MCP tool response payload.
codex_response_success() {
  local response_json="$1"

  # Fast path for common MCP response shape:
  # {"content":[...],"isError":false}
  if echo "$response_json" | jq -e 'type == "object" and has("isError") and .isError == true' >/dev/null 2>&1; then
    echo "false"
    return
  fi
  if echo "$response_json" | jq -e 'type == "object" and has("isError") and .isError == false' >/dev/null 2>&1; then
    echo "true"
    return
  fi

  if echo "$response_json" | jq -e '
    (
      [ .. | objects | .isError? | select(. == true) ] | length
    ) > 0
    or (
      [ .. | objects | .success? | select(. == false) ] | length
    ) > 0
    or (
      [ .. | objects | .error? | select(. != null and . != "" and . != false) ] | length
    ) > 0
    or (
      [ .. | strings | select(test("FAILED \\(exit|\\bError:|timed out|failed to spawn codex"; "i")) ] | length
    ) > 0
  ' >/dev/null 2>&1; then
    echo "false"
  else
    echo "true"
  fi
}

# Compute duration_ms and set STARTED_AT from pending marker (written by codex--log-delegation-start.sh)
STARTED_AT=""
compute_start_and_duration() {
  local prompt_text="$1"
  local prompt_hash
  prompt_hash=$(codex_log_correlation_key "$tool_name" "$prompt_text")

  local pending_file="${PENDING_DIR}/${prompt_hash}"
  if [[ -f "$pending_file" ]]; then
    local start_ms
    start_ms=$(cat "$pending_file")
    rm -f "$pending_file"

    local now_ms
    if [[ "$(uname)" == "Darwin" ]]; then
      STARTED_AT=$(date -u -r "$(( start_ms / 1000 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      now_ms=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo "0")
    else
      STARTED_AT=$(date -u -d "@$(( start_ms / 1000 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
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
  thread_id=$(echo "$tool_response" | jq -r '.threadId // "unknown"' 2>/dev/null || echo "unknown")

  # Reject any thread_id that cannot be a safe filename component.
  # This prevents path traversal: a value like "../../.ssh/authorized_keys"
  # would otherwise be used directly in "${DETAIL_DIR}/${thread_id}.jsonl".
  if [[ "$thread_id" != "unknown" && "$thread_id" != "null" && -n "$thread_id" \
        && ! "$thread_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "$(log_json "error" "delegation" "invalid_thread_id" \
      --arg raw_thread_id "$thread_id" \
      --arg tool "$tool_name")" >> "$LOG_FILE"
    exit 0
  fi

  # Extract prompt and detect parallel vs single call
  if [[ "$tool_name" == "mcp__delegate__codex_parallel" ]]; then
    prompt=$(echo "$tool_input" | jq -c '.tasks // []')
    is_parallel=true
  else
    prompt=$(echo "$tool_input" | jq -r '.prompt // ""')
    is_parallel=false
  fi

  duration_ms=$(compute_start_and_duration "$prompt")

  if [[ "$is_parallel" == "true" ]]; then
    task_count=$(echo "$prompt" | jq 'length')
    first_task_prompt=$(echo "$prompt" | jq -r '.[0].prompt // ""')
    summary=$(make_summary "[${task_count} tasks] ${first_task_prompt}")
    sandbox=$(echo "$prompt" | jq -r '[.[].sandbox // "default"] | unique | join(",")')
    approval_policy=$(echo "$prompt" | jq -r '[.[]."approval-policy" // "default"] | unique | join(",")')
    cwd=$(echo "$prompt" | jq -r '.[0].cwd // "unknown"')
    thread_id="parallel-$(date +%s)-$$"
    response_content=$(echo "$tool_response" | jq -r 'if type == "array" then (map(.content // "") | join("\n")) elif type == "string" then . else tostring end' 2>/dev/null || echo "")
    success=$(codex_response_success "$tool_response")
  else
    sandbox=$(echo "$tool_input" | jq -r '.sandbox // "default"')
    approval_policy=$(echo "$tool_input" | jq -r '.["approval-policy"] // "default"')
    cwd=$(echo "$tool_input" | jq -r '.cwd // "unknown"')
    response_content=$(echo "$tool_response" | jq -r '.content // ""' 2>/dev/null || echo "")
    success=$(codex_response_success "$tool_response")
    if [[ "$thread_id" == "unknown" || "$thread_id" == "null" || -z "$thread_id" ]]; then
      thread_id=$(generate_call_id "codex")
    fi

    summary=$(make_summary "$prompt")
  fi

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
  if [[ "$is_parallel" == "true" ]]; then
    log_json "$local_level" "delegation" "codex_delegation" \
      --argjson turn "$turn" \
      --arg tool "$tool_name" \
      --arg threadId "$thread_id" \
      --argjson task_count "$task_count" \
      --arg sandbox "$sandbox" \
      --arg approval_policy "$approval_policy" \
      --arg cwd "$cwd" \
      --arg prompt "$prompt" \
      --arg response "$response_content" \
      --argjson success "$success" \
      --argjson duration_ms "$duration_ms" \
      --arg started_at "${STARTED_AT:-}" \
      >> "$detail_file"
  else
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
      --arg started_at "${STARTED_AT:-}" \
      >> "$detail_file"
  fi

  # Summary entry for the index log (no prompt/response)
  if [[ "$is_parallel" == "true" ]]; then
    log_entry=$(log_json "$local_level" "delegation" "codex_delegation" \
      --arg type "$tool_type" \
      --arg tool "$tool_name" \
      --arg threadId "$thread_id" \
      --argjson task_count "$task_count" \
      --arg sandbox "$sandbox" \
      --arg approval_policy "$approval_policy" \
      --arg cwd "$cwd" \
      --arg summary "$summary" \
      --arg detail "$detail_file" \
      --argjson success "$success" \
      --argjson duration_ms "$duration_ms" \
      --arg started_at "${STARTED_AT:-}")
  else
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
      --argjson duration_ms "$duration_ms" \
      --arg started_at "${STARTED_AT:-}")
  fi

elif [[ "$tool_type" == "web" || "$tool_type" == "gemini" ]]; then
  query=$(echo "$tool_input" | jq -r '.query // .url // .prompt // ""')
  response_content=$(echo "$tool_response" | jq -r 'if type == "string" then . else (tostring) end' 2>/dev/null || echo "$tool_response")

  summary=$(make_summary "$query")
  duration_ms=$(compute_start_and_duration "$query")

  gemini_success="false"
  gemini_parse_error="false"
  gemini_response_raw="${CLAUDE_TOOL_RESPONSE:-}"

  if [[ -z "$gemini_response_raw" ]]; then
    gemini_parse_error="true"
  elif ! echo "$gemini_response_raw" | jq -e '.' >/dev/null 2>&1; then
    gemini_parse_error="true"
  else
    gemini_is_error=$(echo "$gemini_response_raw" | jq -r 'if (type == "object" and .isError == true) then "true" else "false" end')
    gemini_nonzero_exit=$(echo "$gemini_response_raw" | jq -r '
      [
        .. | objects |
        (.exit_code? // .exitCode? // .["exit-code"]? // empty) |
        (try tonumber catch empty) |
        select(. != 0)
      ] | length > 0
    ')
    gemini_has_expected_result=$(echo "$gemini_response_raw" | jq -r '
      if type == "object" then
        (has("content") or has("result") or has("response") or has("text"))
      else
        false
      end
    ')

    if [[ "$gemini_is_error" == "false" && "$gemini_nonzero_exit" == "false" && "$gemini_has_expected_result" == "true" ]]; then
      gemini_success="true"
    fi
  fi

  # Gemini has no threadId, generate a unique id
  detail_id="gemini-$(date +%s)-$$"
  detail_file="${DETAIL_DIR}/${detail_id}.jsonl"

  log_json "info" "delegation" "gemini_query" \
    --arg tool "$tool_name" \
    --arg query "$query" \
    --arg response "$response_content" \
    --argjson success "$gemini_success" \
    --argjson parse_error "$gemini_parse_error" \
    --argjson duration_ms "$duration_ms" \
    --arg started_at "${STARTED_AT:-}" \
    > "$detail_file"

  # Summary entry for the index log (no response)
  log_entry=$(log_json "info" "delegation" "gemini_query" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg summary "$summary" \
    --arg detail "$detail_file" \
    --argjson success "$gemini_success" \
    --argjson parse_error "$gemini_parse_error" \
    --argjson duration_ms "$duration_ms" \
    --arg started_at "${STARTED_AT:-}")
fi

# Append new entry
echo "$log_entry" >> "$LOG_FILE"

# Rotate: keep only the last MAX_ENTRIES lines, cleaning up detail files for removed entries
cleanup_detail() {
  local line="$1"
  local old_detail
  old_detail=$(echo "$line" | jq -r '.detail // ""')
  [[ -z "$old_detail" || ! -f "$old_detail" ]] && return
  # Resolve the real path (file must exist, so -m / non-GNU realpath is fine)
  # and confirm it stays inside DETAIL_DIR before deleting.
  local canon
  canon=$(readlink -f "$old_detail" 2>/dev/null || realpath "$old_detail" 2>/dev/null) || return
  [[ "$canon" == "${DETAIL_DIR}/"* ]] && rm -f "$old_detail"
}
rotate_jsonl "$LOG_FILE" "$MAX_ENTRIES" cleanup_detail

# Time-based retention: delete detail files older than RETENTION_DAYS
find "$DETAIL_DIR" -name "*.jsonl" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

exit 0
