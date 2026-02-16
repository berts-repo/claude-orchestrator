#!/usr/bin/env bash
# PostToolUse hook
# Logs Codex and Gemini delegation responses to ~/.claude/logs/delegations.jsonl
# Keeps the last 100 entries (FIFO rotation)
set -euo pipefail

MAX_ENTRIES=5
LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/delegations.jsonl"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

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

  log_entry=$(jq -nc \
    --arg ts "$timestamp" \
    --arg type "$tool_type" \
    --arg tool "$tool_name" \
    --arg tid "$thread_id" \
    --arg sb "$sandbox" \
    --arg ap "$approval_policy" \
    --arg cwd "$cwd" \
    --arg prompt "$prompt" \
    --arg response "$response_content" \
    --argjson success "$success" \
    '{
      timestamp: $ts,
      type: $type,
      tool: $tool,
      threadId: $tid,
      sandbox: $sb,
      approval_policy: $ap,
      cwd: $cwd,
      prompt: $prompt,
      response: $response,
      success: $success
    }')

elif [[ "$tool_type" == "gemini" ]]; then
  query=$(echo "$tool_input" | jq -r '.query // .url // .prompt // ""')
  response_content=$(echo "$tool_response" | jq -r 'if type == "string" then . else (tostring) end' 2>/dev/null || echo "$tool_response")

  log_entry=$(jq -nc \
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
    }')
fi

# Append new entry
echo "$log_entry" >> "$LOG_FILE"

# Rotate: keep only the last MAX_ENTRIES lines
line_count=$(wc -l < "$LOG_FILE")
if [[ "$line_count" -gt "$MAX_ENTRIES" ]]; then
  tail -n "$MAX_ENTRIES" "$LOG_FILE" > "${LOG_FILE}.tmp"
  mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

exit 0
