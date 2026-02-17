#!/usr/bin/env bash
# PostToolUse hook
# Logs Codex and Gemini delegations with short summaries to delegations.jsonl
# Full prompt/response stored in per-thread detail files under details/
# Codex threads are JSONL — each turn appends to {threadId}.jsonl
# Keeps the last MAX_ENTRIES summary entries (FIFO rotation)
# Detail files expire after RETENTION_DAYS
set -euo pipefail

MAX_ENTRIES=100
RETENTION_DAYS=30
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/delegations.jsonl"
DETAIL_DIR="${LOG_DIR}/details"

# Ensure directories exist
mkdir -p "$LOG_DIR" "$DETAIL_DIR"

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
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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

  # Determine turn number for this thread
  detail_file="${DETAIL_DIR}/${thread_id}.jsonl"
  if [[ -f "$detail_file" ]]; then
    turn=$(( $(wc -l < "$detail_file") + 1 ))
  else
    turn=1
  fi

  # Append full detail as a new turn (JSONL — one line per turn, never overwrites)
  jq -nc \
    --arg ts "$timestamp" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg tid "$thread_id" \
    --argjson turn "$turn" \
    --arg sb "$sandbox" \
    --arg ap "$approval_policy" \
    --arg cwd "$cwd" \
    --arg prompt "$prompt" \
    --arg response "$response_content" \
    --argjson success "$success" \
    '{
      timestamp: $ts,
      turn: $turn,
      type: $type,
      tool: $tool,
      threadId: $tid,
      sandbox: $sb,
      approval_policy: $ap,
      cwd: $cwd,
      prompt: $prompt,
      response: $response,
      success: $success
    }' >> "$detail_file"

  # Summary entry for the index log (no prompt/response)
  log_entry=$(jq -nc \
    --arg ts "$timestamp" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg tid "$thread_id" \
    --arg sb "$sandbox" \
    --arg ap "$approval_policy" \
    --arg cwd "$cwd" \
    --arg summary "$summary" \
    --arg detail "$detail_file" \
    --argjson success "$success" \
    '{
      timestamp: $ts,
      type: $type,
      tool: $tool,
      threadId: $tid,
      sandbox: $sb,
      approval_policy: $ap,
      cwd: $cwd,
      summary: $summary,
      detail: $detail,
      success: $success
    }')

elif [[ "$tool_type" == "gemini" ]]; then
  query=$(echo "$tool_input" | jq -r '.query // .url // .prompt // ""')
  response_content=$(echo "$tool_response" | jq -r 'if type == "string" then . else (tostring) end' 2>/dev/null || echo "$tool_response")

  summary=$(make_summary "$query")

  # Gemini has no threadId, generate a unique id
  detail_id="gemini-$(date +%s)-$$"
  detail_file="${DETAIL_DIR}/${detail_id}.jsonl"
  jq -nc \
    --arg ts "$timestamp" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg query "$query" \
    --arg response "$response_content" \
    '{
      timestamp: $ts,
      type: $type,
      tool: $tool,
      query: $query,
      response: $response,
      success: true
    }' > "$detail_file"

  # Summary entry for the index log (no response)
  log_entry=$(jq -nc \
    --arg ts "$timestamp" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg summary "$summary" \
    --arg detail "$detail_file" \
    '{
      timestamp: $ts,
      type: $type,
      tool: $tool,
      summary: $summary,
      detail: $detail,
      success: true
    }')
fi

# Append new entry
echo "$log_entry" >> "$LOG_FILE"

# Rotate: keep only the last MAX_ENTRIES lines
line_count=$(wc -l < "$LOG_FILE")
if [[ "$line_count" -gt "$MAX_ENTRIES" ]]; then
  # Remove detail files for entries being rotated out
  head -n $(( line_count - MAX_ENTRIES )) "$LOG_FILE" | while IFS= read -r line; do
    old_detail=$(echo "$line" | jq -r '.detail // ""')
    [[ -f "$old_detail" ]] && rm -f "$old_detail"
  done
  tail -n "$MAX_ENTRIES" "$LOG_FILE" > "${LOG_FILE}.tmp"
  mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Time-based retention: delete detail files older than RETENTION_DAYS
find "$DETAIL_DIR" -name "*.jsonl" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

exit 0
